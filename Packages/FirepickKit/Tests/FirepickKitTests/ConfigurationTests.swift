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
}

