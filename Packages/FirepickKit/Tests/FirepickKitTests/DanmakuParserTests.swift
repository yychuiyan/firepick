import Foundation
import Testing
@testable import FirepickCore
@testable import FirepickPlayback

struct DanmakuParserTests {
    @Test
    func parsesBilibiliXMLAndModes() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <i>
          <d p="12.5,1,25,16711680,1700000000,0,user,row">滚动弹幕</d>
          <d p="15,5,25,16777215,1700000000,0,user,row">顶部弹幕</d>
          <d p="20,4,25,255,1700000000,0,user,row">底部弹幕</d>
        </i>
        """
        let comments = DanmakuParser.parse(Data(xml.utf8))
        #expect(comments.count == 3)
        #expect(comments[0].text == "滚动弹幕")
        #expect(comments[0].time == 12.5)
        #expect(comments[0].mode == .scrolling)
        #expect(comments[1].mode == .top)
        #expect(comments[2].mode == .bottom)
        #expect(comments[2].color == "#0000FF")
    }

    @Test
    func parsesNestedJSONMillisecondsAndDeduplicates() throws {
        let json = """
        {
          "data": [
            {"progress": 2500, "mode": 1, "color": 16777215, "content": "hello"},
            {"progress": 2500, "mode": 1, "color": 16777215, "content": "hello"},
            {"time": 4.5, "type": "top", "colour": "#12ab34", "text": "world"}
          ]
        }
        """
        let comments = DanmakuParser.parse(Data(json.utf8))
        #expect(comments.count == 2)
        #expect(comments[0].time == 2.5)
        #expect(comments[0].text == "hello")
        #expect(comments[1].mode == .top)
        #expect(comments[1].color == "#12AB34")
    }

    @Test
    func ignoresMalformedRecords() {
        let json = """
        [{"time": -2, "text": "invalid"}, {"time": 1, "text": "valid"}]
        """
        let comments = DanmakuParser.parse(Data(json.utf8))
        #expect(comments.map(\.text) == ["valid"])
    }

    @Test
    func parsesDandanPlayParameterizedJSON() {
        let json = """
        {"comments":[{"p":"12.5,1,16777215","m":"hello"},{"p":"15,5,255","m":"top"}]}
        """
        let comments = DanmakuParser.parse(Data(json.utf8))
        #expect(comments.count == 2)
        #expect(comments[0].time == 12.5)
        #expect(comments[0].color == "#FFFFFF")
        #expect(comments[1].mode == .top)
        #expect(comments[1].color == "#0000FF")
    }

    @Test
    func cleansDanmakuSearchTitleAndEpisodeNumber() {
        #expect(DanmakuSourceResolver.cleanTitle("庆余年 第二季（2024）") == "庆余年 第二季")
        #expect(DanmakuSourceResolver.episodeNumber(from: "第12集") == 12)
        #expect(DanmakuSourceResolver.episodeNumber(from: "EP 07") == 7)
        #expect(DanmakuSourceResolver.episodeNumber(from: "2024-01-06期") == nil)
    }
}
