import FirepickBridge
import FirepickCore
import FirepickPlayback
import FirepickProvider
import Foundation
import Network
import Observation

struct SourceConnection: Codable, Identifiable, Equatable {
  var url: String
  var name: String
  var updatedAt: Date
  var displayURL: String?
  var enabled: Bool

  var id: String { url }
  var displayAddress: String {
    SourceAddress.displayURL(displayURL ?? url)
  }

  init(
    url: String,
    name: String,
    updatedAt: Date,
    displayURL: String? = nil,
    enabled: Bool = true
  ) {
    self.url = url
    self.name = name
    self.updatedAt = updatedAt
    self.displayURL = displayURL
    self.enabled = enabled
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    url = try container.decode(String.self, forKey: .url)
    name = try container.decode(String.self, forKey: .name)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    displayURL = try container.decodeIfPresent(String.self, forKey: .displayURL)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
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

  enum VideoOutputPreference: String, CaseIterable, Identifiable {
    case automatic
    case metal
    case system

    var id: String { rawValue }
    var title: String {
      switch self {
      case .automatic: "自动"
      case .metal: "优先 Metal"
      case .system: "系统层"
      }
    }
  }

  enum DecodePreference: String, CaseIterable, Identifiable {
    case automatic
    case hardware
    case software

    var id: String { rawValue }
    var title: String {
      switch self {
      case .automatic: "自动"
      case .hardware: "硬解优先"
      case .software: "软解"
      }
    }
  }

  /// 片头片尾本机标记行为（与「智能去广」片中广告无关）。
  enum AdSkipPreference: String, CaseIterable, Identifiable {
    case off
    case marked
    case aggressive

    var id: String { rawValue }
    var title: String {
      switch self {
      case .off: "关闭"
      case .marked: "自动跳过"
      case .aggressive: "激进（播完直接下一集）"
      }
    }
  }

  enum BufferPreference: String, CaseIterable, Identifiable {
    case short
    case standard
    case long

    var id: String { rawValue }
    var title: String {
      switch self {
      case .short: "短"
      case .standard: "标准"
      case .long: "长"
      }
    }

    var seconds: Double {
      switch self {
      case .short: 2
      case .standard: 5
      case .long: 10
      }
    }
  }

  enum SubtitleFontPreference: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }
    var title: String {
      switch self {
      case .small: "小"
      case .medium: "中"
      case .large: "大"
      }
    }
  }

  enum SubtitleColorPreference: String, CaseIterable, Identifiable {
    case white
    case yellow

    var id: String { rawValue }
    var title: String {
      switch self {
      case .white: "白"
      case .yellow: "黄"
      }
    }
  }

  struct SearchSection: Identifiable {
    let id: String
    let siteName: String
    let result: MediaResult
  }

  struct SearchFailure: Identifiable, Equatable {
    let id: String
    let siteName: String
    let message: String
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
  /// Live TV immersive fullscreen — drives root tab-bar visibility.
  var liveFullscreenActive = false
  /// When fullscreen, swipe-up can temporarily reveal the tab bar.
  var liveShowsTabBarInFullscreen = false
  var configuration: VodConfiguration = .empty
  var selectedSite: SiteConfiguration?
  static let officialSourceVersion = "21"
  static let officialSourceURL = "https://dl.yychuiyan.com/firepick/ios-sources.json?v=21"
  var selectedCategory: FirepickCore.Category?
  var homeResult: MediaResult?
  var detailResult: MediaResult?
  var categoryFilters: [SourceFilter] = []
  var filterSelections: [String: String] = [:]
  /// Per-category filter memory so switching 电视剧↔电影 keeps prior picks.
  private var filterSelectionsByCategory: [String: [String: String]] = [:]
  var currentPage = 1
  var isLoadingMore = false
  var searchSections: [SearchSection] = []
  var searchFailures: [SearchFailure] = []
  var liveSearchResults: [LiveChannel] = []
  var searchText = ""
  var searchHasRun = false
  var searchHistory: [String] = []
  var searchFailureCount = 0
  /// Last recoverable action for the global error banner retry button.
  var lastRecoverableAction: RecoverableAction?

  enum RecoverableAction: Equatable {
    case reloadHome
    case search
    case refreshLive
    case loadDetail(MediaItem)
  }
  var isLoadingHome = false
  /// True from cold start until bootstrap restore finishes.
  /// Default true so the first frame shows loading, not “还没有内容”.
  /// Browse must not kick off a parallel home load — that flashes a second spinner.
  var isRestoringSession = true
  private var categoryCache: [String: MediaResult] = [:]
  private var prefetchTask: Task<Void, Never>?
  private var cacheSizeTask: Task<Void, Never>?
  private var liveRefreshTask: Task<[LiveGroup], Never>?
  private var liveLoadGeneration = 0
  private var activeLiveCacheDigest = ""
  private var didAutoUpdateOfficialSource = false
  var isLoadingDetail = false
  var isLoadingSearch = false
  var isSwitchingConnection = false
  var isUpdatingOfficialSource = false
  /// Non-error status toast (e.g. 配置更新中). Cleared by the presenter when done.
  var statusToast: String?
  var isLoadingLive = false
  var loadMoreFailed = false
  /// Legacy aggregate flag; prefer granular flags for new UI.
  var isLoading = false
  var errorMessage: String?
  /// NWPathMonitor: false when no usable route.
  var isNetworkAvailable = true
  /// Cellular or constrained path. Shown as a dismissible weak-network banner.
  var isNetworkConstrained = false
  /// User dismissed the offline banner until connectivity changes.
  var suppressNetworkBanner = false
  var suppressConstrainedBanner = false
  private var homeLoadGeneration = 0
  /// Category switch / loadMore only — must not cancel `prefetchCategories`.
  private var categoryLoadGeneration = 0
  private var searchLoadGeneration = 0
  var connectionLatencyMS: [String: Int] = [:]
  /// CMS / site probe results for 采集站管理 (keyed by CollectionStation.id).
  var collectionStationLatencyMS: [String: Int] = [:]
  var probingCollectionStationIDs: Set<String> = []
  /// True after at least one 采集站测速 pass finished (so "失败" ≠ "尚未测").
  var didProbeCollectionStations = false
  /// Active CMS pool after 测速淘金 (drives 采集站管理 / 播放来源 / firepick-cms providers).
  var activeCMSProviders: [ActiveCMSProvider] = []
  /// Last refine result shown under 采集站管理.
  var collectionStationProbeStatus: String?
  /// True only for user-tapped 切换/添加线路 — hides Settings spinner on silent restore.
  var userInitiatedConnectionSwitch = false
  /// Reserved. Cloud skip is not wired; local intro/outro marks still apply.
  var cloudAdSkipEnabled = false
  var probingConnectionURLs: Set<String> = []
  var videoOutputPreference: VideoOutputPreference = .automatic
  var decodePreference: DecodePreference = .automatic
  var adSkipPreference: AdSkipPreference = .off
  var backgroundPlaybackEnabled = false
  var incognitoModeEnabled = false
  var multiSourceSearchEnabled = false
  var bufferPreference: BufferPreference = .standard
  var subtitleFontPreference: SubtitleFontPreference = .medium
  var subtitleColorPreference: SubtitleColorPreference = .white
  var subtitleOutlineEnabled = true
  var skipMarks: [String: SkipMark] = [:]
  var playbackFlagSelections: [String: String] = [:]
  var favoriteLiveChannelIDs: Set<String> = []
  var lastLiveChannelID: String?
  var lastLiveChannelName: String?
  var lastLiveGroupName: String?
  var lastLiveShelfID: String?
  var lastLiveURLIndex: Int = 0

  struct SkipMark: Codable, Equatable, Sendable {
    var introEnd: Double?
    var outroStart: Double?
  }
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
  var danmakuEnabledByDefault = false
  var danmakuOpacity = 0.9
  var danmakuFontScale = 1.0
  var danmakuSpeed = 1.0
  /// Auto-match B站 / 自定义弹幕 API when spider returns no danmaku URL.
  var danmakuAutoMatch = true
  /// Optional 弹弹兼容 API root (e.g. https://host/token) covering 爱优腾芒哔.
  var danmakuCustomAPIBase = ""
  var danmakuDisplayArea: DanmakuDisplayArea = .full
  var cacheStatus: String?
  var cacheSizeText = "计算中"
  private var configDigest = ""
  /// Local SHA of the VOD JSON (ignores Bridge upload id) — used to skip redundant home reloads.
  private var localConfigDigest = ""
  private var configurationBaseURL: URL?
  private var pendingInitialSiteKey: String?
  private var loadedEPGSources: Set<String> = []
  private var loadingEPGSources: Set<String> = []

  private var coordinator: ProviderCoordinator?
  private var library: LibraryStore?
  private var persistence: AppPersistence?
  private var bridgeClient: BridgeClient?
  private let router = SourceRouter()
  private var pathMonitor: NWPathMonitor?
  private let configurationSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration)
  }()

  func bootstrap() async {
    isRestoringSession = true
    defer {
      // restorePersistentState clears this itself; keep a safety net for test/error paths.
      if isRestoringSession { isRestoringSession = false }
    }
    startNetworkMonitoring()
    do {
      library = try LibraryStore()
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
        isRestoringSession = false
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
    if let value = persistence?.danmakuAutoMatch {
      danmakuAutoMatch = value
    }
    if let value = persistence?.danmakuCustomAPIBase {
      danmakuCustomAPIBase = value
    }
    if let raw = persistence?.danmakuDisplayArea,
      let area = DanmakuDisplayArea(rawValue: raw)
    {
      danmakuDisplayArea = area
    }
    if let raw = persistence?.videoOutputPreference,
      let value = VideoOutputPreference(rawValue: raw)
    {
      videoOutputPreference = value
    }
    if let raw = persistence?.decodePreference,
      let value = DecodePreference(rawValue: raw)
    {
      decodePreference = value
    }
    if let raw = persistence?.adSkipPreference,
      let value = AdSkipPreference(rawValue: raw)
    {
      adSkipPreference = value
    }
    if let value = persistence?.backgroundPlaybackEnabled {
      backgroundPlaybackEnabled = value
    }
    if let value = persistence?.cloudAdSkipEnabled {
      cloudAdSkipEnabled = value
    }
    if let value = persistence?.incognitoModeEnabled {
      incognitoModeEnabled = value
    }
    if let value = persistence?.multiSourceSearchEnabled {
      multiSourceSearchEnabled = value
    }
    if let raw = persistence?.bufferPreference,
      let value = BufferPreference(rawValue: raw)
    {
      bufferPreference = value
    }
    if let raw = persistence?.subtitleFontPreference,
      let value = SubtitleFontPreference(rawValue: raw)
    {
      subtitleFontPreference = value
    }
    if let raw = persistence?.subtitleColorPreference,
      let value = SubtitleColorPreference(rawValue: raw)
    {
      subtitleColorPreference = value
    }
    if let value = persistence?.subtitleOutlineEnabled {
      subtitleOutlineEnabled = value
    }
    skipMarks = persistence?.loadSkipMarks() ?? [:]
    connectionLatencyMS = persistence?.loadConnectionLatencies() ?? [:]
    playbackFlagSelections = persistence?.loadPlaybackFlagSelections() ?? [:]
    favoriteLiveChannelIDs = Set(persistence?.loadFavoriteLiveChannelIDs() ?? [])
    lastLiveChannelID = persistence?.lastLiveChannelID
    lastLiveChannelName = persistence?.lastLiveChannelName
    lastLiveGroupName = persistence?.lastLiveGroupName
    lastLiveShelfID = persistence?.lastLiveShelfID
    lastLiveURLIndex = persistence?.lastLiveURLIndex ?? 0
    sourceConnections = (try? persistence?.loadSourceConnections()) ?? []
    searchHistory = persistence?.searchHistory ?? []
    let persistedActive = persistence?.loadActiveCMSProviders() ?? []
    activeCMSProviders =
      persistedActive.isEmpty
      ? Self.defaultActiveCMSProviders
      : persistedActive
    consolidateWarehouseConnections()
    if let currentURL = persistence?.currentConnectionURL {
      currentConnection = sourceConnections.first { $0.url == currentURL && $0.enabled }
    }
  }

  /// Fallback active pool before first in-app 测速淘金.
  /// Keep in sync with firepick-cms.js DEFAULT_PROVIDERS (probe: scripts/probe-cms-providers.mjs).
  static let firepickCMSProviders: [(key: String, name: String, api: String)] = [
    ("zuid", "最大", "https://api.zuidapi.com/api.php/provide/vod"),
    ("lzcaiji", "量子", "https://cj.lzcaiji.com/api.php/provide/vod"),
    ("haohua", "豪华", "https://hhzyapi.com/api.php/provide/vod"),
    ("maoyan", "猫眼", "https://api.maoyanapi.top/api.php/provide/vod"),
    ("guangsu", "光速", "https://api.guangsuapi.com/api.php/provide/vod"),
    ("subo", "速播", "https://subocaiji.com/api.php/provide/vod"),
    ("jisu", "极速", "https://jszyapi.com/api.php/provide/vod"),
    ("lzi", "量子", "https://cj.lziapi.com/api.php/provide/vod"),
    ("ruyi", "如意", "https://cj.rycjapi.com/api.php/provide/vod"),
    ("ffzy", "非凡", "https://api.ffzyapi.com/api.php/provide/vod"),
  ]

  static var defaultActiveCMSProviders: [ActiveCMSProvider] {
    firepickCMSProviders.map {
      ActiveCMSProvider(key: $0.key, name: $0.name, api: $0.api)
    }
  }

  static let activeCMSPoolSize = 10

  /// Settings row summary for 采集站管理.
  var collectionStationSummary: String {
    "\(collectionStations.count)"
  }

  /// Rows shown in 采集站管理: firepick providers, or each on-device site.
  var collectionStations: [CollectionStation] {
    collectionStations(in: configuration)
  }

  /// Same rows for a previewed warehouse (线路详情).
  func collectionStations(in configuration: VodConfiguration) -> [CollectionStation] {
    if configuration.sites.contains(where: { $0.key == "firepick_cms" }) {
      let providers =
        activeCMSProviders.isEmpty ? Self.defaultActiveCMSProviders : activeCMSProviders
      return providers.map {
        CollectionStation(
          id: "cms:\($0.key)",
          name: $0.name,
          detail: "拾萤聚合 · 自动选用",
          probeURL: $0.api
        )
      }
    }
    return configuration.sites.filter { !$0.isHidden && isOnDeviceCapable($0) }.map {
      CollectionStation(
        id: $0.key,
        name: $0.name,
        detail: routeLabel(for: $0),
        probeURL: $0.api
      )
    }
  }

  struct ActiveCMSProvider: Codable, Equatable, Sendable, Identifiable {
    var key: String
    var name: String
    var api: String
    var id: String { key }
  }

  struct CollectionStation: Identifiable, Equatable {
    var id: String
    var name: String
    var detail: String
    var probeURL: String?
  }

  /// Merge official ?v= variants into one line, and collapse duplicate loopback warehouses.
  private func consolidateWarehouseConnections() {
    let currentURL = persistence?.currentConnectionURL
    var next = sourceConnections
    var currentReplacement: String?

    let official = next.filter { isOfficialWarehouseURL($0.url) }
    if !official.isEmpty {
      let enabled = official.contains(where: \.enabled)
      next.removeAll { isOfficialWarehouseURL($0.url) }
      let connection = SourceConnection(
        url: Self.officialSourceURL,
        name: URL(string: Self.officialSourceURL)?.host ?? "拾萤精选",
        updatedAt: .now,
        displayURL: Self.officialSourceURL,
        enabled: enabled
      )
      next.insert(connection, at: 0)
      if currentURL.map(isOfficialWarehouseURL) == true {
        currentReplacement = connection.url
      }
    }

    // http://127.0.0.1:8765/...?v=11 and bare/duplicate locals → keep newest one per host:port/path
    var seenLoopback = Set<String>()
    var deduped: [SourceConnection] = []
    for connection in next {
      guard let key = loopbackWarehouseKey(connection.url) else {
        deduped.append(connection)
        continue
      }
      if seenLoopback.contains(key) {
        if currentURL == connection.url, currentReplacement == nil {
          currentReplacement = deduped.first { loopbackWarehouseKey($0.url) == key }?.url
        }
        continue
      }
      seenLoopback.insert(key)
      deduped.append(connection)
    }
    next = deduped

    guard next != sourceConnections || currentReplacement != nil else { return }
    sourceConnections = next
    try? persistence?.saveSourceConnections(sourceConnections)
    if let currentReplacement {
      persistence?.saveCurrentConnectionURL(currentReplacement)
    }
  }

  private func loopbackWarehouseKey(_ raw: String) -> String? {
    guard let components = URLComponents(string: raw),
      let host = components.host?.lowercased(),
      host == "127.0.0.1" || host == "localhost"
    else { return nil }
    let port = components.port.map { ":\($0)" } ?? ""
    return "\(host)\(port)\(components.path)"
  }

  func toggleLiveFavorite(_ channel: LiveChannel) {
    if favoriteLiveChannelIDs.contains(channel.id) {
      favoriteLiveChannelIDs.remove(channel.id)
    } else {
      favoriteLiveChannelIDs.insert(channel.id)
    }
    persistence?.saveFavoriteLiveChannelIDs(Array(favoriteLiveChannelIDs))
  }

  func isLiveFavorite(_ channel: LiveChannel) -> Bool {
    favoriteLiveChannelIDs.contains(channel.id)
  }

  func rememberLiveChannel(_ channel: LiveChannel, groupName: String?, urlIndex: Int) {
    lastLiveChannelID = channel.id
    lastLiveChannelName = channel.name
    lastLiveGroupName = groupName
    lastLiveURLIndex = max(0, urlIndex)
    persistence?.saveLastLiveChannelID(channel.id)
    persistence?.saveLastLiveChannelName(channel.name)
    persistence?.saveLastLiveGroupName(groupName)
    persistence?.saveLastLiveURLIndex(lastLiveURLIndex)
  }

  func rememberLiveShelf(_ shelfID: String) {
    lastLiveShelfID = shelfID
    persistence?.saveLastLiveShelfID(shelfID)
  }

  func allLiveChannels() -> [LiveChannel] {
    liveGroups.flatMap(\.channels)
  }

  func resolveInitialLiveChannel() -> (group: LiveGroup, channel: LiveChannel)? {
    if let match = findLiveChannel(id: lastLiveChannelID, name: lastLiveChannelName) {
      return match
    }
    let favorites = allLiveChannels().filter { favoriteLiveChannelIDs.contains($0.id) }
    if let channel = favorites.first,
      let group = liveGroups.first(where: { $0.channels.contains(where: { $0.id == channel.id }) })
    {
      return (group, channel)
    }
    if let groupName = lastLiveGroupName,
      let group = liveGroups.first(where: { $0.name == groupName }),
      let channel = group.channels.first
    {
      return (group, channel)
    }
    guard let group = liveGroups.first, let channel = group.channels.first else { return nil }
    return (group, channel)
  }

  private func findLiveChannel(id: String?, name: String?) -> (group: LiveGroup, channel: LiveChannel)? {
    if let id,
      let group = liveGroups.first(where: { $0.channels.contains(where: { $0.id == id }) }),
      let channel = group.channels.first(where: { $0.id == id })
    {
      return (group, channel)
    }
    // URLs in id can drift after source refresh; fall back to stable channel name.
    let resolvedName =
      name
      ?? id?.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    guard let resolvedName, !resolvedName.isEmpty else { return nil }
    if let groupName = lastLiveGroupName,
      let group = liveGroups.first(where: { $0.name == groupName }),
      let channel = group.channels.first(where: { $0.name == resolvedName })
    {
      return (group, channel)
    }
    for group in liveGroups {
      if let channel = group.channels.first(where: { $0.name == resolvedName }) {
        return (group, channel)
      }
    }
    return nil
  }

  func loadConnection(_ connection: SourceConnection) async {
    guard connection.enabled else {
      errorMessage = "这条线路已禁用"
      return
    }
    userInitiatedConnectionSwitch = true
    defer { userInitiatedConnectionSwitch = false }
    if await applyConfiguration(
      urlString: connection.url,
      displayURL: connection.displayAddress
    ) {
      currentConnection = connection
    }
  }

  func setConnectionEnabled(_ connection: SourceConnection, enabled: Bool) async {
    guard let index = sourceConnections.firstIndex(where: { $0.id == connection.id }) else { return }
    guard sourceConnections[index].enabled != enabled else { return }
    sourceConnections[index].enabled = enabled
    try? persistence?.saveSourceConnections(sourceConnections)
    guard !enabled, currentConnection?.id == connection.id else { return }
    if let next = sourceConnections.first(where: \.enabled) {
      await loadConnection(next)
    }
    if currentConnection?.id == connection.id {
      currentConnection = nil
      persistence?.saveCurrentConnectionURL(nil)
      unloadConfiguration()
    }
  }

  func removeConnection(_ connection: SourceConnection) {
    let removedCurrent = currentConnection?.id == connection.id
    sourceConnections.removeAll { $0.id == connection.id }
    try? persistence?.saveSourceConnections(sourceConnections)
    if removedCurrent || sourceConnections.isEmpty {
      currentConnection = nil
      persistence?.saveCurrentConnectionURL(nil)
      unloadConfiguration()
    }
  }

  /// Drop in-memory + persisted VOD config when no warehouse address is selected.
  private func unloadConfiguration() {
    persistence?.clearConfiguration()
    persistence?.saveCurrentConnectionURL(nil)
    configurationBaseURL = nil
    availableDepots = []
    configurationCandidates = []
    liveLoadGeneration += 1
    liveRefreshTask?.cancel()
    liveRefreshTask = nil
    isLoadingLive = false
    activeLiveCacheDigest = ""
    liveGroups = []
    loadEmptyConfiguration()
  }

  private func recordConnection(url: URL, displayURL: String? = nil) {
    // Never downgrade a pinned official ?v=N URL to a redirect/bare address.
    if isOfficialWarehouse(url),
      let current = currentConnection,
      isOfficialWarehouseURL(current.url),
      warehouseVersion(current.url) == Self.officialSourceVersion,
      warehouseVersion(url.absoluteString) != Self.officialSourceVersion
    {
      return
    }
    let existing = sourceConnections.first { $0.url == url.absoluteString }
    let connection = SourceConnection(
      url: url.absoluteString,
      name: url.host ?? url.absoluteString,
      updatedAt: .now,
      displayURL: displayURL ?? existing?.displayURL,
      enabled: true
    )
    sourceConnections.removeAll { $0.url == connection.url }
    // Drop bare/outdated official duplicates so the versioned line stays unique.
    if isOfficialWarehouse(url) {
      sourceConnections.removeAll { isOfficialWarehouseURL($0.url) }
    }
    sourceConnections.insert(connection, at: 0)
    currentConnection = connection
    try? persistence?.saveSourceConnections(sourceConnections)
    persistence?.saveCurrentConnectionURL(connection.url)
  }

  private func isOfficialWarehouse(_ url: URL) -> Bool {
    isOfficialWarehouseURL(url.absoluteString)
  }

  private func isOfficialWarehouseURL(_ raw: String) -> Bool {
    guard let components = URLComponents(string: raw),
      let host = components.host?.lowercased()
    else { return false }
    let officialHost =
      host == "dl.yychuiyan.com"
      || host == "firepick-1302621537.cos.ap-shanghai.myqcloud.com"
    return officialHost && components.path.contains("ios-sources.json")
  }

  private func warehouseVersion(_ raw: String) -> String? {
    URLComponents(string: raw)?.queryItems?.first(where: { $0.name == "v" })?.value
  }

  func setPlaybackPreference(_ value: PlaybackPreference) {
    playbackPreference = value
    if value == .mpv, videoOutputPreference == .system {
      videoOutputPreference = .automatic
      persistence?.saveVideoOutputPreference(videoOutputPreference.rawValue)
    }
    persistence?.savePlaybackPreference(value.rawValue)
  }

  var availableVideoOutputPreferences: [VideoOutputPreference] {
    if playbackPreference == .mpv {
      return VideoOutputPreference.allCases.filter { $0 != .system }
    }
    return VideoOutputPreference.allCases
  }

  func setPosterSizePreference(_ value: PosterSizePreference) {
    posterSizePreference = value
    persistence?.savePosterSizePreference(value.rawValue)
  }

  func setVideoOutputPreference(_ value: VideoOutputPreference) {
    videoOutputPreference = value
    persistence?.saveVideoOutputPreference(value.rawValue)
  }

  func setDecodePreference(_ value: DecodePreference) {
    decodePreference = value
    persistence?.saveDecodePreference(value.rawValue)
  }

  func setAdSkipPreference(_ value: AdSkipPreference) {
    adSkipPreference = value
    persistence?.saveAdSkipPreference(value.rawValue)
  }

  func setBackgroundPlaybackEnabled(_ value: Bool) {
    backgroundPlaybackEnabled = value
    persistence?.saveBackgroundPlaybackEnabled(value)
  }

  func setCloudAdSkipEnabled(_ value: Bool) {
    cloudAdSkipEnabled = value
    persistence?.saveCloudAdSkipEnabled(value)
  }

  func setIncognitoModeEnabled(_ value: Bool) {
    incognitoModeEnabled = value
    persistence?.saveIncognitoModeEnabled(value)
  }

  func setMultiSourceSearchEnabled(_ value: Bool) {
    multiSourceSearchEnabled = value
    persistence?.saveMultiSourceSearchEnabled(value)
  }

  func setBufferPreference(_ value: BufferPreference) {
    bufferPreference = value
    persistence?.saveBufferPreference(value.rawValue)
  }

  func setSubtitleFontPreference(_ value: SubtitleFontPreference) {
    subtitleFontPreference = value
    persistence?.saveSubtitleFontPreference(value.rawValue)
  }

  func setSubtitleColorPreference(_ value: SubtitleColorPreference) {
    subtitleColorPreference = value
    persistence?.saveSubtitleColorPreference(value.rawValue)
  }

  func setSubtitleOutlineEnabled(_ value: Bool) {
    subtitleOutlineEnabled = value
    persistence?.saveSubtitleOutlineEnabled(value)
  }

  func clearSkipMarks() {
    skipMarks = [:]
    persistence?.saveSkipMarks(skipMarks)
  }

  /// Per program (vodId), independent across titles. `flag` kept for API compat, unused.
  func skipMarkKey(sourceKey: String?, vodId: String, flag: String?) -> String {
    _ = flag
    return "\(sourceKey ?? "")|\(vodId)"
  }

  func skipMark(sourceKey: String?, vodId: String, flag: String?) -> SkipMark? {
    skipMarks[skipMarkKey(sourceKey: sourceKey, vodId: vodId, flag: flag)]
  }

  func setSkipMark(
    sourceKey: String?,
    vodId: String,
    flag: String?,
    introEnd: Double? = nil,
    outroStart: Double? = nil
  ) {
    let key = skipMarkKey(sourceKey: sourceKey, vodId: vodId, flag: flag)
    var mark = skipMarks[key] ?? SkipMark()
    if let introEnd { mark.introEnd = introEnd }
    if let outroStart { mark.outroStart = outroStart }
    skipMarks[key] = mark
    persistence?.saveSkipMarks(skipMarks)
  }

  func clearSkipMark(sourceKey: String?, vodId: String, flag: String?) {
    skipMarks.removeValue(forKey: skipMarkKey(sourceKey: sourceKey, vodId: vodId, flag: flag))
    persistence?.saveSkipMarks(skipMarks)
  }

  /// Clear only intro or only outro; drop the key when both are empty.
  func clearSkipMarkPart(
    sourceKey: String?,
    vodId: String,
    flag: String?,
    intro: Bool = false,
    outro: Bool = false
  ) {
    let key = skipMarkKey(sourceKey: sourceKey, vodId: vodId, flag: flag)
    guard var mark = skipMarks[key] else { return }
    if intro { mark.introEnd = nil }
    if outro { mark.outroStart = nil }
    if mark.introEnd == nil, mark.outroStart == nil {
      skipMarks.removeValue(forKey: key)
    } else {
      skipMarks[key] = mark
    }
    persistence?.saveSkipMarks(skipMarks)
  }

  func clearAllFavorites() async {
    for entry in favorites {
      await removeFavorite(entry)
    }
  }

  func clearAllHistory() async {
    for entry in history {
      await removeHistory(entry)
    }
  }

  func historyProgress(for item: MediaItem) -> Double? {
    guard let entry = history.first(where: { $0.item.vodId == item.vodId }),
      entry.duration > 0
    else { return nil }
    return min(1, max(0, entry.position / entry.duration))
  }

  func previewConfiguration(for connection: SourceConnection) async throws -> VodConfiguration {
    guard let url = URL(string: connection.url) else {
      throw FirepickError.invalidConfiguration("线路地址无效")
    }
    let downloaded = try await downloadConfiguration(from: url)
    let data = try ConfigurationDecoder.normalize(downloaded.data)
    switch try ConfigurationDetector.detect(data) {
    case .vod(let config):
      return config
    case .depot(let depot):
      throw FirepickError.invalidConfiguration(
        "这是仓库入口，请先选择子线路：\(depot.urls.map(\.name).joined(separator: "、"))"
      )
    case .live:
      throw FirepickError.invalidConfiguration("该地址是直播源，没有点播播放源列表")
    }
  }

  func probeConnectionLatency(_ connection: SourceConnection) async {
    guard let url = URL(string: connection.url) else { return }
    // @Observable does not publish in-place Dictionary/Set mutations — reassign.
    var probing = probingConnectionURLs
    probing.insert(connection.url)
    probingConnectionURLs = probing
    defer {
      var probing = probingConnectionURLs
      probing.remove(connection.url)
      probingConnectionURLs = probing
    }
    let started = Date()
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
    request.httpMethod = "GET"
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      let ms = Int(Date().timeIntervalSince(started) * 1000)
      _ = response
      var next = connectionLatencyMS
      next[connection.url] = ms
      connectionLatencyMS = next
      persistence?.saveConnectionLatencies(connectionLatencyMS)
    } catch {
      var next = connectionLatencyMS
      next.removeValue(forKey: connection.url)
      connectionLatencyMS = next
    }
  }

  func probeAllConnectionLatencies() async {
    let connections = sourceConnections
    await withTaskGroup(of: Void.self) { group in
      var index = 0
      let limit = min(3, connections.count)
      func enqueue() {
        guard index < connections.count else { return }
        let connection = connections[index]
        index += 1
        group.addTask { await self.probeConnectionLatency(connection) }
      }
      for _ in 0..<limit { enqueue() }
      for await _ in group {
        enqueue()
      }
    }
  }

  /// Enter 采集站管理: only re-measure current active pool latency badges.
  func probeActivePoolLatenciesOnly() async {
    let stations = collectionStations
    guard !stations.isEmpty else {
      didProbeCollectionStations = true
      return
    }
    await withTaskGroup(of: Void.self) { group in
      var index = 0
      let limit = min(4, stations.count)
      func enqueue() {
        guard index < stations.count else { return }
        let station = stations[index]
        index += 1
        group.addTask { await self.probeCollectionStationLatency(station) }
      }
      for _ in 0..<limit { enqueue() }
      for await _ in group {
        enqueue()
      }
    }
    didProbeCollectionStations = true
  }

  /// 采集站管理测速：拾萤线路会全量淘金候选池；其它线路只测当前展示站。
  func probeCollectionStationLatencies() async {
    if configuration.sites.contains(where: { $0.key == "firepick_cms" }) {
      await refineActiveCMSProviders()
      return
    }
    let stations = collectionStations
    guard !stations.isEmpty else {
      didProbeCollectionStations = true
      return
    }
    collectionStationProbeStatus = nil
    await withTaskGroup(of: Void.self) { group in
      var index = 0
      let limit = min(4, stations.count)
      func enqueue() {
        guard index < stations.count else { return }
        let station = stations[index]
        index += 1
        group.addTask { await self.probeCollectionStationLatency(station) }
      }
      for _ in 0..<limit { enqueue() }
      for await _ in group {
        enqueue()
      }
    }
    didProbeCollectionStations = true
  }

  func probeCollectionStationLatency(_ station: CollectionStation) async {
    guard let raw = station.probeURL, let base = URL(string: raw) else { return }
    // @Observable does not publish in-place Dictionary/Set mutations — reassign
    // or the 采集站管理 badges stay stuck on "—".
    var probing = probingCollectionStationIDs
    probing.insert(station.id)
    probingCollectionStationIDs = probing
    defer {
      var probing = probingCollectionStationIDs
      probing.remove(station.id)
      probingCollectionStationIDs = probing
    }
    guard let url = Self.cmsListProbeURL(from: base) else { return }
    let ms = await Self.measureProbeLatency(url: url, requireJSONBody: false)
    var next = collectionStationLatencyMS
    if let ms {
      next[station.id] = ms
    } else {
      next.removeValue(forKey: station.id)
    }
    collectionStationLatencyMS = next
  }

  /// Probe all cms-candidates → TopN unique-host survivors → persist + inject CMS.
  private func refineActiveCMSProviders() async {
    collectionStationProbeStatus = "正在测速…"
    let candidates = await CMSProviderCatalog.loadCandidates()
    let pool =
      candidates.isEmpty
      ? Self.defaultActiveCMSProviders.map {
        CMSProviderCatalog.Entry(key: $0.key, name: $0.name, api: $0.api)
      }
      : candidates

    probingCollectionStationIDs = Set(pool.map { "cms:\($0.key)" })
    defer { probingCollectionStationIDs = [] }

    struct ProbeHit: Sendable {
      var entry: CMSProviderCatalog.Entry
      var ms: Int
    }

    let hits: [ProbeHit] = await withTaskGroup(of: ProbeHit?.self) { group in
      var index = 0
      let limit = min(6, pool.count)
      var results: [ProbeHit] = []
      func enqueue() {
        guard index < pool.count else { return }
        let entry = pool[index]
        index += 1
        group.addTask {
          guard let base = URL(string: entry.api),
            let url = Self.cmsListProbeURL(from: base),
            let ms = await Self.measureProbeLatency(url: url, requireJSONBody: true)
          else {
            return nil
          }
          return ProbeHit(entry: entry, ms: ms)
        }
      }
      for _ in 0..<limit { enqueue() }
      for await hit in group {
        if let hit { results.append(hit) }
        enqueue()
      }
      return results
    }

    let ranked = hits.sorted { $0.ms < $1.ms }
    var seenHosts = Set<String>()
    var picked: [ActiveCMSProvider] = []
    var latency: [String: Int] = [:]
    for hit in ranked {
      let host = URL(string: hit.entry.api)?.host?.lowercased() ?? hit.entry.key
      if seenHosts.contains(host) { continue }
      seenHosts.insert(host)
      let name = CMSProviderCatalog.displayName(for: hit.entry)
      picked.append(
        ActiveCMSProvider(key: hit.entry.key, name: name, api: hit.entry.api)
      )
      latency["cms:\(hit.entry.key)"] = hit.ms
      if picked.count >= Self.activeCMSPoolSize { break }
    }

    if picked.isEmpty {
      collectionStationLatencyMS = [:]
      didProbeCollectionStations = true
      collectionStationProbeStatus = "候选站暂不可用，仍用当前活跃池"
      return
    }

    activeCMSProviders = picked
    persistence?.saveActiveCMSProviders(picked)
    collectionStationLatencyMS = latency
    didProbeCollectionStations = true
    collectionStationProbeStatus = "已更新 \(picked.count) 条优质线路"

    await coordinator?.invalidate(sourceKey: "firepick_cms")
    if selectedSite?.key == "firepick_cms", let site = selectedSite {
      selectedSite = siteWithActiveCMSProviders(site)
    }
  }

  private func siteWithActiveCMSProviders(_ site: SiteConfiguration) -> SiteConfiguration {
    guard site.key == "firepick_cms" else { return site }
    var site = site
    let providers =
      activeCMSProviders.isEmpty ? Self.defaultActiveCMSProviders : activeCMSProviders
    let providerValues: [JSONValue] = providers.map { item in
      .object([
        "key": .string(item.key),
        "name": .string(item.name),
        "api": .string(item.api),
      ])
    }
    if case .object(var object) = site.ext {
      object["providers"] = .array(providerValues)
      site.ext = .object(object)
    } else {
      site.ext = .object(["providers": .array(providerValues)])
    }
    return site
  }

  nonisolated private static func cmsListProbeURL(from base: URL) -> URL? {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
    var items = components?.queryItems ?? []
    if !items.contains(where: { $0.name == "ac" }) {
      items.append(URLQueryItem(name: "ac", value: "list"))
    }
    components?.queryItems = items
    return components?.url ?? base
  }

  /// Network wait off the main actor so concurrent probes actually overlap.
  nonisolated private static func measureProbeLatency(
    url: URL,
    requireJSONBody: Bool
  ) async -> Int? {
    let started = Date()
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 8
    )
    request.httpMethod = "GET"
    request.setValue("okhttp/4.1.0", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      let ms = Int(Date().timeIntervalSince(started) * 1000)
      guard let http = response as? HTTPURLResponse,
        (200..<300).contains(http.statusCode)
      else {
        return nil
      }
      if requireJSONBody {
        guard
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          return nil
        }
        let hasList = (object["list"] as? [Any])?.isEmpty == false
        let hasClass = (object["class"] as? [Any])?.isEmpty == false
        let codeOK = (object["code"] as? Int).map { $0 == 1 } ?? true
        guard codeOK, hasList || hasClass else { return nil }
      }
      return ms
    } catch {
      return nil
    }
  }

  func probeSiteLatencies(_ sites: [SiteConfiguration]) async -> [String: Int] {
    var result: [String: Int] = [:]
    let targets = Array(sites.prefix(12))
    await withTaskGroup(of: (String, Int?).self) { group in
      var index = 0
      let limit = min(3, targets.count)
      func enqueue() {
        guard index < targets.count else { return }
        let site = targets[index]
        index += 1
        group.addTask {
          await self.measureSiteLatency(site)
        }
      }
      for _ in 0..<limit { enqueue() }
      for await (key, ms) in group {
        if let ms { result[key] = ms }
        enqueue()
      }
    }
    return result
  }

  private func measureSiteLatency(_ site: SiteConfiguration) async -> (String, Int?) {
    guard let url = URL(string: site.api) else { return (site.key, nil) }
    let started = Date()
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 6
    )
    request.httpMethod = "HEAD"
    do {
      _ = try await URLSession.shared.data(for: request)
      return (site.key, Int(Date().timeIntervalSince(started) * 1000))
    } catch {
      do {
        let getStarted = Date()
        var get = URLRequest(
          url: url,
          cachePolicy: .reloadIgnoringLocalCacheData,
          timeoutInterval: 6
        )
        get.httpMethod = "GET"
        _ = try await URLSession.shared.data(for: get)
        return (site.key, Int(Date().timeIntervalSince(getStarted) * 1000))
      } catch {
        return (site.key, nil)
      }
    }
  }

  /// Resume playback from a history entry. Returns false when caller should open detail.
  @discardableResult
  func resumeFromHistory(_ entry: HistoryEntry) async -> Bool {
    await loadDetail(entry.item)
    let detail = detailResult?.list.first(where: { $0.vodId == entry.item.vodId }) ?? entry.item
    let lines = EpisodeParser.lines(playFrom: detail.playFrom, playURL: detail.playURL)
    guard
      let matched = lines.lazy
        .compactMap({ line -> (PlaybackLine, Episode)? in
          guard let episode = line.episodes.first(where: { $0.value == entry.episodeId })
          else { return nil }
          return (line, episode)
        })
        .first
    else {
      return false
    }
    do {
      let request = try await resolvePlayback(
        item: detail,
        episode: matched.1,
        flag: matched.0.name
      )
      debugPlaybackItem = detail
      debugPlaybackEpisode = matched.1
      debugPlaybackRequest = request
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
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
    setDanmakuEnabledByDefault(false)
    setDanmakuOpacity(0.9)
    setDanmakuFontScale(1)
    setDanmakuSpeed(1)
    setDanmakuAutoMatch(true)
    setDanmakuCustomAPIBase("")
    setDanmakuDisplayArea(.full)
  }

  func setDanmakuAutoMatch(_ value: Bool) {
    danmakuAutoMatch = value
    persistence?.saveDanmakuAutoMatch(value)
  }

  func setDanmakuCustomAPIBase(_ value: String) {
    danmakuCustomAPIBase = value.trimmingCharacters(in: .whitespacesAndNewlines)
    persistence?.saveDanmakuCustomAPIBase(danmakuCustomAPIBase)
  }

  func setDanmakuDisplayArea(_ value: DanmakuDisplayArea) {
    danmakuDisplayArea = value
    persistence?.saveDanmakuDisplayArea(value.rawValue)
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

  /// Drop shared URL responses left by playback. Poster memory/disk cache stays.
  func releasePlaybackCache() {
    // Intentionally do not touch RemoteImageCache or URLCache.shared — clearing
    // shared cache made posters reload slowly on 收藏/历史/搜索 revisit.
  }

  func clearCache() {
    URLCache.shared.removeAllCachedResponses()
    RemoteImageCache.clear()
    cacheSizeTask?.cancel()
    cacheStatus = "正在清理网络与临时缓存…"
    cacheSizeText = "计算中"
    Task {
      await Task.detached(priority: .utility) {
        guard
          let cacheDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
          ).first,
          let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
          )
        else {
          return
        }
        for item in contents {
          try? FileManager.default.removeItem(at: item)
        }
      }.value
      cacheStatus = "已清理网络与临时缓存"
      cacheSizeText = "0 KB"
      refreshCacheSize()
    }
  }

  func refreshCacheSize() {
    cacheSizeTask?.cancel()
    cacheSizeTask = Task {
      let total = await Task.detached(priority: .utility) {
        Self.cacheDirectorySize()
      }.value
      guard !Task.isCancelled else { return }
      guard let total else {
        cacheSizeText = "未知"
        return
      }
      cacheSizeText = ByteCountFormatter.string(
        fromByteCount: total,
        countStyle: .file
      )
    }
  }

  nonisolated private static func cacheDirectorySize() -> Int64? {
    guard
      let cacheDirectory = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      ).first
    else {
      return nil
    }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: cacheDirectory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else {
      return 0
    }
    var bytes: Int64 = 0
    for case let url as URL in enumerator {
      if let values = try? url.resourceValues(forKeys: keys),
        values.isRegularFile == true
      {
        bytes += Int64(values.fileSize ?? 0)
      }
    }
    return bytes
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
    isSwitchingConnection = true
    isLoading = true
    defer {
      isSwitchingConnection = false
      isLoading = false
    }
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

  func selectSite(_ site: SiteConfiguration, preserveBrowse: Bool = false) async {
    if !isOnDeviceCapable(site), bridgeHealth == nil {
      errorMessage =
        "「\(site.name)」需要 Android 运行时（Java/Python 等）。当前以本机 HTTP/JS 为主，请改选本机可用源，或使用自建 iOS 配置仓。"
      return
    }
    let siteChanged = selectedSite?.key != site.key
    // Pull-to-refresh: keep posters on screen (avoid full-screen「正在加载中」).
    let softRefresh = preserveBrowse && !siteChanged && homeResult?.list.isEmpty == false
    let previousHome = softRefresh ? homeResult : nil
    selectedSite = site
    if siteChanged {
      // Keep search results when re-selecting the same site (avoids flash on back).
      searchSections = []
      searchFailures = []
      liveSearchResults = []
      searchHasRun = false
      searchFailureCount = 0
    }
    sourceTestStatus = nil
    if !softRefresh {
      selectedCategory = nil
      categoryFilters = []
      filterSelections = [:]
      filterSelectionsByCategory = [:]
      homeResult = nil
      detailResult = nil
    }
    prefetchTask?.cancel()
    categoryCache = [:]
    currentPage = 1
    persistence?.saveSelectedSiteKey(site.key)
    errorMessage = nil
    loadMoreFailed = false
    homeLoadGeneration += 1
    categoryLoadGeneration += 1
    let generation = homeLoadGeneration
    // Only isLoadingHome — global isLoading would flash SearchView mid-navigation.
    // Soft refresh keeps homeResult so BrowseView stays on the grid (system refresh spinner only).
    isLoadingHome = true
    defer {
      if generation == homeLoadGeneration {
        isLoadingHome = false
      }
    }
    do {
      let provider = try await provider(for: site)
      var result: MediaResult?
      var lastError: Error?
      for attempt in 0..<2 {
        if attempt > 0 {
          try? await Task.sleep(for: .milliseconds(350))
        }
        guard generation == homeLoadGeneration else { return }
        do {
          let loaded = try await provider.homeContent()
          result = loaded
          if !loaded.list.isEmpty { break }
        } catch {
          lastError = error
        }
      }
      guard generation == homeLoadGeneration else { return }
      guard var result else {
        throw lastError ?? FirepickError.network("首页加载失败")
      }
      guard generation == homeLoadGeneration else { return }
      attachSourceKey(site.key, to: &result)
      if result.list.isEmpty, let previousHome, !previousHome.list.isEmpty {
        // Pull-to-refresh failure must not replace readable posters with an error page.
        homeResult = previousHome
        errorMessage = nil
        return
      }
      homeResult = result
      PosterPrefetch.warm(items: result.list)
      errorMessage = nil
      categoryCache = [:]
      if result.list.isEmpty, !result.classes.isEmpty {
        // Only after all transparent retries failed.
        presentRecoverableError(
          "采集站响应较慢或暂时不可用，请下拉刷新重试。",
          action: .reloadHome
        )
      }
      if softRefresh, let current = selectedCategory,
        result.classes.contains(where: { $0.typeId == current.typeId })
      {
        if current.typeId.contains("recommend") {
          prefetchCategories(site: site, classes: result.classes)
        } else {
          await loadCategory(current, site: site)
        }
      } else if let first = homeResult?.classes.first {
        selectedCategory = first
        // 推荐首页不展示筛选；切到分类时再由 loadCategory 注入 filters。
        if !softRefresh {
          categoryFilters = []
          filterSelections = [:]
        }
        // Home already returns the 推荐 list; skip a redundant category fetch
        // (a second loadCategory here flashed another「正在加载中」).
        if first.typeId.contains("recommend") {
          prefetchCategories(site: site, classes: result.classes)
        } else {
          await loadCategory(first, site: site)
        }
      }
    } catch {
      guard generation == homeLoadGeneration else { return }
      if let previousHome, !previousHome.list.isEmpty {
        homeResult = previousHome
        errorMessage = nil
        return
      }
      let text = error.localizedDescription
      if text.contains("Bridge") || text.contains("不可达") {
        presentRecoverableError(
          "本机无法运行该源。请换用 HTTP/JS 源，或查看自建仓说明。",
          action: .reloadHome
        )
      } else {
        presentRecoverableError(text, action: .reloadHome)
      }
    }
  }

  func retryLastRecoverableAction() async {
    errorMessage = nil
    switch lastRecoverableAction {
    case .reloadHome, .none:
      await reloadHome()
    case .search:
      await search()
    case .refreshLive:
      await refreshLiveSources()
    case .loadDetail(let item):
      await loadDetail(item)
    }
  }

  func startNetworkMonitoring() {
    guard pathMonitor == nil else { return }
    let monitor = NWPathMonitor()
    pathMonitor = monitor
    monitor.pathUpdateHandler = { [weak self] path in
      Task { @MainActor in
        let online = path.status == .satisfied
        self?.isNetworkAvailable = online
        self?.isNetworkConstrained = online && path.isConstrained
        if online {
          self?.suppressNetworkBanner = false
        }
        if !path.isConstrained {
          self?.suppressConstrainedBanner = false
        }
      }
    }
    monitor.start(queue: DispatchQueue(label: "firepick.network", qos: .utility))
  }

  /// Prefer friendlier copy for offline / timeout failures.
  func presentRecoverableError(_ raw: String, action: RecoverableAction? = nil) {
    if let action {
      lastRecoverableAction = action
    }
    if !isNetworkAvailable {
      errorMessage = "网络不可用，请检查连接后重试"
      return
    }
    let lower = raw.lowercased()
    if lower.contains("timed out")
      || lower.contains("timeout")
      || raw.contains("超时")
      || lower.contains("NSURLErrorDomain Code=-1001".lowercased())
    {
      errorMessage = "网络超时，源无响应或网络较慢"
      return
    }
    errorMessage = raw
  }

  func playLiveFromSearch(_ channel: LiveChannel) {
    let groupName =
      liveGroups.first(where: { $0.channels.contains(where: { $0.id == channel.id }) })?.name
    rememberLiveChannel(channel, groupName: groupName, urlIndex: 0)
    selectedTab = .live
  }

  /// Fills 电视剧/电影/综艺/动漫 after 推荐 is on screen, so switching tabs does not show a loader.
  private func prefetchCategories(site: SiteConfiguration, classes: [FirepickCore.Category]) {
    prefetchTask?.cancel()
    let generation = homeLoadGeneration
    prefetchTask = Task {
      // Let first-screen covers use the connection before warming category tabs.
      try? await Task.sleep(for: .seconds(2.5))
      if Task.isCancelled || generation != homeLoadGeneration || selectedTab != .vod {
        return
      }
      for category in classes where !category.typeId.contains("recommend") {
        if Task.isCancelled || generation != homeLoadGeneration { return }
        let cacheKey = categoryCacheKey(site: site, typeId: category.typeId)
        if categoryCache[cacheKey] != nil { continue }
        do {
          let provider = try await provider(for: site)
          var result = try await provider.categoryContent(
            typeId: category.typeId,
            page: 1,
            filter: true,
            extend: [:]
          )
          if Task.isCancelled || generation != homeLoadGeneration { return }
          attachSourceKey(site.key, to: &result)
          categoryCache[cacheKey] = result
          PosterPrefetch.warm(items: result.list)
        } catch {
          continue
        }
      }
    }
  }

  func loadCategory(_ category: FirepickCore.Category, site: SiteConfiguration? = nil) async {
    guard let site = site ?? selectedSite else { return }
    let previousTypeId = selectedCategory?.typeId
    let categoryChanged = previousTypeId != category.typeId
    if categoryChanged, let previousTypeId {
      filterSelectionsByCategory[previousTypeId] = filterSelections
    }
    selectedCategory = category
    let keptSource = filterSelections["source"]
    if categoryChanged {
      if let filters = homeResult?.filters?[category.typeId] {
        categoryFilters = Self.browseVisibleFilters(filters)
      } else {
        categoryFilters = Self.browseVisibleFilters(decodedFilters(category.filters))
      }
      if let remembered = filterSelectionsByCategory[category.typeId], !remembered.isEmpty {
        filterSelections = categoryFilters.reduce(into: remembered) { values, filter in
          if values[filter.key] == nil {
            values[filter.key] = filter.initValue ?? filter.value.first?.value ?? ""
          }
        }
      } else {
        filterSelections = categoryFilters.reduce(into: [:]) { values, filter in
          values[filter.key] = filter.initValue ?? filter.value.first?.value ?? ""
        }
      }
      // Keep source selection for CMS queries even though the chip row is hidden.
      if let keptSource, !keptSource.isEmpty {
        filterSelections["source"] = keptSource
      }
      filterSelectionsByCategory[category.typeId] = filterSelections
    }
    let cacheKey = categoryCacheKey(
      site: site,
      typeId: category.typeId,
      selections: filterSelections,
      filters: categoryFilters
    )
    // Instant swap from memory — avoid re-hitting the CMS on 电视剧↔电影.
    if categoryChanged, let cached = categoryCache[cacheKey], !cached.list.isEmpty {
      var shown = cached
      shown.classes = homeResult?.classes ?? cached.classes
      shown.filters = homeResult?.filters ?? cached.filters
      homeResult = shown
      PosterPrefetch.warm(items: shown.list)
      currentPage = 1
      errorMessage = nil
      isLoadingHome = false
      return
    }
    // Do NOT bump homeLoadGeneration here — that cancels prefetchCategories.
    categoryLoadGeneration += 1
    let generation = categoryLoadGeneration
    loadMoreFailed = false
    // Keep the previous grid on screen (silent refresh). Clearing the list made every
    // tab switch flash「正在加载中」; selectedCategory already updates the chip.
    isLoadingHome = true
    defer {
      if generation == categoryLoadGeneration {
        isLoadingHome = false
      }
    }
    do {
      let provider = try await provider(for: site)
      let extend = filterSelections
      var result = try await withThrowingTaskGroup(of: MediaResult.self) { group in
        group.addTask {
          try await provider.categoryContent(
            typeId: category.typeId,
            page: 1,
            filter: true,
            extend: extend
          )
        }
        group.addTask {
          try await Task.sleep(for: .seconds(20))
          throw FirepickError.network("分类加载超时，请重试")
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
      }
      guard generation == categoryLoadGeneration else { return }
      // User already switched away — don't clobber the newer tab.
      guard selectedCategory?.typeId == category.typeId else { return }
      // Keep browse menu (推荐→剧→影→综→漫). Category payloads often ship raw
      // CMS `class` arrays that would scramble the sticky chips.
      if let menu = homeResult?.classes, !menu.isEmpty {
        result.classes = menu
      } else if result.classes.isEmpty {
        result.classes = []
      }
      if result.filters == nil {
        result.filters = homeResult?.filters
      }
      attachSourceKey(site.key, to: &result)
      categoryCache[cacheKey] = result
      homeResult = result
      PosterPrefetch.warm(items: result.list)
      currentPage = 1
      errorMessage = nil
    } catch {
      guard generation == categoryLoadGeneration else { return }
      guard selectedCategory?.typeId == category.typeId else { return }
      presentRecoverableError(error.localizedDescription, action: .reloadHome)
    }
  }

  func selectFilter(_ filter: SourceFilter, value: FilterValue) async {
    filterSelections[filter.key] = value.value
    if let typeId = selectedCategory?.typeId {
      filterSelectionsByCategory[typeId] = filterSelections
    }
    guard let selectedCategory else { return }
    await loadCategory(selectedCategory)
  }

  func applyFilters(_ selections: [String: String]) async {
    filterSelections = selections
    if let typeId = selectedCategory?.typeId {
      filterSelectionsByCategory[typeId] = filterSelections
    }
    guard let selectedCategory else { return }
    await loadCategory(selectedCategory)
  }

  func selectedFilterName(_ filter: SourceFilter) -> String {
    let selected = filterSelections[filter.key] ?? filter.initValue
    return filter.value.first(where: { $0.value == selected })?.name
      ?? filter.name
  }

  /// Compare against each filter's default because a source filter may have a
  /// non-empty initial value without the user changing anything.
  var hasActiveCategoryFilters: Bool {
    categoryFilters.contains { filter in
      let initial = filter.initValue ?? filter.value.first?.value ?? ""
      let current = filterSelections[filter.key] ?? initial
      return current != initial
    }
  }

  /// Default/empty filters share one key with prefetch (`extend: [:]`).
  private func categoryCacheKey(
    site: SiteConfiguration,
    typeId: String,
    selections: [String: String] = [:],
    filters: [SourceFilter] = []
  ) -> String {
    let active = selections.filter { key, value in
      if key == "source" { return false }
      guard let filter = filters.first(where: { $0.key == key }) else {
        return !value.isEmpty
      }
      let initial = filter.initValue ?? filter.value.first?.value ?? ""
      return value != initial
    }
    let part = active.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(
      separator: ","
    )
    return "\(site.key)|\(typeId)|\(part)"
  }

  func loadMore() async {
    guard !isLoadingMore,
      !isLoadingHome,
      let site = selectedSite,
      let category = selectedCategory,
      let pagecount = homeResult?.pagecount,
      currentPage < pagecount
    else {
      return
    }
    let generation = categoryLoadGeneration
    let typeId = category.typeId
    isLoadingMore = true
    loadMoreFailed = false
    defer { isLoadingMore = false }
    do {
      let nextPage = currentPage + 1
      var result = try await provider(for: site).categoryContent(
        typeId: category.typeId,
        page: nextPage,
        filter: true,
        extend: filterSelections
      )
      guard generation == categoryLoadGeneration, selectedCategory?.typeId == typeId else {
        return
      }
      if let menu = homeResult?.classes, !menu.isEmpty {
        result.classes = menu
      } else if result.classes.isEmpty {
        result.classes = []
      }
      if result.filters == nil {
        result.filters = homeResult?.filters
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
      guard generation == categoryLoadGeneration, selectedCategory?.typeId == typeId else {
        return
      }
      loadMoreFailed = true
      errorMessage = error.localizedDescription
    }
  }

  /// Load folder contents without replacing the VOD home grid (push pages use this).
  func loadFolder(_ item: MediaItem) async -> MediaResult? {
    guard
      let site = configuration.sites.first(where: { $0.key == item.sourceKey })
        ?? selectedSite
    else { return nil }
    do {
      let provider = try await provider(for: site)
      var result = try await provider.categoryContent(
        typeId: item.vodId,
        page: 1,
        filter: false,
        extend: [:]
      )
      attachSourceKey(site.key, to: &result)
      return result
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  @available(*, deprecated, message: "Use loadFolder + FolderBrowseView push instead")
  func openFolder(_ item: MediaItem) async {
    if let result = await loadFolder(item) {
      homeResult = result
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
    isLoadingSearch = true
    searchHasRun = false
    defer {
      isLoading = false
      isLoadingSearch = false
    }
    guard let coordinator else {
      searchHasRun = true
      searchSections = []
      searchFailures = []
      liveSearchResults = []
      searchFailureCount = 0
      lastRecoverableAction = .search
      errorMessage = "请先在设置中选择当前点播源"
      return
    }
    var sites: [SiteConfiguration]
    if multiSourceSearchEnabled {
      sites = onDeviceSites
    } else if let selected = selectedSite {
      sites = [selected]
    } else {
      sites = []
    }
    sites = sites.map { site in
      var copy = site
      copy.searchable = 1
      copy.quickSearch = 1
      return copy
    }
    guard !sites.isEmpty else {
      searchHasRun = true
      searchSections = []
      searchFailures = []
      liveSearchResults = []
      searchFailureCount = 0
      lastRecoverableAction = .search
      errorMessage = "请先在设置中选择当前点播源"
      return
    }
    lastRecoverableAction = .search
    let results = await coordinator.search(sites: sites, keyword: keyword)
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
    searchFailures = results.compactMap { key, result in
      guard case .failure(let error) = result else { return nil }
      let name = configuration.sites.first(where: { $0.key == key })?.name ?? key
      return SearchFailure(id: key, siteName: name, message: error.localizedDescription)
    }
    .sorted { $0.siteName.localizedCompare($1.siteName) == .orderedAscending }
    liveSearchResults =
      liveGroups
      .flatMap(\.channels)
      .filter { $0.name.localizedCaseInsensitiveContains(keyword) }
      .prefix(50)
      .map { $0 }
    searchHasRun = true
    if searchFailureCount > 0, searchSections.isEmpty, liveSearchResults.isEmpty {
      presentRecoverableError("搜索失败，请重试", action: .search)
    } else {
      errorMessage = nil
    }
  }

  func clearSearchHistory() {
    searchHistory = []
    persistence?.saveSearchHistory(searchHistory)
  }

  func preferredPlaybackFlag(sourceKey: String?, vodId: String) -> String? {
    guard let sourceKey else { return nil }
    return playbackFlagSelections["\(sourceKey)|\(vodId)"]
  }

  func setPreferredPlaybackFlag(_ flag: String, sourceKey: String?, vodId: String) {
    guard let sourceKey else { return }
    playbackFlagSelections["\(sourceKey)|\(vodId)"] = flag
    persistence?.savePlaybackFlagSelections(playbackFlagSelections)
  }

  func loadDetail(_ item: MediaItem) async {
    guard let sourceKey = item.sourceKey ?? selectedSite?.key,
      let site = configuration.sites.first(where: { $0.key == sourceKey })
    else { return }
    isLoading = true
    isLoadingDetail = true
    defer {
      isLoading = false
      isLoadingDetail = false
    }
    do {
      let provider = try await provider(for: site)
      var result = try await provider.detailContent(id: item.vodId)
      attachSourceKey(site.key, to: &result)
      detailResult = result
    } catch {
      lastRecoverableAction = .loadDetail(item)
      errorMessage = error.localizedDescription
    }
  }

  /// Resolve the same title in another on-device site. VOD IDs are scoped to a
  /// site, so switching the configuration address cannot reuse the old ID.
  func findItem(named title: String, in site: SiteConfiguration) async throws -> MediaItem? {
    try await findItem(named: title, in: site, preferredProviderKey: nil)
  }

  /// Prefer a CMS provider key embedded in `vod_id` (`sdzy|123`) when aggregating.
  func findItem(
    named title: String,
    in site: SiteConfiguration,
    preferredProviderKey: String?
  ) async throws -> MediaItem? {
    let provider = try await provider(for: site)
    let search = try await provider.searchContent(keyword: title, quick: false, page: 1)
    var candidates =
      search.list.isEmpty
      ? try await provider.homeContent().list
      : search.list
    if let preferredProviderKey, !preferredProviderKey.isEmpty {
      let scoped = candidates.filter { $0.vodId.hasPrefix(preferredProviderKey + "|") }
      // Strict: never fall back to another站 — that made 来源 chips look stuck.
      guard !scoped.isEmpty else { return nil }
      candidates = scoped
    }
    let target = Self.normalizedTitle(title)
    guard !target.isEmpty else { return nil }
    let ranked = candidates.compactMap { item -> (MediaItem, Int)? in
      guard let rank = Self.titleMatchRank(target: target, candidate: item.name) else {
        return nil
      }
      return (item, rank)
    }
    guard var best = ranked.min(by: { $0.1 < $1.1 })?.0 else { return nil }
    best.sourceKey = site.key
    return best
  }

  /// Provider keys (e.g. `sdzy`) that return a title match for the current show.
  func providerKeysHavingTitle(_ title: String) async -> Set<String> {
    guard let site = selectedSite else { return [] }
    let target = Self.normalizedTitle(title)
    guard !target.isEmpty else { return [] }
    do {
      let provider = try await provider(for: site)
      let search = try await provider.searchContent(keyword: title, quick: false, page: 1)
      var keys = Set<String>()
      for item in search.list {
        guard Self.titleMatchRank(target: target, candidate: item.name) != nil else { continue }
        guard let bar = item.vodId.firstIndex(of: "|") else { continue }
        let key = String(item.vodId[..<bar])
        if !key.isEmpty { keys.insert(key) }
      }
      return keys
    } catch {
      return []
    }
  }

  /// Episode/期 count for a CMS provider after resolving title → detail.
  /// Used to skip incomplete 来源 when picking 最优线路.
  func detailEpisodeCount(title: String, providerKey: String) async -> Int {
    guard let site = selectedSite, !providerKey.isEmpty else { return 0 }
    do {
      guard
        let item = try await findItem(
          named: title,
          in: site,
          preferredProviderKey: providerKey
        )
      else { return 0 }
      let provider = try await provider(for: site)
      let result = try await provider.detailContent(id: item.vodId)
      guard let detail = result.list.first else { return 0 }
      return Self.playbackEpisodeCount(playFrom: detail.playFrom, playURL: detail.playURL)
    } catch {
      return 0
    }
  }

  static func playbackEpisodeCount(playFrom: String?, playURL: String?) -> Int {
    EpisodeParser.lines(playFrom: playFrom, playURL: playURL)
      .map(\.episodes.count)
      .max() ?? 0
  }

  /// Parse 「更新至35集 / 全40集 / 更新第12期」 style progress from remarks.
  static func expectedUpdateCount(from remarks: String?) -> Int? {
    let text = remarks?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { return nil }
    let patterns = [
      #"更新(?:至|到|第)?\s*(\d+)\s*集"#,
      #"全\s*(\d+)\s*集"#,
      #"更新(?:至|到|第)?\s*(\d+)\s*期"#,
      #"第\s*(\d+)\s*期"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      guard let match = regex.firstMatch(in: text, range: range),
        match.numberOfRanges > 1,
        let numRange = Range(match.range(at: 1), in: text),
        let value = Int(text[numRange]),
        value > 0
      else { continue }
      return value
    }
    return nil
  }

  private static func normalizedTitle(_ title: String) -> String {
    title.lowercased().filter { character in
      !character.isWhitespace && !character.isPunctuation
    }
  }

  /// Lower is better. `nil` means no usable match.
  private static func titleMatchRank(target: String, candidate: String) -> Int? {
    let text = normalizedTitle(candidate)
    guard !text.isEmpty else { return nil }
    if text == target { return 0 }
    if text.hasPrefix(target) || target.hasPrefix(text) {
      return abs(text.count - target.count) + 1
    }
    if text.contains(target) || target.contains(text) {
      return abs(text.count - target.count) + 100
    }
    return nil
  }

  func resolvePlayback(
    item: MediaItem,
    episode: Episode,
    flag: String,
    startPositionOverride: Double? = nil
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
    // Prefer historyEntry (id, then name) so 跨线路 value 漂移仍能续播.
    let previous = historyEntry(for: item, episode: episode)
    // 已看完（靠近片尾）再进该集 → 从 0 重看，不要卡在 51:xx。
    let startPosition =
      startPositionOverride
      ?? Self.resumeStartPosition(
        position: previous?.position ?? 0,
        duration: previous?.duration ?? 0
      )
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
    // Provider-supplied danmaku only — B站/自定义自动匹配在 PlayerView 后台做，
    // 不挡首帧（否则电影开播可多等数秒「加载中」）。
    let danmaku = (result.danmaku ?? []).compactMap { item -> PlaybackDanmaku? in
      guard let url = URL(string: item.url, relativeTo: baseURL)?.absoluteURL else {
        return nil
      }
      return PlaybackDanmaku(url: url, name: item.name)
    }
    // Cloud ad-skip also runs in PlayerView after play starts.
    let skips = (result.skips ?? []).filter { segment in
      segment.end.map { $0 > segment.start } ?? (segment.start > 0)
    }
    return PlaybackRequest(
      url: url,
      headers: result.header ?? [:],
      formatHint: rawURL,
      startPosition: startPosition,
      subtitles: subtitles,
      danmaku: danmaku,
      skips: skips
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

  /// Restore cached channels when entering TV, without loading M3U feeds on app launch.
  func ensureLiveSourcesLoaded() async {
    guard liveGroups.isEmpty else { return }
    if !activeLiveCacheDigest.isEmpty,
      let cached = persistence?.loadLiveGroupsCache(for: activeLiveCacheDigest),
      !cached.isEmpty
    {
      liveGroups = cached
      liveRefreshStatus = "已读取 \(cached.count) 组 · \(liveChannelCount) 频道缓存"
      return
    }
    await refreshLiveSources()
  }

  func refreshLiveSources() async {
    guard let lives = configuration.lives, !lives.isEmpty else { return }
    let generation = liveLoadGeneration
    let baseURL = configurationBaseURL
    let task =
      liveRefreshTask
      ?? Task {
        await self.loadLiveGroups(lives, baseURL: baseURL)
      }
    liveRefreshTask = task
    isLoadingLive = true
    liveRefreshStatus = "正在刷新直播源…"
    let groups = await task.value
    guard generation == liveLoadGeneration else { return }
    liveRefreshTask = nil
    isLoadingLive = false
    if groups.isEmpty {
      liveRefreshStatus = "直播源刷新失败"
      return
    }
    liveGroups = groups
    liveRefreshStatus = "已刷新 \(groups.count) 组 · \(liveChannelCount) 频道"
    if !activeLiveCacheDigest.isEmpty {
      try? persistence?.saveLiveGroupsCache(groups, configurationDigest: activeLiveCacheDigest)
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

  /// Near the end — used for「已看完从 0 重看」and auto-next pause.
  /// Short clips (<30s): last 3s or ≥90% counts as finished.
  static func isNearEnd(position: Double, duration: Double) -> Bool {
    let pos = max(0, position)
    let dur = max(0, duration)
    guard dur > 5, pos > 1 else { return false }
    if dur <= 30 {
      return pos >= dur - 3 || pos >= dur * 0.9
    }
    return pos >= dur - 15 || pos >= dur * 0.92
  }

  /// Manual open of a finished episode → start at 0. Auto-next passes raw override instead.
  static func resumeStartPosition(position: Double, duration: Double) -> Double {
    if isNearEnd(position: position, duration: duration) { return 0 }
    return max(0, position)
  }

  /// Match by episodeId first; fall back to episode name when 线路 value drifts.
  func historyEntry(for item: MediaItem, episode: Episode) -> HistoryEntry? {
    let key = item.sourceKey ?? selectedSite?.key
    let matchesTitle: (HistoryEntry) -> Bool = {
      $0.sourceKey == key && $0.item.vodId == item.vodId
    }
    if let byId = history.first(where: {
      matchesTitle($0) && $0.episodeId == episode.value
    }) {
      return byId
    }
    let name = episode.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    return history.first(where: {
      matchesTitle($0)
        && $0.episodeName.trimmingCharacters(in: .whitespacesAndNewlines) == name
    })
  }

  func saveHistory(
    sourceKey: String, item: MediaItem, episode: Episode, position: Double, duration: Double
  ) async {
    guard !incognitoModeEnabled else { return }
    guard let library else { return }
    // Keep raw progress (including near-end) so auto-next can land there and pause.
    let storedPosition = max(0, position)
    do {
      try await library.saveHistory(
        HistoryEntry(
          sourceKey: sourceKey,
          item: item,
          episodeId: episode.value,
          episodeName: episode.name,
          position: storedPosition,
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
      let newLocalDigest = (try? ConfigurationDigest.sha256(decoded)) ?? ""
      // Background warehouse refresh often re-downloads the same JSON. Keep the
      // already-painted home instead of clearing → second「正在加载中」flash.
      let keepBrowse =
        !localConfigDigest.isEmpty
        && newLocalDigest == localConfigDigest
        && selectedSite != nil
        && decoded.sites.contains(where: { $0.key == selectedSite?.key })

      configuration = decoded
      configurationBaseURL = baseURL
      availableDepots = []
      try persistence?.saveConfiguration(data, baseURL: baseURL)
      localConfigDigest = newLocalDigest
      configDigest = newLocalDigest
      activeLiveCacheDigest = newLocalDigest
      if let bridgeClient {
        configDigest = try await bridgeClient.uploadConfiguration(decoded)
      }
      await coordinator?.invalidate()
      coordinator = makeCoordinator(client: bridgeClient)
      errorMessage = nil

      if keepBrowse {
        break
      }

      liveLoadGeneration += 1
      liveRefreshTask?.cancel()
      liveRefreshTask = nil
      isLoadingLive = false
      liveGroups = []
      liveRefreshStatus = nil
      selectedSite = nil
      homeResult = nil
      searchSections = []
      searchFailures = []
      liveSearchResults = []
      searchHasRun = false
      searchFailureCount = 0
      sourceTestStatus = nil
      loadedEPGSources = []
      loadingEPGSources = []
      epgPrograms = [:]
      epgStatus = nil
      let persistedKey = persistence?.selectedSiteKey
      pendingInitialSiteKey = persistedKey
      if selectInitialSite {
        await selectPendingInitialSite()
      }
    case .live(let name, let groups):
      liveLoadGeneration += 1
      liveRefreshTask?.cancel()
      liveRefreshTask = nil
      isLoadingLive = false
      activeLiveCacheDigest = ""
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

    isRestoringSession = true
    defer { isRestoringSession = false }

    if let currentURL = persistence.currentConnectionURL {
      currentConnection = sourceConnections.first { $0.url == currentURL && $0.enabled }
    }
    if currentConnection == nil {
      if let fallback = sourceConnections.first(where: \.enabled) {
        await loadConnection(fallback)
        if currentConnection != nil {
          await selectPendingInitialSite()
          return
        }
      }
      // No selected warehouse → never keep orphaned sites (e.g. leftover 虎牙).
      unloadConfiguration()
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
        unloadConfiguration()
        return
      }
    } else {
      // Connection exists but config file missing — reload from its URL.
      _ = await applyConfiguration(
        urlString: currentConnection!.url,
        selectInitialSite: false,
        displayURL: currentConnection?.displayAddress
      )
    }

    // Pin official ?v= before first home paint; routine warehouse refresh is
    // deferred so cold start is not blocked on a second config download.
    let needsOfficialPin = officialSourceNeedsUpdate
    if needsOfficialPin {
      await maybeAutoUpdateOfficialSource()
    }

    // First paint as soon as disk (or pinned) config is ready.
    await selectPendingInitialSite()
    if homeResult?.list.isEmpty == false {
      errorMessage = nil
    }

    if !needsOfficialPin, let connection = currentConnection {
      let connectionURL = connection.url
      let display = connection.displayAddress
      Task { @MainActor in
        // Keep cold start focused on the first home paint and poster requests.
        try? await Task.sleep(for: .seconds(2.5))
        guard currentConnection?.url == connectionURL else { return }
        errorMessage = nil
        let refreshed = await applyConfiguration(
          urlString: connectionURL,
          selectInitialSite: false,
          displayURL: display
        )
        if refreshed {
          // Same warehouse JSON keeps browse via keepBrowse — do not reload.
          if selectedSite == nil || homeResult?.list.isEmpty != false {
            await reloadHome()
          }
        } else if await restoreFallbackWarehouse(excluding: connectionURL) {
          errorMessage = nil
          await reloadHome()
        }
      }
    }
  }

  /// Prefer official COS, then any non-loopback saved line.
  private func restoreFallbackWarehouse(excluding url: String) async -> Bool {
    let excluded = url
    let remote = sourceConnections.filter { connection in
      guard connection.enabled, connection.url != excluded else { return false }
      guard let host = URL(string: connection.url)?.host?.lowercased() else { return false }
      return host != "127.0.0.1" && host != "localhost"
    }
    let ordered =
      remote.filter { $0.url.contains("dl.yychuiyan.com") || $0.url.contains("ios-sources.json") }
      + remote
    var seen = Set<String>()
    for candidate in ordered where seen.insert(candidate.url).inserted {
      if await applyConfiguration(
        urlString: candidate.url,
        selectInitialSite: false,
        displayURL: candidate.displayAddress
      ) {
        return true
      }
    }
    if await applyConfiguration(urlString: Self.officialSourceURL, selectInitialSite: false) {
      return true
    }
    return false
  }

  /// Ensures the VOD home has a selected site and loaded content after a
  /// configuration address is applied — including when the user is still on Settings.
  func ensureHomeContentLoaded() async {
    guard currentConnection != nil else { return }
    // restorePersistentState owns the first home load; racing it shows a second spinner.
    if isRestoringSession || isLoadingHome { return }
    if selectedSite == nil {
      await selectPendingInitialSite()
      return
    }
    if let list = homeResult?.list, !list.isEmpty { return }
    // selectSite already performed bounded transparent retries for an empty home.
    if homeResult == nil {
      await reloadHome()
    }
  }

  func reloadHome() async {
    guard currentConnection != nil else { return }
    if officialSourceNeedsUpdate {
      await maybeAutoUpdateOfficialSource()
    }
    if let site = selectedSite {
      // Soft refresh keeps the grid; selectSite reloads the active category when preserved.
      await selectSite(site, preserveBrowse: homeResult?.list.isEmpty == false)
    } else {
      await selectPendingInitialSite()
    }
  }

  var officialSourceNeedsUpdate: Bool {
    guard let connection = currentConnection else { return false }
    let candidates = [connection.url, connection.displayURL].compactMap { $0 }
    var onOfficial = false
    for raw in candidates {
      guard let components = URLComponents(string: raw),
        let host = components.host?.lowercased()
      else { continue }
      let officialHost =
        host == "dl.yychuiyan.com"
        || host == "firepick-1302621537.cos.ap-shanghai.myqcloud.com"
      guard officialHost, components.path.contains("ios-sources.json") else { continue }
      onOfficial = true
      let version = components.queryItems?.first(where: { $0.name == "v" })?.value
      if version == Self.officialSourceVersion {
        return false
      }
    }
    return onOfficial
  }

  /// Quietly refresh the official warehouse when the saved URL is behind.
  func maybeAutoUpdateOfficialSource() async {
    guard officialSourceNeedsUpdate, !didAutoUpdateOfficialSource, !isUpdatingOfficialSource else {
      return
    }
    didAutoUpdateOfficialSource = true
    isUpdatingOfficialSource = true
    statusToast = "配置更新中"
    defer {
      isUpdatingOfficialSource = false
      statusToast = nil
    }
    if !(await applyOfficialSource()) {
      didAutoUpdateOfficialSource = false
    }
  }

  @discardableResult
  func applyOfficialSource() async -> Bool {
    let ok = await applyConfiguration(
      urlString: Self.officialSourceURL,
      displayURL: Self.officialSourceURL
    )
    // Redirects / CDN responses often drop ?v=; pin the versioned official URL.
    if ok, let url = URL(string: Self.officialSourceURL) {
      recordConnection(url: url, displayURL: Self.officialSourceURL)
    }
    return ok
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
    guard currentConnection != nil, selectedSite == nil, !onDeviceSites.isEmpty else {
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
    guard !lives.isEmpty else { return [] }
    return await withTaskGroup(of: (Int, [LiveGroup]).self) { group in
      for (index, live) in lives.enumerated() {
        group.addTask {
          let groups = await self.loadLiveGroupEntry(live, baseURL: baseURL)
          return (index, groups)
        }
      }
      var ordered = Array(repeating: [LiveGroup](), count: lives.count)
      for await (index, groups) in group {
        ordered[index] = groups
      }
      return ordered.flatMap { $0 }
    }
  }

  private func loadLiveGroupEntry(
    _ live: LiveConfiguration,
    baseURL: URL?
  ) async -> [LiveGroup] {
    var output: [LiveGroup] = []
    if let embedded = live.groups {
      output.append(contentsOf: LiveParser.groups(from: embedded))
    }
    if let text = await loadLiveText(live, baseURL: baseURL),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      output.append(contentsOf: parseLiveGroups(text, live: live))
    }
    if let epg = live.epg,
      let resolved = URL(string: epg, relativeTo: baseURL)?.absoluteURL
    {
      for i in output.indices where output[i].epg == nil {
        output[i].epg = resolved.absoluteString
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
    return try await coordinator.provider(for: siteWithActiveCMSProviders(site))
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
      localConfigDigest = try ConfigurationDigest.sha256(configuration)
      configDigest = localConfigDigest
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
    searchFailures = []
    searchHasRun = false
    searchFailureCount = 0
    sourceTestStatus = nil
    persistence?.saveSelectedSiteKey(nil)
  }

  private func loadEmptyConfiguration() {
    configuration = .empty
    localConfigDigest = ""
    configDigest = ""
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

  /// Hide CMS 源站/站点 chips from Browse 筛选 (switch stations on the player page).
  private static func browseVisibleFilters(_ filters: [SourceFilter]) -> [SourceFilter] {
    filters.filter { filter in
      let key = filter.key.lowercased()
      let name = filter.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if key == "source" || key == "site" || key == "provider" { return false }
      if name == "源站" || name == "站点" || name == "来源" { return false }
      return true
    }
  }

}
