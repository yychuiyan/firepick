import Foundation
import Testing

@testable import FirepickCore

@Suite("OfficialVideoPlatformTests")
struct OfficialVideoPlatformTests {
  @Test
  func buildsEncodedSearchURLsForEveryPlatform() {
    let query = "庆余年 第二季"
    let encoded = "%E5%BA%86%E4%BD%99%E5%B9%B4%20%E7%AC%AC%E4%BA%8C%E5%AD%A3"

    #expect(
      OfficialVideoPlatform.tencent.searchURL(for: query)?.absoluteString
        == "https://v.qq.com/x/search/?q=\(encoded)"
    )
    #expect(
      OfficialVideoPlatform.iqiyi.searchURL(for: query)?.absoluteString
        == "https://m.iqiyi.com/search.html?key=\(encoded)"
    )
    #expect(
      OfficialVideoPlatform.youku.searchURL(for: query)?.absoluteString
        == "https://so.youku.com/search_video/q_\(encoded)"
    )
    #expect(
      OfficialVideoPlatform.mgtv.searchURL(for: query)?.absoluteString
        == "https://so.mgtv.com/so?k=\(encoded)"
    )
    #expect(
      OfficialVideoPlatform.bilibili.searchURL(for: query)?.absoluteString
        == "https://m.bilibili.com/search?keyword=\(encoded)"
    )
  }

  @Test
  func presentsPlatformsInRequestedMenuOrder() {
    #expect(
      OfficialVideoPlatform.allCases
        == [.tencent, .youku, .iqiyi, .mgtv, .bilibili]
    )
  }

  @Test
  func trimsSearchQueryAndRejectsBlankOrOverlongInput() {
    #expect(
      OfficialVideoPlatform.tencent.searchURL(for: "  庆余年  ")?.absoluteString
        == "https://v.qq.com/x/search/?q=%E5%BA%86%E4%BD%99%E5%B9%B4"
    )
    #expect(OfficialVideoPlatform.iqiyi.searchURL(for: " \n ") == nil)
    #expect(OfficialVideoPlatform.mgtv.searchURL(for: String(repeating: "剧", count: 81)) == nil)
  }

  @Test
  func matchesOnlyOfficialPlatformHosts() {
    #expect(
      OfficialVideoPlatform.tencent.owns(
        URL(string: "https://v.qq.com/x/cover/example.html")!
      )
    )
    #expect(
      OfficialVideoPlatform.iqiyi.owns(
        URL(string: "https://passport.iqiyi.com/login")!
      )
    )
    #expect(!OfficialVideoPlatform.tencent.owns(URL(string: "https://qq.com/")!))
    #expect(
      !OfficialVideoPlatform.tencent.owns(
        URL(string: "https://v.qq.com.evil.example/")!
      )
    )
    #expect(
      !OfficialVideoPlatform.youku.owns(
        URL(string: "https://notyouku.com/")!
      )
    )
  }

  @Test
  func mapsTencentAppPlayLinkToEmbeddedWebPlayer() throws {
    let deepLink = try #require(
      URL(
        string:
          "txvideo://v.qq.com/VideoDetailActivity?cid=mzc002002kqssyu&vid=q4100dpkd26&isAutoPlay=1"
      )
    )

    #expect(
      OfficialVideoPlatform.tencent.embeddedWebURL(for: deepLink)?.absoluteString
        == "https://v.qq.com/x/cover/mzc002002kqssyu/q4100dpkd26.html"
    )
  }

  @Test
  func mapsTencentHtml5DeepLinkToOfficialPage() throws {
    let deepLink = try #require(
      URL(
        string:
          "txvideo://v.qq.com/Html5Activity?url=https%3A%2F%2Fv.qq.com%2Fx%2Fcover%2Fcid-1%2Fvid-1.html"
      )
    )

    #expect(
      OfficialVideoPlatform.tencent.embeddedWebURL(for: deepLink)?.absoluteString
        == "https://v.qq.com/x/cover/cid-1/vid-1.html"
    )
  }

  @Test
  func resolvesOfficialLinksToTheirPlatform() throws {
    let tencent = try #require(
      OfficialVideoPlatform.linkTarget(
        from:
          "https://v.qq.com/x/cover/mzc00200zsqz54y/u4102l4hqji.html"
      )
    )
    let bilibili = try #require(
      OfficialVideoPlatform.linkTarget(
        from: "m.bilibili.com/video/BV1example"
      )
    )

    #expect(tencent.platform == .tencent)
    #expect(
      tencent.url.absoluteString
        == "https://v.qq.com/x/cover/mzc00200zsqz54y/u4102l4hqji.html"
    )
    #expect(bilibili.platform == .bilibili)
    #expect(bilibili.url.absoluteString == "https://m.bilibili.com/video/BV1example")
  }

  @Test
  func resolvesTencentAppLinkToEmbeddedHTTPPage() throws {
    let target = try #require(
      OfficialVideoPlatform.linkTarget(
        from:
          "txvideo://v.qq.com/VideoDetailActivity?cid=cid-1&vid=vid-1"
      )
    )

    #expect(target.platform == .tencent)
    #expect(
      target.url.absoluteString
        == "https://v.qq.com/x/cover/cid-1/vid-1.html"
    )
  }

  @Test
  func rejectsUnsupportedAndAmbiguousLinks() {
    #expect(
      OfficialVideoPlatform.linkTarget(
        from: "https://v.qq.com.evil.example/x/cover/test.html"
      ) == nil
    )
    #expect(
      OfficialVideoPlatform.linkTarget(from: "javascript:alert(1)") == nil
    )
    #expect(
      OfficialVideoPlatform.linkTarget(from: "https://example.com/video") == nil
    )
    #expect(
      OfficialVideoPlatform.linkTarget(from: "https://v.qq.com/x/a b") == nil
    )
    #expect(
      OfficialVideoPlatform.linkTarget(
        from: "https://v.qq.com/" + String(repeating: "a", count: 2_048)
      ) == nil
    )
  }

  @Test
  func buildsDiscoverySearchURLAndAcceptsSearchEngineHosts() {
    #expect(
      VideoPlatformDiscovery.searchURL(for: " 走马上任 ")?.absoluteString
        == "https://www.baidu.com/s?wd=%E8%B5%B0%E9%A9%AC%E4%B8%8A%E4%BB%BB"
    )
    #expect(VideoPlatformDiscovery.searchURL(for: " ") == nil)
    #expect(
      VideoPlatformDiscovery.ownsSearchEngine(
        URL(string: "https://www.baidu.com/link?url=example")!
      )
    )
    #expect(
      !VideoPlatformDiscovery.ownsSearchEngine(
        URL(string: "https://baidu.com.evil.example/")!
      )
    )
  }

  @Test
  func resolvesBrowserAddressInput() {
    #expect(
      WebAddressResolver.resolve("https://example.com/watch?q=1")?.absoluteString
        == "https://example.com/watch?q=1"
    )
    #expect(
      WebAddressResolver.resolve("jx.202617.xyz/tv.php?url=abc")?.absoluteString
        == "https://jx.202617.xyz/tv.php?url=abc"
    )
    #expect(
      WebAddressResolver.resolve("走马上任")?.absoluteString
        == "https://www.baidu.com/s?wd=%E8%B5%B0%E9%A9%AC%E4%B8%8A%E4%BB%BB"
    )
    #expect(WebAddressResolver.resolve("javascript:alert(1)") == nil)
  }

  @Test
  func detectsOneOfficialPagePerPlatform() {
    let html = """
      <a href="http:\\/\\/v.qq.com\\/x\\/cover\\/cid-1.html?ptag=123">
      <a href="http://v.qq.com/x/cover/cid-2.html">
      <a href="https://www.iqiyi.com/v_example.html">
      <a href="https://m.bilibili.com/video/BV1example?spm_id_from=333">
      <a href="https://example.com/video">其他站点</a>
      """

    let pages = VideoPlatformLinkDetector.extract(from: html)

    #expect(pages.count == 3)
    #expect(pages[0].platform == .iqiyi)
    #expect(
      pages[0].url.absoluteString
        == "https://www.iqiyi.com/v_example.html"
    )
    #expect(pages[1].platform == .tencent)
    #expect(
      pages[1].url.absoluteString
        == "https://v.qq.com/x/cover/cid-1.html"
    )
    #expect(pages[2].platform == .bilibili)
    #expect(
      pages[2].url.absoluteString
        == "https://m.bilibili.com/video/BV1example"
    )
  }

  @Test
  func normalizesWebsiteShortcutAddress() {
    #expect(
      WebsiteShortcut.normalizedURL(from: "v.qq.com")?.absoluteString
        == "https://v.qq.com"
    )
    #expect(
      WebsiteShortcut.normalizedURL(from: "https://www.baidu.com")?.absoluteString
        == "https://www.baidu.com"
    )
    #expect(WebsiteShortcut.normalizedURL(from: "javascript:alert(1)") == nil)
    #expect(WebsiteShortcut.normalizedURL(from: "not a website") == nil)
  }

  @Test
  func encodesSourceURLAsSingleParserParameter() throws {
    let shortcut = try #require(
      WebsiteShortcut.normalizedURL(
        from: "https://jx.example.com/player?url="
      ).map {
        WebsiteShortcut(name: "解析", url: $0, isEnabled: true)
      }
    )

    let parsed = try #require(
      shortcut.parserURL(
        for: "https://v.qq.com/x/cover/cid/vid.html?from=search&x=1#player"
      )
    )
    let components = try #require(
      URLComponents(url: parsed, resolvingAgainstBaseURL: false)
    )
    #expect(
      components.queryItems?.count == 1
    )
    #expect(
      components.queryItems?.first?.value
        == "https://v.qq.com/x/cover/cid/vid.html?from=search&x=1#player"
    )
    #expect(
      shortcut.parserURL(for: "v.qq.com/x/cover/cid/vid.html")
        .flatMap {
          URLComponents(url: $0, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first?
            .value
        }
        == "https://v.qq.com/x/cover/cid/vid.html"
    )
    #expect(shortcut.parserURL(for: "javascript:alert(1)") == nil)
  }

}
