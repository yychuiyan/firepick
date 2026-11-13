import AVKit
import FirepickCore
import FirepickPlayback
import SwiftUI

/// Full-screen live player with channel/EPG overlays — the TV tab root.
struct LivePlaybackShell: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase

  @State private var channel: LiveChannel?
  @State private var groupName: String?
  @State private var urlIndex = 0
  @State private var showHUD = true
  @State private var showPicker = false
  @State private var showEPG = false
  @State private var showLines = false
  @State private var pickerQuery = ""
  @State private var pickerGroup: String?
  @State private var zapHint: String?
  @State private var failure: String?
  @State private var avEngine = AVPlayerEngine()
  @State private var mpvEngine = MPVPlayerEngine()
  @State private var engineKind: PlaybackEngineKind = .avPlayer
  @State private var hideTask: Task<Void, Never>?

  private var playbackEngine: any PlaybackEngine {
    engineKind == .mpv ? mpvEngine : avEngine
  }

  private var flatChannels: [LiveChannel] {
    if pickerGroup == "我的" {
      return model.allLiveChannels().filter { model.isLiveFavorite($0) }
    }
    if let pickerGroup,
      let group = model.liveGroups.first(where: { $0.name == pickerGroup })
    {
      return group.channels
    }
    return model.liveGroups.first(where: { $0.name == groupName })?.channels
      ?? model.liveGroups.first?.channels
      ?? []
  }

  private var filteredChannels: [LiveChannel] {
    let q = pickerQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return flatChannels }
    return flatChannels.filter { $0.name.localizedCaseInsensitiveContains(q) }
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if model.liveGroups.isEmpty {
        emptyState
      } else if let channel {
        playerLayer
        if showHUD {
          hud(for: channel)
            .transition(.opacity)
        }
        if let zapHint {
          Text(zapHint)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.55), in: Capsule())
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
      } else {
        ProgressView()
          .tint(.white)
      }
    }
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
    .sheet(isPresented: $showPicker) {
      channelPicker
        .presentationDetents([.medium, .large])
    }
    .sheet(isPresented: $showEPG) {
      epgSheet
        .presentationDetents([.medium, .large])
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
    .task {
      await bootstrap()
    }
    .onChange(of: model.selectedTab) { _, tab in
      if tab == .live {
        playbackEngine.play()
        scheduleHideHUD()
      } else {
        playbackEngine.pause()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active, model.selectedTab == .live {
        playbackEngine.pause()
      }
    }
    .onDisappear {
      hideTask?.cancel()
      playbackEngine.stop()
    }
    .gesture(
      DragGesture(minimumDistance: 40)
        .onEnded { value in
          if abs(value.translation.height) > abs(value.translation.width) {
            if value.translation.height < 0 {
              zap(delta: 1)
            } else {
              zap(delta: -1)
            }
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
    .foregroundStyle(.white)
  }

  @ViewBuilder
  private var playerLayer: some View {
    if engineKind == .mpv {
      MPVVideoView(engine: mpvEngine)
        .ignoresSafeArea()
    } else {
      LiveSystemPlayerView(player: avEngine.player)
        .ignoresSafeArea()
    }
  }

  private func hud(for channel: LiveChannel) -> some View {
    VStack {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(channel.name)
            .font(.title3.weight(.bold))
          if let number = channel.number {
            Text(number)
              .font(.caption)
              .foregroundStyle(.white.opacity(0.8))
          }
          if let program = model.currentProgram(for: channel) {
            Text(program.title)
              .font(.caption)
              .foregroundStyle(.white.opacity(0.85))
          }
        }
        Spacer()
        Button {
          model.toggleLiveFavorite(channel)
        } label: {
          Image(systemName: model.isLiveFavorite(channel) ? "star.fill" : "star")
            .font(.title3)
            .foregroundStyle(.orange)
            .frame(width: 44, height: 44)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)

      Spacer()

      HStack(spacing: 18) {
        Button { zap(delta: -1) } label: {
          Image(systemName: "chevron.up")
            .font(.title2.weight(.semibold))
        }
        Button {
          if playbackEngine.state == .playing {
            playbackEngine.pause()
          } else {
            playbackEngine.play()
          }
        } label: {
          Image(
            systemName: playbackEngine.state == .playing ? "pause.fill" : "play.fill"
          )
          .font(.title2)
        }
        Button { zap(delta: 1) } label: {
          Image(systemName: "chevron.down")
            .font(.title2.weight(.semibold))
        }
        Spacer()
        Button("选台") {
          pickerGroup = groupName ?? model.liveGroups.first?.name
          showPicker = true
        }
        Button("节目单") { showEPG = true }
        if (channel.urls.count) > 1 {
          Button("线路") { showLines = true }
        }
      }
      .buttonStyle(.plain)
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .background(.ultraThinMaterial.opacity(0.9))
    }
  }

  private var channelPicker: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            Button("我的") { pickerGroup = "我的" }
              .buttonStyle(.bordered)
              .tint(pickerGroup == "我的" ? .orange : .secondary)
            ForEach(model.liveGroups) { group in
              Button(group.name) { pickerGroup = group.name }
                .buttonStyle(.bordered)
                .tint(pickerGroup == group.name ? .orange : .secondary)
            }
          }
          .padding()
        }
        .scrollIndicators(.hidden)

        TextField("搜索频道", text: $pickerQuery)
          .textFieldStyle(.roundedBorder)
          .padding(.horizontal)

        List(filteredChannels) { item in
          Button {
            select(channel: item, groupHint: pickerGroup == "我的" ? nil : pickerGroup)
            showPicker = false
          } label: {
            HStack {
              CachedRemoteImage(url: item.logo.flatMap(URL.init(string:))) {
                Image(systemName: "tv")
                  .foregroundStyle(.secondary)
              }
              .frame(width: 32, height: 32)
              VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                if let program = model.currentProgram(for: item) {
                  Text(program.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }
              Spacer()
              if item.id == channel?.id {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.orange)
              }
              Button {
                model.toggleLiveFavorite(item)
              } label: {
                Image(systemName: model.isLiveFavorite(item) ? "star.fill" : "star")
                  .foregroundStyle(.orange)
              }
              .buttonStyle(.borderless)
            }
          }
        }
        .listStyle(.plain)
      }
      .navigationTitle("选台")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { showPicker = false }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("刷新") {
            Task {
              await model.refreshLiveSources()
              if let group = model.liveGroups.first(where: { $0.name == pickerGroup }) {
                await model.loadEPG(for: group)
              }
            }
          }
        }
      }
      .task {
        if pickerGroup == nil {
          pickerGroup = groupName ?? model.lastLiveGroupName ?? model.liveGroups.first?.name
        }
      }
    }
  }

  private var epgSheet: some View {
    NavigationStack {
      List {
        if let channel {
          let programs = channel.tvgId.flatMap { model.epgPrograms[$0] } ?? []
          if programs.isEmpty {
            ContentUnavailableView(
              "暂无节目单",
              systemImage: "list.bullet.rectangle",
              description: Text(model.epgStatus ?? "下拉或点刷新试试。")
            )
            .listRowBackground(Color.clear)
          } else {
            ForEach(programs) { program in
              VStack(alignment: .leading, spacing: 4) {
                Text(program.title)
                Text(
                  "\(program.start.formatted(date: .omitted, time: .shortened)) – \(program.stop.formatted(date: .omitted, time: .shortened))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              .listRowBackground(
                model.currentProgram(for: channel)?.id == program.id
                  ? Color.orange.opacity(0.12)
                  : nil
              )
            }
          }
        }
      }
      .navigationTitle("节目单")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { showEPG = false }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("刷新") {
            Task {
              if let name = groupName,
                let group = model.liveGroups.first(where: { $0.name == name })
              {
                await model.loadEPG(for: group)
              }
            }
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
    pickerGroup = initial.group.name
    channel = initial.channel
    urlIndex = min(model.lastLiveURLIndex, max(0, initial.channel.urls.count - 1))
    if let preferred = model.playbackPreference.engine {
      engineKind = preferred
    }
    await model.loadEPG(for: initial.group)
    await loadCurrent(autoplay: model.selectedTab == .live)
    scheduleHideHUD()
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
    let channels =
      model.liveGroups.first(where: { $0.name == groupName })?.channels
      ?? model.liveGroups.first?.channels
      ?? []
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

  private func scheduleHideHUD() {
    hideTask?.cancel()
    hideTask = Task {
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      withAnimation { showHUD = false }
    }
  }
}

private struct LiveSystemPlayerView: UIViewControllerRepresentable {
  let player: AVPlayer

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.showsPlaybackControls = false
    controller.allowsPictureInPicturePlayback = true
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    if controller.player !== player {
      controller.player = player
    }
  }
}
