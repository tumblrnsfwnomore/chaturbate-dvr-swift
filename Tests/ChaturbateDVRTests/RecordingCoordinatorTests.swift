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

    func testCleanupStaleFinalizingTempFilesRemovesDuplicateTempOutputs() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sourceURL = tempDir.appendingPathComponent("recording.mp4")
        let staleTemp1 = tempDir.appendingPathComponent("recording_finalizing_aaa.mp4")
        let staleTemp2 = tempDir.appendingPathComponent("recording_audiosync_bbb.mp4")
        let activeTemp = tempDir.appendingPathComponent("recording_finalized.mp4")

        try "one".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "stale1".write(to: staleTemp1, atomically: true, encoding: .utf8)
        try "stale2".write(to: staleTemp2, atomically: true, encoding: .utf8)
        try "active".write(to: activeTemp, atomically: true, encoding: .utf8)

        Channel.cleanupStaleFinalizingTempFiles(for: sourceURL.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTemp1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTemp2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeTemp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
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

    func testSplitRecordingRejectsInvalidRanges() async throws {
        let manager = await MainActor.run { ChannelManager() }

        do {
            _ = try await manager.splitRecording(path: "/tmp/does-not-exist.mp4", startSeconds: 2, endSeconds: 1, saveAsNewFile: true)
            XCTFail("Expected invalid trim range to be rejected")
        } catch RecordingEditError.invalidTrimRange {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCombineRecordingsRequiresMultipleValidInputs() async throws {
        let manager = await MainActor.run { ChannelManager() }
        let singlePath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("combine-single-test.mp4")
        try? FileManager.default.removeItem(at: singlePath)

        do {
            _ = try await manager.combineRecordings(paths: [singlePath.path], outputPath: nil, keepOriginals: true)
            XCTFail("Expected combine request with a single input to be rejected")
        } catch RecordingEditError.invalidSelection {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testRepairMaintenanceDoesNotStartWithoutPendingStates() {
        let manager = ChannelManager()
        let outputPath = manager.appConfig.getOutputPath()

        XCTAssertFalse(manager.shouldStartRecordingRepairMaintenance(for: outputPath, forceRescan: false))
    }

    func testRepairPathsCanonicalizeSymlinksAndAliases() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let realDir = tempDir.appendingPathComponent("real")
        let aliasDir = tempDir.appendingPathComponent("alias")
        let fileName = "recording.mp4"

        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let realFileURL = realDir.appendingPathComponent(fileName)
        try "stub".write(to: realFileURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: aliasDir, withDestinationURL: realDir)

        let realPath = realFileURL.path
        let aliasedPath = aliasDir.appendingPathComponent(fileName).path

        XCTAssertEqual(ChannelManager.canonicalRecordingPath(realPath), ChannelManager.canonicalRecordingPath(aliasedPath))
        XCTAssertEqual(ChannelManager.canonicalRecordingPath(realPath), realPath)
    }

    @MainActor
    func testInProgressManualRecordingsStayLockedFromPendingScan() {
        let manager = ChannelManager()

        XCTAssertEqual(
            manager.recordingRepairState(for: "/tmp/manual-recording.mp4", fileExtension: "mp4", recordingStatus: "Active"),
            .unsupported
        )

        XCTAssertEqual(
            manager.recordingRepairState(for: "/tmp/cbdvr_inprogress_manual-recording.mp4", fileExtension: "mp4", recordingStatus: nil),
            .unsupported
        )

        XCTAssertEqual(
            manager.recordingRepairState(for: "/tmp/finalizing_manual-recording.mp4", fileExtension: "mp4", recordingStatus: "FINALIZING"),
            .unsupported
        )
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
