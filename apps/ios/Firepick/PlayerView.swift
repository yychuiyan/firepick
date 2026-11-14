import AVKit
import FirepickCore
import FirepickPlayback
import MediaPlayer
import SwiftUI
import UIKit

private enum PlayPauseGlyph: Equatable {
  case play
  case pause
}

enum PlayerChrome: Equatable {
  case immersive
  case inline
}

struct PlayerView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase

  let request: PlaybackRequest
  let item: MediaItem
  let episode: Episode?
  var alternateURLs: [URL] = []
  var flag: String? = nil
  var lineEpisodes: [Episode] = []
  var playbackLines: [PlaybackLine] = []
  /// Inline detail player. Immersive is the existing full-screen cover.
  var chrome: PlayerChrome = .immersive
  var onExpand: (() -> Void)? = nil
  var onCollapse: (() -> Void)? = nil
  var onPlayEpisode: ((Episode, String) -> Void)? = nil
  /// Live clock for Detail 来源 handoff (continue from same timestamp).
  var onPlaybackTimeChange: ((Double) -> Void)? = nil
  /// All candidate URLs failed — return true if parent will switch 来源.
  var onUnplayable: (() -> Bool)? = nil

  @State private var avEngine = AVPlayerEngine()
  @State private var mpvEngine = MPVPlayerEngine()
  @State private var engineKind: PlaybackEngineKind
  @State private var failure: String?
  @State private var playbackRate: Float = 1
  @State private var activeRequest: PlaybackRequest?
  @State private var activeEpisode: Episode?
  @State private var activeFlag: String?
  @State private var activeLineEpisodes: [Episode] = []
  @State private var danmakuComments: [DanmakuComment] = []
  @State private var danmakuEnabled = true
  @State private var showingEpisodes = false
  @State private var showingLines = false
  @State private var showingDanmakuSettings = false
  @State private var showControls = true
  @State private var hideTask: Task<Void, Never>?
  @State private var failingOver = false
  @State private var triedURLs: [URL] = []
  @State private var retriedWithAV = false
  @State private var playPauseGlyph: PlayPauseGlyph?
  @State private var singleTapTask: Task<Void, Never>?
  @State private var glyphHideTask: Task<Void, Never>?
  @State private var toast: String?
  @State private var gestureHint: String?
  @State private var brightnessBar: Double?
  @State private var volumeBar: Float?
  @State private var scrubPreview: Double?
  @State private var isScrubbing = false
  @State private var selectedSubtitleIndex: Int?
  @State private var overlayCues: [SubtitleCue] = []
  @State private var isLoadingSubtitles = false
  @State private var incognitoThisSession = false
  @State private var didAutoSkipIntro = false
  @State private var didHandleEnded = false
  @State private var showingNextEpisode = false
  @State private var isResolvingNext = false
  @State private var volumeProxy = VolumeProxy()
  @State private var dragAxis: DragAxis?
  @State private var dragStartBrightness: CGFloat = 0
  @State private var dragStartVolume: Float = 0
  @State private var dragStartTime: Double = 0
  @State private var remoteCommandsConfigured = false
  @State private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
  @State private var showingRatePicker = false
  @State private var orientationLocked = false
  /// Keep progress chrome stable while soft-reloading another 来源.
  @State private var stickyDuration: Double = 0
  @State private var stickyTime: Double = 0
  @State private var lastReportedTime: Double = 0
  @State private var softReloadGeneration = 0

  private enum DragAxis {
    case horizontal
    case vertical
  }

  init(
    request: PlaybackRequest,
    item: MediaItem,
    episode: Episode?,
    alternateURLs: [URL] = [],
    flag: String? = nil,
    lineEpisodes: [Episode] = [],
    playbackLines: [PlaybackLine] = [],
    chrome: PlayerChrome = .immersive,
    onExpand: (() -> Void)? = nil,
    onCollapse: (() -> Void)? = nil,
    onPlayEpisode: ((Episode, String) -> Void)? = nil,
    onPlaybackTimeChange: ((Double) -> Void)? = nil,
    onUnplayable: (() -> Bool)? = nil
  ) {
    self.request = request
    self.item = item
    self.episode = episode
    self.alternateURLs = alternateURLs
    self.flag = flag
    self.lineEpisodes = lineEpisodes
    self.playbackLines = playbackLines
    self.chrome = chrome
    self.onExpand = onExpand
    self.onCollapse = onCollapse
    self.onPlayEpisode = onPlayEpisode
    self.onPlaybackTimeChange = onPlaybackTimeChange
    self.onUnplayable = onUnplayable
    let kind =
      (try? PlayerSelector().select(
        request,
        mpvAvailable: MPVPlaybackSupport.isAvailable
      ).engine) ?? .avPlayer
    _engineKind = State(initialValue: kind)
    _activeEpisode = State(initialValue: episode)
    _activeFlag = State(initialValue: flag)
    _activeLineEpisodes = State(
      initialValue: lineEpisodes.isEmpty
        ? (playbackLines.first(where: { $0.name == flag })?.episodes ?? [])
        : lineEpisodes
    )
  }

  private var previousEpisode: Episode? {
    let episodes = currentLineEpisodes
    guard let current = activeEpisode ?? episode,
      let index = episodes.firstIndex(where: { $0.value == current.value }),
      index > 0
    else { return nil }
    return episodes[index - 1]
  }

  private var nextEpisode: Episode? {
    let episodes = currentLineEpisodes
    guard let current = activeEpisode ?? episode,
      let index = episodes.firstIndex(where: { $0.value == current.value }),
      index + 1 < episodes.count
    else { return nil }
    return episodes[index + 1]
  }

  private var playbackEngine: any PlaybackEngine {
    engineKind == .mpv ? mpvEngine : avEngine
  }

  private var sourceKey: String? {
    item.sourceKey ?? model.selectedSite?.key
  }

  private var skipMark: AppModel.SkipMark? {
    model.skipMark(sourceKey: sourceKey, vodId: item.vodId, flag: activeFlag ?? flag)
  }

  private var currentLineEpisodes: [Episode] {
    if !activeLineEpisodes.isEmpty { return activeLineEpisodes }
    return lineEpisodes
  }

  private var subtitleFontSize: CGFloat {
    switch model.subtitleFontPreference {
    case .small: 15
    case .medium: 18
    case .large: 22
    }
  }

  private var subtitleColor: Color {
    switch model.subtitleColorPreference {
    case .white: .white
    case .yellow: .yellow
    }
  }

  /// Read the concrete engine so SwiftUI observes time ticks.
  /// `any PlaybackEngine` does not publish `@Observable` changes.
  private var observedTime: Double {
    engineKind == .mpv ? mpvEngine.currentTime : avEngine.currentTime
  }

  private var observedDuration: Double {
    engineKind == .mpv ? mpvEngine.duration : avEngine.duration
  }

  private var displayDuration: Double {
    let live = observedDuration
    if live > 0 {
      return live
    }
    return stickyDuration
  }

  private var displayTime: Double {
    // During soft-reload keep the last clock so the scrubber doesn't collapse to 0.
    if stickyTime > 0 {
      if failingOver || isResolvingNext { return stickyTime }
      switch observedState {
      case .loading, .idle:
        if failure == nil { return stickyTime }
      default:
        break
      }
    }
    return observedTime
  }

  /// `any PlaybackEngine` does not publish `@Observable` changes to SwiftUI.
  private var observedState: PlaybackState {
    engineKind == .mpv ? mpvEngine.state : avEngine.state
  }

  private var isPlaying: Bool {
    if engineKind == .mpv {
      return mpvEngine.state == .playing
    }
    // Prefer the real AVPlayer clock so icons match what the user hears/sees.
    return avEngine.isActivelyPlaying
  }

  private var currentTime: Double {
    let raw = scrubPreview ?? displayTime
    guard raw.isFinite, raw >= 0 else { return 0 }
    if duration > 0 { return min(raw, duration) }
    return raw
  }

  private var duration: Double {
    PlaybackTimeline.duration(displayDuration)
  }

  var body: some View {
    playerSurface
    .background {
      if chrome == .immersive {
        Color.black.ignoresSafeArea()
      }
    }
    .statusBarHidden(chrome != .inline)
    .persistentSystemOverlays(chrome == .inline ? .automatic : .hidden)
    .sheet(isPresented: $showingEpisodes) {
      episodePickerSheet
        .presentationDetents([.medium, .large])
    }
    .sheet(isPresented: $showingLines) {
      linePickerSheet
        .presentationDetents([.medium])
    }
    .confirmationDialog("倍速", isPresented: $showingRatePicker, titleVisibility: .visible) {
      ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
        Button(rate == 1 ? "1×" : "\(rate.formatted())×") {
          playbackRate = Float(rate)
          playbackEngine.setPlaybackRate(Float(rate))
          scheduleHideControls()
        }
      }
    }
    .sheet(isPresented: $showingDanmakuSettings) {
      NavigationStack {
        DanmakuSettingsView(
          sessionEnabled: $danmakuEnabled,
          hasComments: !danmakuComments.isEmpty
        )
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("完成") { showingDanmakuSettings = false }
          }
        }
      }
    }
    .background(VolumeProxyHost(proxy: volumeProxy).frame(width: 0, height: 0))
    .task {
      applyPlaybackPreferences()
      configureAudioSession()
      configureRemoteCommandsIfNeeded()
      UIApplication.shared.isIdleTimerDisabled = true
    }
    .task(id: request.id) {
      // Soft-reload in place so 来源/选集 switches keep the progress chrome.
      if activeRequest == nil {
        await loadAvailableSource()
      } else {
        await softReload(request)
      }
      updateNowPlaying()
      scheduleHideControls()
    }
    .task(id: request.danmaku.first?.id) {
      await loadDanmaku()
    }
    .onChange(of: avEngine.currentTime) { _, time in
      notePlaybackClock(time: time, durationValue: avEngine.duration, active: engineKind == .avPlayer)
    }
    .onChange(of: mpvEngine.currentTime) { _, time in
      notePlaybackClock(time: time, durationValue: mpvEngine.duration, active: engineKind == .mpv)
    }
    .onChange(of: selectedSubtitleIndex) { _, index in
      applySubtitleSelection(index)
    }
    .onChange(of: avEngine.state) { _, state in
      handlePlaybackEnded(state)
      if case .failed(let message) = state {
        Task { await recover(from: message) }
      }
      if state == .playing { scheduleHideControls() }
    }
    .onChange(of: mpvEngine.state) { _, state in
      handlePlaybackEnded(state)
      if case .failed(let message) = state {
        Task { await recover(from: message) }
      }
      if state == .playing { scheduleHideControls() }
    }
    .alert("播放下一集？", isPresented: $showingNextEpisode) {
      Button("下一集") {
        Task { await playNextEpisode(auto: false) }
      }
      Button("关闭", role: .cancel) {
        showingNextEpisode = false
      }
    } message: {
      if let next = nextEpisode {
        Text(next.name)
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active, !model.backgroundPlaybackEnabled {
        playbackEngine.pause()
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
    ) { note in
      handleInterruption(note)
    }
    .onDisappear {
      hideTask?.cancel()
      UIApplication.shared.isIdleTimerDisabled = false
      if !incognitoThisSession, let sourceKey {
        let historyEpisode =
          activeEpisode
          ?? episode
          ?? Episode(
            name: item.name,
            value: (activeRequest ?? request).url.absoluteString
          )
        Task {
          await model.saveHistory(
            sourceKey: sourceKey,
            item: item,
            episode: historyEpisode,
            position: observedTime,
            duration: observedDuration
          )
        }
      }
      clearNowPlaying()
      playbackEngine.stop()
      removeRemoteCommands()
      if orientationLocked {
        orientationLocked = false
        OrientationBridge.unlock()
      }
      model.releasePlaybackCache()
    }
  }

  /// Inline playback stays 16:9. A root `GeometryReader` otherwise takes the
  /// leftover screen height and crops the picture to fill it.
  private var playerSurface: some View {
    Group {
      if chrome == .inline {
        Color.black
          .aspectRatio(16.0 / 9.0, contentMode: .fit)
          .overlay { playerStage }
          .clipped()
      } else {
        playerStage
      }
    }
  }

  private var playerStage: some View {
    GeometryReader { geo in
      ZStack {
        Color.black
        videoLayer
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .allowsHitTesting(false)
        DanmakuOverlay(
          comments: danmakuComments,
          currentTime: observedTime,
          isPlaying: isPlaying,
          isEnabled: danmakuEnabled,
          opacity: model.danmakuOpacity,
          fontScale: model.danmakuFontScale,
          speed: model.danmakuSpeed
        )
        if !overlayCues.isEmpty {
          SubtitleOverlay(
            cues: overlayCues,
            currentTime: observedTime,
            fontSize: subtitleFontSize,
            color: subtitleColor,
            outlined: model.subtitleOutlineEnabled
          )
        }
        if showControls {
          controlsOverlay
            .transition(.opacity)
        }
        if let gestureHint {
          Text(gestureHint)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.55), in: Capsule())
        }
        if let brightnessBar {
          sideMeter(value: brightnessBar, icon: "sun.max.fill")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 28)
        }
        if let volumeBar {
          sideMeter(value: Double(volumeBar), icon: "speaker.wave.2.fill")
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 28)
        }
        if let toast {
          Text(toast)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 56)
        }
        if showingNextEpisode, let next = nextEpisode {
          nextEpisodePrompt(next)
        }
        if let displayFailure {
          failureOverlay(displayFailure)
        } else if isAwaitingPlayback {
          ProgressView()
            .tint(.white)
            .scaleEffect(1.2)
        }
        if let playPauseGlyph, !isAwaitingPlayback {
          playPauseFlash(playPauseGlyph)
            .allowsHitTesting(false)
        }
      }
      .contentShape(Rectangle())
      .simultaneousGesture(playerDrag(in: geo.size))
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
            showControls.toggle()
          }
          if showControls { scheduleHideControls() }
        }
      }
    }
  }

  private var episodePickerSheet: some View {
    NavigationStack {
      List(currentLineEpisodes) { ep in
        Button {
          showingEpisodes = false
          Task { await playEpisode(ep, flag: activeFlag ?? flag ?? "") }
        } label: {
          HStack {
            Text(ep.name)
            Spacer()
            if activeEpisode?.value == ep.value {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.orange)
            }
          }
        }
      }
      .navigationTitle("选集")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { showingEpisodes = false }
        }
      }
    }
  }

  private var linePickerSheet: some View {
    NavigationStack {
      List(playbackLines) { line in
        Button {
          showingLines = false
          Task { await switchPlaybackLine(line) }
        } label: {
          HStack {
            Text(line.name)
            Spacer()
            if (activeFlag ?? flag) == line.name {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.orange)
            }
          }
        }
      }
      .navigationTitle("线路")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { showingLines = false }
        }
      }
    }
  }

  private func nextEpisodePrompt(_ next: Episode) -> some View {
    VStack(spacing: 12) {
      Text("本集已结束")
        .font(.headline)
        .foregroundStyle(.white)
      Text(next.name)
        .foregroundStyle(.white.opacity(0.85))
      HStack(spacing: 12) {
        Button("关闭") {
          showingNextEpisode = false
          playbackEngine.stop()
          dismiss()
        }
        .buttonStyle(.bordered)
        Button {
          Task { await playNextEpisode(auto: false) }
        } label: {
          if isResolvingNext {
            ProgressView().tint(.white)
          } else {
            Text("下一集")
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(isResolvingNext)
      }
    }
    .padding(20)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  @ViewBuilder
  private var videoLayer: some View {
    if engineKind == .mpv {
      MPVVideoView(engine: mpvEngine)
    } else {
      SystemPlayerView(
        player: avEngine.player,
        showsControls: false,
        fillsFrame: false
      )
    }
  }

  private var controlsOverlay: some View {
    ZStack {
      VStack(spacing: 0) {
        topControls
        Spacer()
        if chrome != .inline {
          skipButtons
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        progressBar
          .padding(.horizontal, chrome == .inline ? 8 : 16)
          .padding(.bottom, chrome == .inline ? 4 : 10)
          .background(alignment: .bottom) {
            if chrome == .inline {
              LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
              )
              .frame(height: 54)
              .allowsHitTesting(false)
            }
          }
        if chrome != .inline {
          bottomControls
        }
      }
      centerPlayButton
    }
  }

  /// Loading / failover / not-yet-ready — never show play/pause as if content is ready.
  private var isAwaitingPlayback: Bool {
    if failingOver || isResolvingNext { return true }
    if failure != nil { return false }
    switch observedState {
    case .loading, .idle:
      return true
    case .ready, .playing, .paused:
      // Duration still unknown — keep spinner so progress chrome doesn't look empty.
      return duration <= 0
    default:
      return false
    }
  }

  @ViewBuilder
  private var centerPlayButton: some View {
    // Flash glyph already covers the center — never stack a second play/pause.
    if playPauseGlyph != nil, !isAwaitingPlayback {
      Color.clear.frame(width: 1, height: 1)
    } else if chrome == .inline {
      HStack(spacing: 36) {
        Button {
          seek(by: -10)
        } label: {
          Image(systemName: "gobackward.10")
            .font(.title2)
        }
        .accessibilityLabel("快退")
        .disabled(isAwaitingPlayback)
        Button {
          togglePlayPause()
        } label: {
          if isAwaitingPlayback {
            ProgressView()
              .tint(.white)
              .frame(width: 36, height: 36)
          } else {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 34, weight: .regular))
          }
        }
        .disabled(isAwaitingPlayback)
        Button {
          seek(by: 10)
        } label: {
          Image(systemName: "goforward.10")
            .font(.title2)
        }
        .accessibilityLabel("快进")
        .disabled(isAwaitingPlayback)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.white)
    } else {
      Button {
        togglePlayPause()
      } label: {
        ZStack {
          Circle()
            .fill(.black.opacity(0.45))
            .frame(width: 64, height: 64)
          if isAwaitingPlayback {
            ProgressView()
              .tint(.white)
          } else {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
              .font(.title)
              .foregroundStyle(.white)
              .offset(x: isPlaying ? 0 : 2)
          }
        }
      }
      .buttonStyle(.plain)
      .disabled(isAwaitingPlayback)
    }
  }

  private var inlineTitle: String {
    if isAwaitingPlayback { return headlineTitle }
    if let failure, !failure.isEmpty { return failure }
    if case .failed(let message) = observedState, !message.isEmpty {
      return message
    }
    return headlineTitle
  }

  /// TV / series: "剧名 第01集". Movies stay as the title alone.
  private var headlineTitle: String {
    let base = item.name
    guard showsEpisodeInTitle,
      let episodeName = (activeEpisode ?? episode)?.name.trimmingCharacters(in: .whitespacesAndNewlines),
      !episodeName.isEmpty,
      episodeName != base
    else { return base }
    return "\(base) \(episodeName)"
  }

  private var showsEpisodeInTitle: Bool {
    let type = item.typeName ?? ""
    if type.contains("电影") { return false }
    if currentLineEpisodes.count > 1 { return true }
    if let episodeName = (activeEpisode ?? episode)?.name,
      !episodeName.isEmpty,
      episodeName != item.name
    {
      return true
    }
    return false
  }

  private var topControls: some View {
    Group {
      if chrome == .inline {
        ZStack {
          PlayerTitleLabel(
            text: inlineTitle,
            font: .subheadline.weight(.semibold),
            maxWidth: 200
          )
          HStack(spacing: 0) {
            Button {
              playbackEngine.stop()
              dismiss()
            } label: {
              Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
            }
            .accessibilityLabel("返回")
            Spacer(minLength: 0)
            Button {
              guard let sourceKey else { return }
              Task { await model.toggleFavorite(sourceKey: sourceKey, item: item) }
            } label: {
              Image(
                systemName: model.isFavorite(sourceKey: sourceKey ?? "", item: item)
                  ? "star.fill" : "star"
              )
              .font(.body.weight(.semibold))
              .frame(width: 36, height: 36)
            }
            .accessibilityLabel("收藏")
            menuButton
          }
        }
      } else {
        HStack(spacing: 10) {
          Button {
            if let onCollapse {
              onCollapse()
            } else {
              playbackEngine.stop()
              dismiss()
            }
          } label: {
            Image(systemName: "xmark")
              .font(.body.weight(.semibold))
              .frame(width: 36, height: 36)
              .background(.black.opacity(0.35), in: Circle())
          }
          PlayerTitleLabel(text: headlineTitle, font: .headline, maxWidth: 260)
          Spacer(minLength: 0)
          menuButton
        }
      }
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 8)
    .padding(.top, 6)
  }

  private var bottomControls: some View {
    HStack(spacing: 16) {
      Text(
        "\(format(currentTime)) / \(duration > 0 ? format(duration) : "--:--")"
      )
      .font(.caption.monospacedDigit())
      Spacer(minLength: 8)
      if chrome != .inline {
        if !currentLineEpisodes.isEmpty {
          Button("选集") {
            showingEpisodes = true
          }
          .font(.subheadline.weight(.semibold))
        }
        if playbackLines.count > 1 {
          Button("线路") {
            showingLines = true
          }
          .font(.subheadline.weight(.semibold))
        }
        Button {
          showingRatePicker = true
        } label: {
          Text("\(Double(playbackRate).formatted())×")
            .font(.caption.weight(.semibold))
        }
      }
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 16)
    .padding(.bottom, chrome == .inline ? 10 : 18)
    .padding(.top, 8)
  }

  private var menuButton: some View {
    Menu {
      if chrome == .inline, onExpand != nil {
        Button {
          onExpand?()
        } label: {
          Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right")
        }
      }
      Button("弹幕设置") {
        showingDanmakuSettings = true
      }

      if !(activeRequest ?? request).subtitles.isEmpty {
        Menu("字幕") {
          Button("关闭字幕") {
            selectedSubtitleIndex = nil
            showToast("已关闭字幕")
          }
          ForEach(
            Array((activeRequest ?? request).subtitles.enumerated()),
            id: \.offset
          ) { index, subtitle in
            Button {
              selectedSubtitleIndex = index
              showToast(subtitle.name)
            } label: {
              if selectedSubtitleIndex == index {
                Label(subtitle.name, systemImage: "checkmark")
              } else {
                Text(subtitle.name)
              }
            }
          }
        }
      }

      Menu("倍速") {
        ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
          Button {
            playbackRate = Float(rate)
            playbackEngine.setPlaybackRate(Float(rate))
            scheduleHideControls()
          } label: {
            if abs(Double(playbackRate) - rate) < 0.01 {
              Label("\(rate.formatted())×", systemImage: "checkmark")
            } else {
              Text("\(rate.formatted())×")
            }
          }
        }
      }

      Button {
        let time = playbackEngine.currentTime
        model.setSkipMark(
          sourceKey: sourceKey,
          vodId: item.vodId,
          flag: activeFlag ?? flag,
          introEnd: time
        )
        didAutoSkipIntro = false
        showToast("已设片头 \(format(time))，下次从此后起播")
      } label: {
        if let intro = skipMark?.introEnd {
          Label("片头 \(format(intro))", systemImage: "forward.end")
        } else {
          Label("片头", systemImage: "forward.end")
        }
      }

      Button {
        let time = playbackEngine.currentTime
        model.setSkipMark(
          sourceKey: sourceKey,
          vodId: item.vodId,
          flag: activeFlag ?? flag,
          outroStart: time
        )
        showToast("已设片尾 \(format(time))，到达后自动下一集")
      } label: {
        if let outro = skipMark?.outroStart {
          Label("片尾 \(format(outro))", systemImage: "backward.end")
        } else {
          Label("片尾", systemImage: "backward.end")
        }
      }

      if skipMark != nil {
        Button("清除本片片头片尾", role: .destructive) {
          model.clearSkipMark(
            sourceKey: sourceKey,
            vodId: item.vodId,
            flag: activeFlag ?? flag
          )
          didAutoSkipIntro = false
          showToast("已清除本片标记")
        }
      }
    } label: {
      Image(systemName: chrome == .inline ? "gearshape" : "ellipsis.circle")
        .font(chrome == .inline ? .body.weight(.semibold) : .title3)
        .frame(width: 36, height: 36)
        .background(chrome == .inline ? Color.clear : Color.black.opacity(0.35), in: Circle())
    }
  }

  @ViewBuilder
  private var skipButtons: some View {
    HStack {
      if model.adSkipPreference != .off,
        let intro = skipMark?.introEnd,
        playbackEngine.currentTime + 0.5 < intro
      {
        Button("跳过片头") {
          Task { await playbackEngine.seek(to: intro) }
          scheduleHideControls()
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
      }
      Spacer()
      if model.adSkipPreference != .off,
        let outro = skipMark?.outroStart,
        duration > 0,
        playbackEngine.currentTime >= outro
      {
        if nextEpisode != nil {
          Button {
            Task { await playNextEpisode(auto: false) }
          } label: {
            if isResolvingNext {
              ProgressView().tint(.white)
            } else {
              Text("下一集")
            }
          }
          .buttonStyle(.borderedProminent)
          .tint(.orange)
          .disabled(isResolvingNext)
        } else {
          Button("退出") {
            playbackEngine.stop()
            dismiss()
          }
          .buttonStyle(.borderedProminent)
          .tint(.orange)
        }
      }
    }
  }

  private var showsNextEpisodeControl: Bool {
    guard nextEpisode != nil else { return false }
    let type = item.typeName ?? ""
    return !type.contains("电影")
  }

  private var progressBar: some View {
    HStack(spacing: 8) {
      if chrome == .inline {
        if showsNextEpisodeControl {
          Button {
            Task { await playNextEpisode(auto: false) }
          } label: {
            Image(systemName: "forward.end.fill")
              .font(.body.weight(.semibold))
              .frame(width: 28, height: 28)
          }
          .disabled(isResolvingNext || isAwaitingPlayback)
          .buttonStyle(.plain)
          .foregroundStyle(.white)
          .accessibilityLabel("下一集")
        }
        Text(format(currentTime))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.white)
          .frame(width: 44, alignment: .leading)
      }
      CompactSeekBar(
        value: Binding(
          get: {
            let upper = duration > 0 ? duration : 0.1
            return min(max(0, currentTime), upper)
          },
          set: {
            scrubPreview = PlaybackTimeline.position(
              $0,
              duration: duration
            )
          }
        ),
        range: PlaybackTimeline.progressRange(duration: duration),
        tint: chrome == .inline ? .white : .orange,
        enabled: duration > 0 && !isAwaitingPlayback,
        onEditingChanged: { editing in
          isScrubbing = editing
          if !editing, let scrubPreview {
            Task {
              await playbackEngine.seek(to: scrubPreview)
              self.scrubPreview = nil
            }
          }
          scheduleHideControls()
        }
      )
      .frame(height: 28)
      if chrome == .inline {
        Text(duration > 0 ? format(duration) : "--:--")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.white)
          .frame(width: 44, alignment: .trailing)
      }
    }
  }

  private func sideMeter(value: Double, icon: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: icon)
        .foregroundStyle(.white)
      Capsule()
        .fill(.white.opacity(0.25))
        .frame(width: 4, height: 110)
        .overlay(alignment: .bottom) {
          Capsule()
            .fill(.white)
            .frame(width: 4, height: 110 * min(1, max(0, value)))
        }
    }
    .padding(10)
    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }

  private func failureOverlay(_ message: String) -> some View {
    VStack(spacing: 14) {
      Text(message)
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
      HStack(spacing: 12) {
        Button("重试") {
          Task { await loadAvailableSource() }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(.orange)
        if !alternateURLs.isEmpty {
          Button("换线路") {
            Task { await retryNextAlternate() }
          }
          .buttonStyle(.bordered)
        }
      }
    }
    .padding()
  }

  private func playerDrag(in size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 12)
      .onChanged { value in
        if dragAxis == nil {
          if abs(value.translation.width) > abs(value.translation.height) {
            dragAxis = .horizontal
            dragStartTime = playbackEngine.currentTime
          } else {
            dragAxis = .vertical
            dragStartBrightness = UIScreen.main.brightness
            dragStartVolume = volumeProxy.volume
          }
        }
        guard let dragAxis else { return }
        switch dragAxis {
        case .horizontal:
          guard duration > 0 else { return }
          let delta = Double(value.translation.width / size.width) * min(120, duration * 0.25)
          let target = min(duration, max(0, dragStartTime + delta))
          scrubPreview = target
          gestureHint = "\(delta >= 0 ? "+" : "")\(Int(delta))s → \(format(target))"
          brightnessBar = nil
          volumeBar = nil
        case .vertical:
          let delta = -value.translation.height / size.height
          if value.startLocation.x < size.width * 0.5 {
            let next = min(1, max(0, dragStartBrightness + delta))
            UIScreen.main.brightness = next
            brightnessBar = next
            volumeBar = nil
            gestureHint = nil
          } else {
            let next = min(1, max(0, dragStartVolume + Float(delta)))
            volumeProxy.setVolume(next)
            volumeBar = next
            brightnessBar = nil
            gestureHint = nil
          }
          scrubPreview = nil
        }
        showControls = true
      }
      .onEnded { _ in
        if dragAxis == .horizontal, let scrubPreview {
          Task { await playbackEngine.seek(to: scrubPreview) }
        }
        dragAxis = nil
        scrubPreview = nil
        gestureHint = nil
        brightnessBar = nil
        volumeBar = nil
        scheduleHideControls()
      }
  }

  private func applyPlaybackPreferences() {
    if let preferred = model.playbackPreference.engine {
      engineKind = preferred
    }
    danmakuEnabled = model.danmakuEnabledByDefault
    incognitoThisSession = model.incognitoModeEnabled
  }

  private func configureAudioSession() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback, options: [])
      try session.setActive(true)
    } catch {
      // Keep playback even if session config fails.
    }
  }

  private var displayFailure: String? {
    if isAwaitingPlayback { return nil }
    let raw: String?
    if let failure {
      raw = failure
    } else if case .failed(let message) = playbackEngine.state {
      raw = message
    } else {
      raw = nil
    }
    guard let raw, !raw.isEmpty else { return nil }
    return Self.friendlyPlaybackError(raw)
  }

  private static func friendlyPlaybackError(_ message: String) -> String {
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    if Self.isUnplayableResourceError(text) {
      return "当前线路暂时无法播放，请换来源或重试"
    }
    return text
  }

  private static func isUnplayableResourceError(_ message: String) -> Bool {
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.contains("无可用资源")
      || text.contains("许可")
      || text.contains("无权")
      || text.localizedCaseInsensitiveContains("resource")
      || text.localizedCaseInsensitiveContains("permission")
      || text.localizedCaseInsensitiveContains("not authorized")
      || text.localizedCaseInsensitiveContains("cannot open")
      || text.localizedCaseInsensitiveContains("not playable")
      || text.localizedCaseInsensitiveContains("forbidden")
      || text.localizedCaseInsensitiveContains("access")
  }

  /// Ask parent to switch 来源. Returns true when parent will retry (keep loading chrome).
  @discardableResult
  private func handleExhaustedPlayback(_ message: String) -> Bool {
    let text = Self.friendlyPlaybackError(message)
    if onUnplayable?() == true {
      failure = nil
      failingOver = true
      return true
    }
    failingOver = false
    failure = text
    return false
  }

  private func engine(for url: URL) -> PlaybackEngineKind {
    if let forced = model.playbackPreference.engine { return forced }
    let text = url.absoluteString.lowercased()
    if text.contains(".mkv") || text.contains(".iso") || text.contains(".rmvb") {
      return MPVPlaybackSupport.isAvailable ? .mpv : .avPlayer
    }
    return .avPlayer
  }

  private func loadAvailableSource() async {
    triedURLs = []
    retriedWithAV = false
    failure = nil
    await playCandidates([request.url] + alternateURLs)
  }

  private func playCandidates(_ urls: [URL]) async {
    failingOver = true
    failure = nil
    var keepAwaiting = false
    defer { if !keepAwaiting { failingOver = false } }
    var last = "当前线路暂时无法播放，请换来源或重试"
    for url in urls where !triedURLs.contains(url) {
      triedURLs.append(url)
      let kind = engine(for: url)
      if kind != engineKind {
        engineKind = kind
      }
      var candidate = request
      candidate.url = url
      do {
        playbackEngine.applyOptions(playbackEngineOptions)
        try await playbackEngine.load(candidate)
        activeRequest = candidate
        failure = nil
        playbackEngine.setPlaybackRate(playbackRate)
        playbackEngine.play()
        return
      } catch {
        last = Self.friendlyPlaybackError(error.localizedDescription)
      }
    }
    keepAwaiting = handleExhaustedPlayback(last)
  }

  private func recover(from message: String) async {
    guard !failingOver else { return }
    let pending = ([request.url] + alternateURLs).filter { !triedURLs.contains($0) }
    if !pending.isEmpty {
      await playCandidates(pending)
      return
    }
    if engineKind == .mpv, !retriedWithAV, let url = activeRequest?.url ?? Optional(request.url) {
      retriedWithAV = true
      failingOver = true
      var keepAwaiting = false
      defer { if !keepAwaiting { failingOver = false } }
      engineKind = .avPlayer
      var candidate = request
      candidate.url = url
      do {
        playbackEngine.applyOptions(playbackEngineOptions)
        try await playbackEngine.load(candidate)
        activeRequest = candidate
        failure = nil
        playbackEngine.play()
        return
      } catch {
        keepAwaiting = handleExhaustedPlayback(error.localizedDescription)
        return
      }
    }
    handleExhaustedPlayback(message)
  }

  private var playbackEngineOptions: PlaybackEngineOptions {
    let videoOutput: PlaybackVideoOutput
    switch model.videoOutputPreference {
    case .automatic: videoOutput = .automatic
    case .metal: videoOutput = .metal
    case .system: videoOutput = .system
    }
    let decode: PlaybackDecode
    switch model.decodePreference {
    case .automatic: decode = .automatic
    case .hardware: decode = .hardware
    case .software: decode = .software
    }
    return PlaybackEngineOptions(
      videoOutput: videoOutput,
      decode: decode,
      bufferSeconds: model.bufferPreference.seconds
    )
  }

  private func retryNextAlternate() async {
    guard let active = activeRequest?.url else {
      await loadAvailableSource()
      return
    }
    var urls = [request.url] + alternateURLs
    urls = urls.filter { $0 != active }
    alternateReload(urls: urls)
  }

  private func alternateReload(urls: [URL]) {
    Task {
      var lastError: Error?
      for url in urls {
        var candidate = request
        candidate.url = url
        do {
          playbackEngine.applyOptions(playbackEngineOptions)
          try await playbackEngine.load(candidate)
          activeRequest = candidate
          failure = nil
          playbackEngine.play()
          return
        } catch {
          lastError = error
        }
      }
      failure = lastError?.localizedDescription ?? "媒体不可播放"
    }
  }

  private func switchEngine(_ kind: PlaybackEngineKind) async {
    guard kind != engineKind else { return }
    let position = playbackEngine.currentTime
    playbackEngine.pause()
    engineKind = kind
    var candidate = activeRequest ?? request
    candidate.startPosition = position
    do {
      playbackEngine.applyOptions(playbackEngineOptions)
      try await playbackEngine.load(candidate)
      activeRequest = candidate
      failure = nil
      playbackEngine.setPlaybackRate(playbackRate)
      playbackEngine.play()
      showToast(kind == .mpv ? "已切换到 MPV" : "已切换到 AVPlayer")
    } catch {
      failure = error.localizedDescription
    }
  }

  private func loadDanmaku() async {
    guard let source = request.danmaku.first else { return }
    do {
      let (data, response) = try await URLSession.shared.data(from: source.url)
      if let http = response as? HTTPURLResponse,
        !(200..<300).contains(http.statusCode)
      {
        return
      }
      danmakuComments = DanmakuParser.parse(data)
    } catch {
      danmakuComments = []
    }
  }

  private func seek(by delta: Double) {
    let upper = duration > 0 ? duration : .greatestFiniteMagnitude
    let target = min(max(0, currentTime + delta), upper)
    Task { await playbackEngine.seek(to: target) }
    scheduleHideControls()
  }

  private func togglePlayPause() {
    let wasPlaying = isPlaying
    if wasPlaying {
      playbackEngine.pause()
    } else {
      playbackEngine.play()
    }
    // Inline chrome already has the center button; only flash on double-tap.
    if chrome != .inline {
      revealPlayPauseGlyph(wasPlaying ? .pause : .play)
    }
    showControls = true
    scheduleHideControls()
  }

  /// Double-tap the picture. Inline only toggles — no flash over the center buttons.
  private func flashPlayPause() {
    guard observedState != .loading, !isResolvingNext else { return }
    let willPause = isPlaying
    if willPause {
      playbackEngine.pause()
    } else {
      playbackEngine.play()
    }
    if chrome == .inline {
      showControls = true
      scheduleHideControls()
      return
    }
    revealPlayPauseGlyph(willPause ? .pause : .play)
  }

  private func revealPlayPauseGlyph(_ glyph: PlayPauseGlyph) {
    // Instant swap so the center button and flash never crossfade together.
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

  private func playPauseFlash(_ glyph: PlayPauseGlyph) -> some View {
    Image(systemName: glyph == .pause ? "pause.fill" : "play.fill")
      .font(.system(size: 34, weight: .bold))
      .foregroundStyle(.white)
      .offset(x: glyph == .play ? 2 : 0)
      .frame(width: 76, height: 76)
      .background(.black.opacity(0.5), in: Circle())
      .accessibilityLabel(glyph == .pause ? "已暂停" : "正在播放")
  }

  private func notePlaybackClock(time: Double, durationValue: Double, active: Bool) {
    guard active else { return }
    handleAutoSkip(at: time)
    updateNowPlaying()
    lastReportedTime = time
    if time > 0 { stickyTime = time }
    if durationValue > 0 { stickyDuration = durationValue }
    onPlaybackTimeChange?(time)
  }

  /// Reload a new URL without remounting the player chrome.
  private func softReload(_ next: PlaybackRequest) async {
    if activeRequest?.url == next.url,
      abs((activeRequest?.startPosition ?? 0) - next.startPosition) < 0.5
    {
      return
    }
    softReloadGeneration += 1
    let generation = softReloadGeneration
    stickyDuration = max(stickyDuration, observedDuration, duration)
    stickyTime = max(next.startPosition, lastReportedTime, observedTime)
    triedURLs = []
    retriedWithAV = false
    failure = nil
    didAutoSkipIntro = false
    didHandleEnded = false
    showingNextEpisode = false
    activeEpisode = episode
    activeFlag = flag
    activeLineEpisodes = lineEpisodes.isEmpty
      ? (playbackLines.first(where: { $0.name == flag })?.episodes ?? [])
      : lineEpisodes
    await playCandidates([next.url] + alternateURLs)
    guard generation == softReloadGeneration else { return }
    if let index = selectedSubtitleIndex, next.subtitles.indices.contains(index) {
      applySubtitleSelection(index)
    } else {
      selectedSubtitleIndex = nil
      overlayCues = []
    }
    updateNowPlaying()
    scheduleHideControls()
  }

  private func handleAutoSkip(at time: Double) {
    // Per-title marks: always apply when set (长征 ≠ 嫁金钗).
    if !didAutoSkipIntro,
      let intro = skipMark?.introEnd,
      intro > 0,
      time + 0.3 < intro,
      time < 1.5
    {
      didAutoSkipIntro = true
      Task { await playbackEngine.seek(to: intro) }
      showToast("已跳过片头")
    }
    if let outro = skipMark?.outroStart,
      outro > 0,
      duration > 0,
      time >= outro,
      nextEpisode != nil,
      !didHandleEnded
    {
      didHandleEnded = true
      Task { await playNextEpisode(auto: true) }
    }
  }

  private func handlePlaybackEnded(_ state: PlaybackState) {
    guard state == .ended, !didHandleEnded else { return }
    didHandleEnded = true
    if nextEpisode != nil {
      if model.adSkipPreference == .aggressive {
        Task { await playNextEpisode(auto: true) }
      } else {
        showingNextEpisode = true
        showControls = true
      }
    } else {
      showToast("本剧已播完")
    }
  }

  private func playPreviousEpisode() async {
    guard let previous = previousEpisode else {
      showToast("已经是第一集")
      return
    }
    await playEpisode(previous, flag: activeFlag ?? flag ?? "")
  }

  private func playNextEpisode(auto: Bool) async {
    guard let next = nextEpisode else {
      showToast("已经是最后一集")
      return
    }
    let line = activeFlag ?? flag ?? ""
    if let onPlayEpisode {
      onPlayEpisode(next, line)
      return
    }
    await playEpisode(next, flag: line, autoToast: auto)
  }

  private func playEpisode(_ episode: Episode, flag: String, autoToast: Bool = false) async {
    isResolvingNext = true
    showingNextEpisode = false
    defer { isResolvingNext = false }
    do {
      let nextRequest = try await model.resolvePlayback(
        item: item,
        episode: episode,
        flag: flag
      )
      activeEpisode = episode
      activeFlag = flag
      activeRequest = nextRequest
      didAutoSkipIntro = false
      didHandleEnded = false
      try await playbackEngine.load(nextRequest)
      if let index = selectedSubtitleIndex {
        applySubtitleSelection(index)
      }
      failure = nil
      playbackEngine.setPlaybackRate(playbackRate)
      playbackEngine.play()
      updateNowPlaying()
      showToast(autoToast ? "正在播放 \(episode.name)" : episode.name)
      scheduleHideControls()
    } catch {
      failure = error.localizedDescription
      didHandleEnded = false
    }
  }

  private func switchPlaybackLine(_ line: PlaybackLine) async {
    activeFlag = line.name
    activeLineEpisodes = line.episodes
    model.setPreferredPlaybackFlag(
      line.name,
      sourceKey: sourceKey,
      vodId: item.vodId
    )
    let target =
      line.episodes.first(where: { $0.value == activeEpisode?.value })
      ?? activeEpisode.flatMap { current in
        line.episodes.first(where: { $0.name == current.name })
      }
      ?? line.episodes.first
    guard let target else {
      showToast("该线路没有选集")
      return
    }
    await playEpisode(target, flag: line.name)
  }

  private func applySubtitleSelection(_ index: Int?) {
    if engineKind == .mpv {
      mpvEngine.selectSubtitleTrack(index: index)
      overlayCues = []
      return
    }
    Task { await loadOverlaySubtitles(index) }
  }

  private func loadOverlaySubtitles(_ index: Int?) async {
    guard let index,
      let subs = (activeRequest ?? request).subtitles as [PlaybackSubtitle]?,
      subs.indices.contains(index)
    else {
      overlayCues = []
      return
    }
    isLoadingSubtitles = true
    defer { isLoadingSubtitles = false }
    do {
      let (data, response) = try await URLSession.shared.data(from: subs[index].url)
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        overlayCues = []
        showToast("字幕加载失败")
        return
      }
      overlayCues = SubtitleParser.parse(data)
      if overlayCues.isEmpty {
        showToast("无法解析该字幕")
      }
    } catch {
      overlayCues = []
      showToast("字幕加载失败")
    }
  }

  private func configureRemoteCommandsIfNeeded() {
    guard !remoteCommandsConfigured else { return }
    remoteCommandsConfigured = true
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.isEnabled = true
    center.pauseCommand.isEnabled = true
    center.togglePlayPauseCommand.isEnabled = true
    let av = avEngine
    let mpv = mpvEngine
    let playTarget = center.playCommand.addTarget { _ in
      Task { @MainActor in
        av.play()
        mpv.play()
      }
      return .success
    }
    let pauseTarget = center.pauseCommand.addTarget { _ in
      Task { @MainActor in
        av.pause()
        mpv.pause()
      }
      return .success
    }
    let toggleTarget = center.togglePlayPauseCommand.addTarget { _ in
      Task { @MainActor in
        if av.state == .playing || mpv.state == .playing {
          av.pause()
          mpv.pause()
        } else {
          av.play()
          mpv.play()
        }
      }
      return .success
    }
    remoteCommandTargets = [
      (center.playCommand, playTarget),
      (center.pauseCommand, pauseTarget),
      (center.togglePlayPauseCommand, toggleTarget),
    ]
  }

  private func removeRemoteCommands() {
    for registration in remoteCommandTargets {
      registration.command.removeTarget(registration.target)
    }
    remoteCommandTargets = []
    remoteCommandsConfigured = false
  }

  private func updateNowPlaying() {
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: activeEpisode?.name ?? item.name,
      MPMediaItemPropertyArtist: item.name,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: playbackEngine.currentTime,
      MPNowPlayingInfoPropertyPlaybackRate: playbackEngine.state == .playing
        ? Double(playbackRate) : 0,
    ]
    if duration > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = duration
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func clearNowPlaying() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  private func handleInterruption(_ note: Notification) {
    guard
      let info = note.userInfo,
      let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else { return }
    if type == .began {
      playbackEngine.pause()
    }
  }

  private func scheduleHideControls() {
    hideTask?.cancel()
    // Paused: keep chrome so play is one tap away. Playing: auto-hide like hover.
    guard isPlaying else {
      showControls = true
      return
    }
    hideTask = Task {
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, !isScrubbing else { return }
      withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
    }
  }

  private func showToast(_ text: String) {
    withAnimation { toast = text }
    Task {
      try? await Task.sleep(for: .seconds(1.8))
      if toast == text {
        withAnimation { toast = nil }
      }
    }
  }

  private func format(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00" }
    let value = Int(max(0, seconds))
    let h = value / 3600
    let m = (value % 3600) / 60
    let s = value % 60
    if h > 0 {
      return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
  }
}

/// Thin seek bar with a small thumb — SwiftUI `Slider` thumbs are oversized in the player chrome.
private struct CompactSeekBar: View {
  @Binding var value: Double
  var range: ClosedRange<Double>
  var tint: Color
  var enabled: Bool
  var onEditingChanged: (Bool) -> Void

  @State private var isDragging = false

  private let trackHeight: CGFloat = 3
  private let thumbSize: CGFloat = 10

  var body: some View {
    GeometryReader { geo in
      let span = max(range.upperBound - range.lowerBound, 0.0001)
      let progress = min(1, max(0, (value - range.lowerBound) / span))
      let usable = max(geo.size.width - thumbSize, 1)
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.white.opacity(0.28))
          .frame(height: trackHeight)
        Capsule()
          .fill(tint)
          .frame(width: thumbSize / 2 + usable * progress, height: trackHeight)
        Circle()
          .fill(tint)
          .frame(width: thumbSize, height: thumbSize)
          .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
          .offset(x: usable * progress)
      }
      .frame(maxHeight: .infinity, alignment: .center)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { drag in
            guard enabled else { return }
            if !isDragging {
              isDragging = true
              onEditingChanged(true)
            }
            let x = min(max(0, drag.location.x - thumbSize / 2), usable)
            value = range.lowerBound + (x / usable) * span
          }
          .onEnded { _ in
            guard enabled else { return }
            isDragging = false
            onEditingChanged(false)
          }
      )
      .opacity(enabled ? 1 : 0.45)
      .allowsHitTesting(enabled)
    }
  }
}

private struct SystemPlayerView: UIViewControllerRepresentable {
  let player: AVPlayer
  var showsControls = false
  var fillsFrame = false

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.showsPlaybackControls = showsControls
    controller.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
    controller.view.backgroundColor = .black
    controller.allowsPictureInPicturePlayback = true
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    if controller.player !== player {
      controller.player = player
    }
    controller.showsPlaybackControls = showsControls
    controller.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
    controller.view.backgroundColor = .black
  }
}

@MainActor
final class VolumeProxy {
  var volume: Float = AVAudioSession.sharedInstance().outputVolume
  weak var slider: UISlider?

  func setVolume(_ value: Float) {
    let clamped = min(1, max(0, value))
    volume = clamped
    slider?.value = clamped
  }
}

private struct VolumeProxyHost: UIViewRepresentable {
  let proxy: VolumeProxy

  func makeUIView(context: Context) -> MPVolumeView {
    let view = MPVolumeView(frame: .zero)
    view.alpha = 0.01
    view.isUserInteractionEnabled = false
    DispatchQueue.main.async {
      if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
        proxy.slider = slider
        proxy.volume = slider.value
      }
    }
    return view
  }

  func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
