import Foundation
import Testing
@testable import FirepickCore
@testable import FirepickProvider

struct ProviderTests {
    @Test
    func parsesPlaybackLines() {
        let lines = EpisodeParser.lines(
            playFrom: "线路一$$$线路二",
            playURL: "第1集$https://example.com/1.m3u8#第2集$https://example.com/2.m3u8$$$预告$https://example.com/trailer.mp4"
        )
        #expect(lines.count == 2)
        #expect(lines[0].episodes.count == 2)
        #expect(lines[0].episodes[0].name == "第1集")
        #expect(lines[1].episodes[0].value == "https://example.com/trailer.mp4")
    }

    @Test
    func decodesHTTPJSONResult() async throws {
        let session = URLSession(configuration: .ephemeral)
        let provider = try HTTPProvider(
            site: .init(key: "test", name: "Test", type: 1, api: "https://example.com/api"),
            session: session
        )
        let result = MediaResult(
            list: [
                .init(
                    vodId: "1",
                    name: "示例",
                    typeName: nil,
                    pic: nil,
                    remarks: nil,
                    year: nil,
                    area: nil,
                    director: nil,
                    actor: nil,
                    content: nil,
                    playFrom: nil,
                    playURL: nil,
                    playId: nil,
                    tag: nil,
                    action: nil,
                    style: nil,
                    land: nil,
                    circle: nil,
                    ratio: nil
                )
            ]
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(MediaResult.self, from: data)
        #expect(decoded.list.first?.name == "示例")
        _ = provider
    }

    @Test
    func decodesNumericAppleCMSIdentifiers() throws {
        let data = Data(
            #"{"code":1,"pagecount":"42","class":[{"type_id":1,"type_name":"电影"}],"list":[{"vod_id":80314,"vod_name":"示例","type_id":21,"vod_note":null}]}"#.utf8
        )

        let result = try JSONDecoder().decode(MediaResult.self, from: data)

        #expect(result.list.first?.vodId == "80314")
        #expect(result.list.first?.name == "示例")
        #expect(result.classes.first?.typeId == "1")
        #expect(result.pagecount == 42)
    }

    @Test
    func externalRuntimeCanHandleQuickJSSources() async throws {
        let site = SiteConfiguration(
            key: "js",
            name: "QuickJS",
            type: 3,
            api: "https://example.com/spider.js"
        )
        let coordinator = ProviderCoordinator(
            preferBridgeForQuickJS: true,
            bridgeFactory: { site in
                StubProvider(site: site)
            }
        )

        let provider = try await coordinator.provider(for: site)
        let result = try await provider.homeContent()

        #expect(result.list.first?.name == "external")
    }

    @Test
    func searchClosesExternalProviderSessions() async {
        let counter = CloseCounter()
        let coordinator = ProviderCoordinator(
            preferBridgeForQuickJS: true,
            bridgeFactory: { site in
                ClosingProvider(site: site, counter: counter)
            }
        )
        let sites = [
            SiteConfiguration(key: "one", name: "One", type: 3, api: "https://example.com/one.js"),
            SiteConfiguration(key: "two", name: "Two", type: 3, api: "https://example.com/two.js"),
        ]

        _ = await coordinator.search(sites: sites, keyword: "test")

        #expect(await counter.value == 2)
    }
}

private struct StubProvider: SourceProvider {
    let site: SiteConfiguration

    func homeContent() async throws -> MediaResult {
        MediaResult(list: [.init(vodId: "1", name: "external")])
    }

    func categoryContent(
        typeId: String,
        page: Int,
        filter: Bool,
        extend: [String: String]
    ) async throws -> MediaResult {
        MediaResult()
    }

    func searchContent(keyword: String, quick: Bool, page: Int) async throws -> MediaResult {
        MediaResult()
    }

    func detailContent(id: String) async throws -> MediaResult {
        MediaResult()
    }

    func playerContent(flag: String, id: String, vipFlags: [String]) async throws -> MediaResult {
        MediaResult()
    }
}

private actor ClosingProvider: SourceProvider, SessionClosingProvider {
    nonisolated let site: SiteConfiguration
    private let counter: CloseCounter

    init(site: SiteConfiguration, counter: CloseCounter) {
        self.site = site
        self.counter = counter
    }

    func homeContent() async throws -> MediaResult {
        MediaResult()
    }

    func categoryContent(
        typeId: String,
        page: Int,
        filter: Bool,
        extend: [String: String]
    ) async throws -> MediaResult {
        MediaResult()
    }

    func searchContent(keyword: String, quick: Bool, page: Int) async throws -> MediaResult {
        MediaResult()
    }

    func detailContent(id: String) async throws -> MediaResult {
        MediaResult()
    }

    func playerContent(flag: String, id: String, vipFlags: [String]) async throws -> MediaResult {
        MediaResult()
    }

    func closeSession() async {
        await counter.increment()
    }
}

private actor CloseCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

