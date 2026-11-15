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
}
