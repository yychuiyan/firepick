import Foundation
import Testing
@testable import FirepickBridge
@testable import FirepickCore

struct BridgeTests {
    @Test
    func parsesPairingPayload() throws {
        let raw = """
        firepick://pair?id=bridge-1&name=Living%20Room&url=https%3A%2F%2F192.168.1.8%3A9443&pin=ABCDEF&code=123456
        """
        let payload = try #require(BridgePairingPayload(URL(string: raw)!))
        #expect(payload.id == "bridge-1")
        #expect(payload.baseURL.port == 9443)
        #expect(payload.certificateSHA256 == "abcdef")
        #expect(payload.code == "123456")
    }

    @Test
    func routeUsesBridgeForPythonJavaAndNode() {
        let router = SourceRouter()
        for api in ["./spider.py", "csp_Demo", "node:https://example.com/index.js"] {
            #expect(router.route(.init(key: api, name: api, type: 3, api: api)).execution == .bridge)
        }
    }

    @Test
    func mapsBridgeProxyURIToSessionEndpoint() throws {
        let url = try #require(CatVodProxyURL.bridgeURL(
            "proxy://?do=jar&format=mp4",
            baseURL: URL(string: "https://bridge.local:9443")!,
            sessionId: "session-1",
            siteKey: "source"
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/v1/sessions/session-1/proxy")
        #expect(components.queryItems?.contains(.init(name: "siteKey", value: "source")) == true)
        #expect(components.queryItems?.contains(.init(name: "format", value: "mp4")) == true)
    }
}

