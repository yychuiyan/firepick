import Foundation
import Testing

@testable import FirepickProvider

@Suite("CMSProviderCatalogTests")
struct CMSProviderCatalogTests {
  @Test
  func bundledCatalogContainsUsableUniqueProviders() {
    let entries = CMSProviderCatalog.bundledCandidates()
    #expect(entries.count >= 45)
    #expect(Set(entries.map(\.key)).count == entries.count)
    #expect(entries.allSatisfy { !$0.key.isEmpty && !$0.name.isEmpty })
    #expect(entries.contains { $0.adult == true })
    #expect(entries.contains { $0.adult != true })
    #expect(
      entries.allSatisfy {
        guard let url = URL(string: $0.api) else { return false }
        return (url.scheme == "https" || url.scheme == "http") && url.host != nil
      }
    )
  }

  @Test
  func remoteCatalogPrefersOwnAPIThenMonitorSources() {
    let urls = CMSProviderCatalog.defaultRemoteCandidateURLs

    #expect(urls.count == 3)
    #expect(urls[0].host == "sources.yychuiyan.com")
    #expect(urls[0].path == "/api/v1/cms-candidates.json")
    #expect(urls[1].host == "firepick-1302621537.cos.ap-shanghai.myqcloud.com")
    #expect(urls[2].host == "sources.yychuiyan.com")
    #expect(urls.allSatisfy { !$0.path.contains("/firepick/sources/cms-candidates.json") })
  }

  @Test
  func bestCatalogPrefersOwnAPIThenMonitorSources() {
    let urls = CMSProviderCatalog.defaultRemoteBestURLs

    #expect(urls.count == 3)
    #expect(urls[0].host == "sources.yychuiyan.com")
    #expect(urls[0].path == "/api/v1/best.json")
    #expect(urls[1].host == "firepick-1302621537.cos.ap-shanghai.myqcloud.com")
    #expect(urls[0].lastPathComponent == "best.json")
    #expect(urls[2].host == "sources.yychuiyan.com")
    #expect(urls[2].lastPathComponent == "best.json")
  }

  @Test
  func probePoolUsesBestThenOnlineCatalogBeforeFallbacks() {
    let entries = [
      CMSProviderCatalog.Entry(
        key: "best",
        name: "Best",
        api: "https://best.example/api.php/provide/vod"
      ),
      CMSProviderCatalog.Entry(
        key: "catalog",
        name: "Catalog",
        api: "https://catalog.example/api.php/provide/vod"
      ),
      CMSProviderCatalog.Entry(
        key: "best-mirror",
        name: "Mirror",
        api: "https://best.example/mirror/api.php/provide/vod"
      ),
      CMSProviderCatalog.Entry(
        key: "saved",
        name: "Saved",
        api: "https://saved.example/api.php/provide/vod"
      ),
    ]
    let pool = CMSProviderCatalog.prioritizedCandidates(
      best: [entries[0]],
      catalog: [entries[2], entries[1]],
      fallback: [entries[3]],
      limit: 3
    )

    #expect(pool.map(\.key) == ["best", "catalog", "saved"])
  }
}
