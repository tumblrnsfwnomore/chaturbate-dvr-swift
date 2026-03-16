import Foundation

struct BioMetadata: Codable, Equatable {
    var gender: String? // e.g., "A Woman", "A Man"
    var followers: Int?
    var location: String?
    var body: String? // e.g., "36 / 23 / 37"
    var language: String?
    var lastBioRefresh: Int64? // timestamp of last bio fetch
    
    init(
        gender: String? = nil,
        followers: Int? = nil,
        location: String? = nil,
        body: String? = nil,
        language: String? = nil,
        lastBioRefresh: Int64? = nil
    ) {
        self.gender = gender
        self.followers = followers
        self.location = location
        self.body = body
        self.language = language
        self.lastBioRefresh = lastBioRefresh
    }
}

struct ChannelConfig: Codable, Identifiable {
    var id: String { username }
    var isPaused: Bool
    var username: String
    var outputDirectory: String
    var framerate: Int
    var resolution: Int
    var pattern: String
    var maxDuration: Int // minutes
    var maxFilesize: Int // MB
    var createdAt: Int64
    var lastOnlineAt: Int64?
    var recordingHistory: [String]
    var isInvalid: Bool
    var bioMetadata: BioMetadata?
    
    init(
        isPaused: Bool = false,
        username: String,
        outputDirectory: String = "",
        framerate: Int = 30,
        resolution: Int = 1080,
        pattern: String = "{{.Username}}_{{.Year}}-{{.Month}}-{{.Day}}_{{.Hour}}-{{.Minute}}-{{.Second}}{{if .Sequence}}_{{.Sequence}}{{end}}",
        maxDuration: Int = 0,
        maxFilesize: Int = 0,
        createdAt: Int64? = nil,
        lastOnlineAt: Int64? = nil,
        recordingHistory: [String] = [],
        isInvalid: Bool = false,
        bioMetadata: BioMetadata? = nil
    ) {
        self.isPaused = isPaused
        self.username = Self.sanitizeUsername(username)
        self.outputDirectory = outputDirectory
        self.framerate = framerate
        self.resolution = resolution
        self.pattern = pattern
        self.maxDuration = maxDuration
        self.maxFilesize = maxFilesize
        self.createdAt = createdAt ?? Int64(Date().timeIntervalSince1970)
        self.lastOnlineAt = lastOnlineAt
        self.recordingHistory = recordingHistory
        self.isInvalid = isInvalid
        self.bioMetadata = bioMetadata
    }

    private enum CodingKeys: String, CodingKey {
        case isPaused
        case username
        case outputDirectory
        case framerate
        case resolution
        case pattern
        case maxDuration
        case maxFilesize
        case createdAt
        case lastOnlineAt
        case recordingHistory
        case isInvalid
        case bioMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isPaused = try container.decode(Bool.self, forKey: .isPaused)
        username = Self.sanitizeUsername(try container.decode(String.self, forKey: .username))
        outputDirectory = try container.decodeIfPresent(String.self, forKey: .outputDirectory) ?? ""
        framerate = try container.decode(Int.self, forKey: .framerate)
        resolution = try container.decode(Int.self, forKey: .resolution)
        pattern = try container.decode(String.self, forKey: .pattern)
        maxDuration = try container.decode(Int.self, forKey: .maxDuration)
        maxFilesize = try container.decode(Int.self, forKey: .maxFilesize)
        createdAt = try container.decode(Int64.self, forKey: .createdAt)
        lastOnlineAt = try container.decodeIfPresent(Int64.self, forKey: .lastOnlineAt)
        recordingHistory = try container.decodeIfPresent([String].self, forKey: .recordingHistory) ?? []
        isInvalid = try container.decodeIfPresent(Bool.self, forKey: .isInvalid) ?? false
        bioMetadata = try container.decodeIfPresent(BioMetadata.self, forKey: .bioMetadata)
    }
    
    private static func sanitizeUsername(_ username: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return username.components(separatedBy: allowed.inverted).joined()
            .trimmingCharacters(in: .whitespaces)
    }
}

struct ChannelInfo: Identifiable {
    var id: String { username }
    var isOnline: Bool
    var isPaused: Bool
    var username: String
    var duration: String
    var filesize: String
    var filename: String?
    var streamedAt: String?
    var lastOnlineAt: String?
    var lastOnlineAtUnix: Int64?
    var recordings: [String]
    var recordingsDirectory: String
    var maxDuration: String
    var maxFilesize: String
    var createdAt: Int64
    var logs: [String]
    var thumbnailPath: String?
    var isChecking: Bool
    var isWaitingForRecordingSlot: Bool
    var isInvalid: Bool
    var cloudflareBlockCount: Int
    var isNoPersonDetected: Bool
    var noPersonDurationSeconds: Int
    var segmentRetryCount: Int
    var consecutiveSegmentFailures: Int
    var lastSegmentFailureAt: String?
    var bioMetadata: BioMetadata?
}

struct RuntimeDiagnostics {
    var activeRequests: Int
    var queuedRequests: Int
    var maxConcurrentRequests: Int
    var requestQueueSaturated: Bool
    var averageQueueWaitMs: Int
    var maxQueueWaitMs: Int
    var checkingChannels: Int
    var degradedChannels: Int
    var cloudflareBlockedChannels: Int
    var activeRecordings: Int
    var queuedRecordings: Int
    var maxConcurrentRecordings: Int

    static let empty = RuntimeDiagnostics(
        activeRequests: 0,
        queuedRequests: 0,
        maxConcurrentRequests: 0,
        requestQueueSaturated: false,
        averageQueueWaitMs: 0,
        maxQueueWaitMs: 0,
        checkingChannels: 0,
        degradedChannels: 0,
        cloudflareBlockedChannels: 0,
        activeRecordings: 0,
        queuedRecordings: 0,
        maxConcurrentRecordings: 0
    )
}

struct AppConfig: Codable {
    var framerate: Int = 30
    var resolution: Int = 1080
    var outputDirectory: String = ""
    var pattern: String = "{{.Username}}_{{.Year}}-{{.Month}}-{{.Day}}_{{.Hour}}-{{.Minute}}-{{.Second}}{{if .Sequence}}_{{.Sequence}}{{end}}"
    var maxDuration: Int = 0
    var maxFilesize: Int = 0
    var interval: Int = 1 // minutes
    var selectedBrowser: SupportedBrowser = .none
    var domain: String = "https://chaturbate.com/"
    var maxConcurrentRequests: Int = 6 // max concurrent API requests across all channels
    var maxConcurrentRecordings: Int = 0 // 0 means unlimited concurrent recordings
    var breakStaticThresholdMinutes: Int = 10
    var breakNoPersonNoMotionThresholdMinutes: Int = 3
    var breakAnalysisIntervalSeconds: Int = 10
    var webServerEnabled: Bool = false
    var webServerPort: Int = 8888
    
    // Custom decoding to handle missing selectedBrowser from old configs
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        framerate = try container.decodeIfPresent(Int.self, forKey: .framerate) ?? 30
        resolution = try container.decodeIfPresent(Int.self, forKey: .resolution) ?? 1080
        outputDirectory = try container.decodeIfPresent(String.self, forKey: .outputDirectory) ?? ""
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? "{{.Username}}_{{.Year}}-{{.Month}}-{{.Day}}_{{.Hour}}-{{.Minute}}-{{.Second}}{{if .Sequence}}_{{.Sequence}}{{end}}"
        maxDuration = try container.decodeIfPresent(Int.self, forKey: .maxDuration) ?? 0
        maxFilesize = try container.decodeIfPresent(Int.self, forKey: .maxFilesize) ?? 0
        interval = try container.decodeIfPresent(Int.self, forKey: .interval) ?? 1
        selectedBrowser = try container.decodeIfPresent(SupportedBrowser.self, forKey: .selectedBrowser) ?? .none
        domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? "https://chaturbate.com/"
        maxConcurrentRequests = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentRequests) ?? 6
        maxConcurrentRecordings = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentRecordings) ?? 0
        breakStaticThresholdMinutes = try container.decodeIfPresent(Int.self, forKey: .breakStaticThresholdMinutes) ?? 10
        breakNoPersonNoMotionThresholdMinutes = try container.decodeIfPresent(Int.self, forKey: .breakNoPersonNoMotionThresholdMinutes) ?? 3
        breakAnalysisIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .breakAnalysisIntervalSeconds) ?? 10
        webServerEnabled = try container.decodeIfPresent(Bool.self, forKey: .webServerEnabled) ?? false
        webServerPort = try container.decodeIfPresent(Int.self, forKey: .webServerPort) ?? 8888
    }
    
    init() {
        // Default initializer for new instances
    }
    
    private enum CodingKeys: String, CodingKey {
        case framerate, resolution, outputDirectory, pattern
        case maxDuration, maxFilesize, interval, selectedBrowser
        case domain, maxConcurrentRequests
        case maxConcurrentRecordings
        case breakStaticThresholdMinutes
        case breakNoPersonNoMotionThresholdMinutes
        case breakAnalysisIntervalSeconds
        case webServerEnabled
        case webServerPort
    }
    
    func getOutputPath() -> String {
        if outputDirectory.isEmpty {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return documents.appendingPathComponent("ChaturbateDVR").path
        }
        return outputDirectory
    }
    
    func getUserAgent() -> String {
        selectedBrowser.userAgent
    }
    
    func getCookies() async -> String {
        let extractor = BrowserCookieExtractor()
        return await extractor.extractCookies(for: selectedBrowser, domain: "chaturbate.com")
    }
}
