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
  @State private var selectedFlag: String?
  @State private var reverseEpisodes = false
  @State private var expandSynopsis = false
  @State private var downloadToast: String?
  @State private var didScrollToHistory = false

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
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          metadataSection
          synopsisSection
          playCTA
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
            episodeGrid
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
    .navigationTitle(detail.name)
    .navigationBarTitleDisplayMode(.inline)
    .overlay(alignment: .bottom) {
      if let downloadToast {
        Text(downloadToast)
          .font(.subheadline.weight(.medium))
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(.ultraThinMaterial, in: Capsule())
          .padding(.bottom, 24)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
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
    } message: {
      Text(playbackError ?? "")
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
    }
    .onChange(of: selectedFlag) { _, flag in
      guard let flag else { return }
      model.setPreferredPlaybackFlag(
        flag,
        sourceKey: detail.sourceKey ?? model.selectedSite?.key,
        vodId: detail.vodId
      )
    }
    .fullScreenCover(item: $playback) { request in
      PlayerView(
        request: request,
        item: detail,
        episode: playbackEpisode,
        flag: playbackFlag,
        lineEpisodes: lines.first(where: { $0.name == playbackFlag })?.episodes
          ?? activeLine?.episodes
          ?? [],
        playbackLines: lines
      )
    }
  }

  private var metadataSection: some View {
    HStack(alignment: .top, spacing: 16) {
      CachedRemoteImage(url: detail.pic.flatMap(URL.init(string:))) {
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.orange.opacity(0.12))
          Text(String(detail.name.prefix(1)))
            .font(.title.weight(.bold))
            .foregroundStyle(.orange.opacity(0.85))
        }
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

  private var playCTA: some View {
    Button {
      Task { await playPrimary() }
    } label: {
      HStack {
        if resolvingEpisodeID != nil && playback == nil {
          ProgressView()
            .tint(.white)
        }
        Text(ctaTitle)
          .frame(maxWidth: .infinity)
      }
      .padding(.vertical, 4)
    }
    .buttonStyle(.borderedProminent)
    .tint(.orange)
    .disabled(activeLine?.episodes.isEmpty != false || resolvingEpisodeID != nil)
    .padding(.horizontal)
  }

  private var ctaTitle: String {
    if let history = historyEntry {
      return "继续 · \(history.episodeName) · \(format(history.position))"
    }
    return "立即播放"
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
    } else if let line = lines.first {
      Text(line.name)
        .font(.headline)
        .padding(.horizontal)
    }
  }

  private var episodeGrid: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("选集")
          .font(.headline)
        Spacer()
        Button(reverseEpisodes ? "正序" : "倒序") {
          reverseEpisodes.toggle()
        }
        .font(.subheadline.weight(.semibold))
      }
      .padding(.horizontal)

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
        ForEach(displayedEpisodes) { episode in
          let isHistory = historyEntry?.episodeId == episode.value
          Button {
            Task { await play(episode: episode) }
          } label: {
            if resolvingEpisodeID == episode.id {
              ProgressView()
                .frame(maxWidth: .infinity)
            } else {
              Text(episode.name)
            }
          }
          .buttonStyle(.bordered)
          .tint(isHistory ? .orange : .secondary)
          .lineLimit(1)
          .disabled(resolvingEpisodeID != nil)
          .id(episode.value)
          .contextMenu {
            Button {
              Task { await download(episode: episode) }
            } label: {
              Label("下载到本机", systemImage: "arrow.down.circle")
            }
          }
        }
      }
      .padding(.horizontal)
    }
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

  private func download(episode: Episode) async {
    let lineName = activeLine?.name ?? lines.first?.name ?? ""
    resolvingEpisodeID = episode.id
    defer { resolvingEpisodeID = nil }
    do {
      let request = try await model.resolvePlayback(
        item: detail,
        episode: episode,
        flag: lineName
      )
      model.download(request: request, item: detail, episode: episode)
      withAnimation {
        downloadToast = "已加入下载"
      }
      try? await Task.sleep(for: .seconds(1.6))
      withAnimation { downloadToast = nil }
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
  }
}
