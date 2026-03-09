import Foundation

struct Stream {
    let hlsSource: String
}

actor ChaturbateClient {
    private let httpClient: HTTPClient
    private let config: AppConfig
    
    init(config: AppConfig) {
        self.config = config
        self.httpClient = HTTPClient(config: config)
    }
    
    func getStream(username: String) async throws -> Stream {
        let url = "\(config.domain)\(username)"
        let (data, statusCode) = try await httpClient.getDataWithStatus(url)

        if statusCode == 404 {
            throw ChaturbateError.invalidChannel
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        
        if !body.contains("playlist.m3u8") {
            throw ChaturbateError.channelOffline
        }
        
        return try parseStream(body)
    }

    func validateChannel(username: String) async throws {
        do {
            _ = try await getStream(username: username)
        } catch ChaturbateError.channelOffline {
            // Offline channels are still valid and can be added.
            return
        } catch ChaturbateError.privateStream {
            // Private channels can still exist and may become accessible later.
            return
        }
    }
    
    func getPlaylist(hlsSource: String, resolution: Int, framerate: Int) async throws -> Playlist {
        guard !hlsSource.isEmpty else {
            throw ChaturbateError.parsingError("HLS source is empty")
        }
        
        let content = try await httpClient.get(hlsSource)
        return try M3U8Parser.parseMasterPlaylist(content, baseURL: hlsSource, targetResolution: resolution, targetFramerate: framerate)
    }

    func getFollowedUsernames(progress: (@Sendable (String) -> Void)? = nil) async throws -> [String] {
        let debugID = UUID().uuidString
        let startedAt = ISO8601DateFormatter().string(from: Date())
        var debugLines: [String] = []
        progress?("Preparing followed import...")
        debugLines.append("debug_id=\(debugID)")
        debugLines.append("started_at=\(startedAt)")
        debugLines.append("domain=\(config.domain)")
        debugLines.append("selected_browser=\(config.selectedBrowser.displayName)")

        let userAgent = config.getUserAgent()
        debugLines.append("user_agent_present=\(!userAgent.isEmpty)")

        let cookieHeader = await config.getCookies()
        let cookieNames = cookieHeader
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { String($0.split(separator: "=", maxSplits: 1).first ?? "") }
            .filter { !$0.isEmpty }
        debugLines.append("cookie_count=\(cookieNames.count)")
        debugLines.append("has_sessionid_cookie=\(cookieNames.contains("sessionid"))")
        debugLines.append("has_csrftoken_cookie=\(cookieNames.contains("csrftoken"))")
        progress?("Auth check: found \(cookieNames.count) cookies")

        if cookieNames.isEmpty {
            let extractor = BrowserCookieExtractor()
            let diagnostics = await extractor.diagnostics(for: config.selectedBrowser, domain: "chaturbate.com")
            for line in diagnostics.lines {
                debugLines.append("cookie_diag_\(line)")
            }
        }

        // Primary path: use the same JSON room-list API the SPA uses.
        // This is more reliable than scraping placeholder HTML.
        var apiError: Error?
        do {
            progress?("Fetching followed online rooms...")
            let online = try await fetchFollowedUsernamesFromRoomList(showType: "follow", debugLines: &debugLines, progress: progress)
            progress?("Fetching followed offline rooms...")
            let offline = try await fetchFollowedUsernamesFromRoomList(showType: "follow_offline", debugLines: &debugLines, progress: progress)
            progress?("Checking explicit followed endpoints...")
            let explicitFollowed = try await fetchFollowedUsernamesFromExplicitEndpoints(debugLines: &debugLines, progress: progress)

            var combined = online.union(offline).union(explicitFollowed)

            // With valid cookies, paginated followed HTML often contains long-offline
            // follows that API endpoints may omit. Use it as a supplemental source.
            progress?("Scanning followed HTML pages for additional channels...")
            let htmlOnline = try await fetchFollowedUsernamesFromPaginatedHTML(basePath: "followed-cams/", label: "html_online", debugLines: &debugLines, progress: progress)
            let htmlOffline = try await fetchFollowedUsernamesFromPaginatedHTML(basePath: "followed-cams/offline/", label: "html_offline", debugLines: &debugLines, progress: progress)
            combined.formUnion(htmlOnline)
            combined.formUnion(htmlOffline)

            debugLines.append("api_combined_usernames=\(combined.count)")
            progress?("API collected \(combined.count) followed usernames")

            if !combined.isEmpty {
                await FileLogger.shared.log("Followed import succeeded via API (debug_id=\(debugID), usernames=\(combined.count))")
                return combined.sorted()
            }
        } catch {
            debugLines.append("api_error=\(String(describing: error))")
            apiError = error
        }

        // Fallback path: scrape followed pages if API output is unexpectedly empty.
        progress?("API returned no usable followed rows; trying HTML fallback...")
        let onlineURL = "\(config.domain)followed-cams/"
        let offlineURL = "\(config.domain)followed-cams/offline/"

        let onlineBody: String
        let offlineBody: String
        do {
            onlineBody = try await httpClient.get(onlineURL)
            offlineBody = try await httpClient.get(offlineURL)
        } catch {
            debugLines.append("fallback_fetch_error=\(String(describing: error))")
            let report = buildFollowedImportDebugReport(lines: debugLines)
            await FileLogger.shared.log("Followed import failed at fallback fetch\n\(report)", level: "WARN")
            throw ChaturbateError.networkError("Followed import failed (debug_id=\(debugID)). See logs for full report.\n\n\(report)")
        }

        debugLines.append("fallback_online_html_bytes=\(onlineBody.utf8.count)")
        debugLines.append("fallback_offline_html_bytes=\(offlineBody.utf8.count)")
        debugLines.append("fallback_online_roomcard_count=\(countOccurrences(of: "roomCard", in: onlineBody))")
        debugLines.append("fallback_offline_roomcard_count=\(countOccurrences(of: "roomCard", in: offlineBody))")
        debugLines.append("fallback_online_has_login_form=\(looksLikeLoginPage(onlineBody))")
        debugLines.append("fallback_offline_has_login_form=\(looksLikeLoginPage(offlineBody))")

        let online = parseFollowedUsernames(from: onlineBody)
        let offline = parseFollowedUsernames(from: offlineBody)
        let combined = online.union(offline)
        debugLines.append("fallback_online_usernames=\(online.count)")
        debugLines.append("fallback_offline_usernames=\(offline.count)")
        debugLines.append("fallback_combined_usernames=\(combined.count)")
        progress?("HTML fallback collected \(combined.count) usernames")

        if combined.isEmpty,
           (looksLikeLoginPage(onlineBody) || looksLikeLoginPage(offlineBody)) {
            let report = buildFollowedImportDebugReport(lines: debugLines)
            await FileLogger.shared.log("Followed import failed (login page detected)\n\(report)", level: "WARN")
            throw ChaturbateError.networkError("Could not load followed cams. Login cookies may be missing or expired (debug_id=\(debugID)).\n\n\(report)")
        }

        if combined.isEmpty, let apiError {
            debugLines.append("final_error_source=api_error_with_empty_fallback")
            debugLines.append("final_api_error=\(String(describing: apiError))")
            let report = buildFollowedImportDebugReport(lines: debugLines)
            await FileLogger.shared.log("Followed import failed after API+fallback\n\(report)", level: "WARN")
            throw ChaturbateError.networkError("Followed import failed after API + HTML fallback (debug_id=\(debugID)).\n\n\(report)")
        }

        await FileLogger.shared.log("Followed import succeeded via HTML fallback (debug_id=\(debugID), usernames=\(combined.count))")

        return combined.sorted()
    }
    
    private func parseStream(_ body: String) throws -> Stream {
        let pattern = #"window\.initialRoomDossier = "(.*?)""#
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let nsString = body as NSString
        let results = regex.matches(in: body, options: [], range: NSRange(location: 0, length: nsString.length))
        
        guard let match = results.first,
              let range = Range(match.range(at: 1), in: body) else {
            throw ChaturbateError.parsingError("Room dossier not found")
        }
        
        var encodedJSON = String(body[range])
        
        // Decode unicode escape sequences: replace \\u with \u
        // This matches the Go implementation: strings.Replace(strconv.Quote(matches[1]), `\\u`, `\u`, -1)
        encodedJSON = encodedJSON.replacingOccurrences(of: "\\\\u", with: "\\u")
        
        // Decode unicode escape sequences manually
        var decoded = encodedJSON
        let unicodePattern = #"\\u([0-9a-fA-F]{4})"#
        if let regex = try? NSRegularExpression(pattern: unicodePattern, options: []) {
            let nsString = encodedJSON as NSString
            let matches = regex.matches(in: encodedJSON, options: [], range: NSRange(location: 0, length: nsString.length))
            
            // Replace from end to start to maintain indices
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let hexRange = Range(match.range(at: 1), in: encodedJSON),
                      let codePoint = UInt32(String(encodedJSON[hexRange]), radix: 16),
                      let scalar = UnicodeScalar(codePoint),
                      let matchRange = Range(match.range, in: decoded) else {
                    continue
                }
                decoded.replaceSubrange(matchRange, with: String(Character(scalar)))
            }
        }
        
        guard let data = decoded.data(using: .utf8) else {
            // Fallback: try parsing directly
            guard let fallbackData = encodedJSON.data(using: .utf8) else {
                throw ChaturbateError.parsingError("Failed to decode JSON string")
            }
            return try parseRoomDossier(from: fallbackData)
        }
        
        return try parseRoomDossier(from: data)
        
    }
    
    private func parseRoomDossier(from data: Data) throws -> Stream {
        struct RoomDossier: Codable {
            let hlsSource: String
            
            enum CodingKeys: String, CodingKey {
                case hlsSource = "hls_source"
            }
        }
        
        let room = try JSONDecoder().decode(RoomDossier.self, from: data)
        return Stream(hlsSource: room.hlsSource)
    }

    private func fetchFollowedUsernamesFromRoomList(showType: String, debugLines: inout [String], progress: (@Sendable (String) -> Void)? = nil) async throws -> Set<String> {
        guard let baseComponents = URLComponents(string: "\(config.domain)api/ts/roomlist/room-list/") else {
            throw ChaturbateError.networkError("Invalid room-list API URL")
        }

        let limit = 100
        let maxPages = 200
        var page = 0
        var offset = 0
        var allUsernames = Set<String>()
        var totalCountHint: Int?
        var roomListID: String?

        while page < maxPages {
            var components = baseComponents
            components.queryItems = [
                URLQueryItem(name: "show", value: showType),
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "offset", value: "\(offset)")
            ]
            if let roomListID {
                components.queryItems?.append(URLQueryItem(name: "room_list_id", value: roomListID))
            }

            guard let url = components.url else {
                throw ChaturbateError.networkError("Invalid room-list API URL")
            }

            debugLines.append("api_\(showType)_page_\(page)_url=\(url.absoluteString)")

            let (data, statusCode) = try await httpClient.getDataWithStatus(url.absoluteString)
            debugLines.append("api_\(showType)_page_\(page)_status=\(statusCode)")
            debugLines.append("api_\(showType)_page_\(page)_bytes=\(data.count)")

            if statusCode == 401 || statusCode == 403 {
                throw ChaturbateError.networkError("Could not access followed cams. Verify Chaturbate login cookies from your selected browser in Settings.")
            }

            if !(200..<300).contains(statusCode) {
                throw ChaturbateError.networkError("Followed cams request failed with status \(statusCode)")
            }

            let pageData = parseFollowedUsernamesFromRoomListJSON(data, showType: showType)
            totalCountHint = pageData.totalCount ?? totalCountHint
            allUsernames.formUnion(pageData.usernames)
            if roomListID == nil {
                roomListID = pageData.roomListID
            }

            debugLines.append("api_\(showType)_page_\(page)_rooms=\(pageData.roomCount)")
            debugLines.append("api_\(showType)_page_\(page)_has_following_flag=\(pageData.hasFollowingFlag)")
            debugLines.append("api_\(showType)_page_\(page)_parsed_usernames=\(pageData.usernames.count)")
            if let pageDataRoomListID = pageData.roomListID {
                debugLines.append("api_\(showType)_page_\(page)_room_list_id=\(pageDataRoomListID)")
            }
            progress?("\(showType): page \(page + 1), +\(pageData.usernames.count), total \(allUsernames.count)")

            // Safety: if the feed has rooms but no explicit following flag,
            // do not trust it for followed import.
            if pageData.roomCount > 0 && !pageData.hasFollowingFlag {
                debugLines.append("api_\(showType)_page_\(page)_safety_break=no_is_following_flag")
                break
            }

            // Stop when there are no more rooms for the next page.
            if pageData.roomCount == 0 || pageData.roomCount < limit {
                break
            }

            if let totalCountHint, (offset + pageData.roomCount) >= totalCountHint {
                break
            }

            page += 1
            offset += limit
        }

        debugLines.append("api_\(showType)_pages_fetched=\(page + 1)")
        debugLines.append("api_\(showType)_parsed_usernames=\(allUsernames.count)")

        return allUsernames
    }

    private struct RoomListPageData {
        let usernames: Set<String>
        let roomCount: Int
        let totalCount: Int?
        let hasFollowingFlag: Bool
        let roomListID: String?
    }

    private func parseFollowedUsernamesFromRoomListJSON(_ data: Data, showType: String) -> RoomListPageData {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return RoomListPageData(usernames: [], roomCount: 0, totalCount: nil, hasFollowingFlag: false, roomListID: nil)
        }

        // Preferred schema path from room-list payloads:
        // { "rooms": [{ "username": "...", "is_following": true|false, ... }], ... }
        if let root = json as? [String: Any],
           let rooms = root["rooms"] as? [[String: Any]] {
            let direct = parseUsernamesFromRoomsArray(rooms, showType: showType)
            let totalCount = root["total_count"] as? Int
            let hasFollowingFlag = rooms.contains { $0["is_following"] != nil }
            let roomListID = root["room_list_id"] as? String
            return RoomListPageData(
                usernames: direct,
                roomCount: rooms.count,
                totalCount: totalCount,
                hasFollowingFlag: hasFollowingFlag,
                roomListID: roomListID
            )
        }

        var usernames = Set<String>()
        collectUsernames(from: json, parentKey: nil, into: &usernames)
        return RoomListPageData(usernames: usernames, roomCount: 0, totalCount: nil, hasFollowingFlag: false, roomListID: nil)
    }

    private func fetchFollowedUsernamesFromExplicitEndpoints(debugLines: inout [String], progress: (@Sendable (String) -> Void)? = nil) async throws -> Set<String> {
        let endpoints: [(label: String, path: String)] = [
            ("online_followed_rooms", "api/online_followed_rooms/"),
            ("offline_followed_rooms", "api/offline_followed_rooms/")
        ]

        var usernames = Set<String>()

        for endpoint in endpoints {
            let url = "\(config.domain)\(endpoint.path)"
            let (data, statusCode) = try await httpClient.getDataWithStatus(url)
            debugLines.append("api_\(endpoint.label)_status=\(statusCode)")
            debugLines.append("api_\(endpoint.label)_bytes=\(data.count)")

            // Some deployments may not expose all endpoints.
            if statusCode == 404 {
                continue
            }

            if statusCode == 401 || statusCode == 403 {
                throw ChaturbateError.networkError("Could not access followed cams. Verify Chaturbate login cookies from your selected browser in Settings.")
            }

            if !(200..<300).contains(statusCode) {
                continue
            }

            let parsed = parseUsernamesFromFollowedEndpointJSON(data)
            usernames.formUnion(parsed)
            debugLines.append("api_\(endpoint.label)_parsed_usernames=\(parsed.count)")
            progress?("\(endpoint.label): +\(parsed.count), total \(usernames.count)")
        }

        debugLines.append("api_explicit_followed_usernames=\(usernames.count)")
        return usernames
    }

    private func parseUsernamesFromFollowedEndpointJSON(_ data: Data) -> Set<String> {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }

        var usernames = Set<String>()

        // IMPORTANT: Do not recurse through arbitrary JSON here.
        // Explicit endpoints can include recommendation/metadata blocks that contain
        // many usernames not in the user's followed list.
        if let root = json as? [String: Any] {
            if let rooms = root["rooms"] as? [[String: Any]] {
                usernames.formUnion(parseUsernamesFromExplicitRoomArray(rooms))
            }

            if let results = root["results"] as? [[String: Any]] {
                usernames.formUnion(parseUsernamesFromExplicitRoomArray(results))
            }

            if let users = root["users"] as? [[String: Any]] {
                usernames.formUnion(parseUsernamesFromExplicitRoomArray(users))
            }
        } else if let array = json as? [[String: Any]] {
            usernames.formUnion(parseUsernamesFromExplicitRoomArray(array))
        }

        return usernames
    }

    private func parseUsernamesFromExplicitRoomArray(_ rows: [[String: Any]]) -> Set<String> {
        var usernames = Set<String>()

        for row in rows {
            // If an explicit follow signal exists, honor it strictly.
            if let isFollowing = row["is_following"] as? Bool, !isFollowing {
                continue
            }

            let rawUsername = (row["username"] as? String)
                ?? (row["room"] as? String)
                ?? (row["room_name"] as? String)
                ?? (row["roomname"] as? String)
                ?? (row["broadcaster_username"] as? String)
                ?? (row["model_username"] as? String)

            guard let rawUsername,
                  let normalized = extractUsernameCandidate(rawUsername),
                  !normalized.isEmpty else {
                continue
            }

            usernames.insert(normalized)
        }

        return usernames
    }

    private func parseUsernamesFromRoomsArray(_ rooms: [[String: Any]], showType: String) -> Set<String> {
        var usernames = Set<String>()

        // If is_following exists in payload, honor it strictly to avoid pulling recs.
        let hasFollowingFlag = rooms.contains { $0["is_following"] != nil }

        // Safety: for followed import, only trust rows explicitly marked followed.
        if !hasFollowingFlag && (showType == "follow" || showType == "follow_offline") {
            return []
        }

        for room in rooms {
            guard let rawUsername = room["username"] as? String else {
                continue
            }

            let username = extractUsernameCandidate(rawUsername) ?? ""
            guard !username.isEmpty else {
                continue
            }

            if hasFollowingFlag {
                if let isFollowing = room["is_following"] as? Bool, isFollowing {
                    usernames.insert(username)
                }
                continue
            }

            // Only accept explicitly followed rows.
        }

        return usernames
    }

    private func collectUsernames(from value: Any, parentKey: String?, into usernames: inout Set<String>) {
        if let dictionary = value as? [String: Any] {
            for (key, nestedValue) in dictionary {
                let loweredKey = key.lowercased()

                // Avoid importing recommendation blocks when present.
                if loweredKey.contains("recommend") {
                    continue
                }

                if isUsernameKey(loweredKey), let username = extractUsernameCandidate(nestedValue) {
                    usernames.insert(username)
                    continue
                }

                collectUsernames(from: nestedValue, parentKey: loweredKey, into: &usernames)
            }
            return
        }

        if let array = value as? [Any] {
            for item in array {
                collectUsernames(from: item, parentKey: parentKey, into: &usernames)
            }
            return
        }

        if isUsernameKey(parentKey), let username = extractUsernameCandidate(value) {
            usernames.insert(username)
        }
    }

    private func isUsernameKey(_ key: String?) -> Bool {
        guard let key else { return false }

        return key == "username"
            || key == "room"
            || key == "roomname"
            || key == "room_name"
            || key == "broadcaster_username"
            || key == "model_username"
            || key == "slug"
    }

    private func extractUsernameCandidate(_ value: Any) -> String? {
        guard let raw = value as? String else {
            return nil
        }

        // Accept plain usernames and /username-style links.
        var candidate = raw
        if let firstSegment = raw.split(separator: "/").first(where: { !$0.isEmpty }) {
            if raw.contains("/") {
                candidate = String(firstSegment)
            }
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let sanitized = candidate.components(separatedBy: allowed.inverted).joined().lowercased()

        guard !sanitized.isEmpty, sanitized.count <= 50 else {
            return nil
        }

        return sanitized
    }

    private func parseFollowedUsernames(from body: String, allowLooseFallback: Bool = true) -> Set<String> {
        var excludedRanges = findFollowRecommendationsRanges(in: body)
        if excludedRanges.contains(where: { $0.length > (body as NSString).length * 8 / 10 }) {
            // Defensive fallback: if exclusion parsing looks suspiciously broad,
            // prefer returning candidates rather than dropping the whole page.
            excludedRanges = []
        }

        let pattern = #"(?is)<li\b[^>]*class\s*=\s*[\"'][^\"']*\broomCard\b[^\"']*[\"'][^>]*>(.*?)</li>"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let nsBody = body as NSString
        let matches = regex.matches(in: body, options: [], range: NSRange(location: 0, length: nsBody.length))
        var usernames = Set<String>()

        for match in matches {
            let liRange = match.range(at: 0)
            if isRange(liRange, insideAny: excludedRanges) {
                continue
            }

            guard let liSwiftRange = Range(liRange, in: body) else { continue }
            let liHTML = String(body[liSwiftRange])

            if let username = extractUsernameFromRoomCard(liHTML), !username.isEmpty {
                usernames.insert(username)
            }
        }

        if !usernames.isEmpty {
            return usernames
        }

        // Strict mode for followed pages: do not scan arbitrary page links/JSON blobs.
        // This avoids importing non-channel slugs from unrelated UI content.
        if !allowLooseFallback {
            return []
        }

        // Fallback strategy: newer pages can render room data in script/JSON blocks
        // where strict <li class="roomCard"> parsing misses model names.
        usernames.formUnion(extractUsernamesFromDataAttributes(in: body))
        usernames.formUnion(extractUsernamesFromJSONKeys(in: body))
        usernames.formUnion(extractUsernamesFromRoomLinks(in: body))

        return usernames
    }

    private func fetchFollowedUsernamesFromPaginatedHTML(
        basePath: String,
        label: String,
        debugLines: inout [String],
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Set<String> {
        let maxPages = 40
        var allUsernames = Set<String>()
        var consecutiveNoGrowth = 0
        var consecutiveEmptyPages = 0

        for page in 1...maxPages {
            guard let url = paginatedFollowedHTMLURL(basePath: basePath, page: page) else {
                break
            }

            let (data, statusCode) = try await httpClient.getDataWithStatus(url)
            debugLines.append("\(label)_page_\(page)_url=\(url)")
            debugLines.append("\(label)_page_\(page)_status=\(statusCode)")
            debugLines.append("\(label)_page_\(page)_bytes=\(data.count)")

            if statusCode == 401 || statusCode == 403 {
                throw ChaturbateError.networkError("Could not access followed cams HTML pages. Verify Chaturbate login cookies from your selected browser in Settings.")
            }

            if statusCode == 404 {
                break
            }

            if !(200..<300).contains(statusCode) {
                consecutiveNoGrowth += 1
                if consecutiveNoGrowth >= 2 {
                    break
                }
                continue
            }

            let body = String(data: data, encoding: .utf8) ?? ""
            if looksLikeLoginPage(body) {
                debugLines.append("\(label)_page_\(page)_login_page=true")
                break
            }

            let roomCardCount = countOccurrences(of: "roomCard", in: body)
            let parsed = parseFollowedUsernames(from: body, allowLooseFallback: false)
            let beforeCount = allUsernames.count
            allUsernames.formUnion(parsed)
            let added = allUsernames.count - beforeCount

            debugLines.append("\(label)_page_\(page)_roomcard_count=\(roomCardCount)")
            debugLines.append("\(label)_page_\(page)_parsed_usernames=\(parsed.count)")
            debugLines.append("\(label)_page_\(page)_added_usernames=\(added)")
            progress?("\(label): page \(page), +\(added), total \(allUsernames.count)")

            if roomCardCount == 0 && parsed.isEmpty {
                consecutiveEmptyPages += 1
            } else {
                consecutiveEmptyPages = 0
            }

            if added == 0 {
                consecutiveNoGrowth += 1
            } else {
                consecutiveNoGrowth = 0
            }

            if consecutiveEmptyPages >= 2 || consecutiveNoGrowth >= 3 {
                break
            }
        }

        debugLines.append("\(label)_total_usernames=\(allUsernames.count)")
        return allUsernames
    }

    private func paginatedFollowedHTMLURL(basePath: String, page: Int) -> String? {
        let base = "\(config.domain)\(basePath)"
        guard URL(string: base) != nil else {
            return nil
        }

        if page <= 1 {
            return base
        }

        if base.contains("?") {
            return "\(base)&page=\(page)"
        }

        return "\(base)?page=\(page)"
    }

    private func extractUsernamesFromDataAttributes(in body: String) -> Set<String> {
        let patterns = [
            #"\bdata-room\s*=\s*[\"']([A-Za-z0-9_-]{2,50})[\"']"#,
            #"\bdata-username\s*=\s*[\"']([A-Za-z0-9_-]{2,50})[\"']"#,
            #"\bdata-roomname\s*=\s*[\"']([A-Za-z0-9_-]{2,50})[\"']"#
        ]

        return extractUsernamesUsingPatterns(patterns, in: body)
    }

    private func extractUsernamesFromJSONKeys(in body: String) -> Set<String> {
        let patterns = [
            #"\"username\"\s*:\s*\"([A-Za-z0-9_-]{2,50})\""#,
            #"\"room\"\s*:\s*\"([A-Za-z0-9_-]{2,50})\""#,
            #"\"room_name\"\s*:\s*\"([A-Za-z0-9_-]{2,50})\""#,
            #"\"roomname\"\s*:\s*\"([A-Za-z0-9_-]{2,50})\""#,
            #"\"broadcaster_username\"\s*:\s*\"([A-Za-z0-9_-]{2,50})\""#,
            #"\"model_username\"\s*:\s*\"([A-Za-z0-9_-]{2,50})\""#,
            #"\"slug\"\s*:\s*\"([A-Za-z0-9_-]{2,50})\""#
        ]

        return extractUsernamesUsingPatterns(patterns, in: body)
    }

    private func extractUsernamesFromRoomLinks(in body: String) -> Set<String> {
        // Supports /username/, /username, and /p/username/ style links.
        let patterns = [
            #"href\s*=\s*[\"'](?:https?://[^/]+)?/(?:p/)?([A-Za-z0-9_-]{2,50})/?(?:\?[^\"']*)?[\"']"#
        ]

        return extractUsernamesUsingPatterns(patterns, in: body)
    }

    private func extractUsernamesUsingPatterns(_ patterns: [String], in body: String) -> Set<String> {
        var usernames = Set<String>()
        let nsBody = body as NSString
        let searchRange = NSRange(location: 0, length: nsBody.length)

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            for match in regex.matches(in: body, options: [], range: searchRange) {
                guard match.numberOfRanges > 1,
                      let usernameRange = Range(match.range(at: 1), in: body) else {
                    continue
                }

                let candidate = String(body[usernameRange]).lowercased()
                guard isLikelyUsername(candidate) else {
                    continue
                }

                usernames.insert(candidate)
            }
        }

        return usernames
    }

    private func isLikelyUsername(_ candidate: String) -> Bool {
        guard !candidate.isEmpty,
              candidate.count >= 2,
              candidate.count <= 50 else {
            return false
        }

        let reserved = Set([
            "api", "auth", "about", "accounts", "ads", "blog", "broadcast",
            "contest", "contact", "cookies", "favicon", "followed-cams",
            "help", "home", "login", "logout", "privacy", "register",
            "robots", "search", "settings", "sitemap", "static", "support",
            "terms", "upload", "users", "welcome", "www"
        ])

        if reserved.contains(candidate) {
            return false
        }

        return true
    }

    private func extractUsernameFromRoomCard(_ liHTML: String) -> String? {
        let candidates = [
            #"\bdata-room\s*=\s*[\"']([A-Za-z0-9_-]+)[\"']"#,
            #"\bdata-username\s*=\s*[\"']([A-Za-z0-9_-]+)[\"']"#,
            #"href\s*=\s*[\"'](?:https?://[^/]+)?/([A-Za-z0-9_-]+)/?(?:\?[^\"']*)?[\"']"#
        ]

        for pattern in candidates {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let nsHTML = liHTML as NSString
            guard let match = regex.firstMatch(in: liHTML, options: [], range: NSRange(location: 0, length: nsHTML.length)),
                  match.numberOfRanges > 1,
                  let usernameRange = Range(match.range(at: 1), in: liHTML) else {
                continue
            }

            let raw = String(liHTML[usernameRange])
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
            let sanitized = raw.components(separatedBy: allowed.inverted).joined().lowercased()
            if !sanitized.isEmpty {
                return sanitized
            }
        }

        return nil
    }

    private func findFollowRecommendationsRanges(in body: String) -> [NSRange] {
        let divPattern = #"(?is)<(/?)div\b([^>]*)>"#
        guard let regex = try? NSRegularExpression(pattern: divPattern, options: []) else {
            return []
        }

        let nsBody = body as NSString
        let fullRange = NSRange(location: 0, length: nsBody.length)
        let matches = regex.matches(in: body, options: [], range: fullRange)

        var ranges: [NSRange] = []
        var activeStart: Int?
        var depth = 0

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }

            let slashRange = match.range(at: 1)
            let attrsRange = match.range(at: 2)

            let isClosing = slashRange.location != NSNotFound && nsBody.substring(with: slashRange) == "/"

            if !isClosing {
                if activeStart != nil {
                    depth += 1
                } else if attrsRange.location != NSNotFound {
                    let attrs = nsBody.substring(with: attrsRange)
                    if hasFollowRecommendationsID(attrs) {
                        activeStart = match.range.location
                        depth = 1
                    }
                }
            } else if let start = activeStart {
                depth -= 1
                if depth == 0 {
                    let end = match.range.location + match.range.length
                    ranges.append(NSRange(location: start, length: end - start))
                    activeStart = nil
                }
            }
        }

        return ranges
    }

    private func hasFollowRecommendationsID(_ attrs: String) -> Bool {
        let patterns = [
            #"\bid\s*=\s*[\"']followRecommendations[\"']"#,
            #"\bid\s*=\s*followRecommendations\b"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: (attrs as NSString).length)
                if regex.firstMatch(in: attrs, options: [], range: range) != nil {
                    return true
                }
            }
        }

        return false
    }

    private func isRange(_ range: NSRange, insideAny excludedRanges: [NSRange]) -> Bool {
        for excluded in excludedRanges {
            if NSLocationInRange(range.location, excluded) {
                return true
            }
        }
        return false
    }

    private func looksLikeLoginPage(_ body: String) -> Bool {
        let lowered = body.lowercased()
        let hasLoginHeading = lowered.contains("chaturbate login") || lowered.contains(">log in<")
        let hasLoginFormFields = lowered.contains("name=\"username\"") && lowered.contains("name=\"password\"")
        return hasLoginHeading && hasLoginFormFields
    }

    private func countOccurrences(of token: String, in body: String) -> Int {
        guard !token.isEmpty else { return 0 }
        return body.components(separatedBy: token).count - 1
    }

    private func buildFollowedImportDebugReport(lines: [String]) -> String {
        let header = "Followed Import Debug Report"
        let body = lines.map { "- \($0)" }.joined(separator: "\n")
        return "\(header)\n\(body)"
    }
}
