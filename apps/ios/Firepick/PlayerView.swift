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

/// Align leading/trailing chrome to the seek bar (not the time+bar stack).
private extension VerticalAlignment {
  private enum SeekBarCenter: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
      context[VerticalAlignment.center]
    }
  }

  static let seekBarCenter = VerticalAlignment(SeekBarCenter.self)
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
  /// Parent layout fill (half↔full) — may change without chrome flipping.
  var layoutExpanded: Bool = false
  var onExpand: (() -> Void)? = nil
  var onCollapse: (() -> Void)? = nil
  /// startPosition: nil = resume that episode's history; 0 = start from beginning (auto-next).
  var onPlayEpisode: ((Episode, String, Double?) -> Void)? = nil
  /// Live clock for Detail 来源 handoff (continue from same timestamp).
  var onPlaybackTimeChange: ((Double) -> Void)? = nil
  /// All candidate URLs failed — return true if parent will switch 来源.
  var onUnplayable: (() -> Bool)? = nil
  /// Detail bumps this before silent 换站 network work — freeze the live frame early.
  var silentHandoffPulse: Int = 0

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
  @State private var danmakuEnabled = false
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
  /// After 切集, ignore spurious `.ended` for a few seconds (stops ep3→ep4尾→ep5).
  @State private var ignoreEndedUntil = Date.distantPast
  /// Mid-roll ad segments already seeked past for the current request.
  @State private var skippedAdSegmentKeys: Set<String> = []
  @State private var showingNextEpisode = false
  @State private var nextEpisodeCountdown = 5
  @State private var nextEpisodeCountdownTask: Task<Void, Never>?
  @State private var isResolvingNext = false
  /// Once a frame was shown, never cover with black/spinner — keep last picture.
  @State private var keepLastFrame = false
  /// Frozen still shown over AV while the next URL/seek catches up (切集/快进).
  @State private var freezeFrame: UIImage?
  /// True while soft-reloading a different episode/URL — show loading over the handoff.
  @State private var mediaTransitionInFlight = false
  /// ±10 / scrub — spinner replaces center play/pause; video stays visible (no black flash).
  @State private var seekHandoff = false
  /// Auto-next landed near that episode's end — pause and do not cascade.
  @State private var pauseAfterNearEndLanding = false
  /// switchToEpisode already flushed the leaving ep — softReload must not re-save with new sticky.
  @State private var skipNextLeavePersist = false
  @State private var playerSurfaceBox = PlayerSurfaceBox()
  @State private var volumeProxy = VolumeProxy()
  @State private var dragAxis: DragAxis?
  @State private var dragStartBrightness: CGFloat = 0
  @State private var dragStartVolume: Float = 0
  @State private var dragStartTime: Double = 0
  @State private var remoteCommandsConfigured = false
  @State private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
  @State private var showingRatePicker = false
  @State private var showingResolutionPicker = false
  @State private var streamResolution: StreamResolution = .automatic
  /// Auto mode stepped down after stall / constrained network; clears when path recovers.
  @State private var autoQualityDegraded = false
  /// Detected output height while 自动 (from AV presentationSize).
  @State private var detectedOutputHeight: CGFloat = 0
  /// Max short-edge height from HLS variants / URL hints (gates 4K/2K menu rows).
  @State private var streamPeakHeight: CGFloat = 0
  /// Cloud ad-skip segments resolved after first frame (not blocking open).
  @State private var cloudAdSkips: [SkipSegment] = []
  @State private var orientationLocked = false
  /// Keep progress chrome stable while soft-reloading another 来源.
  @State private var stickyDuration: Double = 0
  @State private var stickyTime: Double = 0
  @State private var lastReportedTime: Double = 0
  @State private var softReloadGeneration = 0
  @State private var lastProgressWallclock = Date()
  @State private var lastProgressMediaTime: Double = -1
  @State private var stallRecoveryInFlight = false
  @State private var recoverInFlight = false
  /// Caps cold-start「首帧过慢」station hops so we do not thrash the whole pool.
  @State private var firstFrameFailoverCount = 0
  /// Stall / auto-line switch: keep chrome + last frame, no center spinner.
  @State private var silentHandoff = false
  /// User intent to keep playing across half/full screen transitions.
  @State private var wantsPlaying = true
  @State private var chromeResumeGeneration = 0
  @State private var lastPersistedHistoryPosition: Double = -1
  /// Layout remounts can fire onDisappear briefly — delay stop so expand keeps AV alive.
  @State private var teardownTask: Task<Void, Never>?
  @State private var isPlayerMounted = false
  @State private var holdSpeedSide: HoldSpeedSide?
  @State private var holdSpeedTask: Task<Void, Never>?
  @State private var rateBeforeHold: Float = 1

  private enum DragAxis {
    case horizontal
    case vertical
  }

  private enum HoldSpeedSide {
    case rewind
    case forward
  }

  private static let rateOptions: [Float] = [0.75, 1, 1.25, 1.5, 2]

  private enum StreamResolution: String, CaseIterable, Identifiable {
    case automatic
    case p2160
    case p1440
    case p1080
    case p720
    case p480
    case p360

    var id: String { rawValue }

    var title: String {
      switch self {
      case .automatic: "自动"
      case .p2160: "4K"
      case .p1440: "2K"
      case .p1080: "1080P"
      case .p720: "720P"
      case .p480: "480P"
      case .p360: "360P"
      }
    }

    /// AVPlayer preferredPeakBitRate；自动档由 `effectivePeakBitRate` 优先封顶 1080P。
    var peakBitRate: Double {
      switch self {
      case .automatic: 4_500_000
      case .p2160: 16_000_000
      case .p1440: 8_000_000
      case .p1080: 4_500_000
      case .p720: 2_500_000
      case .p480: 1_200_000
      case .p360: 600_000
      }
    }
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
    layoutExpanded: Bool = false,
    onExpand: (() -> Void)? = nil,
    onCollapse: (() -> Void)? = nil,
    onPlayEpisode: ((Episode, String, Double?) -> Void)? = nil,
    onPlaybackTimeChange: ((Double) -> Void)? = nil,
    onUnplayable: (() -> Bool)? = nil,
    silentHandoffPulse: Int = 0
  ) {
    self.request = request
    self.item = item
    self.episode = episode
    self.alternateURLs = alternateURLs
    self.flag = flag
    self.lineEpisodes = lineEpisodes
    self.playbackLines = playbackLines
    self.chrome = chrome
    self.layoutExpanded = layoutExpanded
    self.onExpand = onExpand
    self.onCollapse = onCollapse
    self.onPlayEpisode = onPlayEpisode
    self.onPlaybackTimeChange = onPlaybackTimeChange
    self.onUnplayable = onUnplayable
    self.silentHandoffPulse = silentHandoffPulse
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
    // During soft-reload / black buffer keep the last clock — don't let the scrubber
    // crawl while the canvas is still black, then snap/reload from 0.
    if stickyTime > 0 {
      if failingOver || isResolvingNext || silentHandoff { return stickyTime }
      if !hasRenderableVideo, failure == nil { return stickyTime }
      switch observedState {
      case .loading, .idle:
        if failure == nil { return stickyTime }
      default:
        break
      }
    }
    return observedTime
  }

  /// AV: wait for first frame. MPV: treat ready/playing as rendered.
  private var hasRenderableVideo: Bool {
    if engineKind == .mpv {
      switch observedState {
      case .playing, .paused, .ready: return true
      default: return false
      }
    }
    return avEngine.isReadyForDisplay
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
    attachPlayerLifecycle(to: playerWithSheets)
      .onChange(of: silentHandoffPulse) { _, pulse in
        // Detail freezes the live picture before findItem/loadDetail — keeps 换站无感.
        guard pulse > 0 else { return }
        beginSilentVisualHandoff(refreshFreeze: true)
      }
  }

  private var playerWithSheets: some View {
    playerSurface
      .background {
        if chrome == .immersive {
          Color.black.ignoresSafeArea()
        }
      }
      .statusBarHidden(chrome != .inline)
      .persistentSystemOverlays(chrome == .inline ? .automatic : .hidden)
      .sheet(isPresented: $showingLines) {
        linePickerSheet
          .presentationDetents([.medium])
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
  }

  @ViewBuilder
  private func attachPlayerLifecycle<V: View>(to content: V) -> some View {
    content
      .background(VolumeProxyHost(proxy: volumeProxy).frame(width: 0, height: 0))
      .task {
        applyPlaybackPreferences()
        configureAudioSession()
        configureRemoteCommandsIfNeeded()
        UIApplication.shared.isIdleTimerDisabled = true
      }
      .task(id: request.id) {
        if activeRequest == nil {
          await loadAvailableSource()
        } else if activeRequest?.url == request.url {
          // Same URL: only seek during an intentional 切集 handoff. Otherwise
          // ignore startPosition so scrub/±10 never jumps back to stale 片尾.
          if mediaTransitionInFlight {
            let target = max(0, request.startPosition)
            stickyTime = target
            lastReportedTime = target
            await playbackEngine.seek(to: target)
          }
          activeRequest = request
          if wantsPlaying { playbackEngine.play() }
        } else {
          await softReload(request)
        }
        updateNowPlaying()
        scheduleHideControls()
        // Background — never block first frame on B站弹幕 / 云端去广.
        async let danmakuReady: Void = loadDanmaku()
        async let adSkipReady: Void = enrichCloudAdSkipsIfNeeded()
        _ = await (danmakuReady, adSkipReady)
      }
      .onChange(of: avEngine.currentTime) { _, time in
        notePlaybackClock(
          time: time, durationValue: avEngine.duration, active: engineKind == .avPlayer)
        if engineKind == .avPlayer { refreshDetectedQuality() }
      }
      .onChange(of: mpvEngine.currentTime) { _, time in
        notePlaybackClock(
          time: time, durationValue: mpvEngine.duration, active: engineKind == .mpv)
      }
      .onAppear {
        isPlayerMounted = true
        teardownTask?.cancel()
        teardownTask = nil
        // Expand remount resumes; real dismiss already cleared wantsPlaying in teardown.
        if wantsPlaying {
          configureAudioSession()
          playbackEngine.play()
        }
      }
      .onChange(of: chrome) { _, _ in
        // Preserve pause/play + rate — do not force play on expand/collapse.
        scheduleResumeAfterChromeChange()
      }
      .onChange(of: layoutExpanded) { _, _ in
        // Expand often changes layout before chrome flips to immersive.
        scheduleResumeAfterChromeChange()
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: UIDevice.orientationDidChangeNotification
        )
      ) { _ in
        scheduleResumeAfterChromeChange()
      }
      .task(id: isPlaying) {
        guard isPlaying else { return }
        lastProgressWallclock = Date()
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(2))
          guard wantsPlaying, !failingOver, !silentHandoff, !stallRecoveryInFlight,
            failure == nil
          else {
            continue
          }
          if Date().timeIntervalSince(lastProgressWallclock) >= 8 {
            await recoverFromStall()
          }
        }
      }
      // Cold start / 换源: API 快不等于开播快。无首帧约 7.5s → 换下一站。
      .task(id: (activeRequest?.url ?? request.url).absoluteString) {
        await watchSlowFirstFrame()
      }
      .onChange(of: selectedSubtitleIndex) { _, index in
        applySubtitleSelection(index)
      }
      .onChange(of: avEngine.state) { _, state in
        // Do NOT clear freeze here — isReadyForDisplay flickers during 切集 and
        // caused black + old-frame flashes. softReload/seek end the handoff.
        handlePlaybackEnded(state)
        if case .failed(let message) = state {
          // Drop any prior error text; `.failed` already counts as awaiting.
          failure = nil
          Task { await recover(from: message) }
        }
        if state == .playing {
          clearFailureIfRenderable()
          scheduleHideControls()
        }
      }
      .onChange(of: avEngine.isReadyForDisplay) { _, ready in
        if ready { clearFailureIfRenderable() }
      }
      .onChange(of: mpvEngine.state) { _, state in
        handlePlaybackEnded(state)
        if case .failed(let message) = state {
          failure = nil
          Task { await recover(from: message) }
        }
        if state == .playing || state == .ready {
          clearFailureIfRenderable()
        }
        if state == .playing { scheduleHideControls() }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .background, !model.backgroundPlaybackEnabled {
          playbackEngine.pause()
        } else if phase == .active, wantsPlaying, model.backgroundPlaybackEnabled {
          playbackEngine.play()
        }
      }
      .onChange(of: model.incognitoModeEnabled) { _, enabled in
        incognitoThisSession = enabled
      }
      .onChange(of: model.backgroundPlaybackEnabled) { _, enabled in
        if enabled { configureAudioSession() }
      }
      .onChange(of: model.isNetworkConstrained) { _, constrained in
        if !constrained {
          autoQualityDegraded = false
        }
        guard streamResolution == .automatic else { return }
        applyPreferredPeakBitRate()
      }
      .onReceive(
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
      ) { note in
        handleInterruption(note)
      }
      .onDisappear {
        isPlayerMounted = false
        hideTask?.cancel()
        nextEpisodeCountdownTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        // Capture BEFORE any stop — layout remounts on expand must not wipe progress.
        persistWatchProgress(force: true)
        let resumeAt = max(observedTime, stickyTime, lastReportedTime)
        stickyTime = max(stickyTime, resumeAt)
        // Silence immediately on back — delayed stop alone left ghost audio on 最近观看.
        silenceAllEngines()
        teardownTask?.cancel()
        teardownTask = Task { @MainActor in
          // Half↔full can briefly disappear the representable; wait before killing AV.
          try? await Task.sleep(for: .milliseconds(450))
          guard !Task.isCancelled, !isPlayerMounted else { return }
          wantsPlaying = false
          clearNowPlaying()
          stopAllEngines()
          removeRemoteCommands()
          if orientationLocked {
            orientationLocked = false
            OrientationBridge.unlock()
          }
          model.releasePlaybackCache()
        }
      }
  }

  /// Pause both engines so AV↔MPV handoff / dismiss never leaves a second soundtrack.
  private func silenceAllEngines() {
    avEngine.pause()
    mpvEngine.pause()
  }

  private func stopAllEngines() {
    avEngine.stop()
    mpvEngine.stop()
  }

  /// Parent `PlayerFrameModifier` owns half-screen 16:9. Fullscreen stage must
  /// be the full window so 返回/菜单 sit on screen corners (black bars OK).
  private var playerSurface: some View {
    playerStage
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black)
      .ignoresSafeArea(.container, edges: chrome == .inline ? [] : .all)
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
          speed: model.danmakuSpeed,
          displayArea: model.danmakuDisplayArea
        )
        .allowsHitTesting(false)
        if !overlayCues.isEmpty {
          SubtitleOverlay(
            cues: overlayCues,
            currentTime: observedTime,
            fontSize: subtitleFontSize,
            color: subtitleColor,
            outlined: model.subtitleOutlineEnabled
          )
          .allowsHitTesting(false)
        }
        if showControls {
          controlsOverlay
            .transition(.opacity)
        } else if isCenterLoading {
          // Controls hidden but still buffering — loading stays on play/pause slot.
          centerPlayButton
            .allowsHitTesting(false)
        }
        if chrome != .inline {
          playerSideDrawer
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
        if showingNextEpisode, let next = nextEpisode {
          nextEpisodeToast(next)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if let toast {
          Text(toast)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.42), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, chrome == .inline ? 48 : 64)
            .allowsHitTesting(false)
        }
        if let displayFailure {
          failureOverlay(displayFailure)
        }
        // Loading only on center play/pause — no standalone spinner overlay.
        if let playPauseGlyph, !isCenterLoading, displayFailure == nil {
          playPauseFlash(playPauseGlyph)
            .allowsHitTesting(false)
        }
      }
      .contentShape(Rectangle())
      // Long-press via UIKit so it does not steal SwiftUI taps (controls toggle).
      .background {
        HoldSpeedProbe(
          onBegan: { point in
            beginHoldSpeed(rewind: point.x < geo.size.width * 0.5)
          },
          onEnded: {
            endHoldSpeed()
          }
        )
      }
      .simultaneousGesture(playerDrag(in: geo.size))
      .simultaneousGesture(edgeSwipeBackGesture(in: geo.size))
      .onTapGesture(count: 2) {
        singleTapTask?.cancel()
        flashPlayPause()
      }
      .onTapGesture(count: 1) {
        guard holdSpeedSide == nil else { return }
        if isPlayerDrawerOpen {
          closePlayerDrawers()
          return
        }
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

  /// Left-edge zone that owns swipe-back (must not compete with seek).
  private var edgeBackWidth: CGFloat { 48 }

  /// Left-edge swipe right → exit fullscreen or leave the player / detail page.
  /// Tuned for real devices: wider edge + lower distance than simulator-only defaults.
  private func edgeSwipeBackGesture(in size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 20)
      .onEnded { value in
        let fromLeftEdge = value.startLocation.x < edgeBackWidth
        let mostlyHorizontal = abs(value.translation.width) > abs(value.translation.height) * 1.05
        let swipedRight = value.translation.width > 56
        guard fromLeftEdge, mostlyHorizontal, swipedRight else { return }
        if let onCollapse, chrome != .inline {
          onCollapse()
        } else {
          playbackEngine.stop()
          dismiss()
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

  /// Light top toast for auto-next — sits under the title, clear of center play.
  private func nextEpisodeToast(_ next: Episode) -> some View {
    HStack(spacing: 6) {
      Text("即将播放")
        .foregroundStyle(.white.opacity(0.72))
      Text(next.name)
        .fontWeight(.semibold)
        .foregroundStyle(.white)
        .lineLimit(1)
      Text("\(nextEpisodeCountdown)s")
        .font(.footnote.monospacedDigit().weight(.bold))
        .foregroundStyle(Color.orange)
    }
    .font(.footnote)
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .background(Color.black.opacity(0.38), in: Capsule())
    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.top, chrome == .inline ? 44 : 68)
    .allowsHitTesting(false)
  }

  @ViewBuilder
  private var videoLayer: some View {
    ZStack {
      Group {
        if engineKind == .mpv {
          MPVVideoView(engine: mpvEngine)
        } else {
          SystemPlayerView(
            player: avEngine.player,
            surface: playerSurfaceBox,
            showsControls: false,
            // Keep source aspect (letterbox/pillarbox OK). Controls sit on the
            // full-screen stage outside the picture, not inside the video box.
            fillsFrame: false
          )
        }
      }
      // Hide live AV only for 切集/换源 freeze — ±10 seek keeps the picture.
      .opacity(shouldHideLivePlayer ? 0 : 1)

      // Hold the previous picture across 切集 / 换源 — never flash black.
      if let freezeFrame {
        Image(uiImage: freezeFrame)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.black)
          .allowsHitTesting(false)
      } else if shouldHideLivePlayer {
        Color.black
          .allowsHitTesting(false)
      }
      // No standalone ProgressView here — loading is bound to center play/pause.
    }
  }

  private var shouldHideLivePlayer: Bool {
    if freezeFrame != nil { return true }
    // Silent 换源 without a freeze frame: keep the live surface (avoid black).
    if mediaTransitionInFlight && !(silentHandoff || keepLastFrame) { return true }
    return false
  }

  /// Capture the current picture, then keep silent chrome until the next frame.
  /// - Parameter refreshFreeze: 从仍可见的直播面重拍（seek/切集开始时）。
  private func beginSilentVisualHandoff(refreshFreeze: Bool = false) {
    // Always mark silent — even before first frame — so 换源 never blacks out.
    keepLastFrame = true
    silentHandoff = true
    // Already frozen: keep that still — never re-snapshot a hidden/black AV surface.
    if freezeFrame != nil { return }
    guard refreshFreeze || hasRenderableVideo else { return }
    if let snap = playerSurfaceBox.snapshot(), snap.size.width > 1 {
      freezeFrame = snap
    }
  }

  private func endSilentVisualHandoffIfReady() {
    guard hasRenderableVideo else { return }
    keepLastFrame = true
    silentHandoff = false
    freezeFrame = nil
    mediaTransitionInFlight = false
    seekHandoff = false
  }

  /// After seek/切集, keep the freeze until AV has a stable picture (not a flicker).
  private func waitForRenderableFrame(near target: Double? = nil) async {
    var stable = 0
    for _ in 0..<60 {
      let ready = hasRenderableVideo
      let nearOk: Bool = {
        guard let target else { return true }
        // New episode usually starts near 0.
        if target < 1.5 { return observedTime < 8 || abs(observedTime - target) < 3 }
        return abs(observedTime - target) < 2.5
      }()
      if ready && nearOk {
        stable += 1
        if stable >= 4 { return }  // ~200ms stable
      } else {
        stable = 0
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  /// Shared leading inset so immersive ✕ lines up with 下一集.
  private var controlSidePadding: CGFloat {
    chrome == .inline ? 8 : 16
  }

  private var controlsOverlay: some View {
    ZStack {
      VStack(spacing: 0) {
        topControls
        Spacer()
        if chrome != .inline {
          skipButtons
            .padding(.horizontal, controlSidePadding)
            .padding(.bottom, 8)
        }
        progressBar
          .padding(.horizontal, controlSidePadding)
          .padding(.bottom, chrome == .inline ? 4 : 14)
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
      }
      centerPlayButton
    }
  }

  private var isPlayerDrawerOpen: Bool {
    showingRatePicker || showingResolutionPicker || showingEpisodes
  }

  /// True when we still have a visible picture (freeze or live frame) to cover handoff.
  private var hasVisibleHandoffPicture: Bool {
    freezeFrame != nil || hasRenderableVideo
  }

  /// Loading / failover / not-yet-ready — never show play/pause as if content is ready.
  private var isAwaitingPlayback: Bool {
    // Have a still/live picture: do not treat as empty awaiting blackout.
    if hasVisibleHandoffPicture, keepLastFrame || silentHandoff { return false }
    if failingOver || isResolvingNext || stallRecoveryInFlight { return true }
    if failure != nil { return false }
    switch observedState {
    case .loading, .idle:
      return true
    case .failed:
      // Recover / 换源 in flight — keep spinner, never flash failure chrome.
      return true
    case .ready, .playing, .paused:
      // Duration still unknown — keep spinner so progress chrome doesn't look empty.
      if duration <= 0 { return true }
      // Clock can move on a black canvas before the first frame — keep awaiting.
      return !hasRenderableVideo
    default:
      return false
    }
  }

  /// Cold start / failover awaiting — feeds center play/pause loading only.
  private var showsLoadingSpinner: Bool {
    if displayFailure != nil { return false }
    // Only hide spinner when a real picture covers the handoff — never bare black.
    if hasVisibleHandoffPicture, keepLastFrame || silentHandoff { return false }
    if failingOver || isResolvingNext || stallRecoveryInFlight { return true }
    return isAwaitingPlayback
  }

  /// Any buffering that replaces the center play/pause glyph (not a free-floating spinner).
  private var isCenterLoading: Bool {
    if displayFailure != nil { return false }
    if seekHandoff { return true }
    // Silent station upgrade with a freeze/live frame: keep picture, no center「加载」.
    if hasVisibleHandoffPicture, silentHandoff || keepLastFrame { return false }
    if mediaTransitionInFlight || isResolvingNext || stallRecoveryInFlight || failingOver {
      return true
    }
    return showsLoadingSpinner
  }

  @ViewBuilder
  private var centerPlayButton: some View {
    if displayFailure != nil {
      Color.clear.frame(width: 1, height: 1)
    } else {
      HStack(spacing: chrome == .inline ? 36 : 48) {
        Button {
          seek(by: -10)
        } label: {
          Image(systemName: "gobackward.10")
            .font(.title2)
        }
        .accessibilityLabel("快退")
        .disabled(isCenterLoading)

        if isCenterLoading {
          ProgressView()
            .tint(.white)
            .scaleEffect(1.25)
            .frame(width: 44, height: 44)
            .accessibilityLabel("加载中")
        } else {
          Button {
            togglePlayPause()
          } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 34, weight: .regular))
          }
          .accessibilityLabel(isPlaying ? "暂停" : "播放")
        }

        Button {
          seek(by: 10)
        } label: {
          Image(systemName: "goforward.10")
            .font(.title2)
        }
        .accessibilityLabel("快进")
        .disabled(isCenterLoading)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.white)
      .opacity(isCenterLoading && !showControls ? 0.95 : 1)
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
                  ? "heart.fill" : "heart"
              )
              .font(.body.weight(.semibold))
              .frame(width: 36, height: 36)
            }
            .accessibilityLabel("收藏")
            menuButton
          }
        }
      } else {
        // Keep title close to ✕ — immersive side padding 40 made the gap look huge.
        HStack(spacing: 4) {
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
          PlayerTitleLabel(text: headlineTitle, font: .headline, maxWidth: 280)
          Spacer(minLength: 0)
          menuButton
        }
      }
    }
    .foregroundStyle(.white)
    .padding(.horizontal, controlSidePadding)
    .padding(.top, chrome == .inline ? 6 : 12)
  }

  /// Trailing-edge drawer for 倍速 / 清晰度 / 选集 (not full-screen sheets).
  @ViewBuilder
  private var playerSideDrawer: some View {
    let open = isPlayerDrawerOpen
    ZStack(alignment: .trailing) {
      if open {
        Color.black.opacity(0.45)
          .ignoresSafeArea()
          .onTapGesture { closePlayerDrawers() }
          .transition(.opacity)

        Group {
          if showingRatePicker {
            rateDrawerPanel
          } else if showingResolutionPicker {
            resolutionDrawerPanel
          } else if showingEpisodes {
            episodeDrawerPanel
          }
        }
        .frame(width: drawerPanelWidth)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.82))
        .transition(.asymmetric(
          insertion: .move(edge: .trailing).combined(with: .opacity),
          removal: .move(edge: .trailing).combined(with: .opacity)
        ))
      }
    }
    .animation(.easeInOut(duration: 0.28), value: open)
    .animation(.easeInOut(duration: 0.28), value: showingRatePicker)
    .animation(.easeInOut(duration: 0.28), value: showingResolutionPicker)
    .animation(.easeInOut(duration: 0.28), value: showingEpisodes)
  }

  private var drawerPanelWidth: CGFloat {
    min(220, UIScreen.main.bounds.width * 0.30)
  }

  private enum PlayerDrawer {
    case rate
    case resolution
    case episodes
  }

  private func openPlayerDrawer(_ drawer: PlayerDrawer) {
    hideTask?.cancel()
    showControls = true
    withAnimation(.easeInOut(duration: 0.28)) {
      showingRatePicker = drawer == .rate
      showingResolutionPicker = drawer == .resolution
      showingEpisodes = drawer == .episodes
      showingLines = false
    }
  }

  private func closePlayerDrawers() {
    withAnimation(.easeInOut(duration: 0.24)) {
      showingRatePicker = false
      showingResolutionPicker = false
      showingEpisodes = false
      showingLines = false
    }
    scheduleHideControls()
  }

  private var rateDrawerPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("倍速")
        .font(.headline)
        .foregroundStyle(.white)
        .padding(.top, 20)
      ForEach(Self.rateOptions, id: \.self) { rate in
        let selected = abs(playbackRate - rate) < 0.01
        Button {
          playbackRate = rate
          playbackEngine.setPlaybackRate(rate)
          closePlayerDrawers()
        } label: {
          HStack {
            Text(rate == 1 ? "1.0×" : "\(rate.formatted())×")
              .font(.body.weight(selected ? .semibold : .regular))
            Spacer()
            if selected {
              Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
            }
          }
          .foregroundStyle(selected ? Color.orange : Color.white)
          .padding(.vertical, 12)
          .padding(.horizontal, 12)
          .background(
            Color.white.opacity(selected ? 0.16 : 0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
          )
        }
        .buttonStyle(.plain)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
  }

  private var resolutionDrawerPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("清晰度")
        .font(.headline)
        .foregroundStyle(.white)
        .padding(.top, 20)
      ForEach(availableStreamResolutions) { option in
        let selected = streamResolution == option
        // Auto row label is stable — never mirror the current manual rung (that showed two「1080P」).
        let label = option == .automatic ? "自动（1080P）" : option.title
        Button {
          streamResolution = option
          if option != .automatic {
            autoQualityDegraded = false
          }
          applyPreferredPeakBitRate()
          showToast("清晰度：\(label)")
          closePlayerDrawers()
        } label: {
          HStack {
            Text(label)
              .font(.body.weight(selected ? .semibold : .regular))
            Spacer()
            if selected {
              Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
            }
          }
          .foregroundStyle(selected ? Color.orange : Color.white)
          .padding(.vertical, 12)
          .padding(.horizontal, 12)
          .background(
            Color.white.opacity(selected ? 0.16 : 0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
          )
        }
        .buttonStyle(.plain)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
  }

  /// 4K/2K only when the stream/URL actually offers them; lower rungs stay selectable as caps.
  private var availableStreamResolutions: [StreamResolution] {
    var options: [StreamResolution] = [.automatic, .p1080, .p720, .p480, .p360]
    let peak = max(detectedOutputHeight, streamPeakHeight, hintedStreamPeakHeight)
    if peak >= 1400 {
      options.insert(.p1440, at: 1)
    }
    if peak >= 2000 {
      options.insert(.p2160, at: 1)
    }
    return options
  }

  private var hintedStreamPeakHeight: CGFloat {
    let active = activeRequest ?? request
    let blob = "\(active.formatHint ?? "") \(active.url.absoluteString)".lowercased()
    if blob.contains("2160") || blob.contains("4k") || blob.contains("uhd") {
      return 2160
    }
    if blob.contains("1440") || blob.contains("2k") {
      return 1440
    }
    return 0
  }

  private func clampResolutionSelection() {
    let available = availableStreamResolutions
    guard !available.contains(streamResolution) else { return }
    streamResolution = .automatic
    applyPreferredPeakBitRate()
  }

  private var episodeDrawerPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("选集")
        .font(.headline)
        .foregroundStyle(.white)
        .padding(.top, 20)
      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(currentLineEpisodes) { ep in
            let selected = (activeEpisode ?? episode)?.value == ep.value
            Button {
              closePlayerDrawers()
              Task { await switchToEpisode(ep, auto: false) }
            } label: {
              HStack {
                Text(ep.name)
                  .font(.subheadline.weight(selected ? .semibold : .regular))
                  .lineLimit(2)
                Spacer(minLength: 4)
                if selected {
                  Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                }
              }
              .foregroundStyle(selected ? Color.orange : Color.white)
              .padding(.vertical, 10)
              .padding(.horizontal, 12)
              .background(
                Color.white.opacity(selected ? 0.16 : 0.06),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
              )
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.bottom, 16)
  }

  private var menuButton: some View {
    Menu {
      Button {
        showingDanmakuSettings = true
      } label: {
        Label("弹幕设置", systemImage: "captions.bubble")
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

      Button {
        openPlayerDrawer(.rate)
      } label: {
        Label("倍速 \(playbackRate.formatted())×", systemImage: "gauge")
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

      if skipMark?.introEnd != nil {
        Button("清除片头", role: .destructive) {
          model.clearSkipMarkPart(
            sourceKey: sourceKey,
            vodId: item.vodId,
            flag: activeFlag ?? flag,
            intro: true
          )
          didAutoSkipIntro = false
          showToast("已清除片头")
        }
      }
      if skipMark?.outroStart != nil {
        Button("清除片尾", role: .destructive) {
          model.clearSkipMarkPart(
            sourceKey: sourceKey,
            vodId: item.vodId,
            flag: activeFlag ?? flag,
            outro: true
          )
          showToast("已清除片尾")
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

  @ViewBuilder
  private var progressBar: some View {
    if chrome == .inline {
      HStack(alignment: .center, spacing: 8) {
        // 半屏不显示下一集 — 全屏才有。
        Text(format(currentTime))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.white)
          .frame(width: 44, alignment: .leading)
        CompactSeekBar(
          value: seekBinding,
          range: PlaybackTimeline.progressRange(duration: duration),
          tint: .white,
          enabled: duration > 0 && !isAwaitingPlayback,
          onEditingChanged: handleSeekEditing
        )
        .frame(height: 28)
        Text(duration > 0 ? format(duration) : "--:--")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.white)
          .frame(width: 44, alignment: .trailing)
        if onExpand != nil {
          Button {
            onExpand?()
          } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
              .font(.body.weight(.semibold))
              .frame(width: 28, height: 28)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.white)
          .accessibilityLabel("全屏")
        }
      }
    } else {
      // Time above the seek bar; leading/trailing keys vertically center on the bar.
      HStack(alignment: .seekBarCenter, spacing: 10) {
        immersiveLeadingControls
          .alignmentGuide(.seekBarCenter) { $0[VerticalAlignment.center] }
        VStack(alignment: .leading, spacing: 2) {
          Text(
            "\(format(currentTime)) / \(duration > 0 ? format(duration) : "--:--")"
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.white.opacity(0.9))
          CompactSeekBar(
            value: seekBinding,
            range: PlaybackTimeline.progressRange(duration: duration),
            tint: .orange,
            enabled: duration > 0 && !isAwaitingPlayback,
            onEditingChanged: handleSeekEditing
          )
          .frame(height: 28)
          .alignmentGuide(.seekBarCenter) { $0[VerticalAlignment.center] }
        }
        immersiveTrailingControls
          .alignmentGuide(.seekBarCenter) { $0[VerticalAlignment.center] }
      }
    }
  }

  private var seekBinding: Binding<Double> {
    Binding(
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
    )
  }

  private func handleSeekEditing(_ editing: Bool) {
    isScrubbing = editing
    if editing {
      seekHandoff = true
      // Manual scrub cancels「已看完 / 自动下一集」so mid-roll drag never looks finished.
      clearFinishedEpisodeChrome()
      cancelNextEpisodeCountdown()
    }
    if !editing, let scrubPreview {
      let target = scrubPreview
      stickyTime = target
      lastReportedTime = target
      seekHandoff = true
      clearFinishedEpisodeChrome()
      // Tell DetailView immediately so silent 换站 won't resume from 0 / thrash.
      pinLiveStartPosition(target)
      Task {
        await playbackEngine.seek(to: target)
        self.scrubPreview = nil
        await waitForRenderableFrame(near: target)
        seekHandoff = false
        // Scrub must never leave 切集 black cover up.
        mediaTransitionInFlight = false
        silentHandoff = false
        freezeFrame = nil
        // Re-pin after seek settles (clock may have glitched to 0 mid-buffer).
        pinLiveStartPosition(max(target, stickyTime, lastReportedTime))
      }
    } else if !editing {
      seekHandoff = false
    }
    scheduleHideControls()
  }

  /// User scrub / ±10 — drop false「本集已看完」and stuck transition chrome.
  private func clearFinishedEpisodeChrome() {
    pauseAfterNearEndLanding = false
    if didHandleEnded {
      didHandleEnded = false
      ignoreEndedUntil = Date().addingTimeInterval(2)
    }
  }

  /// Keep activeRequest in sync with the live clock so failover won't resume 片尾.
  private func pinLiveStartPosition(_ position: Double) {
    let pinned = max(0, position)
    if var current = activeRequest {
      current.startPosition = pinned
      activeRequest = current
    }
    onPlaybackTimeChange?(pinned)
  }

  /// 全屏进度条左侧：下一集 / 弹幕（播放在画面中央；与顶栏 ✕ 同宽对齐对齐）
  private var immersiveLeadingControls: some View {
    HStack(spacing: 4) {
      if showsNextEpisodeControl {
        Button {
          Task { await playNextEpisode(auto: false) }
        } label: {
          Image(systemName: "forward.end.fill")
            .font(.body.weight(.semibold))
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .disabled(isResolvingNext || isAwaitingPlayback)
        .accessibilityLabel("下一集")
      }

      Button {
        danmakuEnabled.toggle()
        scheduleHideControls()
      } label: {
        Image(systemName: danmakuEnabled ? "captions.bubble.fill" : "captions.bubble")
          .font(.body.weight(.semibold))
          .frame(width: 36, height: 36)
          .opacity(danmakuEnabled ? 1 : 0.45)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(danmakuEnabled ? "关闭弹幕" : "打开弹幕")
    }
    .foregroundStyle(.white)
  }

  /// 全屏进度条右侧：倍速 / 清晰度 / 选集（间距收紧）
  private var immersiveTrailingControls: some View {
    HStack(spacing: 8) {
      Button {
        openPlayerDrawer(.rate)
      } label: {
        Text(playbackRateLabel)
          .font(.subheadline.weight(.semibold))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("倍速")

      Button {
        openPlayerDrawer(.resolution)
      } label: {
        Text(resolutionButtonTitle)
          .font(.subheadline.weight(.semibold))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("清晰度")

      if !currentLineEpisodes.isEmpty {
        Button {
          openPlayerDrawer(.episodes)
        } label: {
          Text("选集")
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
      }
    }
    .foregroundStyle(.white)
  }

  private var playbackRateLabel: String {
    abs(playbackRate - 1) < 0.01 ? "倍速" : "\(playbackRate.formatted())×"
  }

  /// Overlay chip: compact「自动」; manual shows 4K/2K/1080P…
  private var resolutionButtonTitle: String {
    streamResolution == .automatic ? "自动" : streamResolution.title
  }

  /// 自动：默认封顶 1080P；仅弱网/卡顿时静默降档（不改菜单文案，避免「一直在变」）。
  private func effectivePeakBitRate() -> Double {
    switch streamResolution {
    case .automatic:
      if autoQualityDegraded {
        return StreamResolution.p480.peakBitRate
      }
      if model.isNetworkConstrained {
        return StreamResolution.p720.peakBitRate
      }
      return StreamResolution.p1080.peakBitRate
    default:
      return streamResolution.peakBitRate
    }
  }

  private func applyPreferredPeakBitRate() {
    playbackEngine.setPreferredPeakBitRate(effectivePeakBitRate())
  }

  /// `height` is the shorter presentation edge (P ladder).
  private static func qualityLabel(forHeight height: CGFloat) -> String? {
    guard height >= 200 else { return nil }
    if height >= 2000 { return "4K" }
    if height >= 1400 { return "2K" }
    if height >= 1000 { return "1080P" }
    if height >= 700 { return "720P" }
    if height >= 480 { return "480P" }
    return "360P"
  }

  private func refreshDetectedQuality() {
    guard engineKind == .avPlayer,
      let size = avEngine.player.currentItem?.presentationSize,
      size.width > 1,
      size.height > 1
    else { return }
    let shortEdge = min(size.width, size.height)
    if abs(shortEdge - detectedOutputHeight) > 4 {
      detectedOutputHeight = shortEdge
    }
    if shortEdge > streamPeakHeight {
      streamPeakHeight = shortEdge
    }
    clampResolutionSelection()
  }

  /// Inspect HLS variants so 4K/2K can appear before the adaptive ladder climbs.
  private func refreshStreamPeakFromAsset() async {
    guard engineKind == .avPlayer,
      let item = avEngine.player.currentItem,
      let asset = item.asset as? AVURLAsset
    else { return }
    refreshDetectedQuality()
    do {
      let variants = try await asset.load(.variants)
      let peak = variants.compactMap { variant -> CGFloat? in
        guard let size = variant.videoAttributes?.presentationSize,
          size.width > 1,
          size.height > 1
        else { return nil }
        return min(size.width, size.height)
      }.max() ?? 0
      if peak > streamPeakHeight {
        streamPeakHeight = peak
        clampResolutionSelection()
      }
    } catch {
      // Single-bitrate / progressive — presentationSize is enough.
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
      // Prefer spinner for recoveries; only show short copy for true hard stops.
      if !Self.isTransientSourceSwitchMessage(message) {
        Text(message)
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
      } else {
        ProgressView()
          .controlSize(.large)
          .tint(.white)
      }
      HStack(spacing: 12) {
        Button("重试") {
          failure = nil
          failingOver = true
          Task { await loadAvailableSource() }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(.orange)
        if !alternateURLs.isEmpty {
          Button("换线路") {
            failure = nil
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
        guard holdSpeedSide == nil else { return }
        // Leave left-edge horizontal drags to swipe-back (real-device Nav/pop).
        if value.startLocation.x < edgeBackWidth,
          abs(value.translation.width) >= abs(value.translation.height)
        {
          return
        }
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
          // Left half → brightness; right half → volume (true-device OK).
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
          let target = scrubPreview
          stickyTime = target
          lastReportedTime = target
          clearFinishedEpisodeChrome()
          pinLiveStartPosition(target)
          seekHandoff = true
          Task {
            await playbackEngine.seek(to: target)
            await waitForRenderableFrame(near: target)
            seekHandoff = false
            mediaTransitionInFlight = false
            silentHandoff = false
            freezeFrame = nil
          }
        }
        dragAxis = nil
        scrubPreview = nil
        if holdSpeedSide == nil {
          gestureHint = nil
        }
        brightnessBar = nil
        volumeBar = nil
        scheduleHideControls()
      }
  }

  private func beginHoldSpeed(rewind: Bool) {
    guard holdSpeedSide == nil else { return }
    guard failure == nil, !isAwaitingPlayback || silentHandoff else { return }
    singleTapTask?.cancel()
    dragAxis = nil
    scrubPreview = nil
    brightnessBar = nil
    volumeBar = nil
    rateBeforeHold = playbackRate
    holdSpeedSide = rewind ? .rewind : .forward
    gestureHint = rewind ? "2× 快退" : "2× 快进"
    showControls = true
    if rewind {
      holdSpeedTask?.cancel()
      holdSpeedTask = Task { @MainActor in
        while !Task.isCancelled, holdSpeedSide == .rewind {
          let here = max(observedTime, stickyTime, lastReportedTime)
          let target = max(0, here - 0.5)
          await playbackEngine.seek(to: target)
          stickyTime = target
          lastReportedTime = target
          try? await Task.sleep(for: .milliseconds(250))
        }
      }
    } else {
      wantsPlaying = true
      playbackEngine.setPlaybackRate(2)
      playbackEngine.play()
      avEngine.player.playImmediately(atRate: 2)
    }
  }

  private func endHoldSpeed() {
    guard holdSpeedSide != nil else { return }
    holdSpeedTask?.cancel()
    holdSpeedTask = nil
    holdSpeedSide = nil
    gestureHint = nil
    playbackEngine.setPlaybackRate(rateBeforeHold)
    if wantsPlaying {
      playbackEngine.play()
      avEngine.player.playImmediately(atRate: max(rateBeforeHold, 0.25))
    }
    scheduleHideControls()
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
    // Frame already on screen — never cover it with stale「切换来源 / 重试」.
    if hasRenderableVideo { return nil }
    // Never surface engine `.failed` while we still auto-recover / 换源.
    if isAwaitingPlayback || failingOver || silentHandoff || stallRecoveryInFlight {
      return nil
    }
    guard let failure, !failure.isEmpty else { return nil }
    // Mid-recovery copy must not become a hard error chrome.
    if Self.isTransientSourceSwitchMessage(failure) { return nil }
    return Self.friendlyPlaybackError(failure)
  }

  private static func isTransientSourceSwitchMessage(_ message: String) -> Bool {
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.contains("正在切换来源")
      || text.contains("首帧过慢")
      || text.contains("播放卡住")
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
  private func handleExhaustedPlayback(_ message: String, silent: Bool = false) -> Bool {
    let text = Self.friendlyPlaybackError(message)
    // Prefer silent 换源 whenever parent can — never park on failure chrome first.
    if onUnplayable?() == true {
      failure = nil
      if silent {
        silentHandoff = true
        failingOver = false
      } else {
        // First-load / black canvas: keep the spinner via failingOver.
        silentHandoff = false
        failingOver = true
      }
      return true
    }
    // No more stations: keep loading spinner — not a sticky error toast over a live frame.
    if hasRenderableVideo {
      failure = nil
      failingOver = false
      silentHandoff = false
      return false
    }
    silentHandoff = false
    failingOver = true
    failure = Self.isTransientSourceSwitchMessage(text)
      ? "暂时无法播放，请重试"
      : text
    return false
  }

  private func clearFailureIfRenderable() {
    guard hasRenderableVideo else { return }
    if failure != nil { failure = nil }
    if failingOver { failingOver = false }
    if silentHandoff { endSilentVisualHandoffIfReady() }
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
    detectedOutputHeight = 0
    streamPeakHeight = hintedStreamPeakHeight
    cloudAdSkips = []
    // Exhaustion silently asks DetailView to 换源; keep spinner (not silentHandoff)
    // so a black first paint doesn't look "failed".
    await playCandidates([request.url] + alternateURLs, silent: false)
  }

  private func playCandidates(
    _ urls: [URL],
    startAt: Double? = nil,
    silent: Bool = false
  ) async {
    if silent || keepLastFrame {
      // softReload already froze; do not refresh (would capture black).
      beginSilentVisualHandoff(refreshFreeze: freezeFrame == nil)
      failingOver = false
    } else {
      failingOver = true
    }
    failure = nil
    var keepAwaiting = false
    defer {
      if !keepAwaiting {
        failingOver = false
        // keepLastFrame: leave freeze up — softReload/onChange clears it when ready.
        if !keepLastFrame {
          silentHandoff = false
          freezeFrame = nil
        }
      }
    }
    var last = "当前线路暂时无法播放，请换来源或重试"
    // Prefer live clock over request.startPosition (stale 片尾 history after scrub).
    let resumeAt = startAt ?? max(stickyTime, lastReportedTime, observedTime)
    for url in urls where !triedURLs.contains(url) {
      triedURLs.append(url)
      let kind = engine(for: url)
      if kind != engineKind {
        // Stop the outgoing engine — otherwise AV+MPV can both keep audio after 换源.
        silenceAllEngines()
        playbackEngine.stop()
        engineKind = kind
      }
      var candidate = request
      candidate.url = url
      if resumeAt > 0.5 {
        candidate.startPosition = resumeAt
      }
      do {
        playbackEngine.applyOptions(playbackEngineOptions)
        try await playbackEngine.load(candidate)
        activeRequest = candidate
        failure = nil
        playbackEngine.setPlaybackRate(playbackRate)
        applyPreferredPeakBitRate()
        wantsPlaying = true
        playbackEngine.play()
        lastProgressWallclock = Date()
        lastProgressMediaTime = resumeAt
        Task { await refreshStreamPeakFromAsset() }
        return
      } catch {
        last = Self.friendlyPlaybackError(error.localizedDescription)
      }
    }
    // Always try parent 换源 on exhaustion; `silent` only controls chrome style.
    keepAwaiting = handleExhaustedPlayback(last, silent: silent)
  }

  private func recover(from message: String) async {
    guard !recoverInFlight, !stallRecoveryInFlight else { return }
    recoverInFlight = true
    defer { recoverInFlight = false }
    failure = nil
    let pending = ([request.url] + alternateURLs).filter { !triedURLs.contains($0) }
    if !pending.isEmpty {
      let resumeAt = max(stickyTime, lastReportedTime, observedTime)
      let hasFrame = stickyTime > 1 || hasRenderableVideo
      await playCandidates(pending, startAt: resumeAt, silent: hasFrame)
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
      // Live clock — not the initial request.startPosition (often stale 片尾).
      candidate.startPosition = max(stickyTime, lastReportedTime, observedTime)
      do {
        playbackEngine.applyOptions(playbackEngineOptions)
        try await playbackEngine.load(candidate)
        activeRequest = candidate
        failure = nil
        playbackEngine.play()
        return
      } catch {
        keepAwaiting = handleExhaustedPlayback(error.localizedDescription, silent: true)
        return
      }
    }
    let hasFrame = stickyTime > 1 || hasRenderableVideo
    _ = handleExhaustedPlayback(message, silent: hasFrame)
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
    let resumeAt = max(stickyTime, lastReportedTime, observedTime)
    Task {
      var lastError: Error?
      for url in urls {
        var candidate = request
        candidate.url = url
        if resumeAt > 0.5 { candidate.startPosition = resumeAt }
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
    silenceAllEngines()
    playbackEngine.stop()
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
    var sources = request.danmaku
    if sources.isEmpty, model.danmakuAutoMatch {
      let custom = URL(string: model.danmakuCustomAPIBase)
      sources = await DanmakuSourceResolver.resolve(
        .init(
          title: item.name,
          episodeLabel: (activeEpisode ?? episode)?.name,
          year: item.year,
          customAPIBase: custom
        )
      )
    }
    guard let source = sources.first else {
      danmakuComments = []
      return
    }
    do {
      var req = URLRequest(url: source.url)
      req.setValue(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        forHTTPHeaderField: "User-Agent"
      )
      if source.url.host?.contains("bilibili") == true {
        req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
      }
      req.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
      let (data, response) = try await URLSession.shared.data(for: req)
      if let http = response as? HTTPURLResponse,
        !(200..<300).contains(http.statusCode)
      {
        danmakuComments = []
        return
      }
      danmakuComments = DanmakuParser.parse(data)
    } catch {
      danmakuComments = []
    }
  }

  private func enrichCloudAdSkipsIfNeeded() async {
    cloudAdSkips = []
    guard model.cloudAdSkipEnabled,
      HlsAdSkipDetector.looksLikeHLS(request.url)
    else { return }
    let detection = await HlsAdSkipDetector.detectResolvingMaster(
      url: request.url,
      headers: request.headers,
      options: .init(adPatterns: model.configuration.ads ?? [])
    )
    cloudAdSkips = detection.skips
  }

  private func seek(by delta: Double) {
    let upper = duration > 0 ? duration : .greatestFiniteMagnitude
    let target = min(max(0, currentTime + delta), upper)
    stickyTime = target
    lastReportedTime = target
    seekHandoff = true
    clearFinishedEpisodeChrome()
    pinLiveStartPosition(target)
    cancelNextEpisodeCountdown()
    Task {
      await playbackEngine.seek(to: target)
      await waitForRenderableFrame(near: target)
      // Always clear — never leave center spinner / black cover stuck.
      seekHandoff = false
      mediaTransitionInFlight = false
      silentHandoff = false
      freezeFrame = nil
    }
    scheduleHideControls()
  }

  private func togglePlayPause() {
    if showingNextEpisode {
      // Toast 期间已暂停：点播放 = 本集从 0 重看；点暂停只取消自动下一集。
      cancelNextEpisodeCountdown()
      showToast("已取消自动下一集")
      if !isPlaying {
        Task { await replayCurrentFromStart() }
      }
      return
    }
    if isPlaying {
      wantsPlaying = false
      playbackEngine.pause()
    } else {
      wantsPlaying = true
      playbackEngine.play()
    }
    // No grey flash mask — center controls already show play/pause in both chromes.
    playPauseGlyph = nil
    showControls = true
    scheduleHideControls()
  }

  /// Double-tap the picture — toggle only, no grey circular flash overlay.
  private func flashPlayPause() {
    guard observedState != .loading, !isResolvingNext else { return }
    if showingNextEpisode {
      cancelNextEpisodeCountdown()
      showToast("已取消自动下一集")
      if !isPlaying {
        Task { await replayCurrentFromStart() }
      }
      return
    }
    if isPlaying {
      wantsPlaying = false
      playbackEngine.pause()
    } else {
      wantsPlaying = true
      playbackEngine.play()
    }
    playPauseGlyph = nil
    showControls = true
    scheduleHideControls()
  }

  /// 本集已结束时从 0 重播（toast 点播放 / 取消自动下一集后重看）。
  private func replayCurrentFromStart() async {
    didHandleEnded = false
    ignoreEndedUntil = Date().addingTimeInterval(4)
    stickyTime = 0
    lastReportedTime = 0
    lastProgressMediaTime = 0
    lastPersistedHistoryPosition = -1
    seekHandoff = true
    wantsPlaying = true
    await playbackEngine.seek(to: 0)
    playbackEngine.setPlaybackRate(playbackRate)
    playbackEngine.play()
    await waitForRenderableFrame(near: 0)
    seekHandoff = false
    // 写成 0，切走再切回本集也从开头播。
    if let sourceKey,
      let ep = activeEpisode ?? episode
    {
      let durationValue = max(observedDuration, stickyDuration, duration)
      Task {
        await model.saveHistory(
          sourceKey: sourceKey,
          item: item,
          episode: ep,
          position: 0,
          duration: durationValue
        )
      }
    }
    showControls = true
    scheduleHideControls()
  }

  private func playPauseFlash(_ glyph: PlayPauseGlyph) -> some View {
    // Kept for layout compatibility; flash path no longer used.
    Image(systemName: glyph == .pause ? "pause.fill" : "play.fill")
      .font(.system(size: 34, weight: .regular))
      .foregroundStyle(.white)
      .offset(x: glyph == .play ? 2 : 0)
      .accessibilityLabel(glyph == .pause ? "已暂停" : "正在播放")
  }

  private func notePlaybackClock(time: Double, durationValue: Double, active: Bool) {
    guard active else { return }
    // 切集过渡中：忽略旧 item 残留的 51:xx 时钟，避免写回 sticky。
    if mediaTransitionInFlight || silentHandoff {
      updateNowPlaying()
      return
    }
    handleAutoSkip(at: time)
    handleMidrollAdSkip(at: time)
    updateNowPlaying()
    // Layout remount / replaceCurrentItem can briefly report ~0 — don't erase the clock.
    let looksLikeGlitch = stickyTime > 2 && time < 1 && time + 1.5 < stickyTime
    // Black canvas with a moving AV clock: freeze sticky/history until first frame.
    let blackClock = !hasRenderableVideo && !silentHandoff && failure == nil
    if !looksLikeGlitch, !blackClock {
      lastReportedTime = time
      if time > 0 { stickyTime = time }
    }
    if durationValue > 0 { stickyDuration = durationValue }
    if !blackClock, time > lastProgressMediaTime + 0.15 {
      lastProgressMediaTime = time
      lastProgressWallclock = Date()
    }
    if !looksLikeGlitch, !blackClock {
      onPlaybackTimeChange?(time)
    }
    if !blackClock, time > 2, time - lastPersistedHistoryPosition >= 5 {
      persistWatchProgress(force: false)
    }
  }

  /// Writes continue-watching progress. `force` bypasses the 5s throttle.
  private func persistWatchProgress(force: Bool) {
    guard !model.incognitoModeEnabled, !incognitoThisSession, let sourceKey else { return }
    // Keep raw progress (incl. near-end) so auto-next can land there and pause.
    let position = max(observedTime, stickyTime, lastReportedTime)
    let durationValue = max(observedDuration, stickyDuration, duration)
    guard position > 1 else { return }
    if !force, abs(position - lastPersistedHistoryPosition) < 4 { return }
    lastPersistedHistoryPosition = position
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
        position: position,
        duration: durationValue
      )
    }
  }

  private func scheduleResumeAfterChromeChange() {
    guard failure == nil else { return }
    chromeResumeGeneration += 1
    let generation = chromeResumeGeneration
    // Freeze the resume target once — never chase a glitchy observedTime backward.
    let resumeAt = max(stickyTime, lastReportedTime, observedTime)
    stickyTime = max(stickyTime, resumeAt)
    Task { @MainActor in
      await resumeAfterChromeChange(generation: generation, resumeAt: resumeAt)
    }
  }

  /// Half ↔ full screen: keep position, play/pause intent, and rate after layout settles.
  private func resumeAfterChromeChange(generation: Int, resumeAt: Double) async {
    configureAudioSession()
    // Rotation / layout can pause AVPlayer repeatedly for >2s on Simulator.
    for delayMs in [0, 50, 150, 300, 500, 800, 1200, 1800, 2500, 3500] as [UInt64] {
      if delayMs > 0 {
        try? await Task.sleep(for: .milliseconds(delayMs))
      }
      guard generation == chromeResumeGeneration, failure == nil else {
        return
      }
      let here = observedTime
      // Only correct a clear rewind/stall; skip tiny gaps (avoids “往前推几秒”).
      if resumeAt > 1.5, here + 2.5 < resumeAt {
        await playbackEngine.seek(to: resumeAt)
        stickyTime = max(stickyTime, resumeAt)
      }
      playbackEngine.setPlaybackRate(playbackRate)
      if wantsPlaying {
        playbackEngine.play()
        avEngine.player.playImmediately(atRate: max(playbackRate, 0.25))
      } else {
        // Keep paused across half↔full — layout must not auto-start playback.
        playbackEngine.pause()
      }
    }
    scheduleHideControls()
  }

  /// Playback clock frozen while "playing" — try alternate URLs, then next 来源.
  private func recoverFromStall() async {
    guard !stallRecoveryInFlight, !failingOver, !silentHandoff else { return }
    // Cold start / never had a frame: first-frame watchdog owns recovery — avoid
    // thrashing 来源 every few seconds (间歇黑屏).
    if !keepLastFrame, !hasRenderableVideo, freezeFrame == nil {
      lastProgressWallclock = Date()
      return
    }
    stallRecoveryInFlight = true
    defer { stallRecoveryInFlight = false }
    // Never max with request.startPosition — scrub to mid then stall would jump to 片尾.
    let position = max(observedTime, stickyTime, lastReportedTime)
    stickyTime = position
    // Avoid immediate re-trigger while recovery is in flight / loading.
    lastProgressWallclock = Date()
    if streamResolution == .automatic, !autoQualityDegraded {
      autoQualityDegraded = true
      applyPreferredPeakBitRate()
    }
    let pending = ([request.url] + alternateURLs).filter { !triedURLs.contains($0) }
    if !pending.isEmpty {
      await playCandidates(pending, startAt: position, silent: true)
      return
    }
    _ = handleExhaustedPlayback("播放卡住，正在切换来源", silent: true)
  }

  // Slow CMS opens often need >4.5s; hopping sooner caused black flashes every few seconds.
  private static let firstFrameTimeoutSeconds: TimeInterval = 7.5
  private static let maxFirstFrameFailovers = 3

  /// No first picture after timeout → try mirrors, then silent 换源 (API ping ≠ 开播).
  private func watchSlowFirstFrame() async {
    // Wall clock includes load()+buffer — only pause for 切集/scrub, not for failingOver.
    var anchor = Date()
    while !Task.isCancelled {
      if hasRenderableVideo { return }
      if !wantsPlaying || failure != nil { return }
      if firstFrameFailoverCount >= Self.maxFirstFrameFailovers { return }
      if isResolvingNext || seekHandoff {
        try? await Task.sleep(for: .milliseconds(250))
        anchor = Date()
        continue
      }
      if Date().timeIntervalSince(anchor) >= Self.firstFrameTimeoutSeconds {
        // load / stall recover still running — wait, do not burn the watch.
        if failingOver || stallRecoveryInFlight || recoverInFlight {
          try? await Task.sleep(for: .milliseconds(250))
          continue
        }
        await recoverFromSlowFirstFrame()
        return
      }
      try? await Task.sleep(for: .milliseconds(200))
    }
  }

  private func recoverFromSlowFirstFrame() async {
    guard !hasRenderableVideo, wantsPlaying else { return }
    guard !stallRecoveryInFlight, !recoverInFlight, !failingOver else { return }
    guard firstFrameFailoverCount < Self.maxFirstFrameFailovers else { return }
    stallRecoveryInFlight = true
    defer { stallRecoveryInFlight = false }
    lastProgressWallclock = Date()
    let position = max(0, stickyTime, lastReportedTime, observedTime)
    let pending = ([activeRequest?.url ?? request.url] + alternateURLs)
      .filter { !triedURLs.contains($0) }
    if !pending.isEmpty {
      let silent = keepLastFrame || silentHandoff
      await playCandidates(pending, startAt: position, silent: silent)
      if hasRenderableVideo { return }
    }
    firstFrameFailoverCount += 1
    let silent = keepLastFrame || hasRenderableVideo
    _ = handleExhaustedPlayback("首帧过慢，正在切换来源", silent: silent)
  }

  /// Reload a new URL without remounting the player chrome.
  private func softReload(_ next: PlaybackRequest) async {
    if activeRequest?.url == next.url {
      // Same media: seek only for intentional 切集; never for stale history bumps.
      if mediaTransitionInFlight {
        let target = max(0, next.startPosition)
        stickyTime = target
        lastReportedTime = target
        await playbackEngine.seek(to: target)
        mediaTransitionInFlight = false
        silentHandoff = false
        freezeFrame = nil
      }
      isResolvingNext = false
      activeRequest = next
      if wantsPlaying { playbackEngine.play() }
      return
    }
    // Same episode + new URL ⇒ 换源. Detect before tearing down.
    let previousName = activeEpisode?.name ?? episode?.name
    let incomingName = episode?.name
    let sameEpisode =
      previousName != nil
      && previousName == incomingName
    let isSourceHandoff = sameEpisode && activeRequest?.url != next.url
    // Freeze before teardown. Source handoff may already have a pulse freeze — keep it.
    beginSilentVisualHandoff(refreshFreeze: freezeFrame == nil)
    let hasPicture = freezeFrame != nil || hasRenderableVideo
    mediaTransitionInFlight = true
    softReloadGeneration += 1
    let generation = softReloadGeneration
    // Flush the episode we are leaving — skip if switchToEpisode already did
    // (sticky may already be the incoming resume).
    if skipNextLeavePersist {
      skipNextLeavePersist = false
    } else {
      persistWatchProgress(force: true)
    }
    var resumeAt = max(0, next.startPosition)
    if isSourceHandoff {
      // 换源: stay where the user is now — never jump to stale 片尾 startPosition.
      resumeAt = max(stickyTime, lastReportedTime, observedTime, next.startPosition)
      if resumeAt < 1 { resumeAt = max(0, next.startPosition) }
    } else {
      // New episode: honor request start，never sticky clock from ep3尾.
      resumeAt = max(0, next.startPosition)
    }
    lastPersistedHistoryPosition = -1
    if !isSourceHandoff {
      stickyDuration = 0
    }
    // Block `.ended` through the whole 切集; then grace period so ep4 doesn't
    // instantly look "finished" from ep3's leftover clock → jump to ep5.
    didHandleEnded = true
    if !sameEpisode {
      ignoreEndedUntil = Date().addingTimeInterval(6)
    }
    stickyTime = resumeAt
    lastReportedTime = resumeAt
    lastProgressMediaTime = resumeAt
    scrubPreview = nil
    triedURLs = []
    retriedWithAV = false
    failure = nil
    didAutoSkipIntro = false
    skippedAdSegmentKeys = []
    // New episode gets a fresh first-frame budget; 换源 keeps the hop cap.
    if !sameEpisode {
      firstFrameFailoverCount = 0
    }
    // Reset quality gates so 换源 doesn't inherit the previous station's 4K/2K.
    detectedOutputHeight = 0
    streamPeakHeight = 0
    cloudAdSkips = []
    streamResolution = .automatic
    autoQualityDegraded = false
    cancelNextEpisodeCountdown()
    activeEpisode = episode
    activeFlag = flag
    activeLineEpisodes = lineEpisodes.isEmpty
      ? (playbackLines.first(where: { $0.name == flag })?.episodes ?? [])
      : lineEpisodes
    await playCandidates(
      [next.url] + alternateURLs,
      startAt: resumeAt,
      silent: hasPicture || isSourceHandoff || resumeAt > 1
    )
    guard generation == softReloadGeneration else { return }
    // Unlock 切集 immediately so rapid 1→130 taps are not blocked ~10s.
    isResolvingNext = false
    await waitForRenderableFrame(near: resumeAt > 1 ? resumeAt : nil)
    endSilentVisualHandoffIfReady()
    // 换源 with progress: keep freeze/silent until a real frame — don't force black+spinner.
    if hasRenderableVideo || !isSourceHandoff {
      if mediaTransitionInFlight || silentHandoff || freezeFrame != nil {
        mediaTransitionInFlight = false
        silentHandoff = false
        freezeFrame = nil
      }
    } else {
      mediaTransitionInFlight = false
    }
    // Only auto-next sets this flag — never infer「已看完」from resumeAt on scrub/换源/切集.
    let landNearEnd = pauseAfterNearEndLanding
    pauseAfterNearEndLanding = false
    if landNearEnd, !isSourceHandoff {
      // 自动下一集且该集历史已在片尾：停在对应进度，暂停，不再连跳。
      wantsPlaying = false
      playbackEngine.pause()
      didHandleEnded = true
      ignoreEndedUntil = Date().addingTimeInterval(60)
      showToast("本集已看完")
    } else {
      didHandleEnded = false
    }
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
    // 片头片尾：仅受「片头片尾」偏好控制，与智能去广无关。
    guard model.adSkipPreference != .off else { return }
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
      duration > 5,
      // Ignore stale/wrong marks that fire during the first seconds of a load.
      outro > duration * 0.5,
      time >= outro,
      time > 5,
      nextEpisode != nil,
      !didHandleEnded,
      !failingOver,
      !silentHandoff
    {
      didHandleEnded = true
      beginNextEpisodeCountdown()
    }
  }

  /// 智能去广：片源/云端返回的插播广告轴，落入区间则跳到段末。
  private func handleMidrollAdSkip(at time: Double) {
    guard model.cloudAdSkipEnabled else { return }
    let segments = (activeRequest ?? request).skips + cloudAdSkips
    guard !segments.isEmpty else { return }
    for segment in segments {
      guard Self.isMidrollAdSegment(segment) else { continue }
      let start = segment.start
      let end = segment.end ?? (start + 1)
      guard end > start, time + 0.15 >= start, time + 0.05 < end else { continue }
      let key = String(format: "%.2f-%.2f", start, end)
      guard !skippedAdSegmentKeys.contains(key) else { continue }
      skippedAdSegmentKeys.insert(key)
      Task { await playbackEngine.seek(to: end) }
      showToast("已跳过广告")
      return
    }
  }

  private static func isMidrollAdSegment(_ segment: SkipSegment) -> Bool {
    let raw = (segment.type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if raw.isEmpty { return true }
    if raw.contains("intro") || raw.contains("outro") || raw.contains("片头") || raw.contains("片尾") {
      return false
    }
    return raw.contains("ad")
      || raw.contains("ads")
      || raw.contains("广告")
      || raw == "skip"
      || raw == "commercial"
  }

  private func handlePlaybackEnded(_ state: PlaybackState) {
    guard state == .ended, !didHandleEnded else { return }
    // AV/MPV often emit `.ended` while a URL is still loading, failing over, or
    // being replaced — that is not “本集已结束”.
    guard !failingOver, !stallRecoveryInFlight, !isResolvingNext else { return }
    guard !mediaTransitionInFlight, !showingNextEpisode, !silentHandoff else { return }
    guard Date() >= ignoreEndedUntil else { return }
    guard duration > 5 else { return }
    let clock = max(stickyTime, currentTime, observedTime)
    // Require near the real end (or a long enough watch) so a 00:00 load end is ignored.
    let nearEnd = clock >= duration - 4 || clock >= duration * 0.92
    guard nearEnd, clock > 5 else { return }

    didHandleEnded = true
    beginNextEpisodeCountdown()
  }

  /// Toast 倒计时自动下一集。无下一集 → 仅提示。点播放可从 0 重看本集。
  private func beginNextEpisodeCountdown() {
    cancelNextEpisodeCountdown()
    if model.adSkipPreference == .aggressive {
      didHandleEnded = true
      Task { await playNextEpisode(auto: true) }
      return
    }
    // 本集已结束：进度落盘为 0，之后切回本集从开头播。
    persistWatchProgress(force: true)
    guard nextEpisode != nil else {
      showToast("本剧已播完")
      return
    }
    // 片尾 / 自定义片尾点：暂停后显示倒计时。
    wantsPlaying = false
    playbackEngine.pause()
    showingNextEpisode = true
    nextEpisodeCountdown = 5
    nextEpisodeCountdownTask = Task {
      for remaining in stride(from: 5, through: 1, by: -1) {
        guard !Task.isCancelled else { return }
        await MainActor.run {
          withAnimation(.easeInOut(duration: 0.15)) {
            nextEpisodeCountdown = remaining
          }
        }
        try? await Task.sleep(for: .seconds(1))
      }
      guard !Task.isCancelled else { return }
      await MainActor.run { showingNextEpisode = false }
      await playNextEpisode(auto: true)
    }
  }

  private func cancelNextEpisodeCountdown() {
    nextEpisodeCountdownTask?.cancel()
    nextEpisodeCountdownTask = nil
    showingNextEpisode = false
  }

  private func playPreviousEpisode() async {
    guard let previous = previousEpisode else {
      showToast("已经是第一集")
      return
    }
    await switchToEpisode(previous, auto: false)
  }

  private func playNextEpisode(auto: Bool) async {
    guard let next = nextEpisode else {
      showToast("已经是最后一集")
      return
    }
    await switchToEpisode(next, auto: auto)
  }

  /// 上一集 / 下一集共用：先落盘当前集，再按目标集历史进度续播（不再误从 0 起）。
  private func switchToEpisode(_ target: Episode, auto: Bool) async {
    // Allow superseding an in-flight 切集 (old guard dropped 130 while 1 was resolving).
    isResolvingNext = true
    let line = activeFlag ?? flag ?? ""
    // Flush CURRENT episode while sticky still belongs to it — playNext used to
    // overwrite sticky with the next ep's resume first, wiping ~40s on 上一集.
    persistWatchProgress(force: true)
    skipNextLeavePersist = true

    let history = model.historyEntry(for: item, episode: target)
    let resumeRaw: Double = {
      if auto {
        return max(0, history?.position ?? 0)
      }
      // Manual 上/下一集：已看完 → 0；否则用原始历史（如 40s）。
      return AppModel.resumeStartPosition(
        position: history?.position ?? 0,
        duration: history?.duration ?? 0
      )
    }()
    let resumeDur = max(0, history?.duration ?? 0)
    let landNearEnd = auto && AppModel.isNearEnd(
      position: history?.position ?? 0,
      duration: resumeDur
    )
    pauseAfterNearEndLanding = landNearEnd
    stickyTime = resumeRaw
    lastReportedTime = resumeRaw
    lastProgressMediaTime = resumeRaw
    stickyDuration = resumeDur
    mediaTransitionInFlight = true
    beginSilentVisualHandoff(refreshFreeze: true)
    if let onPlayEpisode {
      // Detail softReload owns the rest; clear gate if handoff stalls.
      onPlayEpisode(target, line, resumeRaw)
      Task {
        try? await Task.sleep(for: .seconds(8))
        if isResolvingNext { isResolvingNext = false }
      }
      return
    }
    defer { isResolvingNext = false }
    await playEpisode(target, flag: line, autoToast: auto, startAt: resumeRaw)
  }

  private func playEpisode(
    _ episode: Episode,
    flag: String,
    autoToast: Bool = false,
    startAt: Double? = nil
  ) async {
    cancelNextEpisodeCountdown()
    isResolvingNext = true
    beginSilentVisualHandoff()
    defer {
      isResolvingNext = false
      endSilentVisualHandoffIfReady()
    }
    do {
      let nextRequest = try await model.resolvePlayback(
        item: item,
        episode: episode,
        flag: flag,
        startPositionOverride: startAt
      )
      activeEpisode = episode
      activeFlag = flag
      activeRequest = nextRequest
      didAutoSkipIntro = false
      didHandleEnded = false
      skippedAdSegmentKeys = []
      let resumeAt = max(0, startAt ?? nextRequest.startPosition)
      stickyTime = resumeAt
      lastReportedTime = resumeAt
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
      silentHandoff = false
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
    // Same episode on a new 线路 — keep the live clock, don't restart at 0.
    let here = max(stickyTime, lastReportedTime, observedTime)
    await playEpisode(target, flag: line.name, startAt: here > 1 ? here : nil)
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
    // Same rules as center play/pause (toast → cancel + replay from 0).
    let playTarget = center.playCommand.addTarget { _ in
      Task { @MainActor in self.handleRemotePlayPause(forcePlay: true) }
      return .success
    }
    let pauseTarget = center.pauseCommand.addTarget { _ in
      Task { @MainActor in self.handleRemotePlayPause(forcePause: true) }
      return .success
    }
    let toggleTarget = center.togglePlayPauseCommand.addTarget { _ in
      Task { @MainActor in self.handleRemotePlayPause() }
      return .success
    }
    remoteCommandTargets = [
      (center.playCommand, playTarget),
      (center.pauseCommand, pauseTarget),
      (center.togglePlayPauseCommand, toggleTarget),
    ]
  }

  /// Lock screen / headset — mirror in-player play/pause incl. toast countdown.
  private func handleRemotePlayPause(forcePlay: Bool = false, forcePause: Bool = false) {
    if showingNextEpisode {
      cancelNextEpisodeCountdown()
      showToast("已取消自动下一集")
      if forcePause { return }
      // Play / toggle while ended → replay from 0 (same as center button).
      if forcePlay || !isPlaying {
        Task { await replayCurrentFromStart() }
      }
      return
    }
    if forcePause || (!forcePlay && isPlaying) {
      wantsPlaying = false
      playbackEngine.pause()
    } else {
      wantsPlaying = true
      playbackEngine.play()
    }
    updateNowPlaying()
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
    // Keep chrome while a side drawer is open.
    guard !isPlayerDrawerOpen else {
      showControls = true
      return
    }
    hideTask = Task {
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, !isScrubbing, !isPlayerDrawerOpen else { return }
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

/// Holds the live player view so we can snapshot the last frame before 切集/seek.
@MainActor
final class PlayerSurfaceBox {
  weak var view: UIView?

  func snapshot() -> UIImage? {
    guard let view, view.bounds.width > 1, view.bounds.height > 1 else { return nil }
    // Prefer the real video layer if present — drawHierarchy on AVPVC can be empty.
    let image: UIImage?
    if let playerLayer = Self.findPlayerLayer(in: view) {
      let size = playerLayer.bounds.size
      guard size.width > 1, size.height > 1 else { return nil }
      let format = UIGraphicsImageRendererFormat()
      format.scale = view.window?.screen.scale ?? UIScreen.main.scale
      format.opaque = true
      let renderer = UIGraphicsImageRenderer(size: size, format: format)
      image = renderer.image { ctx in
        playerLayer.render(in: ctx.cgContext)
      }
    } else {
      let format = UIGraphicsImageRendererFormat()
      format.scale = view.window?.screen.scale ?? UIScreen.main.scale
      format.opaque = true
      let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
      image = renderer.image { _ in
        view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
      }
    }
    // AVPlayerLayer.render often yields a solid black bitmap — treat as no frame.
    guard let image, !Self.isMostlyBlack(image) else { return nil }
    return image
  }

  private static func isMostlyBlack(_ image: UIImage) -> Bool {
    guard let cg = image.cgImage else { return true }
    let w = min(cg.width, 32)
    let h = min(cg.height, 32)
    guard w > 0, h > 0 else { return true }
    var data = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(
      data: &data,
      width: w,
      height: h,
      bitsPerComponent: 8,
      bytesPerRow: w * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return true }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var lit = 0
    let step = 4
    for i in stride(from: 0, to: data.count, by: step) {
      if Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2]) > 36 { lit += 1 }
    }
    return lit < max(4, (w * h) / 40)
  }

  private static func findPlayerLayer(in root: UIView) -> AVPlayerLayer? {
    if let layer = root.layer as? AVPlayerLayer { return layer }
    var stack: [CALayer] = [root.layer]
    while let layer = stack.popLast() {
      if let playerLayer = layer as? AVPlayerLayer { return playerLayer }
      if let subs = layer.sublayers { stack.append(contentsOf: subs) }
    }
    return nil
  }
}

private struct SystemPlayerView: UIViewControllerRepresentable {
  let player: AVPlayer
  var surface: PlayerSurfaceBox?
  var showsControls = false
  var fillsFrame = false

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.showsPlaybackControls = showsControls
    controller.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
    controller.view.backgroundColor = .black
    // Keep PiP available from the system, but do not auto-enter when the
    // inline player expands to our own immersive chrome (that pauses resume).
    controller.allowsPictureInPicturePlayback = true
    controller.canStartPictureInPictureAutomaticallyFromInline = false
    // iOS 17+: Live Text / 二维码识别 button in the corner when paused.
    controller.allowsVideoFrameAnalysis = false
    surface?.view = controller.contentOverlayView?.superview ?? controller.view
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    if controller.player !== player {
      controller.player = player
    }
    controller.showsPlaybackControls = showsControls
    controller.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
    controller.view.backgroundColor = .black
    controller.allowsVideoFrameAnalysis = false
    surface?.view = controller.view
  }
}

/// UIKit long-press that does not cancel SwiftUI taps (unlike LongPressGesture + Drag).
private struct HoldSpeedProbe: UIViewRepresentable {
  var onBegan: (CGPoint) -> Void
  var onEnded: () -> Void

  func makeUIView(context: Context) -> HoldSpeedProbeView {
    let view = HoldSpeedProbeView()
    view.onBegan = onBegan
    view.onEnded = onEnded
    return view
  }

  func updateUIView(_ uiView: HoldSpeedProbeView, context: Context) {
    uiView.onBegan = onBegan
    uiView.onEnded = onEnded
  }
}

private final class HoldSpeedProbeView: UIView {
  var onBegan: ((CGPoint) -> Void)?
  var onEnded: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = true
    let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
    press.minimumPressDuration = 0.45
    press.allowableMovement = 24
    press.cancelsTouchesInView = false
    press.delaysTouchesBegan = false
    press.delaysTouchesEnded = false
    addGestureRecognizer(press)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
    switch gesture.state {
    case .began:
      onBegan?(gesture.location(in: self))
    case .ended, .cancelled, .failed:
      onEnded?()
    default:
      break
    }
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

  func makeUIView(context: Context) -> UIView {
    let container = UIView(frame: .zero)
    container.isUserInteractionEnabled = false
    container.clipsToBounds = true
    container.isHidden = true

    let volume = MPVolumeView(frame: CGRect(x: -4000, y: -4000, width: 1, height: 1))
    volume.alpha = 0.001
    volume.isUserInteractionEnabled = false
    volume.showsVolumeSlider = true
    volume.setValue(false, forKey: "showsRouteButton")
    volume.isHidden = true
    container.addSubview(volume)

    Self.stripRouteChrome(from: volume)
    DispatchQueue.main.async {
      Self.stripRouteChrome(from: volume)
      if let slider = volume.subviews.compactMap({ $0 as? UISlider }).first {
        proxy.slider = slider
        proxy.volume = slider.value
      }
    }
    return container
  }

  func updateUIView(_ uiView: UIView, context: Context) {
    for case let volume as MPVolumeView in uiView.subviews {
      Self.stripRouteChrome(from: volume)
    }
  }

  private static func stripRouteChrome(from volume: MPVolumeView) {
    volume.setValue(false, forKey: "showsRouteButton")
    for subview in volume.subviews where !(subview is UISlider) {
      subview.isHidden = true
      subview.alpha = 0
      subview.removeFromSuperview()
    }
  }
}
