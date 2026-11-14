import Foundation
import FirepickCore

/// Match title + episode → remote danmaku sources (B站 first; optional 弹弹兼容 API).
public enum DanmakuSourceResolver: Sendable {
  public struct Query: Sendable {
    public var title: String
    public var episodeLabel: String?
    public var year: String?
    /// Optional base like `https://host/token` implementing 弹弹play-compatible search/comment.
    public var customAPIBase: URL?

    public init(
      title: String,
      episodeLabel: String? = nil,
      year: String? = nil,
      customAPIBase: URL? = nil
    ) {
      self.title = title
      self.episodeLabel = episodeLabel
      self.year = year
      self.customAPIBase = customAPIBase
    }
  }

  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 12
    config.timeoutIntervalForResource = 20
    config.httpAdditionalHeaders = [
      "User-Agent":
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      "Accept": "application/json,text/xml,*/*",
    ]
    return URLSession(configuration: config)
  }()

  public static func resolve(_ query: Query) async -> [PlaybackDanmaku] {
    await withTaskGroup(of: [PlaybackDanmaku]?.self) { group in
      group.addTask {
        await resolveWithoutDeadline(query)
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(5))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first ?? []
    }
  }

  private static func resolveWithoutDeadline(_ query: Query) async -> [PlaybackDanmaku] {
    let title = cleanTitle(query.title)
    guard title.count >= 2 else { return [] }
    let episode = episodeNumber(from: query.episodeLabel) ?? 1

    if let custom = query.customAPIBase,
      let hit = await resolveCustomAPI(base: custom, title: title, episode: episode)
    {
      return [hit]
    }

    if let bili = await resolveBilibili(title: title, episode: episode, year: query.year) {
      return [bili]
    }
    return []
  }

  // MARK: - Bilibili

  private static func resolveBilibili(title: String, episode: Int, year: String?) async
    -> PlaybackDanmaku?
  {
    let types = ["media_bangumi", "media_ft"]
    for type in types {
      guard let seasonID = await searchBilibiliSeason(
        keyword: title,
        searchType: type,
        year: year
      ) else { continue }
      guard let cid = await bilibiliCID(seasonID: seasonID, episode: episode) else { continue }
      guard let url = URL(string: "https://comment.bilibili.com/\(cid).xml") else { continue }
      return PlaybackDanmaku(url: url, name: "B站")
    }
    return nil
  }

  private static func searchBilibiliSeason(keyword: String, searchType: String, year: String?)
    async -> Int?
  {
    var components = URLComponents(
      string: "https://api.bilibili.com/x/web-interface/search/type"
    )
    components?.queryItems = [
      URLQueryItem(name: "search_type", value: searchType),
      URLQueryItem(name: "keyword", value: keyword),
      URLQueryItem(name: "page", value: "1"),
    ]
    guard let url = components?.url,
      let json = await getJSON(url, referer: "https://search.bilibili.com")
    else { return nil }
    guard
      let data = json["data"] as? [String: Any],
      let results = data["result"] as? [[String: Any]],
      !results.isEmpty
    else { return nil }

    let wantYear = Int((year ?? "").prefix(4))
    let ranked = results.compactMap { row -> (score: Int, season: Int)? in
      let season =
        intValue(row["season_id"])
        ?? intValue(row["pgc_season_id"])
        ?? intValue(row["media_id"])
      guard let season else { return nil }
      let rawTitle = stripHTML(stringValue(row["title"]) ?? stringValue(row["org_title"]) ?? "")
      var score = titleSimilarity(keyword, rawTitle)
      if let wantYear, let pub = intValue(row["pubtime"]), pub > 0 {
        let cal = Calendar(identifier: .gregorian)
        let y = cal.component(.year, from: Date(timeIntervalSince1970: TimeInterval(pub)))
        if y == wantYear { score += 30 }
        else if abs(y - wantYear) <= 1 { score += 10 }
      }
      if score < 40 { return nil }
      return (score, season)
    }
    .sorted { $0.score > $1.score }
    return ranked.first?.season
  }

  private static func bilibiliCID(seasonID: Int, episode: Int) async -> Int? {
    var components = URLComponents(string: "https://api.bilibili.com/pgc/view/web/season")
    components?.queryItems = [URLQueryItem(name: "season_id", value: String(seasonID))]
    guard let url = components?.url,
      let json = await getJSON(url, referer: "https://www.bilibili.com")
    else { return nil }
    let result = json["result"] as? [String: Any] ?? json["data"] as? [String: Any]
    let episodes = (result?["episodes"] as? [[String: Any]]) ?? []
    guard !episodes.isEmpty else { return nil }

    if let exact = episodes.first(where: { episodeIndex(of: $0) == episode }),
      let cid = intValue(exact["cid"])
    {
      return cid
    }
    // 1-based index fallback when titles are ordinal strings.
    let idx = max(0, episode - 1)
    if episodes.indices.contains(idx), let cid = intValue(episodes[idx]["cid"]) {
      return cid
    }
    return intValue(episodes[0]["cid"])
  }

  private static func episodeIndex(of row: [String: Any]) -> Int? {
    if let n = intValue(row["title"]) { return n }
    if let n = episodeNumber(from: stringValue(row["title"])) { return n }
    if let n = episodeNumber(from: stringValue(row["long_title"])) { return n }
    if let n = intValue(row["ep_index"]) ?? intValue(row["i"]) { return n }
    return nil
  }

  // MARK: - Custom 弹弹兼容 API (covers 爱优腾芒哔 when user deploys danmu_api)

  private static func resolveCustomAPI(base: URL, title: String, episode: Int) async
    -> PlaybackDanmaku?
  {
    var search = URLComponents(
      url: base.appendingPathComponent("api/v2/search/episodes"),
      resolvingAgainstBaseURL: false
    )
    search?.queryItems = [
      URLQueryItem(name: "anime", value: title),
      URLQueryItem(name: "episode", value: String(episode)),
    ]
    guard let searchURL = search?.url,
      let json = await getJSON(searchURL, referer: nil)
    else { return nil }

    let animes = (json["animes"] as? [[String: Any]]) ?? []
    var episodeID: Int?
    for anime in animes {
      let episodes = (anime["episodes"] as? [[String: Any]]) ?? []
      if let match = episodes.first(where: { intValue($0["episodeNumber"]) == episode })
        ?? episodes.first(where: { episodeNumber(from: stringValue($0["episodeTitle"])) == episode })
        ?? episodes.first
      {
        episodeID = intValue(match["episodeId"]) ?? intValue(match["episodeID"])
        if episodeID != nil { break }
      }
    }
    guard let episodeID,
      let commentURL = URL(
        string: base.appendingPathComponent("api/v2/comment/\(episodeID)").absoluteString
          + "?withRelated=true&chConvert=1"
      )
    else { return nil }
    return PlaybackDanmaku(url: commentURL, name: "聚合弹幕")
  }

  // MARK: - HTTP

  private static func getJSON(_ url: URL, referer: String?) async -> [String: Any]? {
    var request = URLRequest(url: url)
    request.setValue(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      forHTTPHeaderField: "User-Agent"
    )
    if let referer {
      request.setValue(referer, forHTTPHeaderField: "Referer")
    }
    do {
      let (data, response) = try await session.data(for: request)
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        return nil
      }
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    } catch {
      return nil
    }
  }

  // MARK: - Text helpers

  public static func cleanTitle(_ raw: String) -> String {
    var text = raw
    text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(
      of: #"第[0-9０-９一二三四五六七八九十百千两]+[话集期]"#,
      with: "",
      options: .regularExpression
    )
    text = text.replacingOccurrences(
      of: #"\((?:19|20)\d{2}\)|（(?:19|20)\d{2}）|(?:19|20)\d{2}$"#,
      with: "",
      options: .regularExpression
    )
    text = text.replacingOccurrences(
      of: #"\[.*?\]|【.*?】|（完结）|\(完结\)|蓝光|高清|国语|粤语|中字|(?:2160|1080|720|480)[Pp]|4K|8K|HDR"#,
      with: "",
      options: .regularExpression
    )
    text = text.replacingOccurrences(
      of: #"(?:网飞版|Netflix版|腾讯版|爱奇艺版|优酷版|芒果版)[\s\-—_]*"#,
      with: "",
      options: [.regularExpression, .caseInsensitive]
    )
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func episodeNumber(from label: String?) -> Int? {
    guard let label else { return nil }
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    let patterns = [
      #"^第\s*0*(\d+)\s*[集期话]$"#,
      #"^0*(\d+)$"#,
      #"[Ee][Pp]?\s*0*(\d+)"#,
      #"第\s*0*(\d+)"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
      guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
        match.numberOfRanges >= 2,
        let capture = Range(match.range(at: 1), in: trimmed),
        let value = Int(trimmed[capture]),
        value > 0
      else { continue }
      return value
    }
    return nil
  }

  private static func titleSimilarity(_ a: String, _ b: String) -> Int {
    let left = normalizeTitle(a)
    let right = normalizeTitle(b)
    guard !left.isEmpty, !right.isEmpty else { return 0 }
    if left == right { return 100 }
    if right.contains(left) || left.contains(right) {
      let ratio = Double(min(left.count, right.count)) / Double(max(left.count, right.count))
      return Int(70 + ratio * 25)
    }
    // Shared prefix length as weak signal.
    let shared = zip(left, right).prefix(while: { $0 == $1 }).count
    if shared >= 2 {
      return min(65, shared * 12)
    }
    return 0
  }

  private static func normalizeTitle(_ text: String) -> String {
    text
      .lowercased()
      .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
      .replacingOccurrences(
        of: #"[：:·\-—_|／/【】\[\]()（）「」『』《》<>]"#,
        with: "",
        options: .regularExpression
      )
  }

  private static func stripHTML(_ text: String) -> String {
    text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
  }

  private static func stringValue(_ any: Any?) -> String? {
    if let s = any as? String { return s }
    if let n = any as? NSNumber { return n.stringValue }
    return nil
  }

  private static func intValue(_ any: Any?) -> Int? {
    if let i = any as? Int { return i }
    if let n = any as? NSNumber { return n.intValue }
    if let s = any as? String, let i = Int(s) { return i }
    return nil
  }
}
