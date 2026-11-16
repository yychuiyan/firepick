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
