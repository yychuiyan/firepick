import Foundation
import Testing

@testable import FirepickCore
@testable import FirepickPlayback

@Suite("BrowsePerformanceTests")
struct BrowsePerformanceTests {
  @Test
  func browseMenusStopAtEighteenItems() {
    let items = (0..<25).map {
      MediaItem(vodId: "item-\($0)", name: "节目 \($0)")
    }
    let result = MediaResult(
      classes: [Category(typeId: "bucket|tv", typeName: "电视剧")],
      list: items
    )
    var paged = result
    paged.pagecount = 99

    let bounded = BrowseCatalogPolicy.bound(paged)

    #expect(bounded.list.count == 18)
    #expect(bounded.list.map(\.vodId) == items.prefix(18).map(\.vodId))
    #expect(bounded.pagecount == 1)
    #expect(bounded.classes == result.classes)
  }

  @Test
  func backgroundPlaybackSurvivesViewDisappearanceOnlyWhenEnabled() {
    #expect(
      PlaybackLifecyclePolicy.keepsAudioWhenViewDisappears(
        backgroundPlaybackEnabled: true,
        isBackground: true
      )
    )
    #expect(
      !PlaybackLifecyclePolicy.keepsAudioWhenViewDisappears(
        backgroundPlaybackEnabled: false,
        isBackground: true
      )
    )
    #expect(
      !PlaybackLifecyclePolicy.keepsAudioWhenViewDisappears(
        backgroundPlaybackEnabled: true,
        isBackground: false
      )
    )
  }
}
