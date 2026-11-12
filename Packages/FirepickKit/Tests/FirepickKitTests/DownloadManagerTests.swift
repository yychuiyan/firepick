import Foundation
import Testing
@testable import FirepickCore
@testable import FirepickPlayback

@MainActor
struct DownloadManagerTests {
    @Test
    func downloadsPersistsAndReopensOfflineFile() async throws {
        let payload = Data(repeating: 0x5A, count: 160_000)
        DownloadURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": String(payload.count),
                    "Content-Type": "video/mp4",
                ]
            )!
            return (response, payload)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = try DownloadManager(directory: directory, session: session)
        manager.download(
            request: PlaybackRequest(
                url: URL(string: "https://example.com/video.mp4?token=1")!,
                headers: ["Referer": "https://example.com/"]
            ),
            sourceKey: "source",
            item: MediaItem(vodId: "vod-1", name: "Test Video"),
            episode: Episode(name: "第 1 集", value: "ep-1")
        )

        for _ in 0..<100 where manager.entries.first?.status != .completed {
            try await Task.sleep(for: .milliseconds(25))
        }
        let entry = try #require(manager.entries.first)
        #expect(entry.status == .completed)
        #expect(entry.fileSize == Int64(payload.count))
        #expect(entry.remoteURL.contains("token=1"))
        let request = try #require(manager.playbackRequest(for: entry))
        #expect(try Data(contentsOf: request.url) == payload)

        let reopened = try DownloadManager(directory: directory, session: session)
        #expect(reopened.entries.first?.status == .completed)
        #expect(reopened.entries.first?.title == "Test Video")
    }
}

private final class DownloadURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let handler = try #require(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
