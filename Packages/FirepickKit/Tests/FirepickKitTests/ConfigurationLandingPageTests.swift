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

  @Test
  func expandsGitHubProxyIntoRawAndJSDelivrFallbacks() throws {
    let proxied =
      "https://gh-proxy.net/https://raw.githubusercontent.com/yoursmile66/TVBox/refs/heads/main/XC.json"
    let urls = ConfigurationLandingPage.candidateURLs(
      from: [proxied],
      baseURL: URL(string: "https://example.com/")!
    )
    let values = urls.map(\.absoluteString)

    #expect(values.contains(proxied))
    #expect(
      values.contains(
        "https://raw.githubusercontent.com/yoursmile66/TVBox/refs/heads/main/XC.json"
      )
    )
    #expect(values.contains("https://cdn.jsdelivr.net/gh/yoursmile66/TVBox@main/XC.json"))
  }

  @Test
  func generatesJSDelivrForDirectGitHubRawLinks() {
    let urls = ConfigurationLandingPage.candidateURLs(
      from: ["https://raw.githubusercontent.com/owner/repo/main/config/tv.json"],
      baseURL: URL(string: "https://example.com/")!
    )
    #expect(
      urls.map(\.absoluteString).contains(
        "https://cdn.jsdelivr.net/gh/owner/repo@main/config/tv.json"
      )
    )
  }
}
