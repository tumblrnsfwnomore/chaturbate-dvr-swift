import Foundation
import Network

/// A minimal embedded HTTP server that exposes a read/control interface
/// for monitoring channels and toggling pause/resume from a remote device.
final class WebServer {

    // MARK: - Action hooks (wired up by ChannelManager)

    var getChannelInfos: (() async -> [ChannelInfo])?
    var pauseAction:     ((String) async -> Void)?
    var resumeAction:    ((String) async -> Void)?
    var getThumbnailPath: ((String) async -> String?)?

    // MARK: - Private state

    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "com.chaturbatedvr.webserver", qos: .utility)

    // MARK: - Lifecycle

    func start(port: UInt16) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw WebServerError.invalidPort
        }
        let l = try NWListener(using: params, on: nwPort)
        l.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        l.stateUpdateHandler = { state in
            switch state {
            case .failed(let err):
                Task { await FileLogger.shared.log("[webserver] listener error: \(err)", level: "WARN") }
            case .ready:
                Task { await FileLogger.shared.log("[webserver] listening on port \(port)") }
            default:
                break
            }
        }
        l.start(queue: serverQueue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: serverQueue)
        receive(from: connection)
    }

    private func receive(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let data, !data.isEmpty else { connection.cancel(); return }
            self?.dispatch(data: data, connection: connection)
        }
    }

    private func dispatch(data: Data, connection: NWConnection) {
        guard let text = String(data: data, encoding: .utf8) else {
            send404(connection: connection); return
        }
        // Parse just the request line; ignore headers for these simple endpoints.
        let firstLine = text.prefix(while: { $0 != "\r" && $0 != "\n" })
        let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { send404(connection: connection); return }

        let method = String(parts[0]).uppercased()
        let rawPath = String(parts[1])
        let path = rawPath.components(separatedBy: "?").first ?? rawPath

        Task { [weak self] in
            await self?.route(method: method, path: path, connection: connection)
        }
    }

    // MARK: - Routing

    private func route(method: String, path: String, connection: NWConnection) async {
        switch (method, path) {

        case ("GET", "/"):
            sendHTML(Self.dashboardHTML, connection: connection)

        case ("GET", "/manifest.json"):
            sendJSON(Self.manifestJSON, connection: connection)

        case ("GET", "/api/channels"):
            let infos = (await getChannelInfos?()) ?? []
            sendChannelsJSON(infos, connection: connection)

        case ("POST", _) where path.hasPrefix("/api/channels/"):
            let rest = String(path.dropFirst("/api/channels/".count))
            if rest.hasSuffix("/pause") {
                let username = decoded(String(rest.dropLast(6)))
                await pauseAction?(username)
                sendJSON(#"{"ok":true}"#, connection: connection)
            } else if rest.hasSuffix("/resume") {
                let username = decoded(String(rest.dropLast(7)))
                await resumeAction?(username)
                sendJSON(#"{"ok":true}"#, connection: connection)
            } else {
                send404(connection: connection)
            }

        case ("GET", _) where path.hasPrefix("/thumbnails/"):
            let username = decoded(String(path.dropFirst("/thumbnails/".count)))
            if let thumbPath = await getThumbnailPath?(username),
               let imgData = try? Data(contentsOf: URL(fileURLWithPath: thumbPath)) {
                sendResponse(status: 200, contentType: "image/jpeg",
                             cacheControl: "max-age=30", body: imgData, connection: connection)
            } else {
                send404(connection: connection)
            }

        default:
            send404(connection: connection)
        }
    }

    // MARK: - JSON serialisation

    private func sendChannelsJSON(_ infos: [ChannelInfo], connection: NWConnection) {
        struct Row: Encodable {
            let username: String
            let isOnline: Bool
            let isPaused: Bool
            let isRecording: Bool
            let isWaiting: Bool
            let duration: String
            let filesize: String
            let streamedAt: String?
            let lastOnlineAt: String?
            let hasThumbnail: Bool
            let isNoPersonDetected: Bool
            let noPersonDurationSeconds: Int
        }
        let rows = infos.map { i in
            Row(
                username: i.username,
                isOnline: i.isOnline,
                isPaused: i.isPaused,
                isRecording: i.isOnline && !i.isPaused && !i.isWaitingForRecordingSlot,
                isWaiting: i.isWaitingForRecordingSlot,
                duration: i.duration,
                filesize: i.filesize,
                streamedAt: i.streamedAt,
                lastOnlineAt: i.lastOnlineAt,
                hasThumbnail: i.thumbnailPath != nil,
                isNoPersonDetected: i.isNoPersonDetected,
                noPersonDurationSeconds: i.noPersonDurationSeconds
            )
        }
        let body = (try? JSONEncoder().encode(rows)) ?? Data("[]".utf8)
        sendResponse(status: 200, contentType: "application/json", body: body, connection: connection)
    }

    // MARK: - Response helpers

    private func sendHTML(_ html: String, connection: NWConnection) {
        sendResponse(status: 200, contentType: "text/html; charset=utf-8",
                     body: Data(html.utf8), connection: connection)
    }

    private func sendJSON(_ json: String, connection: NWConnection) {
        sendResponse(status: 200, contentType: "application/json",
                     body: Data(json.utf8), connection: connection)
    }

    private func send404(connection: NWConnection) {
        sendResponse(status: 404, contentType: "text/plain",
                     body: Data("Not Found".utf8), connection: connection)
    }

    private func sendResponse(
        status: Int,
        contentType: String,
        cacheControl: String = "no-store",
        body: Data,
        connection: NWConnection
    ) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 404: statusText = "Not Found"
        default:  statusText = "Error"
        }
        let header =
            "HTTP/1.1 \(status) \(statusText)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Cache-Control: \(cacheControl)\r\n" +
            "Connection: close\r\n" +
            "Access-Control-Allow-Origin: *\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, contentContext: .finalMessage,
                        isComplete: true, completion: .idempotent)
    }

    private func decoded(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    // MARK: - Error

    enum WebServerError: Error {
        case invalidPort
    }
}

// MARK: - Dashboard HTML

extension WebServer {
    // swiftlint:disable line_length
    
    static var dashboardHTML: String {
        loadDashboardHTML()
    }

    private static func loadDashboardHTML() -> String {
        // Try to load from bundle (when running as built app)
        // First try the standard resource path
        if let bundlePath = Bundle.main.path(forResource: "dashboard", ofType: "html"),
           let content = try? String(contentsOfFile: bundlePath, encoding: .utf8) {
            return content
        }
        
        // Try from WebServer subdirectory if it exists within bundle resources
        if let bundleResourcePath = Bundle.main.resourcePath {
            let webServerPath = bundleResourcePath + "/WebServer/dashboard.html"
            if let content = try? String(contentsOfFile: webServerPath, encoding: .utf8) {
                return content
            }
        }
        
        // Fallback: try to load from source directory (during development)
        let fileManager = FileManager.default
        
        var possiblePaths: [String] = []
        
        // Get the executable path and work backwards
        if let execPath = CommandLine.arguments.first {
            let execURL = URL(fileURLWithPath: execPath)
            
            // Try parent directories up to 8 levels (for packaged apps in dist/)
            var current = execURL
            for _ in 0..<8 {
                let sourcePath = current.appendingPathComponent("Sources/ChaturbateDVR/WebServer/dashboard.html").path
                possiblePaths.append(sourcePath)
                current = current.deletingLastPathComponent()
            }
        }
        
        // Try from current working directory
        let cwd = fileManager.currentDirectoryPath
        possiblePaths.append(cwd + "/Sources/ChaturbateDVR/WebServer/dashboard.html")
        possiblePaths.append(cwd + "/dashboard.html")
        
        // Try from known development paths
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            let devPath = home + "/Developer/chaturbate-dvr/Sources/ChaturbateDVR/WebServer/dashboard.html"
            possiblePaths.append(devPath)
        }
        
        // Check each path
        for path in possiblePaths {
            if fileManager.fileExists(atPath: path),
               let content = try? String(contentsOfFile: path, encoding: .utf8) {
                return content
            }
        }
        
        // Final fallback: minimal inline version if file not found
        let msg = "Dashboard file not found. Tried:\n" + possiblePaths.map { "  • \($0)" }.joined(separator: "\n")
        Task { await FileLogger.shared.log(msg, level: "WARN") }
        
        return """
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>ChaturbateDVR</title>
<style>body{font-family:sans-serif;background:#0f0f0f;color:#e5e5e5;margin:0}
header{background:#1a1a1a;padding:20px;border-bottom:1px solid #333}h1{margin:0;font-size:24px}
.note{margin:20px;padding:20px;background:#1a1a1a;border-radius:8px}
</style></head>
<body>
<header><h1>ChaturbateDVR</h1></header>
<div class="note">
<h2>Dashboard file not found</h2>
<p>Check the app logs for paths that were tried.</p>
<p>The file should be at: Sources/ChaturbateDVR/WebServer/dashboard.html</p>
</div>
</body></html>
"""
    }
    // swiftlint:enable line_length

    static let manifestJSON: String = """
{
  "name": "ChaturbateDVR",
  "short_name": "DVR",
  "description": "Monitor and control Chaturbate stream recordings",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "theme_color": "#0f0f0f",
  "background_color": "#1a1a1a",
  "icons": [
    {
      "src": "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 192 192'><rect fill='%230f0f0f' width='192' height='192'/><circle cx='96' cy='96' r='72' fill='%23a78bfa'/><polygon points='80,64 128,96 80,128' fill='%230f0f0f'/></svg>",
      "sizes": "192x192",
      "type": "image/svg+xml"
    },
    {
      "src": "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 512 512'><rect fill='%230f0f0f' width='512' height='512'/><circle cx='256' cy='256' r='192' fill='%23a78bfa'/><polygon points='213,170 341,256 213,342' fill='%230f0f0f'/></svg>",
      "sizes": "512x512",
      "type": "image/svg+xml"
    }
  ]
}
"""
}
