import FirepickCore
import FirepickPlayback
import SwiftUI

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
  @State private var showingSourceStationPicker = false
  @State private var selectedFlag: String?
  @State private var reverseEpisodes = false
  /// 更多：展开导演 / 演员 / 简介（默认隐藏）。
  @State private var showingMoreMeta = false
  @State private var showingEpisodeDrawer = false
  @State private var didScrollToHistory = false
  @State private var isPlayerExpanded = false
  /// Frozen playable 来源 order (sorted once on enter). nil = still probing silently.
  @State private var orderedPlayableStations: [AppModel.CollectionStation]?
  /// User picked 来源 manually — skip auto optimal until stuck / episode change.
  @State private var userLockedSource = false
  @State private var lastPlaybackTime: Double = 0
  @State private var sourceSwitchHandoff: (position: Double, episodeName: String?)?
  @State private var isSwitchingSource = false
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
    EpisodeParser.lines(playFrom: detail.playFrom, playURL: detail.playURL)
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
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.hidden, for: .navigationBar)
    .toolbar(.hidden, for: .tabBar)
    .onDisappear {
      // Returning from detail/player can leave the tab bar without its material.
      TabBarChrome.restore()
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
      seedFocusFromHistory()
      // Keep previous detail on screen while the new one loads to avoid 选集 flash.
      if model.detailResult?.list.first?.vodId != currentItem.vodId,
        model.detailResult?.list.first?.name != currentItem.name
      {
        model.detailResult = nil
      }
      selectedFlag = model.preferredPlaybackFlag(
        sourceKey: currentItem.sourceKey ?? model.selectedSite?.key,
        vodId: currentItem.vodId
      )
      async let stationsReady: Void = preparePlayableStationsIfNeeded()
      await model.loadDetail(currentItem)
      await stationsReady
      if let name = focusEpisodeName, let match = matchEpisode(named: name) {
        selectedFlag = match.line.name
      } else if selectedFlag == nil || !lines.contains(where: { $0.name == selectedFlag }) {
        selectedFlag = lines.first?.name
      }
      // Prefer the fastest playable 来源 once; user can still change via dropdown.
      if await autoSelectOptimalSourceIfNeeded() {
        return
      }
      if playback == nil, !lines.isEmpty {
        await playPrimary()
      }
    }
    .onChange(of: selectedFlag) { oldFlag, flag in
      guard let flag else { return }
      model.setPreferredPlaybackFlag(
        flag,
        sourceKey: detail.sourceKey ?? model.selectedSite?.key,
        vodId: detail.vodId
      )
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
      if isPlayerExpanded {
        OrientationBridge.enterPortraitThenUnlock()
      }
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
          lastPlaybackTime = time
        },
        onUnplayable: {
          guard let key = playbackProviderKey else { return false }
          // Stuck: unlock manual choice and resume auto optimal failover.
          userLockedSource = false
          return failoverToNextStation(from: key)
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
            if let remarks = detail.remarks?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remarks.isEmpty,
              !remarks.contains("完结")
            {
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
            Text("来源")
              .font(.body)
              .foregroundStyle(.primary)
              .padding(.top, 8)
            sourceChips
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
      return Self.providerDisplayNames[key] ?? key
    }
    let name = model.selectedSite?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? "拾萤" : name
  }

  private static let providerDisplayNames: [String: String] = [
    "iqiyi": "爱奇艺",
    "sdzy": "索尼",
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
    "huya": "虎牙",
    "wolong": "卧龙",
    "maotai": "茅台",
    "ikun": "iKun",
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

  /// Probe title hits + latency once, then freeze sorted playable list (fastest first).
  private func preparePlayableStationsIfNeeded() async {
    guard orderedPlayableStations == nil else { return }
    let all = model.collectionStations
    guard all.count > 1 else {
      orderedPlayableStations = all
      return
    }
    async let keysTask = model.providerKeysHavingTitle(detail.name)
    async let latencyTask: Void = model.probeCollectionStationLatencies()
    let keys = await keysTask
    await latencyTask
    var available = keys
    if let current = playbackProviderKey {
      available.insert(current)
    }
    let playable = all.filter { available.contains(stationProviderKey($0)) }
    // Sort by latency once (fastest first); unknown latency last. Never reshuffle later.
    orderedPlayableStations = playable.sorted { a, b in
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

  /// Auto-pick the fastest playable station. Skipped while the user locked a manual pick.
  @discardableResult
  private func autoSelectOptimalSourceIfNeeded(force: Bool = false) async -> Bool {
    if userLockedSource && !force { return false }
    if force { userLockedSource = false }
    // Mid-playback handoff only when forced (episode change / stuck path).
    if !force {
      guard playback == nil, lastPlaybackTime < 1.5 else { return false }
    }
    guard let stations = orderedPlayableStations, let best = stations.first else { return false }
    let bestKey = stationProviderKey(best)
    guard playbackProviderKey != bestKey else { return false }
    await switchCollectionStation(bestKey, silent: true, userInitiated: false)
    return playbackProviderKey == bestKey
  }

  @discardableResult
  private func failoverToNextStation(from failedKey: String) -> Bool {
    userLockedSource = false
    dropUnplayableStation(failedKey)
    guard let next = orderedPlayableStations?.first else { return false }
    let nextKey = stationProviderKey(next)
    guard nextKey != failedKey else { return false }
    Task { await switchCollectionStation(nextKey, silent: true, userInitiated: false) }
    return true
  }

  private func dropUnplayableStation(_ providerKey: String) {
    guard var stations = orderedPlayableStations else { return }
    stations.removeAll { stationProviderKey($0) == providerKey }
    orderedPlayableStations = stations
  }

  private func latencyColor(ms: Int) -> Color {
    if ms < 800 { return Color(red: 0.20, green: 0.70, blue: 0.35) }
    if ms < 1600 { return Color(red: 0.90, green: 0.55, blue: 0.10) }
    return Color(red: 0.90, green: 0.28, blue: 0.25)
  }

  private func sourceMenuLabel(_ title: String, ms: Int? = nil, emphasized: Bool = true) -> some View {
    HStack(spacing: 8) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
      if let ms {
        Text("\(ms)ms")
          .font(.caption2.monospacedDigit().weight(.medium))
          .foregroundStyle(emphasized ? Color.white.opacity(0.92) : latencyColor(ms: ms))
      }
      Image(systemName: "chevron.up.chevron.down")
        .font(.caption2.weight(.semibold))
        .opacity(0.85)
    }
    .foregroundStyle(emphasized ? Color.white : Color.primary)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(
      emphasized ? Color.orange : Color.secondary.opacity(0.12),
      in: Capsule()
    )
  }

  private var sourceStationPickerSheet: some View {
    let stations = orderedPlayableStations ?? []
    return NavigationStack {
      List {
        ForEach(stations) { station in
          let providerKey = stationProviderKey(station)
          let selected = playbackProviderKey == providerKey
            || (playbackProviderKey == nil && stations.first?.id == station.id)
          let ms = model.collectionStationLatencyMS[station.id]
          Button {
            showingSourceStationPicker = false
            guard !selected else { return }
            Task {
              await switchCollectionStation(
                providerKey,
                silent: true,
                userInitiated: true
              )
            }
          } label: {
            HStack(spacing: 12) {
              Text(station.name)
                .font(.body)
                .foregroundStyle(.primary)
              Spacer(minLength: 8)
              if let ms {
                Text("\(ms)ms")
                  .font(.caption.monospacedDigit().weight(.semibold))
                  .foregroundStyle(latencyColor(ms: ms))
                  .padding(.horizontal, 8)
                  .padding(.vertical, 4)
                  .background(latencyColor(ms: ms).opacity(0.12), in: Capsule())
              } else {
                Text("测速中")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.orange : Color.secondary.opacity(0.35))
                .imageScale(.medium)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .listStyle(.plain)
      .navigationTitle("来源")
      .navigationBarTitleDisplayMode(.inline)
    }
    .presentationDetents([.height(min(520, 72 + CGFloat(max(stations.count, 1)) * 52))])
    .presentationDragIndicator(.visible)
  }

  @ViewBuilder
  private var sourceChips: some View {
    if model.collectionStations.count > 1 {
      if let stations = orderedPlayableStations, stations.isEmpty {
        Text("暂无可用来源")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        // Silent probe: show current/best name immediately; no spinner on 来源.
        let stations = orderedPlayableStations ?? model.collectionStations
        let selected =
          stations.first(where: { stationProviderKey($0) == playbackProviderKey })
          ?? stations.first
        let selectedName = selected?.name ?? playbackSourceName
        let selectedMS = selected.flatMap { model.collectionStationLatencyMS[$0.id] }
        Button {
          showingSourceStationPicker = true
        } label: {
          sourceMenuLabel(selectedName, ms: selectedMS)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingSourceStationPicker) {
          sourceStationPickerSheet
        }
      }
    } else if model.onDeviceSites.count > 1 {
      Menu {
        ForEach(model.onDeviceSites, id: \.key) { site in
          let selected = model.selectedSite?.key == site.key
          Button {
            Task { await switchSource(to: site) }
          } label: {
            if selected {
              Label(site.name, systemImage: "checkmark")
            } else {
              Text(site.name)
            }
          }
          .disabled(selected)
        }
      } label: {
        sourceMenuLabel(model.selectedSite?.name ?? "点播源")
      }
    } else {
      sourceMenuLabel(playbackSourceName)
        .allowsHitTesting(false)
    }
  }

  /// Douban score only (product rule); fall back to site score when Douban is empty.
  private var displayScore: String? {
    if let douban = detail.doubanScore, douban > 0 {
      return String(format: "%.1f", douban)
    }
    if let score = detail.score, score > 0 {
      return String(format: "%.1f", score)
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
    if let focusEpisodeName,
      displayedEpisodes.contains(where: { $0.name == focusEpisodeName })
    {
      return focusEpisodeName
    }
    if let playbackEpisode,
      displayedEpisodes.contains(where: { $0.name == playbackEpisode.name })
    {
      return playbackEpisode.name
    }
    if let value = focusedEpisodeValue,
      let match = displayedEpisodes.first(where: { $0.value == value })
    {
      return match.name
    }
    return displayedEpisodes.first?.name
  }

  private func scrollToFocusedEpisode(using proxy: ScrollViewProxy) {
    guard !didScrollToHistory, let focusID = focusedEpisodeScrollID else { return }
    didScrollToHistory = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      withAnimation(.easeInOut(duration: 0.25)) {
        proxy.scrollTo(focusID, anchor: .center)
      }
    }
  }

  private func scrollToHistoryEpisode(using proxy: ScrollViewProxy) {
    scrollToFocusedEpisode(using: proxy)
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
    beginSourceHandoff()
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
      await applyReplacement(replacement)
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
    beginSourceHandoff()
    do {
      guard
        let replacement = try await model.findItem(
          named: detail.name,
          in: site,
          preferredProviderKey: providerKey
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
      await applyReplacement(replacement)
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

  private func beginSourceHandoff() {
    isSwitchingSource = true
    seedFocusFromHistory()
    let episodeName = playbackEpisode?.name ?? focusEpisodeName ?? titleHistoryHint?.name
    if let episodeName { focusEpisodeName = episodeName }
    let position =
      lastPlaybackTime > 1
      ? lastPlaybackTime
      : (historyEntry?.position ?? titleHistoryHint?.position ?? 0)
    sourceSwitchHandoff = (position, episodeName)
  }

  private func clearSourceHandoff() {
    sourceSwitchHandoff = nil
    isSwitchingSource = false
  }

  private func applyReplacement(_ replacement: MediaItem) async {
    // Keep 选集 highlight + handoff; only swap the stream once new detail is ready.
    let keepEpisodeName = sourceSwitchHandoff?.episodeName ?? focusEpisodeName
    showingEpisodeDrawer = false
    currentItem = replacement
    await model.loadDetail(replacement)
    if let keepEpisodeName, let match = matchEpisode(named: keepEpisodeName) {
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

    if let preferredName, let match = matchEpisode(named: preferredName) {
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
      userLockedSource = false
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
