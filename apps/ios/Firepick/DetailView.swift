import FirepickCore
import FirepickPlayback
import SwiftUI

struct DetailView: View {
  @Environment(AppModel.self) private var model
  let item: MediaItem
  @State private var playback: PlaybackRequest?
  @State private var playbackEpisode: Episode?
  @State private var playbackFlag: String?
  @State private var resolvingEpisodeID: Episode.ID?
  @State private var playbackError: String?
  @State private var showingSourcePicker = false
  @State private var selectedFlag: String?
  @State private var reverseEpisodes = false
  @State private var expandSynopsis = false
  @State private var showingEpisodeDrawer = false
  @State private var didScrollToHistory = false
  @State private var isPlayerExpanded = false

  private var detail: MediaItem {
    if let loaded = model.detailResult?.list.first, loaded.vodId == item.vodId {
      return loaded
    }
    return item
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
    return model.history.first {
      $0.sourceKey == sourceKey && $0.item.vodId == detail.vodId
    }
  }

  private var isDetailLoading: Bool {
    model.isLoadingDetail
      && model.detailResult?.list.first?.vodId != item.vodId
      && lines.isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      inlinePlayer
      if !isPlayerExpanded {
        detailScroll
      }
    }
    .background(isPlayerExpanded ? Color.black : Color.clear)
    .navigationTitle(detail.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(isPlayerExpanded ? .hidden : .automatic, for: .navigationBar)
    .toolbar(isPlayerExpanded ? .hidden : .automatic, for: .tabBar)
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
    .onAppear {
      model.resumeBrowseItem = nil
    }
    .onDisappear {
      if playback != nil {
        model.resumeBrowseItem = detail
      }
    }
    .task(id: item.vodId) {
      if model.detailResult?.list.first?.vodId != item.vodId {
        model.detailResult = nil
      }
      selectedFlag = model.preferredPlaybackFlag(
        sourceKey: item.sourceKey ?? model.selectedSite?.key,
        vodId: item.vodId
      )
      await model.loadDetail(item)
      if selectedFlag == nil || !lines.contains(where: { $0.name == selectedFlag }) {
        selectedFlag = lines.first?.name
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
      guard let oldFlag, oldFlag != flag, playback != nil else { return }
      let episodes = lines.first(where: { $0.name == flag })?.episodes ?? []
      let currentName = playbackEpisode?.name
      let next = episodes.first(where: { $0.name == currentName }) ?? episodes.first
      guard let next else { return }
      Task { await play(episode: next, flag: flag) }
    }
  }

  @ViewBuilder
  private var inlinePlayer: some View {
    if let playback {
      PlayerView(
        request: playback,
        item: detail,
        episode: playbackEpisode,
        flag: playbackFlag,
        lineEpisodes: lines.first(where: { $0.name == playbackFlag })?.episodes
          ?? activeLine?.episodes
          ?? [],
        playbackLines: lines,
        chrome: isPlayerExpanded ? .immersive : .inline,
        onExpand: { isPlayerExpanded = true },
        onCollapse: { isPlayerExpanded = false }
      )
      .id(playbackEpisode?.value ?? playback.url.absoluteString)
      .aspectRatio(isPlayerExpanded ? nil : 16.0 / 9.0, contentMode: .fit)
      .frame(maxWidth: .infinity, maxHeight: isPlayerExpanded ? .infinity : nil)
      .clipped()
    } else {
      ZStack {
        Color.black
        CachedRemoteImage(url: detail.pic.flatMap(URL.init(string:))) {
          Color.black
        }
        .scaledToFill()
        .opacity(0.45)
        if resolvingEpisodeID != nil || isDetailLoading {
          ProgressView()
            .tint(.white)
        } else if lines.isEmpty && !isDetailLoading {
          Text("没有可播放线路")
            .font(.subheadline)
            .foregroundStyle(.white)
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
        VStack(alignment: .leading, spacing: 18) {
          metadataSection
          synopsisSection
          if isDetailLoading {
            HStack(spacing: 8) {
              ProgressView()
              Text("加载线路中…")
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
          } else if lines.isEmpty {
            ContentUnavailableView(
              "没有可播放线路",
              systemImage: "play.slash",
              description: Text(
                model.errorMessage ?? "详情接口没有返回标准选集数据。"
              )
            )
            if model.errorMessage != nil {
              Button("重试加载详情") {
                Task { await model.loadDetail(item) }
              }
              .buttonStyle(.bordered)
              .padding(.horizontal)
            }
          } else {
            linePicker
            episodeAccess
          }
        }
        .padding(.vertical)
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

  private var metadataSection: some View {
    HStack(alignment: .top, spacing: 16) {
      CachedRemoteImage(url: detail.pic.flatMap(URL.init(string:))) {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.secondary.opacity(0.12))
      }
      .scaledToFill()
      .frame(width: 120, height: 168)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      VStack(alignment: .leading, spacing: 8) {
        Text(detail.name)
          .font(.title2.bold())
        metaLine
        Button {
          guard let sourceKey = detail.sourceKey ?? model.selectedSite?.key else { return }
          Task { await model.toggleFavorite(sourceKey: sourceKey, item: detail) }
        } label: {
          let sourceKey = detail.sourceKey ?? model.selectedSite?.key ?? ""
          Label(
            model.isFavorite(sourceKey: sourceKey, item: detail)
              ? "已收藏" : "收藏",
            systemImage: model.isFavorite(
              sourceKey: sourceKey,
              item: detail
            ) ? "heart.fill" : "heart"
          )
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(.horizontal)
  }

  @ViewBuilder
  private var metaLine: some View {
    let parts = [detail.typeName, detail.year, detail.area]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if !parts.isEmpty {
      Text(parts.joined(separator: " · "))
        .foregroundStyle(.secondary)
    }
    if let director = detail.director, !director.isEmpty {
      Text("导演 \(Self.plainText(director))")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    if let actor = detail.actor, !actor.isEmpty {
      Text("演员 \(Self.plainText(actor))")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
  }

  @ViewBuilder
  private var synopsisSection: some View {
    if let content = detail.content, !content.isEmpty {
      let text = Self.plainText(content)
      VStack(alignment: .leading, spacing: 6) {
        Text(text)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(expandSynopsis ? nil : 3)
        Button(expandSynopsis ? "收起" : "展开") {
          expandSynopsis.toggle()
        }
        .font(.caption.weight(.semibold))
      }
      .padding(.horizontal)
    }
  }

  @ViewBuilder
  private var linePicker: some View {
    if lines.count > 1 {
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(lines) { line in
            Button(line.name) {
              selectedFlag = line.name
            }
            .buttonStyle(.bordered)
            .tint(activeLine?.name == line.name ? .orange : .secondary)
          }
        }
        .padding(.horizontal)
      }
      .scrollIndicators(.hidden)
    }
  }

  private var isSingleEpisode: Bool {
    (activeLine?.episodes.count ?? 0) <= 1
  }

  /// Variety-style lists use titled cards; numbered series stay compact.
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

  private var currentEpisodeLabel: String {
    if let history = historyEntry,
      displayedEpisodes.contains(where: { $0.value == history.episodeId })
    {
      return history.episodeName
    }
    return displayedEpisodes.first?.name ?? "选集"
  }

  @ViewBuilder
  private var episodeAccess: some View {
    if !isSingleEpisode {
      Button {
        showingEpisodeDrawer = true
      } label: {
        HStack(spacing: 8) {
          Text("选集")
            .font(.headline)
            .foregroundStyle(.primary)
          Text(currentEpisodeLabel)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer()
          Text("展开")
            .font(.subheadline.weight(.semibold))
          Image(systemName: "chevron.up")
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
      .buttonStyle(.plain)
      .padding(.horizontal)
      .sheet(isPresented: $showingEpisodeDrawer) {
        episodeDrawer
      }
    }
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
        .onAppear { scrollToHistoryEpisode(using: proxy) }
      }
      .navigationTitle("选集")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { showingEpisodeDrawer = false }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(reverseEpisodes ? "正序" : "倒序") {
            reverseEpisodes.toggle()
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private func episodeCell(_ episode: Episode) -> some View {
    let isHistory = historyEntry?.episodeId == episode.value
    return Button {
      showingEpisodeDrawer = false
      Task { await play(episode: episode) }
    } label: {
      if resolvingEpisodeID == episode.id {
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 36)
      } else {
        Text(episode.name)
          .lineLimit(usesEpisodeCards ? 3 : 1)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, minHeight: usesEpisodeCards ? 64 : 36)
      }
    }
    .buttonStyle(.bordered)
    .tint(isHistory ? .orange : .secondary)
    .disabled(resolvingEpisodeID != nil)
    .id(episode.value)
  }

  private func scrollToHistoryEpisode(using proxy: ScrollViewProxy) {
    guard !didScrollToHistory,
      let historyID = historyEntry?.episodeId,
      displayedEpisodes.contains(where: { $0.value == historyID })
    else { return }
    didScrollToHistory = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      withAnimation(.easeInOut(duration: 0.25)) {
        proxy.scrollTo(historyID, anchor: .center)
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

  private func playPrimary() async {
    if let history = historyEntry,
      let line = lines.first(where: {
        $0.episodes.contains(where: { $0.value == history.episodeId })
      }),
      let episode = line.episodes.first(where: { $0.value == history.episodeId })
    {
      selectedFlag = line.name
      await play(episode: episode, flag: line.name)
      return
    }
    guard let line = activeLine, let episode = line.episodes.first else { return }
    await play(episode: episode, flag: line.name)
  }

  private func play(episode: Episode, flag: String? = nil) async {
    let lineName = flag ?? activeLine?.name ?? lines.first?.name ?? ""
    resolvingEpisodeID = episode.id
    playbackError = nil
    defer { resolvingEpisodeID = nil }
    do {
      playback = try await model.resolvePlayback(
        item: detail,
        episode: episode,
        flag: lineName
      )
      playbackEpisode = episode
      playbackFlag = lineName
    } catch {
      playbackError = error.localizedDescription
    }
  }

  private func format(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00" }
    let value = Int(seconds)
    return String(format: "%02d:%02d", value / 60, value % 60)
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
