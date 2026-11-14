import AVKit
import FirepickCore
import FirepickPlayback
import SwiftUI

/// 央视频式电视页：上 16:9 播放器 + 下浅色频道区；全屏为独立沉浸态。
struct LivePlaybackShell: View {
  private enum PlayPauseGlyph {
    case play
    case pause
  }

  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase

  @State private var channel: LiveChannel?
  @State private var groupName: String?
  @State private var urlIndex = 0
  @State private var showHUD = true
  @State private var showLines = false
  @State private var zapHint: String?
  @State private var failure: String?
  @State private var avEngine = AVPlayerEngine()
  @State private var mpvEngine = MPVPlayerEngine()
  @State private var engineKind: PlaybackEngineKind = .avPlayer
  @State private var hideTask: Task<Void, Never>?
  @State private var singleTapTask: Task<Void, Never>?
  @State private var glyphHideTask: Task<Void, Never>?
  @State private var bitrateText = "0 KB/s"
  @State private var selectedShelfID = "cctv"
  @State private var isFullscreen = false
  @State private var reachableIDs: Set<String> = []
  @State private var checkedIDs: Set<String> = []
  @State private var playPauseGlyph: PlayPauseGlyph?
  /// Bumps on leave / new load so late `loadCurrent` cannot restart audio after 点播.
  @State private var liveLoadGeneration = 0
  /// Keep the 16:9 stage black (and muted) until a real video plane is confirmed.
  @State private var holdBlackUntilVideo = false

  private let liveShelves: [LiveShelf] = [
    LiveShelf(id: "cctv", title: "央视", keywords: ["央视", "cctv"]),
    LiveShelf(id: "satellite", title: "卫视", keywords: ["卫视"]),
  ]

  private var playbackEngine: any PlaybackEngine {
    engineKind == .mpv ? mpvEngine : avEngine
  }

  private var isPlaying: Bool {
    if engineKind == .avPlayer {
      return avEngine.isActivelyPlaying
    }
    return mpvEngine.state == .playing
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
      // Leaving the app while on 电视: stop unless 后台播放 (avoids 串音 into other apps).
      if phase != .active, model.selectedTab == .live, !model.backgroundPlaybackEnabled {
        stopAllLiveEngines()
      }
    }
    .onDisappear {
      hideTask?.cancel()
      singleTapTask?.cancel()
      glyphHideTask?.cancel()
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

  private func liveStage(channel: LiveChannel) -> some View {
    GeometryReader { geo in
      let portraitVideoH = geo.size.width * 9 / 16
      ZStack(alignment: .top) {
        // Video plane — must sit above any page background (白屏 was systemBackground
        // painted on the full-height VStack covering this hole).
        Color.black
          .frame(
            width: geo.size.width,
            height: isFullscreen ? geo.size.height : portraitVideoH
          )
          .frame(maxHeight: isFullscreen ? .infinity : nil)

        playerStage(channel: channel, fullscreenChrome: isFullscreen)
          .frame(
            width: geo.size.width,
            height: isFullscreen ? geo.size.height : portraitVideoH
          )
          .frame(maxHeight: isFullscreen ? .infinity : nil)

        if isFullscreen {
          fullscreenBackChrome()
        } else {
          VStack(spacing: 0) {
            Color.clear
              .frame(height: portraitVideoH)
              .allowsHitTesting(false)
              .overlay(alignment: .bottomTrailing) {
                fullscreenEntryButton
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

  /// Single top-leading 返回 — no duplicate bottom「收起」control.
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
      .padding(.leading, 4)
      .padding(.top, 4)
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

      if playbackEngine.state == .loading || holdBlackUntilVideo {
        VStack(spacing: 10) {
          ProgressView()
            .controlSize(.large)
            .tint(.white)
          if !holdBlackUntilVideo || failure == nil {
            Text(bitrateText)
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.white)
          }
        }
        .allowsHitTesting(false)
      }

      if let playPauseGlyph {
        playPauseFlash(playPauseGlyph)
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

      if let failure {
        VStack(spacing: 12) {
          Text(failure)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
          Button("换线路重试") {
            Task { await advanceLine(autoplay: true) }
          }
          .buttonStyle(.borderedProminent)
          .tint(.orange)
        }
        .padding()
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
    .onTapGesture(count: 2) {
      singleTapTask?.cancel()
      flashPlayPause()
    }
    .onTapGesture(count: 1) {
      singleTapTask?.cancel()
      singleTapTask = Task {
        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
          showHUD.toggle()
        }
        if showHUD { scheduleHideHUD() }
      }
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
    ZStack {
      VStack {
        HStack {
          if fullscreenChrome {
            // Room for top-leading 返回 outside the HUD.
            Spacer(minLength: 56)
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
          Button {
            model.toggleLiveFavorite(channel)
            scheduleHideHUD()
          } label: {
            Image(systemName: model.isLiveFavorite(channel) ? "star.fill" : "star")
              .foregroundStyle(.white)
              .frame(width: 40, height: 40)
              .background(.black.opacity(0.4), in: Circle())
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, fullscreenChrome ? 12 : 10)

        Spacer()
      }

      if playPauseGlyph == nil {
        Button {
          togglePlayPause(flash: false)
        } label: {
          Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.white)
            .offset(x: isPlaying ? 0 : 2)
            .frame(width: 68, height: 68)
            .background(.black.opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "暂停" : "播放")
      }
    }
  }

  private func playPauseFlash(_ glyph: PlayPauseGlyph) -> some View {
    Image(systemName: glyph == .pause ? "pause.fill" : "play.fill")
      .font(.system(size: 34, weight: .bold))
      .foregroundStyle(.white)
      .offset(x: glyph == .play ? 2 : 0)
      .frame(width: 76, height: 76)
      .background(.black.opacity(0.5), in: Circle())
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

                    VStack(alignment: .leading, spacing: 2) {
                      Text(item.name)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.orange : Color.primary)
                      if let program = model.currentProgram(for: item) {
                        Text(program.title)
                          .font(.caption)
                          .foregroundStyle(.secondary)
                          .lineLimit(1)
                      }
                    }
                    Spacer(minLength: 0)
                    if isCurrent {
                      Image(systemName: "waveform")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                    }
                  }
                  .padding(.horizontal, 16)
                  .padding(.vertical, 12)
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
      let reachable = variants.filter { reachableIDs.contains($0.id) }
      guard let primary = reachable.first else { return nil }
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
        urls: urls,
        headers: headers
      )
    }
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

  private func probeShelfChannels() async {
    let channels = uniqueShelfCandidates()
    reachableIDs = []
    checkedIDs = []
    guard !channels.isEmpty else { return }
    let width = 20
    var cursor = 0
    await withTaskGroup(of: (String, Bool).self) { group in
      while cursor < channels.count && cursor < width {
        let channel = channels[cursor]
        cursor += 1
        group.addTask {
          let ok = await LiveShelfProbe.responds(channel)
          return (channel.id, ok)
        }
      }
      for await result in group {
        if Task.isCancelled {
          group.cancelAll()
          break
        }
        if result.1 {
          reachableIDs.insert(result.0)
        }
        checkedIDs.insert(result.0)
        if cursor < channels.count {
          let channel = channels[cursor]
          cursor += 1
          group.addTask {
            let ok = await LiveShelfProbe.responds(channel)
            return (channel.id, ok)
          }
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
    let urls = channel.urls.compactMap(URL.init(string:))
    guard !urls.isEmpty else {
      failure = "该频道没有可播放地址"
      holdBlackUntilVideo = false
      return
    }
    let index = min(urlIndex, urls.count - 1)
    urlIndex = index
    let request = PlaybackRequest(url: urls[index], headers: channel.headers)

    func stillActive() -> Bool {
      generation == liveLoadGeneration && model.selectedTab == .live
    }

    do {
      try await playbackEngine.load(request)
      // Newer load owns the engines — do NOT stopAll here (that raced and flashed).
      guard stillActive() else { return }
      failure = nil
      // Probe muted: never let audio-only 湖南卫视 blast while we wait for video.
      if autoplay {
        silenceLiveOutput()
        playbackEngine.play()
      }
      if engineKind == .avPlayer, autoplay {
        let hasVideo = await waitForLiveVideo(seconds: 2.8)
        guard stillActive() else { return }
        if hasVideo {
          unmuteLiveOutput()
          holdBlackUntilVideo = false
          failure = nil
          return
        }
        // No video plane — stop sound before trying the next mirror.
        silenceLiveOutput()
        if index + 1 < urls.count {
          failure = "无画面，正在换线路…"
          urlIndex = index + 1
          await loadCurrent(autoplay: autoplay)
          return
        }
        // Last AV line: try MPV once (HEVC). Stay muted until video-params confirm a plane.
        avEngine.stop()
        engineKind = .mpv
        failure = "无画面，正在用兼容解码…"
        try await mpvEngine.load(request)
        guard stillActive() else { return }
        if autoplay {
          silenceLiveOutput()
          mpvEngine.play()
        }
        let mpvHasVideo = await waitForMPVVideo(seconds: 2.5)
        guard stillActive() else { return }
        if mpvHasVideo {
          failure = nil
          unmuteLiveOutput()
          holdBlackUntilVideo = false
        } else {
          // Still radio-like — stop completely, don't leave soundtrack running.
          silenceLiveOutput()
          mpvEngine.stop()
          failure = "无画面，请换线路重试"
          holdBlackUntilVideo = false
        }
      } else {
        unmuteLiveOutput()
        holdBlackUntilVideo = false
      }
    } catch {
      guard stillActive() else { return }
      silenceLiveOutput()
      if index + 1 < urls.count {
        failure = "线路失败，正在换线…"
        urlIndex = index + 1
        await loadCurrent(autoplay: autoplay)
      } else if engineKind == .avPlayer {
        engineKind = .mpv
        avEngine.stop()
        failure = "无画面，正在用兼容解码…"
        do {
          try await mpvEngine.load(request)
          guard stillActive() else { return }
          if autoplay {
            silenceLiveOutput()
            mpvEngine.play()
          }
          let mpvHasVideo = await waitForMPVVideo(seconds: 2.5)
          guard stillActive() else { return }
          if mpvHasVideo {
            failure = nil
            unmuteLiveOutput()
            holdBlackUntilVideo = false
          } else {
            silenceLiveOutput()
            mpvEngine.stop()
            failure = "无画面，请换线路重试"
            holdBlackUntilVideo = false
          }
        } catch {
          failure = error.localizedDescription
          stopAllLiveEngines()
          holdBlackUntilVideo = false
        }
      } else {
        failure = error.localizedDescription
        stopAllLiveEngines()
        holdBlackUntilVideo = false
      }
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
    showHUD = true
    scheduleHideHUD()
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
    showHUD = true
    scheduleHideHUD()
  }

  private func exitFullscreen() {
    isFullscreen = false
    clearFullscreenTabBarState()
    OrientationBridge.enterPortraitThenUnlock()
    showHUD = true
    scheduleHideHUD()
  }

  private func clearFullscreenTabBarState() {
    model.liveFullscreenActive = false
    model.liveShowsTabBarInFullscreen = false
  }

  private func togglePlayPause(flash: Bool) {
    let wasPlaying = isPlaying
    if wasPlaying {
      playbackEngine.pause()
    } else {
      // Live TV: resume at the live edge, not the paused DVR buffer.
      Task { await resumeLiveFromEdge() }
    }
    if flash {
      revealPlayPauseGlyph(wasPlaying ? .pause : .play)
    }
    showHUD = true
    scheduleHideHUD()
  }

  /// Seek to the HLS live edge (seekable range end), then play.
  private func resumeLiveFromEdge() async {
    if engineKind == .avPlayer, let item = avEngine.player.currentItem {
      let ranges = item.seekableTimeRanges
      if let range = ranges.last?.timeRangeValue,
        range.duration.seconds.isFinite,
        range.duration.seconds > 2
      {
        let live = CMTimeRangeGetEnd(range)
        let target = CMTimeSubtract(live, CMTime(seconds: 1.2, preferredTimescale: 600))
        await avEngine.player.seek(
          to: target,
          toleranceBefore: .positiveInfinity,
          toleranceAfter: .positiveInfinity
        )
      } else {
        // No DVR window — reload so we don't stay stuck on a stale buffer.
        await loadCurrent(autoplay: true)
        return
      }
    }
    playbackEngine.play()
  }

  private func flashPlayPause() {
    guard playbackEngine.state != .loading else { return }
    togglePlayPause(flash: true)
  }

  private func revealPlayPauseGlyph(_ glyph: PlayPauseGlyph) {
    var hideCenter = Transaction()
    hideCenter.disablesAnimations = true
    withTransaction(hideCenter) {
      playPauseGlyph = glyph
    }
    glyphHideTask?.cancel()
    glyphHideTask = Task {
      try? await Task.sleep(for: .seconds(1.0))
      guard !Task.isCancelled else { return }
      var clear = Transaction()
      clear.disablesAnimations = true
      withTransaction(clear) {
        playPauseGlyph = nil
      }
    }
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

  static func responds(_ channel: LiveChannel) async -> Bool {
    for raw in channel.urls.prefix(5) {
      guard let url = URL(string: raw),
        url.scheme == "http" || url.scheme == "https"
      else { continue }
      if await responds(url: url, headers: channel.headers) { return true }
    }
    return false
  }

  private static func responds(url: URL, headers: [String: String]) async -> Bool {
    var request = URLRequest(url: url, timeoutInterval: 3.5)
    request.httpMethod = "GET"
    request.setValue("bytes=0-512", forHTTPHeaderField: "Range")
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    if request.value(forHTTPHeaderField: "User-Agent") == nil {
      request.setValue("AppleCoreMedia/1.0.0.20", forHTTPHeaderField: "User-Agent")
    }
    do {
      let (bytes, response) = try await session.bytes(for: request)
      defer { bytes.task.cancel() }
      let http = response as? HTTPURLResponse
      let code = http?.statusCode ?? 0
      guard (200..<400).contains(code) else { return false }
      let type = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
      if type.contains("mpegurl") || type.contains("mp2t") || type.contains("video")
        || type.contains("octet-stream") || type.isEmpty
      {
        return true
      }
      var sample = Data()
      for try await byte in bytes {
        sample.append(byte)
        if sample.count >= 48 { break }
      }
      if sample.first == 0x47 { return true }
      let text = String(data: sample, encoding: .utf8)?.lowercased() ?? ""
      if text.contains("#extm3u") || text.contains("#extinf") { return true }
      if text.contains("<html") || text.contains("<!doctype") || text.contains("{\"code\"") {
        return false
      }
      return !sample.isEmpty && !type.contains("text/html") && !type.contains("json")
    } catch {
      return false
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
