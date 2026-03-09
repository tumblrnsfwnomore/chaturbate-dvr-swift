import Foundation

enum ChaturbateError: LocalizedError {
    case invalidChannel
    case channelOffline
    case cloudflareBlocked
    case ageVerification
    case privateStream
    case paused
    case networkError(String)
    case parsingError(String)
    case fileError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidChannel:
            return "Channel does not exist (404)"
        case .channelOffline:
            return "Channel is offline"
        case .cloudflareBlocked:
            return "Channel was blocked by Cloudflare"
        case .ageVerification:
            return "Age verification required"
        case .privateStream:
            return "Private stream - authentication required"
        case .paused:
            return "Channel is paused"
        case .networkError(let message):
            return "Network error: \(message)"
        case .parsingError(let message):
            return "Parsing error: \(message)"
        case .fileError(let message):
            return "File error: \(message)"
        }
    }
}
