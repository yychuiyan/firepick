import Foundation
import Testing

@testable import FirepickProvider

@Suite("DeepSeekTitleAssistantTests")
struct DeepSeekTitleAssistantTests {
  private actor Counter {
    var value = 0
    func increment() -> Int {
      value += 1
      return value
    }
  }

  @Test
  func sendsStructuredJSONRequestAndSanitizesResult() async throws {
    let counter = Counter()
    let assistant = DeepSeekTitleAssistant(
      apiKey: "secret-key",
      cacheFileURL: nil,
      transport: { request in
        _ = await counter.increment()
        let body = try #require(request.httpBody)
        let object = try #require(
          JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["model"] as? String == "deepseek-flash")
        #expect(object["temperature"] as? Double == 0)
        #expect(object["max_tokens"] as? Int == 320)
        #expect((object["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect(
          (object["response_format"] as? [String: Any])?["type"] as? String
            == "json_object"
        )
        #expect(
          request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key"
        )
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "system")
        #expect((messages.first?["content"] as? String)?.contains("不可信的影视数据") == true)

        return Self.response(
          for: """
            {
              "task": "title_match",
              "intent": "title",
              "canonicalTitle": "庆余年 第二季",
              "aliases": ["庆余年2", "庆余年2", "a"],
              "searchTerms": ["庆余年 第二季", "庆余年2"],
              "matches": [
                {"id": "known", "confidence": 1.4},
                {"id": "unknown", "confidence": 0.99}
              ],
              "episodeMatch": null,
              "confidence": 0.9
            }
            """
        )
      }
    )

    let result = try await assistant.titleMatch(
      query: "庆余年第二季",
      metadata: .init(title: "庆余年", year: "2024", actors: ["张若昀"]),
      candidates: [.init(id: "known", title: "庆余年 第二季")],
      contentMode: "standard"
    )

    #expect(await counter.value == 1)
    #expect(result.canonicalTitle == "庆余年 第二季")
    #expect(result.aliases == ["庆余年2"])
    #expect(result.matches == [.init(id: "known", confidence: 1)])
  }

  @Test
  func episodeMatchRejectsUnknownIDs() async throws {
    let assistant = DeepSeekTitleAssistant(
      apiKey: "secret-key",
      cacheFileURL: nil,
      transport: { _ in
        Self.response(
          for: """
            {
              "task": "episode_match",
              "intent": "episode",
              "canonicalTitle": null,
              "aliases": [],
              "searchTerms": [],
              "matches": [],
              "episodeMatch": {"id": "unknown", "confidence": 0.99},
              "confidence": 0.99
            }
            """
        )
      }
    )

    let result = try await assistant.episodeMatch(
      mediaTitle: "庆余年",
      currentEpisode: "第03集",
      candidates: [.init(id: "episode-3", name: "EP03")],
      contentMode: "standard"
    )
    #expect(result.episodeMatch == nil)
  }

  @Test
  func cachesPositiveResultsAcrossAssistantInstances() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("firepick-deepseek-\(UUID().uuidString)", isDirectory: true)
    let cacheURL = directory.appendingPathComponent("cache.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstCounter = Counter()
    let secondCounter = Counter()

    let first = DeepSeekTitleAssistant(
      apiKey: "secret-key",
      cacheFileURL: cacheURL,
      transport: { _ in
        _ = await firstCounter.increment()
        return Self.response(
          for: """
            {
              "task": "title_match",
              "intent": "title",
              "canonicalTitle": "庆余年第二季",
              "aliases": ["庆余年2"],
              "searchTerms": ["庆余年 第二季"],
              "matches": [],
              "episodeMatch": null,
              "confidence": 0.9
            }
            """
        )
      }
    )
    _ = try await first.titleMatch(
      query: "庆余年2",
      metadata: .init(title: "庆余年"),
      candidates: [],
      contentMode: "standard"
    )

    let second = DeepSeekTitleAssistant(
      apiKey: "secret-key",
      cacheFileURL: cacheURL,
      transport: { _ in
        _ = await secondCounter.increment()
        return Self.response(for: "{}")
      }
    )
    let cached = try await second.titleMatch(
      query: "庆余年2",
      metadata: .init(title: "庆余年"),
      candidates: [],
      contentMode: "standard"
    )

    #expect(await firstCounter.value == 1)
    #expect(await secondCounter.value == 0)
    #expect(cached.canonicalTitle == "庆余年第二季")
  }

  @Test
  func mapsUnauthorizedResponseToInvalidKey() async {
    let assistant = DeepSeekTitleAssistant(
      apiKey: "bad-key",
      cacheFileURL: nil,
      transport: { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 401,
          httpVersion: nil,
          headerFields: nil
        )!
        return (Data(), response)
      }
    )

    await #expect(throws: DeepSeekAssistError.invalidKey) {
      try await assistant.validateAPIKey()
    }
  }

  @Test
  func negativelyCachesRateLimitWithoutRepeatingRequest() async {
    let counter = Counter()
    let assistant = DeepSeekTitleAssistant(
      apiKey: "secret-key",
      cacheFileURL: nil,
      transport: { request in
        _ = await counter.increment()
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 429,
          httpVersion: nil,
          headerFields: nil
        )!
        return (Data(), response)
      }
    )

    await #expect(throws: DeepSeekAssistError.rateLimited) {
      try await assistant.titleMatch(
        query: "庆余年",
        metadata: .init(title: "庆余年"),
        candidates: [],
        contentMode: "standard"
      )
    }
    await #expect(throws: DeepSeekAssistError.temporarilyUnavailable) {
      try await assistant.titleMatch(
        query: "庆余年",
        metadata: .init(title: "庆余年"),
        candidates: [],
        contentMode: "standard"
      )
    }
    #expect(await counter.value == 1)
  }

  @Test
  func rejectsMalformedJSONAndMismatchedTask() async throws {
    let malformed = DeepSeekTitleAssistant(
      apiKey: "secret-key",
      cacheFileURL: nil,
      transport: { _ in Self.response(for: "not json") }
    )
    await #expect(throws: DeepSeekAssistError.invalidResponse) {
      try await malformed.titleMatch(
        query: "庆余年",
        metadata: .init(title: "庆余年"),
        candidates: [],
        contentMode: "standard"
      )
    }

    let mismatched = DeepSeekTitleAssistant(
      apiKey: "secret-key",
      cacheFileURL: nil,
      transport: { _ in
        Self.response(
          for: """
            {
              "task": "episode_match",
              "intent": "episode",
              "canonicalTitle": null,
              "aliases": [],
              "searchTerms": [],
              "matches": [],
              "episodeMatch": null,
              "confidence": 0.9
            }
            """
        )
      }
    )
    let result = try await mismatched.titleMatch(
      query: "庆余年",
      metadata: .init(title: "庆余年"),
      candidates: [],
      contentMode: "standard"
    )
    #expect(result.confidence == 0)
    #expect(result.aliases.isEmpty)
    #expect(result.searchTerms.isEmpty)
  }

  private static func response(for content: String) -> (Data, URLResponse) {
    let envelope: [String: Any] = [
      "choices": [
        ["message": ["content": content]]
      ]
    ]
    let data = try! JSONSerialization.data(withJSONObject: envelope)
    let response = HTTPURLResponse(
      url: URL(string: "https://api.deepseek.com/chat/completions")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    return (data, response)
  }
}
