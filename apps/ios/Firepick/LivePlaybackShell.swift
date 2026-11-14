import AVKit
import FirepickCore
import FirepickPlayback
import SwiftUI

/// 央视频式电视页：上 16:9 播放器 + 下浅色频道区；全屏为独立沉浸态。
struct LivePlaybackShell: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase

  @State private var channel: LiveChannel?
  @State private var groupName: String?
  @State private var urlIndex = 0
  /// Chrome only after a single tap — never auto-shown on enter/zap.
  @State private var showHUD = false
  @State private var showLines = false
  @State private var zapHint: String?
  @State private var failure: String?
  @State private var avEngine = AVPlayerEngine()
  @State private var mpvEngine = MPVPlayerEngine()
  @State private var engineKind: PlaybackEngineKind = .avPlayer
  @State private var hideTask: Task<Void, Never>?
  @State private var bitrateText = "0 KB/s"
  @State private var selectedShelfID = "cctv"
  @State private var isFullscreen = false
  @State private var reachableIDs: Set<String> = []
  @State private var checkedIDs: Set<String> = []
  /// Best probe RTT (ms) by channel name — shown on each shelf card.
  @State private var channelLatencyMS: [String: Int] = [:]
  /// Bumps on leave / new load so late `loadCurrent` cannot restart audio after 点播.
  @State private var liveLoadGeneration = 0
  /// Keep the 16:9 stage black (and muted) until a real video plane is confirmed.
  @State private var holdBlackUntilVideo = false
  /// Bumps on orientation change so fullscreen can switch to local landscape layout.
  @State private var orientationTick = 0

  private let liveShelves: [LiveShelf] = [
    LiveShelf(id: "cctv", title: "央视", keywords: ["央视", "cctv"]),
    LiveShelf(id: "satellite", title: "卫视", keywords: ["卫视"]),
  ]

  private var playbackEngine: any PlaybackEngine {
    engineKind == .mpv ? mpvEngine : avEngine
  }

  private var liveProbeToken: String {
    model.liveGroups.map { "\($0.id):\($0.channels.count)" }.joined(separator: "|")
  }

  private var activeShelfChannels: [LiveChannel] {
    shelfChannels(id: selectedShelfID)
  }

  private var shelfPending: Bool {
    shelfIsPending(id: selectedShelfID)
  }

  var body: some View {
    Group {
      if model.liveGroups.isEmpty {
        emptyState
      } else if let channel {
        // Keep one player surface across portrait ↔ fullscreen — branching
        // remounts AVPlayer and yields black video + radio-like audio.
        liveStage(channel: channel)
      } else {
        ZStack {
          Color(.systemBackground).ignoresSafeArea()
          ProgressView()
        }
      }
    }
    .confirmationDialog("线路", isPresented: $showLines, titleVisibility: .visible) {
      if let channel {
        ForEach(Array(channel.urls.enumerated()), id: \.offset) { index, url in
          Button(index == urlIndex ? "线路 \(index + 1) ✓" : "线路 \(index + 1)") {
            urlIndex = index
            Task { await loadCurrent(autoplay: true) }
          }
          .disabled(URL(string: url) == nil)
        }
      }
    }
    .task { await bootstrap() }
    .task(id: liveProbeToken) { await probeShelfChannels() }
    .task(id: channel?.id) {
      while !Task.isCancelled {
        refreshBitrate()
        try? await Task.sleep(for: .seconds(1))
      }
    }
    .onChange(of: model.selectedTab) { _, tab in
      if tab == .live {
        Task { await enterLiveTab() }
      } else {
        leaveLiveTab()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      guard model.selectedTab == .live else { return }
      switch phase {
      case .inactive:
        // Control Center / 通知中心 / 亮度条 — must NOT tear down. Treating this as
        // leave-app caused 真机下拉黑屏且无法恢复.
        break
      case .background:
        // Truly backgrounded: stop unless 后台播放 (avoids 串音 into other apps).
        if !model.backgroundPlaybackEnabled {
          stopAllLiveEngines()
        }
      case .active:
        // Returning from background (or after a mistaken stop): reload if idle/black.
        resumeLiveIfNeededAfterForeground()
      @unknown default:
        break
      }
    }
    .onDisappear {
      hideTask?.cancel()
      persistLiveMemory()
      stopAllLiveEngines()
      if isFullscreen {
        isFullscreen = false
        OrientationBridge.enterPortraitThenUnlock()
      }
      clearFullscreenTabBarState()
      model.releasePlaybackCache()
    }
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("没有直播源", systemImage: "dot.radiowaves.left.and.right")
    } description: {
      Text("在设置中添加包含直播的配置后，这里会直接播放。")
    } actions: {
      Button("去设置") { model.selectedTab = .settings }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
      Button("刷新") {
        Task { await model.refreshLiveSources() }
      }
      .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
  }

  /// Simulator / delayed rotate: window stays portrait — paint landscape locally.
  private var fullscreenNeedsLocalLandscape: Bool {
    _ = orientationTick
    return isFullscreen && OrientationBridge.isPortraitInterface
  }

  private func liveStage(channel: LiveChannel) -> some View {
    GeometryReader { geo in
      let portraitVideoH = geo.size.width * 9 / 16
      let localLandscape = fullscreenNeedsLocalLandscape
      ZStack(alignment: .top) {
        // Video plane — must sit above any page background (白屏 was systemBackground
        // painted on the full-height VStack covering this hole).
        Color.black
          .frame(
            width: geo.size.width,
            height: isFullscreen ? geo.size.height : portraitVideoH
          )
          .frame(maxHeight: isFullscreen ? .infinity : nil)

        if isFullscreen {
          fullscreenPlayerStage(
            channel: channel,
            container: geo.size,
            localLandscape: localLandscape
          )
          if showHUD {
            // Keep chrome in window coords (not rotated with the local-landscape stage).
            fullscreenBackChrome()
              .transition(.opacity)
          }
        } else {
          playerStage(channel: channel, fullscreenChrome: false)
            .frame(width: geo.size.width, height: portraitVideoH)

          VStack(spacing: 0) {
            Color.clear
              .frame(height: portraitVideoH)
              .allowsHitTesting(false)
              .overlay(alignment: .bottomTrailing) {
                if showHUD {
                  fullscreenEntryButton
                    .transition(.opacity)
                }
              }
            channelPanel(current: channel)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
              .background(Color(.systemBackground))
          }
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
      .background {
        Group {
          if isFullscreen {
            Color.black
          } else {
            Color(.systemBackground)
          }
        }
        .ignoresSafeArea()
      }
    }
    .ignoresSafeArea(isFullscreen ? .all : [])
    .statusBarHidden(isFullscreen)
    .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
    .onReceive(
      NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
    ) { _ in
      orientationTick &+= 1
    }
    // Touch orientationTick so SwiftUI re-evaluates local-landscape when the scene rotates.
    .onChange(of: orientationTick) { _, _ in }
  }

  @ViewBuilder
  private func fullscreenPlayerStage(
    channel: LiveChannel,
    container: CGSize,
    localLandscape: Bool
  ) -> some View {
    let stage = playerStage(channel: channel, fullscreenChrome: true)
    if localLandscape {
      // Portrait window + landscape intent (Simulator): rotate a landscape frame into place.
      stage
        .frame(width: container.height, height: container.width)
        .rotationEffect(.degrees(90))
        .frame(width: container.width, height: container.height)
    } else {
      stage
        .frame(width: container.width, height: container.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var fullscreenEntryButton: some View {
    Button {
      enterFullscreen()
    } label: {
      Image(systemName: "arrow.up.left.and.arrow.down.right")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.65), radius: 1.5, y: 1)
        .padding(12)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.trailing, 8)
    .padding(.bottom, 6)
    .accessibilityLabel("全屏")
  }

  /// Single top-leading 返回 — shown with HUD on tap only.
  private func fullscreenBackChrome() -> some View {
    VStack {
      HStack {
        Button {
          exitFullscreen()
        } label: {
          Image(systemName: "chevron.left")
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.65), radius: 1.5, y: 1)
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回")
        Spacer()
      }
      .padding(.leading, 16)
      .padding(.trailing, 20)
      .padding(.top, 12)
      Spacer()
    }
  }

  private func playerStage(channel: LiveChannel, fullscreenChrome: Bool) -> some View {
    ZStack {
      Color.black
      playerLayer
      // Cover layer swaps / empty AVPlayerLayer so 切台 never flashes system white.
      if holdBlackUntilVideo || playbackEngine.state == .loading {
        Color.black
      }

      if showHUD {
        playerChrome(channel: channel, fullscreenChrome: fullscreenChrome)
          .transition(.opacity)
      }

      // Recovering / probing mirrors: only spinner — never error copy or「换线路」chrome.
      if playbackEngine.state == .loading || holdBlackUntilVideo || failure != nil {
        VStack(spacing: 10) {
          ProgressView()
            .controlSize(.large)
            .tint(.white)
          if failure == nil {
            Text(bitrateText)
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.white)
          }
        }
        .allowsHitTesting(false)
      }

      if let zapHint {
        Text(zapHint)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(.black.opacity(0.55), in: Capsule())
          .allowsHitTesting(false)
      }
    }
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 36)
        .onEnded { value in
          guard abs(value.translation.height) > abs(value.translation.width) else { return }
          // No fullscreen tab-bar swipe / 收起 — always zap by vertical swipe.
          if value.translation.height < 0 {
            zap(delta: 1)
          } else {
            zap(delta: -1)
          }
        }
    )
    .onTapGesture {
      withAnimation(.easeInOut(duration: 0.18)) {
        showHUD.toggle()
      }
      if showHUD { scheduleHideHUD() }
    }
  }

  @ViewBuilder
  private var playerLayer: some View {
    if engineKind == .mpv {
      MPVVideoView(engine: mpvEngine)
    } else {
      // AVPlayerLayer — AVPlayerViewController shows Apple's radio/Q artwork
      // when no video plane is ready yet.
      LivePlayerLayerView(player: avEngine.player)
    }
  }

  private func playerChrome(channel: LiveChannel, fullscreenChrome: Bool) -> some View {
    VStack {
      HStack {
        if fullscreenChrome {
          // Room for top-leading 返回.
          Spacer(minLength: 72)
        } else {
          Spacer()
        }
        if channel.urls.count > 1 {
          Button("线路") { showLines = true }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.4), in: Capsule())
        }
      }
      .padding(.leading, fullscreenChrome ? 16 : 12)
      .padding(.trailing, fullscreenChrome ? 20 : 12)
      .padding(.top, fullscreenChrome ? 12 : 10)

      Spacer()
    }
  }

  private func channelPanel(current: LiveChannel) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(current.name)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.primary)
        if let program = model.currentProgram(for: current) {
          Text(program.title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 14)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(liveShelves) { shelf in
            let selected = selectedShelfID == shelf.id
            Button {
              // Only switch the list shelf — do not force-sync from the playing channel
              // (that was bouncing 卫视 → 央视 while CCTV was still on air).
              selectedShelfID = shelf.id
              model.rememberLiveShelf(shelf.id)
            } label: {
              Text(shelf.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                  selected ? Color.orange : Color.secondary.opacity(0.12),
                  in: Capsule()
                )
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 16)
      }

      let channels = activeShelfChannels
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            if channels.isEmpty {
              VStack(spacing: 10) {
                if shelfPending {
                  ProgressView().tint(.orange)
                }
                Text(shelfPending ? "正在检测可用频道" : "没有检测到可播放的频道")
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
                  .multilineTextAlignment(.center)
              }
              .frame(maxWidth: .infinity)
              .padding(.vertical, 36)
            } else {
              ForEach(channels, id: \.name) { item in
                let isCurrent = item.name == current.name
                Button {
                  // Stay on the shelf the user is browsing — never re-infer 央视.
                  select(channel: item, groupHint: nil, keepShelf: true)
                } label: {
                  HStack(spacing: 12) {
                    CachedRemoteImage(
                      url: item.logo.flatMap(URL.init(string:)),
                      maxPixelSize: 96
                    ) {
                      Image(systemName: "tv")
                        .foregroundStyle(.secondary)
                    }
                    .frame(width: 36, height: 36)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)

                    VStack(alignment: .leading, spacing: 2) {
                      HStack(spacing: 6) {
                        Text(item.name)
                          .font(.body.weight(isCurrent ? .semibold : .regular))
                          .foregroundStyle(isCurrent ? Color.orange : Color.primary)
                          .lineLimit(1)
                        if isCurrent {
                          Image(systemName: "waveform")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                        }
                      }
                      if let program = model.currentProgram(for: item) {
                        Text(program.title)
                          .font(.caption)
                          .foregroundStyle(.secondary)
                          .lineLimit(1)
                      }
                    }
                    Spacer(minLength: 0)
                    if let ms = channelLatencyMS[item.name] {
                      Text("\(ms)ms")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(liveLatencyColor(ms))
                    } else if shelfPending {
                      Text("…")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    }
                  }
                  .padding(.horizontal, 16)
                  .padding(.vertical, 12)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
                  .background(
                    isCurrent ? Color.orange.opacity(0.08) : Color.clear
                  )
                }
                .buttonStyle(.plain)
                .id(item.name)

                Divider().padding(.leading, 64)
              }

              if shelfPending {
                HStack(spacing: 6) {
                  ProgressView().tint(.orange).controlSize(.small)
                  Text("继续检测…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
              }
            }
          }
        }
        .onAppear {
          scrollToPlayingChannel(proxy, name: current.name, animated: false)
        }
        .onChange(of: current.name) { _, name in
          scrollToPlayingChannel(proxy, name: name)
        }
        .onChange(of: selectedShelfID) { _, _ in
          scrollToPlayingChannel(proxy, name: current.name)
        }
        .onChange(of: channelListScrollToken(channels)) { _, _ in
          scrollToPlayingChannel(proxy, name: current.name, animated: false)
        }
      }
    }
  }

  private func channelListScrollToken(_ channels: [LiveChannel]) -> String {
    channels.map(\.name).joined(separator: "|")
  }

  private func scrollToPlayingChannel(
    _ proxy: ScrollViewProxy,
    name: String,
    animated: Bool = true
  ) {
    guard activeShelfChannels.contains(where: { $0.name == name }) else { return }
    let action = { proxy.scrollTo(name, anchor: .center) }
    if animated {
      withAnimation(.easeInOut(duration: 0.25), action)
    } else {
      action()
    }
  }

  private func refreshBitrate() {
    guard engineKind == .avPlayer,
      let event = avEngine.player.currentItem?.accessLog()?.events.last,
      event.observedBitrate > 0
    else {
      bitrateText = "0 KB/s"
      return
    }
    bitrateText = String(format: "%.0f KB/s", event.observedBitrate / 8 / 1024)
  }

  private func shelfCandidates(_ shelf: LiveShelf) -> [LiveChannel] {
    var seen = Set<String>()
    var channels: [LiveChannel] = []
    for group in model.liveGroups {
      let groupBlob = group.name.lowercased()
      for channel in group.channels {
        let blob = groupBlob + " " + channel.name.lowercased()
        guard shelf.keywords.contains(where: { blob.contains($0.lowercased()) }) else { continue }
        guard seen.insert(channel.id).inserted else { continue }
        channels.append(channel)
      }
    }
    return channels
  }

  private func shelfChannels(id: String) -> [LiveChannel] {
    guard let shelf = liveShelves.first(where: { $0.id == id }) else { return [] }
    var byName: [String: [LiveChannel]] = [:]
    var order: [String] = []
    for channel in shelfCandidates(shelf) {
      let key = channel.name
      if byName[key] == nil { order.append(key) }
      byName[key, default: []].append(channel)
    }
    return order.compactMap { name -> LiveChannel? in
      let variants = byName[name] ?? []
      // Don't wait on probe — show the shelf immediately from cache; probe only fills ms.
      let reachable = variants.filter { reachableIDs.contains($0.id) }
      guard let primary = reachable.first ?? variants.first else { return nil }
      // Merge mirrors from all sources so 湖南卫视 can fail over past a bad 4K/HEVC line.
      var urls: [String] = []
      var headers = primary.headers
      for channel in reachable + variants {
        for url in channel.urls where !urls.contains(url) {
          urls.append(url)
        }
        if headers.isEmpty, !channel.headers.isEmpty {
          headers = channel.headers
        }
      }
      return LiveChannel(
        name: primary.name,
        number: primary.number,
        logo: primary.logo,
        epg: primary.epg,
        tvgId: primary.tvgId,
        urls: Self.preferredLiveURLOrder(urls),
        headers: headers
      )
    }
  }

  /// Prefer non-4K / non-HEVC mirrors first — AVPlayer often gets audio-only on 湖南卫视 4K.
  private static func preferredLiveURLOrder(_ urls: [String]) -> [String] {
    urls.sorted { a, b in
      liveURLDifficulty(a) < liveURLDifficulty(b)
    }
  }

  private static func liveURLDifficulty(_ raw: String) -> Int {
    let text = raw.lowercased()
    var score = 0
    if text.contains("4k") || text.contains("2160") || text.contains("uhd") { score += 20 }
    if text.contains("hevc") || text.contains("h265") || text.contains("h.265") { score += 12 }
    if text.contains("hdr") { score += 6 }
    if text.contains("1080") { score += 2 }
    return score
  }

  private func shelfIsPending(id: String) -> Bool {
    guard let shelf = liveShelves.first(where: { $0.id == id }) else { return false }
    return shelfCandidates(shelf).contains { !checkedIDs.contains($0.id) }
  }

  private func uniqueShelfCandidates() -> [LiveChannel] {
    var seen = Set<String>()
    return liveShelves.flatMap { shelfCandidates($0) }.filter { seen.insert($0.id).inserted }
  }

  /// Prefer channel-name rules so 湖南卫视 never lands under 央视 via group quirks.
  private func shelfID(containing channel: LiveChannel) -> String? {
    let name = channel.name.lowercased()
    if name.contains("卫视") { return "satellite" }
    if name.contains("cctv") || name.contains("央视") { return "cctv" }
    for shelf in liveShelves {
      if shelfCandidates(shelf).contains(where: { $0.name == channel.name }) {
        return shelf.id
      }
    }
    return nil
  }

  private func persistLiveMemory() {
    if let channel {
      model.rememberLiveChannel(channel, groupName: groupName, urlIndex: urlIndex)
    }
    model.rememberLiveShelf(selectedShelfID)
  }

  /// Hard stop both engines — pause alone still leaked 电视 audio into 点播 (串音).
  private func stopAllLiveEngines() {
    liveLoadGeneration += 1
    avEngine.player.isMuted = false
    avEngine.player.volume = 1
    avEngine.stop()
    mpvEngine.stop()
    failure = nil
    holdBlackUntilVideo = false
  }

  /// After Control Center / background return: restart if the surface was torn down.
  private func resumeLiveIfNeededAfterForeground() {
    guard channel != nil else { return }
    let state = playbackEngine.state
    let failed: Bool = {
      if case .failed = state { return true }
      return false
    }()
    let playingOrLoading = state == .playing || state == .loading || state == .ready
    let hasAVItem = engineKind != .avPlayer || avEngine.player.currentItem != nil
    // Still on-air with a live item — Control Center path; leave it alone.
    if playingOrLoading, hasAVItem, !holdBlackUntilVideo, !failed { return }
    Task { await loadCurrent(autoplay: true) }
  }

  private func leaveLiveTab() {
    persistLiveMemory()
    stopAllLiveEngines()
    if isFullscreen {
      exitFullscreen()
    }
  }

  /// Re-enter 电视: restore channel, sync shelf to the playing station, then reload.
  private func enterLiveTab() async {
    if channel == nil {
      await bootstrap()
      return
    }
    restoreRememberedChannelIfNeeded()
    syncShelfToPlayingChannel()
    await loadCurrent(autoplay: true)
    scheduleHideHUD()
  }

  /// Menu follows the on-air channel (浙江卫视 → 卫视), not a stale browsed shelf.
  private func syncShelfToPlayingChannel() {
    guard let channel, let shelfID = shelfID(containing: channel) else { return }
    selectedShelfID = shelfID
    model.rememberLiveShelf(shelfID)
  }

  private func liveLatencyColor(_ ms: Int) -> Color {
    if ms < 400 { return .green }
    if ms < 900 { return .orange }
    return .red
  }

  private func probeShelfChannels() async {
    let channels = uniqueShelfCandidates()
    reachableIDs = []
    checkedIDs = []
    channelLatencyMS = [:]
    guard !channels.isEmpty else { return }
    let width = 20
    var cursor = 0
    await withTaskGroup(of: (id: String, name: String, ok: Bool, ms: Int?).self) { group in
      func enqueue(_ channel: LiveChannel) {
        group.addTask {
          let probed = await LiveShelfProbe.probe(channel)
          return (channel.id, channel.name, probed.ok, probed.ms)
        }
      }
      while cursor < channels.count && cursor < width {
        enqueue(channels[cursor])
        cursor += 1
      }
      for await result in group {
        if Task.isCancelled {
          group.cancelAll()
          break
        }
        if result.ok {
          reachableIDs.insert(result.id)
          if let ms = result.ms {
            var next = channelLatencyMS
            if let prev = next[result.name] {
              next[result.name] = min(prev, ms)
            } else {
              next[result.name] = ms
            }
            channelLatencyMS = next
          }
        }
        checkedIDs.insert(result.id)
        if cursor < channels.count {
          enqueue(channels[cursor])
          cursor += 1
        }
      }
    }
  }

  private func bootstrap() async {
    if model.liveGroups.isEmpty {
      await model.ensureLiveSourcesLoaded()
    }
    guard let initial = model.resolveInitialLiveChannel() else { return }
    groupName = initial.group.name
    channel = initial.channel
    urlIndex = min(model.lastLiveURLIndex, max(0, initial.channel.urls.count - 1))
    if let preferred = model.playbackPreference.engine {
      engineKind = preferred
    }
    // Playing channel wins over last browsed shelf (avoids 浙江卫视 + 央视 tab).
    if let shelfID = shelfID(containing: initial.channel) {
      selectedShelfID = shelfID
    } else if let rememberedShelf = model.lastLiveShelfID,
      liveShelves.contains(where: { $0.id == rememberedShelf })
    {
      selectedShelfID = rememberedShelf
    } else {
      selectedShelfID = liveShelves.first?.id ?? selectedShelfID
    }
    model.rememberLiveShelf(selectedShelfID)
    await model.loadEPG(for: initial.group)
    // TabView may mount this while still on 点播 — don't start audio until 电视 is selected.
    guard model.selectedTab == .live else { return }
    await loadCurrent(autoplay: true)
    scheduleHideHUD()
  }

  private func restoreRememberedChannelIfNeeded() {
    guard let remembered = model.resolveInitialLiveChannel() else { return }
    if channel?.id == remembered.channel.id || channel?.name == remembered.channel.name {
      return
    }
    channel = remembered.channel
    groupName = remembered.group.name
    urlIndex = min(model.lastLiveURLIndex, max(0, remembered.channel.urls.count - 1))
  }

  private func select(
    channel newChannel: LiveChannel,
    groupHint: String?,
    keepShelf: Bool = false
  ) {
    // Kill previous audio immediately so 切台 never leaves the old station playing.
    silenceLiveOutput()
    holdBlackUntilVideo = true
    channel = newChannel
    if let groupHint,
      model.liveGroups.contains(where: { $0.name == groupHint })
    {
      groupName = groupHint
    } else if let group = model.liveGroups.first(where: {
      $0.channels.contains(where: { $0.name == newChannel.name || $0.id == newChannel.id })
    }) {
      groupName = group.name
    }
    if keepShelf {
      model.rememberLiveShelf(selectedShelfID)
    } else if let shelfID = shelfID(containing: newChannel) {
      selectedShelfID = shelfID
      model.rememberLiveShelf(shelfID)
    }
    urlIndex = 0
    failure = nil
    engineKind = model.playbackPreference.engine ?? .avPlayer
    model.rememberLiveChannel(newChannel, groupName: groupName, urlIndex: urlIndex)
    Task { await loadCurrent(autoplay: true) }
  }

  /// Mute + pause both engines without bumping load generation.
  private func silenceLiveOutput() {
    avEngine.player.isMuted = true
    avEngine.player.volume = 0
    avEngine.pause()
    mpvEngine.pause()
  }

  private func unmuteLiveOutput() {
    avEngine.player.isMuted = false
    avEngine.player.volume = 1
  }

  private func loadCurrent(autoplay: Bool) async {
    guard let channel else { return }
    liveLoadGeneration += 1
    let generation = liveLoadGeneration
    holdBlackUntilVideo = true
    silenceLiveOutput()
    model.rememberLiveChannel(channel, groupName: groupName, urlIndex: urlIndex)
    let urls = Self.preferredLiveURLOrder(channel.urls).compactMap(URL.init(string:))
    guard !urls.isEmpty else {
      failure = "retry"
      holdBlackUntilVideo = true
      return
    }
    let startIndex = min(max(0, urlIndex), urls.count - 1)

    func stillActive() -> Bool {
      generation == liveLoadGeneration && model.selectedTab == .live
    }

    // Pass 1: AVPlayer across mirrors (skip heavy 4K/HEVC first via URL order).
    engineKind = .avPlayer
    for offset in 0..<urls.count {
      let index = (startIndex + offset) % urls.count
      urlIndex = index
      let request = PlaybackRequest(url: urls[index], headers: channel.headers)
      do {
        try await avEngine.load(request)
        guard stillActive() else { return }
        failure = nil
        if autoplay {
          silenceLiveOutput()
          avEngine.play()
        }
        let hasVideo = await waitForLiveVideo(seconds: 3.6)
        guard stillActive() else { return }
        if hasVideo {
          unmuteLiveOutput()
          holdBlackUntilVideo = false
          failure = nil
          return
        }
        silenceLiveOutput()
        avEngine.stop()
      } catch {
        guard stillActive() else { return }
        silenceLiveOutput()
        avEngine.stop()
      }
    }

    // Pass 2: MPV for HEVC / odd codecs (湖南卫视 4K often lands here).
    engineKind = .mpv
    for offset in 0..<urls.count {
      let index = (startIndex + offset) % urls.count
      urlIndex = index
      let request = PlaybackRequest(url: urls[index], headers: channel.headers)
      do {
        try await mpvEngine.load(request)
        guard stillActive() else { return }
        failure = nil
        if autoplay {
          silenceLiveOutput()
          mpvEngine.play()
        }
        let hasVideo = await waitForMPVVideo(seconds: 3.2)
        guard stillActive() else { return }
        if hasVideo {
          unmuteLiveOutput()
          holdBlackUntilVideo = false
          failure = nil
          return
        }
        silenceLiveOutput()
        mpvEngine.stop()
      } catch {
        guard stillActive() else { return }
        silenceLiveOutput()
        mpvEngine.stop()
      }
    }

    guard stillActive() else { return }
    // Keep spinner and quietly retry from the next mirror after a short pause.
    failure = "retry"
    holdBlackUntilVideo = true
    engineKind = .avPlayer
    urlIndex = (startIndex + 1) % urls.count
    Task {
      try? await Task.sleep(for: .seconds(2.5))
      guard generation == liveLoadGeneration, model.selectedTab == .live else { return }
      await loadCurrent(autoplay: true)
    }
  }

  /// True when AVPlayer reports a real video plane (not audio-only / black).
  private func waitForLiveVideo(seconds: Double) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if Task.isCancelled { return false }
      if let item = avEngine.player.currentItem {
        let size = item.presentationSize
        if size.width > 1, size.height > 1 {
          return true
        }
      }
      try? await Task.sleep(for: .milliseconds(200))
    }
    if let item = avEngine.player.currentItem {
      let size = item.presentationSize
      return size.width > 1 && size.height > 1
    }
    return false
  }

  private func waitForMPVVideo(seconds: Double) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if Task.isCancelled { return false }
      if mpvEngine.hasVideoPlane { return true }
      try? await Task.sleep(for: .milliseconds(200))
    }
    return mpvEngine.hasVideoPlane
  }

  private func advanceLine(autoplay: Bool) async {
    guard let channel else { return }
    urlIndex = (urlIndex + 1) % max(channel.urls.count, 1)
    await loadCurrent(autoplay: autoplay)
  }

  private func zap(delta: Int) {
    let channels = {
      let shelf = activeShelfChannels
      if !shelf.isEmpty { return shelf }
      // Never fall back to liveGroups.first (央视) — that yanked shelf back to 央视.
      if let groupName,
        let group = model.liveGroups.first(where: { $0.name == groupName })
      {
        return group.channels
      }
      return activeShelfChannels
    }()
    guard let channel, let index = channels.firstIndex(where: { $0.name == channel.name }),
      !channels.isEmpty
    else { return }
    let next = (index + delta + channels.count) % channels.count
    let target = channels[next]
    select(channel: target, groupHint: groupName, keepShelf: true)
    zapHint = target.name
    Task {
      try? await Task.sleep(for: .seconds(1.2))
      if zapHint == target.name { zapHint = nil }
    }
  }

  private func toggleFullscreen() {
    if isFullscreen {
      exitFullscreen()
    } else {
      enterFullscreen()
    }
  }

  private func enterFullscreen() {
    isFullscreen = true
    model.liveFullscreenActive = true
    model.liveShowsTabBarInFullscreen = false
    OrientationBridge.enterLandscape()
    showHUD = false
    // Re-check after the scene settles — Simulator often stays portrait.
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(500))
      orientationTick &+= 1
    }
  }

  private func exitFullscreen() {
    isFullscreen = false
    clearFullscreenTabBarState()
    OrientationBridge.enterPortraitThenUnlock()
    showHUD = false
  }

  private func clearFullscreenTabBarState() {
    model.liveFullscreenActive = false
    model.liveShowsTabBarInFullscreen = false
  }

  private func scheduleHideHUD() {
    hideTask?.cancel()
    hideTask = Task {
      try? await Task.sleep(for: .seconds(3.5))
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.18)) {
        showHUD = false
      }
    }
  }
}

private struct LiveShelf: Identifiable {
  let id: String
  let title: String
  let keywords: [String]
}

private enum LiveShelfProbe {
  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    // 1s was too aggressive — many 卫视 mirrors need 2–3s on cellular.
    config.timeoutIntervalForRequest = 3.5
    config.timeoutIntervalForResource = 4.0
    config.httpMaximumConnectionsPerHost = 8
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config)
  }()

  static func probe(_ channel: LiveChannel) async -> (ok: Bool, ms: Int?) {
    for raw in channel.urls.prefix(5) {
      guard let url = URL(string: raw),
        url.scheme == "http" || url.scheme == "https"
      else { continue }
      if let ms = await latencyMS(url: url, headers: channel.headers) {
        return (true, ms)
      }
    }
    return (false, nil)
  }

  private static func latencyMS(url: URL, headers: [String: String]) async -> Int? {
    var request = URLRequest(url: url, timeoutInterval: 3.5)
    request.httpMethod = "GET"
    request.setValue("bytes=0-512", forHTTPHeaderField: "Range")
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    if request.value(forHTTPHeaderField: "User-Agent") == nil {
      request.setValue("AppleCoreMedia/1.0.0.20", forHTTPHeaderField: "User-Agent")
    }
    let started = Date()
    do {
      let (bytes, response) = try await session.bytes(for: request)
      defer { bytes.task.cancel() }
      let http = response as? HTTPURLResponse
      let code = http?.statusCode ?? 0
      guard (200..<400).contains(code) else { return nil }
      let type = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
      let okType = type.contains("mpegurl") || type.contains("mp2t") || type.contains("video")
        || type.contains("octet-stream") || type.isEmpty
      if okType {
        return Int(Date().timeIntervalSince(started) * 1000)
      }
      var sample = Data()
      for try await byte in bytes {
        sample.append(byte)
        if sample.count >= 48 { break }
      }
      if sample.first == 0x47 {
        return Int(Date().timeIntervalSince(started) * 1000)
      }
      let text = String(data: sample, encoding: .utf8)?.lowercased() ?? ""
      if text.contains("#extm3u") || text.contains("#extinf") {
        return Int(Date().timeIntervalSince(started) * 1000)
      }
      if text.contains("<html") || text.contains("<!doctype") || text.contains("{\"code\"") {
        return nil
      }
      guard !sample.isEmpty, !type.contains("text/html"), !type.contains("json") else {
        return nil
      }
      return Int(Date().timeIntervalSince(started) * 1000)
    } catch {
      return nil
    }
  }
}

private struct LivePlayerLayerView: UIViewRepresentable {
  let player: AVPlayer

  func makeUIView(context: Context) -> LivePlayerUIView {
    let view = LivePlayerUIView()
    view.backgroundColor = .black
    view.isOpaque = true
    view.playerLayer.player = player
    view.playerLayer.videoGravity = .resizeAspect
    view.playerLayer.backgroundColor = UIColor.black.cgColor
    return view
  }

  func updateUIView(_ view: LivePlayerUIView, context: Context) {
    if view.playerLayer.player !== player {
      view.playerLayer.player = player
    }
    view.playerLayer.videoGravity = .resizeAspect
    view.backgroundColor = .black
  }
}

private final class LivePlayerUIView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }

  var playerLayer: AVPlayerLayer {
    layer as! AVPlayerLayer
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    playerLayer.frame = bounds
  }
}
