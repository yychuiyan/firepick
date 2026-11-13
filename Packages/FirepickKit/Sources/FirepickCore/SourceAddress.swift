import Foundation

public enum SourceAddress {
  public static func displayURL(_ value: String) -> String {
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
  }
}
