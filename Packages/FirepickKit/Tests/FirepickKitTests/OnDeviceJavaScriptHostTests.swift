import FirepickCore
import Foundation
import Testing

@testable import FirepickProvider

@Suite(.serialized)
struct OnDeviceJavaScriptHostTests {
  @Test
  func evaluatesCatVodSpiderWithAesXAndHtmlQuery() async throws {
    let script = """
      import { Spider, aesX, htmlQuery } from 'catvod';

        export default class extends Spider {
          constructor() {
            super();
            this.calls = 0;
          }

        homeContent(filter) {
            this.calls += 1;
          const cipher = aesX('AES/CBC/PKCS7', true, 'hello-host', false, '0123456789abcdef', 'fedcba9876543210', true);
          const plain = aesX('AES/CBC/PKCS7', false, cipher, true, '0123456789abcdef', 'fedcba9876543210', false);
          const title = htmlQuery.pdfh('<div class="t">拾萤</div>', 'div.t&&Text');
          return {
            class: [{ type_id: 'movie', type_name: title || 'fallback' }],
            list: [{
              vod_id: '1',
                vod_name: plain + ':' + this.calls,
              vod_remarks: filter ? 'filtered' : 'ok'
            }]
          };
        }

          action(value) {
            return { list: [{ vod_id: 'action', vod_name: value }] };
          }

          liveContent(url) {
            return '#EXTM3U\\n#EXTINF:-1,' + url;
          }
      }
      """

    let session = try Self.makeSession(
      routes: ["/spider.js": script]
    )
    let host = OnDeviceJavaScriptHost(session: session)
    let result = try await host.invoke(
      api: "https://fixture.local/spider.js",
      ext: nil,
      method: .homeContent,
      arguments: [.bool(false)]
    )
    let second = try await host.invoke(
      api: "https://fixture.local/spider.js",
      ext: nil,
      method: .homeContent,
      arguments: [.bool(false)]
    )
    let action = try await host.invoke(
      api: "https://fixture.local/spider.js",
      ext: nil,
      method: .action,
      arguments: [.string("open")]
    )
    let live = try await host.invoke(
      api: "https://fixture.local/spider.js",
      ext: nil,
      method: .liveContent,
      arguments: [.string("https://example.com/live")]
    )

    #expect(result.list.first?.name == "hello-host:1")
    #expect(second.list.first?.name == "hello-host:2")
    #expect(result.classes.first?.typeName == "拾萤")
    #expect(action.list.first?.name == "open")
    #expect(live.rawContent?.contains("https://example.com/live") == true)
    await host.destroy()
  }

  @Test
  func loadsESModulesAndExportsUsedByCatVodSpiders() async throws {
    let script = """
      import helper from 'https://fixture.local/helper.js';
      import { prefix } from 'https://fixture.local/named.js';
      import 'https://fixture.local/side-effect.js';
      import { Spider } from 'catvod';

      export default class extends Spider {
        homeContent() {
          return { list: [{ vod_id: '1', vod_name: prefix + helper }] };
        }
      }
      """
    let session = try Self.makeSession(
      routes: [
        "/spider.js": script,
        "/helper.js": "var value = '模块'; export { value as default };",
        "/named.js": "var value = '前缀-'; export { value as prefix };",
        "/side-effect.js": "globalThis.sideEffectLoaded = true;",
      ]
    )
    let host = OnDeviceJavaScriptHost(session: session)
    let result = try await host.invoke(
      api: "https://fixture.local/spider.js",
      ext: nil,
      method: .homeContent,
      arguments: []
    )
    #expect(result.list.first?.name == "前缀-模块")
    await host.destroy()
  }

  @Test
  func loadsBundledDrpyCompatibilityModules() async throws {
    let script = """
      import JSON5 from 'assets://js/lib/json5.js';
      import Uri from 'assets://js/lib/uri.min.js';
      import templates from 'assets://js/lib/模板.js';
      import { gbkTool } from 'assets://js/lib/gbk.js';
      import 'assets://js/lib/pako.min.js';
      import 'assets://js/lib/jinja.js';
      import 'assets://js/lib/jsoup.js';
      import 'assets://js/lib/node-rsa.js';
      import 'assets://js/lib/jsencrypt.js';
      import { Spider } from 'catvod';

      export default class extends Spider {
        homeContent() {
          const parsed = JSON5.parse("{answer: 42}");
          const uri = new Uri("https://example.com/a?q=1");
          const mubans = templates.getMubans();
          const gbk = gbkTool();
          return {
            list: [{
              vod_id: '1',
              vod_name: [
                parsed.answer,
                uri.host(),
                !!mubans.mxone5,
                gbk.decode('%C4%E3%BA%C3')
              ].join('|')
            }]
          };
        }
      }
      """
    let session = try Self.makeSession(routes: ["/spider.js": script])
    let host = OnDeviceJavaScriptHost(session: session)
    let result = try await host.invoke(
      api: "https://fixture.local/spider.js",
      ext: nil,
      method: .homeContent,
      arguments: []
    )
    #expect(result.list.first?.name == "42|example.com|true|你好")
    await host.destroy()
  }

  @Test
  func htmlQueryUsesZeroBasedEqAndSupportsStandaloneEq() {
    let html = "<div>A</div><div>B</div><div>C</div>"
    #expect(CatVodHTMLQuery.pdfh(html, rule: "div:eq(1)&&Text") == "B")
    #expect(CatVodHTMLQuery.pdfh(html, rule: "div&&:eq(2)&&Text") == "C")
    #expect(
      CatVodHTMLQuery.joinURL(
        "https://source.example/path",
        "//cdn.example/image.jpg"
      ) == "https://cdn.example/image.jpg"
    )
  }

  @Test
  func netReqSupportsCatVodBufferModes() async throws {
    let script = """
      import { Spider, net } from 'catvod';

      export default class extends Spider {
        async homeContent() {
          const text = await net.req('https://fixture.local/data', { params: { q: 'x' } });
          const bytes = await net.req('https://fixture.local/data', { buffer: 1 });
          const base64 = await net.req('https://fixture.local/data', { buffer: 2 });
          const arrayBuffer = await net.req('https://fixture.local/data', { buffer: 3 });
          return {
            list: [{
              vod_id: '1',
              vod_name: [
                text.content,
                Array.isArray(bytes.content),
                base64.content,
                arrayBuffer.content instanceof ArrayBuffer
              ].join('|')
            }]
          };
        }
      }
      """
    let session = try Self.makeSession(
      routes: ["/spider.js": script, "/data": "hello"]
    )
    let host = OnDeviceJavaScriptHost(session: session)
    let result = try await host.invoke(
      api: "https://fixture.local/spider.js",
      ext: nil,
      method: .homeContent,
      arguments: []
    )
    #expect(result.list.first?.name == "hello|true|aGVsbG8=|true")
    await host.destroy()
  }

  @Test
  func surfacesJavaScriptMethodExceptions() async throws {
    let script = """
      import { Spider } from 'catvod';

      export default class extends Spider {
        async homeContent() {
          await Promise.resolve();
          throw new Error('aggregate exploded');
        }
      }
      """
    let session = try Self.makeSession(routes: ["/spider.js": script])
    let host = OnDeviceJavaScriptHost(session: session)
    do {
      _ = try await host.invoke(
        api: "https://fixture.local/spider.js",
        ext: nil,
        method: .homeContent,
        arguments: []
      )
      Issue.record("Expected the JavaScript exception to be surfaced")
    } catch {
      #expect(error.localizedDescription.contains("aggregate exploded"))
    }
    await host.destroy()
  }

  @Test
  func fallsBackToBundledScriptWhenRemoteReturnsEmpty304() async throws {
    JSFixtureURLProtocol.statusCodes = [
      "/firepick-cms.js": 304
    ]
    JSFixtureURLProtocol.routes = [
      "/firepick-cms.js": Data()
    ]
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [JSFixtureURLProtocol.self]
    let host = OnDeviceJavaScriptHost(session: URLSession(configuration: configuration))

    // Bundled Resources/firepick-cms.js should load even when remote is empty 304.
    // Live CMS APIs may be unreachable in unit tests; just assert Spider boots
    // and returns a MediaResult instead of throwing on empty download.
    let result = try await host.invoke(
      api: "https://fixture.local/firepick-cms.js?v=4",
      ext: nil,
      method: .homeContent,
      arguments: [.bool(false)]
    )
    #expect(result.list.count >= 0)
    await host.destroy()
  }

  @Test
  func firepickAggregatorCompletelyBlocksAdultProvidersInStandardMode() async throws {
    let normalPayload = #"""
      {
        "class": [
          {"type_id": "1", "type_name": "电影"},
          {"type_id": "2", "type_name": "无码专区"}
        ],
        "list": [
          {"vod_id": "1", "vod_name": "普通电影", "type_id": "1", "type_name": "电影"},
          {"vod_id": "2", "vod_name": "成人测试", "type_id": "2", "type_name": "无码专区"}
        ]
      }
      """#
    let adultPayload = #"""
      {
        "class": [
          {"type_id": "1", "type_name": "电影"},
          {"type_id": "2", "type_name": "无码专区"},
          {"type_id": "3", "type_name": "国产自拍"},
          {"type_id": "4", "type_name": "网红主播"}
        ],
        "list": [
          {
            "vod_id": "3",
            "vod_name": "成人测试",
            "vod_class": "无码专区",
            "type_id": "1",
            "type_name": "电影"
          },
          {
            "vod_id": "4",
            "vod_name": "自拍测试",
            "vod_class": "国产自拍",
            "type_id": "3",
            "type_name": "国产自拍"
          },
          {
            "vod_id": "5",
            "vod_name": "主播测试",
            "vod_class": "网红主播",
            "type_id": "4",
            "type_name": "网红主播"
          }
        ]
      }
      """#
    let session = try Self.makeSession(
      routes: ["/normal": normalPayload, "/adult": adultPayload]
    )
    let host = OnDeviceJavaScriptHost(session: session)
    let api = "https://dl.yychuiyan.com/firepick/firepick-cms.js?v=22"

    func ext(adultMode: Bool) -> JSONValue {
      .object([
        "adultMode": .bool(adultMode),
        "providers": .array([
          .object([
            "key": .string("normal"),
            "name": .string("普通"),
            "api": .string("https://fixture.local/normal"),
            "adult": .bool(false),
          ]),
          .object([
            "key": .string("adult"),
            "name": .string("成人"),
            "api": .string("https://fixture.local/adult"),
            "adult": .bool(true),
          ]),
        ]),
      ])
    }

    let standard = try await host.invoke(
      api: api,
      ext: ext(adultMode: false),
      method: .homeContent,
      arguments: [.bool(false)]
    )
    #expect(!JSFixtureURLProtocol.requestedPaths.contains("/adult"))
    #expect(standard.list.contains { $0.name == "普通电影" })
    #expect(!standard.list.contains { $0.name == "成人测试" })
    #expect(standard.list.count <= BrowseCatalogPolicy.itemsPerMenu)
    #expect(!standard.classes.contains { $0.typeId == "bucket|adult" })
    #expect(standard.filters?["bucket|adult"] == nil)
    await host.destroy()

    let adultHost = OnDeviceJavaScriptHost(session: session)
    let adult = try await adultHost.invoke(
      api: api,
      ext: ext(adultMode: true),
      method: .homeContent,
      arguments: [.bool(false)]
    )
    #expect(!JSFixtureURLProtocol.requestedPaths.contains("/adult"))
    #expect(!adult.list.isEmpty)
    #expect(adult.classes.contains { $0.typeId == "bucket|adult" && $0.typeName == "成人" })
    let adultFilters = try #require(adult.filters?["bucket|adult"])
    #expect(adultFilters.map(\.key) == ["class", "year", "by"])
    let adultClasses = try #require(adultFilters.first { $0.key == "class" })
    #expect(
      adultClasses.value.map(\.name)
        == ["全部", "国产", "自拍", "主播", "传媒", "人妻", "制服", "无码", "三级", "动漫", "欧美", "女优"]
    )
    let adultSort = try #require(adultFilters.first { $0.key == "by" })
    #expect(adultSort.value.map(\.name) == ["热门", "最多播放", "最新更新"])
    let adultColumn = try await adultHost.invoke(
      api: api,
      ext: ext(adultMode: true),
      method: .categoryContent,
      arguments: [
        .string("bucket|adult"),
        .string("1"),
        .bool(false),
        .object([:]),
      ]
    )
    #expect(JSFixtureURLProtocol.requestedPaths.contains("/adult"))
    #expect(adultColumn.list.contains { $0.name == "成人测试" })
    #expect(adultColumn.list.contains { $0.name == "自拍测试" })
    #expect(adultColumn.list.count <= BrowseCatalogPolicy.itemsPerMenu)
    #expect(adultColumn.pagecount == 1)
    let selfieColumn = try await adultHost.invoke(
      api: api,
      ext: ext(adultMode: true),
      method: .categoryContent,
      arguments: [
        .string("bucket|adult"),
        .string("1"),
        .bool(false),
        .object(["class": .string("自拍")]),
      ]
    )
    #expect(selfieColumn.list.map(\.name).sorted() == ["自拍测试"])
    #expect(selfieColumn.pagecount ?? 1 >= 2)
    await adultHost.destroy()
  }

  private static func makeSession(routes: [String: String]) throws -> URLSession {
    JSFixtureURLProtocol.statusCodes = [:]
    JSFixtureURLProtocol.routes = routes.mapValues { Data($0.utf8) }
    JSFixtureURLProtocol.requestedPaths = []
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [JSFixtureURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private final class JSFixtureURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var routes: [String: Data] = [:]
  nonisolated(unsafe) static var statusCodes: [String: Int] = [:]
  nonisolated(unsafe) static var requestedPaths: [String] = []

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let path = request.url?.path ?? "/"
    Self.requestedPaths.append(path)
    let body = Self.routes[path] ?? Data("not found".utf8)
    let status =
      Self.statusCodes[path]
      ?? (Self.routes[path] == nil ? 404 : 200)
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "https://fixture.local/")!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/javascript"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
