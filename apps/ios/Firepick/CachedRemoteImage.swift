import CryptoKit
import FirepickCore
import ImageIO
import SwiftUI
import UIKit

private struct ImageBox: @unchecked Sendable {
  let image: UIImage?
}

private actor AsyncImageGate {
  private let limit: Int
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func acquire() async {
    if active < limit {
      active += 1
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    if waiters.isEmpty {
      active = max(0, active - 1)
    } else {
      waiters.removeFirst().resume()
    }
  }
}

private actor RemoteImageDiskCache {
  static let shared = RemoteImageDiskCache()

  private static let maximumBytes: Int64 = 256 * 1024 * 1024
  private static let trimInterval = 24
  private let directory: URL?
  private var writesSinceTrim = 0
  private var didInitialTrim = false

  init() {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    let url = caches?.appendingPathComponent("FirepickPosterCache", isDirectory: true)
    if let url {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    directory = url
  }

  func data(for key: String) -> Data? {
    guard let file = fileURL(for: key),
      let data = try? Data(contentsOf: file, options: .mappedIfSafe)
    else {
      return nil
    }
    try? FileManager.default.setAttributes(
      [.modificationDate: Date()],
      ofItemAtPath: file.path
    )
    return data
  }

  func store(_ data: Data, for key: String) {
    guard let directory else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(key + ".img", isDirectory: false)
    try? data.write(to: file, options: .atomic)
    if !didInitialTrim {
      didInitialTrim = true
      trimToLimit()
      return
    }
    writesSinceTrim += 1
    if writesSinceTrim >= Self.trimInterval {
      writesSinceTrim = 0
      trimToLimit()
    }
  }

  func clear() {
    guard let directory else { return }
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    writesSinceTrim = 0
  }

  func sizeBytes() -> Int64 {
    directorySize() ?? 0
  }

  private func fileURL(for key: String) -> URL? {
    directory?.appendingPathComponent(key + ".img", isDirectory: false)
  }

  private func directorySize() -> Int64? {
    guard let directory else { return nil }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else {
      return nil
    }
    var total: Int64 = 0
    for case let url as URL in enumerator {
      if let values = try? url.resourceValues(forKeys: keys),
        values.isRegularFile == true
      {
        total += Int64(values.fileSize ?? 0)
      }
    }
    return total
  }

  private func trimToLimit() {
    guard let directory,
      let total = directorySize(),
      total > Self.maximumBytes
    else {
      return
    }
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey,
      .fileSizeKey,
      .contentModificationDateKey,
    ]
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }
    var entries: [(url: URL, bytes: Int64, date: Date)] = files.compactMap { url in
      guard let values = try? url.resourceValues(forKeys: keys),
        values.isRegularFile == true
      else {
        return nil
      }
      return (
        url,
        Int64(values.fileSize ?? 0),
        values.contentModificationDate ?? .distantPast
      )
    }
    entries.sort { $0.date < $1.date }
    var remaining = total
    for entry in entries where remaining > Self.maximumBytes {
      do {
        try FileManager.default.removeItem(at: entry.url)
        remaining -= entry.bytes
      } catch {}
    }
  }
}

enum RemoteImageCache {
  private final class MemoryBox: @unchecked Sendable {
    let cache: NSCache<NSString, UIImage> = {
      let cache = NSCache<NSString, UIImage>()
      cache.countLimit = 400
      cache.totalCostLimit = 96 * 1024 * 1024
      return cache
    }()
  }

  private static let memoryBox = MemoryBox()

  static func cacheKey(for url: URL, maxPixelSize: CGFloat) -> String {
    let bucket = pixelBucket(maxPixelSize)
    let normalized = normalizedURLString(url) + "|\(bucket)"
    return digest(normalized)
  }

  static func legacyCacheKey(for url: URL) -> String {
    digest(normalizedURLString(url))
  }

  private static func digest(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func pixelBucket(_ value: CGFloat) -> Int {
    let clamped = min(1_600, max(64, value))
    return Int((clamped + 63) / 64) * 64
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

  /// Most CMS covers now support HTTPS; upgrading first avoids an extra 301.
  static func preferredTransportURL(_ url: URL) -> URL {
    guard url.scheme?.lowercased() == "http",
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return url }
    components.scheme = "https"
    return components.url ?? url
  }

  /// SwiftUI rendering may only read memory. Disk work stays on the image actor.
  static func memoryImage(for url: URL, maxPixelSize: CGFloat) -> UIImage? {
    let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
    return memoryBox.cache.object(forKey: key as NSString)
  }

  static func storeMemory(_ image: UIImage, for key: String) {
    memoryBox.cache.setObject(image, forKey: key as NSString, cost: image.cacheCost)
  }

  static func queueDiskWrite(_ image: UIImage, for key: String) {
    let box = ImageBox(image: image)
    Task.detached(priority: .utility) {
      guard let data = box.image?.jpegData(compressionQuality: 0.84) else { return }
      await RemoteImageDiskCache.shared.store(data, for: key)
    }
  }

  static func diskImage(for key: String, maxPixelSize: CGFloat) async -> UIImage? {
    guard let data = await RemoteImageDiskCache.shared.data(for: key) else { return nil }
    let box = await Task.detached(priority: .userInitiated) {
      ImageBox(image: decode(data, maxPixelSize: maxPixelSize))
    }.value
    return box.image
  }

  static func clear() {
    memoryBox.cache.removeAllObjects()
    session.configuration.urlCache?.removeAllCachedResponses()
    Task {
      await RemoteImageDiskCache.shared.clear()
    }
  }

  static let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = URLCache(
      memoryCapacity: 16 * 1024 * 1024,
      diskCapacity: 128 * 1024 * 1024
    )
    configuration.requestCachePolicy = .returnCacheDataElseLoad
    configuration.timeoutIntervalForRequest = 10
    configuration.httpMaximumConnectionsPerHost = 8
    configuration.waitsForConnectivity = false
    configuration.httpAdditionalHeaders = [
      "Accept": "image/*,*/*;q=0.8",
      "User-Agent":
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
    ]
    return URLSession(configuration: configuration)
  }()

  fileprivate static func decode(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: pixelBucket(maxPixelSize),
    ]
    if let thumbnail = CGImageSourceCreateThumbnailAtIndex(
      source,
      0,
      options as CFDictionary
    ) {
      return UIImage(cgImage: thumbnail, scale: 1, orientation: .up)
    }
    return UIImage(data: data)
  }
}

enum PosterPrefetch {
  /// Warm memory/disk cache for the first-screen posters so LazyVGrid does not wait serial.
  static func warm(urls: [URL?], maxPixelSize: CGFloat = 720, limit: Int = 12) {
    let targets = urls.compactMap { $0 }.prefix(limit)
    guard !targets.isEmpty else { return }
    Task(priority: .utility) {
      await withTaskGroup(of: Void.self) { group in
        for url in targets {
          group.addTask {
            _ = await RemoteImagePipeline.shared.image(for: url, maxPixelSize: maxPixelSize)
          }
        }
      }
    }
  }

  static func warm(items: [MediaItem], maxPixelSize: CGFloat = 720, limit: Int = 12) {
    warm(
      urls: items.map { RemoteImageCache.normalizedURL(from: $0.pic) },
      maxPixelSize: maxPixelSize,
      limit: limit
    )
  }
}

private actor RemoteImagePipeline {
  static let shared = RemoteImagePipeline()

  private struct Request: Sendable {
    let url: URL
    let maxPixelSize: CGFloat
  }

  private enum AttemptResult {
    case loaded(ImageBox)
    case retryWithReferer
    case failed
  }

  private let gate = AsyncImageGate(limit: 8)
  private var inFlight: [String: Task<ImageBox, Never>] = [:]

  func image(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
    let bucket = CGFloat(RemoteImageCache.pixelBucket(maxPixelSize))
    if let cached = RemoteImageCache.memoryImage(for: url, maxPixelSize: bucket) {
      return cached
    }
    let key = RemoteImageCache.cacheKey(for: url, maxPixelSize: bucket)
    if let task = inFlight[key] {
      return await task.value.image
    }
    let request = Request(url: url, maxPixelSize: bucket)
    let task = Task<ImageBox, Never> {
      await self.gate.acquire()
      let box = await Self.fetch(request, key: key)
      await self.gate.release()
      return box
    }
    inFlight[key] = task
    let result = await task.value
    inFlight.removeValue(forKey: key)
    return result.image
  }

  private nonisolated static func fetch(_ request: Request, key: String) async -> ImageBox {
    if let cached = await RemoteImageCache.diskImage(
      for: key,
      maxPixelSize: request.maxPixelSize
    ) {
      return ImageBox(image: cached)
    }

    // Reuse the old full-size cache once, then migrate it to the display-sized key.
    let legacyKey = RemoteImageCache.legacyCacheKey(for: request.url)
    if let legacy = await RemoteImageCache.diskImage(
      for: legacyKey,
      maxPixelSize: request.maxPixelSize
    ) {
      RemoteImageCache.storeMemory(legacy, for: key)
      RemoteImageCache.queueDiskWrite(legacy, for: key)
      return ImageBox(image: legacy)
    }

    let preferred = RemoteImageCache.preferredTransportURL(request.url)
    let networkURLs = preferred == request.url ? [request.url] : [preferred, request.url]
    for (urlIndex, networkURL) in networkURLs.enumerated() {
      var result = await attempt(
        url: networkURL,
        referer: nil,
        maxPixelSize: request.maxPixelSize
      )
      if case .retryWithReferer = result {
        result = await attempt(
          url: networkURL,
          referer: "https://\(networkURL.host ?? "")/",
          maxPixelSize: request.maxPixelSize
        )
      }
      if case .loaded(let box) = result, let loaded = box.image {
        RemoteImageCache.storeMemory(loaded, for: key)
        RemoteImageCache.queueDiskWrite(loaded, for: key)
        return box
      }
      if urlIndex == 0, networkURLs.count > 1 {
        try? await Task.sleep(for: .milliseconds(120))
      }
    }
    return ImageBox(image: nil)
  }

  private nonisolated static func attempt(
    url: URL,
    referer: String?,
    maxPixelSize: CGFloat
  ) async -> AttemptResult {
    var request = URLRequest(
      url: url,
      cachePolicy: referer == nil
        ? .returnCacheDataElseLoad : .reloadIgnoringLocalCacheData,
      timeoutInterval: 7
    )
    if let referer {
      request.setValue(referer, forHTTPHeaderField: "Referer")
    }
    do {
      let (data, response) = try await RemoteImageCache.session.data(for: request)
      guard let http = response as? HTTPURLResponse else { return .failed }
      if (200..<300).contains(http.statusCode) {
        let box = await Task.detached(priority: .userInitiated) {
          ImageBox(image: RemoteImageCache.decode(data, maxPixelSize: maxPixelSize))
        }.value
        return box.image == nil ? .failed : .loaded(box)
      }
      // A timeout usually means the route itself is slow; retrying the same host
      // with a Referer only extends first-screen occupancy. Hotlink hosts reject
      // quickly with 4xx and can cheaply try the alternate header.
      return (400..<500).contains(http.statusCode) ? .retryWithReferer : .failed
    } catch {
      return .failed
    }
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
  var maxPixelSize: CGFloat = 720
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
    .onChange(of: url?.absoluteString) { _, _ in
      image = nil
      failed = false
    }
    .task(id: "\(url?.absoluteString ?? "")|\(maxPixelSize)|\(reloadToken)") {
      await load()
    }
  }

  /// Only the thread-safe memory cache is consulted on the render path.
  private var displayedImage: UIImage? {
    if let image { return image }
    guard let url else { return nil }
    return RemoteImageCache.memoryImage(for: url, maxPixelSize: maxPixelSize)
  }

  private func load() async {
    guard let url else {
      image = nil
      failed = false
      return
    }
    if let cached = RemoteImageCache.memoryImage(for: url, maxPixelSize: maxPixelSize) {
      image = cached
      failed = false
      return
    }
    let loaded = await RemoteImagePipeline.shared.image(
      for: url,
      maxPixelSize: maxPixelSize
    )
    guard !Task.isCancelled else { return }
    image = loaded
    failed = loaded == nil
  }
}
