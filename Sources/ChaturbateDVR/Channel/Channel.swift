import Foundation
import AVFoundation
import AppKit
import Vision

private actor MP4Finalizer {
    private static let minDurationRetentionRatio: Double = 0.90
    private static let minFileSizeRetentionRatio: Double = 0.70

    enum RepairOutcome: Equatable, Sendable {
        case succeeded
        case skipped(String)
    }

    private struct MediaMetrics {
        let durationSeconds: Double?
        let sizeBytes: Int64
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private var inFlightPaths: Set<String> = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func enqueue(
        sourcePath: String,
        audioSourcePath: String? = nil,
        destinationPath: String,
        channel: String,
        onCompletion: (@Sendable (RepairOutcome) -> Void)? = nil
    ) {
        guard inFlightPaths.insert(sourcePath).inserted else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let outcome = await self.finalize(
                sourcePath: sourcePath,
                audioSourcePath: audioSourcePath,
                destinationPath: destinationPath,
                channel: channel
            )
            onCompletion?(outcome)
        }
    }

    func repair(path: String, channel: String) async -> RepairOutcome {
        guard inFlightPaths.insert(path).inserted else {
            return .skipped("repair already in progress")
        }

        return await finalize(sourcePath: path, destinationPath: path, channel: channel)
    }

    private func finalize(sourcePath: String, audioSourcePath: String? = nil, destinationPath: String, channel: String) async -> RepairOutcome {
        defer {
            inFlightPaths.remove(sourcePath)
            if inFlightPaths.isEmpty, !idleWaiters.isEmpty {
                let waiters = idleWaiters
                idleWaiters.removeAll(keepingCapacity: false)
                for waiter in waiters {
                    waiter.resume(returning: ())
                }
            }
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let audioSourceURL = audioSourcePath.map { URL(fileURLWithPath: $0) }
        let destinationURL = URL(fileURLWithPath: destinationPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return .skipped("source file missing")
        }

        let hasAudioSidecar = {
            guard let audioSourceURL else { return false }
            return FileManager.default.fileExists(atPath: audioSourceURL.path)
        }()

        let tempURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(sourceURL.deletingPathExtension().lastPathComponent)_finalizing_\(UUID().uuidString).mp4")

        do {
            let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
            let sourceMetrics = try await loadMediaMetrics(for: sourceURL)
            try await exportPassthrough(
                sourceURL: sourceURL,
                audioSourceURL: hasAudioSidecar ? audioSourceURL : nil,
                destinationURL: tempURL
            )
            let exportedMetrics = try await loadMediaMetrics(for: tempURL)
            try validateExport(source: sourceMetrics, exported: exportedMetrics)

            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try FileManager.default.removeItem(at: sourceURL)
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)

            var preservedAttributes: [FileAttributeKey: Any] = [:]
            if let createdAt = sourceAttributes?[.creationDate] {
                preservedAttributes[.creationDate] = createdAt
            }
            if let modifiedAt = sourceAttributes?[.modificationDate] {
                preservedAttributes[.modificationDate] = modifiedAt
            }
            if !preservedAttributes.isEmpty {
                try? FileManager.default.setAttributes(preservedAttributes, ofItemAtPath: destinationURL.path)
            }

            if hasAudioSidecar, let audioSourceURL {
                try? FileManager.default.removeItem(at: audioSourceURL)
            }

            await FileLogger.shared.log("[recording] finalized mp4 for fast open/seek (duration \(formatSeconds(exportedMetrics.durationSeconds)) size \(exportedMetrics.sizeBytes) bytes)", channel: channel)
            return .succeeded
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            await FileLogger.shared.log("[recording] mp4 finalization skipped: \(error.localizedDescription)", channel: channel, level: "WARN")
            return .skipped(error.localizedDescription)
        }
    }

    private func exportPassthrough(sourceURL: URL, audioSourceURL: URL? = nil, destinationURL: URL) async throws {
        if let ffmpegPath = resolveFFMPEGPath() {
            try remuxWithFFMPEG(
                ffmpegPath: ffmpegPath,
                sourceURL: sourceURL,
                audioSourceURL: audioSourceURL,
                destinationURL: destinationURL
            )
            return
        }

        if audioSourceURL != nil {
            throw ChaturbateError.fileError("ffmpeg is required to mux split audio for fragmented MP4 recordings")
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ChaturbateError.fileError("Could not create export session")
        }

        export.shouldOptimizeForNetworkUse = true
        try await export.export(to: destinationURL, as: .mp4)
    }

    private func remuxWithFFMPEG(ffmpegPath: String, sourceURL: URL, audioSourceURL: URL? = nil, destinationURL: URL) throws {
        var arguments: [String] = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", sourceURL.path,
        ]

        if let audioSourceURL {
            arguments += [
                "-i", audioSourceURL.path,
                "-map", "0:v:0",
                "-map", "1:a:0?",
                "-c", "copy",
                "-shortest",
                "-movflags", "+faststart",
                destinationURL.path,
            ]
        } else {
            arguments += [
                "-map", "0",
                "-c", "copy",
                "-movflags", "+faststart",
                destinationURL.path,
            ]
        }

        let result = runProcess(executablePath: ffmpegPath, arguments: arguments)

        guard result.status == 0 else {
            let details = result.stderr.isEmpty ? result.stdout : result.stderr
            let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw ChaturbateError.fileError("ffmpeg remux failed with status \(result.status)")
            }
            throw ChaturbateError.fileError("ffmpeg remux failed: \(trimmed)")
        }
    }

    private func loadMediaMetrics(for fileURL: URL) async throws -> MediaMetrics {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        let asset = AVURLAsset(url: fileURL)
        let durationTime = try await asset.load(.duration)
        let rawDuration = CMTimeGetSeconds(durationTime)
        let duration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : nil

        return MediaMetrics(durationSeconds: duration, sizeBytes: size)
    }

    private func validateExport(source: MediaMetrics, exported: MediaMetrics) throws {
        guard exported.sizeBytes > 0 else {
            throw ChaturbateError.fileError("Finalized file is empty")
        }

        let durationRatio: Double? = {
            guard let sourceDuration = source.durationSeconds,
                  let exportedDuration = exported.durationSeconds,
                  sourceDuration > 0 else {
                return nil
            }
            return exportedDuration / sourceDuration
        }()

        // If the finalized file preserves the playable duration, prefer it even
        // when the container shrinks dramatically. Some fragmented originals are
        // heavily bloated yet still export cleanly to a much smaller MP4.
        if let durationRatio, durationRatio >= Self.minDurationRetentionRatio {
            return
        }

        if source.sizeBytes > 0 {
            let sizeRatio = Double(exported.sizeBytes) / Double(source.sizeBytes)
            if sizeRatio < Self.minFileSizeRetentionRatio {
                throw ChaturbateError.fileError("Finalized file too small (\(formatRatio(sizeRatio)); keeping original)")
            }
        }

        if let durationRatio {
            if durationRatio < Self.minDurationRetentionRatio {
                throw ChaturbateError.fileError("Finalized duration too short (\(formatRatio(durationRatio)); keeping original)")
            }
        }
    }

    private func formatSeconds(_ seconds: Double?) -> String {
        guard let seconds else { return "unknown" }
        return String(format: "%.2fs", seconds)
    }

    private func formatRatio(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }

    private func resolveFFMPEGPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runProcess(executablePath: String, arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            return ProcessResult(
                status: process.terminationStatus,
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self)
            )
        } catch {
            return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
    }

    func waitUntilIdle() async {
        if inFlightPaths.isEmpty {
            return
        }

        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }
}

actor Channel {
    private enum IngestContainerMode {
        case unknown
        case transportStream
        case fragmentedMP4
    }

    enum OfflineThumbnailBackfillResult: Sendable {
        case skipped
        case noVideoCandidate
        case generated
        case generationFailed
    }

    private static let pausedPreviewMinInterval: TimeInterval = 90
    private static let pausedOnlineStickyDuration: TimeInterval = 60
    private static let degradedRecoveryWindowSeconds: TimeInterval = 60
    private static let pausedPreviewMaxSegmentBytes = 6 * 1024 * 1024
    private static let pausedPreviewFallbackMaxSegmentBytes = 24 * 1024 * 1024
    private static let recordingPreviewWindowSeconds: TimeInterval = 30
    private static let recordingPreviewMaxBytes = 12 * 1024 * 1024
    private static let waitingStatusCheckIntervalSeconds: TimeInterval = 30
    private static let waitingPreviewMinInterval: TimeInterval = 120
    private static let waitingOfflineConfirmAttempts: Int = 2
    private static let breakStaticMotionThreshold: Double = 0.003
    private static let breakLowMotionThreshold: Double = 0.015
    private static let breakAnalysisImageSize: Int = 64
    private static let noPersonOfflineCarryWindowSeconds: TimeInterval = 600
    private static let noPersonThenStaticConfirmSeconds: TimeInterval = 45
    private static let recordingStartNoPersonSamples: Int = 3
    private static let recordingStartNoPersonRequiredMisses: Int = 3
    private static let mp4Finalizer = MP4Finalizer()
    private static let segmentTimelineMismatchMinClaimedSeconds: Double = 120
    private static let segmentTimelineMismatchMaxRatio: Double = 2.0
    private static let segmentTimelineMismatchRequiredEvents: Int = 3
    private static let fmp4ForwardDecodeJumpThresholdSeconds: Double = 20

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
    private(set) var sessionDurationSeconds: TimeInterval = 0 // seconds since session started
    private(set) var sessionFilesizeBytes: Int = 0 // bytes written in current online session
    private(set) var isPausedBySessionLimit: Bool = false
    private(set) var logs: [String] = []
    private(set) var currentFilename: String?
    private(set) var pendingFilenameBase: String?
    private(set) var thumbnailPath: String?
    private(set) var liveStreamURL: String?
    private(set) var isChecking: Bool = false
    private(set) var isWaitingForRecordingSlot: Bool = false
    private(set) var isInvalid: Bool
    
    private var currentFile: FileHandle?
    private var currentWorkingFilename: String?
    private var monitoringTask: Task<Void, Never>?
    private var waitingForSlotStatusTask: Task<Void, Never>?
    private var client: ChaturbateClient
    private var appConfig: AppConfig
    private var lastThumbnailTime: Date = Date.distantPast
    private var lastPausedPreviewTime: Date = Date.distantPast
    private var lastWaitingPreviewTime: Date = Date.distantPast
    private var isRefreshingPausedPreview: Bool = false
    private var isRefreshingWaitingPreview: Bool = false
    private var waitingOfflineProbeFailures: Int = 0
    private var playbackOfflineProbeFailures: Int = 0
    private var pausedOnlineStickyUntil: Date?
    private var recentPreviewSegments: [PreviewSegmentChunk] = []
    private var recentPreviewDuration: Double = 0
    private var recentPreviewBytes: Int = 0
    private var recordingPreviewTempPath: String?
    private var activeInitSegmentURI: String?
    private var activeInitSegmentData: Data?
    private var activeAudioPlaylistURL: String?
    private var activeAudioInitSegmentURI: String?
    private var activeAudioInitSegmentData: Data?
    private var activeFragmentTimescale: UInt32?
    private var ingestContainerMode: IngestContainerMode = .unknown
    private var currentFileDecodeTimeOffset: UInt64?
    private var currentAudioFile: FileHandle?
    private var currentAudioWorkingFilename: String?
    private var currentAudioFilesize: Int = 0
    private var previousRawSegmentDecodeStartTime: UInt64?
    private var previousSegmentDecodeStartTime: UInt64?
    private var cumulativeClaimedSegmentDuration: Double = 0
    private var cumulativeObservedSegmentDuration: Double = 0
    private var segmentTimelineMismatchEvents: Int = 0
    private var pendingTimestampDiscontinuity: Bool = false
    private var sessionStartedAt: Date? // tracks session start for session duration limits
    private var lastPreviewFailureLogAt: Date = Date.distantPast
    private var cloudflareBlockCount: Int = 0
    private var segmentRetryCount: Int = 0
    private var consecutiveSegmentFailures: Int = 0
    private var lastSegmentFailureAt: Date?
    private var timelineMismatchCount: Int = 0
    private var lastTimelineMismatchAt: Date?
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
    private let recordingLedger: RecordingLedger
    private var activeRecordingID: Int64?
    private var activeRecordingStartedAt: Date?
    private var activeRecordingFirstPersonDetectedAt: Date?
    private var lastRecordingProgressPersistAt: Date = .distantPast
    private var isFirstCheck: Bool = true
    private var isInGlobalRecordingPauseMode: Bool = false
    
    init(
        config: ChannelConfig,
        appConfig: AppConfig,
        requestCoordinator: RequestCoordinator,
        recordingCoordinator: RecordingCoordinator,
        recordingLedger: RecordingLedger
    ) {
        self.config = config
        self.appConfig = appConfig
        self.client = ChaturbateClient(config: appConfig)
        self.requestCoordinator = requestCoordinator
        self.recordingCoordinator = recordingCoordinator
        self.recordingLedger = recordingLedger
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
        isPausedBySessionLimit = false
        pausedOnlineStickyUntil = wasOnline ? Date().addingTimeInterval(Self.pausedOnlineStickyDuration) : nil
        resetBreakDetectionState()
        clearDegradedState()
        monitoringTask?.cancel()
        monitoringTask = nil
        endWaitingForSlotMonitoring()
        closeCurrentFile(resetStats: true)
        clearRecordingPreviewState(removeTempFile: true)
        if wasOnline {
            addLog("Channel paused (kept as paused-online for up to 1 minute)")
        } else {
            addLog("Channel paused")
        }
    }
    
    func pauseForSessionLimit(reason: String) {
        let wasOnline = isOnline
        config.isPaused = true
        isPausedBySessionLimit = true
        pausedOnlineStickyUntil = wasOnline ? Date().addingTimeInterval(Self.pausedOnlineStickyDuration) : nil
        resetBreakDetectionState()
        clearDegradedState()
        monitoringTask?.cancel()
        monitoringTask = nil
        endWaitingForSlotMonitoring()
        closeCurrentFile(resetStats: true)
        clearRecordingPreviewState(removeTempFile: true)
        addLog("Session limit reached (\(reason)). Channel paused until it goes offline and comes back for a new session.")
    }
    
    func resume() {
        config.isPaused = false
        isPausedBySessionLimit = false
        pausedOnlineStickyUntil = nil
        sessionDurationSeconds = 0
        sessionFilesizeBytes = 0
        sessionStartedAt = nil
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
        endWaitingForSlotMonitoring()
        isOnline = false
        closeCurrentFile(resetStats: true)
        clearRecordingPreviewState(removeTempFile: true)
        cleanupThumbnail()
        addLog("Channel deleted")
    }

    func shutdownForTermination() {
        config.isPaused = true
        pausedOnlineStickyUntil = nil
        resetBreakDetectionState()
        monitoringTask?.cancel()
        monitoringTask = nil
        endWaitingForSlotMonitoring()
        isOnline = false
        closeCurrentFile(resetStats: true)
        clearRecordingPreviewState(removeTempFile: true)
    }

    static func waitForMP4FinalizationToComplete() async {
        await Task.yield()
        await mp4Finalizer.waitUntilIdle()
    }

    static func enqueueExistingMP4Repair(path: String, channel: String) async {
        await mp4Finalizer.enqueue(sourcePath: path, destinationPath: path, channel: channel)
    }

    static func repairExistingMP4(path: String, channel: String) async -> String? {
        let outcome = await mp4Finalizer.repair(path: path, channel: channel)
        switch outcome {
        case .succeeded:
            return nil
        case .skipped(let reason):
            return reason
        }
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
        config.maxSessionDuration = newConfig.maxSessionDuration
        config.maxSessionFilesize = newConfig.maxSessionFilesize
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
        let effectiveWaitingForSlot = isWaitingForRecordingSlot && appConfig.recordingEnabled && !config.isPaused
        
        return ChannelInfo(
            isOnline: isOnline,
            isPaused: config.isPaused,
            isPausedBySessionLimit: isPausedBySessionLimit,
            isActivelyRecording: currentFile != nil || activeRecordingID != nil,
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
            liveStreamURL: isOnline ? liveStreamURL : nil,
            isChecking: isChecking,
            isWaitingForRecordingSlot: effectiveWaitingForSlot,
            isInvalid: isInvalid,
            cloudflareBlockCount: cloudflareBlockCount,
            isPersonDetected: latestPersonDetected,
            isNoPersonDetected: isNoPersonLikely,
            noPersonDurationSeconds: max(0, Int(noPersonStreakSeconds.rounded())),
            segmentRetryCount: segmentRetryCount,
            consecutiveSegmentFailures: consecutiveSegmentFailures,
            lastSegmentFailureAt: lastSegmentFailureAt.map { formatter.string(from: $0) },
            timelineMismatchCount: timelineMismatchCount,
            lastTimelineMismatchAt: lastTimelineMismatchAt.map { formatter.string(from: $0) },
            bioMetadata: config.bioMetadata,
            globalRecordingEnabled: appConfig.recordingEnabled
        )
    }

    func backfillOfflineThumbnailIfNeeded() async -> OfflineThumbnailBackfillResult {
        // Only skip if we already have a successful thumbnail
        guard thumbnailPath == nil,
                            !isOnline else {
            return .skipped
        }

        // Keep retrying until successful; don't give up after first failure
        return await generateThumbnailFromExistingVideoIfNeeded()
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
            liveStreamURL = stream.hlsSource
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
                case .authenticationRequired:
                    addLog("Background check: authentication required (session expired)")
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

    func refreshLiveStreamURLForPlayback() async -> String? {
        guard isOnline else {
            liveStreamURL = nil
            return nil
        }

        do {
            let stream = try await withRequestSlot {
                try await client.getStream(username: config.username)
            }
            playbackOfflineProbeFailures = 0
            liveStreamURL = stream.hlsSource
            markChannelValid()
            return stream.hlsSource
        } catch {
            if let cbError = error as? ChaturbateError {
                switch cbError {
                case .channelOffline, .privateStream, .authenticationRequired:
                    playbackOfflineProbeFailures += 1
                    // Two consecutive offline/private probes are treated as a real
                    // offline transition. Keep the last known URL for a single
                    // transient misclassification while playback is active.
                    if playbackOfflineProbeFailures >= 2 {
                        liveStreamURL = nil
                        markOfflineAndClearDegradedState()
                        return nil
                    }
                    return liveStreamURL
                case .invalidChannel:
                    markChannelInvalid()
                    liveStreamURL = nil
                    return nil
                default:
                    break
                }
            }
            return liveStreamURL
        }
    }

    func refreshStatusForDetailView(refreshPausedThumbnail: Bool = false) async {
        // Avoid competing probes while a check is already in progress.
        guard !isChecking else { return }

        // If actively recording, the recorder loop already provides fresh state.
        if currentFile != nil && !config.isPaused {
            return
        }

        isChecking = true
        defer { isChecking = false }

        do {
            let stream = try await withRequestSlot {
                try await client.getStream(username: config.username)
            }

            playbackOfflineProbeFailures = 0
            liveStreamURL = stream.hlsSource
            markChannelValid()
            isOnline = true
            markLastOnlineNow()

            if refreshPausedThumbnail {
                await updatePausedChannelThumbnailIfNeeded(hlsSource: stream.hlsSource)
            }
        } catch {
            if let cbError = error as? ChaturbateError {
                switch cbError {
                case .channelOffline, .privateStream, .authenticationRequired:
                    playbackOfflineProbeFailures += 1

                    // Confirm with two probes before forcing offline if we were
                    // online. Keep the last known URL during the first transient
                    // failure to reduce open-channel flapping.
                    if playbackOfflineProbeFailures >= 2 || !isOnline {
                        liveStreamURL = nil
                        markOfflineAndClearDegradedState()
                    }
                case .invalidChannel:
                    markChannelInvalid()
                    liveStreamURL = nil
                    markOfflineAndClearDegradedState()
                default:
                    break
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
            let recentSegments = Array(segments.suffix(4)).reversed()
            guard !recentSegments.isEmpty else { return }

            var selectedSegmentData: Data?
            var selectedSegmentSize = 0
            var selectedOversizedFallback = false
            var smallestOversizedData: Data?
            var smallestOversizedSize = Int.max

            for segment in recentSegments {
                let segmentURL = resolveSegmentURL(segment.uri, playlistURL: playlist.playlistURL)
                let segmentData = try await downloadSegmentWithRetry(
                    httpClient: httpClient,
                    url: segmentURL,
                    maxRetries: 2,
                    allowPaused: true,
                    updateStreamHealth: false
                )
                let segmentSize = segmentData.count

                if segmentSize <= Self.pausedPreviewMaxSegmentBytes {
                    selectedSegmentData = segmentData
                    selectedSegmentSize = segmentSize
                    selectedOversizedFallback = false
                    break
                }

                if segmentSize <= Self.pausedPreviewFallbackMaxSegmentBytes,
                   segmentSize < smallestOversizedSize {
                    smallestOversizedData = segmentData
                    smallestOversizedSize = segmentSize
                }
            }

            if selectedSegmentData == nil, let fallback = smallestOversizedData {
                selectedSegmentData = fallback
                selectedSegmentSize = smallestOversizedSize
                selectedOversizedFallback = true
            }

            guard let segmentData = selectedSegmentData else {
                addLog("Live preview segment too large to thumbnail (all recent segments exceeded \(formatFilesize(Self.pausedPreviewFallbackMaxSegmentBytes)))")
                return
            }

            if selectedOversizedFallback {
                addLog("Using larger live preview segment for thumbnail fallback (\(formatFilesize(selectedSegmentSize)))")
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
            guard !shouldSuppressBestEffortThumbnailFailure(error) else {
                return
            }
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
            if !appConfig.recordingEnabled && !config.isPaused {
                if !isInGlobalRecordingPauseMode {
                    isInGlobalRecordingPauseMode = true
                    addLog("Recording is globally paused; switching to low-volume status checks")
                }
                await runLowVolumeStatusCheckWhileRecordingPaused()
                continue
            }

            if isInGlobalRecordingPauseMode {
                isInGlobalRecordingPauseMode = false
                addLog("Recording re-enabled; resuming normal monitoring")
            }

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
                        if breakReason != nil {
                            // Retry sooner for break-gated holds so recovery is detected quickly.
                            waitTime = min(waitTime, 45)
                        }
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
                    case .authenticationRequired:
                        markOfflineAndClearDegradedState()
                        waitTime = max(waitTime, 5 * 60)
                        addLog("Authentication required (session expired). Re-login in Settings. Retrying in \(formatWaitTime(waitTime))")
                        cloudflareBlockCount = 0
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

    private func runLowVolumeStatusCheckWhileRecordingPaused() async {
        // Keep request activity low while still surfacing online/offline transitions.
        let waitTimeSeconds = max(appConfig.interval * 60, 180)
        let wasOnline = isOnline

        endWaitingForSlotMonitoring()
        isChecking = true

        do {
            let stream = try await withRequestSlot {
                try await client.getStream(username: config.username)
            }
            liveStreamURL = stream.hlsSource
            markChannelValid()
            isOnline = true
            markLastOnlineNow()

            if !wasOnline {
                addLog("Channel is online (recording remains globally paused)")
            }

            cloudflareBlockCount = 0
        } catch {
            if let cbError = error as? ChaturbateError {
                switch cbError {
                case .invalidChannel:
                    markChannelInvalid()
                case .channelOffline, .privateStream, .authenticationRequired:
                    markOfflineAndClearDegradedState()
                case .cloudflareBlocked:
                    cloudflareBlockCount += 1
                default:
                    break
                }
            } else {
                markOfflineAndClearDegradedState()
            }

            if wasOnline && !isOnline {
                addLog("Channel went offline during global recording pause")
            }
        }

        isChecking = false
        let jitter = Double.random(in: 0.9...1.1)
        let adjustedWait = UInt64(Double(waitTimeSeconds) * jitter * 1_000_000_000)

        // While globally paused, we still poll slowly, but wake quickly when
        // recording is re-enabled so channels can resume without multi-minute lag.
        let sleepChunk: UInt64 = 5_000_000_000
        var elapsed: UInt64 = 0
        while elapsed < adjustedWait && !Task.isCancelled {
            if appConfig.recordingEnabled {
                break
            }
            let duration = min(sleepChunk, adjustedWait - elapsed)
            try? await Task.sleep(nanoseconds: duration)
            elapsed += duration
        }
    }
    
    private func recordStream() async throws {
        isChecking = true
        prepareForRecordingAttempt()

        let stream = try await withRequestSlot {
            try await client.getStream(username: config.username)
        }
        liveStreamURL = stream.hlsSource
        markChannelValid()

        if await shouldRemainOnBreakBeforeRecording(hlsSource: stream.hlsSource) {
            throw ChaturbateError.channelOffline
        }

        if await shouldDelayStartForNoPerson(hlsSource: stream.hlsSource) {
            throw ChaturbateError.channelOffline
        }
        
        // Check is complete, now we're in recording mode
        isChecking = false

        var activeHlsSource = stream.hlsSource
        var setupAttempt = 0

        while true {
            setupAttempt += 1
            do {
                beginWaitingForSlotMonitoring(initialHlsSource: activeHlsSource)

                try await withRecordingSlot {
                    // Refresh stream setup after slot acquisition so we do not
                    // start from stale waiting-time metadata.
                    let refreshedStream = try await withRequestSlot {
                        try await client.getStream(username: config.username)
                    }
                    activeHlsSource = refreshedStream.hlsSource
                    liveStreamURL = refreshedStream.hlsSource

                    let playlist = try await withRequestSlot {
                        try await client.getPlaylist(
                            hlsSource: activeHlsSource,
                            resolution: config.resolution,
                            framerate: config.framerate
                        )
                    }
                    activeAudioPlaylistURL = playlist.audioPlaylistURL

                    endWaitingForSlotMonitoring()

                    streamedAt = Date()
                    sessionStartedAt = Date()
                    sessionDurationSeconds = 0
                    sessionFilesizeBytes = 0
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
                    let codecsSummary = playlist.codecs ?? "unknown"
                    let audioSummary = playlist.audioLikelyPresent ? "audio signaled" : "audio not signaled"
                    addLog("Stream quality - resolution \(playlist.resolution)p (target: \(config.resolution)p), framerate \(playlist.framerate)fps (target: \(config.framerate)fps), codecs \(codecsSummary), \(audioSummary)")
                    if playlist.audioPlaylistURL != nil {
                        addLog("Split audio playlist detected; recording audio sidecar for final MP4 mux")
                    }
                    if !playlist.audioLikelyPresent {
                        addLog("Selected variant appears video-only; recording may have no audio track")
                    }

                    try await watchSegments(playlist: playlist)
                }

                endWaitingForSlotMonitoring()
                return
            } catch let cbError as ChaturbateError {
                let isRetryableSetupError: Bool
                switch cbError {
                case .privateStream, .channelOffline:
                    isRetryableSetupError = true
                default:
                    isRetryableSetupError = false
                }

                if isRetryableSetupError, setupAttempt < 2, !config.isPaused {
                    addLog("Stream setup returned offline/private, refreshing stream source and retrying once")
                    let refreshed = try await withRequestSlot {
                        try await client.getStream(username: config.username)
                    }
                    activeHlsSource = refreshed.hlsSource
                    liveStreamURL = refreshed.hlsSource
                    markChannelValid()
                    isOnline = true
                    markLastOnlineNow()
                    continue
                }

                endWaitingForSlotMonitoring()
                throw cbError
            } catch {
                endWaitingForSlotMonitoring()
                throw error
            }
        }
    }

    private func beginWaitingForSlotMonitoring(initialHlsSource: String) {
        waitingForSlotStatusTask?.cancel()
        isWaitingForRecordingSlot = true
        waitingOfflineProbeFailures = 0
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
        waitingOfflineProbeFailures = 0
        Task { [recordingCoordinator, username = config.username] in
            await recordingCoordinator.cancelPendingSlotRequest(for: username)
        }
    }

    // Returns an updated HLS source when stream probing succeeds.
    private func probeWaitingStreamStatus() async -> String? {
        guard isWaitingForRecordingSlot, !config.isPaused else { return nil }

        isChecking = true
        do {
            let wasOnline = isOnline
            let stream = try await withRequestSlot {
                try await client.getStream(username: config.username)
            }
            liveStreamURL = stream.hlsSource
            isChecking = false
            waitingOfflineProbeFailures = 0
            markChannelValid()
            isOnline = true
            if !wasOnline {
                markLastOnlineNow()
            }
            return stream.hlsSource
        } catch {
            isChecking = false

            if let cbError = error as? ChaturbateError {
                switch cbError {
                case .invalidChannel:
                    markChannelInvalid()
                    endWaitingForSlotMonitoring()
                    addLog("Waiting for slot: channel returned 404 (marked invalid)")
                case .channelOffline, .privateStream, .authenticationRequired:
                    waitingOfflineProbeFailures += 1
                    if waitingOfflineProbeFailures >= Self.waitingOfflineConfirmAttempts {
                        endWaitingForSlotMonitoring()
                        markOfflineAndClearDegradedState()
                    }
                default:
                    // Keep previous online state for transient failures.
                    waitingOfflineProbeFailures = 0
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
            let recentSegments = Array(segments.suffix(4)).reversed()
            guard !recentSegments.isEmpty else { return }

            var selectedSegmentData: Data?
            var selectedSegmentSize = 0
            var selectedOversizedFallback = false
            var smallestOversizedData: Data?
            var smallestOversizedSize = Int.max

            for segment in recentSegments {
                let segmentURL = resolveSegmentURL(segment.uri, playlistURL: playlist.playlistURL)
                let segmentData = try await downloadSegmentWithRetry(
                    httpClient: httpClient,
                    url: segmentURL,
                    maxRetries: 2,
                    allowPaused: true,
                    updateStreamHealth: false
                )
                let segmentSize = segmentData.count

                if segmentSize <= Self.pausedPreviewMaxSegmentBytes {
                    selectedSegmentData = segmentData
                    selectedSegmentSize = segmentSize
                    selectedOversizedFallback = false
                    break
                }

                if segmentSize <= Self.pausedPreviewFallbackMaxSegmentBytes,
                   segmentSize < smallestOversizedSize {
                    smallestOversizedData = segmentData
                    smallestOversizedSize = segmentSize
                }
            }

            if selectedSegmentData == nil, let fallback = smallestOversizedData {
                selectedSegmentData = fallback
                selectedSegmentSize = smallestOversizedSize
                selectedOversizedFallback = true
            }

            guard let segmentData = selectedSegmentData else {
                addLog("Waiting preview segment too large to thumbnail (all recent segments exceeded \(formatFilesize(Self.pausedPreviewFallbackMaxSegmentBytes)))")
                return
            }

            if selectedOversizedFallback {
                addLog("Using larger waiting preview segment for thumbnail fallback (\(formatFilesize(selectedSegmentSize)))")
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

            let personDetected = await detectHumanPresence(inVideoAtPath: tempSegmentPath)
            if personDetected {
                clearNoPersonIndicatorStateAfterWaitingRecovery()
            }

            let success = await generateThumbnail(from: tempSegmentPath)
            if success {
                await FileLogger.shared.logLiveThumbnailSuccess(channel: config.username)
            }
        } catch {
            // Waiting previews are best-effort and should not affect queue progression.
            guard !shouldSuppressBestEffortThumbnailFailure(error) else {
                return
            }
            await FileLogger.shared.logLiveThumbnailFailure(channel: config.username, error: error.localizedDescription)
        }
    }

    private func shouldSuppressBestEffortThumbnailFailure(_ error: Error) -> Bool {
        if let cbError = error as? ChaturbateError {
            if case .paused = cbError {
                return true
            }
        }

        if error.localizedDescription == ChaturbateError.paused.localizedDescription {
            return true
        }

        return false
    }

    private func clearNoPersonIndicatorStateAfterWaitingRecovery() {
        latestPersonDetected = true
        lastPersonSeenAt = Date()
        isNoPersonLikely = false
        noPersonStreakSeconds = 0
        noPersonNoMotionStreakSeconds = 0
        noPersonCarryExpiryAt = nil
        noPersonEvidenceExpiryAt = nil
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
        let slotGranted = await recordingCoordinator.acquireSlot(for: config.username)
        guard slotGranted else {
            throw ChaturbateError.paused
        }
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await recordingCoordinator.releaseSlot(for: config.username)
            return result
        } catch {
            await recordingCoordinator.releaseSlot(for: config.username)
            throw error
        }
    }
    
    private func watchSegments(playlist: Playlist) async throws {
        var lastVideoSeq = -1
        var lastAudioSeq = -1
        let httpClient = HTTPClient(config: appConfig)
        let recordingStartedAt = Date()
        let noSegmentTimeoutSeconds = 45.0 // Alert if no segments after 45 seconds
        var emptySegmentCount = 0
        
        while !Task.isCancelled && !config.isPaused && appConfig.recordingEnabled {
            let content = try await httpClient.get(playlist.playlistURL)
            try await refreshActiveInitSegment(
                mediaPlaylistContent: content,
                playlistURL: playlist.playlistURL,
                httpClient: httpClient
            )
            let segments = try M3U8Parser.parseMediaPlaylist(content)

            if lastVideoSeq == -1, let latestSequence = segments.last?.sequenceNumber {
                // On startup, begin from the latest published segment to avoid
                // failing on older entries that may already be expired.
                lastVideoSeq = max(-1, latestSequence - 1)
            }
            
            var processedAnySegment = false
            for segment in segments {
                if Task.isCancelled || config.isPaused {
                    throw ChaturbateError.paused
                }
                if !appConfig.recordingEnabled {
                    break
                }
                
                let seq = segment.sequenceNumber
                if seq == -1 || seq <= lastVideoSeq {
                    continue
                }
                lastVideoSeq = seq
                processedAnySegment = true

                let segmentURL = resolveSegmentURL(segment.uri, playlistURL: playlist.playlistURL)
                
                // Download segment with retry
                let segmentData = try await downloadSegmentWithRetry(
                    httpClient: httpClient,
                    url: segmentURL,
                    maxRetries: 3
                )

                try await handleSegment(data: segmentData, duration: segment.duration)
            }

            if let audioPlaylistURL = activeAudioPlaylistURL {
                let audioContent = try await httpClient.get(audioPlaylistURL)
                try await refreshActiveAudioInitSegment(
                    mediaPlaylistContent: audioContent,
                    playlistURL: audioPlaylistURL,
                    httpClient: httpClient
                )
                let audioSegments = try M3U8Parser.parseMediaPlaylist(audioContent)

                if lastAudioSeq == -1, let latestAudioSequence = audioSegments.last?.sequenceNumber {
                    // Align startup behavior with video to avoid immediate stale-segment fetches.
                    lastAudioSeq = max(-1, latestAudioSequence - 1)
                }

                for segment in audioSegments {
                    if Task.isCancelled || config.isPaused {
                        throw ChaturbateError.paused
                    }
                    if !appConfig.recordingEnabled {
                        break
                    }

                    let seq = segment.sequenceNumber
                    if seq == -1 || seq <= lastAudioSeq {
                        continue
                    }
                    lastAudioSeq = seq

                    let segmentURL = resolveSegmentURL(segment.uri, playlistURL: audioPlaylistURL)
                    let audioData = try await downloadSegmentWithRetry(
                        httpClient: httpClient,
                        url: segmentURL,
                        maxRetries: 2,
                        updateStreamHealth: false
                    )

                    try await handleAudioSegment(data: audioData)
                }
            }
            
            // Detect if we're stuck with no segments (indicates potential stream issue)
            if !processedAnySegment {
                emptySegmentCount += 1
                let timeSinceStart = Date().timeIntervalSince(recordingStartedAt)
                
                if timeSinceStart > noSegmentTimeoutSeconds && emptySegmentCount > 5 {
                    addLog("⚠️ No segments downloaded after \(Int(timeSinceStart))s (\(emptySegmentCount) empty cycles); stream may have stalled")
                }
            } else {
                emptySegmentCount = 0
            }
            
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }

        if !appConfig.recordingEnabled && !Task.isCancelled && !config.isPaused {
            addLog("Recording globally disabled, waiting for recording to be re-enabled")
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
    
    private func downloadSegmentWithRetry(
        httpClient: HTTPClient,
        url: String,
        maxRetries: Int,
        allowPaused: Bool = false,
        updateStreamHealth: Bool = true
    ) async throws -> Data {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            if Task.isCancelled || (!allowPaused && config.isPaused) {
                throw ChaturbateError.paused
            }

            do {
                let data = try await httpClient.getData(url)
                try validateDownloadedSegmentPayload(data, url: url)
                if updateStreamHealth, attempt > 1 {
                    segmentRetryCount += (attempt - 1)
                }
                if updateStreamHealth {
                    noteSuccessfulSegmentDownload(attempt: attempt)
                }
                return data
            } catch {
                if Task.isCancelled || (!allowPaused && config.isPaused) {
                    throw ChaturbateError.paused
                }
                lastError = error
                if updateStreamHealth {
                    degradedRecoveryStartedAt = nil
                }
                if updateStreamHealth, attempt < maxRetries {
                    addLog("Segment download failed (attempt \(attempt)/\(maxRetries)); retrying")
                }
                try? await Task.sleep(nanoseconds: 600_000_000) // 600ms delay
            }
        }

        if updateStreamHealth {
            noteFailedSegmentDownload()
            addLog("Segment download failed after \(maxRetries) attempts")
        }
        
        throw lastError ?? ChaturbateError.networkError("Failed to download segment")
    }

    private func validateDownloadedSegmentPayload(_ data: Data, url: String) throws {
        guard !data.isEmpty else {
            throw ChaturbateError.parsingError("Empty segment payload")
        }

        if looksLikeTransportStreamPayload(data) || looksLikeFragmentedMP4Payload(data) {
            return
        }

        let hint = suspiciousPayloadHint(data)
        let reason = hint.map { "Invalid media payload (\($0))" } ?? "Invalid media payload"
        throw ChaturbateError.parsingError("\(reason) from \(url)")
    }

    private func looksLikeTransportStreamPayload(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(188 * 6))
        guard bytes.count >= 188 * 3 else {
            return false
        }

        let maxOffset = min(187, bytes.count - (188 * 3))
        for offset in 0...maxOffset {
            if bytes[offset] == 0x47,
               bytes[offset + 188] == 0x47,
               bytes[offset + (188 * 2)] == 0x47 {
                return true
            }
        }

        return false
    }

    private func looksLikeFragmentedMP4Payload(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(4096))
        guard bytes.count >= 8 else {
            return false
        }

        let allowedTypes: Set<String> = ["styp", "sidx", "moof", "mdat", "free", "skip", "prft", "emsg"]
        var offset = 0
        var sawFragmentBox = false
        var boxCount = 0

        while offset + 8 <= bytes.count && boxCount < 8 {
            let size32 = Int(readUInt32(bytes, at: offset))
            if size32 == 0 {
                break
            }

            var boxSize = size32
            var headerSize = 8
            if size32 == 1 {
                guard offset + 16 <= bytes.count else { return false }
                let size64 = Int(readUInt64(bytes, at: offset + 8))
                guard size64 >= 16 else { return false }
                boxSize = size64
                headerSize = 16
            }

            guard boxSize >= headerSize else { return false }

            let typeRange = (offset + 4)..<(offset + 8)
            let type = String(bytes: bytes[typeRange], encoding: .ascii) ?? ""
            guard allowedTypes.contains(type) else {
                return false
            }

            if type == "moof" || type == "mdat" {
                sawFragmentBox = true
            }

            boxCount += 1

            if offset + boxSize > bytes.count {
                return sawFragmentBox
            }

            offset += boxSize
        }

        return sawFragmentBox
    }

    private func suspiciousPayloadHint(_ data: Data) -> String? {
        let preview = String(decoding: data.suffix(128), as: UTF8.self)
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))

        guard !preview.isEmpty else {
            return nil
        }

        if preview.localizedCaseInsensitiveContains("cache")
            || preview.localizedCaseInsensitiveContains("error")
            || preview.localizedCaseInsensitiveContains("html") {
            return preview
        }

        return nil
    }

    private func markOfflineAndClearDegradedState() {
        isOnline = false
        liveStreamURL = nil
        preserveNoPersonStateAcrossTransientOffline()
        clearDegradedState()
        
        // When channel goes offline, clear session limit pause so it can
        // record fresh when it comes back with a new session
        if isPausedBySessionLimit && !config.isPaused {
            // Only clear if it's not manually paused; manual pauses take precedence
            isPausedBySessionLimit = false
            config.isPaused = false
            sessionDurationSeconds = 0
            sessionFilesizeBytes = 0
            sessionStartedAt = nil
            addLog("Channel went offline - session limit pause cleared, ready to record on next session")
        } else if isPausedBySessionLimit && config.isPaused {
            // Clear the session limit flag but keep the manual pause
            isPausedBySessionLimit = false
            sessionDurationSeconds = 0
            sessionFilesizeBytes = 0
            sessionStartedAt = nil
        }
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

        let normalizedSegment = normalizeFragmentDecodeTimeIfNeeded(data)
        let normalizedSegmentData = normalizedSegment.data
        let observedSegmentDuration = observedSegmentDurationFromDecodeStart(normalizedSegment.decodeStartTime)
        let effectiveSegmentDuration = observedSegmentDuration ?? duration
        try validateSegmentTimeline(claimedDuration: duration, observedDuration: observedSegmentDuration)

        if pendingTimestampDiscontinuity && filesize > 0 {
            addLog("Timestamp discontinuity detected; dropping current segment and rolling to a new recording file")
            try await nextFile()
            pendingTimestampDiscontinuity = false
            return
        }
        pendingTimestampDiscontinuity = false

        try await ensureCurrentFileOpenForWrite()

        guard let file = currentFile else {
            throw ChaturbateError.fileError("No file open")
        }

        if filesize == 0, let initData = activeInitSegmentData {
            try file.write(contentsOf: initData)
            filesize += initData.count
        }
        
        try file.write(contentsOf: normalizedSegmentData)

        let now = Date()
        
        filesize += normalizedSegmentData.count
        sessionFilesizeBytes += normalizedSegmentData.count
        self.duration += effectiveSegmentDuration
        sessionDurationSeconds += effectiveSegmentDuration
        appendSegmentToRecordingPreviewBuffer(data: normalizedSegmentData, duration: effectiveSegmentDuration)
        await persistRecordingProgressIfNeeded(force: false)
        
        // Check session duration limit
        if config.maxSessionDuration > 0 {
            let sessionLimitSeconds = TimeInterval(config.maxSessionDuration * 60)
            if sessionDurationSeconds >= sessionLimitSeconds && !isPausedBySessionLimit {
                pauseForSessionLimit(reason: "\(config.maxSessionDuration) minutes")
                throw ChaturbateError.paused
            }
        }

        // Check session total filesize limit across split files
        if config.maxSessionFilesize > 0 {
            let sessionFilesizeLimitBytes = config.maxSessionFilesize * 1024 * 1024
            if sessionFilesizeBytes >= sessionFilesizeLimitBytes && !isPausedBySessionLimit {
                pauseForSessionLimit(reason: "\(config.maxSessionFilesize) MB")
                throw ChaturbateError.paused
            }
        }
        
        // Generate thumbnail every 5 seconds
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
            addLog("Max filesize or duration exceeded, next file queued")
        }
    }

    private func handleAudioSegment(data: Data) async throws {
        guard activeAudioPlaylistURL != nil else {
            return
        }

        try await ensureCurrentFileOpenForWrite()

        guard let audioFile = currentAudioFile else {
            return
        }

        if currentAudioFilesize == 0, let initData = activeAudioInitSegmentData {
            try audioFile.write(contentsOf: initData)
            currentAudioFilesize += initData.count
        }

        try audioFile.write(contentsOf: data)
        currentAudioFilesize += data.count
    }
    
    private func nextFile() async throws {
        closeCurrentFile(resetStats: true)
        pendingFilenameBase = try generateFilename()
        sequence += 1
    }

    private func ensureCurrentFileOpenForWrite() async throws {
        if currentFile != nil {
            return
        }

        if pendingFilenameBase == nil {
            pendingFilenameBase = try generateFilename()
            sequence += 1
        }

        guard let filenameBase = pendingFilenameBase else {
            throw ChaturbateError.fileError("No pending filename available")
        }

        let fileExtension = activeInitSegmentData == nil ? "ts" : "mp4"
        let isFirstFileInSession = (sequence == 1)
        try await createNewFile(filename: filenameBase, fileExtension: fileExtension)
        pendingFilenameBase = nil

        if isFirstFileInSession {
            addLog("Recording container selected: .\(fileExtension)")
        }
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
        let workingURL = workingFileURL(for: fileURL)
        let shouldRecordAudioSidecar = (fileExtension.lowercased() == "mp4" && activeAudioPlaylistURL != nil)
        let audioWorkingURL = shouldRecordAudioSidecar ? workingAudioFileURL(for: fileURL) : nil

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: workingURL.path) {
            try FileManager.default.removeItem(at: workingURL)
        }

        let created = FileManager.default.createFile(atPath: workingURL.path, contents: nil)
        guard created else {
            throw ChaturbateError.fileError("Could not create file: \(workingURL.path)")
        }

        if let audioWorkingURL {
            if FileManager.default.fileExists(atPath: audioWorkingURL.path) {
                try FileManager.default.removeItem(at: audioWorkingURL)
            }

            let audioCreated = FileManager.default.createFile(atPath: audioWorkingURL.path, contents: nil)
            guard audioCreated else {
                throw ChaturbateError.fileError("Could not create audio sidecar file: \(audioWorkingURL.path)")
            }
        }

        guard let fileHandle = FileHandle(forWritingAtPath: workingURL.path) else {
            throw ChaturbateError.fileError("Could not open file: \(workingURL.path)")
        }

        var audioHandle: FileHandle?
        if let audioWorkingURL {
            guard let opened = FileHandle(forWritingAtPath: audioWorkingURL.path) else {
                throw ChaturbateError.fileError("Could not open audio sidecar file: \(audioWorkingURL.path)")
            }
            audioHandle = opened
        }

        currentFile = fileHandle
        currentFilename = fileURL.path
        currentWorkingFilename = workingURL.path
        currentAudioFile = audioHandle
        currentAudioWorkingFilename = audioWorkingURL?.path
        currentAudioFilesize = 0

        config.recordingHistory.append(fileURL.path)
        if config.recordingHistory.count > 200 {
            config.recordingHistory.removeFirst(config.recordingHistory.count - 200)
        }

        let startedAt = Date()
        activeRecordingStartedAt = startedAt
        activeRecordingFirstPersonDetectedAt = nil
        lastRecordingProgressPersistAt = .distantPast
        activeRecordingID = await recordingLedger.startRecording(
            channelUsername: config.username,
            filePath: fileURL.path,
            workingFilePath: workingURL.path,
            container: fileExtension,
            startedAt: startedAt
        )
        if let activeRecordingID {
            await recordingLedger.appendEvent(
                recordingID: activeRecordingID,
                level: "INFO",
                eventType: "recording_started",
                message: "Recording file opened"
            )
            addLog("Recording file created: \(fileExtension.uppercased()) (0 KB, awaiting segments)")
        }
    }

    private func closeCurrentFile(resetStats: Bool) {
        let finalPath = currentFilename
        let workingPath = currentWorkingFilename
        let audioWorkingPath = currentAudioWorkingFilename
        let shouldFinalizeMP4 = (finalPath as NSString?)?.pathExtension.lowercased() == "mp4"
        let recordingID = activeRecordingID
        let durationSnapshot = duration
        let filesizeSnapshot = filesize
        let endedAt = Date()

        if let file = currentFile {
            do {
                try file.synchronize()
                try file.close()
            } catch {
                addLog("Could not close recording file cleanly: \(error.localizedDescription)")
            }

            currentFile = nil
        }

        if let audioFile = currentAudioFile {
            do {
                try audioFile.synchronize()
                try audioFile.close()
            } catch {
                addLog("Could not close recording audio sidecar cleanly: \(error.localizedDescription)")
            }

            currentAudioFile = nil
        }

        let usableAudioWorkingPath: String? = {
            guard let audioWorkingPath,
                  FileManager.default.fileExists(atPath: audioWorkingPath) else {
                return nil
            }
            return audioWorkingPath
        }()

        if shouldFinalizeMP4, let workingPath, let finalPath {
            let channelName = config.username
            let recordingLedger = self.recordingLedger
            Task {
                await Self.mp4Finalizer.enqueue(
                    sourcePath: workingPath,
                    audioSourcePath: usableAudioWorkingPath,
                    destinationPath: finalPath,
                    channel: channelName
                ) { outcome in
                    guard let recordingID else { return }
                    Task {
                        let resolvedPath: String
                        if FileManager.default.fileExists(atPath: finalPath) {
                            resolvedPath = finalPath
                        } else {
                            resolvedPath = workingPath
                        }

                        let remuxed = outcome == .succeeded
                        let status = remuxed ? "completed" : "completed_with_remux_warning"
                        await recordingLedger.finishRecording(
                            recordingID: recordingID,
                            endedAt: endedAt,
                            durationSeconds: durationSnapshot,
                            fileSizeBytes: Int64(filesizeSnapshot),
                            finalPath: resolvedPath,
                            wasRemuxed: remuxed,
                            status: status
                        )
                        if case .skipped(let reason) = outcome {
                            await recordingLedger.appendEvent(
                                recordingID: recordingID,
                                level: "WARN",
                                eventType: "remux_skipped",
                                message: reason
                            )
                        }
                    }
                }
            }
        } else if let workingPath, let finalPath,
                  workingPath != finalPath,
                  FileManager.default.fileExists(atPath: workingPath) {
            do {
                if FileManager.default.fileExists(atPath: finalPath) {
                    try FileManager.default.removeItem(atPath: finalPath)
                }
                try FileManager.default.moveItem(atPath: workingPath, toPath: finalPath)
            } catch {
                addLog("Could not publish recording file cleanly: \(error.localizedDescription)")
            }

            if let usableAudioWorkingPath {
                try? FileManager.default.removeItem(atPath: usableAudioWorkingPath)
            }

            if let recordingID {
                let recordingLedger = self.recordingLedger
                let resolvedFinalPath = FileManager.default.fileExists(atPath: finalPath) ? finalPath : workingPath
                Task {
                    await recordingLedger.finishRecording(
                        recordingID: recordingID,
                        endedAt: endedAt,
                        durationSeconds: durationSnapshot,
                        fileSizeBytes: Int64(filesizeSnapshot),
                        finalPath: resolvedFinalPath,
                        wasRemuxed: false,
                        status: "completed"
                    )
                }
            }
        } else if let finalPath, let recordingID {
            let recordingLedger = self.recordingLedger
            Task {
                await recordingLedger.finishRecording(
                    recordingID: recordingID,
                    endedAt: endedAt,
                    durationSeconds: durationSnapshot,
                    fileSizeBytes: Int64(filesizeSnapshot),
                    finalPath: finalPath,
                    wasRemuxed: false,
                    status: "completed"
                )
            }
        }

        if resetStats {
            filesize = 0
            duration = 0
            activeRecordingID = nil
            activeRecordingStartedAt = nil
            activeRecordingFirstPersonDetectedAt = nil
            lastRecordingProgressPersistAt = .distantPast
            currentFilename = nil
            currentWorkingFilename = nil
            currentAudioWorkingFilename = nil
            currentAudioFilesize = 0
            pendingFilenameBase = nil
            currentFileDecodeTimeOffset = nil
            resetSegmentTimelineTracking()
        }
    }

    private func workingFileURL(for visibleFileURL: URL) -> URL {
        let hiddenName = ".\(visibleFileURL.lastPathComponent)"
        return visibleFileURL.deletingLastPathComponent().appendingPathComponent(hiddenName)
    }

    private func workingAudioFileURL(for visibleFileURL: URL) -> URL {
        let baseName = visibleFileURL.deletingPathExtension().lastPathComponent
        let hiddenName = ".\(baseName)_audio.m4a"
        return visibleFileURL.deletingLastPathComponent().appendingPathComponent(hiddenName)
    }

    private func normalizeFragmentDecodeTimeIfNeeded(_ data: Data) -> (data: Data, decodeStartTime: UInt64?) {
        guard activeInitSegmentData != nil else {
            return (data, nil)
        }

        guard let rawDecodeStartTime = extractFirstTFDTDecodeTime(from: data) else {
            return (data, nil)
        }

        // Detect timeline rewinds using the segment-level decode start before
        // any normalization. This preserves original fragment timestamps while
        // still forcing file rollover on discontinuities.
        if let previousRaw = previousRawSegmentDecodeStartTime,
           rawDecodeStartTime < previousRaw {
            pendingTimestampDiscontinuity = true
            previousSegmentDecodeStartTime = nil
            addLog("fMP4 decode timeline rewind detected (raw tfdt \(rawDecodeStartTime) < \(previousRaw)); rolling to a new recording file")
        } else if let previousRaw = previousRawSegmentDecodeStartTime,
                  isForwardDecodeTimeJump(rawDecodeStartTime, previousRawDecodeStartTime: previousRaw) {
            pendingTimestampDiscontinuity = true
            previousSegmentDecodeStartTime = nil

            if let timescale = activeFragmentTimescale, timescale > 0 {
                let deltaSeconds = Double(rawDecodeStartTime - previousRaw) / Double(timescale)
                addLog(
                    "fMP4 decode timeline jump detected (+\(String(format: "%.2f", deltaSeconds))s raw tfdt \(previousRaw) -> \(rawDecodeStartTime)); rolling to a new recording file"
                )
            } else {
                addLog(
                    "fMP4 decode timeline jump detected (raw tfdt \(previousRaw) -> \(rawDecodeStartTime)); rolling to a new recording file"
                )
            }
        }

        previousRawSegmentDecodeStartTime = rawDecodeStartTime

        // Preserve original fragment timestamps; mutating tfdt in-place can
        // corrupt long-session playback timing.
        return (data, rawDecodeStartTime)
    }

    private func isForwardDecodeTimeJump(_ rawDecodeStartTime: UInt64, previousRawDecodeStartTime: UInt64) -> Bool {
        guard rawDecodeStartTime > previousRawDecodeStartTime,
              let timescale = activeFragmentTimescale,
              timescale > 0 else {
            return false
        }

        let deltaSeconds = Double(rawDecodeStartTime - previousRawDecodeStartTime) / Double(timescale)
        guard deltaSeconds.isFinite else {
            return false
        }

        return deltaSeconds > Self.fmp4ForwardDecodeJumpThresholdSeconds
    }

    private func extractFirstTFDTDecodeTime(from data: Data) -> UInt64? {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return nil }
        guard let location = findFirstTFDTLocation(in: bytes, range: 0..<bytes.count) else {
            return nil
        }

        if location.version == 1 {
            guard location.valueOffset + 8 <= location.payloadEnd else {
                return nil
            }
            return readUInt64(bytes, at: location.valueOffset)
        }

        guard location.valueOffset + 4 <= location.payloadEnd else {
            return nil
        }
        return UInt64(readUInt32(bytes, at: location.valueOffset))
    }

    private func findFirstTFDTLocation(in bytes: [UInt8], range: Range<Int>) -> (version: UInt8, valueOffset: Int, payloadEnd: Int)? {
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

                guard version == 0 || version == 1 else {
                    cursor += boxSize
                    continue
                }

                return (version, valueOffset, payloadEnd)
            }

            if isContainerBox(type), payloadStart < payloadEnd,
               let nestedLocation = findFirstTFDTLocation(in: bytes, range: payloadStart..<payloadEnd) {
                return nestedLocation
            }

            cursor += boxSize
        }

        return nil
    }

    private func rewriteFirstTFDTDecodeTime(in data: Data, to decodeTime: UInt64) -> Data? {
        var bytes = [UInt8](data)
        guard let location = findFirstTFDTLocation(in: bytes, range: 0..<bytes.count) else {
            return nil
        }

        if location.version == 1 {
            guard location.valueOffset + 8 <= location.payloadEnd else {
                return nil
            }
            writeUInt64(decodeTime, to: &bytes, at: location.valueOffset)
            return Data(bytes)
        }

        guard decodeTime <= UInt64(UInt32.max),
              location.valueOffset + 4 <= location.payloadEnd else {
            return nil
        }
        writeUInt32(UInt32(decodeTime), to: &bytes, at: location.valueOffset)
        return Data(bytes)
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
        return await generateThumbnailDetailed(from: currentWorkingFilename ?? filename, analyzeForBreak: true)
    }

    private func clearRecordingPreviewState(removeTempFile: Bool) {
        recentPreviewSegments.removeAll(keepingCapacity: false)
        recentPreviewDuration = 0
        recentPreviewBytes = 0
        activeInitSegmentURI = nil
        activeInitSegmentData = nil
        activeAudioPlaylistURL = nil
        activeAudioInitSegmentURI = nil
        activeAudioInitSegmentData = nil
        activeFragmentTimescale = nil
        resetSegmentTimelineTracking()

        if removeTempFile, let path = recordingPreviewTempPath {
            try? FileManager.default.removeItem(atPath: path)
            recordingPreviewTempPath = nil
        }
    }

    private func refreshActiveInitSegment(mediaPlaylistContent: String, playlistURL: String, httpClient: HTTPClient) async throws {
        guard let initURI = M3U8Parser.parseInitSegmentURI(mediaPlaylistContent), !initURI.isEmpty else {
            if ingestContainerMode != .transportStream {
                ingestContainerMode = .transportStream
                addLog("Stream ingest mode: MPEG-TS segments (no #EXT-X-MAP)")
            }
            activeInitSegmentURI = nil
            activeInitSegmentData = nil
            activeAudioInitSegmentURI = nil
            activeAudioInitSegmentData = nil
            activeFragmentTimescale = nil
            resetSegmentTimelineTracking()
            return
        }

        if ingestContainerMode != .fragmentedMP4 {
            ingestContainerMode = .fragmentedMP4
            addLog("Stream ingest mode: fragmented MP4 via #EXT-X-MAP")
        }

        if activeInitSegmentURI == initURI, activeInitSegmentData != nil {
            return
        }

        if let previousInit = activeInitSegmentURI,
           previousInit != initURI,
           currentFile != nil,
           filesize > 0 {
            addLog("Init segment changed, rolling to a new recording file")
            try await nextFile()
        }

        let resolvedInitURL = resolveSegmentURL(initURI, playlistURL: playlistURL)
        let initData = try await httpClient.getData(resolvedInitURL)
        activeInitSegmentURI = initURI
        activeInitSegmentData = initData
        activeFragmentTimescale = extractMDHDTimescale(from: initData)

        if activeFragmentTimescale == nil {
            addLog("Could not read fMP4 timescale from init segment; duration guard disabled for this stream")
        }
    }

    private func refreshActiveAudioInitSegment(mediaPlaylistContent: String, playlistURL: String, httpClient: HTTPClient) async throws {
        guard let initURI = M3U8Parser.parseInitSegmentURI(mediaPlaylistContent), !initURI.isEmpty else {
            activeAudioInitSegmentURI = nil
            activeAudioInitSegmentData = nil
            return
        }

        if activeAudioInitSegmentURI == initURI, activeAudioInitSegmentData != nil {
            return
        }

        let resolvedInitURL = resolveSegmentURL(initURI, playlistURL: playlistURL)
        let initData = try await httpClient.getData(resolvedInitURL)
        activeAudioInitSegmentURI = initURI
        activeAudioInitSegmentData = initData
    }

    private func resetSegmentTimelineTracking() {
        previousRawSegmentDecodeStartTime = nil
        previousSegmentDecodeStartTime = nil
        cumulativeClaimedSegmentDuration = 0
        cumulativeObservedSegmentDuration = 0
        segmentTimelineMismatchEvents = 0
    }

    private func observedSegmentDurationFromDecodeStart(_ decodeStartTime: UInt64?) -> Double? {
        guard let decodeStartTime,
              let timescale = activeFragmentTimescale,
              timescale > 0 else {
            return nil
        }

        defer {
            previousSegmentDecodeStartTime = decodeStartTime
        }

        guard let previousStart = previousSegmentDecodeStartTime,
              decodeStartTime > previousStart else {
            return nil
        }

        let observedSeconds = Double(decodeStartTime - previousStart) / Double(timescale)

        // Ignore clearly invalid deltas from malformed fragments.
        guard observedSeconds.isFinite,
              observedSeconds > 0,
              observedSeconds < 30 else {
            return nil
        }

        return observedSeconds
    }

    private func validateSegmentTimeline(claimedDuration: Double, observedDuration: Double?) throws {
        guard let observedDuration else {
            return
        }

        cumulativeClaimedSegmentDuration += max(0, claimedDuration)
        cumulativeObservedSegmentDuration += observedDuration

        guard cumulativeClaimedSegmentDuration >= Self.segmentTimelineMismatchMinClaimedSeconds,
              cumulativeObservedSegmentDuration > 0 else {
            return
        }

        let ratio = cumulativeClaimedSegmentDuration / cumulativeObservedSegmentDuration
        guard ratio.isFinite else {
            return
        }

        if ratio > Self.segmentTimelineMismatchMaxRatio {
            segmentTimelineMismatchEvents += 1

            if segmentTimelineMismatchEvents >= Self.segmentTimelineMismatchRequiredEvents {
                let claimed = formatDuration(cumulativeClaimedSegmentDuration)
                let observed = formatDuration(cumulativeObservedSegmentDuration)
                timelineMismatchCount += 1
                lastTimelineMismatchAt = Date()
                addLog("Timeline mismatch guard triggered (claimed \(claimed) vs media \(observed)); restarting stream capture")
                throw ChaturbateError.parsingError("Segment timeline mismatch")
            }
        } else {
            segmentTimelineMismatchEvents = 0
        }
    }

    private func extractMDHDTimescale(from data: Data) -> UInt32? {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else {
            return nil
        }
        return findMDHDTimescale(in: bytes, range: 0..<bytes.count)
    }

    private func findMDHDTimescale(in bytes: [UInt8], range: Range<Int>) -> UInt32? {
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

            if type == "mdhd" {
                guard payloadStart + 4 <= payloadEnd else {
                    cursor += boxSize
                    continue
                }

                let version = bytes[payloadStart]
                if version == 1 {
                    guard payloadStart + 24 <= payloadEnd else {
                        cursor += boxSize
                        continue
                    }
                    let timescale = readUInt32(bytes, at: payloadStart + 20)
                    if timescale > 0 {
                        return timescale
                    }
                } else {
                    guard payloadStart + 16 <= payloadEnd else {
                        cursor += boxSize
                        continue
                    }
                    let timescale = readUInt32(bytes, at: payloadStart + 12)
                    if timescale > 0 {
                        return timescale
                    }
                }
            } else if isContainerBox(type), payloadStart < payloadEnd,
                      let nestedTimescale = findMDHDTimescale(in: bytes, range: payloadStart..<payloadEnd) {
                return nestedTimescale
            }

            cursor += boxSize
        }

        return nil
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

    private func persistRecordingProgressIfNeeded(force: Bool) async {
        guard let activeRecordingID else { return }

        let now = Date()
        if !force, now.timeIntervalSince(lastRecordingProgressPersistAt) < 5 {
            return
        }

        lastRecordingProgressPersistAt = now
        await recordingLedger.updateRecordingProgress(
            recordingID: activeRecordingID,
            durationSeconds: duration,
            fileSizeBytes: Int64(filesize),
            noPersonDurationSeconds: max(0, Int(noPersonStreakSeconds.rounded())),
            segmentRetryCount: segmentRetryCount,
            consecutiveSegmentFailures: consecutiveSegmentFailures,
            cloudflareBlockCount: cloudflareBlockCount,
            timelineMismatchCount: timelineMismatchCount
        )
    }

    private func notePersonDetectionForActiveRecording(at date: Date) {
        guard let activeRecordingID else { return }
        if activeRecordingFirstPersonDetectedAt == nil {
            activeRecordingFirstPersonDetectedAt = date
        }

        let recordingLedger = self.recordingLedger
        Task {
            await recordingLedger.markPersonDetected(recordingID: activeRecordingID, detectedAt: date)
        }
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

        if let activeRecordingID {
            let recordingLedger = self.recordingLedger
            Task {
                await recordingLedger.appendEvent(
                    recordingID: activeRecordingID,
                    level: "INFO",
                    eventType: "channel_log",
                    message: message
                )
            }
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
        liveStreamURL = nil
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

        for recording in config.recordingHistory.reversed() {
            let normalized = (recording as NSString).expandingTildeInPath
            let parent = (normalized as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: parent) {
                return parent
            }
        }

        // Get base output directory (app default or channel-specific override)
        let baseOutputDir = config.outputDirectory.isEmpty ? appConfig.getOutputPath() : config.outputDirectory
        
        // Add username as subfolder
        return (baseOutputDir as NSString).appendingPathComponent(config.username)
    }

    private func generateThumbnailFromExistingVideoIfNeeded() async -> OfflineThumbnailBackfillResult {
        guard thumbnailPath == nil else { return .skipped }

        let candidate = latestVideoCandidateForThumbnail()
        guard let candidate else {
            await FileLogger.shared.logNoVideosFound(channel: config.username)
            addLog("Background: checking for videos to thumbnail... none found yet")
            return .noVideoCandidate
        }

        let fileName = (candidate as NSString).lastPathComponent
        let fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: candidate)[.size] as? NSNumber)?.intValue ?? 0
        let fileSize = formatFilesize(fileSizeBytes)
        
        await FileLogger.shared.logBackfillAttempt(channel: config.username, videoPath: fileName, fileSize: fileSize)
        addLog("Background: attempting to generate thumbnail from: \(fileName) (\(fileSize))")
        
        let success = await generateThumbnail(from: candidate)
        if success {
            await FileLogger.shared.logBackfillSuccess(channel: config.username)
            return .generated
        } else {
            await FileLogger.shared.logBackfillFailure(channel: config.username, error: "frame extraction failed")
            return .generationFailed
        }
    }

    private func latestVideoCandidateForThumbnail() -> String? {
        var candidates = Set<String>()
        var directoryCandidates = Set<String>()

        directoryCandidates.insert((recordingsDirectoryPath() as NSString).expandingTildeInPath)

        let baseOutputDir = config.outputDirectory.isEmpty ? appConfig.getOutputPath() : config.outputDirectory
        let configuredChannelDir = ((baseOutputDir as NSString).appendingPathComponent(config.username) as NSString).expandingTildeInPath
        directoryCandidates.insert(configuredChannelDir)

        for recording in config.recordingHistory {
            let normalized = (recording as NSString).expandingTildeInPath
            directoryCandidates.insert((normalized as NSString).deletingLastPathComponent)
            if FileManager.default.fileExists(atPath: normalized) {
                candidates.insert(normalized)
            }
        }

        for directoryPath in directoryCandidates where FileManager.default.fileExists(atPath: directoryPath) {
            if let fileNames = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) {
                for fileName in fileNames {
                    let lower = fileName.lowercased()
                    guard lower.hasSuffix(".ts")
                        || lower.hasSuffix(".mp4")
                        || lower.hasSuffix(".mkv")
                        || lower.hasSuffix(".mov")
                        || lower.hasSuffix(".m4v") else {
                        continue
                    }
                    let fullPath = (directoryPath as NSString).appendingPathComponent(fileName)
                    if FileManager.default.fileExists(atPath: fullPath) {
                        candidates.insert(fullPath)
                    }
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
            let checkResult = try await runPreflightFrameAnalysis(
                hlsSource: hlsSource,
                purpose: "break_recheck",
                analyzeForBreak: true
            )
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
            // Fail closed while break is enforced to avoid short record/re-offline
            // flaps when recheck probes are transiently failing.
            pendingBreakOfflineReason = "Break hold: recheck failed (\(error.localizedDescription)); keeping stream offline"
            addLog(pendingBreakOfflineReason ?? "Break hold: recheck failed; keeping stream offline")
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
                    purpose: "start_gate_\(index)",
                    analyzeForBreak: false
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

    private func runPreflightFrameAnalysis(
        hlsSource: String,
        purpose: String,
        analyzeForBreak: Bool
    ) async throws -> ThumbnailGenerationResult {
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

        if !analyzeForBreak {
            let personDetected = await detectHumanPresence(inVideoAtPath: tempSegmentPath)
            latestPersonDetected = personDetected
            lastPersonSeenAt = personDetected ? Date() : nil
        }

        return await generateThumbnailDetailed(from: tempSegmentPath, analyzeForBreak: analyzeForBreak)
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
        // Break analysis currently runs via thumbnail refresh (~5s cadence).
        // Cap the effective interval to this cadence to avoid extra lag.
        let effectiveAnalysisIntervalSeconds = min(analysisIntervalSeconds, 5.0)
        let staticThresholdSeconds = TimeInterval(max(1, min(180, appConfig.breakStaticThresholdMinutes))) * 60
        let noPersonThresholdSeconds = TimeInterval(max(1, min(60, appConfig.breakNoPersonNoMotionThresholdMinutes))) * 60
        let noPersonBadgeThresholdSeconds = min(90.0, max(20.0, noPersonThresholdSeconds / 3.0))
        let sustainedNoPersonEvidenceThresholdSeconds = min(noPersonThresholdSeconds, max(120.0, noPersonBadgeThresholdSeconds * 2.0))
        let personDetectionGraceSeconds = max(30.0, effectiveAnalysisIntervalSeconds * 6.0)

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
           now.timeIntervalSince(last) < effectiveAnalysisIntervalSeconds {
            return false
        }

        let elapsed = max(
            effectiveAnalysisIntervalSeconds,
            lastBreakAnalysisAt.map { now.timeIntervalSince($0) } ?? effectiveAnalysisIntervalSeconds
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
            notePersonDetectionForActiveRecording(at: now)
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
        let fullBodyRequest = VNDetectHumanRectanglesRequest()
        fullBodyRequest.upperBodyOnly = false
        let upperBodyRequest = VNDetectHumanRectanglesRequest()
        upperBodyRequest.upperBodyOnly = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([faceRequest, fullBodyRequest, upperBodyRequest])
            let hasFace = !(faceRequest.results?.isEmpty ?? true)
            let hasFullBody = !(fullBodyRequest.results?.isEmpty ?? true)
            let hasUpperBody = !(upperBodyRequest.results?.isEmpty ?? true)
            return hasFace || hasFullBody || hasUpperBody
        } catch {
            // Fail open to avoid false positives if Vision cannot analyze the frame.
            return true
        }
    }

    private func detectHumanPresence(inVideoAtPath videoPath: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: videoPath) else {
            return true
        }

        let asset = AVAsset(url: URL(fileURLWithPath: videoPath))
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 960, height: 540)
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.8, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.8, preferredTimescale: 600)

        let duration: CMTime
        do {
            duration = try await withTimeoutInterval(4.0) {
                try await asset.load(.duration)
            }
        } catch {
            duration = CMTime(seconds: 3.0, preferredTimescale: 600)
        }

        let durationSeconds = max(0.0, duration.seconds.isFinite ? duration.seconds : 0.0)
        let candidateSeconds: [Double]
        if durationSeconds > 0 {
            candidateSeconds = [
                min(0.5, durationSeconds),
                min(1.4, durationSeconds),
                max(0.0, durationSeconds * 0.5),
                max(0.0, durationSeconds - 0.35)
            ]
        } else {
            candidateSeconds = [0.0, 0.6, 1.2]
        }

        var analyzedFrame = false
        var visitedTimes = Set<Int>()
        for seconds in candidateSeconds {
            let key = Int((seconds * 10.0).rounded())
            if visitedTimes.contains(key) {
                continue
            }
            visitedTimes.insert(key)

            let targetTime = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let cgImage = try? imageGenerator.copyCGImage(at: targetTime, actualTime: nil) else {
                continue
            }

            analyzedFrame = true
            if detectHumanPresence(in: cgImage) {
                return true
            }
        }

        // If we couldn't decode any frame, fail open rather than block recording start.
        return analyzedFrame ? false : true
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
