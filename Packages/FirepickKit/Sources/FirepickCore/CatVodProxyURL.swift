import Foundation

public enum CatVodProxyURL {
    public static func isProxy(_ value: String) -> Bool {
        value.range(of: "proxy://", options: [.anchored, .caseInsensitive]) != nil
    }

    public static func query(from value: String) -> [URLQueryItem] {
        guard isProxy(value) else { return [] }
        var suffix = String(value.dropFirst("proxy://".count))
        if suffix.hasPrefix("?") {
            suffix.removeFirst()
        }
        guard var components = URLComponents(string: "https://firepick.invalid/") else {
            return []
        }
        components.percentEncodedQuery = suffix
        return components.queryItems ?? []
    }

    public static func bridgeURL(
        _ value: String,
        baseURL: URL,
        sessionId: String,
        siteKey: String
    ) -> URL? {
        guard isProxy(value),
              var components = URLComponents(
                url: baseURL
                    .appendingPathComponent("v1")
                    .appendingPathComponent("sessions")
                    .appendingPathComponent(sessionId)
                    .appendingPathComponent("proxy"),
                resolvingAgainstBaseURL: false
              ) else {
            return nil
        }
        var items = query(from: value)
        if !items.contains(where: { $0.name == "siteKey" }) {
            items.append(URLQueryItem(name: "siteKey", value: siteKey))
        }
        components.queryItems = items
        return components.url
    }
}
