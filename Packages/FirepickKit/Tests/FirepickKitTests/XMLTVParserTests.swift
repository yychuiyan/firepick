import Foundation
import Testing
@testable import FirepickCore

struct XMLTVParserTests {
    @Test
    func parsesOffsetsAndInfersMissingStop() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="20261112120000 +0800" channel="cctv1">
            <title>午间新闻</title>
            <desc>新闻摘要</desc>
          </programme>
          <programme start="20261112123000 +0800" stop="20261112130000 +0800" channel="cctv1">
            <title>今日说法</title>
          </programme>
        </tv>
        """
        let programs = XMLTVParser.programs(Data(xml.utf8))
        #expect(programs.count == 2)
        let formatter = ISO8601DateFormatter()
        #expect(formatter.string(from: programs[0].start) == "2026-11-12T04:00:00Z")
        #expect(
            formatter.string(from: programs[0].stop) == "2026-11-12T04:30:00Z"
        )
        #expect(programs[0].description == "新闻摘要")
    }

    @Test
    func rejectsInvalidProgrammesAndSortsChannels() {
        let xml = """
        <tv>
          <programme start="20261112120000 +0000" stop="20261112110000 +0000" channel="bad">
            <title>Invalid</title>
          </programme>
          <programme start="20261112130000 +0000" stop="20261112140000 +0000" channel="b">
            <title>B</title>
          </programme>
          <programme start="20261112110000 +0000" stop="20261112120000 +0000" channel="a">
            <title>A</title>
          </programme>
        </tv>
        """
        let programs = XMLTVParser.programs(Data(xml.utf8))
        #expect(programs.map(\.title) == ["A", "B"])
    }
}
