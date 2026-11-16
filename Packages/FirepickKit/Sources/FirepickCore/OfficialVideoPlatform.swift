import Foundation

public enum OfficialVideoPlatform: String, Codable, CaseIterable, Identifiable, Sendable {
  case tencent
  case youku
  case iqiyi
  case mgtv
  case bilibili

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .tencent:
      "腾讯视频"
    case .iqiyi:
      "爱奇艺"
    case .youku:
      "优酷"
    case .mgtv:
      "芒果TV"
    case .bilibili:
      "哔哩哔哩"
    }
  }

  public var shortMark: String {
    switch self {
    case .tencent:
      "腾讯"
    case .iqiyi:
      "爱奇艺"
    case .youku:
      "优酷"
    case .mgtv:
      "芒果"
    case .bilibili:
      "B站"
    }
  }

  public var homeURL: URL {
    switch self {
    case .tencent:
      URL(string: "https://v.qq.com/")!
    case .iqiyi:
      URL(string: "https://www.iqiyi.com/")!
    case .youku:
      URL(string: "https://www.youku.com/")!
    case .mgtv:
      URL(string: "https://www.mgtv.com/")!
    case .bilibili:
      URL(string: "https://m.bilibili.com/")!
    }
  }

  public var dataStoreIdentifier: UUID {
    switch self {
    case .tencent:
      UUID(uuidString: "33A57DB1-C839-4A06-A16D-81634E73EC54")!
    case .iqiyi:
      UUID(uuidString: "9E066559-348D-4057-9A46-EFC963AEC798")!
    case .youku:
      UUID(uuidString: "D38D6BB4-10D4-4CDC-A8D3-A945789C17D8")!
    case .mgtv:
      UUID(uuidString: "83EBBF02-CC5C-4470-8073-295705876EB1")!
    case .bilibili:
      UUID(uuidString: "84256441-C359-46C1-80B6-CAA58CC50D97")!
    }
  }

  public var officialHosts: [String] {
    switch self {
    case .tencent:
      [
        "v.qq.com",
        "m.v.qq.com",
        "film.qq.com",
        "ptlogin2.qq.com",
        "graph.qq.com",
        "open.weixin.qq.com",
        "passport.qq.com",
      ]
    case .iqiyi:
      ["iqiyi.com"]
    case .youku:
      ["youku.com"]
    case .mgtv:
      ["mgtv.com"]
    case .bilibili:
      ["bilibili.com"]
    }
  }

  public func searchURL(for query: String) -> URL? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }

    switch self {
    case .tencent:
      var components = URLComponents(string: "https://v.qq.com/x/search/")
      components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
      return components?.url
    case .iqiyi:
      var components = URLComponents(string: "https://m.iqiyi.com/search.html")
      components?.queryItems = [URLQueryItem(name: "key", value: trimmed)]
      return components?.url
    case .youku:
      return pathSearchURL(
        base: "https://so.youku.com/search_video/q_",
        query: trimmed
      )
    case .mgtv:
      var components = URLComponents(string: "https://so.mgtv.com/so")
      components?.queryItems = [URLQueryItem(name: "k", value: trimmed)]
      return components?.url
    case .bilibili:
      var components = URLComponents(string: "https://m.bilibili.com/search")
      components?.queryItems = [URLQueryItem(name: "keyword", value: trimmed)]
      return components?.url
    }
  }

  public func owns(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host?.lowercased()
    else { return false }

    return officialHosts.contains { domain in
      host == domain || host.hasSuffix(".\(domain)")
    }
  }

  /// Resolves a pasted URL to the platform that should display it. This only
  /// accepts official platform pages and Tencent's app links that have a safe
  /// official HTTPS equivalent.
  public static func linkTarget(from input: String) -> OfficialPlatformLink? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      trimmed.count <= 2_048,
      !trimmed.contains(where: \.isWhitespace)
    else { return nil }

    let parsed = URL(string: trimmed)
      ?? URL(string: "https://\(trimmed)")
    guard let parsed else { return nil }

    let url = parsed.scheme == nil
      ? URL(string: "https://\(trimmed)")
      : parsed
    guard let url else { return nil }

    if let platform = allCases.first(where: { $0.owns(url) }) {
      return OfficialPlatformLink(platform: platform, url: url)
    }

    if let embedded = tencent.embeddedWebURL(for: url) {
      return OfficialPlatformLink(platform: .tencent, url: embedded)
    }
    return nil
  }

  /// Converts official mobile-app links into HTTPS pages that can stay inside
  /// the same embedded WebKit session.
  public func embeddedWebURL(for url: URL) -> URL? {
    guard self == .tencent,
      url.scheme?.lowercased() == "txvideo",
      let host = url.host?.lowercased(),
      host == "v.qq.com" || host.hasSuffix(".v.qq.com"),
      let components = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false
      )
    else { return nil }

    let query = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
        item in item.value.map { (item.name, $0) }
      }
    )
    if let rawURL = query["url"],
      let embedded = URL(string: rawURL),
      owns(embedded)
    {
      return embedded
    }

    let cid = query["cid"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let vid = query["vid"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let cid, !cid.isEmpty {
      if let vid, !vid.isEmpty {
        return URL(
          string: "https://v.qq.com/x/cover/\(cid)/\(vid).html"
        )
      }
      return URL(string: "https://v.qq.com/x/cover/\(cid).html")
    }
    return nil
  }

  private func pathSearchURL(base: String, query: String) -> URL? {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#%")
    guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
      return nil
    }
    return URL(string: base + encoded)
  }
}

public struct OfficialPlatformLink: Equatable, Sendable {
  public let platform: OfficialVideoPlatform
  public let url: URL

  public init(platform: OfficialVideoPlatform, url: URL) {
    self.platform = platform
    self.url = url
  }
}

public enum VideoPlatformDiscovery {
  public static func searchURL(for query: String) -> URL? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }

    var components = URLComponents(string: "https://www.baidu.com/s")
    components?.queryItems = [URLQueryItem(name: "wd", value: trimmed)]
    return components?.url
  }

  public static func ownsSearchEngine(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host?.lowercased()
    else { return false }
    return host == "baidu.com" || host.hasSuffix(".baidu.com")
  }
}

public enum WebAddressResolver {
  public static func resolve(_ input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 2_048 else { return nil }

    if let official = OfficialVideoPlatform.linkTarget(from: trimmed) {
      return official.url
    }

    if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
      guard scheme == "http" || scheme == "https" else { return nil }
      return url
    }

    if !trimmed.contains(where: \.isWhitespace),
      let url = URL(string: "https://\(trimmed)"),
      let host = url.host,
      host.contains("."),
      host.split(separator: ".").last.map({
        $0.count >= 2 && $0.allSatisfy(\.isLetter)
      }) == true
    {
      return url
    }

    return VideoPlatformDiscovery.searchURL(for: trimmed)
  }
}
