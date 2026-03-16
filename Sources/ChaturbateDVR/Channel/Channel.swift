import Foundation
import AVFoundation
import AppKit
import Vision

actor Channel {
    private static let pausedPreviewMinInterval: TimeInterval = 180
    private static let pausedOnlineStickyDuration: TimeInterval = 60
    private static let degradedRecoveryWindowSeconds: TimeInterval = 60
    private static let pausedPreviewMaxSegmentBytes = 6 * 1024 * 1024
    private static let recordingPreviewWindowSeconds: TimeInterval = 30
    private static let recordingPreviewMaxBytes = 12 * 1024 * 1024
    private static let waitingStatusCheckIntervalSeconds: TimeInterval = 12
    private static let waitingPreviewMinInterval: TimeInterval = 20
    private static let breakStaticMotionThreshold: Double = 0.003
    private static let breakLowMotionThreshold: Double = 0.015
    private static let breakAnalysisImageSize: Int = 64
    private static let noPersonOfflineCarryWindowSeconds: TimeInterval = 600
    private static let noPersonThenStaticConfirmSeconds: TimeInterval = 45
    private static let recordingStartNoPersonSamples: Int = 3
    private static let recordingStartNoPersonRequiredMisses: Int = 2

    private struct PreviewSegmentChunk {
        let data: Data
        let duration: Double
    }

    private struct ThumbnailGenerationResult {
        let success: Bool
        let breakDetected: Bool
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
    private(set) var isWaitingForRecordingSlot: Bool = false
    private(set) var isInvalid: Bool
    
    private var currentFile: FileHandle?
    private var monitoringTask: Task<Void, Never>?
    private var waitingForSlotStatusTask: Task<Void, Never>?
    private var client: ChaturbateClient
    private var appConfig: AppConfig
    private var lastThumbnailTime: Date = Date.distantPast
    private var lastPausedPreviewTime: Date = Date.distantPast
    private var lastWaitingPreviewTime: Date = Date.distantPast
    private var isRefreshingPausedPreview: Bool = false
    private var isRefreshingWaitingPreview: Bool = false
    private var pausedOnlineStickyUntil: Date?
    private var recentPreviewSegments: [PreviewSegmentChunk] = []
    private var recentPreviewDuration: Double = 0
    private var recentPreviewBytes: Int = 0
    private var recordingPreviewTempPath: String?
    private var activeInitSegmentURI: String?
    private var activeInitSegmentData: Data?
    private var currentFileDecodeTimeOffset: UInt64?
    private var lastPreviewFailureLogAt: Date = Date.distantPast
    private var cloudflareBlockCount: Int = 0
    private var segmentRetryCount: Int = 0
    private var consecutiveSegmentFailures: Int = 0
    private var lastSegmentFailureAt: Date?
    private var degradedRecoveryStartedAt: Date?
    private var lastBreakAnalysisAt: Date?
    private var lastBreakLumaFrame: [UInt8]?
    private var latestPersonDetected: Bool?
    private var lastPersonSeenAt: Date?
    private var isNoPersonLikely: Bool = false
    private var noPersonStreakSeconds: TimeInterval = 0
    private var noPersonCarryExpiryAt: Date?
    private var noPersonEvidenceExpiryAt: Date?
    private var activePersonMotionSeconds: TimeInterval = 0
    private var breakEnforced: Bool = false
    private var breakEnforcedAt: Date?
    private var staticFrameStreakSeconds: TimeInterval = 0
    private var noPersonNoMotionStreakSeconds: TimeInterval = 0
    private var pendingBreakOfflineReason: String?
    private let requestCoordinator: RequestCoordinator
    private let recordingCoordinator: RecordingCoordinator
    private var isFirstCheck: Bool = true
    
    init(config: ChannelConfig, appConfig: AppConfig, requestCoordinator: RequestCoordinator, recordingCoordinator: RecordingCoordinator) {
        self.config = config
        self.appConfig = appConfig
        self.client = ChaturbateClient(config: appConfig)
        self.requestCoordinator = requestCoordinator
        self.recordingCoordinator = recordingCoordinator
        self.isInvalid = config.isInvalid
        
        // Load existing thumbnail if available
        self.thumbnailPath = Self.findExistingThumbnail(username: config.username)
    }

    func updateAppConfig(_ newAppConfig: AppConfig) {
        appConfig = newAppConfig
        client = ChaturbateClient(config: newAppConfig)
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
        pausedOnlineStickyUntil = wasOnline ? Date().addingTimeInterval(Self.pausedOnlineStickyDuration) : nil
        resetBreakDetectionState()
        monitoringTask?.cancel()
        monitoringTask = nil
        waitingForSlotStatusTask?.cancel()
        waitingForSlotStatusTask = nil
        closeCurrentFile(resetStats: true)
        clearRecordingPreviewState(removeTempFile: true)
        isWaitingForRecordingSlot = false
        if wasOnline {
            addLog("Channel paused (kept as paused-online for up to 1 minute)")
        } else {
            addLog("Channel paused")
        }
    }
    
    func resume() {
        config.isPaused = false
        pausedOnlineStickyUntil = nil
        guard monitoringTask == nil else { return }
        
        monitoringTask = Task {
            await monitor()
        }
        addLog("Channel resumed")
    }
    
    func stopForDeletion() {
        config.isPaused = true
        pausedOnlineStickyUntil = nil
        resetBreakDetectionState()
        monitoringTask?.cancel()
        monitoringTask = nil
        waitingForSlotStatusTask?.cancel()
        waitingForSlotStatusTask = nil
        isOnline = false
        isWaitingForRecordingSlot = false
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
        config.bioMetadata = newConfig.bioMetadata
        
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
            isWaitingForRecordingSlot: isWaitingForRecordingSlot,
            isInvalid: isInvalid,
            cloudflareBlockCount: cloudflareBlockCount,
            isNoPersonDetected: isNoPersonLikely,
            noPersonDurationSeconds: max(0, Int(noPersonStreakSeconds.rounded())),
            segmentRetryCount: segmentRetryCount,
            consecutiveSegmentFailures: consecutiveSegmentFailures,
            lastSegmentFailureAt: lastSegmentFailureAt.map { formatter.string(from: $0) },
            bioMetadata: config.bioMetadata
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
            let stickyActive = pausedOnlineStickyUntil.map { Date() < $0 } ?? false
            if stickyActive {
                // Preserve paused-online state briefly for channels that were
                // active at pause time, but continue probing in the background.
                isOnline = true
                if wasOnline {
                    addLog("Background check: probe failed/offline, keeping paused-online sticky state")
                }
            } else {
                pausedOnlineStickyUntil = nil
                markOfflineAndClearDegradedState()
                if wasOnline {
                    addLog("Background check: channel went offline")
                }
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
            let initData = try await loadInitSegmentDataIfPresent(
                mediaPlaylistContent: mediaPlaylistContent,
                playlistURL: playlist.playlistURL,
                httpClient: httpClient
            )
            let tempExtension = initData == nil ? "ts" : "mp4"
            let tempSegmentPath = (tempDir as NSString).appendingPathComponent("\(config.username)_paused_preview.\(tempExtension)")
            let tempSegmentURL = URL(fileURLWithPath: tempSegmentPath)

            var previewData = Data()
            if let initData {
                previewData.append(initData)
            }
            previewData.append(segmentData)

            try previewData.write(to: tempSegmentURL, options: .atomic)
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
                    case .channelOffline:
                        let breakReason = consumePendingBreakOfflineReason()
                        markOfflineAndClearDegradedState()
                        if let breakReason {
                            addLog("\(breakReason). Treating stream as offline, trying again in \(formatWaitTime(waitTime))")
                        } else if isFirstCheck {
                            addLog("Channel is offline or private (initial check)")
                        } else {
                            addLog("Channel is offline, trying again in \(formatWaitTime(waitTime))")
                        }
                        cloudflareBlockCount = 0 // Reset on normal offline
                    case .privateStream:
                        markOfflineAndClearDegradedState()
                        if isFirstCheck {
                            addLog("Channel is offline or private (initial check)")
                        } else {
                            addLog("Channel is private, trying again in \(formatWaitTime(waitTime))")
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
        resetBreakDetectionState()
        endWaitingForSlotMonitoring()
        closeCurrentFile(resetStats: true)
        clearRecordingPreviewState(removeTempFile: true)
    }
    
    private func recordStream() async throws {
        isChecking = true
        prepareForRecordingAttempt()

        let stream = try await withRequestSlot {
            try await client.getStream(username: config.username)
        }
        markChannelValid()

        if await shouldRemainOnBreakBeforeRecording(hlsSource: stream.hlsSource) {
            throw ChaturbateError.channelOffline
        }

        if await shouldDelayStartForNoPerson(hlsSource: stream.hlsSource) {
            throw ChaturbateError.channelOffline
        }
        
        // Check is complete, now we're in recording mode
        isChecking = false
        
        let playlist = try await withRequestSlot {
            try await client.getPlaylist(
                hlsSource: stream.hlsSource,
                resolution: config.resolution,
                framerate: config.framerate
            )
        }

        beginWaitingForSlotMonitoring(initialHlsSource: stream.hlsSource)

        try await withRecordingSlot {
            endWaitingForSlotMonitoring()

            streamedAt = Date()
            sequence = 0

            try await nextFile()
            defer {
                // Preserve paused-live state after a user pause until paused probes settle.
                if config.isPaused {
                    let stickyActive = pausedOnlineStickyUntil.map { Date() < $0 } ?? false
                    if !stickyActive {
                        isOnline = false
                    }
                } else {
                    isOnline = false
                }
                closeCurrentFile(resetStats: true)
                clearRecordingPreviewState(removeTempFile: true)
            }

            isOnline = true
            markLastOnlineNow()
            addLog("Recording slot acquired")
            addLog("Stream quality - resolution \(playlist.resolution)p (target: \(config.resolution)p), framerate \(playlist.framerate)fps (target: \(config.framerate)fps)")

            try await watchSegments(playlist: playlist)
        }

        endWaitingForSlotMonitoring()
    }

    private func beginWaitingForSlotMonitoring(initialHlsSource: String) {
        waitingForSlotStatusTask?.cancel()
        isWaitingForRecordingSlot = true
        // We already confirmed stream availability before queueing for a slot.
        isOnline = true
        markLastOnlineNow()
        addLog("Waiting for available recording slot")

        waitingForSlotStatusTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            var latestHlsSource = initialHlsSource

            await self.refreshWaitingForSlotState(hlsSource: latestHlsSource)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.waitingStatusCheckIntervalSeconds * 1_000_000_000))
                if Task.isCancelled { break }

                if let refreshed = await self.probeWaitingStreamStatus() {
                    latestHlsSource = refreshed
                    await self.refreshWaitingForSlotState(hlsSource: latestHlsSource)
                }
            }
        }
    }

    private func endWaitingForSlotMonitoring() {
        waitingForSlotStatusTask?.cancel()
        waitingForSlotStatusTask = nil
        isWaitingForRecordingSlot = false
    }

    // Returns an updated HLS source when stream probing succeeds.
    private func probeWaitingStreamStatus() async -> String? {
        guard isWaitingForRecordingSlot, !config.isPaused else { return nil }

        isChecking = true
        do {
            let stream = try await withRequestSlot {
                try await client.getStream(username: config.username)
            }
            isChecking = false
            markChannelValid()
            isOnline = true
            markLastOnlineNow()
            return stream.hlsSource
        } catch {
            isChecking = false

            if let cbError = error as? ChaturbateError {
                switch cbError {
                case .invalidChannel:
                    markChannelInvalid()
                    markOfflineAndClearDegradedState()
                    addLog("Waiting for slot: channel returned 404 (marked invalid)")
                case .channelOffline, .privateStream:
                    markOfflineAndClearDegradedState()
                default:
                    // Keep previous online state for transient failures.
                    break
                }
            }

            return nil
        }
    }

    private func refreshWaitingForSlotState(hlsSource: String) async {
        guard isWaitingForRecordingSlot else { return }
        await updateWaitingChannelThumbnailIfNeeded(hlsSource: hlsSource)
    }

    private func updateWaitingChannelThumbnailIfNeeded(hlsSource: String) async {
        let now = Date()
        guard now.timeIntervalSince(lastWaitingPreviewTime) >= Self.waitingPreviewMinInterval else {
            return
        }

        guard !isRefreshingWaitingPreview else {
            return
        }
        isRefreshingWaitingPreview = true
        // Throttle on attempts (not only successes) to avoid retry storms.
        lastWaitingPreviewTime = now
        defer { isRefreshingWaitingPreview = false }

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

            guard segmentData.count <= Self.pausedPreviewMaxSegmentBytes else {
                return
            }

            let tempDir = NSTemporaryDirectory()
            let initData = try await loadInitSegmentDataIfPresent(
                mediaPlaylistContent: mediaPlaylistContent,
                playlistURL: playlist.playlistURL,
                httpClient: httpClient
            )
            let tempExtension = initData == nil ? "ts" : "mp4"
            let tempSegmentPath = (tempDir as NSString).appendingPathComponent("\(config.username)_waiting_preview.\(tempExtension)")
            let tempSegmentURL = URL(fileURLWithPath: tempSegmentPath)

            var previewData = Data()
            if let initData {
                previewData.append(initData)
            }
            previewData.append(segmentData)

            try previewData.write(to: tempSegmentURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tempSegmentURL) }

            let success = await generateThumbnail(from: tempSegmentPath)
            if success {
                await FileLogger.shared.logLiveThumbnailSuccess(channel: config.username)
            }
        } catch {
            // Waiting previews are best-effort and should not affect queue progression.
            await FileLogger.shared.logLiveThumbnailFailure(channel: config.username, error: error.localizedDescription)
        }
    }

    private func withRequestSlot<T>(_ operation: () async throws -> T) async throws -> T {
        await requestCoordinator.acquireSlot()
        do {
            let result = try await operation()
            await requestCoordinator.releaseSlot()
            return result
        } catch {
            await requestCoordinator.releaseSlot()
            throw error
        }
    }

    private func withRecordingSlot<T>(_ operation: () async throws -> T) async throws -> T {
        await recordingCoordinator.acquireSlot()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await recordingCoordinator.releaseSlot()
            return result
        } catch {
            await recordingCoordinator.releaseSlot()
            throw error
        }
    }
    
    private func watchSegments(playlist: Playlist) async throws {
        var lastSeq = -1
        let httpClient = HTTPClient(config: appConfig)
        
        while !Task.isCancelled && !config.isPaused {
            let content = try await httpClient.get(playlist.playlistURL)
            try await refreshActiveInitSegment(
                mediaPlaylistContent: content,
                playlistURL: playlist.playlistURL,
                httpClient: httpClient
            )
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

                let normalizedSegmentData = normalizeFragmentDecodeTimeIfNeeded(segmentData)
                
                try await handleSegment(data: normalizedSegmentData, duration: segment.duration)
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
        
        for attempt in 1...maxRetries {
            do {
                let data = try await httpClient.getData(url)
                if attempt > 1 {
                    segmentRetryCount += (attempt - 1)
                }
                noteSuccessfulSegmentDownload(attempt: attempt)
                return data
            } catch {
                lastError = error
                degradedRecoveryStartedAt = nil
                if attempt < maxRetries {
                    addLog("Segment download failed (attempt \(attempt)/\(maxRetries)); retrying")
                }
                try? await Task.sleep(nanoseconds: 600_000_000) // 600ms delay
            }
        }

        noteFailedSegmentDownload()
        addLog("Segment download failed after \(maxRetries) attempts")
        
        throw lastError ?? ChaturbateError.networkError("Failed to download segment")
    }

    private func markOfflineAndClearDegradedState() {
        isOnline = false
        preserveNoPersonStateAcrossTransientOffline()
        clearDegradedState()
    }

    private func clearDegradedState() {
        consecutiveSegmentFailures = 0
        lastSegmentFailureAt = nil
        degradedRecoveryStartedAt = nil
    }

    private func noteFailedSegmentDownload() {
        consecutiveSegmentFailures += 1
        lastSegmentFailureAt = Date()
        degradedRecoveryStartedAt = nil
    }

    private func noteSuccessfulSegmentDownload(attempt: Int) {
        guard consecutiveSegmentFailures > 0 else {
            degradedRecoveryStartedAt = nil
            return
        }

        // Consider the stream healthy only when segments arrive without retries.
        guard attempt == 1 else {
            degradedRecoveryStartedAt = nil
            return
        }

        let now = Date()
        if let recoveryStart = degradedRecoveryStartedAt {
            if now.timeIntervalSince(recoveryStart) > Self.degradedRecoveryWindowSeconds {
                clearDegradedState()
                addLog("Cleared degraded status after 1 minute of stable segment downloads")
            }
            return
        }

        degradedRecoveryStartedAt = now
    }
    
    private func handleSegment(data: Data, duration: Double) async throws {
        if config.isPaused {
            throw ChaturbateError.paused
        }

        guard currentFile != nil else {
            throw ChaturbateError.fileError("No file open")
        }

        if filesize == 0, activeInitSegmentData != nil {
            try migrateActiveRecordingFileToMP4IfNeeded()
        }

        guard let file = currentFile else {
            throw ChaturbateError.fileError("No file open")
        }

        if filesize == 0, let initData = activeInitSegmentData {
            try file.write(contentsOf: initData)
            filesize += initData.count
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
            let thumbnailResult = await refreshLiveRecordingThumbnail()
            if thumbnailResult.success {
                await FileLogger.shared.logLiveThumbnailSuccess(channel: config.username)
            }
            if thumbnailResult.breakDetected {
                throw ChaturbateError.channelOffline
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
        let fileExtension = activeInitSegmentData == nil ? "ts" : "mp4"
        let isFirstFileInSession = (sequence == 0)
        try await createNewFile(filename: filename, fileExtension: fileExtension)
        if isFirstFileInSession {
            addLog("Recording container selected: .\(fileExtension)")
        }
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
    
    private func createNewFile(filename: String, fileExtension: String) async throws {
        let fileURL = URL(fileURLWithPath: (filename as NSString).expandingTildeInPath + ".\(fileExtension)")
        
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

    private func migrateActiveRecordingFileToMP4IfNeeded() throws {
        guard let existingPath = currentFilename,
              existingPath.lowercased().hasSuffix(".ts"),
              let existingHandle = currentFile else {
            return
        }

        let sourceURL = URL(fileURLWithPath: existingPath)
        let destinationURL = sourceURL.deletingPathExtension().appendingPathExtension("mp4")

        do {
            try existingHandle.synchronize()
            try existingHandle.close()
        } catch {
            // Continue with rename attempt; some handles can still be moved safely.
        }
        currentFile = nil

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)

        guard let reopenedHandle = FileHandle(forWritingAtPath: destinationURL.path) else {
            throw ChaturbateError.fileError("Could not reopen file after switching to .mp4: \(destinationURL.path)")
        }
        reopenedHandle.seekToEndOfFile()
        currentFile = reopenedHandle
        currentFilename = destinationURL.path

        if let historyIndex = config.recordingHistory.lastIndex(of: sourceURL.path) {
            config.recordingHistory[historyIndex] = destinationURL.path
        }

        addLog("Detected fragmented MP4 stream, saving recording as .mp4")
    }
    
    private func closeCurrentFile(resetStats: Bool) {
        if let file = currentFile {
            do {
                try file.synchronize()
                try file.close()
            } catch {
                addLog("Could not close recording file cleanly: \(error.localizedDescription)")
            }

            currentFile = nil
        }

        if resetStats {
            filesize = 0
            duration = 0
            currentFilename = nil
            currentFileDecodeTimeOffset = nil
        }
    }

    private func normalizeFragmentDecodeTimeIfNeeded(_ data: Data) -> Data {
        guard activeInitSegmentData != nil else {
            return data
        }

        var bytes = [UInt8](data)
        var changed = false
        rewriteTFDTBoxes(
            in: &bytes,
            range: 0..<bytes.count,
            decodeTimeOffset: &currentFileDecodeTimeOffset,
            changed: &changed
        )

        if changed {
            return Data(bytes)
        }
        return data
    }

    private func rewriteTFDTBoxes(in bytes: inout [UInt8], range: Range<Int>, decodeTimeOffset: inout UInt64?, changed: inout Bool) {
        var cursor = range.lowerBound

        while cursor + 8 <= range.upperBound {
            let size32 = readUInt32(bytes, at: cursor)
            if size32 == 0 {
                break
            }

            var boxSize = Int(size32)
            var headerSize = 8

            if size32 == 1 {
                guard cursor + 16 <= range.upperBound else { break }
                let size64 = readUInt64(bytes, at: cursor + 8)
                guard size64 >= 16, size64 <= UInt64(range.upperBound - cursor) else { break }
                boxSize = Int(size64)
                headerSize = 16
            } else {
                guard boxSize >= 8, cursor + boxSize <= range.upperBound else { break }
            }

            let type = String(bytes: bytes[(cursor + 4)..<(cursor + 8)], encoding: .ascii) ?? ""
            let payloadStart = cursor + headerSize
            let payloadEnd = cursor + boxSize

            if type == "tfdt" {
                guard payloadStart + 4 <= payloadEnd else {
                    cursor += boxSize
                    continue
                }

                let version = bytes[payloadStart]
                let valueOffset = payloadStart + 4

                if version == 1 {
                    guard valueOffset + 8 <= payloadEnd else {
                        cursor += boxSize
                        continue
                    }

                    let decodeTime = readUInt64(bytes, at: valueOffset)
                    if decodeTimeOffset == nil {
                        decodeTimeOffset = decodeTime
                    }
                    let adjusted = decodeTime &- (decodeTimeOffset ?? 0)
                    if adjusted != decodeTime {
                        writeUInt64(adjusted, to: &bytes, at: valueOffset)
                        changed = true
                    }
                } else {
                    guard valueOffset + 4 <= payloadEnd else {
                        cursor += boxSize
                        continue
                    }

                    let decodeTime32 = readUInt32(bytes, at: valueOffset)
                    let decodeTime = UInt64(decodeTime32)
                    if decodeTimeOffset == nil {
                        decodeTimeOffset = decodeTime
                    }
                    let adjusted = decodeTime &- (decodeTimeOffset ?? 0)
                    if adjusted <= UInt64(UInt32.max) {
                        let adjusted32 = UInt32(adjusted)
                        if adjusted32 != decodeTime32 {
                            writeUInt32(adjusted32, to: &bytes, at: valueOffset)
                            changed = true
                        }
                    }
                }
            } else if isContainerBox(type), payloadStart < payloadEnd {
                rewriteTFDTBoxes(
                    in: &bytes,
                    range: payloadStart..<payloadEnd,
                    decodeTimeOffset: &decodeTimeOffset,
                    changed: &changed
                )
            }

            cursor += boxSize
        }
    }

    private func isContainerBox(_ type: String) -> Bool {
        switch type {
        case "moov", "moof", "traf", "trak", "mdia", "minf", "stbl", "edts", "dinf", "mvex", "meta", "udta", "mfra", "skip", "ilst":
            return true
        default:
            return false
        }
    }

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        return (UInt64(bytes[offset]) << 56)
            | (UInt64(bytes[offset + 1]) << 48)
            | (UInt64(bytes[offset + 2]) << 40)
            | (UInt64(bytes[offset + 3]) << 32)
            | (UInt64(bytes[offset + 4]) << 24)
            | (UInt64(bytes[offset + 5]) << 16)
            | (UInt64(bytes[offset + 6]) << 8)
            | UInt64(bytes[offset + 7])
    }

    private func writeUInt32(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }

    private func writeUInt64(_ value: UInt64, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((value >> 56) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 48) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 40) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 32) & 0xFF)
        bytes[offset + 4] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 5] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 6] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 7] = UInt8(value & 0xFF)
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
        let preferredExtension = activeInitSegmentData == nil ? "ts" : "mp4"

        if let existing = recordingPreviewTempPath,
           (existing as NSString).pathExtension == preferredExtension {
            return existing
        }

        if let stalePath = recordingPreviewTempPath {
            try? FileManager.default.removeItem(atPath: stalePath)
            recordingPreviewTempPath = nil
        }

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let previewsDir = tempRoot
            .appendingPathComponent("ChaturbateDVR")
            .appendingPathComponent("recording_previews")
        do {
            try FileManager.default.createDirectory(at: previewsDir, withIntermediateDirectories: true)
        } catch {
            logPreviewFailureIfNeeded("Could not create recording preview temp directory: \(error.localizedDescription)")
        }

        let path = previewsDir.appendingPathComponent("\(config.username)_preview.\(preferredExtension)").path
        recordingPreviewTempPath = path
        return path
    }

    private func writeRecordingPreviewTempFileIfNeeded() -> String? {
        guard !recentPreviewSegments.isEmpty else { return nil }

        let path = recordingPreviewTempFilePath()
        let url = URL(fileURLWithPath: path)

        do {
            var merged = Data()
            merged.reserveCapacity(recentPreviewBytes + (activeInitSegmentData?.count ?? 0))

            if let initData = activeInitSegmentData {
                merged.append(initData)
            }

            for chunk in recentPreviewSegments {
                merged.append(chunk.data)
            }
            try merged.write(to: url, options: .atomic)
            return path
        } catch {
            logPreviewFailureIfNeeded("Could not write recording preview temp file: \(error.localizedDescription)")
            return nil
        }
    }

    private func logPreviewFailureIfNeeded(_ message: String) {
        let now = Date()
        guard now.timeIntervalSince(lastPreviewFailureLogAt) >= 30 else { return }
        lastPreviewFailureLogAt = now
        addLog(message)
    }

    private func refreshLiveRecordingThumbnail() async -> ThumbnailGenerationResult {
        if let previewPath = writeRecordingPreviewTempFileIfNeeded() {
            let previewResult = await generateThumbnailDetailed(from: previewPath, analyzeForBreak: true)
            if previewResult.breakDetected {
                return previewResult
            }
            if previewResult.success {
                return previewResult
            }
        }

        guard let filename = currentFilename else {
            return ThumbnailGenerationResult(success: false, breakDetected: false)
        }
        return await generateThumbnailDetailed(from: filename, analyzeForBreak: true)
    }

    private func clearRecordingPreviewState(removeTempFile: Bool) {
        recentPreviewSegments.removeAll(keepingCapacity: false)
        recentPreviewDuration = 0
        recentPreviewBytes = 0
        activeInitSegmentURI = nil
        activeInitSegmentData = nil

        if removeTempFile, let path = recordingPreviewTempPath {
            try? FileManager.default.removeItem(atPath: path)
            recordingPreviewTempPath = nil
        }
    }

    private func refreshActiveInitSegment(mediaPlaylistContent: String, playlistURL: String, httpClient: HTTPClient) async throws {
        guard let initURI = M3U8Parser.parseInitSegmentURI(mediaPlaylistContent), !initURI.isEmpty else {
            activeInitSegmentURI = nil
            activeInitSegmentData = nil
            return
        }

        if activeInitSegmentURI == initURI, activeInitSegmentData != nil {
            return
        }

        let resolvedInitURL = resolveSegmentURL(initURI, playlistURL: playlistURL)
        let initData = try await httpClient.getData(resolvedInitURL)
        activeInitSegmentURI = initURI
        activeInitSegmentData = initData
    }

    private func loadInitSegmentDataIfPresent(mediaPlaylistContent: String, playlistURL: String, httpClient: HTTPClient) async throws -> Data? {
        guard let initURI = M3U8Parser.parseInitSegmentURI(mediaPlaylistContent), !initURI.isEmpty else {
            return nil
        }

        let resolvedInitURL = resolveSegmentURL(initURI, playlistURL: playlistURL)
        return try await httpClient.getData(resolvedInitURL)
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

    private func consumePendingBreakOfflineReason() -> String? {
        let reason = pendingBreakOfflineReason
        pendingBreakOfflineReason = nil
        return reason
    }

    private func resetBreakDetectionState(clearPendingReason: Bool = true) {
        lastBreakAnalysisAt = nil
        lastBreakLumaFrame = nil
        latestPersonDetected = nil
        lastPersonSeenAt = nil
        isNoPersonLikely = false
        noPersonStreakSeconds = 0
        noPersonCarryExpiryAt = nil
        noPersonEvidenceExpiryAt = nil
        activePersonMotionSeconds = 0
        breakEnforced = false
        breakEnforcedAt = nil
        staticFrameStreakSeconds = 0
        noPersonNoMotionStreakSeconds = 0
        if clearPendingReason {
            pendingBreakOfflineReason = nil
        }
    }

    private func preserveNoPersonStateAcrossTransientOffline() {
        lastBreakAnalysisAt = nil
        lastBreakLumaFrame = nil
        pendingBreakOfflineReason = nil

        if noPersonStreakSeconds > 0 || isNoPersonLikely || noPersonNoMotionStreakSeconds > 0 || noPersonEvidenceExpiryAt != nil {
            noPersonCarryExpiryAt = Date().addingTimeInterval(Self.noPersonOfflineCarryWindowSeconds)
        } else {
            noPersonCarryExpiryAt = nil
        }

        if noPersonEvidenceExpiryAt != nil {
            noPersonEvidenceExpiryAt = Date().addingTimeInterval(Self.noPersonOfflineCarryWindowSeconds)
        }
    }

    private func prepareForRecordingAttempt() {
        let now = Date()

        if let carryExpiry = noPersonCarryExpiryAt, now > carryExpiry {
            noPersonStreakSeconds = 0
            noPersonNoMotionStreakSeconds = 0
            isNoPersonLikely = false
            latestPersonDetected = nil
            lastPersonSeenAt = nil
            noPersonEvidenceExpiryAt = nil
            activePersonMotionSeconds = 0
        }

        if let noPersonEvidenceExpiryAt, now > noPersonEvidenceExpiryAt {
            self.noPersonEvidenceExpiryAt = nil
            activePersonMotionSeconds = 0
        }

        noPersonCarryExpiryAt = nil
        lastBreakAnalysisAt = nil
        lastBreakLumaFrame = nil
        pendingBreakOfflineReason = nil
    }

    private func shouldRemainOnBreakBeforeRecording(hlsSource: String) async -> Bool {
        guard breakEnforced else { return false }

        do {
            let checkResult = try await runPreflightFrameAnalysis(hlsSource: hlsSource, purpose: "break_recheck")
            if checkResult.breakDetected {
                return true
            }

            if hasRecoveredFromBreak() {
                clearBreakEnforcement()
                addLog("Break cleared after sustained person+motion recovery")
                return false
            }

            pendingBreakOfflineReason = "Break hold: still waiting for clear person+motion recovery"
            return true
        } catch {
            pendingBreakOfflineReason = "Break hold: recheck failed (\(error.localizedDescription))"
            return true
        }
    }

    private func shouldDelayStartForNoPerson(hlsSource: String) async -> Bool {
        var misses = 0
        let sampleCount = max(Self.recordingStartNoPersonRequiredMisses, Self.recordingStartNoPersonSamples)
        let requiredMisses = max(1, min(sampleCount, Self.recordingStartNoPersonRequiredMisses))
        let sampleDelaySeconds = 2.0

        for index in 0..<sampleCount {
            do {
                // Force each preflight iteration to run a fresh analysis pass.
                lastBreakAnalysisAt = nil
                let checkResult = try await runPreflightFrameAnalysis(
                    hlsSource: hlsSource,
                    purpose: "start_gate_\(index)"
                )

                if checkResult.breakDetected {
                    return true
                }

                let personDetected = latestPersonDetected == true
                if personDetected {
                    return false
                }

                misses += 1
                if misses >= requiredMisses {
                    pendingBreakOfflineReason = "Start gate: no person detected during preflight checks"
                    addLog("Start gate: delaying recording start (no person detected)")
                    noPersonCarryExpiryAt = Date().addingTimeInterval(Self.noPersonOfflineCarryWindowSeconds)
                    return true
                }
            } catch {
                // Fail open on preflight errors to avoid blocking healthy channels due transient fetch issues.
                addLog("Start gate preflight error (\(error.localizedDescription)); not blocking start")
                return false
            }

            if index < sampleCount - 1 {
                try? await Task.sleep(nanoseconds: UInt64(sampleDelaySeconds * 1_000_000_000))
            }
        }

        return false
    }

    private func runPreflightFrameAnalysis(hlsSource: String, purpose: String) async throws -> ThumbnailGenerationResult {
        let playlist = try await withRequestSlot {
            try await client.getPlaylist(
                hlsSource: hlsSource,
                resolution: config.resolution,
                framerate: config.framerate
            )
        }

        let httpClient = HTTPClient(config: appConfig)
        let mediaPlaylistContent = try await withRequestSlot {
            try await httpClient.get(playlist.playlistURL)
        }
        let segments = try M3U8Parser.parseMediaPlaylist(mediaPlaylistContent)

        guard let latestSegment = segments.last else {
            throw ChaturbateError.parsingError("No media segments available for preflight analysis")
        }

        let segmentURL = resolveSegmentURL(latestSegment.uri, playlistURL: playlist.playlistURL)
        let segmentData = try await downloadSegmentWithRetry(httpClient: httpClient, url: segmentURL, maxRetries: 2)

        guard segmentData.count <= Self.pausedPreviewMaxSegmentBytes else {
            throw ChaturbateError.parsingError("Preflight segment too large")
        }

        let tempDir = NSTemporaryDirectory()
        let initData = try await loadInitSegmentDataIfPresent(
            mediaPlaylistContent: mediaPlaylistContent,
            playlistURL: playlist.playlistURL,
            httpClient: httpClient
        )
        let tempExtension = initData == nil ? "ts" : "mp4"
        let tempSegmentPath = (tempDir as NSString).appendingPathComponent("\(config.username)_\(purpose).\(tempExtension)")
        let tempSegmentURL = URL(fileURLWithPath: tempSegmentPath)

        var previewData = Data()
        if let initData {
            previewData.append(initData)
        }
        previewData.append(segmentData)
        try previewData.write(to: tempSegmentURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempSegmentURL) }

        return await generateThumbnailDetailed(from: tempSegmentPath, analyzeForBreak: true)
    }

    private func hasRecoveredFromBreak() -> Bool {
        let noPersonThresholdSeconds = TimeInterval(max(1, min(60, appConfig.breakNoPersonNoMotionThresholdMinutes))) * 60
        let requiredMotionSeconds = max(30.0, min(180.0, noPersonThresholdSeconds / 2.0))

        let hasPerson = latestPersonDetected == true
        let hasMotion = activePersonMotionSeconds >= requiredMotionSeconds
        let notStatic = staticFrameStreakSeconds == 0

        return hasPerson && hasMotion && notStatic
    }

    private func clearBreakEnforcement() {
        breakEnforced = false
        breakEnforcedAt = nil
        noPersonEvidenceExpiryAt = nil
        noPersonNoMotionStreakSeconds = 0
        noPersonStreakSeconds = 0
        isNoPersonLikely = false
        noPersonCarryExpiryAt = nil
        pendingBreakOfflineReason = nil
    }

    private func evaluateBreakSignalIfNeeded(frameImage: CGImage) -> Bool {
        let analysisIntervalSeconds = TimeInterval(max(5, min(60, appConfig.breakAnalysisIntervalSeconds)))
        let staticThresholdSeconds = TimeInterval(max(1, min(180, appConfig.breakStaticThresholdMinutes))) * 60
        let noPersonThresholdSeconds = TimeInterval(max(1, min(60, appConfig.breakNoPersonNoMotionThresholdMinutes))) * 60
        let noPersonBadgeThresholdSeconds = min(90.0, max(20.0, noPersonThresholdSeconds / 3.0))
        let sustainedNoPersonEvidenceThresholdSeconds = min(noPersonThresholdSeconds, max(120.0, noPersonBadgeThresholdSeconds * 2.0))
        let personDetectionGraceSeconds = max(30.0, analysisIntervalSeconds * 6.0)

        let now = Date()
        if let carryExpiry = noPersonCarryExpiryAt, now > carryExpiry {
            noPersonStreakSeconds = 0
            noPersonNoMotionStreakSeconds = 0
            isNoPersonLikely = false
            latestPersonDetected = nil
            lastPersonSeenAt = nil
            noPersonEvidenceExpiryAt = nil
            activePersonMotionSeconds = 0
            noPersonCarryExpiryAt = nil
        }

        if let noPersonEvidenceExpiryAt, now > noPersonEvidenceExpiryAt {
            self.noPersonEvidenceExpiryAt = nil
            activePersonMotionSeconds = 0
        }

        if let last = lastBreakAnalysisAt,
           now.timeIntervalSince(last) < analysisIntervalSeconds {
            return false
        }

        let elapsed = max(
            analysisIntervalSeconds,
            lastBreakAnalysisAt.map { now.timeIntervalSince($0) } ?? analysisIntervalSeconds
        )
        lastBreakAnalysisAt = now

        guard let currentLuma = lumaFrame(from: frameImage, size: Self.breakAnalysisImageSize) else {
            resetBreakDetectionState()
            return false
        }

        let motionScore: Double?
        if let previousLuma = lastBreakLumaFrame, previousLuma.count == currentLuma.count {
            motionScore = meanAbsoluteDifference(previousLuma, currentLuma)
        } else {
            motionScore = nil
        }
        lastBreakLumaFrame = currentLuma

        let hasPerson = detectHumanPresence(in: frameImage)
        if hasPerson {
            latestPersonDetected = true
            lastPersonSeenAt = now
        } else if let lastSeenAt = lastPersonSeenAt,
                  now.timeIntervalSince(lastSeenAt) <= personDetectionGraceSeconds {
            latestPersonDetected = true
        } else {
            latestPersonDetected = false
        }
        let effectivePersonDetected = latestPersonDetected ?? hasPerson
        let isStaticFrame = (motionScore ?? 1.0) <= Self.breakStaticMotionThreshold
        let isLowMotion = (motionScore ?? 1.0) <= Self.breakLowMotionThreshold

        if !effectivePersonDetected {
            noPersonStreakSeconds += elapsed
        } else {
            noPersonStreakSeconds = 0
        }

        if motionScore != nil, isStaticFrame {
            staticFrameStreakSeconds += elapsed
        } else {
            staticFrameStreakSeconds = 0
        }

        if motionScore != nil, !effectivePersonDetected, isLowMotion {
            noPersonNoMotionStreakSeconds += elapsed
        } else {
            noPersonNoMotionStreakSeconds = 0
        }
        isNoPersonLikely = noPersonNoMotionStreakSeconds >= noPersonBadgeThresholdSeconds

        if noPersonNoMotionStreakSeconds >= sustainedNoPersonEvidenceThresholdSeconds {
            noPersonEvidenceExpiryAt = now.addingTimeInterval(Self.noPersonOfflineCarryWindowSeconds)
        }

        if effectivePersonDetected && !isLowMotion {
            activePersonMotionSeconds += elapsed
        } else {
            activePersonMotionSeconds = 0
        }

        if activePersonMotionSeconds >= 120 {
            noPersonEvidenceExpiryAt = nil
        }

        let hasSustainedNoPersonEvidence = noPersonEvidenceExpiryAt.map { now <= $0 } ?? false

        if hasSustainedNoPersonEvidence,
           staticFrameStreakSeconds >= Self.noPersonThenStaticConfirmSeconds {
            breakEnforced = true
            breakEnforcedAt = now
            pendingBreakOfflineReason = "Break detection: sustained no-person period followed by confirmed static image"
            addLog(pendingBreakOfflineReason ?? "Break detection: no-person + static image")
            return true
        }

        if staticFrameStreakSeconds >= staticThresholdSeconds {
            breakEnforced = true
            breakEnforcedAt = now
            pendingBreakOfflineReason = "Break detection: stream has looked static for \(Int(staticFrameStreakSeconds))s"
            addLog(pendingBreakOfflineReason ?? "Break detection: static stream")
            return true
        }

        if noPersonNoMotionStreakSeconds >= noPersonThresholdSeconds {
            breakEnforced = true
            breakEnforcedAt = now
            pendingBreakOfflineReason = "Break detection: no person + minimal motion for \(Int(noPersonNoMotionStreakSeconds))s"
            addLog(pendingBreakOfflineReason ?? "Break detection: no person + no motion")
            return true
        }

        return false
    }

    private func lumaFrame(from image: CGImage, size: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: size * size)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pixels
    }

    private func meanAbsoluteDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 1.0 }

        var totalDifference: Int = 0
        for index in lhs.indices {
            totalDifference += abs(Int(lhs[index]) - Int(rhs[index]))
        }

        return Double(totalDifference) / Double(lhs.count * 255)
    }

    private func detectHumanPresence(in image: CGImage) -> Bool {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let bodyRequest = VNDetectHumanRectanglesRequest()
        bodyRequest.upperBodyOnly = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([faceRequest, bodyRequest])
            let hasFace = !(faceRequest.results?.isEmpty ?? true)
            let hasBody = !(bodyRequest.results?.isEmpty ?? true)
            return hasFace || hasBody
        } catch {
            // Fail open to avoid false positives if Vision cannot analyze the frame.
            return true
        }
    }
    
    private func generateThumbnail(from videoPath: String) async -> Bool {
        let result = await generateThumbnailDetailed(from: videoPath, analyzeForBreak: false)
        return result.success
    }

    private func generateThumbnailDetailed(from videoPath: String, analyzeForBreak: Bool) async -> ThumbnailGenerationResult {
        guard FileManager.default.fileExists(atPath: videoPath) else {
            return ThumbnailGenerationResult(success: false, breakDetected: false)
        }
        
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
            let breakDetected = analyzeForBreak ? evaluateBreakSignalIfNeeded(frameImage: cgImage) : false
            
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
                return ThumbnailGenerationResult(success: true, breakDetected: breakDetected)
            }
            return ThumbnailGenerationResult(success: false, breakDetected: breakDetected)
        } catch {
            // Silently fail on most errors - thumbnails are nice-to-have
            addLog("Thumbnail generation failed: \(error.localizedDescription)")
            return ThumbnailGenerationResult(success: false, breakDetected: false)
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
