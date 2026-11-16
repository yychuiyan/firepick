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
  func bundledCatalogIncludesNewNiubihuProviders() {
    let entries = CMSProviderCatalog.bundledCandidates()
    let keys = Set(entries.map(\.key))

    #expect(keys.isSuperset(of: ["nb_modu", "nb_xgzy", "nb_dzzy", "nb_ikun"]))
    #expect(
      CMSProviderCatalog.displayName(
        for: CMSProviderCatalog.Entry(
          key: "nb_xgzy",
          name: "西瓜资源",
          api: "https://xiguazy.tv/api.php/provide/vod"
        )
      ) == "西瓜"
    )
  }

  @Test
  func curatedCandidatesLeadTheProbePool() {
    #expect(
      CMSProviderCatalog.curatedCandidates().map(\.key)
        == ["nb_modu", "nb_xgzy", "nb_dzzy", "nb_ikun"]
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

  @Test
  func activePoolLimitsScaleOnlyInAdultMode() {
    #expect(CMSProviderCatalog.activePoolLimit(adultMode: false) == 10)
    #expect(CMSProviderCatalog.activePoolLimit(adultMode: true) == 20)
    #expect(CMSProviderCatalog.candidatePoolLimit(adultMode: false) == 30)
    #expect(CMSProviderCatalog.candidatePoolLimit(adultMode: true) == 40)
  }

  @Test
  func adultPoolReservesAdultAndNormalProviders() {
    let adults = (0..<6).map { index in
      CMSProviderCatalog.Entry(
        key: "adult-\(index)",
        name: "Adult \(index)",
        api: "https://adult-\(index).example/api.php/provide/vod",
        adult: true
      )
    }
    let normals = (0..<24).map { index in
      CMSProviderCatalog.Entry(
        key: "normal-\(index)",
        name: "Normal \(index)",
        api: "https://normal-\(index).example/api.php/provide/vod"
      )
    }
    let pool = CMSProviderCatalog.balancedActivePool(
      primary: adults + normals,
      fallback: [],
      adultMode: true,
      limit: 20,
      minimumAdult: 4
    )

    #expect(pool.count == 20)
    #expect(pool.prefix(4).allSatisfy { $0.adult != true })
    #expect(pool.filter { $0.adult == true }.count == 4)
    #expect(pool.filter { $0.adult != true }.count == 16)
  }

  @Test
  func standardPoolExcludesAdultAndDeduplicatesMirrors() {
    let entries = [
      CMSProviderCatalog.Entry(
        key: "adult",
        name: "Adult",
        api: "https://adult.example/api.php/provide/vod",
        adult: true
      ),
      CMSProviderCatalog.Entry(
        key: "normal",
        name: "Normal",
        api: "https://normal.example/api.php/provide/vod"
      ),
      CMSProviderCatalog.Entry(
        key: "normal-mirror",
        name: "Normal Mirror",
        api: "https://normal.example/mirror/api.php/provide/vod"
      ),
    ]
    let pool = CMSProviderCatalog.balancedActivePool(
      primary: entries,
      fallback: [],
      adultMode: false,
      limit: 10
    )

    #expect(pool.map(\.key) == ["normal"])
  }
}
