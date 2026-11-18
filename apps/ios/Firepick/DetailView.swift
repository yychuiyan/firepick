import FirepickCore
import FirepickPlayback
import FirepickProvider
import SwiftUI

private enum BestSourceCheckFeedback: Equatable {
  case currentBest
  case unavailable
  case switchFailed

  var title: String {
    switch self {
    case .currentBest: "已最佳"
    case .unavailable: "检测失败"
    case .switchFailed: "已恢复"
    }
  }

  var icon: String {
    switch self {
    case .currentBest: "checkmark"
    case .unavailable: "exclamationmark"
    case .switchFailed: "arrow.uturn.backward"
    }
  }
}

private struct PendingBestSource {
  let providerKey: String
  let stationName: String
  let latencyMS: Int?
  let mediaKBps: Int?
  let currentEpisodeCount: Int?
  let candidateEpisodeCount: Int?
  let replacement: MediaItem
  let itemID: String
  let startingProviderKey: String?
  let playGeneration: Int

  var discoversNewEpisodes: Bool {
    guard let currentEpisodeCount, let candidateEpisodeCount else { return false }
    return candidateEpisodeCount > currentEpisodeCount
  }
}

struct DetailView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var currentItem: MediaItem
  @State private var playback: PlaybackRequest?
  @State private var playbackEpisode: Episode?
  @State private var playbackFlag: String?
  @State private var resolvingEpisodeID: Episode.ID?
  @State private var playbackError: String?
  @State private var showingSourcePicker = false
  @State private var selectedFlag: String?
  @State private var reverseEpisodes = false
  /// 更多：展开导演 / 演员 / 简介（默认隐藏）。
  @State private var showingMoreMeta = false
  @State private var showingEpisodeDrawer = false
  @State private var didScrollToHistory = false
  @State private var isPlayerExpanded = false
  /// Frozen playable 来源 order (sorted once on enter). nil = still probing silently.
  @State private var orderedPlayableStations: [AppModel.CollectionStation]?
  @State private var probedStreamProfiles: [String: AppModel.ProviderStreamProbe] = [:]
  /// Stations dropped after unplayable / stuck — survives until probe finishes.
  @State private var droppedProviderKeys: Set<String> = []
  /// One soft recycle when every station was dropped — avoids sticky「暂无可用」.
  @State private var didRecyclePlayableStations = false
  /// One background 测速淘金 when the playable pool is exhausted.
  @State private var didSilentRefineStations = false
  /// User picked 来源 manually — skip auto optimal until stuck / episode change.
  @State private var userLockedSource = false
  /// User scrubbed / mid-watch — stop silent 换站 thrashing.
  @State private var playbackSettled = false
  /// Once any real frame appears, background optimization must never switch stations.
  @State private var hasShownVideoFrame = false
  @State private var lastPlaybackTime: Double = 0
  @State private var sourceSwitchHandoff: (position: Double, episodeName: String?)?
  @State private var isSwitchingSource = false
  @State private var playbackBitrateKBps: Int?
  @State private var isCheckingBestSource = false
  @State private var isAutomaticLatestEpisodeCheck = false
  @State private var bestSourceCheckFeedback: BestSourceCheckFeedback?
  @State private var bestSourceCheckFeedbackGeneration = 0
  @State private var bestSourceCheckTask: Task<Void, Never>?
  @State private var pendingBestSource: PendingBestSource?
  @State private var manualSwitchReady = false
  @State private var bestSourceToast: String?
  @State private var bestSourceToastGeneration = 0
  @State private var latestEpisodeCheckTask: Task<Void, Never>?
  @State private var didScheduleLatestEpisodeCheck = false
  /// Bumped before silent 换站 network work so PlayerView can freeze the live frame first.
  @State private var silentHandoffPulse = 0
  /// Keep 选集 highlight stable across source switches (episode `value` changes per站).
  @State private var focusEpisodeName: String?
  /// Bumped on each play() so rapid 切集 only applies the latest resolve.
  @State private var playGeneration = 0

  init(item: MediaItem) {
    _currentItem = State(initialValue: item)
  }

  private var detail: MediaItem {
    if let loaded = model.detailResult?.list.first, loaded.vodId == currentItem.vodId {
      return loaded
    }
    return currentItem
  }

  private var lines: [PlaybackLine] {
    EpisodeParser.rankedLines(
      EpisodeParser.lines(playFrom: detail.playFrom, playURL: detail.playURL)
    )
  }

  private var activeLine: PlaybackLine? {
    if let selectedFlag,
      let match = lines.first(where: { $0.name == selectedFlag })
    {
      return match
    }
    return lines.first
  }

  private var displayedEpisodes: [Episode] {
    let episodes = activeLine?.episodes ?? []
    return reverseEpisodes ? episodes.reversed() : episodes
  }

  private var historyEntry: HistoryEntry? {
    let sourceKey = detail.sourceKey ?? model.selectedSite?.key ?? ""
    let forVod = model.history.filter {
      $0.sourceKey == sourceKey && $0.item.vodId == detail.vodId
    }
    // Prefer the focused / current episode's row so resume is not another ep's clock.
    if let name = focusEpisodeName ?? playbackEpisode?.name,
      let match = forVod.first(where: { $0.episodeName == name })
    {
      return match
    }
    if let id = playbackEpisode?.value,
      let match = forVod.first(where: { $0.episodeId == id })
    {
      return match
    }
    return forVod.first
  }

  private var isDetailLoading: Bool {
    model.isLoadingDetail
      && model.detailResult?.list.first?.vodId != currentItem.vodId
      && lines.isEmpty
  }

  var body: some View {
    // Layout follows the real window:
    // - Immersive keys only when landscape (otherwise they look “功能键变了”)
    // - Half-screen + detail only when portrait and not expanded
    GeometryReader { geo in
      let windowPortrait = geo.size.height >= geo.size.width
      let windowLandscape = !windowPortrait
      let useImmersiveChrome = windowLandscape
      let playerFillsWindow = isPlayerExpanded || windowLandscape
      let showDetail = !isPlayerExpanded && windowPortrait
      VStack(spacing: 0) {
        inlinePlayer(
          fillsWindow: playerFillsWindow,
          immersive: useImmersiveChrome,
          containerSize: geo.size
        )
        if showDetail {
          detailScroll
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background {
        if playerFillsWindow {
          Color.black.ignoresSafeArea()
        } else {
          FirepickBackdrop()
        }
      }
      .simultaneousGesture(
        compactPlayerBackGesture(
          in: geo.size,
          windowPortrait: windowPortrait
        )
      )
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.hidden, for: .navigationBar)
    .toolbar(.hidden, for: .tabBar)
    .onDisappear {
      // Returning from detail/player can leave the tab bar without its material.
      TabBarChrome.restore()
      // Drop the playback binding so a sticky navigationDestination cannot keep
      // a live PlayerView (and audio) after popping back to 最近观看/搜索.
      playback = nil
    }
    .alert(
      "无法开始播放",
      isPresented: Binding(
        get: { playbackError != nil },
        set: { if !$0 { playbackError = nil } }
      )
    ) {
      Button("知道了", role: .cancel) {
        playbackError = nil
      }
      if lines.count > 1 {
        Button("换播放线路") {
          playbackError = nil
          Task { await playNextLine() }
        }
      }
      if model.onDeviceSites.count > 1 {
        Button("换点播源") {
          playbackError = nil
          showingSourcePicker = true
        }
      }
    } message: {
      Text(playbackError ?? "")
    }
    .sheet(isPresented: $showingSourcePicker) {
      SourcePickerView()
    }
    .task(id: currentItem.vodId) {
      // applyReplacement owns detail+play during 来源 switch (avoid clearing lines mid-flight).
      guard !isSwitchingSource else { return }
      latestEpisodeCheckTask?.cancel()
      latestEpisodeCheckTask = nil
      didScheduleLatestEpisodeCheck = false
      seedFocusFromHistory()
      // Keep previous detail on screen while the new one loads to avoid 选集 flash.
      if model.detailResult?.list.first?.vodId != currentItem.vodId,
        model.detailResult?.list.first?.name != currentItem.name
      {
        model.detailResult = nil
      }
      droppedProviderKeys = []
      didRecyclePlayableStations = false
      didSilentRefineStations = false
      playbackSettled = false
      hasShownVideoFrame = false
      playbackBitrateKBps = nil
      pendingBestSource = nil
      bestSourceToast = nil
      orderedPlayableStations = nil
      probedStreamProfiles = [:]
      // Seed from 采集站管理 current best pool immediately — don't wait on re-probe.
      seedPlayableStationsFromBestPool()
      let preferredProvider = model.preferredPlaybackProvider(for: currentItem)
      let currentProvider =
        currentItem.vodId.split(separator: "|", maxSplits: 1).first.map(String.init)
      var loadedPreferred = false
      if let preferredProvider,
        preferredProvider.providerKey != currentProvider
      {
        var candidate = currentItem
        candidate.vodId = preferredProvider.vodId
        if await model.loadDetail(candidate) {
          currentItem = candidate
          loadedPreferred = true
        }
      }
      if !loadedPreferred {
        await model.loadDetail(currentItem)
      }
      selectedFlag = model.preferredPlaybackFlag(
        sourceKey: currentItem.sourceKey ?? model.selectedSite?.key,
        vodId: currentItem.vodId
      )
      if let name = focusEpisodeName, let match = matchEpisode(named: name) {
        selectedFlag = match.line.name
      } else if selectedFlag == nil || !lines.contains(where: { $0.name == selectedFlag }) {
        selectedFlag = lines.first?.name
      } else if let best = lines.first,
        let selected = lines.first(where: { $0.name == selectedFlag }),
        EpisodeParser.lineMediaRank(best) > EpisodeParser.lineMediaRank(selected)
      {
        selectedFlag = best.name
      }
      // Prefer the management-page best node for first paint when different.
      if playback == nil, !lines.isEmpty {
        // Start the tapped source immediately. The cross-station search and
        // episode-count fan-out can saturate the connection and delay the first
        // HLS segments. Give the selected stream a short head start before
        // backfilling the ranked pool.
        let latencyProbe = Task {
          await probeCurrentSourceLatencyIfNeeded()
        }
        await playPrimary()
        let preparation = Task {
          try? await Task.sleep(for: .seconds(2))
          guard !Task.isCancelled, !hasShownVideoFrame, !playbackSettled else {
            return
          }
          await preparePlayableStationsIfNeeded(forceRebuild: true)
        }
        await latencyProbe.value
        await preparation.value
      }
    }
    .onChange(of: selectedFlag) { oldFlag, flag in
      guard let flag else { return }
      // 来源切换 owns playback via applyReplacement — don't restart from 0 here.
      guard !isSwitchingSource else { return }
      guard let oldFlag, oldFlag != flag, playback != nil else { return }
      let episodes = lines.first(where: { $0.name == flag })?.episodes ?? []
      let currentName = playbackEpisode?.name
      let next = episodes.first(where: { $0.name == currentName }) ?? episodes.first
      guard let next else { return }
      let resume = lastPlaybackTime > 1 ? lastPlaybackTime : nil
      Task { await play(episode: next, flag: flag, startPosition: resume) }
    }
    .onDisappear {
      bestSourceCheckTask?.cancel()
      bestSourceCheckTask = nil
      latestEpisodeCheckTask?.cancel()
      latestEpisodeCheckTask = nil
      isCheckingBestSource = false
      isAutomaticLatestEpisodeCheck = false
      bestSourceCheckFeedback = nil
      pendingBestSource = nil
      bestSourceToast = nil
      if isPlayerExpanded {
        OrientationBridge.enterPortraitThenUnlock()
      }
    }
  }

  private func compactPlayerBackGesture(
    in size: CGSize,
    windowPortrait: Bool
  ) -> some Gesture {
    DragGesture(minimumDistance: 18)
      .onEnded { value in
        guard playback != nil,
          !isPlayerExpanded,
          windowPortrait,
          PlayerBackGesturePolicy.shouldNavigateBack(
            startLocation: value.startLocation,
            translation: value.translation,
            stageWidth: size.width,
            allowsRightHalfStart: true
          )
        else { return }
        playback = nil
        dismiss()
      }
  }

  @ViewBuilder
  private func inlinePlayer(fillsWindow: Bool, immersive: Bool, containerSize: CGSize)
    -> some View
  {
    if let playback {
      PlayerView(
        request: playback,
        item: detail,
        episode: playbackEpisode,
        alternateURLs: fallbackURLs(
          for: playbackEpisode,
          flag: playbackFlag,
          primary: playback.url
        ),
        flag: playbackFlag,
        lineEpisodes: lines.first(where: { $0.name == playbackFlag })?.episodes
          ?? activeLine?.episodes
          ?? [],
        playbackLines: lines,
        chrome: immersive ? .immersive : .inline,
        layoutExpanded: fillsWindow,
        onExpand: {
          isPlayerExpanded = true
          OrientationBridge.enterLandscape()
        },
        onCollapse: {
          Task { @MainActor in
            await OrientationBridge.collapseToPortrait()
            isPlayerExpanded = false
          }
        },
        onPlayEpisode: { episode, flag, start in
          // Serialise 切集 from the player so rapid next taps don't stack resolves.
          Task { @MainActor in
            await play(episode: episode, flag: flag, startPosition: start)
          }
        },
        onPlaybackTimeChange: { time in
          // Large jump ⇒ user scrubbed — lock station so silent 测速 can't reset progress.
          if lastPlaybackTime > 2, abs(time - lastPlaybackTime) > 12 {
            playbackSettled = true
            userLockedSource = true
          }
          if time >= 5 { playbackSettled = true }
          lastPlaybackTime = time
        },
        onPlaybackReady: {
          hasShownVideoFrame = true
          playbackSettled = true
          if isCheckingBestSource {
            manualSwitchReady = true
          }
          if let key = playbackProviderKey {
            model.setPreferredPlaybackProvider(
              key,
              vodId: detail.vodId,
              for: detail
            )
          }
          Task { await probeCurrentSourceLatencyIfNeeded() }
          scheduleLatestEpisodeCheckIfNeeded()
        },
        onWatermarkAdDetected: {
          model.markWatermarkAdProvider(playbackProviderKey)
        },
        onPlaybackQualityMeasured: { height in
          model.recordProviderPlaybackQuality(playbackProviderKey, height: height)
        },
        onMeasuredBitrate: { bitrate in
          playbackBitrateKBps = bitrate
        },
        onUnplayable: {
          guard let key = playbackProviderKey else { return false }
          // Mid-watch / after scrub: never cascade 换站 (was black + progress→0).
          if hasShownVideoFrame || playbackSettled || lastPlaybackTime >= 8
            || userLockedSource
          {
            return false
          }
          userLockedSource = false
          return failoverToNextStation(from: key)
        },
        silentHandoffPulse: silentHandoffPulse,
        onCheckBestSource: {
          startBestSourceCheck()
        },
        isCheckingBestSource: isCheckingBestSource,
        bestSourceCheckStatus: bestSourceCheckStatus,
        externalToast: bestSourceToast,
        pendingBestSourceName: pendingBestSource?.stationName,
        pendingBestSourceTitle:
          pendingBestSource?.discoversNewEpisodes == true
          ? "发现新集"
          : "发现更佳线路",
        pendingBestSourceDetail: pendingBestSource.map(bestSourceChangeDescription),
        hasPendingBestSource: pendingBestSource != nil,
        onConfirmBestSourceSwitch: {
          confirmPendingBestSourceSwitch()
        },
        onCancelBestSourceSwitch: {
          cancelPendingBestSourceSwitch()
        }
      )
      // Stable within one DetailView — soft-reload keeps progress chrome on 来源 switch.
      .id("firepick-player")
      .modifier(
        PlayerFrameModifier(
          expanded: fillsWindow,
          containerWidth: containerSize.width,
          containerHeight: containerSize.height
        )
      )
    } else {
      ZStack {
        Color.black
        if resolvingEpisodeID != nil || isDetailLoading || !lines.isEmpty {
          ProgressView()
            .tint(.white)
        } else {
          Text("没有可播放线路")
            .font(.subheadline)
            .foregroundStyle(.white)
        }
        VStack {
          HStack {
            Button {
              dismiss()
            } label: {
              Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
            }
            Spacer()
          }
          Spacer()
        }
      }
      .aspectRatio(16.0 / 9.0, contentMode: .fit)
      .frame(maxWidth: .infinity)
      .clipped()
    }
  }

  private var detailScroll: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(detail.name)
              .font(.title3.weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(3)
            if let score = displayScore {
              Text(score)
                .font(.title3.weight(.bold))
                .foregroundStyle(.orange)
                .monospacedDigit()
            }
          }
          HStack(spacing: 8) {
            if isCompleted {
              Text("完结")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.orange, in: Capsule())
            }
            if let remarks = displayRemarks {
              Text(remarks)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          if !factLine.isEmpty {
            Text(factLine)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          if hasExpandableMeta {
            Button {
              showingMoreMeta = true
            } label: {
              HStack(spacing: 4) {
                Text("更多")
                Image(systemName: "chevron.down")
                  .font(.caption2.weight(.semibold))
              }
              .font(.subheadline)
              .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
          }

          if isDetailLoading && !isSwitchingSource {
            HStack(spacing: 8) {
              ProgressView().tint(.orange)
              Text("加载线路中…")
                .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
          } else if lines.isEmpty && !isSwitchingSource {
            ContentUnavailableView(
              "没有可播放线路",
              systemImage: "play.slash",
              description: Text(model.errorMessage ?? "详情接口没有返回标准选集数据。")
            )
            if model.errorMessage != nil {
              Button("重试加载详情") {
                Task { await model.loadDetail(currentItem) }
              }
              .buttonStyle(.bordered)
              .tint(.orange)
            }
          } else if !lines.isEmpty || isSwitchingSource {
            sourceStatusRow
              .padding(.top, 8)
            if let pendingBestSource {
              bestSourceConfirmationCard(pendingBestSource)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            // 线路（gsyun/gsm3u8 等）静默选用，不在播放页展示。
            if !displayedEpisodes.isEmpty {
              HStack(spacing: 8) {
                Text("选集")
                  .font(.body)
                  .foregroundStyle(.primary)
                if displayedEpisodes.count > 1 {
                  Button {
                    reverseEpisodes.toggle()
                  } label: {
                    Image(systemName: "arrow.up.arrow.down")
                      .font(.caption.weight(.semibold))
                      .foregroundStyle(.orange)
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel(reverseEpisodes ? "正序" : "倒序")
                }
                Spacer()
                if displayedEpisodes.count > 8 {
                  Button {
                    showingEpisodeDrawer = true
                  } label: {
                    Image(systemName: "square.grid.2x2")
                      .foregroundStyle(.orange)
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("全部选集")
                }
              }
              .padding(.top, 6)
              ScrollViewReader { episodeProxy in
                ScrollView(.horizontal) {
                  HStack(spacing: 8) {
                    ForEach(displayedEpisodes) { episode in
                      episodeChip(episode)
                        // Stable across 来源 switches (value/URL changes per站).
                        .id(episode.name)
                    }
                  }
                }
                .scrollIndicators(.hidden)
                .onAppear {
                  scrollToFocusedEpisodeStrip(using: episodeProxy)
                }
                .onChange(of: displayedEpisodes.map(\.value)) { _, _ in
                  scrollToFocusedEpisodeStrip(using: episodeProxy)
                }
                .onChange(of: playbackEpisode?.value) { _, _ in
                  scrollToFocusedEpisodeStrip(using: episodeProxy)
                }
              }
              .sheet(isPresented: $showingEpisodeDrawer) {
                episodeDrawer
              }
            }
          }
        }
        .sheet(isPresented: $showingMoreMeta) {
          moreMetaDrawer
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 24)
      }
      .onChange(of: displayedEpisodes.map(\.value)) { _, _ in
        scrollToHistoryEpisode(using: proxy)
      }
      .onChange(of: selectedFlag) { _, _ in
        didScrollToHistory = false
        scrollToHistoryEpisode(using: proxy)
      }
    }
  }

  /// Provider key embedded in `vod_id` as `iqiyi|12345`.
  private var playbackProviderKey: String? {
    let id = detail.vodId
    guard let bar = id.firstIndex(of: "|") else { return nil }
    let key = String(id[..<bar])
    return key.isEmpty ? nil : key
  }

  private var playbackSourceName: String {
    if let key = playbackProviderKey {
      if let station = model.collectionStations.first(where: {
        stationProviderKey($0) == key
      }) {
        return station.name
      }
      return Self.providerDisplayNames[key] ?? key
    }
    let name = model.selectedSite?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? "拾萤精选" : name
  }

  private static let providerDisplayNames: [String: String] = [
    "iqiyi": "爱奇艺",
    "sdzy": "闪电",
    "dytt": "电影天堂",
    "maoyan": "猫眼",
    "lzcaiji": "量子",
    "lzi": "量子",
    "zy360": "360资源",
    "jisu": "极速",
    "modu": "魔都",
    "ffzy": "非凡",
    "ffzy_cj": "非凡",
    "bfzy": "暴风",
    "zuid": "最大",
    "xinlang": "新浪",
    "subo": "速播",
    "jinying": "金鹰",
    "uku": "U酷",
    "guangsu": "光速",
    "hongniu": "红牛",
    "moduanime": "魔都动漫",
    "ruyi": "如意",
    "haohua": "豪华",
    "yzzy": "优质",
    "zy1080": "1080",
    "xgzy": "西瓜资源",
    "hongniu3": "红牛备",
    "huya": "虎牙",
    "wujin_com": "无尽",
    "jinyingzy": "金鹰",
    "wolong": "卧龙",
    "maotai": "茅台",
    "ikun": "iKun",
    "baidu": "百度",
    "douban": "豆瓣",
    "piaoling": "飘零",
    "suoni": "索尼",
    "heimuer": "木耳",
    "niuniu": "牛牛",
    "yaya": "丫丫",
    "yinghua": "樱花",
    "kuaiche": "快车",
    "feisu": "飞速",
    "kuaikan": "快看",
    "xiongzhang": "熊掌",
    "qihu": "奇虎",
    "kuaiyun": "快云",
    "wwzy": "旺旺",
    "hw8": "华为吧",
    "okzy": "OK",
    "taopian": "淘片",
  ]

  private func stationProviderKey(_ station: AppModel.CollectionStation) -> String {
    station.id.hasPrefix("cms:") ? String(station.id.dropFirst(4)) : station.id
  }

  private var hasExpandableMeta: Bool {
    let hasDirector = !(detail.director?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    let hasActor = !(detail.actor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    let hasContent = !(detail.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    return hasDirector || hasActor || hasContent
  }

  /// Instant seed: 采集站管理里已经排好的最佳节点顺序（不等待重新测速）.
  private func seedPlayableStationsFromBestPool() {
    guard orderedPlayableStations == nil else { return }
    let all = model.collectionStations
    orderedPlayableStations = all.filter {
      !droppedProviderKeys.contains(stationProviderKey($0))
    }
  }

  /// Probe title hits + latency + episode completeness, then freeze playable list
  /// (完整最新集/期优先，同档再按延迟：最快的为默认最优).
  private func preparePlayableStationsIfNeeded(forceRebuild: Bool = false) async {
    if !forceRebuild, orderedPlayableStations != nil { return }
    let all = model.collectionStations
    guard all.count > 1 else {
      orderedPlayableStations = all
      return
    }
    async let keysTask = model.providerKeysHavingTitle(detail.name)
    // Prefer cached badges from 获取最佳线路; only ping if still empty.
    let needsLatency = model.collectionStationLatencyMS.isEmpty
    async let latencyTask: Void = {
      if needsLatency {
        await model.probeActivePoolLatenciesOnly()
      }
    }()
    let keys = await keysTask
    await latencyTask
    var available = keys
    if let current = playbackProviderKey {
      available.insert(current)
    }
    let playable = all.filter { available.contains(stationProviderKey($0)) }
    let remarkTarget = AppModel.expectedUpdateCount(from: detail.remarks)
    let currentCount = EpisodeUpdatePolicy.episodeCount(in: detail)
    // Movie / single-shot: skip per-station detail fan-out (was the slow path).
    let looksLikeSeries = (remarkTarget ?? 0) > 1 || currentCount > 1
    let complete: [AppModel.CollectionStation]
    // Before the first frame, source availability and latency are enough to
    // recover quickly. Fanning out to eight station details + HLS manifests
    // here competes with the stream we are trying to start.
    if !looksLikeSeries || (!hasShownVideoFrame && !playbackSettled) {
      complete = playable
    } else {
      let counts = await episodeCounts(for: playable)
      let catalogMax = max(counts.values.max() ?? 0, currentCount)
      let target = max(remarkTarget ?? 0, catalogMax)
      let filtered = playable.filter { station in
        (counts[stationProviderKey(station)] ?? 0) >= target
      }
      if !filtered.isEmpty {
        complete = filtered
      } else {
        let bar = max(catalogMax, 1)
        complete = playable.filter { station in
          (counts[stationProviderKey(station)] ?? 0) >= bar
        }
      }
    }
    // Sort by ad/quality/reliability first, then latency. Never reshuffle later.
    let ranked = rankedStationsForPlayback(complete)
    // Honor stations already marked dead while first paint was probing.
    orderedPlayableStations = ranked.filter {
      !droppedProviderKeys.contains(stationProviderKey($0))
    }
  }

  private func rankedStationsForPlayback(
    _ stations: [AppModel.CollectionStation]
  ) -> [AppModel.CollectionStation] {
    stations.sorted { a, b in
      let aAd = model.hasWatermarkAdProvider(stationProviderKey(a))
      let bAd = model.hasWatermarkAdProvider(stationProviderKey(b))
      if aAd != bAd { return !aAd }
      let aKey = stationProviderKey(a)
      let bKey = stationProviderKey(b)
      let aQuality = probedStreamProfiles[aKey]?.quality
      let bQuality = probedStreamProfiles[bKey]?.quality
      let aq = model.providerQualityRank(
        aKey,
        measuredHeight: aQuality.map { min($0.width, $0.height) } ?? 0,
        measuredBandwidth: aQuality?.bandwidth ?? 0
      )
      let bq = model.providerQualityRank(
        bKey,
        measuredHeight: bQuality.map { min($0.width, $0.height) } ?? 0,
        measuredBandwidth: bQuality?.bandwidth ?? 0
      )
      if aq.tier != bq.tier { return aq.tier > bq.tier }
      if aq.reliability != bq.reliability { return aq.reliability > bq.reliability }
      if aq.bandwidth != bq.bandwidth { return aq.bandwidth > bq.bandwidth }
      let ma = model.collectionStationLatencyMS[a.id]
      let mb = model.collectionStationLatencyMS[b.id]
      switch (ma, mb) {
      case let (l?, r?): return l < r
      case (_?, nil): return true
      case (nil, _?): return false
      case (nil, nil): return false
      }
    }
  }

  /// Parallel detail fetch → episode/期 counts keyed by CMS provider.
  private func episodeCounts(
    for stations: [AppModel.CollectionStation]
  ) async -> [String: Int] {
    let title = detail.name
    var counts: [String: Int] = [:]
    if let current = playbackProviderKey {
      let n = AppModel.playbackEpisodeCount(
        playFrom: detail.playFrom,
        playURL: detail.playURL
      )
      if n > 0 { counts[current] = n }
    }
    // Prefer already-fast stations when capping fan-out.
    let ranked = stations.sorted { a, b in
      let ma = model.collectionStationLatencyMS[a.id]
      let mb = model.collectionStationLatencyMS[b.id]
      switch (ma, mb) {
      case let (l?, r?): return l < r
      case (_?, nil): return true
      default: return false
      }
    }
    let keys = Array(ranked.map(stationProviderKey).filter { counts[$0] == nil }.prefix(8))
    let preferredEpisodeName = focusEpisodeName ?? playbackEpisode?.name
    await withTaskGroup(of: (String, AppModel.ProviderStreamProbe).self) { group in
      for (index, key) in keys.enumerated() {
        group.addTask {
          let probe = await model.providerStreamProbe(
            title: title,
            providerKey: key,
            preferredEpisodeName: preferredEpisodeName,
            inspectQuality: index < 4
          )
          return (key, probe)
        }
      }
      for await (key, probe) in group {
        counts[key] = probe.episodeCount
        if probe.quality != nil {
          probedStreamProfiles[key] = probe
        }
      }
    }
    return counts
  }

  @discardableResult
  private func failoverToNextStation(from failedKey: String) -> Bool {
    model.recordProviderPlaybackStall(failedKey)
    // Mid-watch: don't cascade stations after a stall / seek.
    if hasShownVideoFrame || playbackSettled || lastPlaybackTime >= 8 {
      dropUnplayableStation(failedKey)
      return false
    }
    userLockedSource = false
    dropUnplayableStation(failedKey)
    if let next = orderedPlayableStations?.first(where: {
      stationProviderKey($0) != failedKey
    }) {
      let nextKey = stationProviderKey(next)
      Task { await switchCollectionStation(nextKey, silent: true, userInitiated: false) }
      return true
    }
    // Play-first: probe may still be running — finish it, then switch.
    if orderedPlayableStations == nil {
      Task {
        await preparePlayableStationsIfNeeded()
        guard let next = orderedPlayableStations?.first(where: {
          stationProviderKey($0) != failedKey
        })
        else { return }
        await switchCollectionStation(
          stationProviderKey(next),
          silent: true,
          userInitiated: false
        )
      }
      return true
    }
    // All chips dropped — recycle once so UI is not stuck on「暂无可用」and playback can retry.
    if !didRecyclePlayableStations {
      didRecyclePlayableStations = true
      droppedProviderKeys = [failedKey]
      orderedPlayableStations = nil
      Task {
        await preparePlayableStationsIfNeeded()
        guard !hasShownVideoFrame, !playbackSettled else { return }
        if let next = orderedPlayableStations?.first(where: {
          stationProviderKey($0) != failedKey
        }) ?? orderedPlayableStations?.first {
          await switchCollectionStation(
            stationProviderKey(next),
            silent: true,
            userInitiated: false
          )
          return
        }
        // Still empty — silently re-probe CMS pool for a fresher best line.
        await silentlyRefineBestStations(excluding: failedKey)
      }
      return true
    }
    if !didSilentRefineStations {
      Task { await silentlyRefineBestStations(excluding: failedKey) }
      return true
    }
    return false
  }

  /// Background 测速淘金 + rebuild playable order, then switch to the new best station.
  private func silentlyRefineBestStations(excluding failedKey: String) async {
    guard !didSilentRefineStations, !hasShownVideoFrame else { return }
    didSilentRefineStations = true
    // Already mid-watch — refresh badges only, don't interrupt playback.
    if playbackSettled || lastPlaybackTime >= 8 {
      await model.probeCollectionStationLatencies()
      return
    }
    await model.probeCollectionStationLatencies()
    droppedProviderKeys = [failedKey]
    await preparePlayableStationsIfNeeded(forceRebuild: true)
    guard !playbackSettled, lastPlaybackTime < 8 else { return }
    guard let next = orderedPlayableStations?.first(where: {
      stationProviderKey($0) != failedKey
    }) ?? orderedPlayableStations?.first
    else { return }
    await switchCollectionStation(
      stationProviderKey(next),
      silent: true,
      userInitiated: false
    )
  }

  private func dropUnplayableStation(_ providerKey: String) {
    droppedProviderKeys.insert(providerKey)
    guard var stations = orderedPlayableStations else { return }
    stations.removeAll { stationProviderKey($0) == providerKey }
    orderedPlayableStations = stations
  }

  /// 当前站摘要 + 手动检测。检测本身不冻结画面，只有确认候选后才换源。
  private var sourceStatusRow: some View {
    HStack(alignment: .center, spacing: 7) {
      HStack(spacing: 7) {
        Text("来源")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        if isSwitchingSource {
          ProgressView()
            .controlSize(.mini)
            .tint(.secondary)
        } else {
          Circle()
            .fill(sourceSpeedColor)
            .frame(width: 6, height: 6)
        }
        Text(sourceStatusValue)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.86)
          .layoutPriority(1)
        if !isSwitchingSource, let latencyText = sourceLatencyText {
          Text("·")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
          Text(latencyText)
            .font(.caption2.monospacedDigit().weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
      }
      .lineLimit(1)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(sourceAccessibilityLabel)
      Spacer(minLength: 4)
      if let bitrate = playbackBitrateKBps {
        Label(formattedMediaSpeed(bitrate), systemImage: "speedometer")
          .font(.caption.monospacedDigit().weight(.semibold))
          .foregroundStyle(mediaBitrateColor(bitrate))
          .labelStyle(.titleAndIcon)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
      if !isSwitchingSource {
        bestSourceCheckButton
      }
    }
    .padding(.vertical, 2)
  }

  private var bestSourceCheckButton: some View {
    Button {
      startBestSourceCheck()
    } label: {
      HStack(spacing: 4) {
        if isCheckingBestSource, !isAutomaticLatestEpisodeCheck {
          ProgressView()
            .controlSize(.mini)
            .tint(.orange)
        } else if let feedback = bestSourceCheckFeedback {
          Image(systemName: feedback.icon)
            .font(.caption2.weight(.bold))
        } else {
          Image(systemName: "scope")
            .font(.caption2.weight(.semibold))
        }
        Text(bestSourceCheckTitle)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(bestSourceCheckColor)
      .frame(minWidth: 52, minHeight: 26)
      .padding(.horizontal, 7)
      .background(bestSourceCheckColor.opacity(0.10), in: Capsule())
      .overlay {
        Capsule().strokeBorder(bestSourceCheckColor.opacity(0.20), lineWidth: 0.5)
      }
      .fixedSize(horizontal: true, vertical: false)
    }
    .buttonStyle(.plain)
    .disabled(isCheckingBestSource || playback == nil || pendingBestSource != nil)
    .accessibilityLabel(bestSourceCheckAccessibilityLabel)
  }

  private var bestSourceCheckTitle: String {
    if isCheckingBestSource {
      return isAutomaticLatestEpisodeCheck ? "检测" : "检测中"
    }
    if pendingBestSource != nil { return "待确认" }
    if let feedback = bestSourceCheckFeedback { return feedback.title }
    return "检测"
  }

  private var bestSourceCheckColor: Color {
    if pendingBestSource != nil { return .orange }
    switch bestSourceCheckFeedback {
    case .currentBest: return .green
    case .unavailable: return .secondary
    case .switchFailed: return .orange
    case nil: return .orange
    }
  }

  private var bestSourceCheckAccessibilityLabel: String {
    if isCheckingBestSource {
      return isAutomaticLatestEpisodeCheck ? "正在静默检查新集" : "正在检测最佳播放线路"
    }
    if pendingBestSource != nil { return "发现更佳线路，等待确认" }
    switch bestSourceCheckFeedback {
    case .currentBest: return "当前线路已是最佳"
    case .unavailable: return "线路检测失败"
    case .switchFailed: return "新线路加载失败，已恢复当前线路"
    case nil: return "检测最佳播放线路"
    }
  }

  private func bestSourceConfirmationCard(_ pending: PendingBestSource) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 9) {
        Image(systemName: "bolt.horizontal.circle.fill")
          .font(.title3)
          .foregroundStyle(.orange)
        VStack(alignment: .leading, spacing: 3) {
          Text(pending.discoversNewEpisodes ? "发现新集" : "发现更佳线路")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
          Text(bestSourceChangeDescription(pending))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 6)
        Button {
          cancelPendingBestSourceSwitch()
        } label: {
          Image(systemName: "xmark")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Color.secondary.opacity(0.09), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("保留当前线路")
      }

      HStack(spacing: 10) {
        Button("保留当前") {
          cancelPendingBestSourceSwitch()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: Capsule())

        Button(pending.discoversNewEpisodes ? "切换并更新" : "切换线路") {
          confirmPendingBestSourceSwitch()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.orange, in: Capsule())
      }
    }
    .padding(12)
    .background(Color.orange.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(Color.orange.opacity(0.18), lineWidth: 0.75)
    }
    .accessibilityElement(children: .contain)
  }

  private func bestSourceChangeDescription(_ pending: PendingBestSource) -> String {
    let latency = pending.latencyMS.map { " · \($0)ms" } ?? ""
    let media = pending.mediaKBps.map { " · 媒体约 \($0) KB/s" } ?? ""
    let episode = playbackEpisode?.name ?? focusEpisodeName
    let keep =
      episode.map { "将保持 \($0) 和当前播放进度。" }
      ?? "将保持当前播放进度。"
    if let current = pending.currentEpisodeCount,
      let candidate = pending.candidateEpisodeCount,
      candidate > current
    {
      return
        "\(pending.stationName) 已更新至第\(candidate)集，当前来源为第\(current)集"
        + "\(latency)\(media)。\(keep)"
    }
    return "\(pending.stationName)\(latency)\(media)。\(keep)"
  }

  private var sourceStatusValue: String {
    if isSwitchingSource { return "切换线路中" }
    let name = playbackSourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "拾萤精选" : name
  }

  private var sourceLatencyMS: Int? {
    guard !isSwitchingSource, let stationID = sourceStationID else { return nil }
    return model.collectionStationLatencyMS[stationID]
  }

  private var sourceStationID: String? {
    guard let key = playbackProviderKey else { return nil }
    return sourceStation?.id ?? "cms:\(key)"
  }

  private var sourceStation: AppModel.CollectionStation? {
    guard let key = playbackProviderKey else { return nil }
    return model.collectionStations.first(where: { stationProviderKey($0) == key })
  }

  private var isSourceLatencyProbing: Bool {
    guard let stationID = sourceStationID else { return false }
    return model.probingCollectionStationIDs.contains(stationID)
  }

  private var sourceSpeedColor: Color {
    if let latency = sourceLatencyMS {
      if latency <= 300 { return .green }
      if latency <= 900 { return .orange }
      return .red
    }
    if let bitrate = playbackBitrateKBps {
      return mediaBitrateColor(bitrate)
    }
    return .secondary
  }

  private var sourceLatencyText: String? {
    if isSourceLatencyProbing { return "测速中" }
    if let latency = sourceLatencyMS { return "\(latency)ms" }
    if playbackBitrateKBps != nil {
      return sourceStation == nil ? "已记忆" : "未测速"
    }
    return "待测"
  }

  private func mediaBitrateColor(_ bitrate: Int) -> Color {
    if bitrate >= 300 { return .green }
    if bitrate >= 80 { return .orange }
    return .red
  }

  private func formattedMediaSpeed(_ bitrate: Int) -> String {
    if bitrate >= 1024 {
      return String(format: "%.1f MB/s", Double(bitrate) / 1024)
    }
    return "\(bitrate) KB/s"
  }

  private var sourceAccessibilityLabel: String {
    guard !isSwitchingSource else { return "当前来源 切换线路中" }
    if isSourceLatencyProbing {
      return "当前来源 \(sourceStatusValue)，正在测速"
    }
    guard let latency = sourceLatencyMS else {
      if let bitrate = playbackBitrateKBps {
        return "当前来源 \(sourceStatusValue)，媒体速度约 \(bitrate) KB/s，接口尚未测速"
      }
      return "当前来源 \(sourceStatusValue)，尚未测速"
    }
    let speed = latency <= 300 ? "快速" : latency <= 900 ? "一般" : "较慢"
    let media =
      playbackBitrateKBps.map { "，媒体速度约 \($0) KB/s" }
      ?? ""
    return "当前来源 \(sourceStatusValue)，响应 \(latency) 毫秒，\(speed)\(media)"
  }

  private func probeCurrentSourceLatencyIfNeeded() async {
    guard let stationID = sourceStationID,
      model.collectionStationLatencyMS[stationID] == nil,
      !model.probingCollectionStationIDs.contains(stationID),
      let station = model.collectionStations.first(where: { $0.id == stationID })
    else { return }
    await model.probeCollectionStationLatency(station)
  }

  private var bestSourceCheckStatus: String? {
    if isSwitchingSource, isCheckingBestSource {
      return "正在切换最佳线路"
    }
    if isCheckingBestSource {
      return isAutomaticLatestEpisodeCheck ? nil : "正在检测最佳线路"
    }
    switch bestSourceCheckFeedback {
    case .currentBest: return "当前线路已是最佳"
    case .unavailable: return "线路检测失败"
    case .switchFailed: return "新线路加载失败，已恢复当前线路"
    case nil: return nil
    }
  }

  private func startBestSourceCheck() {
    guard !isCheckingBestSource, !isSwitchingSource, pendingBestSource == nil else { return }
    bestSourceCheckTask?.cancel()
    bestSourceCheckTask = Task {
      await checkBestSource(automatic: false)
      bestSourceCheckTask = nil
    }
  }

  private func scheduleLatestEpisodeCheckIfNeeded() {
    guard !didScheduleLatestEpisodeCheck,
      playback != nil,
      !isSwitchingSource,
      (activeLine?.episodes.count ?? 0) > 1
    else { return }
    didScheduleLatestEpisodeCheck = true
    latestEpisodeCheckTask?.cancel()
    latestEpisodeCheckTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled, playback != nil, hasShownVideoFrame,
        currentItem.vodId == detail.vodId
      else { return }
      await checkBestSource(automatic: true)
      latestEpisodeCheckTask = nil
    }
  }

  /// Detection never interrupts playback. It refreshes the current detail,
  /// compares all advertised episode counts, then only starts a seamless
  /// handoff after the user confirms a verified candidate.
  private func checkBestSource(automatic: Bool) async {
    guard !isCheckingBestSource, !isSwitchingSource, playback != nil else { return }
    if automatic, !model.shouldCheckLatestEpisodes(for: currentItem) { return }
    let startingItemID = currentItem.vodId
    let startingProvider = playbackProviderKey
    let startingGeneration = playGeneration
    bestSourceCheckFeedbackGeneration += 1
    bestSourceCheckFeedback = nil
    pendingBestSource = nil
    isCheckingBestSource = true
    isAutomaticLatestEpisodeCheck = automatic
    defer {
      isCheckingBestSource = false
      isAutomaticLatestEpisodeCheck = false
      model.markLatestEpisodesChecked(for: currentItem)
    }

    guard let site = model.selectedSite else {
      if !automatic { showBestSourceFeedback(.unavailable) }
      return
    }

    // A stale in-memory detail made a源 that had already reached 20 appear as
    // 19. Refresh the current source before suggesting any switch.
    if await model.loadDetail(currentItem),
      let refreshed = model.detailResult?.list.first(where: {
        $0.vodId == currentItem.vodId
      })
    {
      currentItem = refreshed
    }
    guard !Task.isCancelled,
      currentItem.vodId == startingItemID,
      playbackProviderKey == startingProvider,
      playGeneration == startingGeneration
    else { return }

    let currentEpisodeCount = EpisodeUpdatePolicy.episodeCount(in: detail)
    let advertisedCounts = await model.providerEpisodeCountsHavingTitle(detail.name)
    guard !Task.isCancelled else { return }
    let allStations = (orderedPlayableStations ?? model.collectionStations)
      .filter { stationProviderKey($0) != startingProvider }
    let latestStations = rankedStationsForPlayback(
      allStations.filter {
        (advertisedCounts[stationProviderKey($0)] ?? 0) > currentEpisodeCount
      }
    )
    let hasNewEpisodes = !latestStations.isEmpty
    let candidates =
      hasNewEpisodes
      ? Array(latestStations.prefix(3))
      : Array(rankedStationsForPlayback(allStations).prefix(3))

    guard !candidates.isEmpty else {
      if !automatic { markCurrentSourceBest() }
      return
    }
    if automatic, !hasNewEpisodes {
      return
    }

    let currentEpisodeName = playbackEpisode?.name ?? focusEpisodeName
    let currentKBps = playbackBitrateKBps ?? 0
    let minimumSpeedCandidateKBps = max(
      140,
      Int((Double(currentKBps) * 1.1).rounded())
    )
    var selectedPending: PendingBestSource?

    for station in candidates {
      guard !Task.isCancelled else { return }
      let providerKey = stationProviderKey(station)
      let replacement: MediaItem
      do {
        guard
          let match = try await model.findItem(
            named: detail.name,
            in: site,
            preferredProviderKey: providerKey,
            metadata: model.aiMetadata(for: detail)
          )
        else { continue }
        replacement = match
      } catch {
        continue
      }

      let candidateLoaded = await model.loadDetail(replacement)
      guard !Task.isCancelled, candidateLoaded,
        let candidateDetail = model.detailResult?.list.first(where: {
          $0.vodId == replacement.vodId
        }),
        let episodeMatch = candidateEpisodeMatch(
          currentEpisodeName,
          in: candidateDetail
        )
      else { continue }

      let candidateEpisodeCount = EpisodeUpdatePolicy.episodeCount(in: candidateDetail)
      let discoversNewEpisodes = candidateEpisodeCount > currentEpisodeCount
      if hasNewEpisodes, !discoversNewEpisodes { continue }
      let minimumCandidateKBps =
        discoversNewEpisodes ? 120 : minimumSpeedCandidateKBps

      // Interface latency is not playback quality. Require the candidate to
      // deliver a real media segment before asking the user to switch.
      guard let measuredKBps = await model.playbackKBps(
        for: replacement,
        episode: episodeMatch.episode,
        flag: episodeMatch.line.name,
        timeout: 4
      ),
        measuredKBps >= minimumCandidateKBps
      else { continue }

      selectedPending = PendingBestSource(
        providerKey: providerKey,
        stationName: station.name,
        latencyMS: model.collectionStationLatencyMS[station.id],
        mediaKBps: measuredKBps,
        currentEpisodeCount: currentEpisodeCount,
        candidateEpisodeCount: candidateEpisodeCount,
        replacement: replacement,
        itemID: startingItemID,
        startingProviderKey: startingProvider,
        playGeneration: startingGeneration
      )
      break
    }

    guard !Task.isCancelled else { return }
    guard currentItem.vodId == startingItemID,
      playbackProviderKey == startingProvider,
      playGeneration == startingGeneration
    else { return }
    guard let selectedPending else {
      if !automatic { markCurrentSourceBest() }
      return
    }
    if !selectedPending.discoversNewEpisodes,
      let measured = selectedPending.mediaKBps,
      let currentNow = playbackBitrateKBps,
      currentNow >= 300,
      measured < Int((Double(currentNow) * 1.1).rounded())
    {
      if !automatic { markCurrentSourceBest() }
      return
    }

    withAnimation(.easeInOut(duration: 0.18)) {
      pendingBestSource = selectedPending
    }
  }

  private func confirmPendingBestSourceSwitch() {
    guard let pending = pendingBestSource else { return }
    guard pending.itemID == currentItem.vodId,
      pending.playGeneration == playGeneration,
      playbackProviderKey == pending.startingProviderKey
    else {
      cancelPendingBestSourceSwitch()
      showBestSourceFeedback(.unavailable)
      return
    }

    withAnimation(.easeInOut(duration: 0.15)) {
      pendingBestSource = nil
    }
    let rollbackItem = currentItem
    bestSourceCheckTask?.cancel()
    manualSwitchReady = false
    isCheckingBestSource = true
    bestSourceCheckTask = Task {
      beginSourceHandoff(seamless: true)
      await applyReplacement(pending.replacement, seamless: true)
      guard !Task.isCancelled else {
        isCheckingBestSource = false
        return
      }

      if playbackProviderKey == pending.providerKey {
        // Keep the old still visible while the confirmed source produces its
        // first stable frame. A stream that never gets there is rolled back.
        isSwitchingSource = true
        for _ in 0..<30 where !manualSwitchReady {
          try? await Task.sleep(for: .milliseconds(200))
          if Task.isCancelled { break }
        }
      }

      if Task.isCancelled {
        isCheckingBestSource = false
        return
      }
      if playbackProviderKey == pending.providerKey, !manualSwitchReady {
        isSwitchingSource = false
        beginSourceHandoff(seamless: true)
        await applyReplacement(rollbackItem, seamless: true)
        showBestSourceFeedback(.switchFailed)
        showBestSourceToast("新线路加载失败，已恢复当前线路")
      } else if playbackProviderKey != pending.providerKey {
        showBestSourceFeedback(.unavailable)
      } else {
        let episodeUpdate =
          pending.discoversNewEpisodes
          ? "，已更新至第\(pending.candidateEpisodeCount ?? 0)集"
          : ""
        showBestSourceToast("已切换到 \(pending.stationName)\(episodeUpdate)")
      }
      isSwitchingSource = false
      isCheckingBestSource = false
      bestSourceCheckTask = nil
    }
  }

  private func cancelPendingBestSourceSwitch() {
    withAnimation(.easeInOut(duration: 0.15)) {
      pendingBestSource = nil
    }
  }

  private func candidateEpisodeMatch(
    _ episodeName: String?,
    in item: MediaItem
  ) -> (line: PlaybackLine, episode: Episode)? {
    let candidateLines = EpisodeParser.rankedLines(
      EpisodeParser.lines(playFrom: item.playFrom, playURL: item.playURL)
    )
    guard let episodeName else {
      return candidateLines.first.flatMap { line in
        line.episodes.first.map { (line, $0) }
      }
    }
    if let exact = candidateLines.lazy.compactMap({ line -> (PlaybackLine, Episode)? in
      line.episodes.first(where: { $0.name == episodeName }).map { (line, $0) }
    }).first {
      return exact
    }
    guard let index = Self.episodeIndex(episodeName) else { return nil }
    return candidateLines.lazy.compactMap({ line -> (PlaybackLine, Episode)? in
      line.episodes.first(where: { Self.episodeIndex($0.name) == index }).map {
        (line, $0)
      }
    }).first
  }

  private func showBestSourceFeedback(_ feedback: BestSourceCheckFeedback) {
    bestSourceCheckFeedbackGeneration += 1
    let generation = bestSourceCheckFeedbackGeneration
    bestSourceCheckFeedback = feedback
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(2.4))
      guard generation == bestSourceCheckFeedbackGeneration else { return }
      bestSourceCheckFeedback = nil
    }
  }

  private func markCurrentSourceBest() {
    showBestSourceFeedback(.currentBest)
    showBestSourceToast("当前已是最优线路")
  }

  private func showBestSourceToast(_ message: String) {
    bestSourceToastGeneration += 1
    let generation = bestSourceToastGeneration
    bestSourceToast = message
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(3.2))
      guard generation == bestSourceToastGeneration else { return }
      bestSourceToast = nil
    }
  }

  private var displayRemarks: String? {
    guard
      let remarks = detail.remarks?.trimmingCharacters(in: .whitespacesAndNewlines),
      !remarks.isEmpty,
      !remarks.contains("完结")
    else { return nil }
    if remarks.range(
      of: #"^第\s*\d+\s*[集期话]$"#,
      options: .regularExpression
    ) != nil {
      return "更新至" + remarks.replacingOccurrences(of: "第", with: "")
    }
    return remarks
  }

  /// Strict Douban score only; CMS scores are not presented as Douban ratings.
  private var displayScore: String? {
    if let douban = detail.doubanScore, douban > 0 {
      return String(format: "%.1f", douban)
    }
    return nil
  }

  private var isCompleted: Bool {
    let remarks = detail.remarks ?? ""
    if remarks.contains("完结") || remarks.contains("已完结") { return true }
    if remarks.range(of: #"全\s*\d+\s*集"#, options: .regularExpression) != nil,
      !remarks.contains("更新")
    {
      return true
    }
    return false
  }

  private var factLine: String {
    var parts: [String] = []
    if let year = detail.year?.trimmingCharacters(in: .whitespacesAndNewlines), !year.isEmpty {
      parts.append("年份：\(year)")
    }
    if let area = detail.area?.trimmingCharacters(in: .whitespacesAndNewlines), !area.isEmpty {
      parts.append("地区：\(area)")
    }
    if let type = detail.typeName?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty {
      parts.append("类型：\(type)")
    }
    return parts.joined(separator: " ")
  }

  private func episodeChip(_ episode: Episode) -> some View {
    let isOn = isFocusedEpisode(episode)
    return Button {
      Task { await play(episode: episode) }
    } label: {
      Text(episode.name)
        .font(.subheadline)
        .foregroundStyle(isOn ? Color.white : Color.primary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
    .buttonStyle(.plain)
    .background(
      isOn ? Color.orange : Color.secondary.opacity(0.12),
      in: Capsule()
    )
  }

  /// Prefer episode name so 来源 switches don't flash the highlight off/on.
  private func isFocusedEpisode(_ episode: Episode) -> Bool {
    // Playing URL wins — avoids lighting every 期 when names collide or fuzzy index misfires.
    if let playbackEpisode, playbackEpisode.value == episode.value {
      return true
    }
    if let focusEpisodeName, !focusEpisodeName.isEmpty {
      if episode.name == focusEpisodeName {
        let sameName = displayedEpisodes.filter { $0.name == focusEpisodeName }
        if sameName.count > 1, let playbackEpisode {
          return episode.value == playbackEpisode.value
        }
        return true
      }
      // Fuzzy index only for 第N集/期 style — never for 2024-01-06期 dates
      // (old all-digit Int made many 期 look like one episode).
      if Self.canFuzzyMatchEpisodeNames(focusEpisodeName, episode.name),
        let a = Self.episodeIndex(focusEpisodeName),
        let b = Self.episodeIndex(episode.name),
        a == b
      {
        return true
      }
      return false
    }
    if let playbackEpisode {
      return playbackEpisode.name == episode.name
    }
    if let history = historyEntry {
      if history.episodeId == episode.value { return true }
      if history.episodeName == episode.name { return true }
      if Self.canFuzzyMatchEpisodeNames(history.episodeName, episode.name),
        let a = Self.episodeIndex(history.episodeName),
        let b = Self.episodeIndex(episode.name),
        a == b
      {
        return true
      }
    }
    if let hint = titleHistoryHint {
      if hint.name == episode.name { return true }
      if Self.canFuzzyMatchEpisodeNames(hint.name, episode.name),
        let a = Self.episodeIndex(hint.name),
        let b = Self.episodeIndex(episode.name),
        a == b
      {
        return true
      }
      // While we already know the resume episode, never light up 第1集 as a fallback.
      return false
    }
    return activeLine?.episodes.first?.value == episode.value
  }

  /// History for this vodId, or same title under another 来源.
  private var titleHistoryHint: (name: String, position: Double)? {
    if let history = historyEntry {
      return (history.episodeName, history.position)
    }
    let target = Self.normalizedTitleKey(currentItem.name)
    guard !target.isEmpty else { return nil }
    guard
      let match = model.history.first(where: {
        Self.normalizedTitleKey($0.item.name) == target && !$0.episodeName.isEmpty
      })
    else { return nil }
    return (match.episodeName, match.position)
  }

  private static func normalizedTitleKey(_ title: String) -> String {
    title.lowercased().filter { character in
      !character.isWhitespace && !character.isPunctuation
    }
  }

  private func seedFocusFromHistory() {
    guard focusEpisodeName == nil else { return }
    if let hint = titleHistoryHint {
      focusEpisodeName = hint.name
    }
  }

  /// Keep the playing / pending episode highlighted — never swap the chip for a spinner.
  private var focusedEpisodeValue: String? {
    if let playbackEpisode {
      return playbackEpisode.value
    }
    if let name = focusEpisodeName,
      let match = displayedEpisodes.first(where: { $0.name == name })
        ?? displayedEpisodes.first(where: {
          Self.canFuzzyMatchEpisodeNames($0.name, name)
            && Self.episodeIndex($0.name) == Self.episodeIndex(name)
        })
    {
      return match.value
    }
    return historyEntry?.episodeId ?? activeLine?.episodes.first?.value
  }

  private var usesEpisodeCards: Bool {
    let names = activeLine?.episodes.map(\.name) ?? []
    guard names.count > 1 else { return false }
    let numericCount = names.filter(Self.isNumericEpisodeName).count
    return numericCount * 2 < names.count
  }

  private static func isNumericEpisodeName(_ name: String) -> Bool {
    let trimmed = name
      .replacingOccurrences(of: "第", with: "")
      .replacingOccurrences(of: "集", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.allSatisfy(\.isNumber)
  }

  private var moreMetaDrawer: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if let director = detail.director, !director.isEmpty {
            Text("导演")
              .font(.body.weight(.semibold))
            Text(Self.plainText(director))
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          if let actor = detail.actor, !actor.isEmpty {
            Text("演员")
              .font(.body.weight(.semibold))
            Text(Self.plainText(actor))
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          if let content = detail.content, !content.isEmpty {
            Text("简介")
              .font(.body.weight(.semibold))
            Text(Self.plainText(content))
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineSpacing(4)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(16)
      }
      .navigationTitle("详情")
      .navigationBarTitleDisplayMode(.inline)
    }
    // Fixed height drawer — long 导演/演员/简介 scroll inside.
    .presentationDetents([.height(420)])
    .presentationDragIndicator(.visible)
  }

  private var episodeDrawer: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVGrid(
            columns: [
              GridItem(
                .adaptive(minimum: usesEpisodeCards ? 148 : 88),
                spacing: 8
              )
            ],
            spacing: 8
          ) {
            ForEach(displayedEpisodes) { episode in
              episodeCell(episode)
            }
          }
          .padding()
        }
        .onAppear {
          didScrollToHistory = false
          scrollToFocusedEpisode(using: proxy)
        }
        .onChange(of: reverseEpisodes) { _, _ in
          didScrollToHistory = false
          scrollToFocusedEpisode(using: proxy)
        }
      }
      .navigationTitle("选集")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(reverseEpisodes ? "正序" : "倒序") {
            reverseEpisodes.toggle()
          }
        }
      }
    }
    // Fixed height drawer — long lists scroll inside.
    .presentationDetents([.height(420)])
    .presentationDragIndicator(.visible)
  }

  private func episodeCell(_ episode: Episode) -> some View {
    let isOn = isFocusedEpisode(episode)
    return Button {
      showingEpisodeDrawer = false
      Task { await play(episode: episode) }
    } label: {
      Text(episode.name)
        .font(.subheadline)
        .foregroundStyle(isOn ? Color.white : Color.primary)
        .lineLimit(usesEpisodeCards ? 3 : 1)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: usesEpisodeCards ? 64 : 36)
        .padding(.horizontal, 8)
        .background(
          isOn ? Color.orange : Color.secondary.opacity(0.12),
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
    .buttonStyle(.plain)
    // Prefer value so duplicate 期 titles don't share one SwiftUI identity.
    .id(episode.id)
  }

  private var focusedEpisodeScrollID: String? {
    if let playbackEpisode,
      let match = displayedEpisodes.first(where: { $0.value == playbackEpisode.value })
    {
      return match.id
    }
    if let focusEpisodeName,
      let match = displayedEpisodes.first(where: { $0.name == focusEpisodeName })
    {
      return match.id
    }
    if let value = focusedEpisodeValue,
      let match = displayedEpisodes.first(where: { $0.value == value })
    {
      return match.id
    }
    return nil
  }

  private func scrollToFocusedEpisode(using proxy: ScrollViewProxy) {
    guard !didScrollToHistory, let focusID = focusedEpisodeScrollID else { return }
    didScrollToHistory = true
    Task { @MainActor in
      // Wait for the sheet detent + LazyVGrid to finish their first layout.
      try? await Task.sleep(for: .milliseconds(350))
      withAnimation(.easeInOut(duration: 0.25)) {
        proxy.scrollTo(focusID, anchor: .center)
      }
    }
  }

  private func scrollToHistoryEpisode(using proxy: ScrollViewProxy) {
    scrollToFocusedEpisode(using: proxy)
  }

  private func scrollToFocusedEpisodeStrip(using proxy: ScrollViewProxy) {
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(120))
      guard let episode = displayedEpisodes.first(where: isFocusedEpisode) else { return }
      withAnimation(.easeInOut(duration: 0.22)) {
        proxy.scrollTo(episode.name, anchor: .center)
      }
    }
  }

  private func playNextLine() async {
    guard lines.count > 1 else { return }
    let names = lines.map(\.name)
    let current = selectedFlag ?? names.first ?? ""
    let index = names.firstIndex(of: current) ?? 0
    let nextName = names[(index + 1) % names.count]
    let episodes = lines.first(where: { $0.name == nextName })?.episodes ?? []
    let next = episodes.first(where: { $0.name == playbackEpisode?.name }) ?? episodes.first
    let hadPlayback = playback != nil
    selectedFlag = nextName
    guard !hadPlayback, let next else { return }
    await play(episode: next, flag: nextName)
  }

  private func switchSource(to site: SiteConfiguration) async {
    let previousSite = model.selectedSite
    beginSourceHandoff(seamless: playback != nil)
    await model.selectSite(site)
    do {
      guard let replacement = try await model.findItem(named: detail.name, in: site) else {
        if let previousSite {
          await model.selectSite(previousSite)
        }
        clearSourceHandoff()
        playbackError = "「\(site.name)」没有找到《\(detail.name)》"
        return
      }
      await applyReplacement(replacement, seamless: lastPlaybackTime > 1)
    } catch {
      if let previousSite {
        await model.selectSite(previousSite)
      }
      clearSourceHandoff()
      playbackError = error.localizedDescription
    }
  }

  /// Switch CMS provider inside 拾萤 without reloading the whole home catalog.
  private func switchCollectionStation(
    _ providerKey: String,
    silent: Bool = false,
    userInitiated: Bool = false
  ) async {
    guard let site = model.selectedSite else { return }
    if playbackProviderKey == providerKey { return }
    if userInitiated {
      // Manual pick: honor this station; don't bounce to auto-optimal afterward.
      userLockedSource = true
    }
    beginSourceHandoff(seamless: silent && playback != nil)
    do {
      guard
        let replacement = try await model.findItem(
          named: detail.name,
          in: site,
          preferredProviderKey: providerKey,
          metadata: model.aiMetadata(for: detail)
        )
      else {
        clearSourceHandoff()
        dropUnplayableStation(providerKey)
        if silent, !userInitiated, failoverToNextStation(from: providerKey) {
          return
        }
        if userInitiated {
          userLockedSource = false
        }
        if !silent {
          playbackError =
            "「\(Self.providerDisplayNames[providerKey] ?? providerKey)」没有找到《\(detail.name)》"
        }
        return
      }
      await applyReplacement(replacement, seamless: silent && lastPlaybackTime > 1)
    } catch {
      clearSourceHandoff()
      if silent, !userInitiated, failoverToNextStation(from: providerKey) {
        return
      }
      if userInitiated {
        userLockedSource = false
      }
      if !silent {
        playbackError = error.localizedDescription
      }
    }
  }

  private func beginSourceHandoff(seamless: Bool = false) {
    isSwitchingSource = true
    seedFocusFromHistory()
    let episodeName = playbackEpisode?.name ?? focusEpisodeName ?? titleHistoryHint?.name
    if let episodeName { focusEpisodeName = episodeName }
    // Prefer live clock; never fall back to 0 when we already had progress.
    let live = max(lastPlaybackTime, sourceSwitchHandoff?.position ?? 0)
    let position =
      live > 1
      ? live
      : (historyEntry?.position ?? titleHistoryHint?.position ?? 0)
    sourceSwitchHandoff = (position, episodeName)
    if seamless {
      // Freeze the live frame before network work so the swap feels invisible.
      silentHandoffPulse += 1
    }
  }

  private func clearSourceHandoff() {
    sourceSwitchHandoff = nil
    isSwitchingSource = false
  }

  private func applyReplacement(_ replacement: MediaItem, seamless: Bool = false) async {
    // Keep 选集 highlight + handoff; only swap the stream once new detail is ready.
    // Do not clear `playback` — PlayerView soft-reloads so the picture stays up.
    let keepEpisodeName = sourceSwitchHandoff?.episodeName ?? focusEpisodeName
    showingEpisodeDrawer = false
    await model.loadDetail(replacement)
    currentItem = replacement
    if let keepEpisodeName,
      let match = await matchEpisodeWithAI(named: keepEpisodeName)
    {
      selectedFlag = match.line.name
      focusEpisodeName = match.episode.name
    } else {
      selectedFlag = lines.first?.name
    }
    // Do not re-probe / re-sort 来源 on switch — order stays frozen from enter.
    if !lines.isEmpty {
      await playPrimary()
    }
    isSwitchingSource = false
  }

  private func playPrimary() async {
    let handoff = sourceSwitchHandoff
    sourceSwitchHandoff = nil
    let preferredName =
      handoff?.episodeName ?? focusEpisodeName ?? historyEntry?.episodeName ?? titleHistoryHint?.name
    // Source handoff keeps the live clock. Fresh open applies「已看完 → 0」.
    let resumePosition: Double? = {
      if let handoff { return max(0, handoff.position) }
      if let entry = historyEntry {
        return AppModel.resumeStartPosition(
          position: entry.position,
          duration: entry.duration
        )
      }
      // Title-level hint has no duration — keep raw position.
      return titleHistoryHint.map { max(0, $0.position) }
    }()

    if let preferredName, let match = await matchEpisodeWithAI(named: preferredName) {
      selectedFlag = match.line.name
      focusEpisodeName = match.episode.name
      await play(
        episode: match.episode,
        flag: match.line.name,
        startPosition: resumePosition.map { max(0, $0) }
      )
      return
    }

    if let history = historyEntry,
      let line = lines.first(where: {
        $0.episodes.contains(where: { $0.value == history.episodeId })
      }),
      let episode = line.episodes.first(where: { $0.value == history.episodeId })
    {
      selectedFlag = line.name
      focusEpisodeName = episode.name
      await play(episode: episode, flag: line.name, startPosition: resumePosition.map { max(0, $0) })
      return
    }
    guard let line = activeLine, let episode = line.episodes.first else { return }
    await play(episode: episode, flag: line.name, startPosition: resumePosition.map { max(0, $0) })
  }

  private func matchEpisode(named name: String) -> (line: PlaybackLine, episode: Episode)? {
    if let line = lines.first(where: { $0.episodes.contains(where: { $0.name == name }) }),
      let episode = line.episodes.first(where: { $0.name == name })
    {
      return (line, episode)
    }
    guard let index = Self.episodeIndex(name) else { return nil }
    for line in lines {
      if let episode = line.episodes.first(where: { Self.episodeIndex($0.name) == index }) {
        return (line, episode)
      }
    }
    return nil
  }

  private func matchEpisodeWithAI(
    named name: String
  ) async -> (line: PlaybackLine, episode: Episode)? {
    if let local = matchEpisode(named: name) {
      return local
    }
    var candidates: [DeepSeekEpisodeCandidate] = []
    var lookup: [String: (PlaybackLine, Episode)] = [:]
    for (lineIndex, line) in lines.enumerated() {
      for (episodeIndex, episode) in line.episodes.enumerated()
      where candidates.count < 200
      {
        let id = "l\(lineIndex)e\(episodeIndex)"
        candidates.append(.init(id: id, name: episode.name))
        lookup[id] = (line, episode)
      }
    }
    guard !candidates.isEmpty,
      let matchedID = await model.aiEpisodeMatchID(
        mediaTitle: detail.name,
        currentEpisode: name,
        candidates: candidates
      ),
      let matched = lookup[matchedID]
    else { return nil }
    if let expected = Self.episodeIndex(name),
      let actual = Self.episodeIndex(matched.1.name),
      expected != actual
    {
      return nil
    }
    return matched
  }

  /// True only when both labels are plain episode numbers (第3集 / 03), not dates.
  private static func canFuzzyMatchEpisodeNames(_ a: String, _ b: String) -> Bool {
    isStrictEpisodeNumberLabel(a) && isStrictEpisodeNumberLabel(b)
  }

  private static func isStrictEpisodeNumberLabel(_ name: String) -> Bool {
    episodeIndex(name) != nil
  }

  /// Parse 第12集 / 第12期 / 12 — not concatenated calendar digits like 20240106.
  private static func episodeIndex(_ name: String) -> Int? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let patterns = [
      #"^第\s*0*(\d+)\s*[集期话]$"#,
      #"^0*(\d+)$"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
      guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
        match.numberOfRanges >= 2,
        let capture = Range(match.range(at: 1), in: trimmed),
        let value = Int(trimmed[capture])
      else { continue }
      return value
    }
    return nil
  }

  private func fallbackURLs(for episode: Episode?, flag: String?, primary: URL) -> [URL] {
    guard let episode else { return [] }
    var urls: [URL] = []
    func add(_ raw: String) {
      guard let url = URL(string: raw),
        url.scheme == "http" || url.scheme == "https",
        url != primary,
        !urls.contains(url)
      else { return }
      urls.append(url)
    }
    for line in lines where line.name != flag {
      let match = line.episodes.first(where: { $0.name == episode.name }) ?? line.episodes.first
      if let match { add(match.value) }
    }
    return urls.sorted { mediaRank($0) > mediaRank($1) }
  }

  private func mediaRank(_ url: URL) -> Int {
    let text = url.absoluteString.lowercased()
    if text.contains(".m3u8") { return 2 }
    if text.contains(".mp4") { return 1 }
    return 0
  }

  private func play(
    episode: Episode,
    flag: String? = nil,
    startPosition: Double? = nil
  ) async {
    playGeneration += 1
    let generation = playGeneration
    let lineName = flag ?? activeLine?.name ?? lines.first?.name ?? ""
    let previousEpisodeName = playbackEpisode?.name ?? focusEpisodeName
    // Focus the chip immediately; loading stays in the player, not on 选集.
    focusEpisodeName = episode.name
    playbackEpisode = episode
    playbackFlag = lineName
    resolvingEpisodeID = episode.id
    playbackError = nil
    defer {
      if generation == playGeneration {
        resolvingEpisodeID = nil
      }
    }

    // 切集：只解除手动锁，便于之后卡住再自动换源。
    // 不要在这里 await 换最优源——会先黑屏再卡 2–3s 才播新集。
    let episodeChanged =
      previousEpisodeName != nil && previousEpisodeName != episode.name
    if episodeChanged {
      pendingBestSource = nil
      // Freeze the outgoing frame before resolving the next episode. Waiting
      // until PlaybackRequest changes can expose the loading/poster layer for a
      // frame, which reads as a visible flash.
      if playback != nil {
        silentHandoffPulse += 1
      }
      userLockedSource = false
      playbackSettled = false
      hasShownVideoFrame = false
      lastPlaybackTime = 0
    }

    do {
      // nil override → resolvePlayback 用该集历史（id/name）；显式 override 给上/下一集续播点。
      let resolved = try await model.resolvePlayback(
        item: detail,
        episode: episode,
        flag: lineName,
        startPositionOverride: startPosition
      )
      guard generation == playGeneration else { return }
      playback = resolved
    } catch {
      guard generation == playGeneration else { return }
      if let key = playbackProviderKey, failoverToNextStation(from: key) {
        // Silent 换源 — keep player on loading chrome, no error toast.
        return
      }
      playbackError = error.localizedDescription
      if let key = playbackProviderKey {
        dropUnplayableStation(key)
      }
    }
  }

  private static func plainText(_ html: String) -> String {
    html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
      .replacingOccurrences(of: "&nbsp;", with: " ")
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&apos;", with: "'")
  }
}

private struct PlayerFrameModifier: ViewModifier {
  let expanded: Bool
  let containerWidth: CGFloat
  let containerHeight: CGFloat

  func body(content: Content) -> some View {
    // Single modifier chain — never `if/else` around `content` or SwiftUI
    // remounts AVPlayer (reload flash + seek back a few seconds).
    let width = max(containerWidth, 1)
    let height = expanded ? max(containerHeight, 1) : width * 9.0 / 16.0
    content
      .frame(width: width, height: height)
      .frame(maxWidth: .infinity, maxHeight: expanded ? .infinity : nil)
      .clipped()
      .ignoresSafeArea(.container, edges: expanded ? .all : [])
  }
}
