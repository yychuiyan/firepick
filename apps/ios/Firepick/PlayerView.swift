import AVKit
import FirepickCore
import FirepickPlayback
import MediaPlayer
import SwiftUI
import UIKit

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
  @State private var showingCast = false
  @State private var showingEpisodes = false
  @State private var showingLines = false
  @State private var showingDanmakuSettings = false
  @State private var showControls = true
  @State private var hideTask: Task<Void, Never>?
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
    playbackLines: [PlaybackLine] = []
  ) {
    self.request = request
    self.item = item
    self.episode = episode
    self.alternateURLs = alternateURLs
    self.flag = flag
    self.lineEpisodes = lineEpisodes
    self.playbackLines = playbackLines
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

  private var currentTime: Double {
    scrubPreview ?? playbackEngine.currentTime
  }

  private var duration: Double {
    max(playbackEngine.duration, 0)
  }

  var body: some View {
    GeometryReader { geo in
      ZStack {
        Color.black.ignoresSafeArea()
        videoLayer
        DanmakuOverlay(
          comments: danmakuComments,
          currentTime: playbackEngine.currentTime,
          isPlaying: playbackEngine.state == .playing,
          isEnabled: danmakuEnabled,
          opacity: model.danmakuOpacity,
          fontScale: model.danmakuFontScale,
          speed: model.danmakuSpeed
        )
        if !overlayCues.isEmpty {
          SubtitleOverlay(
            cues: overlayCues,
            currentTime: playbackEngine.currentTime,
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
        }
        if playbackEngine.state == .loading || isResolvingNext {
          ProgressView()
            .tint(.white)
            .scaleEffect(1.2)
        }
      }
      .contentShape(Rectangle())
      .gesture(playerDrag(in: geo.size))
      .onTapGesture(count: 2) {
        togglePlayPause()
      }
      .onTapGesture(count: 1) {
        withAnimation(.easeInOut(duration: 0.18)) {
          showControls.toggle()
        }
        if showControls { scheduleHideControls() }
      }
    }
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
    .preferredColorScheme(.dark)
    .sheet(isPresented: $showingCast) {
      DLNACastView(request: activeRequest ?? request, title: item.name)
    }
    .sheet(isPresented: $showingEpisodes) {
      episodePickerSheet
        .presentationDetents([.medium, .large])
    }
    .sheet(isPresented: $showingLines) {
      linePickerSheet
        .presentationDetents([.medium])
    }
    .sheet(isPresented: $showingDanmakuSettings) {
      NavigationStack {
        DanmakuSettingsView()
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
      await loadAvailableSource()
      updateNowPlaying()
      maybeShowResumeToast()
      scheduleHideControls()
    }
    .task(id: request.danmaku.first?.id) {
      await loadDanmaku()
    }
    .onChange(of: playbackEngine.currentTime) { _, time in
      handleAutoSkip(at: time)
      updateNowPlaying()
    }
    .onChange(of: selectedSubtitleIndex) { _, index in
      applySubtitleSelection(index)
    }
    .onChange(of: avEngine.state) { _, state in
      handlePlaybackEnded(state)
    }
    .onChange(of: mpvEngine.state) { _, state in
      handlePlaybackEnded(state)
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
            position: playbackEngine.currentTime,
            duration: playbackEngine.duration
          )
        }
      }
      clearNowPlaying()
      playbackEngine.stop()
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
        .ignoresSafeArea()
    } else {
      SystemPlayerView(player: avEngine.player, showsControls: false)
        .ignoresSafeArea()
    }
  }

  private var controlsOverlay: some View {
    VStack(spacing: 0) {
      HStack {
        Button {
          playbackEngine.stop()
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.body.weight(.semibold))
            .frame(width: 36, height: 36)
            .background(.black.opacity(0.35), in: Circle())
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(item.name)
            .font(.headline)
            .lineLimit(1)
          if let activeEpisode {
            Text(activeEpisode.name)
              .font(.caption)
              .foregroundStyle(.white.opacity(0.8))
          }
        }
        Spacer()
        menuButton
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .padding(.top, 12)

      Spacer()

      skipButtons
        .padding(.horizontal, 16)
        .padding(.bottom, 8)

      progressBar
        .padding(.horizontal, 16)
        .padding(.bottom, 10)

      HStack(spacing: 16) {
        Button { togglePlayPause() } label: {
          Image(
            systemName: playbackEngine.state == .playing ? "pause.fill" : "play.fill"
          )
          .font(.title2)
        }
        Text(
          "\(format(currentTime)) / \(duration > 0 ? format(duration) : "--:--")"
        )
        .font(.caption.monospacedDigit())
        Spacer(minLength: 8)
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
        Text("\(Double(playbackRate).formatted())×")
          .font(.caption.weight(.semibold))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .padding(.bottom, 18)
      .padding(.top, 8)
      .background(.ultraThinMaterial.opacity(0.85))
    }
  }

  private var menuButton: some View {
    Menu {
            Button {
              model.download(
                request: activeRequest ?? request,
                item: item,
                episode: activeEpisode ?? episode
              )
              showToast("已加入下载")
            } label: {
              Label("下载到本机", systemImage: "arrow.down.circle")
            }
            Button {
              playbackEngine.pause()
              dismiss()
              model.selectedTab = .settings
            } label: {
              Label("查看下载", systemImage: "arrow.down.to.line")
            }
      Button { showingCast = true } label: {
        Label("投屏到 DLNA", systemImage: "airplayvideo")
      }

      Button {
        if danmakuComments.isEmpty {
          showToast("暂无弹幕")
        } else {
          danmakuEnabled.toggle()
        }
      } label: {
        Label(
          danmakuEnabled ? "关闭弹幕" : "打开弹幕",
          systemImage: "text.bubble"
        )
      }
      Button("弹幕设置") {
        showingDanmakuSettings = true
      }

      Toggle(isOn: $incognitoThisSession) {
        Label("本次无痕", systemImage: "eye.slash")
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

      Menu("播放引擎") {
        Button("AVPlayer") { Task { await switchEngine(.avPlayer) } }
        if MPVPlaybackSupport.isAvailable {
          Button("MPV") { Task { await switchEngine(.mpv) } }
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

      if model.adSkipPreference != .off {
        Button("标记为片头结束") {
          model.setSkipMark(
            sourceKey: sourceKey,
            vodId: item.vodId,
            flag: activeFlag ?? flag,
            introEnd: playbackEngine.currentTime
          )
          showToast("已标记片头结束 \(format(playbackEngine.currentTime))")
        }
        Button("标记为片尾开始") {
          model.setSkipMark(
            sourceKey: sourceKey,
            vodId: item.vodId,
            flag: activeFlag ?? flag,
            outroStart: playbackEngine.currentTime
          )
          showToast("已标记片尾开始 \(format(playbackEngine.currentTime))")
        }
        if skipMark != nil {
          Button("清除本片标记", role: .destructive) {
            model.clearSkipMark(
              sourceKey: sourceKey,
              vodId: item.vodId,
              flag: activeFlag ?? flag
            )
            didAutoSkipIntro = false
            showToast("已清除本片标记")
          }
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.title3)
        .frame(width: 36, height: 36)
        .background(.black.opacity(0.35), in: Circle())
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

  private var progressBar: some View {
    VStack(spacing: 6) {
      Slider(
        value: Binding(
          get: { currentTime },
          set: { scrubPreview = $0 }
        ),
        in: 0...max(duration, 0.1),
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
      .tint(.orange)
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
    if let failure { return failure }
    switch playbackEngine.state {
    case .failed(let message):
      return message
    default:
      return nil
    }
  }

  private func loadAvailableSource() async {
    var lastError: Error?
    var urls = [request.url]
    urls.append(contentsOf: alternateURLs.filter { !urls.contains($0) })
    for url in urls {
      var candidate = request
      candidate.url = url
      do {
        try await playbackEngine.load(candidate)
        activeRequest = candidate
        failure = nil
        playbackEngine.setPlaybackRate(playbackRate)
        playbackEngine.play()
        return
      } catch {
        lastError = error
      }
    }
    failure = lastError?.localizedDescription ?? "媒体不可播放"
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

  private func togglePlayPause() {
    if playbackEngine.state == .playing {
      playbackEngine.pause()
    } else {
      playbackEngine.play()
    }
    showControls = true
    scheduleHideControls()
  }

  private func maybeShowResumeToast() {
    let start = request.startPosition
    guard start > 2 else { return }
    showToast("已从 \(format(start)) 续播")
  }

  private func handleAutoSkip(at time: Double) {
    if model.adSkipPreference == .aggressive,
      !didAutoSkipIntro,
      let intro = skipMark?.introEnd,
      time + 0.3 < intro,
      time < 1.5
    {
      didAutoSkipIntro = true
      Task { await playbackEngine.seek(to: intro) }
      showToast("已跳过片头")
    }
    if model.adSkipPreference == .aggressive,
      let outro = skipMark?.outroStart,
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

  private func playNextEpisode(auto: Bool) async {
    guard let next = nextEpisode else {
      showToast("已经是最后一集")
      return
    }
    await playEpisode(next, flag: activeFlag ?? flag ?? "", autoToast: auto)
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
    center.playCommand.addTarget { _ in
      Task { @MainActor in
        av.play()
        mpv.play()
      }
      return .success
    }
    center.pauseCommand.addTarget { _ in
      Task { @MainActor in
        av.pause()
        mpv.pause()
      }
      return .success
    }
    center.togglePlayPauseCommand.addTarget { _ in
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
    hideTask = Task {
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled, !isScrubbing else { return }
      withAnimation { showControls = false }
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

private struct SystemPlayerView: UIViewControllerRepresentable {
  let player: AVPlayer
  var showsControls = false

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.showsPlaybackControls = showsControls
    controller.allowsPictureInPicturePlayback = true
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    if controller.player !== player {
      controller.player = player
    }
    controller.showsPlaybackControls = showsControls
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
