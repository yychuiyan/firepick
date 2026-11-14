import FirepickCore
import Foundation

/// FongMi-style HLS mid-roll ad detection for VOD media playlists.
///
/// Keeps the original timeline (AVPlayer/MPV seek) instead of rewriting the
/// m3u8 — safer for AES implicit IV, byte ranges, and multi-rendition sync.
///
/// Heuristics (legacy `HlsAdsParser` shape):
/// 1. Only playlists with `#EXT-X-ENDLIST`
/// 2. Path/prefix minority groups when the majority group is > 50% of segments
/// 3. Discontinuity blocks that are not the majority duration block
/// 4. Optional `ads` host/pattern hits from the warehouse config
public enum HlsAdSkipDetector {
  public struct Options: Sendable, Equatable {
    /// Warehouse `ads` entries: substring or regex (same spirit as CatVod).
    public var adPatterns: [String]
    /// Abort when detected ads exceed this fraction of total duration.
    public var maxAdDurationRatio: Double
    public var session: URLSession

    public init(
      adPatterns: [String] = [],
      maxAdDurationRatio: Double = 0.35,
      session: URLSession = .shared
    ) {
      self.adPatterns = adPatterns
      self.maxAdDurationRatio = maxAdDurationRatio
      self.session = session
    }
  }

  public struct Detection: Sendable, Equatable {
    public var skips: [SkipSegment]
    public var reason: String

    public static let empty = Detection(skips: [], reason: "none")
  }

  // MARK: - Public

  public static func detect(
    url: URL,
    headers: [String: String] = [:],
    options: Options = .init()
  ) async -> Detection {
    guard looksLikeHLS(url) else {
      return Detection(skips: [], reason: "not-hls")
    }
    do {
      let text = try await fetchPlaylist(url: url, headers: headers, session: options.session)
      return detect(playlist: text, baseURL: url, options: options)
    } catch {
      return Detection(skips: [], reason: "fetch-failed")
    }
  }

  public static func detect(
    playlist text: String,
    baseURL: URL?,
    options: Options = .init()
  ) -> Detection {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.contains("#EXTM3U") else {
      return Detection(skips: [], reason: "not-m3u8")
    }
    // Master → pick highest bandwidth media playlist URI and stop here
    // (caller should re-fetch; unit tests pass media playlists directly).
    if isMasterPlaylist(trimmed) {
      return Detection(skips: [], reason: "master")
    }
    guard isVodPlaylist(trimmed) else {
      return Detection(skips: [], reason: "live")
    }

    let segments = parseMediaSegments(trimmed, baseURL: baseURL)
    guard segments.count >= 4 else {
      return Detection(skips: [], reason: "too-few-segments")
    }

    var adFlags = Array(repeating: false, count: segments.count)

    // 1) Config ads host/pattern hits (additive, does not require majority gate).
    if !options.adPatterns.isEmpty {
      for (index, segment) in segments.enumerated() {
        if matchesAdPattern(segment.absoluteURL.absoluteString, patterns: options.adPatterns)
          || matchesAdPattern(segment.absoluteURL.host ?? "", patterns: options.adPatterns)
        {
          adFlags[index] = true
        }
      }
    }

    // 2) Path/prefix minority groups (FongMi findMinorityGroup).
    applyPathMinorityAds(segments: segments, flags: &adFlags)

    // 3) Discontinuity blocks that are not the majority duration block.
    applyDiscontinuityMinorityAds(segments: segments, flags: &adFlags)

    let adCount = adFlags.filter(\.self).count
    guard adCount > 0, adCount < segments.count else {
      return Detection(skips: [], reason: adCount == 0 ? "no-ads" : "all-ads")
    }

    let totalDuration = segments.reduce(0.0) { $0 + $1.duration }
    let adDuration = zip(segments, adFlags).reduce(0.0) { sum, pair in
      pair.1 ? sum + pair.0.duration : sum
    }
    guard totalDuration > 0,
      adDuration / totalDuration <= options.maxAdDurationRatio
    else {
      return Detection(skips: [], reason: "ad-ratio-too-high")
    }

    let skips = ranges(from: segments, flags: adFlags)
    guard !skips.isEmpty else {
      return Detection(skips: [], reason: "no-ranges")
    }
    return Detection(skips: skips, reason: "hls-heuristic")
  }

  /// Resolve master → media once, then detect.
  public static func detectResolvingMaster(
    url: URL,
    headers: [String: String] = [:],
    options: Options = .init()
  ) async -> Detection {
    guard looksLikeHLS(url) else {
      return Detection(skips: [], reason: "not-hls")
    }
    do {
      let text = try await fetchPlaylist(url: url, headers: headers, session: options.session)
      if isMasterPlaylist(text),
        let mediaURL = preferredMediaPlaylistURL(from: text, baseURL: url)
      {
        let mediaText = try await fetchPlaylist(
          url: mediaURL,
          headers: headers,
          session: options.session
        )
        return detect(playlist: mediaText, baseURL: mediaURL, options: options)
      }
      return detect(playlist: text, baseURL: url, options: options)
    } catch {
      return Detection(skips: [], reason: "fetch-failed")
    }
  }

  public static func looksLikeHLS(_ url: URL) -> Bool {
    let text = url.absoluteString.lowercased()
    if text.contains(".m3u8") { return true }
    if text.contains("m3u8") { return true }
    if url.pathExtension.lowercased() == "m3u8" { return true }
    return false
  }

  // MARK: - Heuristics

  private static func applyPathMinorityAds(
    segments: [Segment],
    flags: inout [Bool]
  ) {
    var groups: [String: [Int]] = [:]
    for (index, segment) in segments.enumerated() {
      let key = pathGroupKey(for: segment.absoluteURL)
      groups[key, default: []].append(index)
    }
    guard groups.count >= 2 else { return }
    let sorted = groups.values.sorted { $0.count > $1.count }
    guard let majority = sorted.first,
      majority.count * 2 > segments.count
    else { return }
    let majorityKey = pathGroupKey(for: segments[majority[0]].absoluteURL)
    for (key, indices) in groups where key != majorityKey {
      for index in indices {
        flags[index] = true
      }
    }
  }

  private static func applyDiscontinuityMinorityAds(
    segments: [Segment],
    flags: inout [Bool]
  ) {
    var blocks: [[Int]] = []
    var current: [Int] = []
    for (index, segment) in segments.enumerated() {
      if segment.discontinuityBefore, !current.isEmpty {
        blocks.append(current)
        current = []
      }
      current.append(index)
    }
    if !current.isEmpty { blocks.append(current) }
    guard blocks.count >= 2 else { return }

    let durations = blocks.map { indices in
      indices.reduce(0.0) { $0 + segments[$1].duration }
    }
    guard let maxDuration = durations.max(), maxDuration > 0 else { return }
    let majorityIndices = durations.enumerated()
      .filter { abs($0.element - maxDuration) < 0.001 }
      .map(\.offset)
    // Require a clear majority block (> 50% of total duration).
    let total = durations.reduce(0, +)
    guard maxDuration * 2 > total else { return }

    for (blockIndex, indices) in blocks.enumerated()
    where !majorityIndices.contains(blockIndex) {
      // Only treat short discontinuity islands as ads (avoid killing alt CDN).
      let blockDuration = durations[blockIndex]
      guard blockDuration < maxDuration * 0.25 else { continue }
      for index in indices {
        flags[index] = true
      }
    }
  }

  private static func pathGroupKey(for url: URL) -> String {
    let host = (url.host ?? "").lowercased()
    var path = url.path
    if path.hasSuffix("/") { path.removeLast() }
    if let slash = path.lastIndex(of: "/") {
      path = String(path[..<slash])
    }
    // Collapse numeric / hash leaf folders that differ per segment.
    let parts = path.split(separator: "/").map(String.init)
    let normalized = parts.map { part -> String in
      if part.count >= 8, part.allSatisfy(\.isHexDigit) { return "#" }
      if part.allSatisfy(\.isNumber) { return "N" }
      return part
    }
    return host + "/" + normalized.joined(separator: "/")
  }

  private static func ranges(from segments: [Segment], flags: [Bool]) -> [SkipSegment] {
    var result: [SkipSegment] = []
    var time = 0.0
    var rangeStart: Double?
    for (index, segment) in segments.enumerated() {
      let isAd = flags[index]
      if isAd {
        if rangeStart == nil { rangeStart = time }
      } else if let start = rangeStart {
        result.append(SkipSegment(type: "ad", start: start, end: time))
        rangeStart = nil
      }
      time += segment.duration
    }
    if let start = rangeStart, time > start {
      result.append(SkipSegment(type: "ad", start: start, end: time))
    }
    return mergeAdjacent(result)
  }

  private static func mergeAdjacent(_ skips: [SkipSegment], gap: Double = 0.35) -> [SkipSegment] {
    guard var current = skips.first else { return [] }
    var merged: [SkipSegment] = []
    for next in skips.dropFirst() {
      let currentEnd = current.end ?? current.start
      if next.start <= currentEnd + gap {
        current.end = max(currentEnd, next.end ?? next.start)
      } else {
        merged.append(current)
        current = next
      }
    }
    merged.append(current)
    return merged
  }

  // MARK: - Playlist parsing

  struct Segment: Equatable {
    var duration: Double
    var uri: String
    var absoluteURL: URL
    var discontinuityBefore: Bool
  }

  static func isVodPlaylist(_ text: String) -> Bool {
    text.contains("#EXT-X-ENDLIST")
  }

  static func isMasterPlaylist(_ text: String) -> Bool {
    text.contains("#EXT-X-STREAM-INF")
  }

  static func preferredMediaPlaylistURL(from text: String, baseURL: URL) -> URL? {
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    var bestBandwidth = -1
    var bestURI: String?
    var pendingBandwidth = 0
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("#EXT-X-STREAM-INF") {
        pendingBandwidth = bandwidth(from: trimmed) ?? 0
      } else if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
        if pendingBandwidth >= bestBandwidth {
          bestBandwidth = pendingBandwidth
          bestURI = trimmed
        }
        pendingBandwidth = 0
      }
    }
    guard let bestURI else { return nil }
    return URL(string: bestURI, relativeTo: baseURL)?.absoluteURL
  }

  static func parseMediaSegments(_ text: String, baseURL: URL?) -> [Segment] {
    let lines = text.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    var segments: [Segment] = []
    var pendingDuration: Double?
    var discontinuity = false
    for line in lines {
      if line.hasPrefix("#EXTINF:") {
        let payload = line.dropFirst("#EXTINF:".count)
        let number = payload.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        pendingDuration = Double(number)
      } else if line.hasPrefix("#EXT-X-DISCONTINUITY") {
        discontinuity = true
      } else if line.hasPrefix("#") {
        continue
      } else if !line.isEmpty, let duration = pendingDuration {
        let absolute =
          URL(string: line, relativeTo: baseURL)?.absoluteURL
          ?? URL(string: line)
          ?? baseURL
          ?? URL(fileURLWithPath: "/")
        segments.append(
          Segment(
            duration: max(duration, 0.01),
            uri: line,
            absoluteURL: absolute,
            discontinuityBefore: discontinuity
          )
        )
        pendingDuration = nil
        discontinuity = false
      }
    }
    return segments
  }

  private static func bandwidth(from streamInf: String) -> Int? {
    guard let range = streamInf.range(of: "BANDWIDTH=") else { return nil }
    let rest = streamInf[range.upperBound...]
    let digits = rest.prefix(while: { $0.isNumber })
    return Int(digits)
  }

  private static func matchesAdPattern(_ value: String, patterns: [String]) -> Bool {
    let haystack = value.lowercased()
    for pattern in patterns {
      let needle = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !needle.isEmpty else { continue }
      if haystack.contains(needle.lowercased()) { return true }
      if let regex = try? NSRegularExpression(pattern: needle, options: [.caseInsensitive]),
        regex.firstMatch(
          in: value,
          options: [],
          range: NSRange(value.startIndex..., in: value)
        ) != nil
      {
        return true
      }
    }
    return false
  }

  private static func fetchPlaylist(
    url: URL,
    headers: [String: String],
    session: URLSession
  ) async throws -> String {
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    if request.value(forHTTPHeaderField: "User-Agent") == nil {
      request.setValue(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
        forHTTPHeaderField: "User-Agent"
      )
    }
    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw URLError(.badServerResponse)
    }
    guard let text = String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .isoLatin1)
    else {
      throw URLError(.cannotDecodeContentData)
    }
    return text
  }
}
