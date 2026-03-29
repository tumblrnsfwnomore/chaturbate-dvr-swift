import Foundation
import Combine
import AppKit

struct FollowedImportPreview {
    let found: [String]
    let existing: [String]
    let toAdd: [String]
}

struct BioBackfillProgress {
    let completed: Int
    let total: Int
    let currentChannel: String
}

actor RequestCoordinator {
    struct Stats {
        let activeRequests: Int
        let queuedRequests: Int
        let maxConcurrent: Int
        let saturationEvents: Int
        let averageWaitMs: Int
        let maxWaitMs: Int
    }

    private var activeRequests: Int = 0
    private var maxConcurrent: Int
    private var waitingTasks: [CheckedContinuation<Void, Never>] = []
    private var saturationEvents: Int = 0
    private var totalWaitMs: Int = 0
    private var waitSamples: Int = 0
    private var maxObservedWaitMs: Int = 0
    
    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }
    
    func updateMaxConcurrent(_ max: Int) {
        maxConcurrent = max
        // Resume waiting tasks if we increased the limit
        while activeRequests < maxConcurrent && !waitingTasks.isEmpty {
            let continuation = waitingTasks.removeFirst()
            activeRequests += 1
            continuation.resume()
        }
    }
    
    func acquireSlot() async {
        if activeRequests < maxConcurrent {
            activeRequests += 1
            return
        }

        saturationEvents += 1
        let waitStart = Date()
        
        await withCheckedContinuation { continuation in
            waitingTasks.append(continuation)
        }

        let waitedMs = max(0, Int(Date().timeIntervalSince(waitStart) * 1000))
        totalWaitMs += waitedMs
        waitSamples += 1
        maxObservedWaitMs = max(maxObservedWaitMs, waitedMs)
    }
    
    func releaseSlot() {
        activeRequests -= 1
        
        if !waitingTasks.isEmpty && activeRequests < maxConcurrent {
            let continuation = waitingTasks.removeFirst()
            activeRequests += 1
            continuation.resume()
        }
    }

    func getStats() -> Stats {
        let average = waitSamples > 0 ? (totalWaitMs / waitSamples) : 0
        return Stats(
            activeRequests: activeRequests,
            queuedRequests: waitingTasks.count,
            maxConcurrent: maxConcurrent,
            saturationEvents: saturationEvents,
            averageWaitMs: average,
            maxWaitMs: maxObservedWaitMs
        )
    }
}

actor RecordingCoordinator {
    struct Stats {
        let activeRecordings: Int
        let queuedRecordings: Int
        let maxConcurrent: Int
    }

    struct QueueSnapshot {
        let activeUsernames: [String]
        let waitingUsernames: [String]
        let maxConcurrent: Int
        let recordingEnabled: Bool
        let isManualHoldEnabled: Bool
    }

    private struct WaitingTask {
        let username: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var activeRecordings: Int = 0
    private var activeCountsByUsername: [String: Int] = [:]
    private var maxConcurrent: Int
    private var recordingEnabled: Bool = true
    private var isManualHoldEnabled: Bool = false
    private var waitingTasks: [WaitingTask] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    private var isUnlimited: Bool {
        maxConcurrent <= 0
    }

    private func resumeWaitingTasksIfPossible() {
        guard recordingEnabled, !isManualHoldEnabled else { return }

        if isUnlimited {
            while !waitingTasks.isEmpty {
                let waitingTask = waitingTasks.removeFirst()
                activeRecordings += 1
                activeCountsByUsername[waitingTask.username, default: 0] += 1
                waitingTask.continuation.resume(returning: true)
            }
            return
        }

        while activeRecordings < maxConcurrent && !waitingTasks.isEmpty {
            let waitingTask = waitingTasks.removeFirst()
            activeRecordings += 1
            activeCountsByUsername[waitingTask.username, default: 0] += 1
            waitingTask.continuation.resume(returning: true)
        }
    }

    func updateMaxConcurrent(_ max: Int) {
        maxConcurrent = max
        resumeWaitingTasksIfPossible()
    }

    func setRecordingEnabled(_ enabled: Bool) {
        recordingEnabled = enabled
        resumeWaitingTasksIfPossible()
    }

    func setManualQueueHold(_ enabled: Bool) {
        isManualHoldEnabled = enabled
        resumeWaitingTasksIfPossible()
    }

    func acquireSlot(for username: String) async -> Bool {
        if recordingEnabled && !isManualHoldEnabled && (isUnlimited || activeRecordings < maxConcurrent) {
            activeRecordings += 1
            activeCountsByUsername[username, default: 0] += 1
            return true
        }

        return await withCheckedContinuation { continuation in
            waitingTasks.append(WaitingTask(username: username, continuation: continuation))
        }
    }

    func cancelPendingSlotRequest(for username: String) {
        guard !waitingTasks.isEmpty else { return }

        var remaining: [WaitingTask] = []
        remaining.reserveCapacity(waitingTasks.count)

        for waitingTask in waitingTasks {
            if waitingTask.username == username {
                waitingTask.continuation.resume(returning: false)
            } else {
                remaining.append(waitingTask)
            }
        }

        waitingTasks = remaining
    }

    func releaseSlot(for username: String) {
        if activeRecordings > 0 {
            activeRecordings -= 1
        }
        if let count = activeCountsByUsername[username] {
            if count <= 1 {
                activeCountsByUsername.removeValue(forKey: username)
            } else {
                activeCountsByUsername[username] = count - 1
            }
        }
        resumeWaitingTasksIfPossible()
    }

    func reorderWaitingQueue(usernames: [String]) {
        guard waitingTasks.count > 1 else { return }

        var remaining = waitingTasks
        var reordered: [WaitingTask] = []

        for username in usernames {
            if let index = remaining.firstIndex(where: { $0.username == username }) {
                reordered.append(remaining.remove(at: index))
            }
        }

        if !remaining.isEmpty {
            reordered.append(contentsOf: remaining)
        }

        waitingTasks = reordered
    }

    func getQueueSnapshot() -> QueueSnapshot {
        QueueSnapshot(
            activeUsernames: activeCountsByUsername
                .sorted { $0.key < $1.key }
                .map(\.key),
            waitingUsernames: waitingTasks.map { $0.username },
            maxConcurrent: maxConcurrent,
            recordingEnabled: recordingEnabled,
            isManualHoldEnabled: isManualHoldEnabled
        )
    }

    func getStats() -> Stats {
        Stats(
            activeRecordings: activeRecordings,
            queuedRecordings: waitingTasks.count,
            maxConcurrent: maxConcurrent
        )
    }
}

@MainActor
class ChannelManager: ObservableObject {
    @Published var channels: [String: Channel] = [:]
    @Published var appConfig = AppConfig()
    @Published var runtimeDiagnostics: RuntimeDiagnostics = .empty
    @Published var isHydratingChannels: Bool = true
    
    var channelCount: Int {
        channels.count
    }
    
    private let configURL: URL
    private let appConfigURL: URL
    private var pausedStatusCheckTask: Task<Void, Never>?
    private var offlineThumbnailBackfillTask: Task<Void, Never>?
    private var bioBackfillTask: Task<Void, Never>?
    private var pausedProbeIndex: Int = 0
    private var thumbnailBackfillIndex: Int = 0
    private var bioBackfillIndex: Int = 0
    private let requestCoordinator: RequestCoordinator
    private let recordingCoordinator: RecordingCoordinator
    private var webServer: WebServer?
    private var webServerActivePort: Int = 0
    private var isShuttingDown = false

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = appSupport.appendingPathComponent("ChaturbateDVR")
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        configURL = appFolder.appendingPathComponent("channels.json")
        appConfigURL = appFolder.appendingPathComponent("appconfig.json")
        
        // Initialize with default, will update after loading config
        requestCoordinator = RequestCoordinator(maxConcurrent: 6)
        recordingCoordinator = RecordingCoordinator(maxConcurrent: 0)
        
        loadAppConfig()
        
        // Update with actual config value
        Task {
            await requestCoordinator.updateMaxConcurrent(appConfig.maxConcurrentRequests)
            await recordingCoordinator.updateMaxConcurrent(appConfig.maxConcurrentRecordings)
            await recordingCoordinator.setRecordingEnabled(appConfig.recordingEnabled)
        }
        
        loadConfig()
        startPausedStatusChecks()
        startOfflineThumbnailBackfill()
        // Bio backfill is manual via on-demand refresh controls in Add Channel and Settings
        // startBioBackfill()

        if appConfig.webServerEnabled {
            startWebServer()
        }

        Task {
            await FileLogger.shared.log("[manager] initialized")
        }
    }

    deinit {
        pausedStatusCheckTask?.cancel()
        offlineThumbnailBackfillTask?.cancel()
        bioBackfillTask?.cancel()
        webServer?.stop()
    }

    func shutdownForTermination() async {
        if isShuttingDown { return }
        isShuttingDown = true

        await FileLogger.shared.log("[manager] graceful shutdown started")

        pausedStatusCheckTask?.cancel()
        pausedStatusCheckTask = nil
        offlineThumbnailBackfillTask?.cancel()
        offlineThumbnailBackfillTask = nil
        bioBackfillTask?.cancel()
        bioBackfillTask = nil

        stopWebServer()

        for (_, channel) in channels {
            await channel.shutdownForTermination()
        }

        await FileLogger.shared.log("[manager] waiting for mp4 finalization jobs")
        await Channel.waitForMP4FinalizationToComplete()

        await saveConfig()
        await FileLogger.shared.log("[manager] graceful shutdown complete")
    }
    
    private func loadAppConfig() {
        if let data = try? Data(contentsOf: appConfigURL),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            appConfig = config
            Task {
                await FileLogger.shared.log("[manager] loaded app config")
            }
        } else {
            Task {
                await FileLogger.shared.log("[manager] using default app config (no saved config found)")
            }
        }
    }
    
    func saveAppConfig() {
        let appConfigSnapshot = appConfig
        let appConfigURL = self.appConfigURL

        // Perform disk I/O on a background queue to avoid blocking the web server
        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try JSONEncoder().encode(appConfigSnapshot)
                try data.write(to: appConfigURL)
                Task {
                    await FileLogger.shared.log("[manager] saved app config")
                }
            } catch {
                Task {
                    await FileLogger.shared.log("[manager] failed to save app config: \(error.localizedDescription)", level: "WARN")
                }
            }
        }
        
        Task {
            await requestCoordinator.updateMaxConcurrent(appConfig.maxConcurrentRequests)
            await self.recordingCoordinator.updateMaxConcurrent(appConfig.maxConcurrentRecordings)
            await self.recordingCoordinator.setRecordingEnabled(appConfig.recordingEnabled)

            let recordingsCap = appConfig.maxConcurrentRecordings == 0 ? "unlimited" : String(appConfig.maxConcurrentRecordings)
            await FileLogger.shared.log("[manager] updated max concurrent recordings to \(recordingsCap)")
            await FileLogger.shared.log("[manager] recording \(appConfig.recordingEnabled ? "enabled" : "disabled")")
            
            for (_, channel) in channels {
                await channel.updateAppConfig(appConfig)
            }
            await FileLogger.shared.log("[manager] updated max concurrent requests to \(appConfig.maxConcurrentRequests)")
            await FileLogger.shared.log("[manager] updated break detection settings: static=\(appConfig.breakStaticThresholdMinutes)m no_person=\(appConfig.breakNoPersonNoMotionThresholdMinutes)m analysis=\(appConfig.breakAnalysisIntervalSeconds)s")
        }

        if appConfig.webServerEnabled {
            startWebServer()
        } else {
            stopWebServer()
        }
    }
    
    func createChannel(config: ChannelConfig) async throws {
        await FileLogger.shared.log("[manager] create channel requested", channel: config.username)

        guard channels[config.username] == nil else {
            await FileLogger.shared.log("[manager] create channel rejected: already exists", channel: config.username, level: "WARN")
            throw ChaturbateError.networkError("Channel \(config.username) already exists")
        }

        // Validate channel existence (404 means it was deleted/never existed).
        let validator = ChaturbateClient(config: appConfig)
        do {
            try await validator.validateChannel(username: config.username)
        } catch ChaturbateError.invalidChannel {
            await FileLogger.shared.log("[manager] create channel rejected: invalid/404", channel: config.username, level: "WARN")
            throw ChaturbateError.invalidChannel
        } catch {
            // Do not block create on temporary/network/offline/private errors.
            await FileLogger.shared.log("[manager] channel validation non-fatal error: \(error.localizedDescription)", channel: config.username, level: "WARN")
        }
        
        let channel = Channel(
            config: config,
            appConfig: appConfig,
            requestCoordinator: requestCoordinator,
            recordingCoordinator: recordingCoordinator
        )
        channels[config.username] = channel
        
        // Save immediately
        await saveConfig()
        
        if !config.isPaused {
            await channel.resume()
        }

        await FileLogger.shared.log("[manager] channel created", channel: config.username)
        
        // Fetch bio metadata asynchronously (non-blocking)
        let username = config.username
        Task {
            await self.refreshBioMetadata(username: username)
        }
    }
    
    func pauseChannel(username: String) async {
        guard let channel = channels[username] else { return }
        await channel.pause()

        // Prioritize freshly paused channels so paused-live/offline state
        // resolves quickly and list placement stays accurate.
        Task {
            await channel.refreshPausedOnlineStatus(bypassRateLimit: true)
        }

        await saveConfig()
        await FileLogger.shared.log("[manager] channel paused", channel: username)
    }
    
    func resumeChannel(username: String) async {
        guard let channel = channels[username] else { return }
        await channel.resume()
        await saveConfig()
        await FileLogger.shared.log("[manager] channel resumed", channel: username)
    }
    
    func updateChannel(username: String, newConfig: ChannelConfig) async throws -> String {
        guard let channel = channels[username] else {
            await FileLogger.shared.log("[manager] update channel failed: not found", channel: username, level: "WARN")
            throw ChaturbateError.networkError("Channel \(username) not found")
        }

        let targetUsername = sanitizeUsername(newConfig.username)
        guard !targetUsername.isEmpty else {
            throw ChaturbateError.networkError("Username cannot be empty")
        }

        let shouldRename = targetUsername != username

        if shouldRename {
            if channels[targetUsername] != nil {
                throw ChaturbateError.networkError("Channel \(targetUsername) already exists")
            }

            let info = await channel.getInfo()
            if info.isOnline && !info.isPaused {
                throw ChaturbateError.networkError("Cannot rename while recording. Pause the channel first")
            }

            let validator = ChaturbateClient(config: appConfig)
            do {
                try await validator.validateChannel(username: targetUsername)
            } catch ChaturbateError.invalidChannel {
                throw ChaturbateError.invalidChannel
            } catch {
                // Do not block rename on temporary network/offline/private errors.
            }
        }

        let updatedConfig = ChannelConfig(
            isPaused: newConfig.isPaused,
            username: targetUsername,
            outputDirectory: newConfig.outputDirectory,
            framerate: newConfig.framerate,
            resolution: newConfig.resolution,
            pattern: newConfig.pattern,
            maxDuration: newConfig.maxDuration,
            maxFilesize: newConfig.maxFilesize,
            maxSessionDuration: newConfig.maxSessionDuration,
            maxSessionFilesize: newConfig.maxSessionFilesize,
            createdAt: newConfig.createdAt,
            lastOnlineAt: newConfig.lastOnlineAt,
            recordingHistory: newConfig.recordingHistory,
            isInvalid: newConfig.isInvalid
        )
        
        await channel.updateConfig(updatedConfig)

        if shouldRename {
            await channel.renameUsername(to: targetUsername)
            channels.removeValue(forKey: username)
            channels[targetUsername] = channel
            await FileLogger.shared.log("[manager] channel renamed from \(username) to \(targetUsername)", channel: targetUsername)
        }

        await saveConfig()
        await FileLogger.shared.log("[manager] channel config updated", channel: targetUsername)
        return targetUsername
    }

    private func sanitizeUsername(_ username: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return username
            .components(separatedBy: allowed.inverted)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func getChannelConfig(username: String) async -> ChannelConfig? {
        guard let channel = channels[username] else { return nil }
        return await channel.config
    }
    
    func deleteChannel(username: String) async {
        guard let channel = channels[username] else { return }
        await channel.stopForDeletion()
        channels.removeValue(forKey: username)
        await saveConfig()
        await FileLogger.shared.log("[manager] channel deleted", channel: username)
    }
    
    func getChannelInfo(username: String) async -> ChannelInfo? {
        guard let channel = channels[username] else { return nil }
        return await channel.getInfo()
    }
    
    func getAllChannelInfo() async -> [ChannelInfo] {
        var infos: [ChannelInfo] = []
        for (_, channel) in channels {
            infos.append(await channel.getInfo())
        }

        let queueSnapshot = await getRecordingQueueSnapshot()
        let waitingQueueOrder: [String: Int] = Dictionary(
            uniqueKeysWithValues: queueSnapshot.waitingUsernames.enumerated().map { ($0.element, $0.offset) }
        )

        func sortPriority(for info: ChannelInfo) -> Int {
            // Requested order:
            // 0: recording, 1: waiting for recording slot, 2: paused but online,
            // 3: offline, 4: paused (offline)
            if info.isOnline && !info.isPaused && !info.isWaitingForRecordingSlot { return 0 }
            if info.isWaitingForRecordingSlot { return 1 }
            if info.isOnline && info.isPaused { return 2 }
            if !info.isOnline && !info.isPaused { return 3 }
            return 4
        }

        let sortedInfos = infos.sorted { lhs, rhs in
            let lhsPriority = sortPriority(for: lhs)
            let rhsPriority = sortPriority(for: rhs)

            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }

            // Waiting channels should follow real queue order first.
            if lhsPriority == 1 {
                let lhsQueueIndex = waitingQueueOrder[lhs.username] ?? Int.max
                let rhsQueueIndex = waitingQueueOrder[rhs.username] ?? Int.max
                if lhsQueueIndex != rhsQueueIndex {
                    return lhsQueueIndex < rhsQueueIndex
                }
            }

            // More recently online channels should appear first.
            let lhsLastOnline = lhs.lastOnlineAtUnix ?? 0
            let rhsLastOnline = rhs.lastOnlineAtUnix ?? 0
            if lhsLastOnline != rhsLastOnline {
                return lhsLastOnline > rhsLastOnline
            }

            // Stable final tie-breaker.
            return lhs.username.lowercased() < rhs.username.lowercased()
        }

        let coordinatorStats = await requestCoordinator.getStats()
        let recordingStats = await recordingCoordinator.getStats()
        runtimeDiagnostics = RuntimeDiagnostics(
            activeRequests: coordinatorStats.activeRequests,
            queuedRequests: coordinatorStats.queuedRequests,
            maxConcurrentRequests: coordinatorStats.maxConcurrent,
            requestQueueSaturated: coordinatorStats.queuedRequests > 0,
            averageQueueWaitMs: coordinatorStats.averageWaitMs,
            maxQueueWaitMs: coordinatorStats.maxWaitMs,
            checkingChannels: sortedInfos.filter { $0.isChecking }.count,
            degradedChannels: sortedInfos.filter { $0.consecutiveSegmentFailures > 0 }.count,
            cloudflareBlockedChannels: sortedInfos.filter { $0.cloudflareBlockCount > 0 }.count,
            activeRecordings: recordingStats.activeRecordings,
            queuedRecordings: recordingStats.queuedRecordings,
            maxConcurrentRecordings: recordingStats.maxConcurrent
        )

        return sortedInfos
    }

    func setManualRecordingQueueHold(_ enabled: Bool) async {
        await recordingCoordinator.setManualQueueHold(enabled)
        await FileLogger.shared.log("[manager] manual recording queue hold \(enabled ? "enabled" : "disabled")")
    }

    func getRecordingQueueSnapshot() async -> RecordingCoordinator.QueueSnapshot {
        let rawSnapshot = await recordingCoordinator.getQueueSnapshot()
        var validWaitingUsernames: [String] = []

        for username in rawSnapshot.waitingUsernames {
            guard let channel = channels[username] else { continue }
            let info = await channel.getInfo()
            guard info.isOnline,
                  info.isWaitingForRecordingSlot,
                  !info.isPaused,
                  !info.isInvalid else {
                continue
            }
            validWaitingUsernames.append(username)
        }

        return RecordingCoordinator.QueueSnapshot(
            activeUsernames: rawSnapshot.activeUsernames,
            waitingUsernames: validWaitingUsernames,
            maxConcurrent: rawSnapshot.maxConcurrent,
            recordingEnabled: rawSnapshot.recordingEnabled,
            isManualHoldEnabled: rawSnapshot.isManualHoldEnabled
        )
    }

    func applyManualRecordingQueue(
        waitingOrder: [String],
        rotateOutRecordings: [String],
        releaseHoldAfterApply: Bool
    ) async {
        await recordingCoordinator.reorderWaitingQueue(usernames: waitingOrder)

        for username in rotateOutRecordings {
            guard let channel = channels[username] else { continue }
            await channel.pause()
            await channel.resume()
            await FileLogger.shared.log("[manager] rotated recording slot for manual queue apply", channel: username)
        }

        if releaseHoldAfterApply {
            await recordingCoordinator.setManualQueueHold(false)
        }
        await FileLogger.shared.log("[manager] applied manual recording queue plan")
    }

    func openRecordingFolder(username: String) async {
        guard let channel = channels[username] else { return }
        let folderPath = await channel.getRecordingFolderPath()
        NSWorkspace.shared.open(URL(fileURLWithPath: folderPath))
        await FileLogger.shared.log("[manager] opened recording folder: \(folderPath)", channel: username)
    }

    func openChannelPage(username: String) {
        guard let url = URL(string: "https://chaturbate.com/\(username)") else { return }

        Task {
            await FileLogger.shared.log("[manager] opening channel page", channel: username)
        }

        let browser = appConfig.selectedBrowser
        if browser != .none,
           let bundleId = browser.bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, _ in }
            return
        }

        NSWorkspace.shared.open(url)
    }

    func importFollowedChannels() async throws -> (imported: Int, skipped: Int) {
        let preview = try await prepareFollowedImport()
        return await importFollowedChannelsFromPreview(preview)
    }

    func prepareFollowedImport(progress: (@Sendable (String) -> Void)? = nil) async throws -> FollowedImportPreview {
        await FileLogger.shared.log("[manager] import followed cams preview started")

        let client = ChaturbateClient(config: appConfig)
        let usernames: [String]
        do {
            usernames = try await client.getFollowedUsernames(progress: progress)
        } catch {
            await FileLogger.shared.log("[manager] import followed cams preview failed: \(error.localizedDescription)", level: "WARN")
            throw error
        }

        let existingLower = Set(channels.keys.map { $0.lowercased() })
        var existing: [String] = []
        var toAdd: [String] = []

        for username in usernames {
            if existingLower.contains(username.lowercased()) {
                existing.append(username)
            } else {
                toAdd.append(username)
            }
        }

        let preview = FollowedImportPreview(found: usernames, existing: existing, toAdd: toAdd)
        await FileLogger.shared.log("[manager] import followed cams preview complete: found=\(preview.found.count), to_add=\(preview.toAdd.count), existing=\(preview.existing.count)")
        return preview
    }

    func importFollowedChannelsFromPreview(_ preview: FollowedImportPreview) async -> (imported: Int, skipped: Int) {
        await FileLogger.shared.log("[manager] import followed cams apply started: requested=\(preview.toAdd.count)")

        var imported = 0
        var skipped = preview.existing.count
        var importedChannels: [Channel] = []

        for username in preview.toAdd {
            let usernameLower = username.lowercased()
            if channels.keys.contains(where: { $0.lowercased() == usernameLower }) {
                skipped += 1
                continue
            }

            let config = ChannelConfig(
                isPaused: true,
                username: username,
                outputDirectory: appConfig.outputDirectory,
                framerate: appConfig.framerate,
                resolution: appConfig.resolution,
                pattern: appConfig.pattern,
                maxDuration: appConfig.maxDuration,
                maxFilesize: appConfig.maxFilesize
            )

            if channels[config.username] != nil {
                skipped += 1
                continue
            }

            let channel = Channel(
                config: config,
                appConfig: appConfig,
                requestCoordinator: requestCoordinator,
                recordingCoordinator: recordingCoordinator
            )
            channels[config.username] = channel
            importedChannels.append(channel)
            imported += 1
        }

        if imported > 0 {
            await saveConfig()

            let channelsToProbe = importedChannels
            Task.detached(priority: .utility) {
                await FileLogger.shared.log("[manager] import followed cams post-check started: channels=\(channelsToProbe.count)")

                // Run an initial probe for newly imported paused channels so online status
                // appears promptly instead of waiting for the round-robin timer.
                await withTaskGroup(of: Void.self) { group in
                    for channel in channelsToProbe {
                        group.addTask {
                            await channel.refreshPausedOnlineStatus(bypassRateLimit: true)
                        }
                    }
                }

                await FileLogger.shared.log("[manager] import followed cams post-check complete")
            }
        }

        await FileLogger.shared.log("[manager] import followed cams apply complete: imported=\(imported), skipped=\(skipped)")
        return (imported, skipped)
    }

    func importChannelsFromFolders(parentDirectory: String) async -> (imported: Int, skipped: Int) {
        let root = (parentDirectory as NSString).expandingTildeInPath
        var imported = 0
        var skipped = 0

        await FileLogger.shared.log("[manager] import from folders started: \(root)")

        guard let children = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }

        let sortedFolders = children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }

        for folder in sortedFolders {
            let folderName = folder.lastPathComponent
            let username = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
            if username.isEmpty {
                skipped += 1
                continue
            }

            let usernameLower = username.lowercased()
            if channels.keys.contains(where: { $0.lowercased() == usernameLower }) {
                skipped += 1
                continue
            }

            guard folderContainsVideoFiles(folder.path) else {
                skipped += 1
                continue
            }

            let config = ChannelConfig(
                isPaused: true,
                username: username,
                outputDirectory: root,
                framerate: appConfig.framerate,
                resolution: appConfig.resolution,
                pattern: appConfig.pattern,
                maxDuration: appConfig.maxDuration,
                maxFilesize: appConfig.maxFilesize
            )

            if channels[config.username] != nil {
                skipped += 1
                continue
            }

            let channel = Channel(
                config: config,
                appConfig: appConfig,
                requestCoordinator: requestCoordinator,
                recordingCoordinator: recordingCoordinator
            )
            channels[config.username] = channel
            imported += 1
        }

        if imported > 0 {
            await saveConfig()
        }

        await FileLogger.shared.log("[manager] import complete: imported=\(imported), skipped=\(skipped)")

        return (imported, skipped)
    }

    private func folderContainsVideoFiles(_ path: String) -> Bool {
        guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return false
        }

        for file in fileNames {
            let lower = file.lowercased()
            if lower.hasSuffix(".ts") || lower.hasSuffix(".mp4") || lower.hasSuffix(".mkv") || lower.hasSuffix(".mov") {
                return true
            }
        }

        return false
    }
    
    private func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let configs = try? JSONDecoder().decode([ChannelConfig].self, from: data) else {
            isHydratingChannels = false
            Task {
                await FileLogger.shared.log("[manager] no saved channels config found")
            }
            return
        }

        Task {
            await FileLogger.shared.log("[manager] loaded channels config (\(configs.count) channels)")
        }
        
        Task {
            // Separate unpaused and paused channels
            var unpausedChannels: [Channel] = []
            var pausedChannels: [Channel] = []

            // Populate all channels first so UI list renders immediately.
            for config in configs {
                let channel = Channel(
                    config: config,
                    appConfig: appConfig,
                    requestCoordinator: requestCoordinator,
                    recordingCoordinator: recordingCoordinator
                )
                channels[config.username] = channel
                
                if !config.isPaused {
                    unpausedChannels.append(channel)
                } else {
                    pausedChannels.append(channel)
                }
            }

            // Mark initial hydration complete once channels are loaded into memory.
            isHydratingChannels = false

            // Priority 1: On launch, detect paused-online channels first.
            // Use bounded concurrency and bypass normal rate limiting so the UI
            // surfaces online paused channels quickly after startup.
            await runStartupPausedSweep(pausedChannels)

            // Priority 2: Start unpaused channels after paused-online detection pass.
            for (index, channel) in unpausedChannels.enumerated() {
                if index > 0 {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms between channels
                }
                await channel.resume()
            }
        }
    }

    private func runStartupPausedSweep(_ pausedChannels: [Channel]) async {
        guard !pausedChannels.isEmpty else { return }

        // Bounded parallelism avoids request bursts while still prioritizing startup detection.
        let batchSize = 12
        await FileLogger.shared.log("[manager] startup paused sweep started: channels=\(pausedChannels.count), batch=\(batchSize)")

        var index = 0
        while index < pausedChannels.count {
            let end = min(index + batchSize, pausedChannels.count)
            let batch = Array(pausedChannels[index..<end])

            await withTaskGroup(of: Void.self) { group in
                for channel in batch {
                    group.addTask {
                        await channel.refreshPausedOnlineStatus(bypassRateLimit: true)
                    }
                }
            }

            index = end
        }

        await FileLogger.shared.log("[manager] startup paused sweep complete")
    }
    
    private func saveConfig() async {
        let configs = await getAllChannelConfigs()
        do {
            let data = try JSONEncoder().encode(configs)
            try data.write(to: configURL)
            await FileLogger.shared.log("[manager] saved channels config (\(configs.count) channels)")
        } catch {
            await FileLogger.shared.log("[manager] failed to save channels config: \(error.localizedDescription)", level: "WARN")
        }
    }
    
    private func getAllChannelConfigs() async -> [ChannelConfig] {
        var configs: [ChannelConfig] = []
        for (_, channel) in channels {
            let config = await channel.config
            configs.append(config)
        }
        return configs
    }

    func refreshBioMetadata(username: String) async {
        guard let channel = channels[username] else { return }
        
        await FileLogger.shared.log("[manager] fetching bio metadata for channel", channel: username)
        
        let client = ChaturbateClient(config: appConfig)
        do {
            var bioMetadata = try await client.getBioMetadata(username: username)
            var config = await channel.config
            let existingBio = config.bioMetadata

            // Preserve previously known values when a refresh returns placeholders or partial data.
            if bioMetadata.gender == nil { bioMetadata.gender = existingBio?.gender }
            if bioMetadata.followers == nil { bioMetadata.followers = existingBio?.followers }
            if bioMetadata.location == nil { bioMetadata.location = existingBio?.location }
            if bioMetadata.body == nil { bioMetadata.body = existingBio?.body }
            if bioMetadata.language == nil { bioMetadata.language = existingBio?.language }

            config.bioMetadata = bioMetadata
            await channel.updateConfig(config)
            await saveConfig()
            let genderStr = bioMetadata.gender ?? "unknown"
            await FileLogger.shared.log("[manager] bio metadata updated: gender=\(genderStr)", channel: username)
        } catch {
            await FileLogger.shared.log("[manager] failed to fetch bio metadata: \(error.localizedDescription)", channel: username, level: "WARN")
        }
    }

    func backfillAllChannelsBioMetadata(progress: @escaping (BioBackfillProgress) -> Void) async throws {
        let channelList = Array(channels.keys).sorted()
        await FileLogger.shared.log("[manager] starting bio metadata backfill for all \(channelList.count) channels")
        
        for (index, username) in channelList.enumerated() {
            try Task.checkCancellation()
            progress(BioBackfillProgress(completed: index, total: channelList.count, currentChannel: username))
            await refreshBioMetadata(username: username)
            
            // Small delay between requests to avoid overwhelming the server
            try await Task.sleep(nanoseconds: 2 * 1_000_000_000) // 2 seconds
        }
        
        progress(BioBackfillProgress(completed: channelList.count, total: channelList.count, currentChannel: ""))
        await FileLogger.shared.log("[manager] bio metadata backfill complete for all channels")
    }

    private func startPausedStatusChecks() {
        pausedStatusCheckTask?.cancel()
        Task {
            await FileLogger.shared.log("[manager] started paused status checks")
        }
        pausedStatusCheckTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                // Probe multiple paused channels per cycle so large imports
                // don't take an hour+ to get an initial online flag.
                await self.checkPausedChannelStatusBatch(maxChecks: 3)
                try? await Task.sleep(nanoseconds: 6 * 1_000_000_000)
            }
        }
    }

    private func startOfflineThumbnailBackfill() {
        offlineThumbnailBackfillTask?.cancel()
        Task {
            await FileLogger.shared.log("[manager] started offline thumbnail backfill")
        }
        offlineThumbnailBackfillTask = Task { [weak self] in
            guard let self else { return }

            // Avoid startup I/O spikes: wait a bit before first backfill pass.
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)

            while !Task.isCancelled {
                await FileLogger.shared.logBackfillCycleStart()
                await self.backfillOneOfflineThumbnail()
                await FileLogger.shared.logBackfillCycleEnd()
                // One channel at a time keeps disk usage smooth on large libraries.
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            }
        }
    }

    private func backfillOneOfflineThumbnail() async {
        var candidates: [(String, Channel)] = []

        for (username, channel) in channels {
            let info = await channel.getInfo()
            if !info.isOnline, info.thumbnailPath == nil {
                candidates.append((username, channel))
            }
        }

        guard !candidates.isEmpty else { return }

        candidates.sort { lhs, rhs in
            lhs.0.lowercased() < rhs.0.lowercased()
        }

        if thumbnailBackfillIndex >= candidates.count {
            thumbnailBackfillIndex = 0
        }

        let (username, channel) = candidates[thumbnailBackfillIndex]
        thumbnailBackfillIndex = (thumbnailBackfillIndex + 1) % candidates.count
        await FileLogger.shared.log("Thumbnail backfill: selected candidate from offline queue", channel: username)
        
        // Timeout per channel: 30 seconds max so one slow channel doesn't block others
        let timeoutNanos: UInt64 = 30 * 1_000_000_000
        
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    await channel.backfillOfflineThumbnailIfNeeded()
                }
                
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanos)
                    throw TimeoutError()
                }
                
                // Wait for first result (either completion or timeout)
                while let _ = try await group.next() {
                    group.cancelAll()
                    break
                }
            }
        } catch {
            if error is TimeoutError {
                await channel.addLogFromManager("Thumbnail generation timed out after 30 seconds, moving to next channel")
                await FileLogger.shared.logThumbnailTimeout(channel: await channel.config.username)
            } else {
                await channel.addLogFromManager("Thumbnail generation failed during background backfill: \(error.localizedDescription)")
                await FileLogger.shared.log("Thumbnail backfill: unexpected error - \(error.localizedDescription)", channel: username, level: "WARN")
            }
        }
    }

    private func startBioBackfill() {
        bioBackfillTask?.cancel()
        Task {
            await FileLogger.shared.log("[manager] started bio metadata backfill")
        }
        bioBackfillTask = Task { [weak self] in
            guard let self else { return }

            // Wait a bit before starting bio backfill to avoid startup resource contention
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)

            while !Task.isCancelled {
                await self.backfillOneBioMetadata()
                // One channel at a time to avoid overwhelming the network
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    private func backfillOneBioMetadata() async {
        var candidates: [(String, Channel)] = []

        for (username, channel) in channels {
            let config = await channel.config
            // Only backfill if bio metadata doesn't exist or is too old (>90 days)
            let shouldBackfill: Bool
            if let lastRefresh = config.bioMetadata?.lastBioRefresh {
                let daysSinceRefresh = (Int64(Date().timeIntervalSince1970) - lastRefresh) / (24 * 3600)
                shouldBackfill = daysSinceRefresh > 90
            } else {
                shouldBackfill = true
            }
            
            if shouldBackfill {
                candidates.append((username, channel))
            }
        }

        guard !candidates.isEmpty else { return }

        // Round-robin to give all channels a fair chance
        let (username, _) = candidates[bioBackfillIndex % candidates.count]
        bioBackfillIndex = (bioBackfillIndex + 1) % candidates.count

        await refreshBioMetadata(username: username)
    }

    private func checkPausedChannelStatusBatch(maxChecks: Int) async {
        guard maxChecks > 0 else { return }

        var pausedChannels: [(String, Channel)] = []

        for (username, channel) in channels {
            if await channel.config.isPaused {
                pausedChannels.append((username, channel))
            }
        }

        guard !pausedChannels.isEmpty else { return }

        pausedChannels.sort { lhs, rhs in
            lhs.0.lowercased() < rhs.0.lowercased()
        }

        if pausedProbeIndex >= pausedChannels.count {
            pausedProbeIndex = 0
        }

        let checksToRun = min(maxChecks, pausedChannels.count)
        var channelsToCheck: [Channel] = []
        channelsToCheck.reserveCapacity(checksToRun)

        for _ in 0..<checksToRun {
            let (_, channel) = pausedChannels[pausedProbeIndex]
            pausedProbeIndex = (pausedProbeIndex + 1) % pausedChannels.count
            channelsToCheck.append(channel)
        }

        await withTaskGroup(of: Void.self) { group in
            for channel in channelsToCheck {
                group.addTask {
                    await channel.refreshPausedOnlineStatus()
                }
            }
        }
    }

    // MARK: - Embedded web server

    private func startWebServer() {
        let port = appConfig.webServerPort
        // Avoid redundant restart when port hasn't changed.
        if webServer != nil && webServerActivePort == port { return }

        webServer?.stop()
        webServer = nil
        webServerActivePort = 0

        let server = WebServer()

        server.getChannelInfos = { [weak self] in
            guard let self else { return [] }
            return await self.getAllChannelInfo()
        }
        server.pauseAction = { [weak self] username in
            guard let self else { return }
            await self.pauseChannel(username: username)
        }
        server.resumeAction = { [weak self] username in
            guard let self else { return }
            await self.resumeChannel(username: username)
        }
        server.getThumbnailPath = { [weak self] username in
            guard let self else { return nil }
            return await self.getChannelThumbnailPath(username: username)
        }
        server.getRecordingEnabled = { [weak self] in
            guard let self else { return true }
            return self.appConfig.recordingEnabled
        }
        server.setRecordingEnabled = { [weak self] enabled in
            guard let self else { return }
            self.appConfig.recordingEnabled = enabled
            self.saveAppConfig()
            await FileLogger.shared.log("[manager] recording globally \(enabled ? "enabled" : "disabled") via web interface")
        }

        do {
            try server.start(port: UInt16(port))
            webServer = server
            webServerActivePort = port
        } catch {
            Task { await FileLogger.shared.log("[webserver] start failed on port \(port): \(error)", level: "WARN") }
        }
    }

    private func stopWebServer() {
        guard webServer != nil else { return }
        webServer?.stop()
        webServer = nil
        webServerActivePort = 0
        Task { await FileLogger.shared.log("[webserver] stopped") }
    }

    func getChannelThumbnailPath(username: String) async -> String? {
        guard let channel = channels[username] else { return nil }
        return await channel.thumbnailPath
    }
}

private struct TimeoutError: Error {}
