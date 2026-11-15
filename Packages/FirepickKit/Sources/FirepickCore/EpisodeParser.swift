import Foundation

public struct PlaybackLine: Equatable, Sendable, Identifiable {
    public var name: String
    public var episodes: [Episode]

    public var id: String { name }
}

public struct Episode: Equatable, Sendable, Identifiable {
    public var name: String
    public var value: String

    public var id: String { "\(name)|\(value)" }

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum EpisodeParser {
    /// CatVod stores lines as `line1$$$line2` and episodes as
    /// `episode#episode`. A named episode is `name$value`.
    public static func lines(playFrom: String?, playURL: String?) -> [PlaybackLine] {
        guard let playURL, !playURL.isEmpty else { return [] }
        let names = (playFrom ?? "").components(separatedBy: "$$$")
        let groups = playURL.components(separatedBy: "$$$")

        let parsed = groups.enumerated().map { index, group in
            let fallbackName = names.indices.contains(index) ? names[index] : "线路 \(index + 1)"
            let episodes = group.components(separatedBy: "#").compactMap { raw -> Episode? in
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                if let separator = value.firstIndex(of: "$") {
                    let name = String(value[..<separator]).trimmingCharacters(in: .whitespaces)
                    let target = String(value[value.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                    return Episode(name: name.isEmpty ? target : name, value: target)
                }
                return Episode(name: value, value: value)
            }
            return PlaybackLine(name: fallbackName.isEmpty ? "线路 \(index + 1)" : fallbackName, episodes: episodes)
        }
        guard !parsed.contains(where: { lineMediaRank($0) >= 40 }) else {
            return parsed
        }
        return parsed.flatMap { line -> [PlaybackLine] in
            guard let derived = derivedHLSLine(from: line) else { return [line] }
            return [derived, line]
        }
    }

    /// Prefer lines whose episode values are directly consumable media. CatVod
    /// sources commonly expose a web viewer URL before the actual HLS mirror;
    /// handing that HTML page to AVPlayer makes startup wait for a doomed probe.
    public static func rankedLines(_ lines: [PlaybackLine]) -> [PlaybackLine] {
        lines.enumerated()
            .sorted { left, right in
                let leftRank = lineMediaRank(left.element)
                let rightRank = lineMediaRank(right.element)
                if leftRank != rightRank { return leftRank > rightRank }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    public static func lineMediaRank(_ line: PlaybackLine) -> Int {
        let samples = line.episodes.prefix(12)
        guard !samples.isEmpty else { return 0 }
        var score = 0
        for episode in samples {
            score += mediaValueRank(episode.value)
        }
        let name = line.name.lowercased()
        if name.contains("m3u8") { score += 12 }
        if name.contains("mp4") { score += 8 }
        return score
    }

    static func mediaValueRank(_ value: String) -> Int {
        let lower = value.lowercased()
        if lower.contains(".m3u8") || lower.contains("m3u8") { return 50 }
        let path = URL(string: lower)?.path ?? lower
        let ext = URL(fileURLWithPath: path).pathExtension
        switch ext {
        case "mp4", "m4v", "mov":
            return 40
        case "mkv", "flv", "ts", "iso", "m2ts":
            return 30
        case "html", "htm":
            return -10
        default:
            return ext.isEmpty ? 0 : 10
        }
    }

    private static func derivedHLSLine(from line: PlaybackLine) -> PlaybackLine? {
        guard !line.episodes.isEmpty else { return nil }
        var episodes: [Episode] = []
        for episode in line.episodes {
            guard let url = URL(string: episode.value),
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                url.pathComponents.dropLast().last == "play",
                URL(fileURLWithPath: url.path).pathExtension.isEmpty,
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return nil }
            let basePath = components.path.hasSuffix("/")
                ? String(components.path.dropLast())
                : components.path
            components.path = basePath + "/index.m3u8"
            guard let derived = components.url else { return nil }
            episodes.append(Episode(name: episode.name, value: derived.absoluteString))
        }
        return PlaybackLine(name: "\(line.name)m3u8", episodes: episodes)
    }
}

