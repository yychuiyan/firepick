import Foundation

public struct HLSQualityProfile: Equatable, Sendable {
  public var width: Int
  public var height: Int
  public var bandwidth: Int

  public init(width: Int, height: Int, bandwidth: Int) {
    self.width = width
    self.height = height
    self.bandwidth = bandwidth
  }
}

public enum HLSQualityProbe {
  public static func parseMasterPlaylist(_ text: String) -> HLSQualityProfile? {
    var profiles: [HLSQualityProfile] = []
    for line in text.components(separatedBy: .newlines)
    where line.uppercased().hasPrefix("#EXT-X-STREAM-INF:") {
      let attributes = line
        .drop(while: { $0 != ":" })
        .dropFirst()
        .split(separator: ",")
      var width = 0
      var height = 0
      var bandwidth = 0
      for attribute in attributes {
        let pair = attribute.split(separator: "=", maxSplits: 1)
        guard pair.count == 2 else { continue }
        let key = pair[0].trimmingCharacters(in: .whitespaces).uppercased()
        let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        switch key {
        case "RESOLUTION":
          let dimensions = value.lowercased().split(separator: "x")
          if dimensions.count == 2 {
            width = Int(dimensions[0]) ?? 0
            height = Int(dimensions[1]) ?? 0
          }
        case "BANDWIDTH":
          bandwidth = Int(value) ?? 0
        default:
          break
        }
      }
      if width > 0, height > 0 {
        profiles.append(
          HLSQualityProfile(width: width, height: height, bandwidth: max(0, bandwidth))
        )
      }
    }
    return profiles.max {
      if $0.height != $1.height { return $0.height < $1.height }
      return $0.bandwidth < $1.bandwidth
    }
  }

  public static func probe(
    url: URL,
    headers: [String: String] = [:],
    timeout: TimeInterval = 2.5,
    session: URLSession = .shared
  ) async -> HLSQualityProfile? {
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: timeout
    )
    request.setValue(
      "application/vnd.apple.mpegurl,application/x-mpegURL,text/plain,*/*",
      forHTTPHeaderField: "Accept"
    )
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse,
        (200..<300).contains(http.statusCode),
        let text = String(data: data, encoding: .utf8)
      else {
        return nil
      }
      return parseMasterPlaylist(text)
    } catch {
      return nil
    }
  }
}
