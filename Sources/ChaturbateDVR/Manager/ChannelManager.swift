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

enum RecordingRepairState: Equatable {
    case pendingScan
    case scanning
    case good
    case needsRemux
    case queued
    case remuxing
    case repaired
    case failed(String)
    case unsupported
}

struct RecordingRepairSummary: Equatable {
    let pendingScan: Int
    let scanning: Int
    let good: Int
    let needsRemux: Int
    let queued: Int
    let remuxing: Int
    let repaired: Int
    let failed: Int

    static let empty = RecordingRepairSummary(
        pendingScan: 0,
        scanning: 0,
        good: 0,
        needsRemux: 0,
        queued: 0,
        remuxing: 0,
        repaired: 0,
        failed: 0
    )
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

    private func reconcileActiveRecordingCount() {
        let derivedActiveCount = activeCountsByUsername.values.reduce(0, +)
        if derivedActiveCount != activeRecordings {
            activeRecordings = max(derivedActiveCount, 0)
        }
    }

    private func resumeWaitingTasksIfPossible() {
        guard recordingEnabled, !isManualHoldEnabled else { return }

        // Keep totals consistent so stale counters cannot block queue wake-ups.
        reconcileActiveRecordingCount()

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
        reconcileActiveRecordingCount()
        return QueueSnapshot(
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
        reconcileActiveRecordingCount()
        return Stats(
            activeRecordings: activeRecordings,
            queuedRecordings: waitingTasks.count,
            maxConcurrent: maxConcurrent
        )
    }
}

@MainActor
class ChannelManager: ObservableObject {
    private static let thumbnailBackfillNoVideoCooldownSeconds: TimeInterval = 10 * 60

    private struct MP4RepairCandidate {
        let path: String
        let channelName: String
        let modifiedAt: Date
        let sizeBytes: Int64
    }

    private enum RecordingRepairAuditDecision {
        case good
        case optionalRemux
        case needsRemux
    }

    private struct RecordingAuditMetrics {
        /// nil means ffprobe was not available; duration-based checks are skipped.
        let formatDuration: Double?
        /// nil means ffprobe was not available or stream duration was unavailable.
        let videoDuration: Double?
        let fileSize: Int64
        let moovInHead: Bool
        let moofInHead: Bool
        let malformedBoxes: Bool
    }

    private struct HeadBoxFlags {
        let moovInHead: Bool
        let moofInHead: Bool
    }

    private struct RepairedRecordingIndexEntry: Codable {
        let sizeBytes: Int64
        let modifiedAtUnix: TimeInterval
    }

    private enum BackgroundWorker: String, CaseIterable {
        case pausedStatus = "Paused status checks"
        case thumbnailBackfill = "Offline thumbnail backfill"
        case ledgerMaintenance = "Recording ledger maintenance"

        var staleThresholdSeconds: TimeInterval {
            switch self {
            case .pausedStatus:
                return 120
            case .thumbnailBackfill:
                return 120
            case .ledgerMaintenance:
                return 8 * 60
            }
        }
    }

    private enum RecordingAuditCacheDecision: String, Codable {
        case good
        case optionalRemux
        case needsRemux
    }

    private struct RecordingAuditCacheEntry: Codable {
        let sizeBytes: Int64
        let modifiedAtUnix: TimeInterval
        let decision: RecordingAuditCacheDecision
    }

    @Published var channels: [String: Channel] = [:]
    @Published var appConfig = AppConfig()
    @Published var runtimeDiagnostics: RuntimeDiagnostics = .empty
    @Published var isHydratingChannels: Bool = true
    @Published var recordingRepairStates: [String: RecordingRepairState] = [:]
    @Published var recordingRepairSummary: RecordingRepairSummary = .empty
    @Published var isRepairingFlaggedRecordings: Bool = false
    @Published var isRecordingRepairScanActive: Bool = false
    @Published var recordingRepairScanDetail: String?
    @Published var backgroundWorkerWarnings: [String] = []
    
    var channelCount: Int {
        channels.count
    }
    
    private let configURL: URL
    private let appConfigURL: URL
    private let repairIndexURL: URL
    private let auditCacheURL: URL
    private let recordingLedgerBackfillMarkerURL: URL
    private var repairedRecordingIndex: [String: RepairedRecordingIndexEntry] = [:]
    private var auditCache: [String: RecordingAuditCacheEntry] = [:]
    private var pausedStatusCheckTask: Task<Void, Never>?
    private var offlineThumbnailBackfillTask: Task<Void, Never>?
    private var bioBackfillTask: Task<Void, Never>?
    private var recordingLedgerMaintenanceTask: Task<Void, Never>?
    private var mp4RepairTask: Task<Void, Never>?
    private var recordingRepairRunTask: Task<Void, Never>?
    private var backgroundWorkerWatchdogTask: Task<Void, Never>?
    private var recordingRepairRootPath: String?
    private var recordingRepairCurrentPath: String?
    private var recordingRepairStopAfterCurrentItem = false
    private var pausedProbeIndex: Int = 0
    private var lastPausedProbeDeferralLogAt: Date = .distantPast
    private var thumbnailBackfillIndex: Int = 0
    private var thumbnailBackfillCooldownUntil: [String: Date] = [:]
    private var bioBackfillIndex: Int = 0
    private let requestCoordinator: RequestCoordinator
    private let recordingCoordinator: RecordingCoordinator
    private let recordingLedger: RecordingLedger
    private var backgroundWorkerLastHeartbeat: [BackgroundWorker: Date] = [:]
    private var activeBackgroundWorkerAlerts: Set<BackgroundWorker> = []
    private var webServer: WebServer?
    private var webServerActivePort: Int = 0
    private var isShuttingDown = false

    var isAuthenticated: Bool {
        appConfig.isAuthenticated()
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = appSupport.appendingPathComponent("ChaturbateDVR")
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        configURL = appFolder.appendingPathComponent("channels.json")
        appConfigURL = appFolder.appendingPathComponent("appconfig.json")
        repairIndexURL = appFolder.appendingPathComponent("recording-repair-index.json")
        auditCacheURL = appFolder.appendingPathComponent("recording-audit-cache.json")
        recordingLedgerBackfillMarkerURL = appFolder.appendingPathComponent("recording-ledger-backfill.done")
        
        // Initialize with default, will update after loading config
        requestCoordinator = RequestCoordinator(maxConcurrent: 6)
        recordingCoordinator = RecordingCoordinator(maxConcurrent: 0)
        recordingLedger = RecordingLedger.shared

        Task {
            await recordingLedger.initialize(appFolder: appFolder)
        }
        
        loadAppConfig()
        loadRepairIndex()
        loadAuditCache()

        // Update with actual config value
        Task {
            await requestCoordinator.updateMaxConcurrent(appConfig.maxConcurrentRequests)
            await recordingCoordinator.updateMaxConcurrent(appConfig.maxConcurrentRecordings)
            await recordingCoordinator.setRecordingEnabled(appConfig.recordingEnabled)
        }
        
        loadConfig()
        startPausedStatusChecks()
        startOfflineThumbnailBackfill()
        startRecordingLedgerMaintenance()
        startBackgroundWorkerWatchdog()
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
        recordingLedgerMaintenanceTask?.cancel()
        mp4RepairTask?.cancel()
        recordingRepairRunTask?.cancel()
        backgroundWorkerWatchdogTask?.cancel()
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
        recordingLedgerMaintenanceTask?.cancel()
        recordingLedgerMaintenanceTask = nil
        backgroundWorkerWatchdogTask?.cancel()
        backgroundWorkerWatchdogTask = nil
        recordingRepairStopAfterCurrentItem = true

        stopWebServer()

        if let mp4RepairTask {
            await FileLogger.shared.log("[manager] waiting for recording repair scan to become idle")
            await mp4RepairTask.value
            self.mp4RepairTask = nil
        }

        if let recordingRepairRunTask {
            await FileLogger.shared.log("[manager] waiting for active recording repair run to become idle")
            await recordingRepairRunTask.value
            self.recordingRepairRunTask = nil
        }

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
                await FileLogger.shared.pruneOldLogs(keepingDays: config.logRetentionDays)
            }
        } else {
            Task {
                await FileLogger.shared.log("[manager] using default app config (no saved config found)")
                await FileLogger.shared.pruneOldLogs(keepingDays: AppConfig().logRetentionDays)
            }
        }
    }

    private func loadRepairIndex() {
        guard let data = try? Data(contentsOf: repairIndexURL),
              let decoded = try? JSONDecoder().decode([String: RepairedRecordingIndexEntry].self, from: data) else {
            repairedRecordingIndex = [:]
            return
        }
        repairedRecordingIndex = decoded
    }

    private func saveRepairIndex() {
        let snapshot = repairedRecordingIndex
        let destination = repairIndexURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: destination, options: .atomic)
            }
        }
    }

    private func loadAuditCache() {
        guard let data = try? Data(contentsOf: auditCacheURL),
              let decoded = try? JSONDecoder().decode([String: RecordingAuditCacheEntry].self, from: data) else {
            auditCache = [:]
            return
        }
        auditCache = decoded
    }

    private func saveAuditCache() {
        let snapshot = auditCache
        let destination = auditCacheURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: destination, options: .atomic)
            }
        }
    }

    /// Returns a cached decision if the file's size and modification date match the stored fingerprint.
    private func cachedAuditDecision(for candidate: MP4RepairCandidate) -> RecordingRepairAuditDecision? {
        guard let entry = auditCache[candidate.path] else { return nil }
        guard entry.sizeBytes == candidate.sizeBytes,
                            abs(candidate.modifiedAt.timeIntervalSince1970 - entry.modifiedAtUnix) < 2.0 else {
            return nil
        }
        switch entry.decision {
        case .good: return .good
        case .optionalRemux: return .optionalRemux
        case .needsRemux: return .needsRemux
        }
    }

    /// Stores an audit decision for a candidate so future scans can skip re-auditing.
    private func storeAuditDecision(_ decision: RecordingRepairAuditDecision, for candidate: MP4RepairCandidate) {
        let cacheDecision: RecordingAuditCacheDecision
        switch decision {
        case .good: cacheDecision = .good
        case .optionalRemux: cacheDecision = .optionalRemux
        case .needsRemux: cacheDecision = .needsRemux
        }
        auditCache[candidate.path] = RecordingAuditCacheEntry(
            sizeBytes: candidate.sizeBytes,
            modifiedAtUnix: candidate.modifiedAt.timeIntervalSince1970,
            decision: cacheDecision
        )

        // Persist incrementally so long-running scans survive relaunches.
        saveAuditCache()
    }

    func ensureRecordingRepairMaintenanceRunning() {
        let rootPath = appConfig.getOutputPath()

        if recordingRepairRootPath == rootPath,
           mp4RepairTask == nil,
           !recordingRepairStates.isEmpty {
            let hasUnresolvedStates = recordingRepairStates.values.contains { state in
                switch state {
                case .pendingScan, .scanning:
                    return true
                default:
                    return false
                }
            }

            if !hasUnresolvedStates {
                return
            }
        }

        if recordingRepairRootPath == rootPath, mp4RepairTask != nil {
            return
        }

        mp4RepairTask?.cancel()
        recordingRepairRootPath = rootPath
        recordingRepairCurrentPath = nil
        recordingRepairStopAfterCurrentItem = false
        recordingRepairStates.removeAll(keepingCapacity: false)
        recordingRepairSummary = .empty
        isRecordingRepairScanActive = true
        recordingRepairScanDetail = nil

        mp4RepairTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            let candidates = await Self.findAllMP4RepairCandidates(rootPath: rootPath)
            await self.prepareRecordingRepairState(candidates: candidates)

            guard !Task.isCancelled else {
                await self.finishRecordingRepairMaintenance()
                return
            }

            if candidates.isEmpty {
                await FileLogger.shared.log("[manager] no mp4 recordings found for repair maintenance")
                await self.finishRecordingRepairMaintenance()
                return
            }

            await FileLogger.shared.log("[manager] starting recording repair maintenance for \(candidates.count) mp4 file(s)")

            var remaining = candidates.count
            for candidate in candidates {
                let shouldStop = await self.shouldStopRecordingRepairAfterCurrentItem()
                if Task.isCancelled || shouldStop {
                    break
                }

                let existingState = await self.recordingRepairStateRaw(for: candidate.path)
                if existingState != .pendingScan {
                    remaining -= 1
                    continue
                }

                await self.setRecordingRepairScanDetail(candidate.path)

                var didAuditOnDisk = false

                if await self.isAlreadyRepaired(path: candidate.path) {
                    await self.setRecordingRepairState(.good, for: candidate.path)
                    remaining -= 1
                    await self.updateRecordingRepairSummary()
                    continue
                }

                // Use persistent audit cache to avoid re-probing unchanged files.
                if let cached = await self.cachedAuditDecision(for: candidate) {
                    switch cached {
                    case .good:
                        await self.setRecordingRepairState(.good, for: candidate.path)
                    case .optionalRemux, .needsRemux:
                        await self.setRecordingRepairState(.needsRemux, for: candidate.path)
                    }
                    remaining -= 1
                    await self.updateRecordingRepairSummary()
                    continue
                }

                await self.setRecordingRepairState(.scanning, for: candidate.path)
                let auditDecision = await Self.auditRecordingRepairCandidate(path: candidate.path)
                await self.storeAuditDecision(auditDecision, for: candidate)
                didAuditOnDisk = true

                switch auditDecision {
                case .good:
                    await self.setRecordingRepairState(.good, for: candidate.path)
                case .optionalRemux:
                    // Mirror audit-remux-candidates.sh semantics: fragmented head alone
                    // is optional, so surface it as a candidate but do not auto-remux.
                    await self.setRecordingRepairState(.needsRemux, for: candidate.path)
                case .needsRemux:
                    await self.setRecordingRepairState(.needsRemux, for: candidate.path)
                }

                remaining -= 1
                await self.updateRecordingRepairSummary()
                if didAuditOnDisk && remaining > 0 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }

            await self.finishRecordingRepairMaintenance()
            await self.saveAuditCache()
        }
    }

    func startRepairForFlaggedRecordings() {
        guard recordingRepairRunTask == nil else { return }

        let flaggedPaths = recordingRepairStates
            .filter { _, state in
                switch state {
                case .needsRemux, .failed:
                    return true
                default:
                    return false
                }
            }
            .map(\.key)

        guard !flaggedPaths.isEmpty else { return }

        let sortedPaths = flaggedPaths.sorted { lhs, rhs in
            let lhsDate = (try? URL(fileURLWithPath: lhs).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let rhsDate = (try? URL(fileURLWithPath: rhs).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            if lhsDate == rhsDate {
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            return lhsDate > rhsDate
        }

        recordingRepairStopAfterCurrentItem = false
        isRepairingFlaggedRecordings = true

        recordingRepairRunTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            for path in sortedPaths {
                let shouldStop = await self.shouldStopRecordingRepairAfterCurrentItem()
                if Task.isCancelled || shouldStop {
                    break
                }

                let currentState = await self.recordingRepairStateRaw(for: path)
                guard currentState == .needsRemux || {
                    if case .failed = currentState { return true }
                    return false
                }() else {
                    continue
                }

                await self.setRecordingRepairState(.queued, for: path)
                await self.setRecordingRepairCurrentPath(path)
                await self.setRecordingRepairState(.remuxing, for: path)

                let channelName = URL(fileURLWithPath: path)
                    .deletingLastPathComponent()
                    .lastPathComponent
                let repairFailure = await Channel.repairExistingMP4(path: path, channel: channelName)

                await self.setRecordingRepairCurrentPath(nil)
                if let repairFailure {
                    await self.setRecordingRepairState(.failed(repairFailure), for: path)
                } else {
                    await self.markRecordingAsRepaired(path: path)
                    await self.setRecordingRepairState(.repaired, for: path)
                }
            }

            await self.finishRecordingRepairRun()
        }
    }

    private static func findAllMP4RepairCandidates(rootPath: String) async -> [MP4RepairCandidate] {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let normalizedRoot = (rootPath as NSString).expandingTildeInPath
            let rootURL = URL(fileURLWithPath: normalizedRoot, isDirectory: true)

            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return []
            }

            let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return []
            }

            var candidates: [MP4RepairCandidate] = []

            while let fileURL = enumerator.nextObject() as? URL {
                if let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                   values.isDirectory == true,
                   fileURL.lastPathComponent.lowercased().hasPrefix("remux-test") {
                    enumerator.skipDescendants()
                    continue
                }

                let lowerName = fileURL.lastPathComponent.lowercased()
                if lowerName.contains("_finalizing_") || lowerName.contains(".sb-") {
                    continue
                }

                guard fileURL.pathExtension.lowercased() == "mp4" else { continue }

                guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                      values.isRegularFile == true else {
                    continue
                }

                let modifiedAt = values.contentModificationDate ?? Date.distantPast

                let sizeBytes = Int64(values.fileSize ?? 0)
                guard sizeBytes > 0 else { continue }

                let channelName = fileURL.deletingLastPathComponent().lastPathComponent
                candidates.append(MP4RepairCandidate(path: fileURL.path, channelName: channelName, modifiedAt: modifiedAt, sizeBytes: sizeBytes))
            }

            candidates.sort { lhs, rhs in
                if lhs.modifiedAt == rhs.modifiedAt {
                    return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                }
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return candidates
        }.value
    }

    private static func auditRecordingRepairCandidate(path: String) async -> RecordingRepairAuditDecision {
        await Task.detached(priority: .utility) {
            let fileURL = URL(fileURLWithPath: path)
            let fm = FileManager.default
            guard fm.fileExists(atPath: fileURL.path) else {
                return .good
            }

            let fileSize = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard fileSize > 0 else {
                return .good
            }

            do {
                let metrics = try collectRecordingAuditMetrics(fileURL: fileURL, fileSize: fileSize)

                // Duration checks are skipped entirely when ffprobe is unavailable
                // (nil means we couldn't run ffprobe, not that the file is broken).
                let durationMetadataMismatch: Bool
                switch (metrics.formatDuration, metrics.videoDuration) {
                case let (fd?, vd?):
                    durationMetadataMismatch =
                        (fd <= 0.1 && metrics.fileSize > 100 * 1024 * 1024)
                        || (vd <= 0.1 && metrics.fileSize > 100 * 1024 * 1024)
                        || (fd > 0 && vd > 0 && abs(fd - vd) > 15)
                case let (fd?, nil):
                    durationMetadataMismatch = fd <= 0.1 && metrics.fileSize > 100 * 1024 * 1024
                case let (nil, vd?):
                    durationMetadataMismatch = vd <= 0.1 && metrics.fileSize > 100 * 1024 * 1024
                case (nil, nil):
                    // ffprobe not available; skip duration checks
                    durationMetadataMismatch = false
                }

                let shortForSize: Bool
                if let fd = metrics.formatDuration {
                    shortForSize = fd > 0 && fd < 180 && metrics.fileSize > 800 * 1024 * 1024
                } else {
                    shortForSize = false
                }

                if metrics.malformedBoxes || durationMetadataMismatch || shortForSize {
                    return .needsRemux
                }

                if metrics.moofInHead {
                    return .optionalRemux
                }

                return .good
            } catch {
                // Propagate only genuine I/O failures as good (unknown), not needsRemux.
                // A catch here means collectRecordingAuditMetrics itself threw, which
                // currently does not happen; leave as good to avoid false positives.
                return .good
            }
        }.value
    }

    /// Resolves the ffprobe binary from well-known install locations.
    /// GUI apps do not inherit the shell PATH, so /usr/bin/env cannot find Homebrew tools.
    private nonisolated static func resolveFFProbePath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffprobe",   // Apple Silicon Homebrew
            "/usr/local/bin/ffprobe",       // Intel Homebrew / MacPorts
            "/usr/bin/ffprobe",             // system install
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private nonisolated static func collectRecordingAuditMetrics(fileURL: URL, fileSize: Int64) throws -> RecordingAuditMetrics {
        // Resolve ffprobe once; if unavailable, duration fields remain nil and
        // duration-based checks are skipped to avoid false positives.
        let ffprobePath = resolveFFProbePath()

        let formatDuration: Double? = ffprobePath.flatMap { path in
            runFFProbeDuration(ffprobePath: path, arguments: ["-show_entries", "format=duration"], fileURL: fileURL)
        }
        let videoDuration: Double? = ffprobePath.flatMap { path in
            runFFProbeDuration(ffprobePath: path, arguments: ["-select_streams", "v:0", "-show_entries", "stream=duration"], fileURL: fileURL)
        }

        let headFlags = parseHeadBoxFlags(fileURL: fileURL, fileSize: fileSize, maxBytes: 12 * 1024 * 1024)
        let malformedBoxes = hasMalformedTopLevelBoxes(fileURL: fileURL, fileSize: fileSize)

        return RecordingAuditMetrics(
            formatDuration: formatDuration,
            videoDuration: videoDuration,
            fileSize: fileSize,
            moovInHead: headFlags.moovInHead,
            moofInHead: headFlags.moofInHead,
            malformedBoxes: malformedBoxes
        )
    }

    private nonisolated static func runFFProbeDuration(ffprobePath: String, arguments: [String], fileURL: URL) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = ["-v", "error"]
            + arguments
            + ["-of", "default=nokey=1:noprint_wrappers=1", fileURL.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let raw = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \ .isNewline)
                .first
                .map(String.init)
            guard let raw else { return nil }
            return Double(raw)
        } catch {
            return nil
        }
    }

    private nonisolated static func parseHeadBoxFlags(fileURL: URL, fileSize: Int64, maxBytes: Int) -> HeadBoxFlags {
        let readLimit = min(UInt64(maxBytes), UInt64(max(fileSize, 0)))
        guard readLimit >= 8 else {
            return HeadBoxFlags(moovInHead: false, moofInHead: false)
        }

        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            var offset: UInt64 = 0
            var moov = false
            var moof = false

            while offset + 8 <= readLimit {
                try handle.seek(toOffset: offset)
                guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }

                let size32 = Int(header.prefix(4).reduce(0) { ($0 << 8) | Int($1) })
                let type = String(decoding: header.suffix(4), as: UTF8.self)
                var boxSize = UInt64(size32)
                var headerSize: UInt64 = 8

                if size32 == 0 {
                    boxSize = UInt64(fileSize) - offset
                } else if size32 == 1 {
                    guard let ext = try handle.read(upToCount: 8), ext.count == 8 else { break }
                    boxSize = UInt64(ext.reduce(0) { ($0 << 8) | UInt64($1) })
                    headerSize = 16
                }

                if boxSize < headerSize {
                    break
                }

                if type == "moov" { moov = true }
                if type == "moof" { moof = true }
                if moov && moof { break }

                if offset + boxSize > readLimit {
                    break
                }
                offset += boxSize
            }

            return HeadBoxFlags(moovInHead: moov, moofInHead: moof)
        } catch {
            return HeadBoxFlags(moovInHead: false, moofInHead: false)
        }
    }

    private nonisolated static func hasMalformedTopLevelBoxes(fileURL: URL, fileSize: Int64) -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            var offset: UInt64 = 0
            while offset + 8 <= UInt64(fileSize) {
                try handle.seek(toOffset: offset)
                guard let header = try handle.read(upToCount: 8), header.count == 8 else {
                    return true
                }

                let size32 = Int(header.prefix(4).reduce(0) { ($0 << 8) | Int($1) })
                var boxSize = UInt64(size32)
                var headerSize: UInt64 = 8

                if size32 == 0 {
                    boxSize = UInt64(fileSize) - offset
                } else if size32 == 1 {
                    guard let extended = try handle.read(upToCount: 8), extended.count == 8 else {
                        return true
                    }
                    boxSize = UInt64(extended.reduce(0) { ($0 << 8) | UInt64($1) })
                    headerSize = 16
                }

                if boxSize < headerSize || offset + boxSize > UInt64(fileSize) {
                    return true
                }

                offset += boxSize
            }

            return false
        } catch {
            return true
        }
    }

    private func prepareRecordingRepairState(candidates: [MP4RepairCandidate]) {
        var nextStates: [String: RecordingRepairState] = [:]
        nextStates.reserveCapacity(candidates.count)
        for candidate in candidates {
            if isAlreadyRepaired(candidate: candidate) {
                nextStates[candidate.path] = .good
            } else if let cachedDecision = cachedAuditDecision(for: candidate) {
                switch cachedDecision {
                case .good:
                    nextStates[candidate.path] = .good
                case .optionalRemux, .needsRemux:
                    nextStates[candidate.path] = .needsRemux
                }
            } else {
                nextStates[candidate.path] = .pendingScan
            }
        }
        recordingRepairStates = nextStates
        updateRecordingRepairSummary()
    }

    private func isAlreadyRepaired(candidate: MP4RepairCandidate) -> Bool {
        guard let entry = repairedRecordingIndex[candidate.path] else {
            return false
        }
        return entry.sizeBytes == candidate.sizeBytes
            && abs(candidate.modifiedAt.timeIntervalSince1970 - entry.modifiedAtUnix) < 2.0
    }

    private func setRecordingRepairState(_ state: RecordingRepairState, for path: String) {
        recordingRepairStates[path] = state
        updateRecordingRepairSummary()
    }

    private func setRecordingRepairCurrentPath(_ path: String?) {
        recordingRepairCurrentPath = path
    }

    private func setRecordingRepairScanDetail(_ path: String?) {
        recordingRepairScanDetail = path.map { ($0 as NSString).lastPathComponent }
    }

    private func recordingRepairStateRaw(for path: String) -> RecordingRepairState {
        recordingRepairStates[path] ?? .pendingScan
    }

    private func isAlreadyRepaired(path: String) -> Bool {
        guard let entry = repairedRecordingIndex[path] else {
            return false
        }

        let fileURL = URL(fileURLWithPath: path)
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let fileSize = values.fileSize,
              let modifiedAt = values.contentModificationDate else {
            return false
        }

        let modifiedAtUnix = modifiedAt.timeIntervalSince1970
        return Int64(fileSize) == entry.sizeBytes && abs(modifiedAtUnix - entry.modifiedAtUnix) < 2.0
    }

    private func markRecordingAsRepaired(path: String) {
        let fileURL = URL(fileURLWithPath: path)
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let fileSize = values.fileSize,
              let modifiedAt = values.contentModificationDate else {
            return
        }

        repairedRecordingIndex[path] = RepairedRecordingIndexEntry(
            sizeBytes: Int64(fileSize),
            modifiedAtUnix: modifiedAt.timeIntervalSince1970
        )
        saveRepairIndex()
    }

    private func shouldStopRecordingRepairAfterCurrentItem() -> Bool {
        recordingRepairStopAfterCurrentItem
    }

    private func finishRecordingRepairMaintenance() {
        mp4RepairTask = nil
        isRecordingRepairScanActive = false
        recordingRepairScanDetail = nil
        updateRecordingRepairSummary()
    }

    private func finishRecordingRepairRun() {
        recordingRepairCurrentPath = nil
        recordingRepairRunTask = nil
        isRepairingFlaggedRecordings = false
        updateRecordingRepairSummary()
    }

    private func updateRecordingRepairSummary() {
        var pendingScan = 0
        var scanning = 0
        var good = 0
        var needsRemux = 0
        var queued = 0
        var remuxing = 0
        var repaired = 0
        var failed = 0

        for state in recordingRepairStates.values {
            switch state {
            case .pendingScan:
                pendingScan += 1
            case .scanning:
                scanning += 1
            case .good:
                good += 1
            case .needsRemux:
                needsRemux += 1
            case .queued:
                queued += 1
            case .remuxing:
                remuxing += 1
            case .repaired:
                repaired += 1
            case .failed:
                failed += 1
            case .unsupported:
                break
            }
        }

        recordingRepairSummary = RecordingRepairSummary(
            pendingScan: pendingScan,
            scanning: scanning,
            good: good,
            needsRemux: needsRemux,
            queued: queued,
            remuxing: remuxing,
            repaired: repaired,
            failed: failed
        )
    }

    func recordingRepairState(for path: String, fileExtension: String) -> RecordingRepairState {
        if fileExtension.lowercased() != "mp4" {
            return .unsupported
        }
        return recordingRepairStates[path] ?? .pendingScan
    }

    func terminationBlockReason() -> String? {
        guard let currentPath = recordingRepairCurrentPath else {
            if isRepairingFlaggedRecordings {
                return "Recording remux is active. Please wait for the current remux to finish before quitting."
            }
            return nil
        }
        return "Recording repair in progress for \((currentPath as NSString).lastPathComponent). Please wait for the current remux to finish before quitting."
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

    func setInAppSession(cookies: [String: String], userAgent: String, username: String?) {
        appConfig.authMode = .inAppWebView
        appConfig.inAppCookies = cookies
        appConfig.inAppUserAgent = userAgent
        appConfig.loggedInUsername = username ?? ""
        appConfig.hasCompletedOnboarding = true
        saveAppConfig()
    }

    func completeOnboardingWithoutLogin() {
        appConfig.hasCompletedOnboarding = true
        saveAppConfig()
    }

    func signOutInAppSession() {
        appConfig.inAppCookies = [:]
        appConfig.inAppUserAgent = ""
        appConfig.loggedInUsername = ""
        appConfig.authMode = .inAppWebView
        saveAppConfig()
    }
    
    func createChannel(config: ChannelConfig) async throws -> String {
        let sanitizedUsername = sanitizeUsername(config.username)
        guard !sanitizedUsername.isEmpty else {
            throw ChaturbateError.networkError("Username cannot be empty")
        }

        await FileLogger.shared.log("[manager] create channel requested", channel: sanitizedUsername)

        let duplicateUsername = channels.keys.first(where: { $0.lowercased() == sanitizedUsername.lowercased() })
        guard duplicateUsername == nil else {
            await FileLogger.shared.log("[manager] create channel rejected: already exists", channel: sanitizedUsername, level: "WARN")
            throw ChaturbateError.networkError("Channel \(duplicateUsername ?? sanitizedUsername) already exists")
        }

        let normalizedConfig = ChannelConfig(
            isPaused: config.isPaused,
            username: sanitizedUsername,
            outputDirectory: config.outputDirectory,
            framerate: config.framerate,
            resolution: config.resolution,
            pattern: config.pattern,
            maxDuration: config.maxDuration,
            maxFilesize: config.maxFilesize,
            maxSessionDuration: config.maxSessionDuration,
            maxSessionFilesize: config.maxSessionFilesize,
            createdAt: config.createdAt,
            lastOnlineAt: config.lastOnlineAt,
            recordingHistory: config.recordingHistory,
            isInvalid: config.isInvalid,
            bioMetadata: config.bioMetadata
        )

        // Validate channel existence (404 means it was deleted/never existed).
        let validator = ChaturbateClient(config: appConfig)
        do {
            try await validator.validateChannel(username: sanitizedUsername)
        } catch ChaturbateError.invalidChannel {
            await FileLogger.shared.log("[manager] create channel rejected: invalid/404", channel: sanitizedUsername, level: "WARN")
            throw ChaturbateError.invalidChannel
        } catch {
            // Do not block create on temporary/network/offline/private errors.
            await FileLogger.shared.log("[manager] channel validation non-fatal error: \(error.localizedDescription)", channel: sanitizedUsername, level: "WARN")
        }
        
        let channel = Channel(
            config: normalizedConfig,
            appConfig: appConfig,
            requestCoordinator: requestCoordinator,
            recordingCoordinator: recordingCoordinator,
            recordingLedger: recordingLedger
        )
        channels[sanitizedUsername] = channel
        
        // Save immediately
        await saveConfig()
        
        if !normalizedConfig.isPaused {
            await channel.resume()
        }

        await FileLogger.shared.log("[manager] channel created", channel: sanitizedUsername)
        
        // Fetch bio metadata asynchronously (non-blocking)
        let username = sanitizedUsername
        Task {
            await self.refreshBioMetadata(username: username)
        }

        return sanitizedUsername
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
            await recordingLedger.renameChannel(oldUsername: username, newUsername: targetUsername)
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

    func getRecordingLibraryEntries() async -> [RecordingLedgerEntry] {
        await recordingLedger.fetchLibraryEntries(includeMissing: false)
    }

    func markRecordingMovedToTrash(path: String) async {
        let normalizedPath = (path as NSString).expandingTildeInPath
        await recordingLedger.markRecordingMovedToTrash(filePath: normalizedPath)

        recordingRepairStates.removeValue(forKey: normalizedPath)
        repairedRecordingIndex.removeValue(forKey: normalizedPath)
        auditCache.removeValue(forKey: normalizedPath)

        updateRecordingRepairSummary()
        saveRepairIndex()
        saveAuditCache()
    }

    func getChannelRecordingPaths(username: String) async -> [String] {
        let entries = await recordingLedger.fetchChannelRecordingEntries(
            username: username,
            includeMissing: false
        )
        return entries.map(\ .path)
    }

    func refreshLiveStreamURL(username: String) async -> String? {
        guard let channel = channels[username] else { return nil }
        return await channel.refreshLiveStreamURLForPlayback()
    }

    func refreshChannelStatusForDetail(username: String, refreshPausedThumbnail: Bool = false) async -> ChannelInfo? {
        guard let channel = channels[username] else { return nil }
        await channel.refreshStatusForDetailView(refreshPausedThumbnail: refreshPausedThumbnail)
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
                recordingCoordinator: recordingCoordinator,
                recordingLedger: recordingLedger
            )
            channels[config.username] = channel
            importedChannels.append(channel)
            imported += 1
        }

        if imported > 0 {
            await saveConfig()

            let channelsToProbe = importedChannels
            Task.detached(priority: .utility) { [self] in
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

                // Fetch bio metadata for each imported channel sequentially.
                for channel in channelsToProbe {
                    let username = await channel.config.username
                    await self.refreshBioMetadata(username: username)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
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
        var importedChannels: [Channel] = []

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
                recordingCoordinator: recordingCoordinator,
                recordingLedger: recordingLedger
            )
            channels[config.username] = channel
            importedChannels.append(channel)
            imported += 1
        }

        if imported > 0 {
            await saveConfig()

            let channelsToFetch = importedChannels
            Task { [self] in
                for channel in channelsToFetch {
                    let username = await channel.config.username
                    await self.refreshBioMetadata(username: username)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
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
                    recordingCoordinator: recordingCoordinator,
                    recordingLedger: recordingLedger
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
        noteBackgroundWorkerHeartbeat(.pausedStatus)
        Task {
            await FileLogger.shared.log("[manager] started paused status checks")
        }
        pausedStatusCheckTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                self.noteBackgroundWorkerHeartbeat(.pausedStatus)
                let checksPerCycle = self.appConfig.recordingEnabled ? 2 : 1
                let sleepNanoseconds: UInt64 = self.appConfig.recordingEnabled
                    ? 8 * 1_000_000_000
                    : 30 * 1_000_000_000
                // Probe multiple paused channels per cycle so large imports
                // don't take an hour+ to get an initial online flag.
                // Keep this intentionally conservative to avoid starving
                // foreground playback/detail probes.
                await self.checkPausedChannelStatusBatch(maxChecks: checksPerCycle)
                self.noteBackgroundWorkerHeartbeat(.pausedStatus)
                try? await Task.sleep(nanoseconds: sleepNanoseconds)
            }
        }
    }

    private func startOfflineThumbnailBackfill() {
        offlineThumbnailBackfillTask?.cancel()
        noteBackgroundWorkerHeartbeat(.thumbnailBackfill)
        Task {
            await FileLogger.shared.log("[manager] started offline thumbnail backfill")
        }
        offlineThumbnailBackfillTask = Task { [weak self] in
            guard let self else { return }

            // Avoid startup I/O spikes: wait a bit before first backfill pass.
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)

            while !Task.isCancelled {
                self.noteBackgroundWorkerHeartbeat(.thumbnailBackfill)

                // Background thumbnail generation is not essential while
                // recording is globally paused; keep this worker mostly idle.
                if !self.appConfig.recordingEnabled {
                    try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    self.noteBackgroundWorkerHeartbeat(.thumbnailBackfill)
                    continue
                }

                await FileLogger.shared.logBackfillCycleStart()
                await self.backfillOneOfflineThumbnail()
                await FileLogger.shared.logBackfillCycleEnd()
                self.noteBackgroundWorkerHeartbeat(.thumbnailBackfill)
                // One channel at a time keeps disk usage smooth on large libraries.
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            }
        }
    }

    private func startRecordingLedgerMaintenance() {
        recordingLedgerMaintenanceTask?.cancel()
        noteBackgroundWorkerHeartbeat(.ledgerMaintenance)
        recordingLedgerMaintenanceTask = Task { [weak self] in
            guard let self else { return }

            await FileLogger.shared.log("[manager] started recording ledger maintenance")
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)

            if self.hasCompletedInitialLedgerBackfill() {
                await FileLogger.shared.log("[manager] skipping initial recording ledger backfill (marker present)")
            } else {
                let initialConfigs = await self.getAllChannelConfigs()
                let repairedPaths = Set(self.repairedRecordingIndex.keys)
                let backfill = await self.recordingLedger.backfillExistingRecordings(
                    channelConfigs: initialConfigs,
                    defaultOutputRoot: self.appConfig.getOutputPath(),
                    repairedPaths: repairedPaths
                )

                self.markInitialLedgerBackfillComplete(backfill: backfill)
                await FileLogger.shared.log(
                    "[manager] recording ledger backfill complete: inserted=\(backfill.inserted), existing=\(backfill.skippedExisting), missing=\(backfill.missingAdded)"
                )
            }

            while !Task.isCancelled {
                self.noteBackgroundWorkerHeartbeat(.ledgerMaintenance)
                let reconcile = await self.recordingLedger.reconcileFilesystem(rootPath: self.appConfig.getOutputPath())
                if reconcile.missing > 0 || reconcile.moved > 0 || reconcile.recovered > 0 {
                    await FileLogger.shared.log(
                        "[manager] recording ledger reconcile: checked=\(reconcile.checked), moved=\(reconcile.moved), missing=\(reconcile.missing), recovered=\(reconcile.recovered)",
                        level: "WARN"
                    )
                }
                self.noteBackgroundWorkerHeartbeat(.ledgerMaintenance)

                try? await Task.sleep(nanoseconds: 3 * 60 * 1_000_000_000)
            }
        }
    }

    private func startBackgroundWorkerWatchdog() {
        backgroundWorkerWatchdogTask?.cancel()
        for worker in BackgroundWorker.allCases {
            backgroundWorkerLastHeartbeat[worker] = Date()
        }

        backgroundWorkerWatchdogTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.evaluateBackgroundWorkerHealth()
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    private func noteBackgroundWorkerHeartbeat(_ worker: BackgroundWorker) {
        backgroundWorkerLastHeartbeat[worker] = Date()
    }

    private func evaluateBackgroundWorkerHealth() async {
        let now = Date()
        var warnings: [String] = []

        for worker in BackgroundWorker.allCases {
            guard let lastHeartbeat = backgroundWorkerLastHeartbeat[worker] else { continue }
            let lagSeconds = now.timeIntervalSince(lastHeartbeat)
            if lagSeconds > worker.staleThresholdSeconds {
                let warning = "\(worker.rawValue) appears stale (last heartbeat \(Int(lagSeconds))s ago)"
                warnings.append(warning)

                if !activeBackgroundWorkerAlerts.contains(worker) {
                    activeBackgroundWorkerAlerts.insert(worker)
                    await FileLogger.shared.log("[manager] watchdog: \(warning)", level: "WARN")
                    restartBackgroundWorker(worker)
                }
            } else if activeBackgroundWorkerAlerts.contains(worker) {
                activeBackgroundWorkerAlerts.remove(worker)
                await FileLogger.shared.log("[manager] watchdog: \(worker.rawValue) heartbeat recovered")
            }
        }

        backgroundWorkerWarnings = warnings.sorted()
    }

    private func restartBackgroundWorker(_ worker: BackgroundWorker) {
        Task {
            await FileLogger.shared.log("[manager] watchdog: restarting \(worker.rawValue)", level: "WARN")
        }

        switch worker {
        case .pausedStatus:
            startPausedStatusChecks()
        case .thumbnailBackfill:
            startOfflineThumbnailBackfill()
        case .ledgerMaintenance:
            startRecordingLedgerMaintenance()
        }
    }

    private func hasCompletedInitialLedgerBackfill() -> Bool {
        FileManager.default.fileExists(atPath: recordingLedgerBackfillMarkerURL.path)
    }

    private func markInitialLedgerBackfillComplete(backfill: RecordingBackfillSummary) {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let marker = [
            "completed_at=\(timestamp)",
            "inserted=\(backfill.inserted)",
            "existing=\(backfill.skippedExisting)",
            "missing=\(backfill.missingAdded)"
        ].joined(separator: "\n")

        do {
            try marker.write(to: recordingLedgerBackfillMarkerURL, atomically: true, encoding: String.Encoding.utf8)
        } catch {
            Task {
                await FileLogger.shared.log(
                    "[manager] failed to write recording ledger backfill marker: \(error.localizedDescription)",
                    level: "WARN"
                )
            }
        }
    }

    private func backfillOneOfflineThumbnail() async {
        var candidates: [(String, Channel)] = []
        let now = Date()

        // Drop expired cooldown entries before scanning for work.
        thumbnailBackfillCooldownUntil = thumbnailBackfillCooldownUntil.filter { _, until in
            until > now
        }

        for (username, channel) in channels {
            let info = await channel.getInfo()
            let coolingDown = thumbnailBackfillCooldownUntil[username].map { $0 > now } ?? false
            if !coolingDown, !info.isOnline, info.thumbnailPath == nil {
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
            var backfillResult: Channel.OfflineThumbnailBackfillResult?

            try await withThrowingTaskGroup(of: Channel.OfflineThumbnailBackfillResult.self) { group in
                group.addTask {
                    await channel.backfillOfflineThumbnailIfNeeded()
                }
                
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanos)
                    throw TimeoutError()
                }
                
                // Wait for first result (either completion or timeout)
                while let result = try await group.next() {
                    backfillResult = result
                    group.cancelAll()
                    break
                }
            }

            switch backfillResult {
            case .noVideoCandidate:
                let until = Date().addingTimeInterval(Self.thumbnailBackfillNoVideoCooldownSeconds)
                thumbnailBackfillCooldownUntil[username] = until
                await FileLogger.shared.log(
                    "Thumbnail backfill: no video candidate cooldown active for \(Int(Self.thumbnailBackfillNoVideoCooldownSeconds))s",
                    channel: username
                )
            case .generated:
                thumbnailBackfillCooldownUntil.removeValue(forKey: username)
            default:
                break
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

        let requestStats = await requestCoordinator.getStats()
        let queueBusy = requestStats.queuedRequests > 0
            || requestStats.activeRequests >= max(1, requestStats.maxConcurrent - 1)

        if queueBusy {
            let now = Date()
            if now.timeIntervalSince(lastPausedProbeDeferralLogAt) >= 30 {
                lastPausedProbeDeferralLogAt = now
                await FileLogger.shared.log(
                    "[manager] deferring paused status probes (request queue busy: active=\(requestStats.activeRequests)/\(requestStats.maxConcurrent), queued=\(requestStats.queuedRequests))"
                )
            }
            return
        }

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
