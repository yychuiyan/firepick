import Foundation
import FirepickCore

public protocol SourceProvider: Sendable {
    var site: SiteConfiguration { get }

    func homeContent() async throws -> MediaResult
    func categoryContent(typeId: String, page: Int, filter: Bool, extend: [String: String]) async throws -> MediaResult
    func searchContent(keyword: String, quick: Bool, page: Int) async throws -> MediaResult
    func detailContent(id: String) async throws -> MediaResult
    func playerContent(flag: String, id: String, vipFlags: [String]) async throws -> MediaResult
}

public protocol SessionClosingProvider: Sendable {
    func closeSession() async
}

public extension SourceProvider {
    func homeVideoContent() async throws -> MediaResult {
        MediaResult()
    }

    func liveContent(url: String) async throws -> MediaResult {
        throw FirepickError.unsupported("当前 Provider 不支持直播")
    }

    func action(_ action: String) async throws -> MediaResult {
        MediaResult()
    }
}

