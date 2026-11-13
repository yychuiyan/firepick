import SwiftUI
import UIKit

enum RemoteImageCache {
  private final class MemoryBox: @unchecked Sendable {
    let cache = NSCache<NSURL, UIImage>()
  }

  private static let memoryBox = MemoryBox()

  static func cachedImage(for url: URL) -> UIImage? {
    memoryBox.cache.object(forKey: url as NSURL)
  }

  static func store(_ image: UIImage, for url: URL) {
    memoryBox.cache.setObject(image, forKey: url as NSURL)
  }

  static func clear() {
    memoryBox.cache.removeAllObjects()
    session.configuration.urlCache?.removeAllCachedResponses()
  }

  static let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = URLCache(
      memoryCapacity: 64 * 1024 * 1024,
      diskCapacity: 256 * 1024 * 1024
    )
    configuration.requestCachePolicy = .returnCacheDataElseLoad
    return URLSession(configuration: configuration)
  }()
}

struct CachedRemoteImage<Placeholder: View>: View {
  let url: URL?
  @ViewBuilder var placeholder: () -> Placeholder

  @State private var image: UIImage?

  var body: some View {
    Group {
      if let image {
        Image(uiImage: image)
          .resizable()
      } else {
        placeholder()
      }
    }
    .task(id: url?.absoluteString) {
      await load()
    }
  }

  private func load() async {
    guard let url else {
      image = nil
      return
    }
    if let cached = RemoteImageCache.cachedImage(for: url) {
      image = cached
      return
    }
    do {
      let (data, response) = try await RemoteImageCache.session.data(from: url)
      guard let http = response as? HTTPURLResponse,
        (200..<300).contains(http.statusCode),
        let loaded = UIImage(data: data)
      else {
        return
      }
      RemoteImageCache.store(loaded, for: url)
      image = loaded
    } catch {
      // Keep placeholder on failure; scrolling can retry via task(id:).
    }
  }
}
