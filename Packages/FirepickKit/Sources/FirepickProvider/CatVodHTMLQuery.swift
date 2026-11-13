import Foundation
import SwiftSoup

/// Hikerview-style DOM helpers used by CatVod JS (`pdfh` / `pd` / `pdfa` / `pdfl`).
enum CatVodHTMLQuery {
  static func pdfh(_ html: String, rule: String) -> String {
    pd(html, rule: rule, urlKey: "")
  }

  static func pd(_ html: String, rule: String, urlKey: String) -> String {
    do {
      let doc = try SwiftSoup.parse(html)
      return try parseDomForURL(doc: doc, html: html, rule: rule, addURL: urlKey)
    } catch {
      return ""
    }
  }

  static func pdfa(_ html: String, rule: String) -> [String] {
    do {
      let doc = try SwiftSoup.parse(html)
      return try parseDomForArray(doc: doc, rule: rule)
    } catch {
      return []
    }
  }

  static func pdfl(
    _ html: String,
    rule: String,
    texts: String,
    urls: String,
    urlKey: String
  ) -> [[String: String]] {
    let nodes = pdfa(html, rule: rule)
    var rows: [[String: String]] = []
    for node in nodes {
      let text = pdfh(node, rule: texts)
      var url = pd(node, rule: urls, urlKey: urlKey)
      if !urlKey.isEmpty, !url.isEmpty, !url.contains("://") {
        url = joinURL(urlKey, url)
      }
      rows.append(["text": text, "url": url])
    }
    return rows
  }

  static func joinURL(_ base: String, _ relative: String) -> String {
    if relative.hasPrefix("//") {
      let scheme = URL(string: base)?.scheme ?? "https"
      return "\(scheme):\(relative)"
    }
    if relative.hasPrefix("http://") || relative.hasPrefix("https://")
      || relative.hasPrefix("ftp:") || relative.hasPrefix("magnet:")
      || relative.hasPrefix("thunder:")
    {
      return relative
    }
    guard let baseURL = URL(string: base) else { return relative }
    return URL(string: relative, relativeTo: baseURL)?.absoluteString ?? relative
  }

  private static func parseDomForURL(
    doc: Document,
    html: String,
    rule: String,
    addURL: String
  ) throws -> String {
    if rule == "body&&Text" || rule == "Text" {
      return try doc.text()
    }
    if rule == "body&&Html" || rule == "Html" {
      return try doc.html()
    }

    var option = ""
    var workRule = rule
    if rule.contains("&&") {
      let parts = rule.components(separatedBy: "&&")
      option = parts.last ?? ""
      workRule = parts.dropLast().joined(separator: "&&")
    }
    workRule = toCSS(workRule, firstOnly: true)
    let elements = try select(doc, css: workRule)
    guard let first = elements.first(where: { _ in true }) else { return "" }
    if option.isEmpty {
      return try first.outerHtml()
    }
    if option == "Text" {
      return try first.text()
    }
    if option == "Html" {
      return try first.html()
    }
    for key in option.components(separatedBy: "||") {
      var value = try first.attr(key)
      if key.lowercased().contains("style"), value.contains("url(") {
        if let match = value.range(of: #"url\((.*?)\)"#, options: .regularExpression) {
          value = String(value[match])
            .replacingOccurrences(of: "url(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
      }
      if !value.isEmpty {
        if !addURL.isEmpty, shouldJoin(key), !isAbsolute(value) {
          return joinURL(addURL, value)
        }
        return value
      }
    }
    return ""
  }

  private static func parseDomForArray(doc: Document, rule: String) throws -> [String] {
    let css = toCSS(rule, firstOnly: false)
    let elements = try select(doc, css: css)
    return try elements.map { try $0.outerHtml() }
  }

  private static func select(_ doc: Document, css: String) throws -> Elements {
    if css.isEmpty {
      return Elements([doc])
    }
    return try doc.select(css)
  }

  /// Converts a subset of hikerview rules into CSS selectors.
  private static func toCSS(_ rule: String, firstOnly: Bool) -> String {
    let parts =
      rule
      .replacingOccurrences(of: "&&", with: " ")
      .split(separator: " ")
      .map(String.init)
      .filter { !$0.isEmpty }

    var normalizedParts: [String] = []
    for part in parts {
      if let match = part.wholeMatch(of: /:eq\((\d+)\)/) {
        let index = (Int(match.1) ?? 0) + 1
        if normalizedParts.isEmpty {
          normalizedParts.append(":nth-child(\(index))")
        } else {
          normalizedParts[normalizedParts.count - 1] += ":nth-child(\(index))"
        }
        continue
      }
      var value = part
      if let expression = try? NSRegularExpression(pattern: #":eq\((\d+)\)"#) {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = expression.matches(in: value, range: range)
        for match in matches.reversed() {
          guard match.numberOfRanges > 1,
            let whole = Range(match.range, in: value),
            let indexRange = Range(match.range(at: 1), in: value),
            let index = Int(value[indexRange])
          else {
            continue
          }
          value.replaceSubrange(whole, with: ":nth-child(\(index + 1))")
        }
      }
      if value == ":first" { value = ":first-child" }
      if value == ":last" { value = ":last-child" }
      normalizedParts.append(value)
    }

    var css = normalizedParts.joined(separator: " ")
    if firstOnly, !css.isEmpty, !css.contains(":nth"), !css.contains(":first") {
      css += ":first-of-type"
    }
    return css
  }

  private static func shouldJoin(_ key: String) -> Bool {
    let lower = key.lowercased()
    return lower.contains("url") || lower.contains("src") || lower.contains("href")
      || lower.hasPrefix("data-")
  }

  private static func isAbsolute(_ value: String) -> Bool {
    value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("//")
      || value.hasPrefix("ftp:") || value.hasPrefix("magnet:") || value.hasPrefix("thunder:")
      || value.hasPrefix("data:")
  }
}
