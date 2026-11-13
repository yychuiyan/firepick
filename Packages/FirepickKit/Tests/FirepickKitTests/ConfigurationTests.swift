import Foundation
import Testing

@testable import FirepickCore

struct ConfigurationTests {
  @Test
  func decodesCatVodSiteKinds() throws {
    let json = """
      {
        "sites": [
          {"key":"http","name":"HTTP","type":1,"api":"https://example.com/vod"},
          {"key":"js","name":"JS","type":3,"api":"./spider.js","ext":{"region":"cn"}},
          {"key":"java","name":"Java","type":3,"api":"csp_Demo","jar":"./spider.jar"}
        ]
      }
      """.data(using: .utf8)!

    let config = try JSONDecoder().decode(VodConfiguration.self, from: json)
    #expect(config.sites.count == 3)
    #expect(config.sites[1].ext?.objectValue?["region"]?.stringValue == "cn")
  }

  @Test
  func digestIsStableRegardlessOfPropertyOrder() throws {
    let first = VodConfiguration(
      sites: [.init(key: "a", name: "A", type: 1, api: "https://example.com")]
    )
    let second = VodConfiguration(
      spider: nil,
      sites: [.init(key: "a", name: "A", type: 1, api: "https://example.com")]
    )
    #expect(try ConfigurationDigest.sha256(first) == ConfigurationDigest.sha256(second))
  }

  @Test
  func javaSitesInheritTheGlobalSpiderJar() {
    var config = VodConfiguration(
      spider: "./jar/spider.jar",
      sites: [
        .init(key: "java", name: "Java", type: 3, api: "csp_Demo"),
        .init(key: "js", name: "JS", type: 3, api: "./spider.js"),
      ]
    )

    config.inheritGlobalSpider()

    #expect(config.sites[0].jar == "./jar/spider.jar")
    #expect(config.sites[1].jar == nil)
  }

  @Test
  func decodesTVBoxConfigurationWrappedAfterJPEGEndMarker() throws {
    let json = """
      {
        // Legacy commented configuration entry.
        "sites": [
          {"key":"wrapped","name":"图片封装配置","type":1,"api":"https://example.com/vod"}
        ],
        "lives": []
      }
      """
    let encoded = json.data(using: .utf8)!.base64EncodedString()
    var wrapped = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x00, 0xFF, 0xD9])
    wrapped.append(Data("AbCd1234**\(encoded)".utf8))

    let detected = try ConfigurationDetector.detect(wrapped)
    guard case .vod(let configuration) = detected else {
      Issue.record("Expected image-wrapped VOD configuration")
      return
    }
    #expect(configuration.sites.count == 1)
    #expect(configuration.sites[0].key == "wrapped")
  }

  @Test
  func keepsRejectingPlainAndMalformedJPEGResponses() {
    let plain = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x00, 0xFF, 0xD9])
    #expect(throws: FirepickError.self) {
      try ConfigurationDecoder.normalize(plain)
    }

    var malformed = plain
    malformed.append(Data("AbCd1234**%%%notbase64".utf8))
    #expect(throws: FirepickError.self) {
      try ConfigurationDecoder.normalize(malformed)
    }
  }

  @Test
  func restoresInternationalizedDomainNameForDisplay() {
    #expect(
      SourceAddress.displayURL("http://www.xn--sss604efuw.net/tv")
        == "http://www.饭太硬.net/tv"
    )
    #expect(
      SourceAddress.displayURL("http://www.饭太硬.net/tv")
        == "http://www.饭太硬.net/tv"
    )
  }
}
