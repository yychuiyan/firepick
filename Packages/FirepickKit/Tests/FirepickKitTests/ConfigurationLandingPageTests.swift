import Foundation
import Testing

@testable import FirepickCore

struct ConfigurationLandingPageTests {
  @Test
  func extractsConfigurationLinksFromNavigationPage() throws {
    let html = """
      <a data-clipboard-text="http://example.com/tvbox.json">配置</a>
      <a href="http://example.com/live.m3u">直播</a>
      <a href="http://example.com/about">关于</a>
      <a href="https://example.com/config?a=1&amp;b=2">备用</a>
      <a href="http://tvbox.example.com/">伪装配置</a>
      <a href="http://img.example.com/config.jpg">图片配置</a>
      """
    let urls = ConfigurationLandingPage.candidateURLs(
      from: Data(html.utf8),
      baseURL: URL(string: "http://source.example/page")!
    )
    #expect(urls.count == 5)
    let first = try #require(urls.first)
    let fallback = try #require(urls.last)
    #expect(first.absoluteString == "http://example.com/tvbox.json")
    #expect(fallback.absoluteString == "http://img.example.com/config.jpg")
  }
}
