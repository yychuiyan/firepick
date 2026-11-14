import CryptoKit
import SwiftUI
import UIKit

enum RemoteImageCache {
  private final class MemoryBox: @unchecked Sendable {
    let cache: NSCache<NSString, UIImage> = {
      let cache = NSCache<NSString, UIImage>()
      cache.countLimit = 400
      cache.totalCostLimit = 128 * 1024 * 1024
      return cache
    }()
  }

  private static let memoryBox = MemoryBox()
  private static let diskFolderName = "FirepickPosterCache"
  private static let ioQueue = DispatchQueue(label: "firepick.poster-cache", qos: .utility)

  private static var diskDirectory: URL? {
    guard
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    let dir = caches.appendingPathComponent(diskFolderName, isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path) {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
  }

  static func cacheKey(for url: URL) -> String {
    let normalized = normalizedURLString(url)
    let digest = SHA256.hash(data: Data(normalized.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func normalizedURLString(_ url: URL) -> String {
    var string = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
    // Collapse accidental spaces in CMS pic fields.
    string = string.replacingOccurrences(of: " ", with: "%20")
    return string
  }

  static func normalizedURL(from raw: String?) -> URL? {
    guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      return nil
    }
    text = text.replacingOccurrences(of: " ", with: "%20")
    if let url = URL(string: text) { return url }
    return text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
      .flatMap(URL.init(string:))
  }

  static func cachedImage(for url: URL) -> UIImage? {
    let key = cacheKey(for: url)
    if let memory = memoryBox.cache.object(forKey: key as NSString) {
      return memory
    }
    if let disk = readDisk(key: key) {
      memoryBox.cache.setObject(disk, forKey: key as NSString, cost: disk.cacheCost)
      return disk
    }
    return nil
  }

  static func store(_ image: UIImage, for url: URL, data: Data? = nil) {
    let key = cacheKey(for: url)
    memoryBox.cache.setObject(image, forKey: key as NSString, cost: image.cacheCost)
    let payload = data ?? image.jpegData(compressionQuality: 0.92) ?? image.pngData()
    guard let payload else { return }
    ioQueue.async {
      writeDisk(key: key, data: payload)
    }
  }

  static func clear() {
    memoryBox.cache.removeAllObjects()
    session.configuration.urlCache?.removeAllCachedResponses()
    if let dir = diskDirectory {
      try? FileManager.default.removeItem(at: dir)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }

  static let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = URLCache(
      memoryCapacity: 64 * 1024 * 1024,
      diskCapacity: 512 * 1024 * 1024
    )
    configuration.requestCachePolicy = .returnCacheDataElseLoad
    configuration.timeoutIntervalForRequest = 20
    configuration.httpAdditionalHeaders = [
      "Accept": "image/*,*/*;q=0.8",
      "User-Agent":
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
    ]
    return URLSession(configuration: configuration)
  }()

  private static func diskURL(key: String) -> URL? {
    diskDirectory?.appendingPathComponent(key + ".img", isDirectory: false)
  }

  private static func readDisk(key: String) -> UIImage? {
    guard let file = diskURL(key: key),
      let data = try? Data(contentsOf: file),
      let image = UIImage(data: data)
    else { return nil }
    return image
  }

  private static func writeDisk(key: String, data: Data) {
    guard let file = diskURL(key: key) else { return }
    try? data.write(to: file, options: [.atomic])
  }
}

private extension UIImage {
  var cacheCost: Int {
    let area = Int(size.width * size.height * scale * scale)
    return max(1, area * 4)
  }
}

struct CachedRemoteImage<Placeholder: View>: View {
  let url: URL?
  @ViewBuilder var placeholder: () -> Placeholder

  @State private var image: UIImage?
  @State private var failed = false
  @State private var reloadToken = 0

  var body: some View {
    Group {
      if let image = displayedImage {
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

  /// Sync memory/disk hit — avoid one frame of shimmer on every page revisit.
  private var displayedImage: UIImage? {
    if let image { return image }
    guard let url else { return nil }
    return RemoteImageCache.cachedImage(for: url)
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
      var request = URLRequest(
        url: url,
        cachePolicy: .returnCacheDataElseLoad,
        timeoutInterval: 20
      )
      if let host = url.host, !host.isEmpty {
        request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
      }
      let (data, response) = try await RemoteImageCache.session.data(for: request)
      guard let http = response as? HTTPURLResponse,
        (200..<300).contains(http.statusCode),
        let loaded = UIImage(data: data)
      else {
        failed = true
        return
      }
      RemoteImageCache.store(loaded, for: url, data: data)
      image = loaded
      failed = false
    } catch {
      // One retry without Referer — some CDNs reject hotlink headers.
      do {
        let (data, response) = try await RemoteImageCache.session.data(from: url)
        guard let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode),
          let loaded = UIImage(data: data)
        else {
          failed = true
          return
        }
        RemoteImageCache.store(loaded, for: url, data: data)
        image = loaded
        failed = false
      } catch {
        failed = true
      }
    }
  }
}
