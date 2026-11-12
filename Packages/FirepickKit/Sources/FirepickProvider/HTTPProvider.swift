import Foundation
import FirepickCore

public actor HTTPProvider: SourceProvider {
    public nonisolated let site: SiteConfiguration

    private let session: URLSession
    private let baseURL: URL
    private let configurationHeaders: [String: String]

    public init(
        site: SiteConfiguration,
        session: URLSession = .shared,
        configurationHeaders: [String: String] = [:]
    ) throws {
        guard let baseURL = URL(string: site.api), baseURL.scheme != nil else {
            throw FirepickError.invalidConfiguration("站点 \(site.name) 的 api 不是有效 URL")
        }
        self.site = site
        self.session = session
        self.baseURL = baseURL
        self.configurationHeaders = configurationHeaders
    }

    public func homeContent() async throws -> MediaResult {
        switch site.effectiveType {
        case 4:
            return try await request(params: ["filter": "true"], decodeAs: .json)
        case 0:
            return try await request(params: [:], decodeAs: .xml)
        default:
            return try await request(params: [:], decodeAs: .json)
        }
    }

    public func categoryContent(
        typeId: String,
        page: Int,
        filter: Bool,
        extend: [String: String]
    ) async throws -> MediaResult {
        var params = [
            "ac": site.effectiveType == 0 ? "videolist" : "detail",
            "t": typeId,
            "pg": String(page),
        ]

        if !extend.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: extend, options: [.sortedKeys])
            let json = String(decoding: data, as: UTF8.self)
            if site.effectiveType == 4 {
                params["ext"] = Self.base64URL(json)
            } else {
                params["f"] = json
            }
        }

        return try await request(
            params: params,
            decodeAs: site.effectiveType == 0 ? .xml : .json
        )
    }

    public func searchContent(keyword: String, quick: Bool, page: Int) async throws -> MediaResult {
        var params = [
            "wd": keyword,
            "quick": String(quick),
            "extend": "",
        ]
        if page > 1 {
            params["pg"] = String(page)
        }
        return try await request(
            params: params,
            decodeAs: site.effectiveType == 0 ? .xml : .json
        )
    }

    public func detailContent(id: String) async throws -> MediaResult {
        try await request(
            params: [
                "ac": site.effectiveType == 0 ? "videolist" : "detail",
                "ids": id,
            ],
            decodeAs: site.effectiveType == 0 ? .xml : .json
        )
    }

    public func playerContent(flag: String, id: String, vipFlags: [String]) async throws -> MediaResult {
        if site.effectiveType == 3 || site.effectiveType == 4 {
            return try await request(params: ["play": id, "flag": flag], decodeAs: .json)
        }

        var result = MediaResult(url: .string(id), header: site.headerDictionary)
        result.flag = flag
        result.key = site.key
        result.playUrl = site.playUrl
        result.parse = Self.looksLikePlayableMedia(id) && (site.playUrl ?? "").isEmpty ? 0 : 1
        return result
    }

    public func action(_ action: String) async throws -> MediaResult {
        guard site.effectiveType == 4, let url = URL(string: action) else {
            return MediaResult()
        }
        let (data, response) = try await session.data(for: makeRequest(url: url, params: [:]))
        try validate(response)
        return try JSONDecoder().decode(MediaResult.self, from: data)
    }

    private enum DecodeMode {
        case json
        case xml
    }

    private func request(params: [String: String], decodeAs mode: DecodeMode) async throws -> MediaResult {
        let url = appending(params: params, to: baseURL)
        let (data, response) = try await session.data(for: makeRequest(url: url, params: [:]))
        try validate(response)
        do {
            switch mode {
            case .json:
                return try JSONDecoder().decode(MediaResult.self, from: data)
            case .xml:
                return try XMLMediaDecoder.decode(data)
            }
        } catch let error as FirepickError {
            throw error
        } catch {
            throw FirepickError.provider("\(site.name): \(error.localizedDescription)")
        }
    }

    private func makeRequest(url: URL, params: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(site.timeout ?? 15)
        var headers = configurationHeaders
        site.headerDictionary.forEach { headers[$0.key] = $0.value }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return request
    }

    private func appending(params: [String: String], to base: URL) -> URL {
        guard !params.isEmpty,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        let existing = components.queryItems ?? []
        components.queryItems = existing + params
            .sorted(by: { $0.key < $1.key })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url ?? base
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw FirepickError.network("无效响应")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw FirepickError.network("HTTP \(response.statusCode)")
        }
    }

    private static func looksLikePlayableMedia(_ value: String) -> Bool {
        let lower = value.lowercased()
        return [".m3u8", ".mp4", ".mkv", ".flv", ".ts", ".webm"].contains { lower.contains($0) }
    }

    static func base64URL(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

