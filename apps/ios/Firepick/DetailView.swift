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
  @State private var selectedFlag: String?
  @State private var reverseEpisodes = false
  @State private var synopsisExpanded = false
  @State private var showingEpisodeDrawer = false
  @State private var didScrollToHistory = false
  @State private var isPlayerExpanded = false

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
    return model.history.first {
      $0.sourceKey == sourceKey && $0.item.vodId == detail.vodId
    }
  }

  private var isDetailLoading: Bool {
    model.isLoadingDetail
      && model.detailResult?.list.first?.vodId != currentItem.vodId
      && lines.isEmpty
  }

  var body: some View {
    // Keep one PlayerView instance across expand/collapse so playback continues.
    VStack(spacing: 0) {
      inlinePlayer
      if !isPlayerExpanded {
        detailScroll
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background {
      if isPlayerExpanded {
        Color.black.ignoresSafeArea()
      } else {
        FirepickBackdrop()
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.hidden, for: .navigationBar)
    .toolbar(.hidden, for: .tabBar)
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
      if model.detailResult?.list.first?.vodId != currentItem.vodId {
        model.detailResult = nil
      }
      selectedFlag = model.preferredPlaybackFlag(
        sourceKey: currentItem.sourceKey ?? model.selectedSite?.key,
        vodId: currentItem.vodId
      )
      await model.loadDetail(currentItem)
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
    .onDisappear {
      if isPlayerExpanded {
        OrientationBridge.enterPortraitThenUnlock()
      }
    }
  }

  @ViewBuilder
  private var inlinePlayer: some View {
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
        chrome: isPlayerExpanded ? .immersive : .inline,
        onExpand: {
          isPlayerExpanded = true
          OrientationBridge.enterLandscape()
        },
        onCollapse: {
          isPlayerExpanded = false
          OrientationBridge.enterPortraitThenUnlock()
        },
        onPlayEpisode: { episode, flag in
          Task { await play(episode: episode, flag: flag) }
        }
      )
      .id("\(playbackEpisode?.value ?? "")|\(playback.url.absoluteString)")
      .modifier(PlayerFrameModifier(expanded: isPlayerExpanded))
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
          if let director = detail.director, !director.isEmpty {
            Text("导演：\(Self.plainText(director))")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          if let actor = detail.actor, !actor.isEmpty {
            Text("演员：\(Self.plainText(actor))")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          if isDetailLoading {
            HStack(spacing: 8) {
              ProgressView().tint(.orange)
              Text("加载线路中…")
                .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
          } else if lines.isEmpty {
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
          } else {
            Text("来源")
              .font(.body)
              .foregroundStyle(.primary)
              .padding(.top, 8)
            sourceChips
            if lines.count > 1 {
              Text("线路")
                .font(.body)
                .foregroundStyle(.primary)
                .padding(.top, 8)
              chipRow(lines.map(\.name), selected: activeLine?.name) { name in
                selectedFlag = name
              }
            }
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
                  }
                }
              }
              .scrollIndicators(.hidden)
              .sheet(isPresented: $showingEpisodeDrawer) {
                episodeDrawer
              }
            }
          }

          if let content = detail.content, !content.isEmpty {
            let plain = Self.plainText(content)
            let canExpand = plain.count > 72
            Text("简介")
              .font(.body)
              .foregroundStyle(.primary)
              .padding(.top, 8)
            Button {
              guard canExpand else { return }
              synopsisExpanded.toggle()
            } label: {
              Text(plain)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .lineLimit(synopsisExpanded ? nil : 3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .multilineTextAlignment(.leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(nil, value: synopsisExpanded)
            .accessibilityHint(canExpand ? (synopsisExpanded ? "收起简介" : "展开简介") : "")
          }
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
    "dytt": "电影天堂",
    "maoyan": "猫眼",
    "lzcaiji": "量子",
    "lzi": "量子影视",
    "zy360": "360资源",
    "jisu": "极速",
    "modu": "魔都",
    "ffzy": "非凡",
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

  @ViewBuilder
  private var sourceChips: some View {
    let sites = model.onDeviceSites
    if sites.count > 1 {
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(sites, id: \.key) { site in
            let selected = model.selectedSite?.key == site.key
            Button {
              Task {
                await switchSource(to: site)
              }
            } label: {
              Text(site.name)
                .font(.subheadline)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
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
      }
      .scrollIndicators(.hidden)
    } else {
      Text(playbackSourceName)
        .font(.subheadline)
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange, in: Capsule())
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

  private func chipRow(_ titles: [String], selected: String?, onSelect: @escaping (String) -> Void) -> some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(titles, id: \.self) { title in
          let isOn = title == selected
          Button(title) { onSelect(title) }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isOn ? Color.orange : Color.secondary.opacity(0.12), in: Capsule())
        }
      }
    }
    .scrollIndicators(.hidden)
  }

  private func episodeChip(_ episode: Episode) -> some View {
    let isOn = focusedEpisodeValue == episode.value
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
    .id(episode.value)
  }

  /// Keep the playing / pending episode highlighted — never swap the chip for a spinner.
  private var focusedEpisodeValue: String? {
    playbackEpisode?.value ?? historyEntry?.episodeId ?? activeLine?.episodes.first?.value
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
    let isOn = focusedEpisodeValue == episode.value
    return Button {
      showingEpisodeDrawer = false
      Task { await play(episode: episode) }
    } label: {
      Text(episode.name)
        .lineLimit(usesEpisodeCards ? 3 : 1)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: usesEpisodeCards ? 64 : 36)
    }
    .buttonStyle(.bordered)
    .tint(isOn ? .orange : .secondary)
    .id(episode.value)
  }

  private func scrollToHistoryEpisode(using proxy: ScrollViewProxy) {
    guard !didScrollToHistory,
      let focusID = focusedEpisodeValue,
      displayedEpisodes.contains(where: { $0.value == focusID })
    else { return }
    didScrollToHistory = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      withAnimation(.easeInOut(duration: 0.25)) {
        proxy.scrollTo(focusID, anchor: .center)
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

  private func switchSource(to site: SiteConfiguration) async {
    let previousSite = model.selectedSite
    await model.selectSite(site)
    do {
      guard let replacement = try await model.findItem(named: detail.name, in: site) else {
        if let previousSite {
          await model.selectSite(previousSite)
        }
        playbackError = "「\(site.name)」没有找到《\(detail.name)》"
        return
      }
      playback = nil
      playbackEpisode = nil
      playbackFlag = nil
      selectedFlag = nil
      showingEpisodeDrawer = false
      model.detailResult = nil
      currentItem = replacement
      await model.loadDetail(replacement)
      selectedFlag = lines.first?.name
      if !lines.isEmpty {
        await playPrimary()
      }
    } catch {
      if let previousSite {
        await model.selectSite(previousSite)
      }
      playbackError = error.localizedDescription
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

  private func play(episode: Episode, flag: String? = nil) async {
    let lineName = flag ?? activeLine?.name ?? lines.first?.name ?? ""
    // Focus the chip immediately; loading stays in the player, not on 选集.
    playbackEpisode = episode
    playbackFlag = lineName
    resolvingEpisodeID = episode.id
    playbackError = nil
    defer { resolvingEpisodeID = nil }
    do {
      playback = try await model.resolvePlayback(
        item: detail,
        episode: episode,
        flag: lineName
      )
    } catch {
      playbackError = error.localizedDescription
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

  func body(content: Content) -> some View {
    if expanded {
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    } else {
      content
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
    }
  }
}
