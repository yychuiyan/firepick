import Foundation
import Testing
@testable import FirepickCore

struct ConfigurationDetectorTests {
    @Test
    func detectsMultiDepot() throws {
        let data = """
        {"urls":[{"name":"主线路","url":"./vod.json"},{"name":"备用","url":"https://example.com/vod.json"}]}
        """.data(using: .utf8)!
        guard case let .depot(document) = try ConfigurationDetector.detect(data) else {
            Issue.record("Expected depot")
            return
        }
        #expect(document.urls.count == 2)
    }

    @Test
    func detectsM3UAndGroups() throws {
        let data = """
        #EXTM3U
        #EXTINF:-1 group-title="新闻" tvg-id="cctv1" tvg-logo="https://example.com/1.png",CCTV-1
        #EXTVLCOPT:http-user-agent=Demo
        https://example.com/live.m3u8
        """.data(using: .utf8)!
        guard case let .live(_, groups) = try ConfigurationDetector.detect(data) else {
            Issue.record("Expected live")
            return
        }
        #expect(groups.first?.name == "新闻")
        #expect(groups.first?.channels.first?.name == "CCTV-1")
        #expect(groups.first?.channels.first?.headers["User-Agent"] == "Demo")
    }

    @Test
    func detectsTXT() throws {
        let data = """
        新闻,#genre#
        CCTV-1,https://example.com/1.m3u8#https://example.com/backup.m3u8
        """.data(using: .utf8)!
        guard case let .live(_, groups) = try ConfigurationDetector.detect(data) else {
            Issue.record("Expected live")
            return
        }
        #expect(groups.first?.channels.first?.urls.count == 2)
    }

    @Test
    func preservesM3UEPGAndPerURLHeaders() throws {
        let data = """
        #EXTM3U url-tvg="https://example.com/epg.xml"
        #EXTINF:-1 group-title="新闻",CCTV-1
        https://one.example/live.m3u8|User-Agent=Custom&Referer=https://example.com/
        #EXTINF:-1 group-title="新闻",CCTV-1
        https://two.example/live.m3u8
        """.data(using: .utf8)!
        guard case let .live(_, groups) = try ConfigurationDetector.detect(data) else {
            Issue.record("Expected live")
            return
        }
        let channel = try #require(groups.first?.channels.first)
        #expect(groups.first?.epg == "https://example.com/epg.xml")
        #expect(channel.urls.count == 2)
        #expect(channel.headers["User-Agent"] == "Custom")
        #expect(channel.headers["Referer"] == "https://example.com/")
    }

    @Test
    func decodesDynamicLiveConfigurationAndInheritsSpider() throws {
        let data = """
        {
          "spider": "https://example.com/spider.jar",
          "sites": [{"key":"one","name":"One","type":3,"api":"csp_One"}],
          "lives": [{
            "name": "Dynamic",
            "url": "https://example.com/live.txt",
            "api": "csp_Live",
            "ext": {"token":"abc"}
          }]
        }
        """.data(using: .utf8)!
        guard case var .vod(configuration) = try ConfigurationDetector.detect(data) else {
            Issue.record("Expected VOD configuration")
            return
        }
        configuration.inheritGlobalSpider()
        #expect(configuration.lives?.first?.jar == "https://example.com/spider.jar")
        #expect(configuration.lives?.first?.api == "csp_Live")
    }

    @Test
    func rejectsHTMLPagesWithActionableError() {
        let data = "<!doctype html><html><body>TVBox repository</body></html>"
            .data(using: .utf8)!
        do {
            _ = try ConfigurationDetector.detect(data)
            Issue.record("Expected invalid configuration")
        } catch {
            #expect(error.localizedDescription.contains("网页"))
        }
    }

    @Test
    func rejectsSingleSiteAPIWithActionableError() {
        let data = """
        {"code":1,"msg":"ok","list":[{"vod_id":1,"vod_name":"Demo"}]}
        """.data(using: .utf8)!
        do {
            _ = try ConfigurationDetector.detect(data)
            Issue.record("Expected invalid configuration")
        } catch {
            #expect(error.localizedDescription.contains("完整"))
        }
    }

    @Test
    func toleratesHashPrefixedSectionComments() throws {
        let data = """
        {
          ## sites
          "sites": [
            {"key":"one","name":"One","type":0,"api":"https://example.com/api"}
          ]
        }
        """.data(using: .utf8)!
        guard case let .vod(configuration) = try ConfigurationDetector.detect(data) else {
            Issue.record("Expected VOD configuration")
            return
        }
        #expect(configuration.sites.count == 1)
        #expect(configuration.sites.first?.key == "one")
    }

    @Test
    func keepsSitesAfterLineComments() throws {
        let source = """
        {
          "sites": [
            {"key":"one","name":"One","type":3,"api":"https://example.com/js/drpy.js"},
        //{"key":"disabled","name":"Disabled","type":3,"api":"csp_Disabled"},
        ## section
            {"key":"two","name":"Two","type":0,"api":"https://example.com/api"}
          ]
        }
        """
        let data = source
            .replacingOccurrences(of: "\n", with: "\r\n")
            .data(using: .utf8)!
        guard case let .vod(configuration) = try ConfigurationDetector.detect(data) else {
            Issue.record("Expected VOD configuration")
            return
        }
        #expect(configuration.sites.map(\.key) == ["one", "two"])
    }

    @Test
    func rejectsUnknownJSONArrayWithActionableError() {
        let data = """
        [{"name":"not-a-live-group"}]
        """.data(using: .utf8)!
        do {
            _ = try ConfigurationDetector.detect(data)
            Issue.record("Expected invalid configuration")
        } catch {
            #expect(error.localizedDescription.contains("sites"))
        }
    }

    @Test
    func toleratesLiveEntriesWithoutName() throws {
        let data = """
        {
          "sites": [
            {"key":"one","name":"One","type":0,"api":"https://example.com/api"}
          ],
          "lives": [
            {"group":"redirect","channels":[]}
          ]
        }
        """.data(using: .utf8)!
        guard case let .vod(configuration) = try ConfigurationDetector.detect(data) else {
            Issue.record("Expected VOD configuration")
            return
        }
        #expect(configuration.sites.count == 1)
        #expect(configuration.lives?.first?.name == "直播源")
    }
}

