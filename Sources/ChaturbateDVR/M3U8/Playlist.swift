import Foundation

struct Playlist {
    let playlistURL: String
    let audioPlaylistURL: String?
    let rootURL: String
    let resolution: Int
    let framerate: Int
    let codecs: String?
    let audioLikelyPresent: Bool
}

private struct AudioRendition {
    let groupID: String
    let uri: String
    let isDefault: Bool
}

private struct Variant {
    let width: Int
    let framerate: Int
    let uri: String
    let audioGroupID: String?
    let codecs: String?
    let audioLikelyPresent: Bool
}

struct M3U8Parser {
    static func parseMasterPlaylist(_ content: String, baseURL: String, targetResolution: Int, targetFramerate: Int) throws -> Playlist {
        var variants: [Variant] = []
        var audioRenditionsByGroup: [String: AudioRendition] = [:]
        
        let lines = content.components(separatedBy: .newlines)
        var currentResolution: Int?
        var currentFramerate: Int = 30
        var currentCodecs: String?
        var currentAudioGroupID: String?
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#EXT-X-MEDIA:") {
                if let rendition = parseAudioRendition(from: trimmed) {
                    if let existing = audioRenditionsByGroup[rendition.groupID] {
                        if rendition.isDefault && !existing.isDefault {
                            audioRenditionsByGroup[rendition.groupID] = rendition
                        }
                    } else {
                        audioRenditionsByGroup[rendition.groupID] = rendition
                    }
                }
                continue
            }
            
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
                currentCodecs = try? extractValue(from: trimmed, key: "CODECS")
                currentAudioGroupID = try? extractValue(from: trimmed, key: "AUDIO")
            } else if trimmed.hasPrefix("#") {
                continue
            } else if !trimmed.isEmpty && currentResolution != nil {
                if let width = currentResolution {
                    let audioLikelyPresent = codecsLikelyContainAudio(currentCodecs) || currentAudioGroupID != nil
                    variants.append(
                        Variant(
                            width: width,
                            framerate: currentFramerate,
                            uri: trimmed,
                            audioGroupID: currentAudioGroupID,
                            codecs: currentCodecs,
                            audioLikelyPresent: audioLikelyPresent
                        )
                    )
                }
                
                currentResolution = nil
                currentCodecs = nil
                currentAudioGroupID = nil
            }
        }
        
        guard !variants.isEmpty else {
            throw ChaturbateError.parsingError("No playlist variants found")
        }

        // Find matching resolution set first.
        guard let selectedVariant = findBestVariant(
            variants: variants,
            targetResolution: targetResolution,
            targetFramerate: targetFramerate
        ) else {
            throw ChaturbateError.parsingError("Resolution not found")
        }
        
        let finalResolution = selectedVariant.width
        let finalFramerate = selectedVariant.framerate
        let playlistURL = selectedVariant.uri
        
        guard let base = URL(string: baseURL),
              let fullPlaylistURL = URL(string: playlistURL, relativeTo: base)?.absoluteURL else {
            throw ChaturbateError.parsingError("Invalid playlist URL")
        }

        let fullAudioPlaylistURL: String? = {
            guard let groupID = selectedVariant.audioGroupID,
                  let rendition = audioRenditionsByGroup[groupID],
                  let audioURL = URL(string: rendition.uri, relativeTo: base)?.absoluteURL else {
                return nil
            }
            return audioURL.absoluteString
        }()

        let rootURL = fullPlaylistURL.deletingLastPathComponent().absoluteString
        
        return Playlist(
            playlistURL: fullPlaylistURL.absoluteString,
            audioPlaylistURL: fullAudioPlaylistURL,
            rootURL: rootURL,
            resolution: finalResolution,
            framerate: finalFramerate,
            codecs: selectedVariant.codecs,
            audioLikelyPresent: selectedVariant.audioLikelyPresent
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
        let pattern = "\(key)=(\"[^\"]*\"|[^,]+)"
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let nsString = line as NSString
        let results = regex.matches(in: line, options: [], range: NSRange(location: 0, length: nsString.length))
        
        guard let match = results.first,
              let range = Range(match.range(at: 1), in: line) else {
            throw ChaturbateError.parsingError("Could not extract \(key)")
        }
        
        return String(line[range]).replacingOccurrences(of: "\"", with: "")
    }

    private static func parseAudioRendition(from line: String) -> AudioRendition? {
        guard let type = try? extractValue(from: line, key: "TYPE"),
              type.uppercased() == "AUDIO",
              let groupID = try? extractValue(from: line, key: "GROUP-ID"),
              let uri = try? extractValue(from: line, key: "URI"),
              !groupID.isEmpty,
              !uri.isEmpty else {
            return nil
        }

        let isDefault: Bool
        if let defaultValue = try? extractValue(from: line, key: "DEFAULT") {
            isDefault = defaultValue.uppercased() == "YES"
        } else {
            isDefault = false
        }

        return AudioRendition(groupID: groupID, uri: uri, isDefault: isDefault)
    }

    
    private static func findBestVariant(
        variants: [Variant],
        targetResolution: Int,
        targetFramerate: Int
    ) -> Variant? {
        let availableWidths = Set(variants.map { $0.width })
        let selectedWidth: Int

        if availableWidths.contains(targetResolution) {
            selectedWidth = targetResolution
        } else if let below = availableWidths.filter({ $0 < targetResolution }).max() {
            selectedWidth = below
        } else if let minWidth = availableWidths.min() {
            selectedWidth = minWidth
        } else {
            return nil
        }

        let widthVariants = variants.filter { $0.width == selectedWidth }
        if widthVariants.isEmpty {
            return nil
        }

        // Prefer variants whose CODECS indicate audio.
        let preferredForAudio = widthVariants.filter { $0.audioLikelyPresent }
        let pool = preferredForAudio.isEmpty ? widthVariants : preferredForAudio

        if let exactFPS = pool.first(where: { $0.framerate == targetFramerate }) {
            return exactFPS
        }

        if let fallbackFPS = pool.min(by: {
            abs($0.framerate - targetFramerate) < abs($1.framerate - targetFramerate)
        }) {
            return fallbackFPS
        }

        return pool.first
    }

    private static func codecsLikelyContainAudio(_ codecs: String?) -> Bool {
        guard let codecs, !codecs.isEmpty else {
            return false
        }

        let lower = codecs.lowercased()
        return lower.contains("mp4a")
            || lower.contains("ac-3")
            || lower.contains("ec-3")
            || lower.contains("opus")
    }
}

struct MediaSegment {
    let uri: String
    let duration: Double
    let sequenceNumber: Int
}
