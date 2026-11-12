import Foundation
import Testing
@testable import FirepickBridge
@testable import FirepickCore

@Suite(.serialized)
struct FongmiServerClientTests {
    @Test
    func loadsAndInvokesExistingFongmiServerProtocol() async throws {
        let state = MockState()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            let body: String
            switch (method, path) {
            case ("POST", "/spider-api"):
                body = #"{"session":"test-session","root":"/tmp"}"#
            case ("POST", "/spider-api/load"), ("POST", "/spider-api/run"):
                body = #"{"state":"running","result":""}"#
            case ("GET", "/spider-api"):
                state.polls += 1
                let snapshot = state.polls
                if snapshot < 2 {
                    body = #"{"state":"loading","result":""}"#
                } else {
                    body = #"{"state":"done","result":"{\"class\":[{\"type_id\":\"1\",\"type_name\":\"电影\"}],\"list\":[{\"vod_id\":\"1\",\"vod_name\":\"示例\"}]}"}"#
                }
            default:
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = FongmiServerClient(
            baseURL: URL(string: "http://127.0.0.1:9978")!,
            session: URLSession(configuration: configuration)
        )

        try await client.load(
            api: "https://example.com/spider.js",
            ext: "",
            jar: ""
        )
        let result = try await client.invoke(method: "homeContent", arguments: [])
        #expect(result.classes.first?.typeName == "电影")
        #expect(result.list.first?.name == "示例")
    }

    @Test
    func homeContentSendsTheRequiredBooleanArgument() async throws {
        let state = MockState()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            let body: String
            switch (method, path) {
            case ("POST", "/spider-api"):
                body = #"{"session":"test-session","root":"/tmp"}"#
            case ("POST", "/spider-api/load"):
                body = #"{"state":"loading","result":""}"#
            case ("POST", "/spider-api/run"):
                state.runBody = MockURLProtocol.body(of: request).flatMap {
                    String(data: $0, encoding: .utf8)
                } ?? ""
                body = #"{"state":"running","result":""}"#
            case ("GET", "/spider-api"):
                state.polls += 1
                if state.polls == 1 {
                    body = #"{"state":"loaded","result":""}"#
                } else {
                    body = #"{"state":"done","result":"{\"list\":[]}"}"#
                }
            default:
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = FongmiServerClient(
            baseURL: URL(string: "http://127.0.0.1:9978")!,
            session: URLSession(configuration: configuration)
        )
        let provider = FongmiServerProvider(
            site: .init(key: "js", name: "JS", type: 3, api: "https://example.com/spider.js"),
            client: client
        )

        _ = try await provider.homeContent()

        let body = try #require(state.runBody.data(using: .utf8))
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["method"] as? String == "homeContent")
        #expect(object["args"] as? [Bool] == [false])
    }

    @Test
    func readsAndControlsFongmiRemotePlayback() async throws {
        let state = MockState()
        MockURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                state.remoteBody = MockURLProtocol.body(of: request)
            }
            let body = """
            {
              "active": true,
              "title": "Test",
              "position": 120000,
              "duration": 3600000,
              "playWhenReady": true,
              "repeatOne": false,
              "live": false,
              "canNavigate": true,
              "canSeek": true,
              "canSetSpeed": true,
              "speed": 1.25,
              "engine": "mpv",
              "video": "1920x1080"
            }
            """
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = FongmiRemoteClient(
            baseURL: URL(string: "http://127.0.0.1:9978")!,
            session: URLSession(configuration: configuration)
        )
        let status = try await client.status()
        #expect(status.active)
        #expect(status.position == 120_000)
        #expect(status.engine == "mpv")
        _ = try await client.control(.speed, speed: 2)
        let body = String(decoding: try #require(state.remoteBody), as: UTF8.self)
        #expect(body.contains("type=speed"))
        #expect(body.contains("speed=2.0"))
    }
}

private final class MockState: @unchecked Sendable {
    var polls = 0
    var runBody = ""
    var remoteBody: Data?
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

