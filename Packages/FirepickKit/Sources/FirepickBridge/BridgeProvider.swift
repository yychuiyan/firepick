import Foundation
import FirepickCore
import FirepickProvider

public actor BridgeProvider: SourceProvider, SessionClosingProvider {
    public nonisolated let site: SiteConfiguration
    private let client: BridgeClient
    private let configDigest: String
    private var sessionId: String?

    public init(site: SiteConfiguration, client: BridgeClient, configDigest: String) {
        self.site = site
        self.client = client
        self.configDigest = configDigest
    }

    public func homeContent() async throws -> MediaResult {
        try await invoke(method: .homeContent, arguments: [.bool(false)])
    }

    public func homeVideoContent() async throws -> MediaResult {
        try await invoke(method: .homeVideoContent, arguments: [])
    }

    public func categoryContent(
        typeId: String,
        page: Int,
        filter: Bool,
        extend: [String: String]
    ) async throws -> MediaResult {
        try await invoke(
            method: .categoryContent,
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
            method: .searchContent,
            arguments: [.string(keyword), .bool(quick), .string(String(page))]
        )
    }

    public func detailContent(id: String) async throws -> MediaResult {
        try await invoke(method: .detailContent, arguments: [.array([.string(id)])])
    }

    public func playerContent(flag: String, id: String, vipFlags: [String]) async throws -> MediaResult {
        var result = try await invoke(
            method: .playerContent,
            arguments: [.string(flag), .string(id), .array(vipFlags.map(JSONValue.string))]
        )
        guard let rawURL = result.url?.playbackURL,
              CatVodProxyURL.isProxy(rawURL) else {
            return result
        }
        let session = try await ensureSession()
        let localURL = try await client.localProxyURL(
            sessionId: session,
            rawURL: rawURL,
            siteKey: site.key
        )
        result.url = .string(localURL.absoluteString)
        result.header = [:]
        return result
    }

    public func liveContent(url: String) async throws -> MediaResult {
        try await invoke(method: .liveContent, arguments: [.string(url)])
    }

    public func action(_ action: String) async throws -> MediaResult {
        try await invoke(method: .action, arguments: [.string(action)])
    }

    public func closeSession() async {
        guard let sessionId else { return }
        await client.deleteSession(id: sessionId)
        self.sessionId = nil
    }

    private func invoke(method: ProviderMethod, arguments: [JSONValue]) async throws -> MediaResult {
        let session = try await ensureSession()
        return try await client.invoke(
            sessionId: session,
            request: BridgeInvokeRequest(method: method, arguments: arguments)
        )
    }

    private func ensureSession() async throws -> String {
        if let sessionId {
            return sessionId
        }
        let response = try await client.createSession(
            BridgeSessionRequest(configDigest: configDigest, source: site)
        )
        sessionId = response.sessionId
        return response.sessionId
    }
}

