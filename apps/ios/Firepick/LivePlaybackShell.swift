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
        if isFullscreen {
          fullscreenBody(channel: channel)
        } else {
          portraitBody(channel: channel)
        }
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
        if channel == nil {
          Task { await bootstrap() }
        } else {
          // Re-entering the tab: restore last remembered channel if it drifted.
          restoreRememberedChannelIfNeeded()
          playbackEngine.play()
          scheduleHideHUD()
        }
      } else {
        playbackEngine.pause()
        if isFullscreen {
          exitFullscreen()
        }
        if let channel {
          model.rememberLiveChannel(channel, groupName: groupName, urlIndex: urlIndex)
        }
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active, model.selectedTab == .live {
        playbackEngine.pause()
      }
    }
    .onChange(of: channel?.id) { _, _ in
      syncShelfToCurrentChannel()
    }
    .onDisappear {
      hideTask?.cancel()
      singleTapTask?.cancel()
      glyphHideTask?.cancel()
      playbackEngine.stop()
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

  private func portraitBody(channel: LiveChannel) -> some View {
    VStack(spacing: 0) {
      ZStack(alignment: .bottomTrailing) {
        playerStage(channel: channel, fullscreenChrome: false)
        // Always visible — HUD auto-hide must not remove the fullscreen entry.
        Button {
          enterFullscreen()
        } label: {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 12)
        .padding(.bottom, 12)
        .accessibilityLabel("全屏")
      }
      .aspectRatio(16 / 9, contentMode: .fit)
      .frame(maxWidth: .infinity)
      .background(Color.black)

      channelPanel(current: channel)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
    }
    .background(Color(.systemBackground).ignoresSafeArea())
  }

  private func fullscreenBody(channel: LiveChannel) -> some View {
    ZStack {
      Color.black.ignoresSafeArea()
      playerStage(channel: channel, fullscreenChrome: true)
        .ignoresSafeArea()
      // Always-available exit so fullscreen is never a trap when HUD is hidden.
      VStack {
        HStack {
          Button {
            exitFullscreen()
          } label: {
            Image(systemName: "chevron.left")
              .font(.body.weight(.semibold))
              .foregroundStyle(.white)
              .frame(width: 40, height: 40)
              .background(.black.opacity(0.55), in: Circle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("退出全屏")
          Spacer()
        }
        .padding(.leading, 16)
        .padding(.top, 12)
        Spacer()
      }
    }
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
  }

  private func playerStage(channel: LiveChannel, fullscreenChrome: Bool) -> some View {
    ZStack {
      playerLayer

      if showHUD {
        playerChrome(channel: channel, fullscreenChrome: fullscreenChrome)
          .transition(.opacity)
      }

      if playbackEngine.state == .loading {
        VStack(spacing: 10) {
          ProgressView()
            .controlSize(.large)
            .tint(.white)
          Text(bitrateText)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.white)
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
          if fullscreenChrome {
            handleFullscreenTabBarSwipe(value.translation.height)
          } else if value.translation.height < 0 {
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
      LiveSystemPlayerView(player: avEngine.player)
    }
  }

  private func playerChrome(channel: LiveChannel, fullscreenChrome: Bool) -> some View {
    ZStack {
      VStack {
        HStack {
          if !fullscreenChrome {
            Spacer()
          } else {
            // Persistent 「返回」 lives outside HUD; keep trailing actions here.
            Spacer(minLength: 120)
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
        .padding(.top, fullscreenChrome ? 52 : 10)

        Spacer()

        if fullscreenChrome {
          HStack(alignment: .bottom) {
            Spacer()
            Button {
              exitFullscreen()
            } label: {
              Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("退出全屏")
          }
          .padding(.trailing, 12)
          .padding(.bottom, 12)
        }
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
              selectedShelfID = shelf.id
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
            ForEach(channels) { item in
              Button {
                select(channel: item, groupHint: nil)
              } label: {
                HStack(spacing: 12) {
                  CachedRemoteImage(url: item.logo.flatMap(URL.init(string:))) {
                    Image(systemName: "tv")
                      .foregroundStyle(.secondary)
                  }
                  .frame(width: 36, height: 36)
                  .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                  VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                      .font(.body.weight(item.id == current.id ? .semibold : .regular))
                      .foregroundStyle(item.id == current.id ? Color.orange : Color.primary)
                    if let program = model.currentProgram(for: item) {
                      Text(program.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                  }
                  Spacer(minLength: 0)
                  if item.id == current.id {
                    Image(systemName: "waveform")
                      .font(.caption.weight(.bold))
                      .foregroundStyle(.orange)
                  }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                  item.id == current.id ? Color.orange.opacity(0.08) : Color.clear
                )
              }
              .buttonStyle(.plain)

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
    var chosen: [String: LiveChannel] = [:]
    var order: [String] = []
    for channel in shelfCandidates(shelf) {
      let key = channel.name
      if chosen[key] == nil {
        order.append(key)
      }
      if chosen[key] == nil || reachableIDs.contains(channel.id) {
        chosen[key] = channel
      }
    }
    return order.compactMap { name in
      guard let channel = chosen[name], reachableIDs.contains(channel.id) else { return nil }
      return channel
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

  private func shelfID(containing channel: LiveChannel) -> String? {
    for shelf in liveShelves {
      if shelfCandidates(shelf).contains(where: { $0.id == channel.id || $0.name == channel.name }) {
        return shelf.id
      }
    }
    return nil
  }

  private func syncShelfToCurrentChannel() {
    guard let channel, let shelfID = shelfID(containing: channel) else { return }
    if selectedShelfID != shelfID {
      selectedShelfID = shelfID
    }
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
      await model.refreshLiveSources()
    }
    guard let initial = model.resolveInitialLiveChannel() else { return }
    groupName = initial.group.name
    channel = initial.channel
    urlIndex = min(model.lastLiveURLIndex, max(0, initial.channel.urls.count - 1))
    if let preferred = model.playbackPreference.engine {
      engineKind = preferred
    }
    if let shelfID = shelfID(containing: initial.channel) {
      selectedShelfID = shelfID
    } else {
      selectedShelfID = liveShelves.first?.id ?? selectedShelfID
    }
    await model.loadEPG(for: initial.group)
    await loadCurrent(autoplay: model.selectedTab == .live)
    scheduleHideHUD()
  }

  private func restoreRememberedChannelIfNeeded() {
    guard let remembered = model.resolveInitialLiveChannel() else { return }
    if channel?.id == remembered.channel.id || channel?.name == remembered.channel.name {
      syncShelfToCurrentChannel()
      return
    }
    select(channel: remembered.channel, groupHint: remembered.group.name)
  }

  private func select(channel newChannel: LiveChannel, groupHint: String?) {
    channel = newChannel
    if let groupHint,
      model.liveGroups.contains(where: { $0.name == groupHint })
    {
      groupName = groupHint
    } else if let group = model.liveGroups.first(where: {
      $0.channels.contains(where: { $0.id == newChannel.id })
    }) {
      groupName = group.name
    }
    if let shelfID = shelfID(containing: newChannel) {
      selectedShelfID = shelfID
    }
    urlIndex = 0
    failure = nil
    Task { await loadCurrent(autoplay: true) }
  }

  private func loadCurrent(autoplay: Bool) async {
    guard let channel else { return }
    model.rememberLiveChannel(channel, groupName: groupName, urlIndex: urlIndex)
    let urls = channel.urls.compactMap(URL.init(string:))
    guard !urls.isEmpty else {
      failure = "该频道没有可播放地址"
      return
    }
    let index = min(urlIndex, urls.count - 1)
    urlIndex = index
    let request = PlaybackRequest(url: urls[index], headers: channel.headers)
    do {
      try await playbackEngine.load(request)
      failure = nil
      if autoplay { playbackEngine.play() }
    } catch {
      failure = error.localizedDescription
      if index + 1 < urls.count {
        urlIndex = index + 1
        await loadCurrent(autoplay: autoplay)
      }
    }
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
      return model.liveGroups.first(where: { $0.name == groupName })?.channels
        ?? model.liveGroups.first?.channels
        ?? []
    }()
    guard let channel, let index = channels.firstIndex(where: { $0.id == channel.id }),
      !channels.isEmpty
    else { return }
    let next = (index + delta + channels.count) % channels.count
    let target = channels[next]
    select(channel: target, groupHint: groupName)
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

  private func handleFullscreenTabBarSwipe(_ translationHeight: CGFloat) {
    if translationHeight < -40 {
      withAnimation(.easeInOut(duration: 0.28)) {
        model.liveShowsTabBarInFullscreen = true
      }
    } else if translationHeight > 40 {
      withAnimation(.easeInOut(duration: 0.28)) {
        model.liveShowsTabBarInFullscreen = false
      }
    }
  }

  private func togglePlayPause(flash: Bool) {
    let wasPlaying = isPlaying
    if wasPlaying {
      playbackEngine.pause()
    } else {
      playbackEngine.play()
    }
    if flash {
      revealPlayPauseGlyph(wasPlaying ? .pause : .play)
    }
    showHUD = true
    scheduleHideHUD()
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
    config.timeoutIntervalForRequest = 1.0
    config.timeoutIntervalForResource = 1.2
    config.httpMaximumConnectionsPerHost = 8
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config)
  }()

  static func responds(_ channel: LiveChannel) async -> Bool {
    for raw in channel.urls.prefix(3) {
      guard let url = URL(string: raw),
        url.scheme == "http" || url.scheme == "https"
      else { continue }
      if await responds(url: url, headers: channel.headers) { return true }
    }
    return false
  }

  private static func responds(url: URL, headers: [String: String]) async -> Bool {
    var request = URLRequest(url: url, timeoutInterval: 1.0)
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

private struct LiveSystemPlayerView: UIViewControllerRepresentable {
  let player: AVPlayer

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.showsPlaybackControls = false
    controller.videoGravity = .resizeAspect
    controller.view.backgroundColor = .black
    controller.allowsPictureInPicturePlayback = true
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    if controller.player !== player {
      controller.player = player
    }
  }
}
