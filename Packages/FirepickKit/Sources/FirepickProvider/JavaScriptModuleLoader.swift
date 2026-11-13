import FirepickCore
import Foundation

/// Minimal synchronous-style ES module bundler for JavaScriptCore.
///
/// JavaScriptCore executes scripts, not ES modules. CatVod spiders commonly
/// import `catvod`, local `assets://` helpers, and remote helper scripts, so we
/// resolve those imports before evaluation and wrap each dependency with a
/// CommonJS-compatible `module.exports`.
final class JavaScriptModuleLoader: @unchecked Sendable {
  private let session: URLSession
  private let baseURL: URL?
  private var cache: [String: String] = [:]

  init(session: URLSession, baseURL: URL?) {
    self.session = session
    self.baseURL = baseURL
  }

  func prepare(source: String, scriptURL: URL) async throws -> String {
    let imports = try await loadImports(
      source: source,
      scriptURL: scriptURL,
      stack: [scriptURL.absoluteString]
    )
    let withImports = replace(imports: imports, in: source)
    return transformMainExports(withImports)
  }

  private struct ImportReplacement {
    let range: NSRange
    let code: String
  }

  private struct NamedImport {
    let imported: String
    let local: String
  }

  private func loadImports(
    source: String,
    scriptURL: URL,
    stack: [String]
  ) async throws -> [ImportReplacement] {
    let matches = importMatches(in: source)
    var output: [ImportReplacement] = []

    for (index, match) in matches.enumerated() {
      guard let clauseRange = Range(match.clauseRange, in: source),
        let specifierRange = Range(match.specifierRange, in: source)
      else {
        continue
      }
      let clause = String(source[clauseRange])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let specifier = decodeJavaScriptString(
        String(source[specifierRange])
          .trimmingCharacters(in: .whitespacesAndNewlines)
      )

      if specifier == "catvod" {
        output.append(
          ImportReplacement(
            range: match.fullRange,
            code: catVodReplacement(for: clause)
          )
        )
        continue
      }

      guard let moduleURL = resolve(specifier, relativeTo: scriptURL),
        !stack.contains(moduleURL.absoluteString)
      else {
        output.append(
          ImportReplacement(
            range: match.fullRange,
            code: missingModuleReplacement(for: clause, index: index)
          )
        )
        continue
      }

      let moduleSource: String
      do {
        moduleSource = try await loadModule(moduleURL)
      } catch {
        NSLog(
          "Firepick JS module unavailable: %@ (%@)",
          moduleURL.absoluteString,
          error.localizedDescription
        )
        output.append(
          ImportReplacement(
            range: match.fullRange,
            code: missingModuleReplacement(for: clause, index: index)
          )
        )
        continue
      }

      let nested = try await loadImports(
        source: moduleSource,
        scriptURL: moduleURL,
        stack: stack + [moduleURL.absoluteString]
      )
      let moduleWithImports = replace(imports: nested, in: moduleSource)
      let transformed = transformModuleExports(moduleWithImports)
      output.append(
        ImportReplacement(
          range: match.fullRange,
          code: moduleReplacement(
            clause: clause,
            index: index,
            source: transformed,
            url: moduleURL
          )
        )
      )
    }
    return output
  }

  private struct ImportMatch {
    let fullRange: NSRange
    let clauseRange: NSRange
    let specifierRange: NSRange
  }

  private func importMatches(in source: String) -> [ImportMatch] {
    let masked = maskedForImports(source)
    let fullRange = NSRange(location: 0, length: (masked as NSString).length)
    let patterns = [
      #"import\s*([^;"']+?)\s*from\s*["']([^"']+)["']\s*;?"#,
      #"import\s*["']([^"']+)["']\s*;?"#,
    ]
    var seen = Set<String>()
    var output: [ImportMatch] = []
    for (patternIndex, pattern) in patterns.enumerated() {
      guard let expression = try? NSRegularExpression(pattern: pattern) else {
        continue
      }
      for match in expression.matches(in: masked, range: fullRange) {
        guard match.range.location != NSNotFound else { continue }
        let key = "\(match.range.location):\(match.range.length)"
        guard seen.insert(key).inserted else { continue }
        if patternIndex == 0 {
          guard match.numberOfRanges > 2 else { continue }
          output.append(
            ImportMatch(
              fullRange: match.range,
              clauseRange: match.range(at: 1),
              specifierRange: match.range(at: 2)
            )
          )
        } else {
          output.append(
            ImportMatch(
              fullRange: match.range,
              clauseRange: NSRange(location: 0, length: 0),
              specifierRange: match.range(at: 1)
            )
          )
        }
      }
    }
    return output.sorted { $0.fullRange.location < $1.fullRange.location }
  }

  private func maskedForImports(_ source: String) -> String {
    let units = Array(source.utf16)
    var output = units
    var index = 0
    var quote: UInt16?
    var escaped = false
    var lineComment = false
    var blockComment = false

    func blank(_ position: Int) {
      guard position < output.count else { return }
      if output[position] != 10, output[position] != 13 {
        output[position] = 32
      }
    }

    while index < units.count {
      let value = units[index]
      let next = index + 1 < units.count ? units[index + 1] : 0
      if lineComment {
        blank(index)
        if value == 10 || value == 13 { lineComment = false }
        index += 1
        continue
      }
      if blockComment {
        blank(index)
        if value == 42, next == 47 {
          blank(index + 1)
          blockComment = false
          index += 2
          continue
        }
        index += 1
        continue
      }
      if let activeQuote = quote {
        if escaped {
          blank(index)
          escaped = false
        } else if value == 92 {
          blank(index)
          escaped = true
        } else if value == activeQuote {
          quote = nil
        } else {
          blank(index)
        }
        index += 1
        continue
      }
      if value == 47, next == 47 {
        blank(index)
        blank(index + 1)
        lineComment = true
        index += 2
        continue
      }
      if value == 47, next == 42 {
        blank(index)
        blank(index + 1)
        blockComment = true
        index += 2
        continue
      }
      if value == 34 || value == 39 || value == 96 {
        quote = value
        escaped = false
        index += 1
        continue
      }
      index += 1
    }
    return String(decoding: output, as: UTF16.self)
  }

  private func replace(
    imports: [ImportReplacement],
    in source: String
  ) -> String {
    let output = NSMutableString(string: source)
    for replacement in imports.sorted(by: { $0.range.location > $1.range.location }) {
      output.replaceCharacters(in: replacement.range, with: replacement.code)
    }
    return output as String
  }

  private func catVodReplacement(for clause: String) -> String {
    guard !clause.isEmpty else { return "" }
    let bindings = importBindings(clause)
    var lines: [String] = []
    if let name = bindings.defaultName {
      lines.append("var \(name) = requireCatvod();")
    }
    if let name = bindings.namespaceName {
      lines.append("var \(name) = requireCatvod();")
    }
    if !bindings.named.isEmpty {
      lines.append(
        "var {\(bindings.named.map { "\($0.imported): \($0.local)" }.joined(separator: ","))} = requireCatvod();"
      )
    }
    return lines.joined(separator: "\n")
  }

  private func missingModuleReplacement(for clause: String, index: Int) -> String {
    let bindings = importBindings(clause)
    var lines = ["var __firepickModule\(index) = {};"]
    if let name = bindings.defaultName {
      lines.append("var \(name) = undefined;")
    }
    if let name = bindings.namespaceName {
      lines.append("var \(name) = __firepickModule\(index);")
    }
    for item in bindings.named {
      lines.append("var \(item.local) = undefined;")
    }
    return lines.joined(separator: "\n")
  }

  private func moduleReplacement(
    clause: String,
    index: Int,
    source: String,
    url: URL
  ) -> String {
    let moduleName = "__firepickModule\(index)"
    var lines = [
      "var \(moduleName) = (function() {",
      "var module = { exports: {} };",
      "var exports = module.exports;",
      source,
      "return module.exports;",
      "})();",
    ]

    let bindings = importBindings(clause)
    if let name = bindings.defaultName {
      lines.append(
        "var \(name) = \(moduleName) && \(moduleName).default !== undefined ? \(moduleName).default : \(moduleName);"
      )
    }
    if let name = bindings.namespaceName {
      lines.append("var \(name) = \(moduleName);")
    }
    for item in bindings.named {
      lines.append("var \(item.local) = \(moduleName)[\(jsString(item.imported))];")
    }
    if bindings.defaultName == nil,
      bindings.namespaceName == nil,
      bindings.named.isEmpty
    {
      let fallbackName = moduleGlobalName(for: url)
      lines.append(
        "if (typeof globalThis !== 'undefined' && \(moduleName) && typeof \(moduleName) === 'object') {"
      )
      lines.append(
        "try { globalThis[\(jsString(fallbackName))] = \(moduleName).default !== undefined ? \(moduleName).default : \(moduleName); } catch (e) {}"
      )
      lines.append("}")
    }
    return lines.joined(separator: "\n")
  }

  private struct ImportBindings {
    var defaultName: String?
    var namespaceName: String?
    var named: [NamedImport]
  }

  private func importBindings(_ clause: String) -> ImportBindings {
    var result = ImportBindings(defaultName: nil, namespaceName: nil, named: [])
    var remaining = clause.trimmingCharacters(in: .whitespacesAndNewlines)
    if remaining.isEmpty {
      return result
    }
    if let braceStart = remaining.firstIndex(of: "{"),
      let braceEnd = remaining.lastIndex(of: "}"),
      braceStart < braceEnd
    {
      let before = remaining[..<braceStart]
        .trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\r\n"))
      if !before.isEmpty {
        result.defaultName = String(before)
      }
      let named = remaining[remaining.index(after: braceStart)..<braceEnd]
      result.named = named.split(separator: ",").compactMap { value in
        let parts = value.split(separator: " as ", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let imported = parts.first, !imported.isEmpty else { return nil }
        let local = parts.count > 1 ? parts[1] : imported
        return NamedImport(imported: imported, local: local)
      }
      return result
    }
    if remaining.hasPrefix("*") {
      let parts = remaining.split(separator: " ", omittingEmptySubsequences: true)
      if parts.count >= 3, parts[1] == "as" {
        result.namespaceName = String(parts[2])
      }
      return result
    }
    remaining = remaining.trimmingCharacters(
      in: CharacterSet(charactersIn: " ,\t\r\n")
    )
    result.defaultName = remaining.isEmpty ? nil : remaining
    return result
  }

  private func transformModuleExports(_ source: String) -> String {
    let exportList = #"export\s*\{([^}]*)\}\s*;?"#
    let exportDefault = #"export\s+default\s*"#
    let exportedDeclaration =
      #"export\s+(const|let|var|function|class)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#

    var text = source
    if let expression = try? NSRegularExpression(pattern: exportList) {
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      let matches = expression.matches(in: text, range: range)
      for match in matches.reversed() {
        guard match.numberOfRanges > 1,
          let listRange = Range(match.range(at: 1), in: text),
          let wholeRange = Range(match.range, in: text)
        else {
          continue
        }
        let properties = String(text[listRange])
          .split(separator: ",")
          .compactMap { value -> String? in
            let parts = value.split(separator: " as ", maxSplits: 1).map {
              $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let original = parts.first else { return nil }
            let exported = parts.count > 1 ? parts[1] : original
            return "\(jsString(exported)): \(original)"
          }
        text.replaceSubrange(
          wholeRange,
          with: "Object.assign(module.exports, {\(properties.joined(separator: ","))});"
        )
      }
    }

    var declared: [String] = []
    if let expression = try? NSRegularExpression(pattern: exportedDeclaration) {
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      let matches = expression.matches(in: text, range: range)
      for match in matches.reversed() {
        guard match.numberOfRanges > 2,
          let wholeRange = Range(match.range, in: text),
          let kindRange = Range(match.range(at: 1), in: text),
          let nameRange = Range(match.range(at: 2), in: text)
        else {
          continue
        }
        let kind = String(text[kindRange])
        let name = String(text[nameRange])
        declared.append(name)
        text.replaceSubrange(wholeRange, with: "\(kind) \(name)")
      }
    }

    text = text.replacingOccurrences(
      of: exportDefault,
      with: "module.exports.default = ",
      options: .regularExpression
    )
    if !declared.isEmpty {
      text +=
        "\n"
        + declared.map {
          "module.exports[\(jsString($0))] = \($0);"
        }.joined(separator: "\n")
    }
    return text
  }

  private func transformMainExports(_ source: String) -> String {
    var text = source
    let namedDefault = #"export\s+default\s+class\s+(?!extends\b)([A-Za-z_$][A-Za-z0-9_$]*)"#
    var defaultClassName: String?
    if let expression = try? NSRegularExpression(pattern: namedDefault) {
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      if let match = expression.firstMatch(in: text, range: range),
        match.numberOfRanges > 1,
        let nameRange = Range(match.range(at: 1), in: text)
      {
        defaultClassName = String(text[nameRange])
      }
      text = expression.stringByReplacingMatches(
        in: text,
        range: range,
        withTemplate: "class $1"
      )
    }
    text = text.replacingOccurrences(
      of: #"export\s+default\s+class(?=\s+extends|\s*\{)"#,
      with: "var __firepickExport = class",
      options: .regularExpression
    )
    text = text.replacingOccurrences(
      of: #"export\s+default\s*"#,
      with: "var __firepickExport = ",
      options: .regularExpression
    )
    text = text.replacingOccurrences(
      of: #"export\s+\{[^}]*\}\s*;?"#,
      with: "",
      options: .regularExpression
    )
    if let defaultClassName {
      text += "\nvar __firepickExport = \(defaultClassName);"
    }
    return text
  }

  private func resolve(_ specifier: String, relativeTo scriptURL: URL) -> URL? {
    if specifier.hasPrefix("assets://") {
      if bundledResourceURL(for: specifier) != nil {
        return URL(string: "firepick-asset://\(specifier.dropFirst(9))")
      }
      let path = String(specifier.dropFirst("assets://".count))
      let root =
        baseURL?.deletingLastPathComponent()
        ?? scriptURL.deletingLastPathComponent().deletingLastPathComponent()
      return URL(string: path, relativeTo: root)?.absoluteURL
    }
    guard let url = URL(string: specifier, relativeTo: scriptURL)?.absoluteURL,
      url.scheme == "http" || url.scheme == "https"
    else {
      return nil
    }
    return url
  }

  private func loadModule(_ url: URL) async throws -> String {
    let key = url.absoluteString
    if let cached = cache[key] {
      return cached
    }
    if key.hasPrefix("firepick-asset://") {
      guard
        let resource = bundledResourceURL(
          for: "assets://\(key.dropFirst("firepick-asset://".count))"),
        let source = try? String(contentsOf: resource, encoding: .utf8)
      else {
        throw FirepickError.provider("内置 JS 模块不存在：\(key)")
      }
      cache[key] = source
      return source
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.assumesHTTP3Capable = false
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    request.setValue(
      "\"firepick-module-\(UUID().uuidString)\"",
      forHTTPHeaderField: "If-None-Match"
    )
    request.setValue(
      "Thu, 01 Jan 1970 00:00:00 GMT",
      forHTTPHeaderField: "If-Modified-Since"
    )
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
      forHTTPHeaderField: "User-Agent"
    )
    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse,
      !(200..<300).contains(http.statusCode)
    {
      throw FirepickError.network("JS 模块 HTTP \(http.statusCode)")
    }
    guard let source = String(data: data, encoding: .utf8) else {
      throw FirepickError.provider("JS 模块不是 UTF-8")
    }
    cache[key] = source
    return source
  }

  private func bundledResourceURL(for specifier: String) -> URL? {
    let filename =
      URL(string: specifier)?.lastPathComponent
      ?? (specifier as NSString).lastPathComponent
    let ext = (filename as NSString).pathExtension
    let base = (filename as NSString).deletingPathExtension
    return Bundle.module.url(forResource: base, withExtension: ext)
  }

  private func moduleGlobalName(for url: URL) -> String {
    var name = url.deletingPathExtension().lastPathComponent
    if name.hasSuffix(".min") {
      name.removeLast(".min".count)
    }
    if name == "crypto-js" {
      return "CryptoJS"
    }
    let pieces = name.split(separator: "-")
    if pieces.count > 1 {
      return pieces.enumerated().map { index, piece in
        index == 0
          ? piece.lowercased()
          : piece.prefix(1).uppercased() + piece.dropFirst()
      }.joined()
    }
    return name
  }

  private func jsString(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode(value),
      let text = String(data: data, encoding: .utf8)
    else {
      return "\"\""
    }
    return text
  }

  private func decodeJavaScriptString(_ value: String) -> String {
    var output = value
    let patterns: [(String, (String) -> String)] = [
      (
        #"\\x([0-9A-Fa-f]{2})"#,
        { hex in
          UnicodeScalar(UInt32(hex, radix: 16) ?? 0).map(String.init) ?? ""
        }
      ),
      (
        #"\\u([0-9A-Fa-f]{4})"#,
        { hex in
          UnicodeScalar(UInt32(hex, radix: 16) ?? 0).map(String.init) ?? ""
        }
      ),
    ]
    for (pattern, transform) in patterns {
      guard let expression = try? NSRegularExpression(pattern: pattern) else {
        continue
      }
      let range = NSRange(output.startIndex..<output.endIndex, in: output)
      for match in expression.matches(in: output, range: range).reversed() {
        guard match.numberOfRanges > 1,
          let wholeRange = Range(match.range, in: output),
          let valueRange = Range(match.range(at: 1), in: output)
        else {
          continue
        }
        output.replaceSubrange(
          wholeRange,
          with: transform(String(output[valueRange]))
        )
      }
    }
    return
      output
      .replacingOccurrences(of: #"\/"#, with: "/")
      .replacingOccurrences(of: #"\\"#, with: #"\"#)
      .replacingOccurrences(of: "\\\"", with: "\"")
      .replacingOccurrences(of: "\\'", with: "'")
  }
}
