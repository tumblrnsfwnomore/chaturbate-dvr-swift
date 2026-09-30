import XCTest
@testable import ChaturbateDVR

final class RecordingCoordinatorTests: XCTestCase {
    func testQueuedSlotEventuallyTimesOutAndIsRejected() async throws {
        let coordinator = RecordingCoordinator(maxConcurrent: 1, staleWaitTimeoutSeconds: 0.05)

        let firstGranted = await coordinator.acquireSlot(for: "first")
        XCTAssertTrue(firstGranted)

        let result = await withTimeout(seconds: 0.2) {
            await coordinator.acquireSlot(for: "second")
        }

        XCTAssertEqual(result, false)
    }

    func testBreakDetectedFragmentBelowRetentionThresholdIsDiscarded() {
        XCTAssertTrue(
            Channel.shouldDiscardRecordingFragmentForTermination(
                durationSeconds: 5,
                filesizeBytes: 64 * 1024,
                terminationReason: "break_detection"
            )
        )

        XCTAssertFalse(
            Channel.shouldDiscardRecordingFragmentForTermination(
                durationSeconds: 12,
                filesizeBytes: 512 * 1024,
                terminationReason: "break_detection"
            )
        )
    }

    func testTransientRecordingFailuresBackOffBeforeForcingOffline() {
        XCTAssertFalse(
            Channel.shouldTreatTransientRecordingFailureAsOffline(
                consecutiveFailures: 3,
                failureWindowSeconds: 25
            )
        )

        XCTAssertFalse(
            Channel.shouldTreatTransientRecordingFailureAsOffline(
                consecutiveFailures: 5,
                failureWindowSeconds: 25
            )
        )

        XCTAssertTrue(
            Channel.shouldTreatTransientRecordingFailureAsOffline(
                consecutiveFailures: 6,
                failureWindowSeconds: 25
            )
        )
    }

    func testWaitingOfflineProbeRequiresMultipleConfirmationsBeforeMarkingOffline() {
        XCTAssertFalse(
            Channel.shouldTreatWaitingProbeFailureAsOffline(failureCount: 1, wasOnlineBeforeFailure: true)
        )
        XCTAssertFalse(
            Channel.shouldTreatWaitingProbeFailureAsOffline(failureCount: 2, wasOnlineBeforeFailure: true)
        )
        XCTAssertTrue(
            Channel.shouldTreatWaitingProbeFailureAsOffline(failureCount: 3, wasOnlineBeforeFailure: true)
        )
    }

    func testManualBreakOverrideIsTemporaryAndNotPersistedAcrossChannels() async {
        let config = ChannelConfig(username: "testuser")
        let appConfig = AppConfig()
        let requestCoordinator = RequestCoordinator(maxConcurrent: 2)
        let recordingRequestCoordinator = RequestCoordinator(maxConcurrent: 8)
        let recordingCoordinator = RecordingCoordinator(maxConcurrent: 1)
        let manualRecordingSlotManager = ManualRecordingSlotManager()
        let recordingLedger = RecordingLedger()

        let channel = Channel(
            config: config,
            appConfig: appConfig,
            requestCoordinator: requestCoordinator,
            recordingRequestCoordinator: recordingRequestCoordinator,
            recordingCoordinator: recordingCoordinator,
            manualRecordingSlotManager: manualRecordingSlotManager,
            recordingLedger: recordingLedger
        )

        let initialInfo = await channel.getInfo()
        XCTAssertFalse(initialInfo.isManualBreakOverrideActive)

        await channel.setManualBreakOverrideEnabled(true)
        let enabledInfo = await channel.getInfo()
        XCTAssertTrue(enabledInfo.isManualBreakOverrideActive)

        let freshChannel = Channel(
            config: config,
            appConfig: appConfig,
            requestCoordinator: requestCoordinator,
            recordingRequestCoordinator: recordingRequestCoordinator,
            recordingCoordinator: recordingCoordinator,
            manualRecordingSlotManager: manualRecordingSlotManager,
            recordingLedger: recordingLedger
        )
        let freshInfo = await freshChannel.getInfo()
        XCTAssertFalse(freshInfo.isManualBreakOverrideActive)
    }

    func testAudioSyncRepairAppliesObservedAudioDelayForRetime() {
        let observedDelay = 0.875

        let filter = Channel.buildRetimedAudioFilter(
            audioInputIndex: 1,
            tempoAdjustment: nil,
            audioDelaySeconds: observedDelay
        )

        XCTAssertTrue(filter.contains("adelay=875|875"))
        XCTAssertTrue(filter.contains("aresample=async=1:first_pts=0"))
    }

    func testRecordingsLibrarySkipsImmediateDiskRescanWhenCachedDataIsFresh() {
        let now = Date()
        XCTAssertTrue(
            RecordingsLibraryView.shouldScheduleBackgroundDiskRescan(
                hasCachedEntries: false,
                lastDiskRescanAt: nil,
                now: now,
                force: false
            )
        )
        XCTAssertFalse(
            RecordingsLibraryView.shouldScheduleBackgroundDiskRescan(
                hasCachedEntries: true,
                lastDiskRescanAt: now.addingTimeInterval(-60),
                now: now,
                force: false
            )
        )
        XCTAssertTrue(
            RecordingsLibraryView.shouldScheduleBackgroundDiskRescan(
                hasCachedEntries: true,
                lastDiskRescanAt: now.addingTimeInterval(-10 * 60),
                now: now,
                force: false
            )
        )
    }

    @MainActor
    func testRepairMaintenanceDoesNotStartWithoutPendingStates() {
        let manager = ChannelManager()
        let outputPath = manager.appConfig.getOutputPath()

        XCTAssertFalse(manager.shouldStartRecordingRepairMaintenance(for: outputPath, forceRescan: false))
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async -> T) async -> T? {
        let task = Task { await operation() }
        let timeoutTask = Task { () -> T? in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }

        return await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask { await timeoutTask.value }
            return await group.next() ?? nil
        }
    }
}
