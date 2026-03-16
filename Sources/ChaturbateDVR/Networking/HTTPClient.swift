import Foundation

actor HTTPClient {
    private let session: URLSession
    private let config: AppConfig
    
    init(config: AppConfig) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10.0
        configuration.timeoutIntervalForResource = 30.0
        
        self.session = URLSession(configuration: configuration)
        self.config = config
    }
    
    func get(_ url: String) async throws -> String {
        let (data, _) = try await getDataWithStatus(url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func getHTML(_ url: String) async throws -> String {
        guard let url = URL(string: url) else {
            throw ChaturbateError.networkError("Invalid URL: \(url)")
        }
        var request = URLRequest(url: url)
        // Plain browser-style request — no XHR header, so the server returns full HTML
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let userAgent = config.getUserAgent()
        if !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let cookies = await config.getCookies()
        if !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }

        let (data, httpResponse) = try await execute(request: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        await FileLogger.shared.log("[http] getHTML status=\(httpResponse.statusCode) url=\(httpResponse.url?.absoluteString ?? "nil") bytes=\(body.count) title=\(body.components(separatedBy: "<title>").dropFirst().first?.components(separatedBy: "</title>").first ?? "none")")
        // Detect redirect to /roomlogin/ — treat as offline (same as getDataWithStatus).
        if let finalURL = httpResponse.url, finalURL.path.hasPrefix("/roomlogin/") {
            throw ChaturbateError.channelOffline
        }
        return body
    }
    
    func getData(_ url: String) async throws -> Data {
        let (data, _) = try await getDataWithStatus(url)
        return data
    }

    func getDataWithStatus(_ url: String) async throws -> (Data, Int) {
        guard let url = URL(string: url) else {
            throw ChaturbateError.networkError("Invalid URL: \(url)")
        }
        let request = await buildRequest(url: url)
        let (data, httpResponse) = try await execute(request: request)

        // Detect redirect to /roomlogin/ — Chaturbate sends some offline/restricted
        // channels here. The login page has no room dossier so treat this as offline.
        if let finalURL = httpResponse.url, finalURL.path.hasPrefix("/roomlogin/") {
            throw ChaturbateError.channelOffline
        }

        if httpResponse.statusCode == 403 {
            throw ChaturbateError.privateStream
        }
        
        let bodyString = String(data: data, encoding: .utf8) ?? ""
        
        if bodyString.contains("<title>Just a moment...</title>") {
            throw ChaturbateError.cloudflareBlocked
        }
        
        if bodyString.contains("Verify your age") {
            throw ChaturbateError.ageVerification
        }

        return (data, httpResponse.statusCode)
    }

    private func buildRequest(url: URL) async -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

        let userAgent = config.getUserAgent()
        if !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let cookies = await config.getCookies()
        if !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }

        return request
    }

    private func execute(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChaturbateError.networkError("Invalid response")
        }

        return (data, httpResponse)
    }
}
