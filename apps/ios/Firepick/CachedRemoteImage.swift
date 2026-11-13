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
  @State private var failed = false
  @State private var reloadToken = 0

  var body: some View {
    Group {
      if let image {
        Image(uiImage: image)
          .resizable()
      } else if failed {
        placeholder()
          .overlay {
            Button {
              failed = false
              reloadToken += 1
            } label: {
              Image(systemName: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
          }
      } else {
        placeholder()
      }
    }
    .task(id: "\(url?.absoluteString ?? "")|\(reloadToken)") {
      await load()
    }
  }

  private func load() async {
    guard let url else {
      image = nil
      failed = false
      return
    }
    if let cached = RemoteImageCache.cachedImage(for: url) {
      image = cached
      failed = false
      return
    }
    do {
      let (data, response) = try await RemoteImageCache.session.data(from: url)
      guard let http = response as? HTTPURLResponse,
        (200..<300).contains(http.statusCode),
        let loaded = UIImage(data: data)
      else {
        failed = true
        return
      }
      RemoteImageCache.store(loaded, for: url)
      image = loaded
      failed = false
    } catch {
      failed = true
    }
  }
}
