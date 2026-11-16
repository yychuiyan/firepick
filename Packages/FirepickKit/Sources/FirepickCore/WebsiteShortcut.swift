import Foundation

public struct WebsiteShortcut: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var url: URL
  public var isEnabled: Bool

  public init(
    id: UUID = UUID(),
    name: String,
    url: URL,
    isEnabled: Bool = false
  ) {
    self.id = id
    self.name = name
    self.url = url
    self.isEnabled = isEnabled
  }

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case url
    case isEnabled
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    url = try container.decode(URL.self, forKey: .url)
    // Backwards compatible: older stored shortcuts may not have isEnabled.
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
  }

  public static func normalizedURL(from rawAddress: String) -> URL? {
    let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      trimmed.count <= 2_048,
      !trimmed.contains(where: \.isWhitespace)
    else { return nil }

    let candidate = trimmed.contains("://")
      ? trimmed
      : "https://\(trimmed)"
    guard let url = URL(string: candidate),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      url.host != nil
    else { return nil }
    return url
  }

  /// Appends a video page to the configured parser base URL as one encoded
  /// value. Query parameters inside the video URL must not become parameters
  /// of the parser endpoint.
  public func parserURL(for rawSourceAddress: String) -> URL? {
    guard let baseScheme = url.scheme?.lowercased(),
      baseScheme == "http" || baseScheme == "https",
      url.host != nil,
      let source = Self.normalizedURL(from: rawSourceAddress)
    else { return nil }

    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=?#+%")
    guard let encodedSource = source.absoluteString.addingPercentEncoding(
      withAllowedCharacters: allowed
    ) else { return nil }

    guard let result = URL(string: url.absoluteString + encodedSource),
      let resultScheme = result.scheme?.lowercased(),
      resultScheme == "http" || resultScheme == "https",
      result.host != nil
    else { return nil }
    return result
  }
}

public enum WebsiteShortcutDefaults {
  public static let latestVersion = 4

  private struct DefaultShortcut {
    let id: UUID
    let name: String
    let url: URL
    let enabledOnEmpty: Bool
  }

  private static let defaultShortcuts: [DefaultShortcut] = [
    DefaultShortcut(
      id: UUID(uuidString: "2E7E4A50-39A0-41B9-B7E6-976A7D55A210")!,
      name: "七哥解析（可选集）",
      url: URL(string: "https://jx.202617.xyz/tv.php?url=")!,
      enabledOnEmpty: false
    ),
    DefaultShortcut(
      id: UUID(uuidString: "AF69036D-77C2-45B8-A3FF-38C3BE6DA7C2")!,
      name: "M1907（可选集）",
      url: URL(string: "https://im1907.top/?jx=")!,
      enabledOnEmpty: false
    ),
    DefaultShortcut(
      id: UUID(uuidString: "25A8A4EA-2BE7-442F-A0DB-1F140597D221")!,
      name: "789解析",
      url: URL(string: "https://jiexi.789jiexi.com/?url=")!,
      enabledOnEmpty: false
    ),
    DefaultShortcut(
      id: UUID(uuidString: "61FA11C2-0B53-4E5A-8BFD-6A83D93DEAC8")!,
      name: "LX解析",
      url: URL(string: "https://jx.lxyy.club/index.php?url=")!,
      enabledOnEmpty: true
    ),
    DefaultShortcut(
      id: UUID(uuidString: "EE6239BB-2E9A-4E0A-8886-27C777A96F8C")!,
      name: "通用线路（可选集）",
      url: URL(string: "http://player.maqq.cn/?url=")!,
      enabledOnEmpty: false
    ),
    DefaultShortcut(
      id: UUID(uuidString: "12D742BE-8725-431A-949F-B678E835B522")!,
      name: "通用线路",
      url: URL(string: "https://jx.jiexi.icu/?url=")!,
      enabledOnEmpty: false
    ),
  ]

  public static func initialShortcuts() -> [WebsiteShortcut] {
    upgrade(shortcuts: [], fromVersion: 0)
  }

  public static func upgrade(
    shortcuts: [WebsiteShortcut],
    fromVersion: Int
  ) -> [WebsiteShortcut] {
    guard fromVersion < latestVersion else { return shortcuts }

    let wasEmpty = shortcuts.isEmpty
    var remaining = shortcuts
    var result: [WebsiteShortcut] = []
    for definition in defaultShortcuts {
      if let index = remaining.firstIndex(where: { $0.url == definition.url }) {
        var existing = remaining.remove(at: index)
        existing.name = definition.name
        result.append(existing)
      } else {
        result.append(
          WebsiteShortcut(
            id: definition.id,
            name: definition.name,
            url: definition.url,
            isEnabled: wasEmpty && definition.enabledOnEmpty
          )
        )
      }
    }
    result.append(contentsOf: remaining)
    return result
  }
}
