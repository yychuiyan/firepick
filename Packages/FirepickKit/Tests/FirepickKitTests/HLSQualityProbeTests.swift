import Foundation
import Testing
@testable import FirepickProvider

@Suite("HLSQualityProbeTests")
struct HLSQualityProbeTests {
  @Test func selectsHighestResolutionThenBandwidth() {
    let playlist = """
      #EXTM3U
      #EXT-X-STREAM-INF:BANDWIDTH=1800000,RESOLUTION=1280x720
      medium.m3u8
      #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
      high.m3u8
      #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080
      high-plus.m3u8
      """
    let profile = HLSQualityProbe.parseMasterPlaylist(playlist)
    #expect(profile == HLSQualityProfile(width: 1920, height: 1080, bandwidth: 8_000_000))
  }

  @Test func rejectsMediaPlaylistWithoutVariants() {
    let playlist = """
      #EXTM3U
      #EXT-X-TARGETDURATION:6
      #EXTINF:6,
      segment.ts
      """
    #expect(HLSQualityProbe.parseMasterPlaylist(playlist) == nil)
  }

  @Test func resolvesBestVariantAndSkipsInitializationMap() throws {
    let master = """
      #EXTM3U
      #EXT-X-STREAM-INF:BANDWIDTH=1800000,RESOLUTION=1280x720
      medium/index.m3u8
      #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
      high/index.m3u8
      """
    let base = try #require(URL(string: "https://example.com/play/master.m3u8"))
    let variant = try #require(HLSQualityProbe.bestVariantURL(in: master, baseURL: base))
    #expect(variant.absoluteString == "https://example.com/play/high/index.m3u8")

    let media = """
      #EXTM3U
      #EXT-X-MAP:URI="init.mp4"
      #EXTINF:6,
      segment-1.m4s
      #EXTINF:6,
      segment-2.m4s
      """
    let segment = try #require(
      HLSQualityProbe.firstMediaSegmentURL(in: media, baseURL: variant)
    )
    #expect(segment.absoluteString == "https://example.com/play/high/segment-2.m4s")
  }
}
