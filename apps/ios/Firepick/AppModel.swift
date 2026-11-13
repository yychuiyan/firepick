import FirepickBridge
import FirepickCore
import FirepickPlayback
import FirepickProvider
import Foundation
import Observation

struct SourceConnection: Codable, Identifiable, Equatable {
  var url: String
  var name: String
  var updatedAt: Date
  var displayURL: String?

  var id: String { url }
  var displayAddress: String {
    SourceAddress.displayURL(displayURL ?? url)
  }
}

@MainActor
@Observable
final class AppModel {
  enum Tab: Hashable {
    case vod
    case live
    case settings
  }

  enum PlaybackPreference: String, CaseIterable, Identifiable {
    case automatic
    case avPlayer
    case mpv

    var id: String { rawValue }

    var title: String {
      switch self {
      case .automatic: "自动"
      case .avPlayer: "AVPlayer"
      case .mpv: "MPV"
      }
    }

    var engine: PlaybackEngineKind? {
      switch self {
      case .automatic: nil
      case .avPlayer: .avPlayer
      case .mpv: .mpv
      }
    }
  }

  enum PosterSizePreference: String, CaseIterable, Identifiable {
    case compact
    case standard
    case large

    var id: String { rawValue }

    var title: String {
      switch self {
      case .compact: "紧凑"
      case .standard: "标准"
      case .large: "大图"
      }
    }

    var minimumWidth: CGFloat {
      switch self {
      case .compact: 108
      case .standard: 132
      case .large: 168
      }
    }
  }

  struct SearchSection: Identifiable {
    let id: String
    let siteName: String
    let result: MediaResult
  }

  struct ConfigurationCandidate: Identifiable, Equatable {
    var url: URL
    var id: String { url.absoluteString }
  }

  struct SourceRouteCount: Identifiable {
    let runtime: ProviderRuntime
    let count: Int

    var id: ProviderRuntime { runtime }
  }

  var selectedTab: Tab = .vod
  var configuration: VodConfiguration = .empty
  var selectedSite: SiteConfiguration?
  var selectedCategory: FirepickCore.Category?
  var homeResult: MediaResult?
  var detailResult: MediaResult?
  var categoryFilters: [SourceFilter] = []
  var filterSelections: [String: String] = [:]
  var currentPage = 1
  var isLoadingMore = false
  var searchSections: [SearchSection] = []
  var liveSearchResults: [LiveChannel] = []
  var searchText = ""
  var searchHasRun = false
  var searchHistory: [String] = []
  var searchFailureCount = 0
  var isLoading = false
  var errorMessage: String?
  var history: [HistoryEntry] = []
  var favorites: [FavoriteEntry] = []
  var bridgeHealth: BridgeHealth?
  var availableDepots: [ConfigurationDepot] = []
  var configurationCandidates: [ConfigurationCandidate] = []
  var sourceConnections: [SourceConnection] = []
  var currentConnection: SourceConnection?
  var liveGroups: [LiveGroup] = []
  var epgPrograms: [String: [LiveProgram]] = [:]
  var epgStatus: String?
  var liveRefreshStatus: String?
  var debugPlaybackRequest: PlaybackRequest?
  var debugPlaybackItem: MediaItem?
  var debugPlaybackEpisode: Episode?
  var sourceTestStatus: String?
  var sourceTestIsRunning = false
  var playbackPreference: PlaybackPreference = .automatic
  var posterSizePreference: PosterSizePreference = .standard
  var danmakuEnabledByDefault = true
  var danmakuOpacity = 0.9
  var danmakuFontScale = 1.0
  var danmakuSpeed = 1.0
  var cacheStatus: String?
  var cacheSizeText = "计算中"
  private var configDigest = ""
  private var configurationBaseURL: URL?
  private var pendingInitialSiteKey: String?
  private var loadedEPGSources: Set<String> = []
  private var loadingEPGSources: Set<String> = []

  private var coordinator: ProviderCoordinator?
  private var library: LibraryStore?
  var downloads: DownloadManager?
  private var persistence: AppPersistence?
  private var bridgeClient: BridgeClient?
  private let router = SourceRouter()
  private let configurationSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration)
  }()

  func bootstrap() async {
    do {
      library = try LibraryStore()
      downloads = try DownloadManager()
      persistence = try AppPersistence()
      loadPreferences()
      try await refreshLibrary()
    } catch {
      errorMessage = error.localizedDescription
    }

    #if DEBUG
      let environment = ProcessInfo.processInfo.environment
      let hasTestConfiguration = !(environment["FIREPICK_TEST_CONFIG_URL"] ?? "").isEmpty
      let hasTestBridge = !(environment["FIREPICK_TEST_BRIDGE_URI"] ?? "").isEmpty
      if !hasTestConfiguration, !hasTestBridge {
        await restorePersistentState()
      } else {
        if configuration.sites.isEmpty {
          loadEmptyConfiguration()
        }
        if let testURL = environment["FIREPICK_TEST_CONFIG_URL"], !testURL.isEmpty {
          await applyConfiguration(urlString: testURL, selectInitialSite: false)
        }
        if let bridgeURI = environment["FIREPICK_TEST_BRIDGE_URI"], !bridgeURI.isEmpty {
          await pairBridge(uriString: bridgeURI)
        } else if bridgeClient == nil,
          let credentials = try? persistence?.loadBridgeCredentials()
        {
          await configureBridge(credentials: credentials)
        }
        await selectPendingInitialSite()
      }

      if let testSiteKey = environment["FIREPICK_TEST_SITE_KEY"],
        let site = configuration.sites.first(where: { $0.key == testSiteKey })
      {
        await selectSite(site)
        if environment["FIREPICK_TEST_AUTO_PLAY"] == "1" {
          await autoPlayFirstAvailable()
        }
      }
      if let mediaURL = environment["FIREPICK_TEST_MEDIA_URL"],
        let url = URL(string: mediaURL)
      {
        debugPlaybackRequest = PlaybackRequest(url: url, formatHint: mediaURL)
        debugPlaybackItem = MediaItem(
          vodId: "test-media",
          name: "TVAPP 直播源验证",
          sourceKey: "live"
        )
        debugPlaybackEpisode = Episode(name: "CGTN", value: mediaURL)
      }
      switch environment["FIREPICK_TEST_TAB"] {
      case "vod":
        selectedTab = .vod
      case "live":
        selectedTab = .live
      case "settings":
        selectedTab = .settings
      default:
        break
      }
    #else
      await restorePersistentState()
    #endif
  }

  private func loadPreferences() {
    if let raw = persistence?.playbackPreference,
      let value = PlaybackPreference(rawValue: raw)
    {
      playbackPreference = value
    }
    if let raw = persistence?.posterSizePreference,
      let value = PosterSizePreference(rawValue: raw)
    {
      posterSizePreference = value
    }
    if let value = persistence?.danmakuEnabledByDefault {
      danmakuEnabledByDefault = value
    }
    if let value = persistence?.danmakuOpacity {
      danmakuOpacity = min(1, max(0.2, value))
    }
    if let value = persistence?.danmakuFontScale {
      danmakuFontScale = min(1.75, max(0.75, value))
    }
    if let value = persistence?.danmakuSpeed {
      danmakuSpeed = min(2, max(0.5, value))
    }
    sourceConnections = (try? persistence?.loadSourceConnections()) ?? []
    searchHistory = persistence?.searchHistory ?? []
    if let currentURL = persistence?.currentConnectionURL {
      currentConnection = sourceConnections.first { $0.url == currentURL }
    }
    refreshCacheSize()
  }

  func loadConnection(_ connection: SourceConnection) async {
    if await applyConfiguration(
      urlString: connection.url,
      displayURL: connection.displayAddress
    ) {
      currentConnection = connection
    }
  }

  func removeConnection(_ connection: SourceConnection) {
    sourceConnections.removeAll { $0.id == connection.id }
    if currentConnection?.id == connection.id {
      currentConnection = nil
      persistence?.saveCurrentConnectionURL(nil)
    }
    try? persistence?.saveSourceConnections(sourceConnections)
  }

  private func recordConnection(url: URL, displayURL: String? = nil) {
    let existing = sourceConnections.first { $0.url == url.absoluteString }
    let connection = SourceConnection(
      url: url.absoluteString,
      name: url.host ?? url.absoluteString,
      updatedAt: .now,
      displayURL: displayURL ?? existing?.displayURL
    )
    sourceConnections.removeAll { $0.url == connection.url }
    sourceConnections.insert(connection, at: 0)
    currentConnection = connection
    try? persistence?.saveSourceConnections(sourceConnections)
    persistence?.saveCurrentConnectionURL(connection.url)
  }

  func setPlaybackPreference(_ value: PlaybackPreference) {
    playbackPreference = value
    persistence?.savePlaybackPreference(value.rawValue)
  }

  func setPosterSizePreference(_ value: PosterSizePreference) {
    posterSizePreference = value
    persistence?.savePosterSizePreference(value.rawValue)
  }

  func setDanmakuEnabledByDefault(_ value: Bool) {
    danmakuEnabledByDefault = value
    persistence?.saveDanmakuEnabledByDefault(value)
  }

  func setDanmakuOpacity(_ value: Double) {
    danmakuOpacity = min(1, max(0.2, value))
    persistence?.saveDanmakuOpacity(danmakuOpacity)
  }

  func setDanmakuFontScale(_ value: Double) {
    danmakuFontScale = min(1.75, max(0.75, value))
    persistence?.saveDanmakuFontScale(danmakuFontScale)
  }

  func setDanmakuSpeed(_ value: Double) {
    danmakuSpeed = min(2, max(0.5, value))
    persistence?.saveDanmakuSpeed(danmakuSpeed)
  }

  func resetDanmakuSettings() {
    setDanmakuEnabledByDefault(true)
    setDanmakuOpacity(0.9)
    setDanmakuFontScale(1)
    setDanmakuSpeed(1)
  }

  func recordSearchHistory(_ keyword: String) {
    let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    searchHistory.removeAll {
      $0.caseInsensitiveCompare(value) == .orderedSame
    }
    searchHistory.insert(value, at: 0)
    searchHistory = Array(searchHistory.prefix(20))
    persistence?.saveSearchHistory(searchHistory)
  }

  func removeSearchHistory(_ values: Set<String>) {
    guard !values.isEmpty else { return }
    searchHistory.removeAll { values.contains($0) }
    persistence?.saveSearchHistory(searchHistory)
  }

  func clearCache() {
    URLCache.shared.removeAllCachedResponses()
    if let cacheDirectory = FileManager.default.urls(
      for: .cachesDirectory,
      in: .userDomainMask
    ).first,
      let contents = try? FileManager.default.contentsOfDirectory(
        at: cacheDirectory,
        includingPropertiesForKeys: nil
      )
    {
      for item in contents {
        try? FileManager.default.removeItem(at: item)
      }
    }
    cacheStatus = "缓存已清理"
    cacheSizeText = "0 KB"
  }

  func refreshCacheSize() {
    guard
      let cacheDirectory = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      ).first
    else {
      cacheSizeText = "未知"
      return
    }
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    var total: Int64 = 0
    if let enumerator = FileManager.default.enumerator(
      at: cacheDirectory,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles]
    ) {
      for case let url as URL in enumerator {
        if let values = try? url.resourceValues(forKeys: Set(keys)),
          values.isRegularFile == true
        {
          total += Int64(values.fileSize ?? 0)
        }
      }
    }
    cacheSizeText = ByteCountFormatter.string(
      fromByteCount: total,
      countStyle: .file
    )
  }

  @discardableResult
  func applyConfiguration(
    urlString: String,
    selectInitialSite: Bool = true,
    displayURL: String? = nil
  ) async -> Bool {
    guard let url = normalizedConfigurationURL(urlString) else {
      errorMessage = "配置地址无效"
      return false
    }
    isLoading = true
    defer { isLoading = false }
    var responseDescription = ""
    do {
      let downloaded = try await downloadConfiguration(from: url)
      responseDescription = downloaded.description
      try await applyConfiguration(
        ConfigurationDecoder.normalize(downloaded.data),
        baseURL: downloaded.url,
        selectInitialSite: selectInitialSite
      )
      recordConnection(url: url, displayURL: displayURL ?? urlString)
      configurationCandidates = []
      return true
    } catch {
      if responseDescription.isEmpty {
        errorMessage = error.localizedDescription
      } else {
        errorMessage = "\(error.localizedDescription)\n\n\(responseDescription)"
      }
      return false
    }
  }

  private struct DownloadedConfiguration {
    var data: Data
    var url: URL
    var description: String
  }

  private func downloadConfiguration(from url: URL) async throws -> DownloadedConfiguration {
    let directFailure: Error?
    let direct = try? await requestConfiguration(
      url,
      userAgent: "okhttp/4.1.0",
      accept: "*/*"
    )
    if let direct, isConfigurationPayload(direct.data) {
      return direct
    }
    directFailure = directFailureFor(url: url, direct: direct)

    let browser: DownloadedConfiguration
    do {
      browser = try await requestConfiguration(
        url,
        userAgent:
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36",
        accept: "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8"
      )
    } catch {
      throw directFailure ?? error
    }

    if isConfigurationPayload(browser.data) {
      return browser
    }

    var candidates = ConfigurationLandingPage.candidateURLs(
      from: browser.data,
      baseURL: browser.url
    )
    var seen = Set<String>()
    candidates = candidates.filter { seen.insert($0.absoluteString).inserted }
    for candidate in candidates {
      if let attempt = await downloadConfigurationCandidate(candidate) {
        return attempt
      }
    }

    configurationCandidates = candidates.map { ConfigurationCandidate(url: $0) }
    throw FirepickError.invalidConfiguration(
      "当前地址返回图片或导航网页，未能提取配置直链。请从页面复制原始 JSON 地址"
    )
  }

  private func requestConfiguration(
    _ url: URL,
    userAgent: String,
    accept: String
  ) async throws -> DownloadedConfiguration {
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    let (data, response) = try await configurationSession.data(for: request)
    guard let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode)
    else {
      throw FirepickError.network("配置下载失败")
    }
    return DownloadedConfiguration(
      data: data,
      url: http.url ?? url,
      description: "HTTP \(http.statusCode) · \(http.mimeType ?? "未知类型") · \(data.count) 字节"
    )
  }

  private func isImagePayload(_ data: Data) -> Bool {
    data.starts(with: [0x42, 0x4D])
      || data.starts(with: [0x89, 0x50, 0x4E, 0x47])
      || data.starts(with: [0xFF, 0xD8, 0xFF])
      || data.starts(with: Array("GIF8".utf8))
      || (data.count >= 12
        && data.prefix(4) == Data("RIFF".utf8)
        && data.dropFirst(8).prefix(4) == Data("WEBP".utf8))
  }

  private func isHTMLPayload(_ data: Data) -> Bool {
    var prefix = String(decoding: data.prefix(2_048), as: UTF8.self)
    prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    if prefix.hasPrefix("\u{FEFF}") {
      prefix.removeFirst()
      prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let lowered = prefix.lowercased()
    return lowered.hasPrefix("<!doctype html")
      || lowered.hasPrefix("<html")
      || lowered.hasPrefix("<head")
      || lowered.hasPrefix("<body")
  }

  private func isConfigurationPayload(_ data: Data) -> Bool {
    guard !data.isEmpty else { return false }
    if isImagePayload(data) {
      guard let normalized = try? ConfigurationDecoder.normalize(data) else {
        return false
      }
      return !isImagePayload(normalized) && !isHTMLPayload(normalized)
    }
    return !isHTMLPayload(data)
  }

  private func downloadConfigurationCandidate(
    _ candidate: URL
  ) async -> DownloadedConfiguration? {
    for request in [
      (
        userAgent: "okhttp/4.1.0",
        accept: "*/*"
      ),
      (
        userAgent:
          "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
        accept: "application/json,text/plain,text/html;q=0.8,*/*;q=0.5"
      ),
    ] {
      guard
        let attempt = try? await requestConfiguration(
          candidate,
          userAgent: request.userAgent,
          accept: request.accept
        ),
        isConfigurationPayload(attempt.data)
      else {
        continue
      }
      return attempt
    }
    return nil
  }

  private func normalizedConfigurationURL(_ value: String) -> URL? {
    var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if !trimmed.contains("://") {
      trimmed = "http://\(trimmed)"
    }
    guard let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      return nil
    }
    return url
  }

  private func directFailureFor(
    url: URL,
    direct: DownloadedConfiguration?
  ) -> Error? {
    guard let direct else {
      return FirepickError.network("无法连接配置地址")
    }
    if isImagePayload(direct.data) {
      return FirepickError.invalidConfiguration(
        "\(url.absoluteString) 返回了图片，正在尝试提取页面内的配置入口"
      )
    }
    return FirepickError.invalidConfiguration(
      "\(url.absoluteString) 返回了网页，正在尝试提取页面内的配置入口"
    )
  }

  func selectSite(_ site: SiteConfiguration) async {
    if !isOnDeviceCapable(site), bridgeHealth == nil {
      errorMessage =
        "「\(site.name)」需要 Android 运行时（Java/Python 等）。当前以本机 HTTP/JS 为主，请改选本机可用源，或使用自建 iOS 配置仓。"
      return
    }
    selectedSite = site
    searchSections = []
    liveSearchResults = []
    searchHasRun = false
    searchFailureCount = 0
    sourceTestStatus = nil
    selectedCategory = nil
    categoryFilters = []
    filterSelections = [:]
    currentPage = 1
    persistence?.saveSelectedSiteKey(site.key)
    homeResult = nil
    detailResult = nil
    errorMessage = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let provider = try await provider(for: site)
      var result = try await provider.homeContent()
      attachSourceKey(site.key, to: &result)
      homeResult = result
      errorMessage = nil
      if let first = homeResult?.classes.first {
        await loadCategory(first, site: site)
      }
    } catch {
      let text = error.localizedDescription
      if text.contains("Bridge") || text.contains("不可达") {
        errorMessage = "本机无法运行该源。请换用 HTTP/JS 源，或查看自建仓说明。"
      } else {
        errorMessage = text
      }
    }
  }

  func loadCategory(_ category: FirepickCore.Category, site: SiteConfiguration? = nil) async {
    guard let site = site ?? selectedSite else { return }
    let categoryChanged = selectedCategory?.typeId != category.typeId
    selectedCategory = category
    if categoryChanged {
      if let filters = homeResult?.filters?[category.typeId] {
        categoryFilters = filters
      } else {
        categoryFilters = decodedFilters(category.filters)
      }
      filterSelections = categoryFilters.reduce(into: [:]) { values, filter in
        values[filter.key] = filter.initValue ?? filter.value.first?.value ?? ""
      }
    }
    isLoading = true
    defer { isLoading = false }
    do {
      let provider = try await provider(for: site)
      var result = try await provider.categoryContent(
        typeId: category.typeId,
        page: 1,
        filter: true,
        extend: filterSelections
      )
      if result.classes.isEmpty {
        result.classes = homeResult?.classes ?? []
      }
      if result.list.isEmpty, let current = homeResult, !current.list.isEmpty {
        result.list = current.list
      }
      attachSourceKey(site.key, to: &result)
      homeResult = result
      currentPage = 1
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func selectFilter(_ filter: SourceFilter, value: FilterValue) async {
    filterSelections[filter.key] = value.value
    guard let selectedCategory else { return }
    await loadCategory(selectedCategory)
  }

  func selectedFilterName(_ filter: SourceFilter) -> String {
    let selected = filterSelections[filter.key] ?? filter.initValue
    return filter.value.first(where: { $0.value == selected })?.name
      ?? filter.name
  }

  func loadMore() async {
    guard !isLoadingMore,
      !isLoading,
      let site = selectedSite,
      let category = selectedCategory,
      let pagecount = homeResult?.pagecount,
      currentPage < pagecount
    else {
      return
    }
    isLoadingMore = true
    defer { isLoadingMore = false }
    do {
      let nextPage = currentPage + 1
      var result = try await provider(for: site).categoryContent(
        typeId: category.typeId,
        page: nextPage,
        filter: true,
        extend: filterSelections
      )
      if result.classes.isEmpty {
        result.classes = homeResult?.classes ?? []
      }
      attachSourceKey(site.key, to: &result)
      let existing = Set(homeResult?.list.map(\.id) ?? [])
      result.list =
        (homeResult?.list ?? [])
        + result.list.filter {
          !existing.contains($0.id)
        }
      homeResult = result
      currentPage = nextPage
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func openFolder(_ item: MediaItem) async {
    guard let site = configuration.sites.first(where: { $0.key == item.sourceKey }) else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let provider = try await provider(for: site)
      var result = try await provider.categoryContent(
        typeId: item.vodId,
        page: 1,
        filter: false,
        extend: [:]
      )
      attachSourceKey(site.key, to: &result)
      homeResult = result
      selectedSite = site
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func performAction(_ item: MediaItem) async {
    guard let action = item.action,
      let site = configuration.sites.first(where: { $0.key == item.sourceKey })
    else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let result = try await provider(for: site).action(action)
      if !result.list.isEmpty {
        var result = result
        attachSourceKey(site.key, to: &result)
        homeResult = result
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func search() async {
    let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !keyword.isEmpty else { return }
    recordSearchHistory(keyword)
    isLoading = true
    searchHasRun = false
    defer { isLoading = false }
    guard let coordinator,
      var site = selectedSite
    else {
      searchHasRun = true
      searchSections = []
      liveSearchResults = []
      searchFailureCount = 0
      errorMessage = "请先在设置中选择当前点播源"
      return
    }
    site.searchable = 1
    site.quickSearch = 1
    let results = await coordinator.search(sites: [site], keyword: keyword)
    searchFailureCount = results.values.reduce(into: 0) { count, result in
      if case .failure = result {
        count += 1
      }
    }
    searchSections = results.compactMap { key, result in
      guard case .success(let media) = result else { return nil }
      guard let site = configuration.sites.first(where: { $0.key == key }) else { return nil }
      var resultMedia = media
      attachSourceKey(site.key, to: &resultMedia)
      return SearchSection(id: key, siteName: site.name, result: resultMedia)
    }
    .sorted { $0.siteName.localizedCompare($1.siteName) == .orderedAscending }
    liveSearchResults =
      liveGroups
      .flatMap(\.channels)
      .filter { $0.name.localizedCaseInsensitiveContains(keyword) }
      .prefix(50)
      .map { $0 }
    searchHasRun = true
  }

  func loadDetail(_ item: MediaItem) async {
    guard let sourceKey = item.sourceKey ?? selectedSite?.key,
      let site = configuration.sites.first(where: { $0.key == sourceKey })
    else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let provider = try await provider(for: site)
      var result = try await provider.detailContent(id: item.vodId)
      attachSourceKey(site.key, to: &result)
      detailResult = result
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func resolvePlayback(
    item: MediaItem,
    episode: Episode,
    flag: String
  ) async throws -> PlaybackRequest {
    guard let sourceKey = item.sourceKey ?? selectedSite?.key,
      let site = configuration.sites.first(where: { $0.key == sourceKey })
    else {
      throw FirepickError.provider("找不到播放来源")
    }
    let result = try await provider(for: site).playerContent(
      flag: flag,
      id: episode.value,
      vipFlags: configuration.flags ?? []
    )
    let rawURL =
      result.url?.playbackURL
      ?? result.playUrl
      ?? (episode.value.hasPrefix("http") ? episode.value : nil)
    guard let rawURL,
      let url = URL(string: rawURL, relativeTo: URL(string: site.api))?.absoluteURL
    else {
      if result.web != nil {
        throw FirepickError.unsupported("该来源只提供网页播放")
      }
      throw FirepickError.playback("来源没有返回可播放地址")
    }
    let previous = history.first {
      $0.sourceKey == sourceKey
        && $0.item.vodId == item.vodId
        && $0.episodeId == episode.value
    }
    let baseURL = URL(string: site.api)
    let subtitles = (result.subs ?? []).compactMap { subtitle -> PlaybackSubtitle? in
      guard subtitle.flag != 0,
        let url = URL(string: subtitle.url, relativeTo: baseURL)?.absoluteURL
      else { return nil }
      return PlaybackSubtitle(
        url: url,
        name: subtitle.name,
        language: subtitle.lang
      )
    }
    let danmaku = (result.danmaku ?? []).compactMap { item -> PlaybackDanmaku? in
      guard let url = URL(string: item.url, relativeTo: baseURL)?.absoluteURL else {
        return nil
      }
      return PlaybackDanmaku(url: url, name: item.name)
    }
    return PlaybackRequest(
      url: url,
      headers: result.header ?? [:],
      formatHint: rawURL,
      startPosition: previous?.position ?? 0,
      subtitles: subtitles,
      danmaku: danmaku
    )
  }

  func routeLabel(for site: SiteConfiguration) -> String {
    let route = router.route(site)
    switch route.execution {
    case .onDevice:
      return route.runtime == .http ? "本机 HTTP" : "本机 JS"
    case .bridge:
      return switch route.runtime {
      case .java: "需安卓 · Java"
      case .python: "需安卓 · Python"
      case .nodeJS: "需安卓 · Node"
      case .quickJS: "需安卓 · JS"
      case .thunder: "需安卓 · Thunder"
      case .bdj: "需安卓 · BD-J"
      case .nativeCore: "需安卓 · Native"
      case .http: "需安卓 · HTTP"
      }
    case .unsupported:
      return "不支持"
    }
  }

  var sourceRouteCounts: [SourceRouteCount] {
    Dictionary(grouping: configuration.sites, by: { router.route($0).runtime })
      .map { SourceRouteCount(runtime: $0.key, count: $0.value.count) }
      .sorted { $0.runtime.rawValue < $1.runtime.rawValue }
  }

  var hiddenSiteCount: Int {
    configuration.sites.count(where: \.isHidden)
  }

  var liveChannelCount: Int {
    liveGroups.reduce(0) { $0 + $1.channels.count }
  }

  func runtimeLabel(_ runtime: ProviderRuntime) -> String {
    switch runtime {
    case .http: "HTTP / XML / JSON"
    case .quickJS: "QuickJS"
    case .python: "Python"
    case .nodeJS: "Node.js"
    case .java: "Java / JAR"
    case .thunder: "Thunder"
    case .bdj: "BD-J"
    case .nativeCore: "原生扩展"
    }
  }

  func testSelectedSource() async {
    guard let site = selectedSite else {
      sourceTestStatus = "请先选择一个点播源"
      return
    }
    sourceTestIsRunning = true
    sourceTestStatus = nil
    defer { sourceTestIsRunning = false }
    do {
      let result = try await provider(for: site).homeContent()
      let classes = result.classes.count
      let items = result.list.count
      sourceTestStatus = "\(site.name) 可用 · \(classes) 个分类 · \(items) 个条目"
    } catch {
      sourceTestStatus = "\(site.name) 不可用 · \(error.localizedDescription)"
    }
  }

  func loadEPG(for group: LiveGroup) async {
    guard let source = group.epg,
      let url = URL(string: source, relativeTo: configurationBaseURL)?.absoluteURL,
      !loadedEPGSources.contains(url.absoluteString),
      !loadingEPGSources.contains(url.absoluteString)
    else {
      return
    }
    loadingEPGSources.insert(url.absoluteString)
    defer { loadingEPGSources.remove(url.absoluteString) }
    epgStatus = "正在读取节目单…"
    do {
      var request = URLRequest(url: url)
      request.timeoutInterval = 20
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse,
        (200..<300).contains(http.statusCode)
      else {
        throw FirepickError.network("EPG HTTP 错误")
      }
      let programs = XMLTVParser.programs(data)
      let grouped = Dictionary(grouping: programs, by: \.channelId)
      for (channelId, values) in grouped {
        let merged = (epgPrograms[channelId] ?? []) + values
        epgPrograms[channelId] = Array(
          Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { old, _ in old })
            .values
        )
        .sorted { $0.start < $1.start }
      }
      loadedEPGSources.insert(url.absoluteString)
      epgStatus =
        programs.isEmpty
        ? "节目单为空"
        : "节目单已加载 · \(programs.count) 个节目"
    } catch {
      epgStatus = "节目单读取失败：\(error.localizedDescription)"
    }
  }

  func refreshLiveSources() async {
    guard let lives = configuration.lives, !lives.isEmpty else { return }
    isLoading = true
    defer { isLoading = false }
    liveRefreshStatus = "正在刷新直播源…"
    let groups = await loadLiveGroups(
      lives,
      baseURL: configurationBaseURL
    )
    if groups.isEmpty {
      liveRefreshStatus = "直播源刷新失败"
    } else {
      liveGroups = groups
      liveRefreshStatus = "已刷新 \(groups.count) 组 · \(liveChannelCount) 频道"
    }
  }

  func currentProgram(for channel: LiveChannel) -> LiveProgram? {
    guard let id = channel.tvgId else { return nil }
    let now = Date()
    return epgPrograms[id]?.first {
      $0.start <= now && now < $0.stop
    }
  }

  func nextProgram(for channel: LiveChannel) -> LiveProgram? {
    guard let id = channel.tvgId else { return nil }
    let now = Date()
    return epgPrograms[id]?.first {
      $0.start > now
    }
  }

  func setHidden(_ hidden: Bool, for site: SiteConfiguration) async {
    let wasSelected = selectedSite?.key == site.key
    await updateSite(site.key) {
      $0.hide = hidden ? 1 : 0
    }
    guard hidden, wasSelected else { return }
    if let next = configuration.sites.first(where: { !$0.isHidden }) {
      await selectSite(next)
    } else {
      clearSelectedVodState()
    }
  }

  @discardableResult
  func addSite(_ site: SiteConfiguration) async -> Bool {
    let key = site.key.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = site.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let api = site.api.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, !name.isEmpty, !api.isEmpty else {
      errorMessage = "源标识、名称和地址不能为空"
      return false
    }
    guard
      !configuration.sites.contains(where: {
        $0.key.caseInsensitiveCompare(key) == .orderedSame
      })
    else {
      errorMessage = "源标识“\(key)”已存在"
      return false
    }

    var site = site
    site.key = key
    site.name = name
    site.api = api
    configuration.sites.append(site)
    guard await persistCurrentConfiguration() else { return false }
    if selectedSite == nil {
      await selectSite(site)
    }
    return true
  }

  @discardableResult
  func updateSite(_ site: SiteConfiguration) async -> Bool {
    guard let index = configuration.sites.firstIndex(where: { $0.key == site.key }) else {
      errorMessage = "找不到要修改的点播源"
      return false
    }
    var site = site
    site.name = site.name.trimmingCharacters(in: .whitespacesAndNewlines)
    site.api = site.api.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !site.name.isEmpty, !site.api.isEmpty else {
      errorMessage = "源名称和地址不能为空"
      return false
    }

    let wasSelected = selectedSite?.key == site.key
    configuration.sites[index] = site
    guard await persistCurrentConfiguration() else { return false }
    if wasSelected {
      await selectSite(site)
    }
    return true
  }

  func removeSite(_ site: SiteConfiguration) async {
    configuration.sites.removeAll { $0.key == site.key }
    let removedSelectedSite = selectedSite?.key == site.key
    if removedSelectedSite {
      clearSelectedVodState()
    }
    await persistCurrentConfiguration()

    if removedSelectedSite,
      let next = configuration.sites.first(where: { !$0.isHidden })
    {
      await selectSite(next)
    }
  }

  func clearVodSources() async {
    configuration.sites = []
    clearSelectedVodState()
    coordinator = makeCoordinator(client: bridgeClient)
    await persistCurrentConfiguration()
  }

  func saveHistory(
    sourceKey: String, item: MediaItem, episode: Episode, position: Double, duration: Double
  ) async {
    guard let library else { return }
    do {
      try await library.saveHistory(
        HistoryEntry(
          sourceKey: sourceKey,
          item: item,
          episodeId: episode.value,
          episodeName: episode.name,
          position: position,
          duration: duration
        )
      )
      try await refreshLibrary()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func toggleFavorite(sourceKey: String, item: MediaItem) async {
    guard let library else { return }
    do {
      if favorites.contains(where: {
        $0.sourceKey == sourceKey && $0.item.vodId == item.vodId
      }) {
        try await library.removeFavorite(
          sourceKey: sourceKey,
          vodId: item.vodId
        )
      } else {
        try await library.saveFavorite(
          FavoriteEntry(sourceKey: sourceKey, item: item, createdAt: .now)
        )
      }
      try await refreshLibrary()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func download(
    request: PlaybackRequest,
    item: MediaItem,
    episode: Episode?
  ) {
    guard let downloads else { return }
    let sourceKey = item.sourceKey ?? selectedSite?.key ?? "unknown"
    let episode =
      episode
      ?? Episode(
        name: item.name,
        value: request.url.absoluteString
      )
    downloads.download(
      request: request,
      sourceKey: sourceKey,
      item: item,
      episode: episode
    )
  }

  func isFavorite(sourceKey: String, item: MediaItem) -> Bool {
    favorites.contains {
      $0.sourceKey == sourceKey && $0.item.vodId == item.vodId
    }
  }

  func removeFavorite(_ entry: FavoriteEntry) async {
    guard let library else { return }
    do {
      try await library.removeFavorite(
        sourceKey: entry.sourceKey,
        vodId: entry.item.vodId
      )
      try await refreshLibrary()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func removeHistory(_ entry: HistoryEntry) async {
    guard let library else { return }
    do {
      try await library.removeHistory(
        sourceKey: entry.sourceKey,
        vodId: entry.item.vodId
      )
      try await refreshLibrary()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func configureBridge(credentials: BridgeCredentials) async {
    let client = BridgeClient(credentials: credentials)
    bridgeClient = client
    do {
      bridgeHealth = try await client.health()
      try persistence?.saveBridgeCredentials(credentials)
      configDigest = try await client.uploadConfiguration(configuration)
      await coordinator?.invalidate()
      coordinator = makeCoordinator(client: client)
      if let selectedSite {
        await selectSite(selectedSite)
      }
    } catch {
      NSLog("Firepick Bridge configuration failed: %@", error.localizedDescription)
      errorMessage = error.localizedDescription
    }
  }

  func pairBridge(uriString: String) async {
    guard let url = URL(string: uriString),
      let payload = BridgePairingPayload(url)
    else {
      errorMessage = "配对链接无效"
      return
    }

    var credentials = BridgeCredentials(
      baseURL: payload.baseURL,
      certificateSHA256: payload.certificateSHA256,
      token: ""
    )
    let client = BridgeClient(credentials: credentials)
    isLoading = true
    defer { isLoading = false }
    do {
      credentials.token = try await client.pair(code: payload.code)
      bridgeClient = BridgeClient(credentials: credentials)
      configDigest = try await bridgeClient?.uploadConfiguration(configuration) ?? ""
      await configureBridge(credentials: credentials)
    } catch {
      NSLog("Firepick Bridge pairing failed: %@", error.localizedDescription)
      errorMessage = error.localizedDescription
    }
  }

  func loadDepot(_ depot: ConfigurationDepot) async {
    guard let baseURL = configurationBaseURL,
      let resolved = URL(string: depot.url, relativeTo: baseURL)?.absoluteURL
    else {
      errorMessage = "配置仓库地址无效"
      return
    }
    await applyConfiguration(urlString: resolved.absoluteString)
  }

  private func applyConfiguration(
    _ data: Data,
    baseURL: URL?,
    selectInitialSite: Bool = true
  ) async throws {
    switch try ConfigurationDetector.detect(data) {
    case .depot(let depot):
      if let msg = depot.msg {
        throw FirepickError.invalidConfiguration(msg)
      }
      availableDepots = depot.urls
      configurationBaseURL = baseURL
      try persistence?.saveConfiguration(data, baseURL: baseURL)
      errorMessage = nil
    case .vod(let decodedConfiguration):
      guard decodedConfiguration.msg == nil, !decodedConfiguration.sites.isEmpty else {
        throw FirepickError.invalidConfiguration(
          decodedConfiguration.msg ?? "没有站点"
        )
      }
      var decoded = decodedConfiguration
      decoded.inheritGlobalSpider(router: router)
      configuration = decoded
      configurationBaseURL = baseURL
      availableDepots = []
      try persistence?.saveConfiguration(data, baseURL: baseURL)
      configDigest = (try? ConfigurationDigest.sha256(decoded)) ?? ""
      if let bridgeClient {
        configDigest = try await bridgeClient.uploadConfiguration(decoded)
      }
      await coordinator?.invalidate()
      coordinator = makeCoordinator(client: bridgeClient)
      selectedSite = nil
      homeResult = nil
      searchSections = []
      liveSearchResults = []
      searchHasRun = false
      searchFailureCount = 0
      sourceTestStatus = nil
      loadedEPGSources = []
      loadingEPGSources = []
      epgPrograms = [:]
      epgStatus = nil
      liveGroups = await loadLiveGroups(decoded.lives ?? [], baseURL: baseURL)
      errorMessage = nil
      let persistedKey = persistence?.selectedSiteKey
      pendingInitialSiteKey = persistedKey
      if selectInitialSite {
        await selectPendingInitialSite()
      }
    case .live(let name, let groups):
      liveGroups = groups
      availableDepots = []
      configurationBaseURL = baseURL
      try persistence?.saveConfiguration(data, baseURL: baseURL)
      selectedTab = .live
      errorMessage = groups.isEmpty ? "\(name) 中没有识别到频道" : nil
    }
  }

  private func restorePersistentState() async {
    guard let persistence else {
      loadEmptyConfiguration()
      return
    }
    if let data = persistence.configurationData {
      do {
        try await applyConfiguration(
          data,
          baseURL: persistence.configurationBaseURL,
          selectInitialSite: false
        )
      } catch {
        errorMessage = error.localizedDescription
        persistence.clearConfiguration()
        loadEmptyConfiguration()
      }
    } else {
      loadEmptyConfiguration()
      return
    }

    if let currentURL = persistence.currentConnectionURL {
      currentConnection = sourceConnections.first {
        $0.url == currentURL
      }
    }
    if currentConnection == nil, let baseURL = persistence.configurationBaseURL {
      currentConnection = sourceConnections.first {
        $0.url == baseURL.absoluteString
      }
      if currentConnection == nil {
        recordConnection(url: baseURL)
      }
    }

    if let credentials = try? persistence.loadBridgeCredentials() {
      await configureBridge(credentials: credentials)
    }
    await selectPendingInitialSite()
  }

  /// Ensures the VOD home has a selected site and loaded content after a
  /// configuration address is applied — including when the user is still on Settings.
  func ensureHomeContentLoaded() async {
    guard selectedSite == nil else { return }
    await selectPendingInitialSite()
  }

  func reloadHome() async {
    if let site = selectedSite {
      await selectSite(site)
    } else {
      await selectPendingInitialSite()
    }
  }

  /// Sites that can run on-device (HTTP / QuickJS) without Android Bridge.
  func isOnDeviceCapable(_ site: SiteConfiguration) -> Bool {
    let route = router.route(site)
    switch route.execution {
    case .onDevice where route.runtime == .http || route.runtime == .quickJS:
      return true
    default:
      return false
    }
  }

  var onDeviceSites: [SiteConfiguration] {
    configuration.sites.filter { !$0.isHidden && isOnDeviceCapable($0) }
  }

  var bridgeOnlySites: [SiteConfiguration] {
    configuration.sites.filter { site in
      !site.isHidden && !isOnDeviceCapable(site)
    }
  }

  private func selectPendingInitialSite() async {
    guard selectedSite == nil, !configuration.sites.isEmpty else {
      return
    }
    let persisted = pendingInitialSiteKey.flatMap { key in
      configuration.sites.first(where: { $0.key == key && isOnDeviceCapable($0) })
    }
    pendingInitialSiteKey = nil
    let httpFirst = onDeviceSites.first(where: { router.route($0).runtime == .http })
    let anyOnDevice = onDeviceSites.first
    if let site = persisted ?? httpFirst ?? anyOnDevice {
      await selectSite(site)
    }
  }

  private func autoPlayFirstAvailable() async {
    guard let item = homeResult?.list.first(where: { !$0.isFolder && !$0.isAction }) else {
      return
    }
    await loadDetail(item)
    guard let detail = detailResult?.list.first else { return }
    let lines = EpisodeParser.lines(playFrom: detail.playFrom, playURL: detail.playURL)
    guard let line = lines.first,
      let episode = line.episodes.first,
      let request = try? await resolvePlayback(
        item: detail,
        episode: episode,
        flag: line.name
      )
    else {
      return
    }
    debugPlaybackItem = detail
    debugPlaybackEpisode = episode
    debugPlaybackRequest = request
  }

  private func loadLiveGroups(_ lives: [LiveConfiguration], baseURL: URL?) async -> [LiveGroup] {
    var output: [LiveGroup] = []
    for live in lives {
      let start = output.count
      if let embedded = live.groups {
        output.append(contentsOf: LiveParser.groups(from: embedded))
      }
      if let text = await loadLiveText(live, baseURL: baseURL),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        let groups = parseLiveGroups(text, live: live)
        output.append(contentsOf: groups)
      }
      if let epg = live.epg,
        let resolved = URL(string: epg, relativeTo: baseURL)?.absoluteURL
      {
        for index in start..<output.count where output[index].epg == nil {
          output[index].epg = resolved.absoluteString
        }
      }
    }
    return output
  }

  private func loadLiveText(
    _ live: LiveConfiguration,
    baseURL: URL?
  ) async -> String? {
    if let api = live.api, !api.isEmpty {
      let site = Self.resolve(
        SiteConfiguration(
          key: "live:\(live.name)",
          name: live.name,
          type: 3,
          api: api,
          ext: live.ext,
          jar: live.jar
        ),
        baseURL: baseURL
      )
      if let result = try? await provider(for: site).liveContent(url: live.url ?? ""),
        let content = result.rawContent
      {
        return content
      }
    }

    guard let source = live.url,
      !source.isEmpty
    else {
      return nil
    }
    guard let resolved = URL(string: source, relativeTo: baseURL)?.absoluteURL else {
      return nil
    }
    var request = URLRequest(url: resolved)
    request.timeoutInterval = 20
    liveHeaders(live).forEach {
      request.setValue($0.value, forHTTPHeaderField: $0.key)
    }
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode)
    else {
      return nil
    }
    return String(decoding: data, as: UTF8.self)
  }

  private func parseLiveGroups(
    _ text: String,
    live: LiveConfiguration
  ) -> [LiveGroup] {
    guard let data = text.data(using: .utf8) else { return [] }
    var groups: [LiveGroup] = []
    if case .live(_, let detected) = try? ConfigurationDetector.detect(data) {
      groups = detected
    } else if let single = try? JSONDecoder().decode(LiveGroup.self, from: data) {
      groups = [single]
    }
    let headers = liveHeaders(live)
    return groups.map { group in
      var group = group
      group.channels = group.channels.map { channel in
        var channel = channel
        headers.forEach { channel.headers[$0.key] = $0.value }
        if channel.epg == nil {
          channel.epg = live.epg
        }
        return channel
      }
      if group.epg == nil {
        group.epg = live.epg
      }
      return group
    }
  }

  private func liveHeaders(_ live: LiveConfiguration) -> [String: String] {
    var headers = live.header ?? [:]
    if let ua = live.ua { headers["User-Agent"] = ua }
    if let referer = live.referer { headers["Referer"] = referer }
    if let origin = live.origin { headers["Origin"] = origin }
    if case .object(let values)? = configuration.headers {
      values.forEach { key, value in
        if let text = value.stringValue, headers[key] == nil {
          headers[key] = text
        }
      }
    }
    return headers
  }

  private func attachSourceKey(_ sourceKey: String, to result: inout MediaResult) {
    result.list = result.list.map { item in
      var item = item
      item.sourceKey = sourceKey
      return item
    }
  }

  private func provider(for site: SiteConfiguration) async throws -> any SourceProvider {
    if coordinator == nil {
      coordinator = makeCoordinator(client: bridgeClient)
    }
    guard let coordinator else {
      throw FirepickError.provider("Provider 未初始化")
    }
    return try await coordinator.provider(for: site)
  }

  private func makeCoordinator(client: BridgeClient?) -> ProviderCoordinator {
    let configDigest =
      configDigest.isEmpty
      ? ((try? ConfigurationDigest.sha256(configuration)) ?? "")
      : configDigest
    let baseURL = configurationBaseURL
    let firepickBridge = bridgeClient
    let bridgeFactory: @Sendable (SiteConfiguration) throws -> any SourceProvider = { site in
      let resolvedSite = Self.resolve(site, baseURL: baseURL)
      guard let client = firepickBridge else {
        throw FirepickError.unsupported("该源需要 Android 运行时，当前未连接")
      }
      return BridgeProvider(
        site: resolvedSite,
        client: client,
        configDigest: configDigest
      )
    }
    let quickJSFactory: @Sendable (SiteConfiguration) throws -> any SourceProvider = { site in
      let resolvedSite = Self.resolve(site, baseURL: baseURL)
      return QuickJSProvider(
        site: resolvedSite,
        host: OnDeviceJavaScriptHost(baseURL: baseURL)
      )
    }
    return ProviderCoordinator(
      preferBridgeForQuickJS: false,
      bridgeFactory: bridgeFactory,
      quickJSFactory: quickJSFactory
    )
  }

  nonisolated private static func resolve(_ site: SiteConfiguration, baseURL: URL?)
    -> SiteConfiguration
  {
    guard let baseURL else { return site }
    var site = site
    if site.api.hasPrefix("."), let url = URL(string: site.api, relativeTo: baseURL) {
      site.api = url.absoluteURL.absoluteString
    }
    if let jar = site.jar,
      jar.hasPrefix("."),
      let url = URL(string: jar, relativeTo: baseURL)
    {
      site.jar = url.absoluteURL.absoluteString
    }
    if let ext = site.ext {
      site.ext = resolve(ext, baseURL: baseURL)
    }
    return site
  }

  nonisolated private static func resolve(_ value: JSONValue, baseURL: URL) -> JSONValue {
    switch value {
    case .string(let text):
      let resolved = text.components(separatedBy: "$$$").map { component in
        guard component.hasPrefix("."),
          let url = URL(string: component, relativeTo: baseURL)
        else {
          return component
        }
        return url.absoluteURL.absoluteString
      }
      return .string(resolved.joined(separator: "$$$"))
    case .array(let values):
      return .array(values.map { resolve($0, baseURL: baseURL) })
    case .object(let values):
      return .object(values.mapValues { resolve($0, baseURL: baseURL) })
    default:
      return value
    }
  }

  private func refreshLibrary() async throws {
    guard let library else { return }
    async let history = library.history()
    async let favorites = library.favorites()
    self.history = try await history
    self.favorites = try await favorites
  }

  private func updateSite(
    _ key: String,
    update: (inout SiteConfiguration) -> Void
  ) async {
    guard let index = configuration.sites.firstIndex(where: { $0.key == key }) else {
      return
    }
    update(&configuration.sites[index])
    await persistCurrentConfiguration()
  }

  @discardableResult
  private func persistCurrentConfiguration() async -> Bool {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(configuration)
      try persistence?.saveConfiguration(data, baseURL: configurationBaseURL)
      configDigest = try ConfigurationDigest.sha256(configuration)
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
    if let bridgeClient {
      do {
        configDigest = try await bridgeClient.uploadConfiguration(configuration)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
    return true
  }

  private func clearSelectedVodState() {
    selectedSite = nil
    selectedCategory = nil
    homeResult = nil
    detailResult = nil
    categoryFilters = []
    filterSelections = [:]
    currentPage = 1
    searchSections = []
    searchHasRun = false
    searchFailureCount = 0
    sourceTestStatus = nil
    persistence?.saveSelectedSiteKey(nil)
  }

  private func loadEmptyConfiguration() {
    configuration = .empty
    clearSelectedVodState()
    coordinator = makeCoordinator(client: bridgeClient)
  }

  private func decodedFilters(_ value: JSONValue?) -> [SourceFilter] {
    guard let value,
      let data = try? JSONEncoder().encode(value)
    else {
      return []
    }
    if let filters = try? JSONDecoder().decode([SourceFilter].self, from: data) {
      return filters
    }
    if let groups = try? JSONDecoder().decode(
      [String: [SourceFilter]].self,
      from: data
    ) {
      return groups.values.flatMap { $0 }
    }
    return []
  }

}
