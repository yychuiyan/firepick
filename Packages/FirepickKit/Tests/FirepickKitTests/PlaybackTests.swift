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
}

