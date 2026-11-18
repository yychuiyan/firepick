import Foundation

public enum EpisodeUpdatePolicy {
  public static let refreshInterval: TimeInterval = 12 * 60

  /// Maps each CMS provider to the newest episode number advertised by a
  /// matching search row. Published progress wins over raw playback entries so
  /// trailers or bonus clips cannot masquerade as episode 39.
  public static func sourceEpisodeCounts(
    from items: [MediaItem],
    matchingTitle title: String
  ) -> [String: Int] {
    let target = normalizedTitle(title)
    guard !target.isEmpty else { return [:] }

    var counts: [String: Int] = [:]
    for item in items where normalizedTitle(item.name) == target {
      guard let separator = item.vodId.firstIndex(of: "|") else { continue }
      let providerKey = String(item.vodId[..<separator])
      guard !providerKey.isEmpty else { continue }
      counts[providerKey] = max(counts[providerKey] ?? 0, episodeCount(in: item))
    }
    return counts
  }

  public static func episodeCount(in item: MediaItem) -> Int {
    progressEpisodeCount(from: item.remarks)
      ?? EpisodeParser.lines(playFrom: item.playFrom, playURL: item.playURL)
        .map(\.episodes.count)
        .max()
      ?? 0
  }

  public static func progressEpisodeCount(from remarks: String?) -> Int? {
    let text = remarks?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { return nil }
    let patterns = [
      #"第\s*0*(\d+)\s*[集期话]"#,
      #"更新(?:至|到|第)?\s*(\d+)\s*[集期话]"#,
      #"全\s*(\d+)\s*[集期话]"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      guard let match = regex.firstMatch(in: text, range: range),
        match.numberOfRanges > 1,
        let numberRange = Range(match.range(at: 1), in: text),
        let value = Int(text[numberRange]),
        value > 0
      else { continue }
      return value
    }
    return nil
  }

  public static func displayProgress(from remarks: String?) -> String? {
    let text = remarks?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { return nil }
    guard let count = progressEpisodeCount(from: text) else { return text }
    if text.contains("全"), !text.contains("更新") {
      return "全\(count)集"
    }
    return "已更新至\(count)集"
  }

  public static func isCheckDue(
    lastCheckedAt: Date?,
    now: Date,
    interval: TimeInterval = refreshInterval
  ) -> Bool {
    guard let lastCheckedAt else { return true }
    return now.timeIntervalSince(lastCheckedAt) >= interval
  }

  private static func normalizedTitle(_ title: String) -> String {
    title.lowercased().filter { character in
      !character.isWhitespace && !character.isPunctuation
    }
  }
}
