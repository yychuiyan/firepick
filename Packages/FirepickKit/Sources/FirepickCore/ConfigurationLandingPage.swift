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
    return values.flatMap { value in
      expandedMirrorValues(value).compactMap { expandedValue in
        guard
          let url = URL(string: expandedValue, relativeTo: baseURL)?.absoluteURL,
          isCandidate(url),
          seen.insert(url.absoluteString).inserted
        else {
          return nil
        }
        return url
      }
    }
    .prefix(24)
    .map { $0 }
  }

  private static func expandedMirrorValues(_ value: String) -> [String] {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let rawURL: String
    if let range = trimmed.range(of: "https://raw.githubusercontent.com/") {
      rawURL = String(trimmed[range.lowerBound...])
    } else {
      rawURL = trimmed
    }

    var values: [String] = []
    if rawURL.hasPrefix("https://raw.githubusercontent.com/") {
      values.append(rawURL)
      if let mirror = jsDelivrMirror(for: rawURL) {
        values.append(mirror)
      }
    }
    if rawURL != trimmed || values.isEmpty {
      values.append(trimmed)
    }
    return values
  }

  private static func jsDelivrMirror(for rawURL: String) -> String? {
    guard let url = URL(string: rawURL),
      url.host?.lowercased() == "raw.githubusercontent.com"
    else {
      return nil
    }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count >= 4 else { return nil }

    let branchIndex: Int
    if parts.count >= 6, parts[2] == "refs", parts[3] == "heads" {
      branchIndex = 4
    } else {
      branchIndex = 2
    }
    guard branchIndex + 1 < parts.count else { return nil }

    let owner = parts[0]
    let repository = parts[1]
    let branch = parts[branchIndex]
    let filePath = parts[(branchIndex + 1)...].joined(separator: "/")
    var components = URLComponents()
    components.scheme = "https"
    components.host = "cdn.jsdelivr.net"
    components.path = "/gh/\(owner)/\(repository)@\(branch)/\(filePath)"
    components.query = url.query
    return components.url?.absoluteString
  }

  private static func isCandidate(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    let path = url.path.lowercased()
    let query = url.query?.lowercased() ?? ""
    return host.contains("tvbox")
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
  }

  private static func decodeHTMLEntities(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&#38;", with: "&")
      .replacingOccurrences(of: "&quot;", with: "\"")
  }
}
