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

        return groups.enumerated().map { index, group in
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
    }
}

