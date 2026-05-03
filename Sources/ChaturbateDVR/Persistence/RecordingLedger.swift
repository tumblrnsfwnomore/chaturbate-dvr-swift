import Foundation
import AVFoundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct RecordingBackfillSummary {
    var inserted: Int
    var skippedExisting: Int
    var missingAdded: Int
}

struct RecordingReconcileSummary {
    var checked: Int
    var moved: Int
    var missing: Int
    var recovered: Int
}

struct ActiveRecordingRecoverySummary {
    var checked: Int
    var finalizedWithWarning: Int
    var markedMissing: Int
    var autoRepairCandidates: [ActiveRecordingAutoRepairCandidate]
}

struct ActiveRecordingAutoRepairCandidate: Sendable {
    let path: String
    let channelUsername: String
}

struct RecordingLedgerEntry: Sendable {
    let path: String
    let workingFilePath: String?
    let channelUsername: String
    let fileExtension: String
    let fileSizeBytes: Int64
    let durationSeconds: Double
    let startedAt: Date?
    let endedAt: Date?
    let modifiedAt: Date
    let fileExists: Bool
    let status: String

    var isActive: Bool {
        status == "active"
    }

    var isFinalizing: Bool {
        status == "finalizing"
    }
}

struct RecordingEventEntry: Sendable, Identifiable {
    let id: Int64
    let createdAt: Date
    let level: String
    let eventType: String
    let message: String
    let metadataJSON: String?
}

struct RecordingLedgerDetail: Sendable {
    let id: Int64
    let path: String
    let workingFilePath: String?
    let channelUsername: String
    let fileExtension: String
    let status: String
    let durationSeconds: Double
    let fileSizeBytes: Int64
    let fileExists: Bool
    let startedAt: Date?
    let endedAt: Date?
    let remuxedAt: Date?
    let firstPersonDetectedAt: Date?
    let lastPersonDetectedAt: Date?
    let noPersonDurationSeconds: Int
    let segmentRetryCount: Int
    let consecutiveSegmentFailures: Int
    let cloudflareBlockCount: Int
    let timelineMismatchCount: Int
    let audioPresent: Int
    let missingSince: Date?
    let fileLastSeenAt: Date?
    let fileLastModifiedAt: Date?
    let isRemuxed: Bool
    let isBackfilled: Bool
    let events: [RecordingEventEntry]

    var isActive: Bool {
        status == "active"
    }

    var isFinalizing: Bool {
        status == "finalizing"
    }
}

actor RecordingLedger {
    static let shared = RecordingLedger()
    private static let legacyWorkingFilePrefix = "."
    private static let workingFilePrefix = ".cbdvr_work_"
    private static let visibleWorkingFilePrefix = "cbdvr_inprogress_"

    private static func isIgnoredInProgressFilename(_ fileName: String) -> Bool {
        let lowerName = fileName.lowercased()
        return lowerName.hasPrefix(workingFilePrefix)
            || lowerName.hasPrefix(visibleWorkingFilePrefix)
            || lowerName.contains("_finalizing_")
    }

    private struct CatalogEntry {
        let path: String
        let sizeBytes: Int64
        let modifiedAt: Int64
    }

    private struct RecordingRow {
        let id: Int64
        let path: String
        let status: String
        let sizeBytes: Int64
        let modifiedAt: Int64
    }

    private struct ActiveRecordingRow {
        let id: Int64
        let channelUsername: String
        let path: String
        let workingPath: String?
        let startedAt: Int64
        let durationSeconds: Double
        let sizeBytes: Int64
        let originalStatus: String
    }

    private var database: OpaquePointer?
    private var databaseURL: URL?

    func initialize(appFolder: URL) async {
        let dbURL = appFolder.appendingPathComponent("recordings.sqlite")
        _ = openIfNeeded(databaseURL: dbURL)
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func startRecording(
        channelUsername: String,
        filePath: String,
        workingFilePath: String?,
        container: String,
        startedAt: Date
    ) async -> Int64? {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return nil
        }

        let channelID = ensureChannelID(username: channelUsername, database: database)
        guard channelID > 0 else { return nil }

        let now = nowUnix()
        let startedUnix = Int64(startedAt.timeIntervalSince1970)

        let sql = """
        INSERT INTO recordings (
            channel_id, started_at, ended_at, duration_seconds, file_size_bytes,
            file_path, working_file_path, container, status, is_remuxed, remuxed_at,
            first_person_detected_at, last_person_detected_at,
            missing_since, file_last_seen_at, file_last_modified_at,
            file_exists, created_at, updated_at, is_backfilled
        )
        VALUES (?, ?, NULL, 0, 0, ?, ?, ?, 'active', 0, NULL, NULL, NULL, NULL, ?, NULL, 1, ?, ?, 0)
        ON CONFLICT(file_path) DO UPDATE SET
            channel_id = excluded.channel_id,
            started_at = COALESCE(recordings.started_at, excluded.started_at),
            working_file_path = excluded.working_file_path,
            container = excluded.container,
            status = 'active',
            file_exists = 1,
            missing_since = NULL,
            updated_at = excluded.updated_at
        """

        guard let statement = prepare(database: database, sql: sql) else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, channelID)
        sqlite3_bind_int64(statement, 2, startedUnix)
        bindText(statement: statement, index: 3, value: normalizePath(filePath))
        bindText(statement: statement, index: 4, value: normalizeOptionalPath(workingFilePath))
        bindText(statement: statement, index: 5, value: container)
        sqlite3_bind_int64(statement, 6, now)
        sqlite3_bind_int64(statement, 7, now)
        sqlite3_bind_int64(statement, 8, now)

        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }

        if let existingID = recordingID(forPath: filePath, database: database) {
            return existingID
        }

        return sqlite3_last_insert_rowid(database)
    }

    func updateRecordingProgress(
        recordingID: Int64,
        durationSeconds: Double,
        fileSizeBytes: Int64,
        noPersonDurationSeconds: Int,
        segmentRetryCount: Int,
        consecutiveSegmentFailures: Int,
        cloudflareBlockCount: Int,
        timelineMismatchCount: Int
    ) async {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return
        }

        let sql = """
        UPDATE recordings
        SET duration_seconds = ?,
            file_size_bytes = ?,
            no_person_duration_seconds = ?,
            segment_retry_count = ?,
            consecutive_segment_failures = ?,
            cloudflare_block_count = ?,
            timeline_mismatch_count = ?,
            updated_at = ?
        WHERE id = ?
        """

        guard let statement = prepare(database: database, sql: sql) else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, durationSeconds)
        sqlite3_bind_int64(statement, 2, fileSizeBytes)
        sqlite3_bind_int64(statement, 3, Int64(noPersonDurationSeconds))
        sqlite3_bind_int64(statement, 4, Int64(segmentRetryCount))
        sqlite3_bind_int64(statement, 5, Int64(consecutiveSegmentFailures))
        sqlite3_bind_int64(statement, 6, Int64(cloudflareBlockCount))
        sqlite3_bind_int64(statement, 7, Int64(timelineMismatchCount))
        sqlite3_bind_int64(statement, 8, nowUnix())
        sqlite3_bind_int64(statement, 9, recordingID)

        _ = sqlite3_step(statement)
    }

    func appendEvent(
        recordingID: Int64,
        level: String,
        eventType: String,
        message: String,
        metadataJSON: String? = nil,
        createdAt: Date = Date()
    ) async {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return
        }

        let sql = """
        INSERT INTO recording_events (recording_id, created_at, level, event_type, message, metadata_json)
        VALUES (?, ?, ?, ?, ?, ?)
        """

        guard let statement = prepare(database: database, sql: sql) else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, recordingID)
        sqlite3_bind_int64(statement, 2, Int64(createdAt.timeIntervalSince1970))
        bindText(statement: statement, index: 3, value: level)
        bindText(statement: statement, index: 4, value: eventType)
        bindText(statement: statement, index: 5, value: message)
        bindText(statement: statement, index: 6, value: metadataJSON)

        _ = sqlite3_step(statement)
    }

    func markFinalizing(recordingID: Int64) async {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return
        }

        let sql = """
        UPDATE recordings
        SET status = 'finalizing', updated_at = ?
        WHERE id = ? AND status = 'active'
        """

        guard let statement = prepare(database: database, sql: sql) else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, nowUnix())
        sqlite3_bind_int64(statement, 2, recordingID)

        _ = sqlite3_step(statement)
    }

    func markPersonDetected(recordingID: Int64, detectedAt: Date) async {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return
        }

        let detectedUnix = Int64(detectedAt.timeIntervalSince1970)
        let sql = """
        UPDATE recordings
        SET first_person_detected_at = COALESCE(first_person_detected_at, ?),
            last_person_detected_at = ?,
            updated_at = ?
        WHERE id = ?
        """

        guard let statement = prepare(database: database, sql: sql) else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, detectedUnix)
        sqlite3_bind_int64(statement, 2, detectedUnix)
        sqlite3_bind_int64(statement, 3, nowUnix())
        sqlite3_bind_int64(statement, 4, recordingID)

        _ = sqlite3_step(statement)
    }

    func finishRecording(
        recordingID: Int64,
        endedAt: Date,
        durationSeconds: Double,
        fileSizeBytes: Int64,
        finalPath: String,
        wasRemuxed: Bool,
        status: String
    ) async {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return
        }

        let normalizedPath = normalizePath(finalPath)
        let finalAttributes = try? FileManager.default.attributesOfItem(atPath: normalizedPath)
        let observedSize = (finalAttributes?[.size] as? NSNumber)?.int64Value ?? fileSizeBytes
        let modified = ((finalAttributes?[.modificationDate] as? Date)?.timeIntervalSince1970).map(Int64.init)
        let exists = FileManager.default.fileExists(atPath: normalizedPath)
        let audioPresent = exists ? await audioPresenceFromMediaFile(path: normalizedPath) : -1
        let now = nowUnix()

        let sql = """
        UPDATE recordings
        SET ended_at = ?,
            duration_seconds = ?,
            file_size_bytes = ?,
            file_path = ?,
            working_file_path = NULL,
            status = ?,
            is_remuxed = ?,
            remuxed_at = CASE WHEN ? = 1 THEN ? ELSE remuxed_at END,
            audio_present = ?,
            file_exists = ?,
            missing_since = CASE WHEN ? = 1 THEN NULL ELSE COALESCE(missing_since, ?) END,
            file_last_seen_at = CASE WHEN ? = 1 THEN ? ELSE file_last_seen_at END,
            file_last_modified_at = COALESCE(?, file_last_modified_at),
            updated_at = ?
        WHERE id = ?
        """

        guard let statement = prepare(database: database, sql: sql) else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(endedAt.timeIntervalSince1970))
        sqlite3_bind_double(statement, 2, durationSeconds)
        sqlite3_bind_int64(statement, 3, observedSize)
        bindText(statement: statement, index: 4, value: normalizedPath)
        bindText(statement: statement, index: 5, value: status)
        sqlite3_bind_int(statement, 6, wasRemuxed ? 1 : 0)
        sqlite3_bind_int(statement, 7, wasRemuxed ? 1 : 0)
        sqlite3_bind_int64(statement, 8, now)
        sqlite3_bind_int(statement, 9, Int32(audioPresent))
        sqlite3_bind_int(statement, 10, exists ? 1 : 0)
        sqlite3_bind_int(statement, 11, exists ? 1 : 0)
        sqlite3_bind_int64(statement, 12, now)
        sqlite3_bind_int(statement, 13, exists ? 1 : 0)
        sqlite3_bind_int64(statement, 14, now)
        if let modified {
            sqlite3_bind_int64(statement, 15, modified)
        } else {
            sqlite3_bind_null(statement, 15)
        }
        sqlite3_bind_int64(statement, 16, now)
        sqlite3_bind_int64(statement, 17, recordingID)

        _ = sqlite3_step(statement)
    }

    func renameChannel(oldUsername: String, newUsername: String) async {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return
        }

        let oldID = ensureChannelID(username: oldUsername, database: database)
        let newID = ensureChannelID(username: newUsername, database: database)

        guard oldID > 0, newID > 0 else { return }

        let updateRecordings = "UPDATE recordings SET channel_id = ?, updated_at = ? WHERE channel_id = ?"
        if let statement = prepare(database: database, sql: updateRecordings) {
            sqlite3_bind_int64(statement, 1, newID)
            sqlite3_bind_int64(statement, 2, nowUnix())
            sqlite3_bind_int64(statement, 3, oldID)
            _ = sqlite3_step(statement)
            sqlite3_finalize(statement)
        }

        let deleteOld = "DELETE FROM channels WHERE id = ?"
        if let statement = prepare(database: database, sql: deleteOld) {
            sqlite3_bind_int64(statement, 1, oldID)
            _ = sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    func backfillExistingRecordings(
        channelConfigs: [ChannelConfig],
        defaultOutputRoot: String,
        repairedPaths: Set<String>
    ) async -> RecordingBackfillSummary {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return RecordingBackfillSummary(inserted: 0, skippedExisting: 0, missingAdded: 0)
        }

        var summary = RecordingBackfillSummary(inserted: 0, skippedExisting: 0, missingAdded: 0)
        let allowedExtensions: Set<String> = ["ts", "mp4", "mkv", "mov", "m4v"]

        for config in channelConfigs {
            let channelID = ensureChannelID(username: config.username, database: database)
            guard channelID > 0 else { continue }

            var discovered = Set<String>()
            let historyPaths = config.recordingHistory.map { normalizePath(($0 as NSString).expandingTildeInPath) }
            for path in historyPaths {
                discovered.insert(path)
            }

            let baseOutput = config.outputDirectory.isEmpty ? defaultOutputRoot : config.outputDirectory
            let channelDir = normalizePath(((baseOutput as NSString).appendingPathComponent(config.username) as NSString).expandingTildeInPath)
            for filePath in listVideoFiles(at: channelDir, allowedExtensions: allowedExtensions) {
                discovered.insert(filePath)
            }

            let sortedPaths = discovered.sorted()
            for filePath in sortedPaths {
                if recordingID(forPath: filePath, database: database) != nil {
                    summary.skippedExisting += 1
                    continue
                }

                if FileManager.default.fileExists(atPath: filePath) {
                    if await insertBackfilledFile(path: filePath, channelID: channelID, repairedPaths: repairedPaths, database: database) {
                        summary.inserted += 1
                    }
                } else if historyPaths.contains(filePath) {
                    if insertMissingBackfilledRecord(path: filePath, channelID: channelID, database: database) {
                        summary.missingAdded += 1
                    }
                }
            }
        }

        // Also capture recordings that exist on disk but are no longer listed in channel configs.
        // This keeps forensic history complete even after channel removals/import drift.
        let rootPath = normalizePath((defaultOutputRoot as NSString).expandingTildeInPath)
        let orphanCandidates = listVideoFilesRecursively(at: rootPath, allowedExtensions: allowedExtensions)
        for filePath in orphanCandidates {
            if recordingID(forPath: filePath, database: database) != nil {
                summary.skippedExisting += 1
                continue
            }

            guard FileManager.default.fileExists(atPath: filePath) else { continue }
            let channelName = URL(fileURLWithPath: filePath).deletingLastPathComponent().lastPathComponent
            guard !channelName.isEmpty else { continue }

            let channelID = ensureChannelID(username: channelName, database: database)
            guard channelID > 0 else { continue }

            if await insertBackfilledFile(path: filePath, channelID: channelID, repairedPaths: repairedPaths, database: database) {
                summary.inserted += 1
            }
        }

        return summary
    }

    func reconcileFilesystem(rootPath: String) async -> RecordingReconcileSummary {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return RecordingReconcileSummary(checked: 0, moved: 0, missing: 0, recovered: 0)
        }

        let normalizedRoot = normalizePath((rootPath as NSString).expandingTildeInPath)
        let catalog = buildCatalog(rootPath: normalizedRoot)
        let recordings = loadRecordingRows(database: database)

        var summary = RecordingReconcileSummary(checked: recordings.count, moved: 0, missing: 0, recovered: 0)
        var consumedPaths = Set<String>()

        for row in recordings {
            if let entry = catalog.byPath[row.path] {
                consumedPaths.insert(entry.path)
                let wasMissing = row.status == "missing"
                updateRecordingAsSeen(rowID: row.id, status: wasMissing ? "recovered" : row.status, entry: entry, database: database)
                if wasMissing {
                    summary.recovered += 1
                    appendSystemEvent(recordingID: row.id, level: "INFO", eventType: "filesystem_recovered", message: "Recording file is available again at original path", database: database)
                }
                continue
            }

            if let moved = findMovedCandidate(for: row, catalog: catalog, consumedPaths: consumedPaths) {
                consumedPaths.insert(moved.path)
                moveRecording(rowID: row.id, newEntry: moved, database: database)
                summary.moved += 1
                appendSystemEvent(recordingID: row.id, level: "WARN", eventType: "filesystem_moved", message: "Recording path changed from \(row.path) to \(moved.path)", database: database)
                continue
            }

            let wasAlreadyMissing = row.status == "missing"
            markRecordingMissing(rowID: row.id, alreadyMissing: wasAlreadyMissing, database: database)
            if !wasAlreadyMissing {
                summary.missing += 1
                appendSystemEvent(recordingID: row.id, level: "WARN", eventType: "filesystem_missing", message: "Recording file is missing from disk at \(row.path)", database: database)
            }
        }

        return summary
    }

    func recoverAbandonedActiveRecordings(activeBefore cutoffUnix: Int64) async -> ActiveRecordingRecoverySummary {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return ActiveRecordingRecoverySummary(checked: 0, finalizedWithWarning: 0, markedMissing: 0, autoRepairCandidates: [])
        }

        let rows = loadActiveRecordingRows(activeBefore: cutoffUnix, database: database)
        guard !rows.isEmpty else {
            return ActiveRecordingRecoverySummary(checked: 0, finalizedWithWarning: 0, markedMissing: 0, autoRepairCandidates: [])
        }

        var summary = ActiveRecordingRecoverySummary(
            checked: rows.count,
            finalizedWithWarning: 0,
            markedMissing: 0,
            autoRepairCandidates: []
        )
        let now = nowUnix()
        var queuedRepairPaths = Set<String>()

        func orphanedFinalizingTempPath(for finalPath: String, fileManager: FileManager) -> String? {
            let finalURL = URL(fileURLWithPath: finalPath)
            let directoryURL = finalURL.deletingLastPathComponent()
            let fileStem = finalURL.deletingPathExtension().lastPathComponent.lowercased()
            let expectedPrefixes = [
                "\(fileStem)_finalizing_",
                "\(Self.legacyWorkingFilePrefix)\(fileStem)_finalizing_",
                "\(Self.workingFilePrefix)\(fileStem)_finalizing_",
                "\(Self.visibleWorkingFilePrefix)\(fileStem)_finalizing_",
            ]

            guard let candidates = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return nil
            }

            let tempCandidates = candidates.filter { url in
                guard url.pathExtension.lowercased() == "mp4",
                      expectedPrefixes.contains(where: { prefix in
                          url.lastPathComponent.lowercased().hasPrefix(prefix)
                      }) else {
                    return false
                }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true
            }

            return tempCandidates.max { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                }
                return lhsDate < rhsDate
            }?.path
        }

        for row in rows {
            let fileManager = FileManager.default

            let finalPath = normalizePath(row.path)
            let finalExists = fileManager.fileExists(atPath: finalPath)

            let normalizedWorkingPath = normalizeOptionalPath(row.workingPath)
            let workingExists = normalizedWorkingPath.map { fileManager.fileExists(atPath: $0) } ?? false

            var resolvedPath: String?
            if finalExists {
                resolvedPath = finalPath
            } else if workingExists {
                if let normalizedWorkingPath {
                    do {
                        if fileManager.fileExists(atPath: finalPath) {
                            try fileManager.removeItem(atPath: finalPath)
                        }
                        try fileManager.moveItem(atPath: normalizedWorkingPath, toPath: finalPath)
                        resolvedPath = finalPath
                    } catch {
                        resolvedPath = normalizedWorkingPath
                    }
                }
            } else {
                if let tempFinalizingPath = orphanedFinalizingTempPath(for: finalPath, fileManager: fileManager) {
                    do {
                        if fileManager.fileExists(atPath: finalPath) {
                            try fileManager.removeItem(atPath: finalPath)
                        }
                        try fileManager.moveItem(atPath: tempFinalizingPath, toPath: finalPath)
                        resolvedPath = finalPath
                    } catch {
                        resolvedPath = tempFinalizingPath
                    }
                } else {
                    resolvedPath = nil
                }
            }

            let resolvedAttributes = resolvedPath.flatMap { try? fileManager.attributesOfItem(atPath: $0) }
            let observedSize = (resolvedAttributes?[.size] as? NSNumber)?.int64Value ?? (row.sizeBytes > 0 ? row.sizeBytes : nil)
            let modifiedAtUnix = ((resolvedAttributes?[.modificationDate] as? Date)?.timeIntervalSince1970).map(Int64.init)
            let endedUnix = modifiedAtUnix ?? now

            let wallClockDuration = row.startedAt > 0 ? max(0, endedUnix - row.startedAt) : 0
            let stabilizedDuration = max(row.durationSeconds, Double(wallClockDuration))

            let status: String
            if resolvedPath != nil {
                status = "completed_with_warning"
                summary.finalizedWithWarning += 1
            } else {
                status = "interrupted_missing"
                summary.markedMissing += 1
            }

            let sql = """
            UPDATE recordings
            SET ended_at = COALESCE(ended_at, ?),
                duration_seconds = CASE
                    WHEN COALESCE(duration_seconds, 0) > ? THEN duration_seconds
                    ELSE ?
                END,
                file_size_bytes = CASE
                    WHEN ? IS NOT NULL THEN ?
                    ELSE file_size_bytes
                END,
                file_path = COALESCE(?, file_path),
                working_file_path = NULL,
                status = ?,
                file_exists = ?,
                missing_since = CASE
                    WHEN ? = 1 THEN NULL
                    ELSE COALESCE(missing_since, ?)
                END,
                file_last_seen_at = CASE
                    WHEN ? = 1 THEN ?
                    ELSE file_last_seen_at
                END,
                file_last_modified_at = COALESCE(?, file_last_modified_at),
                updated_at = ?
            WHERE id = ?
            """

            guard let statement = prepare(database: database, sql: sql) else { continue }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, endedUnix)
            sqlite3_bind_double(statement, 2, stabilizedDuration)
            sqlite3_bind_double(statement, 3, stabilizedDuration)
            if let observedSize {
                sqlite3_bind_int64(statement, 4, observedSize)
                sqlite3_bind_int64(statement, 5, observedSize)
            } else {
                sqlite3_bind_null(statement, 4)
                sqlite3_bind_null(statement, 5)
            }
            bindText(statement: statement, index: 6, value: resolvedPath)
            bindText(statement: statement, index: 7, value: status)
            sqlite3_bind_int(statement, 8, resolvedPath == nil ? 0 : 1)
            sqlite3_bind_int(statement, 9, resolvedPath == nil ? 0 : 1)
            sqlite3_bind_int64(statement, 10, now)
            sqlite3_bind_int(statement, 11, resolvedPath == nil ? 0 : 1)
            sqlite3_bind_int64(statement, 12, now)
            if let modifiedAtUnix {
                sqlite3_bind_int64(statement, 13, modifiedAtUnix)
            } else {
                sqlite3_bind_null(statement, 13)
            }
            sqlite3_bind_int64(statement, 14, now)
            sqlite3_bind_int64(statement, 15, row.id)

            _ = sqlite3_step(statement)

            appendSystemEvent(
                recordingID: row.id,
                level: "WARN",
                eventType: row.originalStatus == "finalizing" ? "abandoned_finalizing_recovered" : "abandoned_active_recovered",
                message: row.originalStatus == "finalizing"
                    ? "Recovered stale finalizing recording after app restart"
                    : "Recovered stale active recording after app restart",
                database: database
            )

            if let resolvedPath,
               URL(fileURLWithPath: resolvedPath).pathExtension.lowercased() == "mp4",
               fileManager.fileExists(atPath: resolvedPath),
               queuedRepairPaths.insert(resolvedPath).inserted {
                summary.autoRepairCandidates.append(
                    ActiveRecordingAutoRepairCandidate(
                        path: resolvedPath,
                        channelUsername: row.channelUsername
                    )
                )
            }
        }

        return summary
    }

    func fetchLibraryEntries(limit: Int? = nil, includeMissing: Bool = false) async -> [RecordingLedgerEntry] {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return []
        }

        var sql = """
        SELECT
            r.file_path,
            r.working_file_path,
            c.username,
            COALESCE(r.container, ''),
            COALESCE(r.file_size_bytes, 0),
            COALESCE(r.duration_seconds, 0),
            r.started_at,
            r.ended_at,
            COALESCE(r.file_last_modified_at, r.ended_at, r.updated_at, r.created_at, 0),
            COALESCE(r.file_exists, 0),
            r.status
        FROM recordings r
        JOIN channels c ON c.id = r.channel_id
        """

        if !includeMissing {
            sql += " WHERE (COALESCE(r.file_exists, 0) = 1 OR r.status IN ('active', 'finalizing'))"
            sql += " AND r.status != 'deleted'"
        } else {
            sql += " WHERE r.status != 'deleted'"
        }
        sql += " ORDER BY COALESCE(r.file_last_modified_at, r.ended_at, r.updated_at, r.created_at, 0) DESC"

        if let limit, limit > 0 {
            sql += " LIMIT \(limit)"
        }

        guard let statement = prepare(database: database, sql: sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        var entries: [RecordingLedgerEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = columnText(statement: statement, index: 0), !path.isEmpty else { continue }
            let workingFilePath = columnText(statement: statement, index: 1)
            let channel = columnText(statement: statement, index: 2) ?? "unknown"
            let container = columnText(statement: statement, index: 3) ?? ""
            let sizeBytes = sqlite3_column_int64(statement, 4)
            let durationSeconds = sqlite3_column_double(statement, 5)
            let startedAt = optionalDate(statement: statement, index: 6)
            let endedAt = optionalDate(statement: statement, index: 7)
            let modifiedUnix = sqlite3_column_int64(statement, 8)
            let fileExists = sqlite3_column_int(statement, 9) != 0
            let status = columnText(statement: statement, index: 10) ?? "unknown"

            let ext = container.isEmpty ? URL(fileURLWithPath: path).pathExtension.lowercased() : container.lowercased()
            let modifiedAt = Date(timeIntervalSince1970: TimeInterval(modifiedUnix))

            entries.append(
                RecordingLedgerEntry(
                    path: path,
                    workingFilePath: normalizeOptionalPath(workingFilePath),
                    channelUsername: channel,
                    fileExtension: ext,
                    fileSizeBytes: sizeBytes,
                    durationSeconds: durationSeconds,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    modifiedAt: modifiedAt,
                    fileExists: fileExists,
                    status: status
                )
            )
        }

        return entries
    }

    func fetchChannelRecordingEntries(
        username: String,
        includeMissing: Bool = false,
        limit: Int? = nil
    ) async -> [RecordingLedgerEntry] {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return []
        }

        var sql = """
        SELECT
            r.file_path,
            r.working_file_path,
            c.username,
            COALESCE(r.container, ''),
            COALESCE(r.file_size_bytes, 0),
            COALESCE(r.duration_seconds, 0),
            r.started_at,
            r.ended_at,
            COALESCE(r.file_last_modified_at, r.ended_at, r.updated_at, r.created_at, 0),
            COALESCE(r.file_exists, 0),
            r.status
        FROM recordings r
        JOIN channels c ON c.id = r.channel_id
        WHERE c.username = ?
        """

        if !includeMissing {
            sql += " AND (COALESCE(r.file_exists, 0) = 1 OR r.status = 'active')"
        }
        sql += " AND r.status != 'deleted'"
        sql += " ORDER BY COALESCE(r.file_last_modified_at, r.ended_at, r.updated_at, r.created_at, 0) DESC"

        if let limit, limit > 0 {
            sql += " LIMIT \(limit)"
        }

        guard let statement = prepare(database: database, sql: sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        bindText(statement: statement, index: 1, value: username)

        var entries: [RecordingLedgerEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = columnText(statement: statement, index: 0), !path.isEmpty else { continue }
            let workingFilePath = columnText(statement: statement, index: 1)
            let channel = columnText(statement: statement, index: 2) ?? username
            let container = columnText(statement: statement, index: 3) ?? ""
            let sizeBytes = sqlite3_column_int64(statement, 4)
            let durationSeconds = sqlite3_column_double(statement, 5)
            let startedAt = optionalDate(statement: statement, index: 6)
            let endedAt = optionalDate(statement: statement, index: 7)
            let modifiedUnix = sqlite3_column_int64(statement, 8)
            let fileExists = sqlite3_column_int(statement, 9) != 0
            let status = columnText(statement: statement, index: 10) ?? "unknown"

            let ext = container.isEmpty ? URL(fileURLWithPath: path).pathExtension.lowercased() : container.lowercased()
            let modifiedAt = Date(timeIntervalSince1970: TimeInterval(modifiedUnix))

            entries.append(
                RecordingLedgerEntry(
                    path: path,
                    workingFilePath: normalizeOptionalPath(workingFilePath),
                    channelUsername: channel,
                    fileExtension: ext,
                    fileSizeBytes: sizeBytes,
                    durationSeconds: durationSeconds,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    modifiedAt: modifiedAt,
                    fileExists: fileExists,
                    status: status
                )
            )
        }

        return entries
    }

    func fetchRecordingDetail(filePath: String) async -> RecordingLedgerDetail? {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return nil
        }

        let normalizedPath = normalizePath(filePath)
        let sql = """
        SELECT
            r.id,
            r.file_path,
            r.working_file_path,
            c.username,
            COALESCE(r.container, ''),
            r.status,
            COALESCE(r.duration_seconds, 0),
            COALESCE(r.file_size_bytes, 0),
            COALESCE(r.file_exists, 0),
            r.started_at,
            r.ended_at,
            r.remuxed_at,
            r.first_person_detected_at,
            r.last_person_detected_at,
            COALESCE(r.no_person_duration_seconds, 0),
            COALESCE(r.segment_retry_count, 0),
            COALESCE(r.consecutive_segment_failures, 0),
            COALESCE(r.cloudflare_block_count, 0),
            COALESCE(r.timeline_mismatch_count, 0),
            COALESCE(r.audio_present, -1),
            r.missing_since,
            r.file_last_seen_at,
            r.file_last_modified_at,
            COALESCE(r.is_remuxed, 0),
            COALESCE(r.is_backfilled, 0)
        FROM recordings r
        JOIN channels c ON c.id = r.channel_id
        WHERE r.file_path = ?
        LIMIT 1
        """

        guard let statement = prepare(database: database, sql: sql) else { return nil }
        defer { sqlite3_finalize(statement) }

        bindText(statement: statement, index: 1, value: normalizedPath)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let recordingID = sqlite3_column_int64(statement, 0)
        guard let path = columnText(statement: statement, index: 1) else {
            return nil
        }

        let workingFilePath = normalizeOptionalPath(columnText(statement: statement, index: 2))
        let channelUsername = columnText(statement: statement, index: 3) ?? "unknown"
        let container = columnText(statement: statement, index: 4) ?? ""
        let status = columnText(statement: statement, index: 5) ?? "unknown"
        let durationSeconds = sqlite3_column_double(statement, 6)
        let fileSizeBytes = sqlite3_column_int64(statement, 7)
        let fileExists = sqlite3_column_int(statement, 8) != 0
        let fileExtension = container.isEmpty ? URL(fileURLWithPath: path).pathExtension.lowercased() : container.lowercased()

        return RecordingLedgerDetail(
            id: recordingID,
            path: normalizePath(path),
            workingFilePath: workingFilePath,
            channelUsername: channelUsername,
            fileExtension: fileExtension,
            status: status,
            durationSeconds: durationSeconds,
            fileSizeBytes: fileSizeBytes,
            fileExists: fileExists,
            startedAt: optionalDate(statement: statement, index: 9),
            endedAt: optionalDate(statement: statement, index: 10),
            remuxedAt: optionalDate(statement: statement, index: 11),
            firstPersonDetectedAt: optionalDate(statement: statement, index: 12),
            lastPersonDetectedAt: optionalDate(statement: statement, index: 13),
            noPersonDurationSeconds: Int(sqlite3_column_int64(statement, 14)),
            segmentRetryCount: Int(sqlite3_column_int64(statement, 15)),
            consecutiveSegmentFailures: Int(sqlite3_column_int64(statement, 16)),
            cloudflareBlockCount: Int(sqlite3_column_int64(statement, 17)),
            timelineMismatchCount: Int(sqlite3_column_int64(statement, 18)),
            audioPresent: Int(sqlite3_column_int64(statement, 19)),
            missingSince: optionalDate(statement: statement, index: 20),
            fileLastSeenAt: optionalDate(statement: statement, index: 21),
            fileLastModifiedAt: optionalDate(statement: statement, index: 22),
            isRemuxed: sqlite3_column_int(statement, 23) != 0,
            isBackfilled: sqlite3_column_int(statement, 24) != 0,
            events: fetchRecordingEvents(recordingID: recordingID, database: database)
        )
    }

    func fetchStatusByPath(paths: [String]) async -> [String: String] {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return [:]
        }

        let normalizedPaths = Array(Set(paths.map(normalizePath))).filter { !$0.isEmpty }
        guard !normalizedPaths.isEmpty else { return [:] }

        var statuses: [String: String] = [:]
        let chunkSize = 400
        var start = 0

        while start < normalizedPaths.count {
            let end = min(start + chunkSize, normalizedPaths.count)
            let chunk = Array(normalizedPaths[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = "SELECT file_path, status FROM recordings WHERE file_path IN (\(placeholders))"

            guard let statement = prepare(database: database, sql: sql) else {
                start = end
                continue
            }

            for (offset, path) in chunk.enumerated() {
                bindText(statement: statement, index: Int32(offset + 1), value: path)
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = columnText(statement: statement, index: 0),
                      let status = columnText(statement: statement, index: 1) else {
                    continue
                }
                statuses[path] = status
            }

            sqlite3_finalize(statement)
            start = end
        }

        return statuses
    }

    func markRecordingMovedToTrash(filePath: String) async {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return
        }

        let normalizedPath = normalizePath(filePath)
        let now = nowUnix()
        let sql = """
        UPDATE recordings
        SET status = 'deleted',
            file_exists = 0,
            missing_since = NULL,
            updated_at = ?
        WHERE file_path = ?
        """

        guard let statement = prepare(database: database, sql: sql) else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, now)
        sqlite3_bind_int64(statement, 2, now)
        bindText(statement: statement, index: 3, value: normalizedPath)
        _ = sqlite3_step(statement)

        if let recordingID = recordingID(forPath: normalizedPath, database: database) {
            appendSystemEvent(
                recordingID: recordingID,
                level: "INFO",
                eventType: "moved_to_trash",
                message: "Recording was explicitly moved to Trash",
                database: database
            )
        }
    }

    func markAutoRepairOutcome(filePath: String, failureReason: String?) async {
        guard let database = openIfNeeded(databaseURL: databaseURL ?? defaultDatabaseURL()) else {
            return
        }

        let normalizedPath = normalizePath(filePath)
        let now = nowUnix()

        if let failureReason {
            if let recordingID = recordingID(forPath: normalizedPath, database: database) {
                appendSystemEvent(
                    recordingID: recordingID,
                    level: "WARN",
                    eventType: "abandoned_active_auto_repair_failed",
                    message: failureReason,
                    database: database
                )
            }
            return
        }

        let sql = """
        UPDATE recordings
        SET status = 'completed',
            is_remuxed = 1,
            remuxed_at = CASE WHEN remuxed_at IS NULL THEN ? ELSE remuxed_at END,
            file_exists = 1,
            missing_since = NULL,
            file_last_seen_at = CASE
                WHEN file_last_seen_at IS NULL THEN ?
                ELSE file_last_seen_at
            END,
            updated_at = ?
        WHERE file_path = ?
        """

        guard let statement = prepare(database: database, sql: sql) else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, now)
        sqlite3_bind_int64(statement, 2, now)
        sqlite3_bind_int64(statement, 3, now)
        bindText(statement: statement, index: 4, value: normalizedPath)
        _ = sqlite3_step(statement)

        if let recordingID = recordingID(forPath: normalizedPath, database: database) {
            appendSystemEvent(
                recordingID: recordingID,
                level: "INFO",
                eventType: "abandoned_active_auto_repair_succeeded",
                message: "Automatic startup repair finalized recovered recording",
                database: database
            )
        }
    }

    // MARK: - Internal helpers

    private func openIfNeeded(databaseURL: URL) -> OpaquePointer? {
        if let existing = database {
            return existing
        }

        let directory = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db {
                sqlite3_close(db)
            }
            return nil
        }

        self.database = db
        self.databaseURL = databaseURL
        configureDatabase(database: db)
        createSchema(database: db)
        return db
    }

    private func defaultDatabaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = appSupport.appendingPathComponent("ChaturbateDVR")
        return appFolder.appendingPathComponent("recordings.sqlite")
    }

    private func configureDatabase(database: OpaquePointer) {
        _ = sqlite3_exec(database, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        _ = sqlite3_exec(database, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        _ = sqlite3_exec(database, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
    }

    private func createSchema(database: OpaquePointer) {
        let schema = """
        CREATE TABLE IF NOT EXISTS channels (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL UNIQUE,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS recordings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            channel_id INTEGER NOT NULL,
            started_at INTEGER,
            ended_at INTEGER,
            duration_seconds REAL,
            file_size_bytes INTEGER,
            file_path TEXT NOT NULL UNIQUE,
            working_file_path TEXT,
            container TEXT,
            status TEXT NOT NULL DEFAULT 'active',
            is_remuxed INTEGER NOT NULL DEFAULT 0,
            remuxed_at INTEGER,
            first_person_detected_at INTEGER,
            last_person_detected_at INTEGER,
            no_person_duration_seconds INTEGER NOT NULL DEFAULT 0,
            segment_retry_count INTEGER NOT NULL DEFAULT 0,
            consecutive_segment_failures INTEGER NOT NULL DEFAULT 0,
            cloudflare_block_count INTEGER NOT NULL DEFAULT 0,
            timeline_mismatch_count INTEGER NOT NULL DEFAULT 0,
            audio_present INTEGER NOT NULL DEFAULT -1,
            missing_since INTEGER,
            file_last_seen_at INTEGER,
            file_last_modified_at INTEGER,
            file_exists INTEGER NOT NULL DEFAULT 1,
            is_backfilled INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            FOREIGN KEY(channel_id) REFERENCES channels(id)
        );

        CREATE TABLE IF NOT EXISTS recording_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            recording_id INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            level TEXT NOT NULL,
            event_type TEXT NOT NULL,
            message TEXT NOT NULL,
            metadata_json TEXT,
            FOREIGN KEY(recording_id) REFERENCES recordings(id)
        );

        CREATE INDEX IF NOT EXISTS idx_recordings_channel_started
            ON recordings(channel_id, started_at DESC);
        CREATE INDEX IF NOT EXISTS idx_recordings_status
            ON recordings(status, file_exists);
        CREATE INDEX IF NOT EXISTS idx_recordings_last_seen
            ON recordings(file_last_seen_at DESC);
        CREATE INDEX IF NOT EXISTS idx_recording_events_recording_time
            ON recording_events(recording_id, created_at);
        """

        _ = sqlite3_exec(database, schema, nil, nil, nil)
        ensureRecordingColumns(database: database)
        applyMigrations(database: database)
    }

    private func ensureRecordingColumns(database: OpaquePointer) {
        if !columnExists(table: "recordings", column: "audio_present", database: database) {
            _ = sqlite3_exec(database, "ALTER TABLE recordings ADD COLUMN audio_present INTEGER NOT NULL DEFAULT -1;", nil, nil, nil)
        }
    }

    private func applyMigrations(database: OpaquePointer) {
        let currentVersion = databaseUserVersion(database: database)

        if currentVersion < 1 {
            // Legacy releases used 'missing' for explicit trash actions.
            _ = sqlite3_exec(database, "UPDATE recordings SET status = 'deleted' WHERE status = 'missing';", nil, nil, nil)
            setDatabaseUserVersion(database: database, version: 1)
        }
    }

    private func databaseUserVersion(database: OpaquePointer) -> Int {
        let sql = "PRAGMA user_version;"
        guard let statement = prepare(database: database, sql: sql) else { return 0 }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func setDatabaseUserVersion(database: OpaquePointer, version: Int) {
        _ = sqlite3_exec(database, "PRAGMA user_version = \(max(version, 0));", nil, nil, nil)
    }

    private func fetchRecordingEvents(recordingID: Int64, database: OpaquePointer) -> [RecordingEventEntry] {
        let sql = """
        SELECT id, created_at, level, event_type, message, metadata_json
        FROM recording_events
        WHERE recording_id = ?
        ORDER BY created_at DESC, id DESC
        """

        guard let statement = prepare(database: database, sql: sql) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, recordingID)

        var events: [RecordingEventEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let createdAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)))
            let level = columnText(statement: statement, index: 2) ?? "INFO"
            let eventType = columnText(statement: statement, index: 3) ?? "unknown"
            let message = columnText(statement: statement, index: 4) ?? ""
            let metadataJSON = columnText(statement: statement, index: 5)
            events.append(
                RecordingEventEntry(
                    id: id,
                    createdAt: createdAt,
                    level: level,
                    eventType: eventType,
                    message: message,
                    metadataJSON: metadataJSON
                )
            )
        }

        return events
    }

    private func optionalDate(statement: OpaquePointer?, index: Int32) -> Date? {
        guard let statement, sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, index)))
    }

    private func columnExists(table: String, column: String, database: OpaquePointer) -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        guard let statement = prepare(database: database, sql: sql) else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = columnText(statement: statement, index: 1), name == column {
                return true
            }
        }

        return false
    }

    private func ensureChannelID(username: String, database: OpaquePointer) -> Int64 {
        if let existing = channelID(username: username, database: database) {
            let sql = "UPDATE channels SET updated_at = ? WHERE id = ?"
            if let statement = prepare(database: database, sql: sql) {
                sqlite3_bind_int64(statement, 1, nowUnix())
                sqlite3_bind_int64(statement, 2, existing)
                _ = sqlite3_step(statement)
                sqlite3_finalize(statement)
            }
            return existing
        }

        let now = nowUnix()
        let insert = "INSERT INTO channels (username, created_at, updated_at) VALUES (?, ?, ?)"
        guard let statement = prepare(database: database, sql: insert) else { return -1 }
        defer { sqlite3_finalize(statement) }

        bindText(statement: statement, index: 1, value: username)
        sqlite3_bind_int64(statement, 2, now)
        sqlite3_bind_int64(statement, 3, now)

        guard sqlite3_step(statement) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(database)
    }

    private func channelID(username: String, database: OpaquePointer) -> Int64? {
        let sql = "SELECT id FROM channels WHERE username = ? LIMIT 1"
        guard let statement = prepare(database: database, sql: sql) else { return nil }
        defer { sqlite3_finalize(statement) }

        bindText(statement: statement, index: 1, value: username)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func recordingID(forPath path: String, database: OpaquePointer) -> Int64? {
        let sql = "SELECT id FROM recordings WHERE file_path = ? LIMIT 1"
        guard let statement = prepare(database: database, sql: sql) else { return nil }
        defer { sqlite3_finalize(statement) }

        bindText(statement: statement, index: 1, value: normalizePath(path))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func insertBackfilledFile(path: String, channelID: Int64, repairedPaths: Set<String>, database: OpaquePointer) async -> Bool {
        let normalizedPath = normalizePath(path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: normalizedPath) else {
            return false
        }

        let sizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let createdAt = (attributes[.creationDate] as? Date)
        let modifiedAt = (attributes[.modificationDate] as? Date) ?? Date()
        let durationSeconds = await durationFromMediaFile(path: normalizedPath)
        let audioPresent = await audioPresenceFromMediaFile(path: normalizedPath)

        let endUnix = Int64(modifiedAt.timeIntervalSince1970)
        let startUnix: Int64
        if let createdAt {
            startUnix = Int64(createdAt.timeIntervalSince1970)
        } else if let durationSeconds {
            startUnix = max(0, endUnix - Int64(durationSeconds.rounded()))
        } else {
            startUnix = endUnix
        }

        let now = nowUnix()
        let ext = URL(fileURLWithPath: normalizedPath).pathExtension.lowercased()
        let remuxed = repairedPaths.contains(normalizedPath)

        let sql = """
        INSERT INTO recordings (
            channel_id, started_at, ended_at, duration_seconds, file_size_bytes,
            file_path, working_file_path, container, status, is_remuxed, remuxed_at,
            first_person_detected_at, last_person_detected_at,
            audio_present,
            missing_since, file_last_seen_at, file_last_modified_at,
            file_exists, is_backfilled, created_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, NULL, ?, 'backfilled', ?, ?, NULL, NULL, ?, NULL, ?, ?, 1, 1, ?, ?)
        """

        guard let statement = prepare(database: database, sql: sql) else { return false }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, channelID)
        sqlite3_bind_int64(statement, 2, startUnix)
        sqlite3_bind_int64(statement, 3, endUnix)
        if let durationSeconds {
            sqlite3_bind_double(statement, 4, durationSeconds)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_int64(statement, 5, sizeBytes)
        bindText(statement: statement, index: 6, value: normalizedPath)
        bindText(statement: statement, index: 7, value: ext)
        sqlite3_bind_int(statement, 8, remuxed ? 1 : 0)
        if remuxed {
            sqlite3_bind_int64(statement, 9, now)
        } else {
            sqlite3_bind_null(statement, 9)
        }
        sqlite3_bind_int(statement, 10, Int32(audioPresent))
        sqlite3_bind_int64(statement, 11, now)
        sqlite3_bind_int64(statement, 12, endUnix)
        sqlite3_bind_int64(statement, 13, now)
        sqlite3_bind_int64(statement, 14, now)

        guard sqlite3_step(statement) == SQLITE_DONE else { return false }

        let insertedID = sqlite3_last_insert_rowid(database)
        appendSystemEvent(
            recordingID: insertedID,
            level: "INFO",
            eventType: "backfill_inserted",
            message: "Backfilled from existing recording file",
            database: database
        )
        return true
    }

    private func insertMissingBackfilledRecord(path: String, channelID: Int64, database: OpaquePointer) -> Bool {
        let now = nowUnix()
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let sql = """
        INSERT INTO recordings (
            channel_id, started_at, ended_at, duration_seconds, file_size_bytes,
            file_path, working_file_path, container, status, is_remuxed, remuxed_at,
            first_person_detected_at, last_person_detected_at,
            missing_since, file_last_seen_at, file_last_modified_at,
            file_exists, is_backfilled, created_at, updated_at
        )
        VALUES (?, NULL, NULL, NULL, NULL, ?, NULL, ?, 'missing', 0, NULL, NULL, NULL, ?, NULL, NULL, 0, 1, ?, ?)
        """

        guard let statement = prepare(database: database, sql: sql) else { return false }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, channelID)
        bindText(statement: statement, index: 2, value: path)
        bindText(statement: statement, index: 3, value: ext)
        sqlite3_bind_int64(statement, 4, now)
        sqlite3_bind_int64(statement, 5, now)
        sqlite3_bind_int64(statement, 6, now)

        guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        let insertedID = sqlite3_last_insert_rowid(database)
        appendSystemEvent(
            recordingID: insertedID,
            level: "WARN",
            eventType: "backfill_missing",
            message: "Historical recording path missing during backfill: \(path)",
            database: database
        )
        return true
    }

    private func loadRecordingRows(database: OpaquePointer) -> [RecordingRow] {
        let sql = """
        SELECT id, file_path, status, COALESCE(file_size_bytes, 0), COALESCE(file_last_modified_at, 0)
        FROM recordings
        WHERE status NOT IN ('active', 'finalizing', 'deleted')
        """

        guard let statement = prepare(database: database, sql: sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        var rows: [RecordingRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let path = columnText(statement: statement, index: 1) ?? ""
            let status = columnText(statement: statement, index: 2) ?? "completed"
            let sizeBytes = sqlite3_column_int64(statement, 3)
            let modified = sqlite3_column_int64(statement, 4)
            rows.append(RecordingRow(id: id, path: path, status: status, sizeBytes: sizeBytes, modifiedAt: modified))
        }
        return rows
    }

    private func loadActiveRecordingRows(activeBefore cutoffUnix: Int64, database: OpaquePointer) -> [ActiveRecordingRow] {
        let sql = """
        SELECT
                        r.id,
                        c.username,
                        r.file_path,
                        r.working_file_path,
                        COALESCE(r.started_at, r.created_at, r.updated_at, 0),
                        COALESCE(r.duration_seconds, 0),
                        COALESCE(r.file_size_bytes, 0),
                        r.status
                FROM recordings r
                JOIN channels c ON c.id = r.channel_id
        WHERE status IN ('active', 'finalizing')
                    AND COALESCE(r.updated_at, 0) <= ?
        """

        guard let statement = prepare(database: database, sql: sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, cutoffUnix)

        var rows: [ActiveRecordingRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let channelUsername = columnText(statement: statement, index: 1) ?? "unknown"
            let path = columnText(statement: statement, index: 2) ?? ""
            let workingPath = columnText(statement: statement, index: 3)
            let startedAt = sqlite3_column_int64(statement, 4)
            let duration = sqlite3_column_double(statement, 5)
            let sizeBytes = sqlite3_column_int64(statement, 6)
            let originalStatus = columnText(statement: statement, index: 7) ?? "active"

            rows.append(
                ActiveRecordingRow(
                    id: id,
                    channelUsername: channelUsername,
                    path: path,
                    workingPath: workingPath,
                    startedAt: startedAt,
                    durationSeconds: duration,
                    sizeBytes: sizeBytes,
                    originalStatus: originalStatus
                )
            )
        }
        return rows
    }

    private func buildCatalog(rootPath: String) -> (byPath: [String: CatalogEntry], bySize: [Int64: [CatalogEntry]]) {
        let allowedExtensions: Set<String> = ["ts", "mp4", "mkv", "mov", "m4v"]
        guard FileManager.default.fileExists(atPath: rootPath) else {
            return ([:], [:])
        }

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ([:], [:])
        }

        var byPath: [String: CatalogEntry] = [:]
        var bySize: [Int64: [CatalogEntry]] = [:]

        while let fileURL = enumerator.nextObject() as? URL {
            guard !Self.isIgnoredInProgressFilename(fileURL.lastPathComponent) else { continue }
            guard allowedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }

            let path = normalizePath(fileURL.path)
            let sizeBytes = Int64(values.fileSize ?? 0)
            let modifiedAt = Int64((values.contentModificationDate ?? Date.distantPast).timeIntervalSince1970)
            let entry = CatalogEntry(path: path, sizeBytes: sizeBytes, modifiedAt: modifiedAt)

            byPath[path] = entry
            bySize[sizeBytes, default: []].append(entry)
        }

        return (byPath, bySize)
    }

    private func findMovedCandidate(
        for row: RecordingRow,
        catalog: (byPath: [String: CatalogEntry], bySize: [Int64: [CatalogEntry]]),
        consumedPaths: Set<String>
    ) -> CatalogEntry? {
        guard row.sizeBytes > 0, let candidates = catalog.bySize[row.sizeBytes], !candidates.isEmpty else {
            return nil
        }

        let oldURL = URL(fileURLWithPath: row.path)
        let oldName = oldURL.lastPathComponent.lowercased()
        let oldExt = oldURL.pathExtension.lowercased()

        let available = candidates.filter { !consumedPaths.contains($0.path) && URL(fileURLWithPath: $0.path).pathExtension.lowercased() == oldExt }
        guard !available.isEmpty else { return nil }

        if let exactName = available.first(where: { URL(fileURLWithPath: $0.path).lastPathComponent.lowercased() == oldName }) {
            return exactName
        }

        let closeMtime = available.filter { abs($0.modifiedAt - row.modifiedAt) <= 5 }
        if closeMtime.count == 1 {
            return closeMtime[0]
        }

        if available.count == 1 {
            return available[0]
        }

        return nil
    }

    private func updateRecordingAsSeen(rowID: Int64, status: String, entry: CatalogEntry, database: OpaquePointer) {
        let normalizedStatus: String
        if status == "missing" {
            normalizedStatus = "recovered"
        } else if status == "moved" {
            normalizedStatus = "completed"
        } else {
            normalizedStatus = status
        }

        let sql = """
        UPDATE recordings
        SET status = ?,
            file_exists = 1,
            missing_since = NULL,
            file_size_bytes = ?,
            file_last_modified_at = ?,
            file_last_seen_at = ?,
            updated_at = ?
        WHERE id = ?
        """

        guard let statement = prepare(database: database, sql: sql) else { return }
        defer { sqlite3_finalize(statement) }

        let now = nowUnix()
        bindText(statement: statement, index: 1, value: normalizedStatus)
        sqlite3_bind_int64(statement, 2, entry.sizeBytes)
        sqlite3_bind_int64(statement, 3, entry.modifiedAt)
        sqlite3_bind_int64(statement, 4, now)
        sqlite3_bind_int64(statement, 5, now)
        sqlite3_bind_int64(statement, 6, rowID)

        _ = sqlite3_step(statement)
    }

    private func moveRecording(rowID: Int64, newEntry: CatalogEntry, database: OpaquePointer) {
        let sql = """
        UPDATE recordings
        SET file_path = ?,
            status = 'moved',
            file_exists = 1,
            missing_since = NULL,
            file_size_bytes = ?,
            file_last_modified_at = ?,
            file_last_seen_at = ?,
            updated_at = ?
        WHERE id = ?
        """

        guard let statement = prepare(database: database, sql: sql) else { return }
        defer { sqlite3_finalize(statement) }

        let now = nowUnix()
        bindText(statement: statement, index: 1, value: newEntry.path)
        sqlite3_bind_int64(statement, 2, newEntry.sizeBytes)
        sqlite3_bind_int64(statement, 3, newEntry.modifiedAt)
        sqlite3_bind_int64(statement, 4, now)
        sqlite3_bind_int64(statement, 5, now)
        sqlite3_bind_int64(statement, 6, rowID)

        _ = sqlite3_step(statement)
    }

    private func markRecordingMissing(rowID: Int64, alreadyMissing: Bool, database: OpaquePointer) {
        let sql = """
        UPDATE recordings
        SET status = 'missing',
            file_exists = 0,
            missing_since = CASE WHEN missing_since IS NULL THEN ? ELSE missing_since END,
            updated_at = ?
        WHERE id = ?
        """

        guard let statement = prepare(database: database, sql: sql) else { return }
        defer { sqlite3_finalize(statement) }

        let now = nowUnix()
        sqlite3_bind_int64(statement, 1, now)
        sqlite3_bind_int64(statement, 2, now)
        sqlite3_bind_int64(statement, 3, rowID)
        _ = sqlite3_step(statement)

        if !alreadyMissing {
            appendSystemEvent(
                recordingID: rowID,
                level: "WARN",
                eventType: "file_missing",
                message: "Recording file no longer exists at expected path",
                database: database
            )
        }
    }

    private func appendSystemEvent(
        recordingID: Int64,
        level: String,
        eventType: String,
        message: String,
        database: OpaquePointer
    ) {
        let sql = """
        INSERT INTO recording_events (recording_id, created_at, level, event_type, message, metadata_json)
        VALUES (?, ?, ?, ?, ?, NULL)
        """

        guard let statement = prepare(database: database, sql: sql) else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, recordingID)
        sqlite3_bind_int64(statement, 2, nowUnix())
        bindText(statement: statement, index: 3, value: level)
        bindText(statement: statement, index: 4, value: eventType)
        bindText(statement: statement, index: 5, value: message)
        _ = sqlite3_step(statement)
    }

    private func listVideoFiles(at directoryPath: String, allowedExtensions: Set<String>) -> [String] {
        guard FileManager.default.fileExists(atPath: directoryPath) else {
            return []
        }

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) else {
            return []
        }

        return files.compactMap { filename in
            guard !Self.isIgnoredInProgressFilename(filename) else { return nil }
            let ext = (filename as NSString).pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { return nil }
            let fullPath = normalizePath((directoryPath as NSString).appendingPathComponent(filename))
            return FileManager.default.fileExists(atPath: fullPath) ? fullPath : nil
        }
    }

    private func listVideoFilesRecursively(at rootPath: String, allowedExtensions: Set<String>) -> [String] {
        guard FileManager.default.fileExists(atPath: rootPath) else {
            return []
        }

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [String] = []
        while let fileURL = enumerator.nextObject() as? URL {
            guard !Self.isIgnoredInProgressFilename(fileURL.lastPathComponent) else { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { continue }
            if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                results.append(normalizePath(fileURL.path))
            }
        }
        return results
    }

    private func durationFromMediaFile(path: String) async -> Double? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let duration = try? await asset.load(.duration) else {
            return nil
        }
        let seconds = CMTimeGetSeconds(duration)
        if seconds.isFinite, seconds > 0 {
            return seconds
        }
        return nil
    }

    private func audioPresenceFromMediaFile(path: String) async -> Int {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio) {
            return audioTracks.isEmpty ? 0 : 1
        }

        if let tracks = try? await asset.load(.tracks) {
            let hasAudio = tracks.contains { $0.mediaType == .audio }
            return hasAudio ? 1 : 0
        }

        return -1
    }

    private func prepare(database: OpaquePointer, sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        return statement
    }

    private func bindText(statement: OpaquePointer?, index: Int32, value: String?) {
        guard let statement else { return }
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func columnText(statement: OpaquePointer?, index: Int32) -> String? {
        guard let statement,
              let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.path
    }

    private func normalizeOptionalPath(_ path: String?) -> String? {
        guard let path else { return nil }
        return normalizePath(path)
    }

    private func nowUnix() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }
}
