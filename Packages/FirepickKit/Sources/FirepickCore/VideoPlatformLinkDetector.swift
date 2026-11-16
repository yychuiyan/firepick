import Foundation

public struct DetectedPlatformPage: Equatable, Identifiable, Sendable {
  public let platform: OfficialVideoPlatform
  public let url: URL

  public var id: String {
    "\(platform.rawValue)|\(url.absoluteString)"
  }

  public init(platform: OfficialVideoPlatform, url: URL) {
    self.platform = platform
    self.url = url
  }
}

public enum VideoPlatformDetectionError: LocalizedError, Equatable {
  case invalidTitle
  case requestFailed
  case noResults

  public var errorDescription: String? {
    switch self {
    case .invalidTitle:
      "请输入 1 到 80 个字符的片名"
    case .requestFailed:
      "片名识别失败，请稍后重试"
    case .noResults:
      "没有识别到可用的官方视频页面"
    }
  }
}

public enum VideoPlatformLinkDetector {
  public static let platformPriority: [OfficialVideoPlatform] = [
    .iqiyi,
    .tencent,
    .youku,
    .mgtv,
    .bilibili,
  ]

  private static let trackingParameters: Set<String> = [
    "ptag", "mreferrer", "spm", "from", "source",
  ]

  public static func search(
    title: String,
    session: URLSession = .shared
  ) async throws -> [DetectedPlatformPage] {
    guard let searchURL = VideoPlatformDiscovery.searchURL(for: title) else {
      throw VideoPlatformDetectionError.invalidTitle
    }

    var request = URLRequest(
      url: searchURL,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: 20
    )
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
      forHTTPHeaderField: "User-Agent"
    )
    request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
    request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw VideoPlatformDetectionError.requestFailed
    }

    guard let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode),
      data.count <= 12 * 1_024 * 1_024
    else {
      throw VideoPlatformDetectionError.requestFailed
    }

    let pages = extract(from: String(decoding: data, as: UTF8.self))
    guard !pages.isEmpty else {
      throw VideoPlatformDetectionError.noResults
    }
    return pages
  }

  public static func extract(from rawHTML: String) -> [DetectedPlatformPage] {
    let html = normalize(rawHTML)
    guard let regex = try? NSRegularExpression(
      pattern: #"https?://[^"'<>\\\s]+"#,
      options: [.caseInsensitive]
    ) else { return [] }

    let range = NSRange(html.startIndex..<html.endIndex, in: html)
    var pages: [DetectedPlatformPage] = []
    var seenPlatforms = Set<OfficialVideoPlatform>()

    for match in regex.matches(in: html, range: range) {
      guard let valueRange = Range(match.range, in: html) else { continue }
      let value = trimDelimiters(String(html[valueRange]))
      guard let target = OfficialVideoPlatform.linkTarget(from: value),
        let normalized = normalizedOfficialURL(target.url),
        normalized.path != "/",
        seenPlatforms.insert(target.platform).inserted
      else { continue }

      pages.append(
        DetectedPlatformPage(platform: target.platform, url: normalized)
      )
    }

    let order = Dictionary(
      uniqueKeysWithValues: platformPriority.enumerated().map {
        ($1, $0)
      }
    )
    return pages.sorted {
      (order[$0.platform] ?? .max) < (order[$1.platform] ?? .max)
    }
  }

  private static func normalize(_ html: String) -> String {
    html
      .replacingOccurrences(of: #"\/"#, with: "/")
      .replacingOccurrences(of: #"\u002F"#, with: "/", options: .caseInsensitive)
      .replacingOccurrences(of: #"\u003A"#, with: ":", options: .caseInsensitive)
      .replacingOccurrences(of: #"\u0026"#, with: "&", options: .caseInsensitive)
      .replacingOccurrences(of: "&amp;", with: "&")
  }

  private static func trimDelimiters(_ value: String) -> String {
    var result = value
    while let last = result.last,
      [",", ".", ";", ")", "]", "}"].contains(last)
    {
      result.removeLast()
    }
    return result
  }

  private static func normalizedOfficialURL(_ url: URL) -> URL? {
    guard var components = URLComponents(
      url: url,
      resolvingAgainstBaseURL: false
    ) else { return nil }
    components.scheme = "https"
    components.fragment = nil
    components.queryItems = components.queryItems?.filter {
      let name = $0.name.lowercased()
      return !trackingParameters.contains(name)
        && !name.hasPrefix("utm_")
        && !name.hasPrefix("spm")
    }
    if components.queryItems?.isEmpty == true {
      components.queryItems = nil
    }
    return components.url
  }
}
