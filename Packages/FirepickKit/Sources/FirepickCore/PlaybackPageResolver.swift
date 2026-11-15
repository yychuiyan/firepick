import Foundation

/// Resolve the HLS URL embedded in CatVod web-player pages before handing the
/// URL to AVPlayer. Several sources expose an HTML viewer link as their first
/// playback line and omit the equivalent m3u8 line from compact API variants.
public enum PlaybackPageResolver {
    public static func isDirectMediaURL(_ url: URL) -> Bool {
        let text = url.absoluteString.lowercased()
        if text.contains(".m3u8") || text.contains(".mp4") || text.contains(".m4v")
            || text.contains(".mov") || text.contains(".mkv")
        {
            return true
        }
        return false
    }

    public static func resolve(
        url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = 4,
        session: URLSession = .shared
    ) async -> URL? {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                return nil
            }
            let mime = (http.mimeType ?? "").lowercased()
            if mime.contains("mpegurl") {
                return response.url ?? url
            }
            guard let text = String(data: data.prefix(2 * 1024 * 1024), encoding: .utf8)
                ?? String(
                    data: data.prefix(2 * 1024 * 1024),
                    encoding: .isoLatin1
                )
            else {
                return nil
            }
            return extractM3U8URL(
                from: text,
                baseURL: response.url ?? url
            )
        } catch {
            return nil
        }
    }

    public static func extractM3U8URL(
        from body: String,
        baseURL: URL
    ) -> URL? {
        let normalized = body
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
        let pattern =
            #"(?i)(?:https?:)?//[^"'<>\\\s]+?\.m3u8[^"'<>\\\s]*|/[^"'<>\\\s]+?\.m3u8[^"'<>\\\s]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let matches = regex.matches(in: normalized, range: range)
        var candidates: [URL] = []
        for match in matches {
            guard let valueRange = Range(match.range, in: normalized) else { continue }
            let value = String(normalized[valueRange])
            guard let candidate = URL(string: value, relativeTo: baseURL)?.absoluteURL,
                let scheme = candidate.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                !candidates.contains(candidate)
            else { continue }
            candidates.append(candidate)
        }
        return candidates.first(where: { $0.host == baseURL.host }) ?? candidates.first
    }
}
