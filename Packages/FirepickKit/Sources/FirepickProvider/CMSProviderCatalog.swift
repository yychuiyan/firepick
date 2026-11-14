import Foundation

/// Bundled AppleCMS `provide/vod` candidate pool (`cms-candidates.json`).
public enum CMSProviderCatalog {
  public struct Entry: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var api: String

    public var id: String { key }

    public init(key: String, name: String, api: String) {
      self.key = key
      self.name = name
      self.api = api
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

  /// Prefer remote catalog when reachable; otherwise bundled.
  public static func loadCandidates(
    remoteURL: URL? = URL(
      string: "https://dl.yychuiyan.com/firepick/sources/cms-candidates.json"
    ),
    session: URLSession = .shared,
    timeout: TimeInterval = 4
  ) async -> [Entry] {
    if let remoteURL {
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
    return bundledCandidates()
  }
}
