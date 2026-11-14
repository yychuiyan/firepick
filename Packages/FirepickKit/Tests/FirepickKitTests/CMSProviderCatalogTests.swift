import Foundation
import Testing

@testable import FirepickProvider

@Suite("CMSProviderCatalogTests")
struct CMSProviderCatalogTests {
  @Test
  func bundledCatalogContainsUsableUniqueProviders() {
    let entries = CMSProviderCatalog.bundledCandidates()
    #expect(entries.count >= 50)
    #expect(Set(entries.map(\.key)).count == entries.count)
    #expect(entries.allSatisfy { !$0.key.isEmpty && !$0.name.isEmpty })
    #expect(
      entries.allSatisfy {
        guard let url = URL(string: $0.api) else { return false }
        return url.scheme == "https" && url.host != nil
      }
    )
  }
}
