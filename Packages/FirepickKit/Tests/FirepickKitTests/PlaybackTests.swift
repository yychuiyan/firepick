import Foundation
import Testing

@testable import FirepickCore
@testable import FirepickPlayback

struct PlaybackTests {
  @Test
  func selectsAVPlayerForNativeFiles() throws {
    let selector = PlayerSelector()
    let selection = try selector.select(
      .init(url: URL(string: "https://example.com/movie.mp4")!),
      mpvAvailable: true
    )
    #expect(selection.engine == .avPlayer)
  }

  @Test
  func rejectsExtendedFormatsWithoutMPV() {
    let selector = PlayerSelector()
    #expect(throws: FirepickError.self) {
      try selector.select(
        .init(url: URL(string: "https://example.com/movie.mkv")!),
        mpvAvailable: false
      )
    }
  }

  @Test(arguments: ["movie.iso", "movie.mkv", "movie.m2ts?token=abc"])
  func selectsMPVForDiscAndMatroskaContainers(_ name: String) throws {
    let selector = PlayerSelector()
    let hint = "https://example.com/\(name)"
    let selection = try selector.select(
      .init(url: URL(string: hint)!, formatHint: hint),
      mpvAvailable: true
    )
    #expect(selection.engine == .mpv)
  }

  @Test
  func handlesFormatHintQueryParameters() throws {
    let selector = PlayerSelector()
    let selection = try selector.select(
      .init(
        url: URL(string: "https://example.com/opaque/1")!,
        formatHint: "https://example.com/movie.mp4?token=expiring"
      ),
      mpvAvailable: false
    )
    #expect(selection.engine == .avPlayer)
  }

  @Test
  func honoursPreferredMPVWhenAvailable() throws {
    let selector = PlayerSelector()
    let selection = try selector.select(
      .init(
        url: URL(string: "https://example.com/movie.mp4")!,
        preferredEngine: .mpv
      ),
      mpvAvailable: true
    )
    #expect(selection.engine == .mpv)
  }

  @Test
  func normalizesUnknownTimelineValues() {
    #expect(PlaybackTimeline.duration(.nan) == 0)
    #expect(PlaybackTimeline.duration(.infinity) == 0)
    #expect(PlaybackTimeline.duration(-4) == 0)
    #expect(PlaybackTimeline.duration(12) == 12)
    #expect(PlaybackTimeline.position(20, duration: 12) == 12)
    #expect(PlaybackTimeline.position(-1, duration: 12) == 0)
    #expect(PlaybackTimeline.position(.nan, duration: 12) == 0)
    #expect(PlaybackTimeline.position(8, duration: 0) == 8)
  }

  @Test
  func mapsPlaybackEngineOptionsForMPVAndAVPlayer() {
    let hardware = PlaybackEngineOptions(
      videoOutput: .metal,
      decode: .hardware,
      bufferSeconds: 10
    )
    #expect(hardware.mpvVideoOutput == "gpu-next")
    #expect(hardware.mpvHardwareDecode == "videotoolbox")

    let software = PlaybackEngineOptions(
      videoOutput: .system,
      decode: .software,
      bufferSeconds: 2
    )
    #expect(software.mpvVideoOutput == "gpu-next")
    #expect(software.mpvHardwareDecode == "no")
    #expect(software.bufferSeconds == 2)
  }

  @Test
  func detectsMinorityHLSAdSegmentWithoutRewritingTimeline() throws {
    let playlist = """
    #EXTM3U
    #EXT-X-TARGETDURATION:10
    #EXTINF:10,
    main/1.ts
    #EXTINF:10,
    main/2.ts
    #EXTINF:10,
    main/3.ts
    #EXTINF:10,
    main/4.ts
    #EXTINF:10,
    main/5.ts
    #EXTINF:10,
    main/6.ts
    #EXT-X-DISCONTINUITY
    #EXTINF:5,
    ads/promo.ts
    #EXT-X-ENDLIST
    """
    let detection = HlsAdSkipDetector.detect(
      playlist: playlist,
      baseURL: URL(string: "https://cdn.example/show/index.m3u8")
    )
    let skip = try #require(detection.skips.first)
    #expect(detection.skips.count == 1)
    #expect(abs(skip.start - 60) < 0.01)
    #expect(abs((skip.end ?? 0) - 65) < 0.01)
  }

  @Test
  func doesNotTreatLivePlaylistAsVODAds() {
    let detection = HlsAdSkipDetector.detect(
      playlist: """
      #EXTM3U
      #EXTINF:5,
      ads/1.ts
      """,
      baseURL: URL(string: "https://cdn.example/live/index.m3u8")
    )
    #expect(detection.reason == "live")
    #expect(detection.skips.isEmpty)
  }
}
