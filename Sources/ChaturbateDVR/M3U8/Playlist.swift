import Foundation

struct Playlist {
    let playlistURL: String
    let rootURL: String
    let resolution: Int
    let framerate: Int
}

struct Resolution {
    var width: Int
    var framerates: [Int: String] // [framerate: url]
}

struct M3U8Parser {
    static func parseMasterPlaylist(_ content: String, baseURL: String, targetResolution: Int, targetFramerate: Int) throws -> Playlist {
        var resolutions: [Int: Resolution] = [:]
        
        let lines = content.components(separatedBy: .newlines)
        var currentResolution: Int?
        var currentFramerate: Int = 30
        var currentURI: String?
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("#EXT-X-STREAM-INF:") {
                // Parse resolution
                if let resolutionMatch = try? extractValue(from: trimmed, key: "RESOLUTION") {
                    let parts = resolutionMatch.split(separator: "x")
                    if parts.count == 2, let width = Int(parts[1]) {
                        currentResolution = width
                    }
                }
                
                // Parse framerate from NAME
                if let nameMatch = try? extractValue(from: trimmed, key: "NAME") {
                    if nameMatch.contains("FPS:60.0") {
                        currentFramerate = 60
                    } else {
                        currentFramerate = 30
                    }
                }
            } else if trimmed.hasPrefix("#") {
                continue
            } else if !trimmed.isEmpty && currentResolution != nil {
                currentURI = trimmed
                
                if let width = currentResolution, let uri = currentURI {
                    if resolutions[width] == nil {
                        resolutions[width] = Resolution(width: width, framerates: [:])
                    }
                    resolutions[width]?.framerates[currentFramerate] = uri
                }
                
                currentResolution = nil
                currentURI = nil
            }
        }
        
        // Find matching resolution
        guard let variant = findBestVariant(resolutions: resolutions, targetResolution: targetResolution) else {
            throw ChaturbateError.parsingError("Resolution not found")
        }
        
        let finalResolution = variant.width
        var finalFramerate = targetFramerate
        var playlistURL: String
        
        if let url = variant.framerates[targetFramerate] {
            playlistURL = url
        } else if let firstURL = variant.framerates.values.first {
            playlistURL = firstURL
            finalFramerate = variant.framerates.first(where: { $0.value == firstURL })?.key ?? 30
        } else {
            throw ChaturbateError.parsingError("No playlist URL found")
        }
        
        guard let base = URL(string: baseURL),
              let fullPlaylistURL = URL(string: playlistURL, relativeTo: base)?.absoluteURL else {
            throw ChaturbateError.parsingError("Invalid playlist URL")
        }

        let rootURL = fullPlaylistURL.deletingLastPathComponent().absoluteString
        
        return Playlist(
            playlistURL: fullPlaylistURL.absoluteString,
            rootURL: rootURL,
            resolution: finalResolution,
            framerate: finalFramerate
        )
    }
    
    static func parseMediaPlaylist(_ content: String) throws -> [MediaSegment] {
        var segments: [MediaSegment] = []
        let lines = content.components(separatedBy: .newlines)
        
        var currentDuration: Double = 0
        var nextSequenceNumber = 0
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let sequenceValue = trimmed.replacingOccurrences(of: "#EXT-X-MEDIA-SEQUENCE:", with: "")
                nextSequenceNumber = Int(sequenceValue.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if trimmed.hasPrefix("#EXTINF:") {
                let durationString = trimmed.replacingOccurrences(of: "#EXTINF:", with: "")
                    .components(separatedBy: ",").first ?? "0"
                currentDuration = Double(durationString) ?? 0
            } else if !trimmed.isEmpty && !trimmed.hasPrefix("#") && currentDuration > 0 {
                segments.append(MediaSegment(uri: trimmed, duration: currentDuration, sequenceNumber: nextSequenceNumber))
                nextSequenceNumber += 1
                currentDuration = 0
            }
        }
        
        return segments
    }

    static func parseInitSegmentURI(_ content: String) -> String? {
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#EXT-X-MAP:") else {
                continue
            }

            if let uri = try? extractValue(from: trimmed, key: "URI"), !uri.isEmpty {
                return uri
            }
        }

        return nil
    }
    
    private static func extractValue(from line: String, key: String) throws -> String {
        let pattern = "\(key)=([^,]+)"
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let nsString = line as NSString
        let results = regex.matches(in: line, options: [], range: NSRange(location: 0, length: nsString.length))
        
        guard let match = results.first,
              let range = Range(match.range(at: 1), in: line) else {
            throw ChaturbateError.parsingError("Could not extract \(key)")
        }
        
        return String(line[range]).replacingOccurrences(of: "\"", with: "")
    }
    
    private static func findBestVariant(resolutions: [Int: Resolution], targetResolution: Int) -> Resolution? {
        // Try exact match first
        if let exact = resolutions[targetResolution] {
            return exact
        }
        
        // Find highest resolution below target
        let candidates = resolutions.values.filter { $0.width < targetResolution }
        return candidates.max(by: { $0.width < $1.width })
    }
}

struct MediaSegment {
    let uri: String
    let duration: Double
    let sequenceNumber: Int
}
