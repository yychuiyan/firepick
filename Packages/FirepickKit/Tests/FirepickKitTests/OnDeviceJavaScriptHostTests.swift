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
  func htmlQueryUsesZeroBasedEqAndSupportsStandaloneEq() {
    let html = "<div>A</div><div>B</div><div>C</div>"
    #expect(CatVodHTMLQuery.pdfh(html, rule: "div:eq(1)&&Text") == "B")
    #expect(CatVodHTMLQuery.pdfh(html, rule: "div&&:eq(2)&&Text") == "C")
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

  private static func makeSession(routes: [String: String]) throws -> URLSession {
    JSFixtureURLProtocol.routes = routes.mapValues { Data($0.utf8) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [JSFixtureURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private final class JSFixtureURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var routes: [String: Data] = [:]

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let path = request.url?.path ?? "/"
    let body = Self.routes[path] ?? Data("not found".utf8)
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "https://fixture.local/")!,
      statusCode: Self.routes[path] == nil ? 404 : 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/javascript"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
