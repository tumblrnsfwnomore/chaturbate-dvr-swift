import Foundation
import AppKit
import SQLite3
import Security
import CommonCrypto
import CryptoKit

enum SupportedBrowser: String, CaseIterable, Codable {
    case none = "None"
    case chrome = "Chrome"
    case firefox = "Firefox"
    case brave = "Brave"
    case edge = "Edge"
    case arc = "Arc"
    case safari = "Safari"
    
    var displayName: String {
        rawValue
    }
    
    var bundleIdentifier: String? {
        switch self {
        case .none:
            return nil
        case .chrome:
            return "com.google.Chrome"
        case .firefox:
            return "org.mozilla.firefox"
        case .brave:
            return "com.brave.Browser"
        case .edge:
            return "com.microsoft.edgemac"
        case .arc:
            return "company.thebrowser.Browser"
        case .safari:
            return "com.apple.Safari"
        }
    }
    
    var userAgent: String {
        switch self {
        case .none:
            return ""
        case .chrome:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        case .firefox:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:121.0) Gecko/20100101 Firefox/121.0"
        case .brave:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        case .edge:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"
        case .arc:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        case .safari:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        }
    }
    
    var cookieDatabasePath: String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        
        switch self {
        case .none:
            return nil
        case .chrome:
            return "\(homeDir)/Library/Application Support/Google/Chrome/Default/Cookies"
        case .firefox:
            // Firefox uses a profile-based system, need to find the default profile
            let profilesPath = "\(homeDir)/Library/Application Support/Firefox/Profiles"
            if let profile = findFirefoxDefaultProfile(at: profilesPath) {
                return "\(profilesPath)/\(profile)/cookies.sqlite"
            }
            return nil
        case .brave:
            return "\(homeDir)/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies"
        case .edge:
            return "\(homeDir)/Library/Application Support/Microsoft Edge/Default/Cookies"
        case .arc:
            return "\(homeDir)/Library/Application Support/Arc/User Data/Default/Cookies"
        case .safari:
            return "\(homeDir)/Library/Cookies/Cookies.binarycookies"
        }
    }
    
    var isInstalled: Bool {
        if self == .none { return true }
        
        guard let bundleId = bundleIdentifier else { return false }
        
        // Use NSWorkspace to find app by bundle identifier
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        return appURL != nil
    }
    
    private func findFirefoxDefaultProfile(at profilesPath: String) -> String? {
        guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: profilesPath) else {
            return nil
        }
        
        // Look for default-release profile first
        if let defaultProfile = profiles.first(where: { $0.contains("default-release") }) {
            return defaultProfile
        }
        
        // Fallback to any .default profile
        return profiles.first(where: { $0.hasSuffix(".default") })
    }
}

actor BrowserCookieExtractor {

    struct CookieExtractionDiagnostics {
        var lines: [String]
    }
    
    func extractCookies(for browser: SupportedBrowser, domain: String = "chaturbate.com") async -> String {
        guard browser != .none else {
            return ""
        }

        let databasePaths = cookieDatabaseCandidates(for: browser)
        guard !databasePaths.isEmpty else {
            return ""
        }

        var merged: [String: String] = [:]
        for dbPath in databasePaths {
            do {
                let cookies = try await queryCookiesFromDatabase(at: dbPath, domain: domain, browser: browser)
                for (name, value) in cookies where !name.isEmpty && !value.isEmpty {
                    if merged[name] == nil {
                        merged[name] = value
                    }
                }
            } catch {
                continue
            }
        }

        if merged.isEmpty {
            return ""
        }

        return merged.keys.sorted().compactMap { name in
            guard let value = merged[name] else { return nil }
            return "\(name)=\(value)"
        }.joined(separator: "; ")
    }

    func diagnostics(for browser: SupportedBrowser, domain: String = "chaturbate.com") async -> CookieExtractionDiagnostics {
        var lines: [String] = []
        lines.append("browser=\(browser.displayName)")

        let candidates = cookieDatabaseCandidates(for: browser)
        lines.append("db_candidate_count=\(candidates.count)")
        if candidates.isEmpty {
            return CookieExtractionDiagnostics(lines: lines)
        }

        let chromiumKey = chromiumEncryptionKey(for: browser)
        lines.append("chromium_key_available=\(chromiumKey != nil)")

        for path in candidates {
            let exists = FileManager.default.fileExists(atPath: path)
            lines.append("db_path=\(path)")
            lines.append("db_exists=\(exists)")
            guard exists else { continue }

            do {
                let stats = try await cookieStatsFromDatabase(at: path, domain: domain, browser: browser, chromiumKey: chromiumKey)
                lines.append("db_stats_total_rows=\(stats.totalRows)")
                lines.append("db_stats_non_empty_plaintext=\(stats.nonEmptyPlaintext)")
                lines.append("db_stats_attempted_decrypt=\(stats.attemptedDecrypt)")
                lines.append("db_stats_successful_decrypt=\(stats.successfulDecrypt)")
                lines.append("db_stats_unique_cookie_names=\(stats.uniqueCookieNames)")
                lines.append("db_stats_decoded_cookie_names=\(stats.decodedCookieNames)")
                lines.append("db_stats_decoded_has_sessionid=\(stats.decodedHasSessionID)")
                lines.append("db_stats_decoded_has_csrftoken=\(stats.decodedHasCSRFTOKEN)")
            } catch {
                lines.append("db_stats_error=\(error.localizedDescription)")
            }
        }

        return CookieExtractionDiagnostics(lines: lines)
    }

    private func cookieDatabaseCandidates(for browser: SupportedBrowser) -> [String] {
        switch browser {
        case .none:
            return []
        case .firefox:
            return firefoxCookieDatabases()
        case .safari:
            if let path = browser.cookieDatabasePath, FileManager.default.fileExists(atPath: path) {
                return [path]
            }
            return []
        case .chrome, .brave, .edge, .arc:
            return chromiumCookieDatabases(for: browser)
        }
    }

    private func chromiumCookieDatabases(for browser: SupportedBrowser) -> [String] {
        guard let userDataRoot = chromiumUserDataRoot(for: browser) else {
            return []
        }

        let profileNames = chromiumProfileNames(userDataRoot: userDataRoot)
        var result: [String] = []

        for profile in profileNames {
            let profileDir = (userDataRoot as NSString).appendingPathComponent(profile)
            let modern = (profileDir as NSString).appendingPathComponent("Network/Cookies")
            let legacy = (profileDir as NSString).appendingPathComponent("Cookies")

            if FileManager.default.fileExists(atPath: modern) {
                result.append(modern)
            }
            if FileManager.default.fileExists(atPath: legacy) {
                result.append(legacy)
            }
        }

        return Array(NSOrderedSet(array: result)) as? [String] ?? result
    }

    private func chromiumUserDataRoot(for browser: SupportedBrowser) -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        switch browser {
        case .chrome:
            return "\(homeDir)/Library/Application Support/Google/Chrome"
        case .brave:
            return "\(homeDir)/Library/Application Support/BraveSoftware/Brave-Browser"
        case .edge:
            return "\(homeDir)/Library/Application Support/Microsoft Edge"
        case .arc:
            return "\(homeDir)/Library/Application Support/Arc/User Data"
        default:
            return nil
        }
    }

    private func chromiumProfileNames(userDataRoot: String) -> [String] {
        var ordered: [String] = []

        // Prefer browser's last-used profile when available.
        let localStatePath = (userDataRoot as NSString).appendingPathComponent("Local State")
        if let lastUsed = chromiumLastUsedProfile(localStatePath: localStatePath) {
            ordered.append(lastUsed)
        }

        // Always include common default profile names.
        ordered.append("Default")
        ordered.append("Profile 1")

        // Discover additional profile folders.
        if let children = try? FileManager.default.contentsOfDirectory(atPath: userDataRoot) {
            let discovered = children
                .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
                .sorted()
            ordered.append(contentsOf: discovered)
        }

        return Array(NSOrderedSet(array: ordered)) as? [String] ?? ordered
    }

    private func chromiumLastUsedProfile(localStatePath: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: localStatePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let lastUsed = profile["last_used"] as? String,
              !lastUsed.isEmpty else {
            return nil
        }
        return lastUsed
    }

    private func firefoxCookieDatabases() -> [String] {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let profilesPath = "\(homeDir)/Library/Application Support/Firefox/Profiles"

        guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: profilesPath) else {
            return []
        }

        let preferred = profiles.sorted { lhs, rhs in
            let lhsScore = firefoxProfileScore(lhs)
            let rhsScore = firefoxProfileScore(rhs)
            if lhsScore == rhsScore {
                return lhs < rhs
            }
            return lhsScore > rhsScore
        }

        return preferred.compactMap { profile in
            let path = "\(profilesPath)/\(profile)/cookies.sqlite"
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
    }

    private func firefoxProfileScore(_ name: String) -> Int {
        if name.contains("default-release") { return 3 }
        if name.contains("default") { return 2 }
        return 1
    }
    
    private func queryCookiesFromDatabase(at path: String, domain: String, browser: SupportedBrowser) async throws -> [(String, String)] {
        // gallery-dl style approach:
        // 1) try direct immutable readonly access
        // 2) fallback to a temporary copy (including WAL/SHM sidecars)
        var db: OpaquePointer?
        var tempPathsToCleanup: [String] = []

        if let direct = openSQLiteReadOnlyDatabase(path: path) {
            db = direct
        } else if let copied = prepareTempSQLiteCopy(from: path) {
            tempPathsToCleanup = copied.cleanupPaths
            db = openSQLiteReadOnlyDatabase(path: copied.databasePath)
        }

        guard let db else {
            return []
        }

        defer {
            sqlite3_close(db)
            for cleanupPath in tempPathsToCleanup {
                try? FileManager.default.removeItem(atPath: cleanupPath)
            }
        }
        
        // Chrome/Brave/Edge/Arc use: name, value, host_key, path, expires_utc, is_secure, is_httponly
        // Firefox uses: name, value, host, path, expiry, isSecure, isHttpOnly
        
        let query: String
        if browser == .firefox {
            query = """
                SELECT name, value, host, path, expiry, isSecure, isHttpOnly
                FROM moz_cookies
                WHERE host LIKE '%\(domain)%'
                ORDER BY creationTime DESC
                """
        } else {
            query = """
                SELECT name, value, encrypted_value, host_key, path, expires_utc, is_secure, is_httponly
                FROM cookies
                WHERE host_key LIKE '%\(domain)%'
                ORDER BY creation_utc DESC
                """
        }
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        
        defer {
            sqlite3_finalize(statement)
        }
        
        let chromiumKey = chromiumEncryptionKey(for: browser)
        var cookies: [(name: String, value: String)] = []
        var seenNames = Set<String>()
        
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(statement, 0) else { continue }

            let name = String(cString: namePtr)
            if seenNames.contains(name) {
                continue
            }

            var value = ""
            if let valuePtr = sqlite3_column_text(statement, 1) {
                value = String(cString: valuePtr)
            }

            if value.isEmpty, browser != .firefox, let chromiumKey {
                if let encryptedBlob = readBlob(statement: statement, atColumn: 2),
                   let decryptedValue = decryptChromiumCookie(encryptedBlob, key: chromiumKey),
                   !decryptedValue.isEmpty {
                    value = decryptedValue
                }
            }

            if value.isEmpty {
                continue
            }

            seenNames.insert(name)
            cookies.append((name: name, value: value))
        }
        
        return cookies
    }

    private struct CookieStats {
        let totalRows: Int
        let nonEmptyPlaintext: Int
        let attemptedDecrypt: Int
        let successfulDecrypt: Int
        let uniqueCookieNames: Int
        let decodedCookieNames: Int
        let decodedHasSessionID: Bool
        let decodedHasCSRFTOKEN: Bool
    }

    private func cookieStatsFromDatabase(at path: String, domain: String, browser: SupportedBrowser, chromiumKey: Data?) async throws -> CookieStats {
        var db: OpaquePointer?
        var tempPathsToCleanup: [String] = []

        if let direct = openSQLiteReadOnlyDatabase(path: path) {
            db = direct
        } else if let copied = prepareTempSQLiteCopy(from: path) {
            tempPathsToCleanup = copied.cleanupPaths
            db = openSQLiteReadOnlyDatabase(path: copied.databasePath)
        }

        guard let db else {
            return CookieStats(
                totalRows: 0,
                nonEmptyPlaintext: 0,
                attemptedDecrypt: 0,
                successfulDecrypt: 0,
                uniqueCookieNames: 0,
                decodedCookieNames: 0,
                decodedHasSessionID: false,
                decodedHasCSRFTOKEN: false
            )
        }

        defer {
            sqlite3_close(db)
            for cleanupPath in tempPathsToCleanup {
                try? FileManager.default.removeItem(atPath: cleanupPath)
            }
        }

        let query: String
        if browser == .firefox {
            query = "SELECT name, value FROM moz_cookies WHERE host LIKE '%\(domain)%'"
        } else {
            query = "SELECT name, value, encrypted_value FROM cookies WHERE host_key LIKE '%\(domain)%'"
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return CookieStats(
                totalRows: 0,
                nonEmptyPlaintext: 0,
                attemptedDecrypt: 0,
                successfulDecrypt: 0,
                uniqueCookieNames: 0,
                decodedCookieNames: 0,
                decodedHasSessionID: false,
                decodedHasCSRFTOKEN: false
            )
        }
        defer { sqlite3_finalize(statement) }

        var totalRows = 0
        var nonEmptyPlaintext = 0
        var attemptedDecrypt = 0
        var successfulDecrypt = 0
        var names = Set<String>()
        var decodedNames = Set<String>()
        var decodedHasSessionID = false
        var decodedHasCSRFTOKEN = false

        while sqlite3_step(statement) == SQLITE_ROW {
            totalRows += 1

            if let namePtr = sqlite3_column_text(statement, 0) {
                names.insert(String(cString: namePtr))
            }

            var value = ""
            if let valuePtr = sqlite3_column_text(statement, 1) {
                value = String(cString: valuePtr)
            }

            if !value.isEmpty {
                nonEmptyPlaintext += 1
                if let namePtr = sqlite3_column_text(statement, 0) {
                    let cookieName = String(cString: namePtr)
                    decodedNames.insert(cookieName)
                    if cookieName == "sessionid" { decodedHasSessionID = true }
                    if cookieName == "csrftoken" { decodedHasCSRFTOKEN = true }
                }
            } else if browser != .firefox {
                if let encryptedBlob = readBlob(statement: statement, atColumn: 2), !encryptedBlob.isEmpty {
                    attemptedDecrypt += 1
                    if let chromiumKey,
                       let decryptedValue = decryptChromiumCookie(encryptedBlob, key: chromiumKey),
                       !decryptedValue.isEmpty {
                        successfulDecrypt += 1
                        if let namePtr = sqlite3_column_text(statement, 0) {
                            let cookieName = String(cString: namePtr)
                            decodedNames.insert(cookieName)
                            if cookieName == "sessionid" { decodedHasSessionID = true }
                            if cookieName == "csrftoken" { decodedHasCSRFTOKEN = true }
                        }
                    }
                }
            }
        }

        return CookieStats(
            totalRows: totalRows,
            nonEmptyPlaintext: nonEmptyPlaintext,
            attemptedDecrypt: attemptedDecrypt,
            successfulDecrypt: successfulDecrypt,
            uniqueCookieNames: names.count,
            decodedCookieNames: decodedNames.count,
            decodedHasSessionID: decodedHasSessionID,
            decodedHasCSRFTOKEN: decodedHasCSRFTOKEN
        )
    }

    private func openSQLiteReadOnlyDatabase(path: String) -> OpaquePointer? {
        // Use URI mode to mirror gallery-dl's immutable read path.
        let escapedPath = path
            .replacingOccurrences(of: "?", with: "%3f")
            .replacingOccurrences(of: "#", with: "%23")
        let uriPath = "file:\(escapedPath)?mode=ro&immutable=1"

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        if sqlite3_open_v2(uriPath, &db, flags, nil) == SQLITE_OK {
            return db
        }

        if db != nil {
            sqlite3_close(db)
        }
        return nil
    }

    private func prepareTempSQLiteCopy(from sourcePath: String) -> (databasePath: String, cleanupPaths: [String])? {
        let fm = FileManager.default
        let tempRoot = NSTemporaryDirectory()
        let id = UUID().uuidString
        let tempDbPath = (tempRoot as NSString).appendingPathComponent("cookies_temp_\(id).sqlite")

        do {
            try fm.copyItem(atPath: sourcePath, toPath: tempDbPath)
        } catch {
            return nil
        }

        var cleanupPaths: [String] = [tempDbPath]

        // Copy WAL/SHM sidecars when present; otherwise WAL-backed rows can appear missing.
        let sidecars = ["-wal", "-shm"]
        for suffix in sidecars {
            let srcSidecar = sourcePath + suffix
            let dstSidecar = tempDbPath + suffix
            if fm.fileExists(atPath: srcSidecar) {
                do {
                    try fm.copyItem(atPath: srcSidecar, toPath: dstSidecar)
                    cleanupPaths.append(dstSidecar)
                } catch {
                    // Non-fatal: best effort only.
                }
            }
        }

        return (databasePath: tempDbPath, cleanupPaths: cleanupPaths)
    }

    private func readBlob(statement: OpaquePointer?, atColumn column: Int32) -> Data? {
        let byteCount = sqlite3_column_bytes(statement, column)
        guard byteCount > 0,
              let blobPointer = sqlite3_column_blob(statement, column) else {
            return nil
        }

        return Data(bytes: blobPointer, count: Int(byteCount))
    }

    private func chromiumEncryptionKey(for browser: SupportedBrowser) -> Data? {
        let serviceName: String
        let accountName: String
        switch browser {
        case .chrome:
            serviceName = "Chrome Safe Storage"
            accountName = "Chrome"
        case .brave:
            serviceName = "Brave Safe Storage"
            accountName = "Brave"
        case .edge:
            serviceName = "Microsoft Edge Safe Storage"
            accountName = "Microsoft Edge"
        case .arc:
            serviceName = "Arc Safe Storage"
            accountName = "Arc"
        default:
            return nil
        }

        guard let passwordData = safeStoragePassword(service: serviceName, account: accountName) else {
            return nil
        }

        let salt = Data("saltysalt".utf8)
        var derivedKey = Data(count: kCCKeySizeAES128)
        let derivedKeyLength = derivedKey.count

        let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        derivedKeyLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            return nil
        }

        return derivedKey
    }

    private func safeStoragePassword(service: String, account: String) -> Data? {
        // 1) service + account (gallery-dl style security invocation)
        if let data = keychainPassword(service: service, account: account) {
            return data
        }

        // 2) service only fallback
        if let data = keychainPassword(service: service, account: nil) {
            return data
        }

        // 3) shell fallback to mirror gallery-dl behavior exactly
        if let data = securityFindGenericPassword(service: service, account: account) {
            return data
        }

        return nil
    }

    private func keychainPassword(service: String, account: String?) -> Data? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        if let account {
            query[kSecAttrAccount] = account
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return data
    }

    private func securityFindGenericPassword(service: String, account: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-a", account, "-s", service]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return data.trimmingTrailingNewline()
        } catch {
            return nil
        }
    }

    private func decryptChromiumCookie(_ encryptedValue: Data, key: Data) -> String? {
        guard encryptedValue.count > 3 else {
            return nil
        }

        if encryptedValue.starts(with: Data("v10".utf8)) || encryptedValue.starts(with: Data("v11".utf8)) {
            let payload = encryptedValue.dropFirst(3)

            // Newer Chromium builds may store cookie values as AES-GCM payloads:
            // [12-byte nonce][ciphertext+16-byte tag].
            if payload.count > 12 + 16,
               let value = decryptChromiumCookieGCM(payload: payload, key: key),
               !value.isEmpty {
                return value
            }

            // Fallback to legacy AES-CBC decryption used by older Chromium builds.
            return decryptChromiumCookieCBC(payload: payload, key: key)
        }

        return decryptChromiumCookieCBC(payload: encryptedValue, key: key)
    }

    private func decryptChromiumCookieGCM(payload: Data, key: Data) -> String? {
        guard payload.count > 12 + 16 else {
            return nil
        }

        let nonceData = payload.prefix(12)
        let cipherAndTag = payload.dropFirst(12)
        guard let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            return nil
        }

        // CryptoKit expects combined = ciphertext || tag.
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherAndTag.dropLast(16), tag: cipherAndTag.suffix(16))
        } catch {
            return nil
        }

        do {
            let symmetricKey = SymmetricKey(data: key)
            let decrypted = try AES.GCM.open(sealedBox, using: symmetricKey)
            return decodeChromiumCookieValue(from: Data(decrypted))
        } catch {
            return nil
        }
    }

    private func decryptChromiumCookieCBC(payload: Data, key: Data) -> String? {
        guard !payload.isEmpty else {
            return nil
        }

        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var outLength: size_t = 0
        var outData = Data(count: payload.count + kCCBlockSizeAES128)
        let outCapacity = outData.count

        let status = outData.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outBytes.baseAddress,
                            outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            return nil
        }

        outData.removeSubrange(outLength..<outData.count)
        return decodeChromiumCookieValue(from: outData)
    }

    private func decodeChromiumCookieValue(from decryptedData: Data) -> String? {
        // Newer Chromium DB versions can prefix decrypted cookie plaintext
        // with a 32-byte SHA-256(host_key). Try raw decode first, then strip prefix.
        if let raw = String(data: decryptedData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters), !raw.isEmpty {
            return raw
        }

        if decryptedData.count > 32 {
            let withoutHostHash = decryptedData.dropFirst(32)
            if let decoded = String(data: withoutHostHash, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters), !decoded.isEmpty {
                return decoded
            }
        }

        return nil
    }
}

private extension Data {
    func trimmingTrailingNewline() -> Data {
        var bytes = self
        while let last = bytes.last, last == 0x0A || last == 0x0D {
            bytes.removeLast()
        }
        return bytes
    }
}
