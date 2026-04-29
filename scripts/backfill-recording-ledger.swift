import Foundation
import SQLite3
import AVFoundation

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct AppConfig: Decodable {
    let outputDirectory: String?

    func resolvedOutputPath() -> String {
        let configured = (outputDirectory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return NSString(string: configured).expandingTildeInPath
        }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("ChaturbateDVR").path
    }
}

struct ChannelConfig: Decodable {
    let username: String
    let outputDirectory: String?
    let recordingHistory: [String]?
}

func readJSON<T: Decodable>(_ path: String, as type: T.Type) throws -> T {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode(T.self, from: data)
}

func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
    guard let stmt else { return }
    guard let value else {
        sqlite3_bind_null(stmt, index)
        return
    }
    sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
}

func prepare(_ db: OpaquePointer?, _ sql: String) -> OpaquePointer? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        return nil
    }
    return stmt
}

func nowUnix() -> Int64 {
    Int64(Date().timeIntervalSince1970)
}

func normalize(_ path: String) -> String {
    URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardized.path
}

func fileDurationSeconds(path: String) -> Double? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let seconds = CMTimeGetSeconds(asset.duration)
    if seconds.isFinite, seconds > 0 {
        return seconds
    }
    return nil
}

func openDatabase(path: String) -> OpaquePointer? {
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
        if let db { sqlite3_close(db) }
        return nil
    }

    _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
    _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
    _ = sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)

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

    CREATE INDEX IF NOT EXISTS idx_recordings_channel_started ON recordings(channel_id, started_at DESC);
    CREATE INDEX IF NOT EXISTS idx_recordings_status ON recordings(status, file_exists);
    CREATE INDEX IF NOT EXISTS idx_recording_events_recording_time ON recording_events(recording_id, created_at);
    """

    guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return nil
    }

    return db
}

func channelID(db: OpaquePointer?, username: String) -> Int64? {
    guard let stmt = prepare(db, "SELECT id FROM channels WHERE username = ? LIMIT 1") else {
        return nil
    }
    defer { sqlite3_finalize(stmt) }

    bindText(stmt, 1, username)
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return sqlite3_column_int64(stmt, 0)
}

func ensureChannelID(db: OpaquePointer?, username: String) -> Int64? {
    if let existing = channelID(db: db, username: username) {
        if let stmt = prepare(db, "UPDATE channels SET updated_at = ? WHERE id = ?") {
            sqlite3_bind_int64(stmt, 1, nowUnix())
            sqlite3_bind_int64(stmt, 2, existing)
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        return existing
    }

    guard let stmt = prepare(db, "INSERT INTO channels (username, created_at, updated_at) VALUES (?, ?, ?)") else {
        return nil
    }
    defer { sqlite3_finalize(stmt) }

    let now = nowUnix()
    bindText(stmt, 1, username)
    sqlite3_bind_int64(stmt, 2, now)
    sqlite3_bind_int64(stmt, 3, now)
    guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
    return sqlite3_last_insert_rowid(db)
}

func recordingExists(db: OpaquePointer?, path: String) -> Bool {
    guard let stmt = prepare(db, "SELECT 1 FROM recordings WHERE file_path = ? LIMIT 1") else {
        return false
    }
    defer { sqlite3_finalize(stmt) }

    bindText(stmt, 1, path)
    return sqlite3_step(stmt) == SQLITE_ROW
}

func listVideoFiles(in directoryPath: String, allowedExt: Set<String>) -> [String] {
    guard FileManager.default.fileExists(atPath: directoryPath) else { return [] }
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) else { return [] }

    var results: [String] = []
    for name in entries {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard allowedExt.contains(ext) else { continue }
        let full = normalize((directoryPath as NSString).appendingPathComponent(name))
        if FileManager.default.fileExists(atPath: full) {
            results.append(full)
        }
    }
    return results
}

func listVideoFilesRecursively(in rootPath: String, allowedExt: Set<String>) -> [String] {
    guard FileManager.default.fileExists(atPath: rootPath) else { return [] }
    let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        return []
    }

    var out: [String] = []
    while let fileURL = enumerator.nextObject() as? URL {
        let ext = fileURL.pathExtension.lowercased()
        if !allowedExt.contains(ext) { continue }
        let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        if isRegular {
            out.append(normalize(fileURL.path))
        }
    }
    return out
}

func runBackfill() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = appSupport.appendingPathComponent("ChaturbateDVR")
    let markerPath = appFolder.appendingPathComponent("recording-ledger-backfill.done").path
        let channelsPath = appFolder.appendingPathComponent("channels.json").path
        let appConfigPath = appFolder.appendingPathComponent("appconfig.json").path
        let dbPath = appFolder.appendingPathComponent("recordings.sqlite").path

        guard fm.fileExists(atPath: channelsPath) else {
            fputs("No channels.json found at \(channelsPath)\n", stderr)
            exit(1)
        }

        let channels: [ChannelConfig]
        let appConfig: AppConfig
        do {
            channels = try readJSON(channelsPath, as: [ChannelConfig].self)
            if fm.fileExists(atPath: appConfigPath) {
                appConfig = try readJSON(appConfigPath, as: AppConfig.self)
            } else {
                appConfig = AppConfig(outputDirectory: nil)
            }
        } catch {
            fputs("Failed to read config JSON: \(error)\n", stderr)
            exit(1)
        }

        guard let db = openDatabase(path: dbPath) else {
            fputs("Failed to open database at \(dbPath)\n", stderr)
            exit(1)
        }
        defer { sqlite3_close(db) }

        let allowedExt = Set(["ts", "mp4", "mkv", "mov", "m4v"])
        let defaultRoot = normalize(appConfig.resolvedOutputPath())

        var inserted = 0
        var skipped = 0
        var missing = 0

        for channel in channels {
            guard let channelID = ensureChannelID(db: db, username: channel.username) else {
                continue
            }

            var candidates = Set<String>()
            for historyPath in (channel.recordingHistory ?? []) {
                candidates.insert(normalize(historyPath))
            }

            let channelBase = (channel.outputDirectory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let outputRoot = channelBase.isEmpty ? defaultRoot : normalize(channelBase)
            let channelDir = normalize((outputRoot as NSString).appendingPathComponent(channel.username))
            for p in listVideoFiles(in: channelDir, allowedExt: allowedExt) {
                candidates.insert(p)
            }

            for path in candidates.sorted() {
                if recordingExists(db: db, path: path) {
                    skipped += 1
                    continue
                }

                if fm.fileExists(atPath: path) {
                    guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    if size <= 0 { continue }

                    let modifiedAt = (attrs[.modificationDate] as? Date) ?? Date()
                    let createdAt = attrs[.creationDate] as? Date
                    let endUnix = Int64(modifiedAt.timeIntervalSince1970)
                    let duration = fileDurationSeconds(path: path)
                    let startUnix: Int64
                    if let createdAt {
                        startUnix = Int64(createdAt.timeIntervalSince1970)
                    } else if let duration {
                        startUnix = max(0, endUnix - Int64(duration.rounded()))
                    } else {
                        startUnix = endUnix
                    }

                    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                    let now = nowUnix()

                    guard let stmt = prepare(db, """
                        INSERT INTO recordings (
                            channel_id, started_at, ended_at, duration_seconds, file_size_bytes,
                            file_path, working_file_path, container, status, is_remuxed, remuxed_at,
                            first_person_detected_at, last_person_detected_at,
                            missing_since, file_last_seen_at, file_last_modified_at,
                            file_exists, is_backfilled, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, NULL, ?, 'backfilled', 0, NULL, NULL, NULL, NULL, ?, ?, 1, 1, ?, ?)
                    """) else {
                        continue
                    }

                    sqlite3_bind_int64(stmt, 1, channelID)
                    sqlite3_bind_int64(stmt, 2, startUnix)
                    sqlite3_bind_int64(stmt, 3, endUnix)
                    if let duration {
                        sqlite3_bind_double(stmt, 4, duration)
                    } else {
                        sqlite3_bind_null(stmt, 4)
                    }
                    sqlite3_bind_int64(stmt, 5, size)
                    bindText(stmt, 6, path)
                    bindText(stmt, 7, ext)
                    sqlite3_bind_int64(stmt, 8, now)
                    sqlite3_bind_int64(stmt, 9, endUnix)
                    sqlite3_bind_int64(stmt, 10, now)
                    sqlite3_bind_int64(stmt, 11, now)

                    if sqlite3_step(stmt) == SQLITE_DONE {
                        inserted += 1
                    }
                    sqlite3_finalize(stmt)
                } else {
                    guard let stmt = prepare(db, """
                        INSERT INTO recordings (
                            channel_id, started_at, ended_at, duration_seconds, file_size_bytes,
                            file_path, working_file_path, container, status, is_remuxed, remuxed_at,
                            first_person_detected_at, last_person_detected_at,
                            missing_since, file_last_seen_at, file_last_modified_at,
                            file_exists, is_backfilled, created_at, updated_at
                        ) VALUES (?, NULL, NULL, NULL, NULL, ?, NULL, ?, 'missing', 0, NULL, NULL, NULL, ?, NULL, NULL, 0, 1, ?, ?)
                    """) else {
                        continue
                    }

                    let now = nowUnix()
                    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                    sqlite3_bind_int64(stmt, 1, channelID)
                    bindText(stmt, 2, path)
                    bindText(stmt, 3, ext)
                    sqlite3_bind_int64(stmt, 4, now)
                    sqlite3_bind_int64(stmt, 5, now)
                    sqlite3_bind_int64(stmt, 6, now)
                    if sqlite3_step(stmt) == SQLITE_DONE {
                        missing += 1
                    }
                    sqlite3_finalize(stmt)
                }
            }
        }

        // Orphan discovery from full output root.
        for path in listVideoFilesRecursively(in: defaultRoot, allowedExt: allowedExt) {
            if recordingExists(db: db, path: path) {
                skipped += 1
                continue
            }

            let channelName = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            if channelName.isEmpty { continue }
            guard let channelID = ensureChannelID(db: db, username: channelName) else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }

            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            if size <= 0 { continue }

            let modifiedAt = (attrs[.modificationDate] as? Date) ?? Date()
            let createdAt = attrs[.creationDate] as? Date
            let endUnix = Int64(modifiedAt.timeIntervalSince1970)
            let duration = fileDurationSeconds(path: path)
            let startUnix: Int64
            if let createdAt {
                startUnix = Int64(createdAt.timeIntervalSince1970)
            } else if let duration {
                startUnix = max(0, endUnix - Int64(duration.rounded()))
            } else {
                startUnix = endUnix
            }
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            let now = nowUnix()

            guard let stmt = prepare(db, """
                INSERT INTO recordings (
                    channel_id, started_at, ended_at, duration_seconds, file_size_bytes,
                    file_path, working_file_path, container, status, is_remuxed, remuxed_at,
                    first_person_detected_at, last_person_detected_at,
                    missing_since, file_last_seen_at, file_last_modified_at,
                    file_exists, is_backfilled, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, NULL, ?, 'backfilled', 0, NULL, NULL, NULL, NULL, ?, ?, 1, 1, ?, ?)
            """) else {
                continue
            }

            sqlite3_bind_int64(stmt, 1, channelID)
            sqlite3_bind_int64(stmt, 2, startUnix)
            sqlite3_bind_int64(stmt, 3, endUnix)
            if let duration {
                sqlite3_bind_double(stmt, 4, duration)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_int64(stmt, 5, size)
            bindText(stmt, 6, path)
            bindText(stmt, 7, ext)
            sqlite3_bind_int64(stmt, 8, now)
            sqlite3_bind_int64(stmt, 9, endUnix)
            sqlite3_bind_int64(stmt, 10, now)
            sqlite3_bind_int64(stmt, 11, now)

            if sqlite3_step(stmt) == SQLITE_DONE {
                inserted += 1
            }
            sqlite3_finalize(stmt)
        }

        print("Backfill complete")
        print("  database: \(dbPath)")
        print("  channels: \(channels.count)")
        print("  inserted: \(inserted)")
        print("  skipped_existing: \(skipped)")
        print("  missing_history_added: \(missing)")

        let formatter = ISO8601DateFormatter()
        let marker = [
            "completed_at=\(formatter.string(from: Date()))",
            "inserted=\(inserted)",
            "existing=\(skipped)",
            "missing=\(missing)"
        ].joined(separator: "\n")

        do {
            try marker.write(toFile: markerPath, atomically: true, encoding: .utf8)
            print("  marker: \(markerPath)")
        } catch {
            fputs("Warning: failed to write marker at \(markerPath): \(error)\n", stderr)
        }
}

runBackfill()
