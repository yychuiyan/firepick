import Foundation

public enum SourceAddress {
  public static func displayURL(_ value: String) -> String {
    let decoded: String = {
      guard let encodedHost = URL(string: value)?.host,
        let displayHost = URLComponents(string: value)?.host,
        encodedHost != displayHost,
        let range = value.range(of: encodedHost)
      else {
        return value
      }
      var result = value
      result.replaceSubrange(range, with: displayHost)
      return result
    }()
    return strippingCacheBuster(decoded)
  }

  /// `?v=N` is only a CDN/cache buster for warehouse JSON — hide it in UI.
  public static func strippingCacheBuster(_ value: String) -> String {
    guard var components = URLComponents(string: value),
      let items = components.queryItems,
      items.contains(where: { $0.name == "v" })
    else {
      return value
    }
    let kept = items.filter { $0.name != "v" }
    components.queryItems = kept.isEmpty ? nil : kept
    return components.string ?? value
  }
}
