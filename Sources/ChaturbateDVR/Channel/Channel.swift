import Foundation
import AVFoundation
import AppKit

actor Channel {
    private static let pausedPreviewMinInterval: TimeInterval = 180
    private static let pausedPreviewMaxSegmentBytes = 6 * 1024 * 1024
    private static let recordingPreviewWindowSeconds: TimeInterval = 30
    private static let recordingPreviewMaxBytes = 12 * 1024 * 1024

    private struct PreviewSegmentChunk {
        let data: Data
        let duration: Double
    }

    private(set) var config: ChannelConfig
    private(set) var isOnline: Bool = false
    private(set) var streamedAt: Date?
    private(set) var duration: Double = 0 // seconds
    private(set) var filesize: Int = 0 // bytes
    private(set) var sequence: Int = 0
    private(set) var logs: [String] = []
    private(set) var currentFilename: String?
    private(set) var thumbnailPath: String?
    private(set) var isChecking: Bool = false
    private(set) var isInvalid: Bool
    
    private var currentFile: FileHandle?
    private var monitoringTask: Task<Void, Never>?
    private let client: ChaturbateClient
    private let appConfig: AppConfig
    private var lastThumbnailTime: Date = Date.distantPast
    private var lastPausedPreviewTime: Date = Date.distantPast
    private var isRefreshingPausedPreview: Bool = false
    private var recentPreviewSegments: [PreviewSegmentChunk] = []
    private var recentPreviewDuration: Double = 0
    private var recentPreviewBytes: Int = 0
    private var recordingPreviewTempPath: String?
    private var cloudflareBlockCount: Int = 0
    private let requestCoordinator: RequestCoordinator
    private var isFirstCheck: Bool = true
    
    init(config: ChannelConfig, appConfig: AppConfig, requestCoordinator: RequestCoordinator) {
        self.config = config
        self.appConfig = appConfig
        self.client = ChaturbateClient(config: appConfig)
        self.requestCoordinator = requestCoordinator
        self.isInvalid = config.isInvalid
        
        // Load existing thumbnail if available
        self.thumbnailPath = Self.findExistingThumbnail(username: config.username)
    }
    
    private nonisolated static func findExistingThumbnail(username: String) -> String? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let thumbnailsDir = appSupport.appendingPathComponent("ChaturbateDVR").appendingPathComponent("thumbnails")
        let expectedPath = thumbnailsDir.appendingPathComponent("\(username)_thumb.jpg").path
        
        if FileManager.default.fileExists(atPath: expectedPath) {
            return expectedPath
        }
        return nil
    }
    
    func pause() {
        let wasOnline = isOnline
        config.isPaused = true
        monitoringTask?.cancel()
        monitoringTask = nil
        closeCurrentFile(resetStats: true)
        clearRecordingPreviewState(removeTempFile: true)
        if wasOnline {
            addLog("Channel paused (kept as paused-online until next background check)")
        } else {
            addLog("Channel paused")
        }
    }
    
    func resume() {
        config.isPaused = false
        guard monitoringTask == nil else { return }
        
        monitoringTask = Task {
            await monitor()
        }
        addLog("Channel resumed")
    }
    
    func stopForDeletion() {
        config.isPaused = true
        monitoringTask?.cancel()
        monitoringTask = nil
        isOnline = false
        closeCurrentFile(resetStats: true)
        clearRecordingPreviewState(removeTempFile: true)
        cleanupThumbnail()
        addLog("Channel deleted")
    }
    
    func updateConfig(_ newConfig: ChannelConfig) {
        let wasRecording = !config.isPaused && isOnline
        
        // Update config fields (keep username as identifier)
        config.outputDirectory = newConfig.outputDirectory
        config.framerate = newConfig.framerate
        config.resolution = newConfig.resolution
        config.pattern = newConfig.pattern
        config.maxDuration = newConfig.maxDuration
        config.maxFilesize = newConfig.maxFilesize
        
        // If settings changed while recording, log it
        if wasRecording {
            addLog("Settings updated - changes will apply to next recording session")
        }
    }

    func renameUsername(to newUsername: String) {
        let oldUsername = config.username
        guard !newUsername.isEmpty, newUsername != oldUsername else { return }

        config.username = newUsername

        if let oldPath = thumbnailPath,
           FileManager.default.fileExists(atPath: oldPath) {
            let newPath = (oldPath as NSString)
                .deletingLastPathComponent + "/\(newUsername)_thumb.jpg"
            do {
                // Replace any stale thumbnail for the new username.
                if FileManager.default.fileExists(atPath: newPath) {
                    try FileManager.default.removeItem(atPath: newPath)
                }
                try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
                thumbnailPath = newPath
            } catch {
                addLog("Could not rename thumbnail file during channel rename")
            }
        }

        addLog("Channel renamed from \(oldUsername) to \(newUsername)")
    }
    
    func getInfo() -> ChannelInfo {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd hh:mm a"
        
        return ChannelInfo(
            isOnline: isOnline,
            isPaused: config.isPaused,
            username: config.username,
            duration: formatDuration(duration),
            filesize: formatFilesize(filesize),
            filename: currentFilename,
            streamedAt: streamedAt.map { formatter.string(from: $0) },
            lastOnlineAt: config.lastOnlineAt.map { formatter.string(from: Date(timeIntervalSince1970: TimeInterval($0))) },
            lastOnlineAtUnix: config.lastOnlineAt,
            recordings: config.recordingHistory,
            recordingsDirectory: recordingsDirectoryPath(),
            maxDuration: formatDuration(Double(config.maxDuration * 60)),
            maxFilesize: formatFilesize(config.maxFilesize * 1024 * 1024),
            createdAt: config.createdAt,
            logs: Array(logs.suffix(100)),
            thumbnailPath: thumbnailPath,
            isChecking: isChecking,
            isInvalid: isInvalid
        )
    }

    func backfillOfflineThumbnailIfNeeded() async {
        // Only skip if we already have a successful thumbnail
        guard thumbnailPath == nil,
                            !isOnline else {
            return
        }

        // Keep retrying until successful; don't give up after first failure
        await generateThumbnailFromExistingVideoIfNeeded()
    }

    func refreshPausedOnlineStatus(bypassRateLimit: Bool = false) async {
        guard config.isPaused else { return }

        // If a channel was actively recording when paused, keep that online
        // state sticky until the user resumes it.
        if isOnline {
            return
        }

        let wasOnline = isOnline

        // Use rate limiter for normal background checks.
        // Startup/import sweeps can bypass this for faster online detection.
        if !bypassRateLimit {
            await requestCoordinator.acquireSlot()
        }
        isChecking = true

        do {
            let stream = try await client.getStream(username: config.username)
            isChecking = false
            if !bypassRateLimit {
                await requestCoordinator.releaseSlot()
            }

            markChannelValid()
            isOnline = true
            markLastOnlineNow()

            // Keep paused previews as low-priority, best-effort work.
            // Refreshes are heavily throttled inside the helper.
            if !bypassRateLimit {
                schedulePausedPreviewRefresh(hlsSource: stream.hlsSource)
            }

            if !wasOnline {
                addLog("Background check: channel is now online")
            }
        } catch {
            isChecking = false
            if !bypassRateLimit {
                await requestCoordinator.releaseSlot()
            }

            if let cbError = error as? ChaturbateError {
                switch cbError {
                case .invalidChannel:
                    markChannelInvalid()
                    addLog("Background check: channel returned 404 (marked invalid)")
                default:
                    break
                }
            }
            isOnline = false
            if wasOnline {
                addLog("Background check: channel went offline")
            }
        }
    }

    private func schedulePausedPreviewRefresh(hlsSource: String) {
        Task(priority: .background) { [weak self] in
            guard let self else { return }
            await self.updatePausedChannelThumbnailIfNeeded(hlsSource: hlsSource)
        }
    }

    private func updatePausedChannelThumbnailIfNeeded(hlsSource: String) async {
        let now = Date()
        guard now.timeIntervalSince(lastPausedPreviewTime) >= Self.pausedPreviewMinInterval else {
            return
        }

        guard !isRefreshingPausedPreview else {
            return
        }
        isRefreshingPausedPreview = true
        // Throttle on attempts (not only successes) to avoid retry storms.
        lastPausedPreviewTime = now
        defer { isRefreshingPausedPreview = false }

        do {
            let playlist = try await client.getPlaylist(
                hlsSource: hlsSource,
                resolution: config.resolution,
                framerate: config.framerate
            )

            let httpClient = HTTPClient(config: appConfig)
            let mediaPlaylistContent = try await httpClient.get(playlist.playlistURL)
            let segments = try M3U8Parser.parseMediaPlaylist(mediaPlaylistContent)
            guard let latestSegment = segments.last else { return }

            let segmentURL = resolveSegmentURL(latestSegment.uri, playlistURL: playlist.playlistURL)
            let segmentData = try await downloadSegmentWithRetry(httpClient: httpClient, url: segmentURL, maxRetries: 2)

            // Keep paused previews lightweight and avoid writing large transient files.
            guard segmentData.count <= Self.pausedPreviewMaxSegmentBytes else {
                return
            }

            let tempDir = NSTemporaryDirectory()
            let tempSegmentPath = (tempDir as NSString).appendingPathComponent("\(config.username)_paused_preview.ts")
            let tempSegmentURL = URL(fileURLWithPath: tempSegmentPath)

            try segmentData.write(to: tempSegmentURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tempSegmentURL) }

            addLog("Attempting to refresh thumbnail from live stream")
            let success = await generateThumbnail(from: tempSegmentPath)
            if success {
                await FileLogger.shared.logLiveThumbnailSuccess(channel: config.username)
            }
        } catch {
            // Silently fail - paused previews are best-effort.
            await FileLogger.shared.logLiveThumbnailFailure(channel: config.username, error: error.localizedDescription)
        }
    }
    
    func addLogFromManager(_ message: String) {
        addLog(message)
    }

    func getRecordingFolderPath() -> String {
        recordingsDirectoryPath()
    }
    
    private func monitor() async {
        addLog("Starting to record `\(config.username)`")
        
        while !Task.isCancelled {
            do {
                try await recordStream()
                // Success - reset Cloudflare block count and first check flag
                cloudflareBlockCount = 0
                isFirstCheck = false
            } catch {
                if Task.isCancelled { break }
                
                var waitTime = appConfig.interval * 60 // base wait in seconds
                
                if error is ChaturbateError {
                    let cbError = error as! ChaturbateError
                    switch cbError {
                    case .invalidChannel:
                        markChannelInvalid()
                        waitTime = max(waitTime, 30 * 60)
                        addLog("Channel returned 404 (invalid/deleted). Retrying in \(formatWaitTime(waitTime))")
                        cloudflareBlockCount = 0
                    case .channelOffline, .privateStream:
                        if isFirstCheck {
                            addLog("Channel is offline or private (initial check)")
                        } else {
                            addLog("Channel is offline or private, trying again in \(formatWaitTime(waitTime))")
                        }
                        cloudflareBlockCount = 0 // Reset on normal offline
                    case .cloudflareBlocked:
                        cloudflareBlockCount += 1
                        waitTime = calculateExponentialBackoff(baseInterval: waitTime, blockCount: cloudflareBlockCount)
                        addLog("Blocked by Cloudflare (block #\(cloudflareBlockCount)). Using exponential backoff, trying again in \(formatWaitTime(waitTime))")
                    case .paused:
                        isChecking = false
                        break
                    default:
                        addLog("Error: \(cbError.localizedDescription). Retrying in \(formatWaitTime(waitTime))")
                        cloudflareBlockCount = 0
                    }
                } else {
                    addLog("Error: \(error.localizedDescription). Retrying in \(formatWaitTime(waitTime))")
                    cloudflareBlockCount = 0
                }
                
                isFirstCheck = false
                
                // Channel is not actively probing during retry sleep.
                isChecking = false
                let jitter = Double.random(in: 0.9...1.1)
                let adjustedWait = UInt64(Double(waitTime) * jitter * 1_000_000_000)
                
                // For long waits (>30s), provide periodic feedback
                if waitTime > 30 {
                    let checkInterval: UInt64 = 30_000_000_000 // 30 seconds
                    var elapsed: UInt64 = 0
                    while elapsed < adjustedWait && !Task.isCancelled {
                        let sleepDuration = min(checkInterval, adjustedWait - elapsed)
                        try? await Task.sleep(nanoseconds: sleepDuration)
                        elapsed += sleepDuration
                        if elapsed < adjustedWait && !Task.isCancelled {
                            let remainingSeconds = Int((adjustedWait - elapsed) / 1_000_000_000)
                            addLog("Waiting to retry... \(formatWaitTime(remainingSeconds)) remaining")
                        }
                    }
                } else {
                    try? await Task.sleep(nanoseconds: adjustedWait)
                }
            }
        }

        if !config.isPaused {
            isOnline = false
        }
        closeCurrentFile(resetStats: true)
        clearRecordingPreviewState(removeTempFile: true)
    }
    
    private func recordStream() async throws {
        // Acquire slot from rate limiter before making request
        await requestCoordinator.acquireSlot()
        isChecking = true
        defer {
            Task {
                await requestCoordinator.releaseSlot()
            }
        }
        
        let stream = try await client.getStream(username: config.username)
        markChannelValid()
        
        // Check is complete, now we're in recording mode
        isChecking = false
        
        streamedAt = Date()
        sequence = 0
        
        try await nextFile()
        defer {
            isOnline = false
            closeCurrentFile(resetStats: true)
            clearRecordingPreviewState(removeTempFile: true)
        }
        
        let playlist = try await client.getPlaylist(
            hlsSource: stream.hlsSource,
            resolution: config.resolution,
            framerate: config.framerate
        )
        
        isOnline = true
        markLastOnlineNow()
        addLog("Stream quality - resolution \(playlist.resolution)p (target: \(config.resolution)p), framerate \(playlist.framerate)fps (target: \(config.framerate)fps)")
        
        try await watchSegments(playlist: playlist)
    }
    
    private func watchSegments(playlist: Playlist) async throws {
        var lastSeq = -1
        let httpClient = HTTPClient(config: appConfig)
        
        while !Task.isCancelled && !config.isPaused {
            let content = try await httpClient.get(playlist.playlistURL)
            let segments = try M3U8Parser.parseMediaPlaylist(content)
            
            for segment in segments {
                if Task.isCancelled || config.isPaused {
                    throw ChaturbateError.paused
                }
                
                let seq = segment.sequenceNumber
                if seq == -1 || seq <= lastSeq {
                    continue
                }
                lastSeq = seq

                let segmentURL = resolveSegmentURL(segment.uri, playlistURL: playlist.playlistURL)
                
                // Download segment with retry
                let segmentData = try await downloadSegmentWithRetry(
                    httpClient: httpClient,
                    url: segmentURL,
                    maxRetries: 3
                )
                
                try await handleSegment(data: segmentData, duration: segment.duration)
            }
            
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
    }

    private func resolveSegmentURL(_ uri: String, playlistURL: String) -> String {
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
            return uri
        }

        guard let baseURL = URL(string: playlistURL),
              let resolved = URL(string: uri, relativeTo: baseURL)?.absoluteURL else {
            return uri
        }

        return resolved.absoluteString
    }
    
    private func downloadSegmentWithRetry(httpClient: HTTPClient, url: String, maxRetries: Int) async throws -> Data {
        var lastError: Error?
        
        for _ in 0..<maxRetries {
            do {
                return try await httpClient.getData(url)
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 600_000_000) // 600ms delay
            }
        }
        
        throw lastError ?? ChaturbateError.networkError("Failed to download segment")
    }
    
    private func handleSegment(data: Data, duration: Double) async throws {
        if config.isPaused {
            throw ChaturbateError.paused
        }
        
        guard let file = currentFile else {
            throw ChaturbateError.fileError("No file open")
        }
        
        try file.write(contentsOf: data)
        try file.synchronize()
        
        filesize += data.count
        self.duration += duration
        appendSegmentToRecordingPreviewBuffer(data: data, duration: duration)
        
        // Generate thumbnail every 5 seconds
        let now = Date()
        if now.timeIntervalSince(lastThumbnailTime) >= 5.0 {
            lastThumbnailTime = now
            let success = await refreshLiveRecordingThumbnail()
            if success {
                await FileLogger.shared.logLiveThumbnailSuccess(channel: config.username)
            }
        }
        
        addLog("Duration: \(formatDuration(self.duration)), Filesize: \(formatFilesize(filesize))")
        
        if shouldSwitchFile() {
            try await nextFile()
            addLog("Max filesize or duration exceeded, new file created: \(currentFilename ?? "unknown")")
        }
    }
    
    private func nextFile() async throws {
        closeCurrentFile(resetStats: true)
        let filename = try generateFilename()
        try await createNewFile(filename: filename)
        sequence += 1
    }
    
    private func generateFilename() throws -> String {
        guard let streamedAt = streamedAt else {
            throw ChaturbateError.fileError("No stream start time")
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        let year = formatter.string(from: streamedAt)
        formatter.dateFormat = "MM"
        let month = formatter.string(from: streamedAt)
        formatter.dateFormat = "dd"
        let day = formatter.string(from: streamedAt)
        formatter.dateFormat = "HH"
        let hour = formatter.string(from: streamedAt)
        formatter.dateFormat = "mm"
        let minute = formatter.string(from: streamedAt)
        formatter.dateFormat = "ss"
        let second = formatter.string(from: streamedAt)
        
        var pattern = config.pattern
        pattern = pattern.replacingOccurrences(of: "{{.Username}}", with: config.username)
        pattern = pattern.replacingOccurrences(of: "{{.Year}}", with: year)
        pattern = pattern.replacingOccurrences(of: "{{.Month}}", with: month)
        pattern = pattern.replacingOccurrences(of: "{{.Day}}", with: day)
        pattern = pattern.replacingOccurrences(of: "{{.Hour}}", with: hour)
        pattern = pattern.replacingOccurrences(of: "{{.Minute}}", with: minute)
        pattern = pattern.replacingOccurrences(of: "{{.Second}}", with: second)
        
        if sequence == 0 {
            pattern = pattern.replacingOccurrences(of: "{{if .Sequence}}_{{.Sequence}}{{end}}", with: "")
        } else {
            pattern = pattern.replacingOccurrences(of: "{{if .Sequence}}_{{.Sequence}}{{end}}", with: "_\(sequence)")
        }
        pattern = pattern.replacingOccurrences(of: "{{.Sequence}}", with: "\(sequence)")
        
        // Strip any path components from the pattern - it should only be a filename
        let filename = (pattern as NSString).lastPathComponent
        
        // Get base output directory (app default or channel-specific override)
        let baseOutputDir = config.outputDirectory.isEmpty ? appConfig.getOutputPath() : config.outputDirectory
        
        // Add username as subfolder
        let outputDir = (baseOutputDir as NSString).appendingPathComponent(config.username)
        
        // Combine output directory with filename-only pattern
        let fullPath = (outputDir as NSString).appendingPathComponent(filename)
        
        return fullPath
    }
    
    private func createNewFile(filename: String) async throws {
        let fileURL = URL(fileURLWithPath: (filename as NSString).expandingTildeInPath + ".ts")
        
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        let created = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard created else {
            throw ChaturbateError.fileError("Could not create file: \(fileURL.path)")
        }
        
        guard let fileHandle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw ChaturbateError.fileError("Could not open file: \(fileURL.path)")
        }
        
        currentFile = fileHandle
        currentFilename = fileURL.path

        config.recordingHistory.append(fileURL.path)
        if config.recordingHistory.count > 200 {
            config.recordingHistory.removeFirst(config.recordingHistory.count - 200)
        }
    }
    
    private func closeCurrentFile(resetStats: Bool) {
        if let file = currentFile {
            do {
                try file.synchronize()
                try file.close()
            } catch {
                // Ignore close errors
            }

            currentFile = nil
        }

        if resetStats {
            filesize = 0
            duration = 0
            currentFilename = nil
        }
    }

    private func appendSegmentToRecordingPreviewBuffer(data: Data, duration: Double) {
        recentPreviewSegments.append(PreviewSegmentChunk(data: data, duration: duration))
        recentPreviewDuration += duration
        recentPreviewBytes += data.count

        while recentPreviewSegments.count > 1,
              (recentPreviewDuration > Self.recordingPreviewWindowSeconds || recentPreviewBytes > Self.recordingPreviewMaxBytes) {
            let removed = recentPreviewSegments.removeFirst()
            recentPreviewDuration = max(0, recentPreviewDuration - removed.duration)
            recentPreviewBytes = max(0, recentPreviewBytes - removed.data.count)
        }
    }

    private func recordingPreviewTempFilePath() -> String {
        if let existing = recordingPreviewTempPath {
            return existing
        }

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let previewsDir = tempRoot
            .appendingPathComponent("ChaturbateDVR")
            .appendingPathComponent("recording_previews")
        try? FileManager.default.createDirectory(at: previewsDir, withIntermediateDirectories: true)

        let path = previewsDir.appendingPathComponent("\(config.username)_preview.ts").path
        recordingPreviewTempPath = path
        return path
    }

    private func writeRecordingPreviewTempFileIfNeeded() -> String? {
        guard !recentPreviewSegments.isEmpty else { return nil }

        let path = recordingPreviewTempFilePath()
        let url = URL(fileURLWithPath: path)

        do {
            var merged = Data()
            merged.reserveCapacity(recentPreviewBytes)
            for chunk in recentPreviewSegments {
                merged.append(chunk.data)
            }
            try merged.write(to: url, options: .atomic)
            return path
        } catch {
            return nil
        }
    }

    private func refreshLiveRecordingThumbnail() async -> Bool {
        if let previewPath = writeRecordingPreviewTempFileIfNeeded() {
            let previewSuccess = await generateThumbnail(from: previewPath)
            if previewSuccess {
                return true
            }
        }

        guard let filename = currentFilename else { return false }
        return await generateThumbnail(from: filename)
    }

    private func clearRecordingPreviewState(removeTempFile: Bool) {
        recentPreviewSegments.removeAll(keepingCapacity: false)
        recentPreviewDuration = 0
        recentPreviewBytes = 0

        if removeTempFile, let path = recordingPreviewTempPath {
            try? FileManager.default.removeItem(atPath: path)
            recordingPreviewTempPath = nil
        }
    }
    
    private func cleanupThumbnail() {
        if let path = thumbnailPath {
            try? FileManager.default.removeItem(atPath: path)
            thumbnailPath = nil
        }
    }
    
    private func calculateExponentialBackoff(baseInterval: Int, blockCount: Int) -> Int {
        // Exponential backoff: base * 2^(blockCount-1), capped at 30 minutes
        let multiplier = min(pow(2.0, Double(blockCount - 1)), 30.0)
        return min(Int(Double(baseInterval) * multiplier), 30 * 60)
    }
    
    private func formatWaitTime(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        } else {
            let minutes = seconds / 60
            let remainingSeconds = seconds % 60
            if remainingSeconds == 0 {
                return "\(minutes)m"
            }
            return "\(minutes)m \(remainingSeconds)s"
        }
    }
    
    private func shouldSwitchFile() -> Bool {
        let maxFilesizeBytes = config.maxFilesize * 1024 * 1024
        let maxDurationSeconds = config.maxDuration * 60
        
        return (duration >= Double(maxDurationSeconds) && config.maxDuration > 0) ||
               (filesize >= maxFilesizeBytes && config.maxFilesize > 0)
    }
    
    private func addLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timestamp = formatter.string(from: Date())
        let logMessage = "\(timestamp) [INFO] \(message)"
        logs.append(logMessage)
        if logs.count > 100 {
            logs.removeFirst()
        }

        // Persist every channel log entry for post-mortem debugging.
        let channelName = config.username
        Task {
            await FileLogger.shared.log(message, channel: channelName)
        }
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
    
    private func formatFilesize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func markLastOnlineNow() {
        config.lastOnlineAt = Int64(Date().timeIntervalSince1970)
    }

    private func markChannelInvalid() {
        isInvalid = true
        config.isInvalid = true
    }

    private func markChannelValid() {
        if isInvalid {
            addLog("Channel recovered from invalid state")
        }
        isInvalid = false
        config.isInvalid = false
    }

    private func recordingsDirectoryPath() -> String {
        if let currentFilename {
            return (currentFilename as NSString).deletingLastPathComponent
        }

        if let lastRecording = config.recordingHistory.last {
            return (lastRecording as NSString).deletingLastPathComponent
        }

        // Get base output directory (app default or channel-specific override)
        let baseOutputDir = config.outputDirectory.isEmpty ? appConfig.getOutputPath() : config.outputDirectory
        
        // Add username as subfolder
        return (baseOutputDir as NSString).appendingPathComponent(config.username)
    }

    private func generateThumbnailFromExistingVideoIfNeeded() async {
        guard thumbnailPath == nil else { return }

        let candidate = latestVideoCandidateForThumbnail()
        guard let candidate else {
            await FileLogger.shared.logNoVideosFound(channel: config.username)
            addLog("Background: checking for videos to thumbnail... none found yet")
            return
        }

        let fileName = (candidate as NSString).lastPathComponent
        let fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: candidate)[.size] as? NSNumber)?.intValue ?? 0
        let fileSize = formatFilesize(fileSizeBytes)
        
        await FileLogger.shared.logBackfillAttempt(channel: config.username, videoPath: fileName, fileSize: fileSize)
        addLog("Background: attempting to generate thumbnail from: \(fileName) (\(fileSize))")
        
        let success = await generateThumbnail(from: candidate)
        if success {
            await FileLogger.shared.logBackfillSuccess(channel: config.username)
        } else {
            await FileLogger.shared.logBackfillFailure(channel: config.username, error: "frame extraction failed")
        }
    }

    private func latestVideoCandidateForThumbnail() -> String? {
        var candidates = Set<String>()

        for recording in config.recordingHistory {
            let normalized = (recording as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: normalized) {
                candidates.insert(normalized)
            }
        }

        let directoryPath = (recordingsDirectoryPath() as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: directoryPath),
           let fileNames = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) {
            for fileName in fileNames {
                let lower = fileName.lowercased()
                guard lower.hasSuffix(".ts") || lower.hasSuffix(".mp4") || lower.hasSuffix(".mkv") || lower.hasSuffix(".mov") else {
                    continue
                }
                let fullPath = (directoryPath as NSString).appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: fullPath) {
                    candidates.insert(fullPath)
                }
            }
        }

        let sorted = candidates.sorted { lhs, rhs in
            let lhsDate = (try? FileManager.default.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? Date.distantPast
            let rhsDate = (try? FileManager.default.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? Date.distantPast
            return lhsDate > rhsDate
        }

        for path in sorted {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 2 * 1024 * 1024 {
                return path
            }
        }

        return sorted.first
    }
    
    private func generateThumbnail(from videoPath: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: videoPath) else { return false }
        
        let asset = AVAsset(url: URL(fileURLWithPath: videoPath))
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 1280, height: 720)
        
        do {
            // For large files, loading duration can be slow. Use a timeout.
            let durationTask = Task {
                try await asset.load(.duration)
            }
            
            let duration: CMTime
            do {
                duration = try await withTimeoutInterval(10.0) {
                    try await durationTask.value
                }
            } catch {
                addLog("Thumbnail generation timeout for large file, trying with fixed time")
                duration = CMTime(seconds: 10.0, preferredTimescale: 600)
            }
            
            // For very large files, extract frame from early in the video (10 sec)
            // For smaller files, prefer near the end (2 sec before end)
            let targetTime: CMTime
            if duration.seconds > 600 { // > 10 minutes
                // Large file: use frame from 10 seconds in
                targetTime = CMTime(seconds: 10.0, preferredTimescale: 600)
            } else {
                // Normal file: use frame from 2 seconds before end
                targetTime = CMTime(seconds: max(0, duration.seconds - 2.0), preferredTimescale: 600)
            }
            
            let cgImage = try imageGenerator.copyCGImage(at: targetTime, actualTime: nil)
            
            // Save thumbnail to persistent app support directory
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let appFolder = appSupport.appendingPathComponent("ChaturbateDVR")
            let thumbnailsDir = appFolder.appendingPathComponent("thumbnails")
            try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
            
            let newThumbnailPath = thumbnailsDir.appendingPathComponent("\(config.username)_thumb.jpg").path
            let thumbnailURL = URL(fileURLWithPath: newThumbnailPath)
            
            // Delete old thumbnail if it exists
            if let oldPath = thumbnailPath, FileManager.default.fileExists(atPath: oldPath) {
                try? FileManager.default.removeItem(atPath: oldPath)
            }
            
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            if let tiffData = image.tiffRepresentation,
               let bitmapImage = NSBitmapImageRep(data: tiffData),
               let jpegData = bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: 0.90]) {
                try jpegData.write(to: thumbnailURL)
                thumbnailPath = newThumbnailPath
                addLog("✓ Thumbnail generated successfully")
                return true
            }
            return false
        } catch {
            // Silently fail on most errors - thumbnails are nice-to-have
            addLog("Thumbnail generation failed: \(error.localizedDescription)")
            return false
        }
    }
    
    private func withTimeoutInterval<T>(_ seconds: TimeInterval, _ operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            
            if let result = try await group.next() {
                group.cancelAll()
                return result
            }
            throw TimeoutError()
        }
    }
}

private struct TimeoutError: Error {}
