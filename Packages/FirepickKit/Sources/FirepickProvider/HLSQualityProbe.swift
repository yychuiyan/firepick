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

  /// Sample a real media segment before offering a source switch. Catalog
  /// latency and manifest bandwidth do not catch CDNs that return a fast API
  /// response but deliver video at only a few KB/s.
  public static func samplePlaybackKBps(
    url: URL,
    headers: [String: String] = [:],
    timeout: TimeInterval = 5,
    session: URLSession = .shared
  ) async -> Int? {
    if !url.absoluteString.lowercased().contains(".m3u8") {
      return await sampleMediaURL(
        url,
        headers: headers,
        timeout: timeout,
        session: session
      )
    }
    do {
      let masterText = try await playlistText(
        url: url,
        headers: headers,
        timeout: min(timeout, 3),
        session: session
      )
      let mediaURL = bestVariantURL(in: masterText, baseURL: url) ?? url
      let mediaText =
        mediaURL == url
        ? masterText
        : try await playlistText(
          url: mediaURL,
          headers: headers,
          timeout: min(timeout, 3),
          session: session
        )
      guard let segmentURL = firstMediaSegmentURL(in: mediaText, baseURL: mediaURL) else {
        return nil
      }
      return await sampleMediaURL(
        segmentURL,
        headers: headers,
        timeout: timeout,
        session: session
      )
    } catch {
      return nil
    }
  }

  static func bestVariantURL(in text: String, baseURL: URL) -> URL? {
    var pendingScore: (height: Int, bandwidth: Int)?
    var best: (score: (height: Int, bandwidth: Int), url: URL)?
    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.uppercased().hasPrefix("#EXT-X-STREAM-INF:") {
        pendingScore = streamScore(line)
        continue
      }
      guard let score = pendingScore, !line.isEmpty, !line.hasPrefix("#") else { continue }
      pendingScore = nil
      guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
      if let best,
        best.score.height > score.height
          || (best.score.height == score.height && best.score.bandwidth >= score.bandwidth)
      {
        continue
      }
      best = (score, url)
    }
    return best?.url
  }

  static func firstMediaSegmentURL(in text: String, baseURL: URL) -> URL? {
    let segments = text.components(separatedBy: .newlines).compactMap { rawLine -> URL? in
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
      return URL(string: line, relativeTo: baseURL)?.absoluteURL
    }
    guard !segments.isEmpty else { return nil }
    return segments[min(1, segments.count - 1)]
  }

  private static func playlistText(
    url: URL,
    headers: [String: String],
    timeout: TimeInterval,
    session: URLSession
  ) async throws -> String {
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
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode),
      let text = String(data: data, encoding: .utf8)
    else {
      throw URLError(.cannotParseResponse)
    }
    return text
  }

  private static func streamScore(_ line: String) -> (height: Int, bandwidth: Int) {
    var height = 0
    var bandwidth = 0
    let attributes = line.drop(while: { $0 != ":" }).dropFirst().split(separator: ",")
    for attribute in attributes {
      let pair = attribute.split(separator: "=", maxSplits: 1)
      guard pair.count == 2 else { continue }
      let key = pair[0].trimmingCharacters(in: .whitespaces).uppercased()
      let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
      switch key {
      case "RESOLUTION":
        let dimensions = value.lowercased().split(separator: "x")
        if dimensions.count == 2 {
          height = Int(dimensions[1]) ?? 0
        }
      case "BANDWIDTH":
        bandwidth = Int(value) ?? 0
      default:
        break
      }
    }
    return (height, bandwidth)
  }

  private static func sampleMediaURL(
    _ url: URL,
    headers: [String: String],
    timeout: TimeInterval,
    session: URLSession
  ) async -> Int? {
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: timeout
    )
    request.setValue("bytes=0-524287", forHTTPHeaderField: "Range")
    request.setValue("*/*", forHTTPHeaderField: "Accept")
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    do {
      let started = Date()
      let (data, response) = try await session.data(for: request)
      let elapsed = max(0.05, Date().timeIntervalSince(started))
      guard let http = response as? HTTPURLResponse,
        (200..<300).contains(http.statusCode),
        data.count >= 64 * 1024
      else { return nil }
      return max(1, Int((Double(data.count) / 1024 / elapsed).rounded()))
    } catch {
      return nil
    }
  }
}
