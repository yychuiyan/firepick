import Foundation

/// Bundled AppleCMS `provide/vod` candidate pool (`cms-candidates.json`).
public enum CMSProviderCatalog {
  public struct Entry: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var api: String
    public var adult: Bool?
    public var priority: Int?

    public var id: String { key }

    public init(
      key: String,
      name: String,
      api: String,
      adult: Bool? = nil,
      priority: Int? = nil
    ) {
      self.key = key
      self.name = name
      self.api = api
      self.adult = adult
      self.priority = priority
    }
  }

  private struct File: Codable, Sendable {
    var providers: [Entry]
  }

  /// Short chip labels for 采集站管理 / 播放来源 (≤4 chars-ish).
  public static let shortNames: [String: String] = [
    "lzcaiji": "量子",
    "lzi": "量子",
    "bfzy": "暴风",
    "subo": "速播",
    "ffzy": "非凡",
    "ffzy_cj": "非凡",
    "jisu": "极速",
    "dytt": "天堂",
    "zuid": "最大",
    "zuid_me": "最大",
    "guangsu": "光速",
    "ruyi": "如意",
    "iqiyi": "爱奇艺",
    "xinlang": "新浪",
    "uku": "U酷",
    "uku_alt": "U酷",
    "maoyan": "猫眼",
    "zy360": "360",
    "zy360zz": "360",
    "modu": "魔都",
    "wujin": "无尽",
    "wujin_com": "无尽",
    "hongniu": "红牛",
    "hongniu3": "红牛",
    "wolong": "卧龙",
    "wolong_web": "卧龙",
    "haohua": "豪华",
    "yzzy": "优质",
    "zy1080": "1080",
    "huya": "虎牙",
    "maotai": "茅台",
    "jinying": "金鹰",
    "jinyingzy": "金鹰",
    "ikun": "iKun",
    "moduanime": "魔都漫",
    "baidu": "百度",
    "douban": "豆瓣",
    "piaoling": "飘零",
    "suoni": "索尼",
    "heimuer": "木耳",
    "niuniu": "牛牛",
    "yaya": "丫丫",
    "yinghua": "樱花",
    "sdzy": "闪电",
    "kuaiche": "快车",
    "feisu": "飞速",
    "kuaikan": "快看",
    "xiongzhang": "熊掌",
    "qihu": "奇虎",
    "kuaiyun": "快云",
    "wwzy": "旺旺",
    "hw8": "华为吧",
    "okzy": "OK",
    "taopian": "淘片",
    "nb_modu": "魔都",
    "nb_xgzy": "西瓜",
    "nb_dzzy": "大众",
    "nb_ikun": "iKun",
  ]

  public static func displayName(for entry: Entry) -> String {
    shortNames[entry.key] ?? entry.name
  }

  public static func bundledCandidates() -> [Entry] {
    guard let url = Bundle.module.url(forResource: "cms-candidates", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let file = try? JSONDecoder().decode(File.self, from: data)
    else {
      return []
    }
    return file.providers
  }

  public static func curatedCandidates() -> [Entry] {
    bundledCandidates()
      .filter { $0.priority != nil }
      .sorted { ($0.priority ?? .max) < ($1.priority ?? .max) }
  }

  public static let defaultRemoteCandidateURLs: [URL] = [
    URL(string: "https://sources.yychuiyan.com/api/v1/cms-candidates.json")!,
    URL(
      string:
        "https://firepick-1302621537.cos.ap-shanghai.myqcloud.com/firepick-monitor/data/cms-candidates.json"
    )!,
    URL(string: "https://sources.yychuiyan.com/data/cms-candidates.json")!,
  ]

  public static let defaultRemoteBestURLs: [URL] = [
    URL(string: "https://sources.yychuiyan.com/api/v1/best.json")!,
    URL(
      string:
        "https://firepick-1302621537.cos.ap-shanghai.myqcloud.com/firepick-monitor/data/best.json"
    )!,
    URL(string: "https://sources.yychuiyan.com/data/best.json")!,
  ]

  /// Prefer the monitor catalog, then fall back to the bundled pool.
  public static func loadCandidates(
    remoteURL: URL? = nil,
    session: URLSession = .shared,
    timeout: TimeInterval = 4
  ) async -> [Entry] {
    let urls = remoteURL.map { [$0] } ?? defaultRemoteCandidateURLs
    return await fetchRemoteCandidates(urls: urls, session: session, timeout: timeout)
      ?? bundledCandidates()
  }

  /// Returns only remotely fetched candidates. This lets callers distinguish
  /// a monitor outage from a successful bundled fallback.
  public static func loadRemoteCandidates(
    remoteURL: URL? = nil,
    session: URLSession = .shared,
    timeout: TimeInterval = 4
  ) async -> [Entry]? {
    let urls = remoteURL.map { [$0] } ?? defaultRemoteCandidateURLs
    return await fetchRemoteCandidates(urls: urls, session: session, timeout: timeout)
  }

  /// Keeps the monitor shortlist first, then fills the probe budget from the
  /// larger online catalog. Saved/default pools are fallback-only.
  public static func prioritizedCandidates(
    best: [Entry],
    catalog: [Entry],
    fallback: [Entry],
    limit: Int
  ) -> [Entry] {
    guard limit > 0 else { return [] }
    var seenHosts = Set<String>()
    var result: [Entry] = []
    for entry in best + catalog + fallback {
      let host = URL(string: entry.api)?.host?.lowercased() ?? entry.key
      guard seenHosts.insert(host).inserted else { continue }
      result.append(entry)
      if result.count >= limit { break }
    }
    return result
  }

  public static func activePoolLimit(adultMode: Bool) -> Int {
    adultMode ? 20 : 10
  }

  public static func candidatePoolLimit(adultMode: Bool) -> Int {
    adultMode ? 40 : 30
  }

  /// Keep an adult-mode pool mixed and useful for ordinary search: normal
  /// providers occupy the leading wave, while adult providers have reserved
  /// slots. Hosts are unique so mirrors do not consume two rows.
  public static func balancedActivePool(
    primary: [Entry],
    fallback: [Entry],
    adultMode: Bool,
    limit: Int,
    minimumAdult: Int = 4
  ) -> [Entry] {
    guard limit > 0 else { return [] }
    let eligiblePrimary = adultMode ? primary : primary.filter { $0.adult != true }
    let eligibleFallback = adultMode ? fallback : fallback.filter { $0.adult != true }
    var seenHosts = Set<String>()
    let unique = (eligiblePrimary + eligibleFallback).filter { entry in
      let host = URL(string: entry.api)?.host?.lowercased() ?? entry.key
      return seenHosts.insert(host).inserted
    }
    guard adultMode else {
      return Array(unique.prefix(limit))
    }

    let adults = unique.filter { $0.adult == true }
    let normals = unique.filter { $0.adult != true }
    let adultCount = min(max(0, minimumAdult), adults.count, limit)
    let normalReserve = max(0, limit - adultCount)
    let normalSeed = Array(normals.prefix(normalReserve))
    let adultSeed = Array(adults.prefix(adultCount))
    var result = normalSeed + adultSeed
    result.append(contentsOf: normals.dropFirst(normalSeed.count))
    result.append(contentsOf: adults.dropFirst(adultSeed.count))
    return Array(result.prefix(limit))
  }

  /// Load the monitor's best-line shortlist. An empty result means every remote
  /// endpoint failed, allowing callers to preserve their local active pool.
  public static func loadBestCandidates(
    session: URLSession = .shared,
    timeout: TimeInterval = 2
  ) async -> [Entry] {
    await fetchRemoteCandidates(
      urls: defaultRemoteBestURLs,
      session: session,
      timeout: timeout
    ) ?? []
  }

  private static func fetchRemoteCandidates(
    urls: [URL],
    session: URLSession,
    timeout: TimeInterval
  ) async -> [Entry]? {
    for remoteURL in urls {
      var request = URLRequest(url: remoteURL, timeoutInterval: timeout)
      request.cachePolicy = .reloadIgnoringLocalCacheData
      if let (data, response) = try? await session.data(for: request),
        let http = response as? HTTPURLResponse,
        (200..<300).contains(http.statusCode),
        let file = try? JSONDecoder().decode(File.self, from: data),
        !file.providers.isEmpty
      {
        return file.providers
      }
    }
    return nil
  }
}
