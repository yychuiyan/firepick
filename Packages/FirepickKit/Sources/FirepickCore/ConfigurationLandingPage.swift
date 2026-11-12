import Foundation

public enum ConfigurationLandingPage {
  public static func candidateURLs(from data: Data, baseURL: URL) -> [URL] {
    let html = String(decoding: data, as: UTF8.self)
    let attributePatterns = [
      #"(?:data-clipboard-text|href)\s*=\s*"([^"]+)""#,
      #"(?:data-clipboard-text|href)\s*=\s*'([^']+)'"#,
    ]

    var candidates: [String] = []
    for pattern in attributePatterns {
      guard
        let expression = try? NSRegularExpression(
          pattern: pattern,
          options: [.caseInsensitive]
        )
      else {
        continue
      }
      let range = NSRange(html.startIndex..<html.endIndex, in: html)
      for match in expression.matches(in: html, range: range) {
        guard match.numberOfRanges > 1,
          let valueRange = Range(match.range(at: 1), in: html)
        else {
          continue
        }
        candidates.append(decodeHTMLEntities(String(html[valueRange])))
      }
    }

    return candidateURLs(from: candidates, baseURL: baseURL)
  }

  public static func candidateURLs(from values: [String], baseURL: URL) -> [URL] {
    var seen = Set<String>()
    return values.compactMap { value in
      guard value.hasPrefix("http://") || value.hasPrefix("https://"),
        let url = URL(string: value, relativeTo: baseURL)?.absoluteURL
      else {
        return nil
      }
      let host = url.host?.lowercased() ?? ""
      let path = url.path.lowercased()
      let query = url.query?.lowercased() ?? ""
      guard
        host.contains("tvbox")
          || path.contains("json")
          || path.contains(".txt")
          || path.contains(".m3u")
          || path.contains("tvbox")
          || path.contains("config")
          || path.contains(".jpg")
          || path.contains(".jpeg")
          || path.contains(".bmp")
          || path.contains(".png")
          || path.hasSuffix("/tv")
          || query.contains("config")
      else {
        return nil
      }
      guard seen.insert(url.absoluteString).inserted else { return nil }
      return url
    }
    .prefix(12)
    .map { $0 }
  }

  private static func decodeHTMLEntities(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&#38;", with: "&")
      .replacingOccurrences(of: "&quot;", with: "\"")
  }
}
