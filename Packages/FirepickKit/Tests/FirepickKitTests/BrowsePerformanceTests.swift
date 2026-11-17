import Foundation
import Testing

@testable import FirepickCore
@testable import FirepickPlayback

private actor PrefetchConcurrencyProbe {
  private var active = 0
  private var maximum = 0

  func begin() {
    active += 1
    maximum = max(maximum, active)
  }

  func end() {
    active -= 1
  }

  var maximumActive: Int {
    maximum
  }
}

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
  func filteredBrowseMenusPreservePagination() {
    let items = (0..<25).map {
      MediaItem(vodId: "filtered-\($0)", name: "筛选节目 \($0)")
    }
    var result = MediaResult(list: items)
    result.pagecount = 7

    let bounded = BrowseCatalogPolicy.bound(
      result,
      preservesPagination: true
    )

    #expect(bounded.list.count == 18)
    #expect(bounded.pagecount == 7)
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

  @Test
  func browsePrefetchRunsTwoCategoriesWithoutExceedingLimit() async {
    let probe = PrefetchConcurrencyProbe()
    let categories = ["tv", "movie", "variety", "anime"]

    let completed = await BrowsePrefetchScheduler.run(
      categories,
      maxConcurrent: 2
    ) { category in
      await probe.begin()
      try? await Task.sleep(for: .milliseconds(40))
      await probe.end()
      return category
    }

    #expect(Set(completed) == Set(categories))
    #expect(await probe.maximumActive == 2)
  }
}
