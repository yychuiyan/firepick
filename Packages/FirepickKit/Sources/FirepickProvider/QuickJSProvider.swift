import Foundation
import FirepickCore

public protocol QuickJSHost: Sendable {
    func invoke(
        api: String,
        ext: JSONValue?,
        method: ProviderMethod,
        arguments: [JSONValue]
    ) async throws -> MediaResult
}

public actor QuickJSProvider: SourceProvider {
    public nonisolated let site: SiteConfiguration
    private let host: any QuickJSHost

    public init(site: SiteConfiguration, host: any QuickJSHost) {
        self.site = site
        self.host = host
    }

    public func homeContent() async throws -> MediaResult {
        try await host.invoke(api: site.api, ext: site.ext, method: .homeContent, arguments: [])
    }

    public func homeVideoContent() async throws -> MediaResult {
        try await host.invoke(api: site.api, ext: site.ext, method: .homeVideoContent, arguments: [])
    }

    public func categoryContent(
        typeId: String,
        page: Int,
        filter: Bool,
        extend: [String: String]
    ) async throws -> MediaResult {
        let extValue = JSONValue.object(extend.mapValues(JSONValue.string))
        return try await host.invoke(
            api: site.api,
            ext: site.ext,
            method: .categoryContent,
            arguments: [.string(typeId), .string(String(page)), .bool(filter), extValue]
        )
    }

    public func searchContent(keyword: String, quick: Bool, page: Int) async throws -> MediaResult {
        try await host.invoke(
            api: site.api,
            ext: site.ext,
            method: .searchContent,
            arguments: [.string(keyword), .bool(quick), .string(String(page))]
        )
    }

    public func detailContent(id: String) async throws -> MediaResult {
        try await host.invoke(
            api: site.api,
            ext: site.ext,
            method: .detailContent,
            arguments: [.array([.string(id)])]
        )
    }

    public func playerContent(flag: String, id: String, vipFlags: [String]) async throws -> MediaResult {
        try await host.invoke(
            api: site.api,
            ext: site.ext,
            method: .playerContent,
            arguments: [.string(flag), .string(id), .array(vipFlags.map(JSONValue.string))]
        )
    }
}

