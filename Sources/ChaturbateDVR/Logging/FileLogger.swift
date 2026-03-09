import Foundation

actor FileLogger {
    static let shared = FileLogger()
    
    private let logDirectory: URL
    private let dateFormatter: DateFormatter
    private let timeFormatter: DateFormatter
    private var currentLogFile: URL?
    private var fileHandle: FileHandle?
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.logDirectory = appSupport
            .appendingPathComponent("ChaturbateDVR")
            .appendingPathComponent("logs")
        
        // Ensure logs directory exists
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd"
        
        self.timeFormatter = DateFormatter()
        self.timeFormatter.dateFormat = "HH:mm:ss.SSS"
    }
    
    func log(_ message: String, channel: String? = nil, level: String = "INFO") {
        let timestamp = timeFormatter.string(from: Date())
        let channelStr = channel.map { "[\($0)] " } ?? ""
        let logLine = "\(timestamp) [\(level)] \(channelStr)\(message)\n"
        
        // Get today's log file
        let dateStr = dateFormatter.string(from: Date())
        let logFileName = "chaturbate-dvr-\(dateStr).log"
        let logFilePath = logDirectory.appendingPathComponent(logFileName)
        
        // Switch to new file if date changed
        if currentLogFile != logFilePath {
            fileHandle?.closeFile()
            currentLogFile = logFilePath
            
            // Create file if it doesn't exist
            if !FileManager.default.fileExists(atPath: logFilePath.path) {
                FileManager.default.createFile(atPath: logFilePath.path, contents: nil)
            }
            
            fileHandle = FileHandle(forWritingAtPath: logFilePath.path)
            fileHandle?.seekToEndOfFile()
        }
        
        if let data = logLine.data(using: .utf8) {
            fileHandle?.write(data)
            fileHandle?.synchronizeFile()
        }
    }
    
    func logBackfillAttempt(channel: String, videoPath: String, fileSize: String) {
        log("Thumbnail backfill: attempting generation from \(videoPath) (\(fileSize))", channel: channel)
    }
    
    func logBackfillSuccess(channel: String) {
        log("Thumbnail backfill: ✓ generated successfully", channel: channel)
    }
    
    func logBackfillFailure(channel: String, error: String) {
        log("Thumbnail backfill: ✗ failed - \(error)", channel: channel, level: "WARN")
    }
    
    func logThumbnailTimeout(channel: String) {
        log("Thumbnail backfill: ✗ timeout after 30 seconds", channel: channel, level: "WARN")
    }
    
    func logNoVideosFound(channel: String) {
        log("Thumbnail backfill: no suitable videos found yet", channel: channel)
    }
    
    func logBackfillCycleStart() {
        log("Thumbnail backfill cycle started")
    }
    
    func logBackfillCycleEnd() {
        log("Thumbnail backfill cycle complete")
    }

    func logLiveThumbnailSuccess(channel: String) {
        log("Live thumbnail: ✓ updated from recording/stream", channel: channel)
    }

    func logLiveThumbnailFailure(channel: String, error: String) {
        log("Live thumbnail: ✗ failed - \(error)", channel: channel, level: "WARN")
    }
}
