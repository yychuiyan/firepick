import Foundation
import FirepickCore
import FirepickProvider

public actor FongmiServerProvider: SourceProvider, SessionClosingProvider {
    public nonisolated let site: SiteConfiguration
    private let client: FongmiServerClient
    private var loaded = false

    public init(site: SiteConfiguration, client: FongmiServerClient) {
        self.site = site
        self.client = client
    }

    public func homeContent() async throws -> MediaResult {
        try await invoke(.homeContent, arguments: [.bool(false)])
    }

    public func homeVideoContent() async throws -> MediaResult {
        try await invoke(.homeVideoContent, arguments: [])
    }

    public func categoryContent(
        typeId: String,
        page: Int,
        filter: Bool,
        extend: [String: String]
    ) async throws -> MediaResult {
        try await invoke(
            .categoryContent,
            arguments: [
                .string(typeId),
                .string(String(page)),
                .bool(filter),
                .object(extend.mapValues(JSONValue.string)),
            ]
        )
    }

    public func searchContent(keyword: String, quick: Bool, page: Int) async throws -> MediaResult {
        try await invoke(
            .searchContent,
            arguments: [.string(keyword), .bool(quick), .string(String(page))]
        )
    }

    public func detailContent(id: String) async throws -> MediaResult {
        try await invoke(.detailContent, arguments: [.array([.string(id)])])
    }

    public func playerContent(flag: String, id: String, vipFlags: [String]) async throws -> MediaResult {
        var result = try await invoke(
            .playerContent,
            arguments: [.string(flag), .string(id), .array(vipFlags.map(JSONValue.string))]
        )
        if let rawURL = result.url?.playbackURL,
           CatVodProxyURL.isProxy(rawURL),
           let proxyURL = CatVodProxyURL.fongmiURL(
               rawURL,
               baseURL: client.baseURL,
               siteKey: site.key
           ) {
            result.url = .string(proxyURL.absoluteString)
        }
        return result
    }

    public func liveContent(url: String) async throws -> MediaResult {
        try await invoke(.liveContent, arguments: [.string(url)])
    }

    public func action(_ action: String) async throws -> MediaResult {
        try await invoke(.action, arguments: [.string(action)])
    }

    public func closeSession() async {
        await client.close()
        loaded = false
    }

    private func invoke(_ method: ProviderMethod, arguments: [JSONValue]) async throws -> MediaResult {
        if !loaded {
            try await client.load(
                api: site.api,
                ext: site.ext?.stringValue ?? site.ext.map(Self.jsonString) ?? "",
                jar: site.jar ?? ""
            )
            loaded = true
        }
        return try await client.invoke(method: method.rawValue, arguments: arguments)
    }

    private static func jsonString(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

