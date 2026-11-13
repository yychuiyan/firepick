import FirepickCore
import FirepickPlayback
import SwiftUI

struct BrowseView: View {
  @Environment(AppModel.self) private var model
  @State private var selectedItem: MediaItem?
  @State private var selectedFolder: MediaItem?
  @State private var showingSearch = false
  @State private var showingFavorites = false
  @State private var showingHistory = false
  @State private var showingFilterSheet = false
  @State private var resumingHistoryID: String?

  private var columns: [GridItem] {
    [
      GridItem(
        .adaptive(minimum: model.posterSizePreference.minimumWidth, maximum: 240),
        spacing: 14
      )
    ]
  }

  private var hasActiveWarehouse: Bool {
    model.currentConnection != nil && !model.onDeviceSites.isEmpty
  }

  private var isRootVisible: Bool {
    selectedItem == nil
      && selectedFolder == nil
      && !showingSearch
      && !showingFavorites
      && !showingHistory
  }

  private var showContinueWatching: Bool {
    !continueWatching.isEmpty
  }

  private var continueWatching: [HistoryEntry] {
    var seen = Set<String>()
    var result: [HistoryEntry] = []
    for entry in model.history {
      let key = "\(entry.sourceKey)|\(entry.item.vodId)"
      guard seen.insert(key).inserted else { continue }
      result.append(entry)
      if result.count >= 12 { break }
    }
    return result.filter(matchesSelectedCategory)
  }

  private var isRecommendShelf: Bool {
    let typeId = model.selectedCategory?.typeId ?? ""
    return typeId.isEmpty || typeId.contains("recommend")
  }

  private var visibleCategories: [FirepickCore.Category] {
    (model.homeResult?.classes ?? []).filter { category in
      let id = category.typeId
      return !id.hasSuffix("kids") && !id.hasSuffix("doc")
    }
  }

  private var highScoreItems: [MediaItem] {
    guard isRecommendShelf, !hasActiveFilters else { return [] }
    return Array(
      (model.homeResult?.list ?? [])
        .filter { ($0.doubanScore ?? 0) > 0 }
        .sorted { ($0.doubanScore ?? 0) > ($1.doubanScore ?? 0) }
        .prefix(12)
    )
  }

  private var latestItems: [MediaItem] {
    let all = model.homeResult?.list ?? []
    guard !highScoreItems.isEmpty else { return all }
    let featured = Set(highScoreItems.map(\.id))
    let rest = all.filter { !featured.contains($0.id) }
    return rest.isEmpty ? all : rest
  }

  private func matchesSelectedCategory(_ entry: HistoryEntry) -> Bool {
    guard !isRecommendShelf else { return true }
    let typeId = model.selectedCategory?.typeId ?? ""
    let name = entry.item.typeName ?? ""
    if typeId.hasSuffix("tv") {
      return name.contains("剧") && !name.contains("动漫") && !name.contains("动画")
    }
    if typeId.hasSuffix("movie") {
      return name.contains("片") || name.contains("电影")
    }
    if typeId.hasSuffix("variety") {
      return name.contains("综艺")
    }
    if typeId.hasSuffix("anime") {
      return name.contains("动漫") || name.contains("动画")
    }
    return false
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        pageHeader
          .padding(.bottom, 8)

        if hasActiveWarehouse {
          stickyCategoryChrome
        }

        if hasActiveWarehouse, model.officialSourceNeedsUpdate {
          officialUpdateBanner
        }

        ScrollView {
          LazyVStack(alignment: .leading, spacing: 28) {
            if hasActiveWarehouse, showContinueWatching {
              continueWatchingSection
            }

            if !hasActiveWarehouse {
              emptyContent
            } else if model.isLoadingHome && model.homeResult == nil {
              ProgressView("正在读取数据源…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            } else if let items = model.homeResult?.list, !items.isEmpty {
              catalogSection
            } else if model.isLoadingHome {
              ProgressView("正在读取数据源…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            } else {
              emptyContent
            }
          }
          .padding(.vertical)
        }
      }
      .refreshable {
        guard hasActiveWarehouse else { return }
        await model.reloadHome()
      }
      .task(id: homeLoadToken) {
        guard hasActiveWarehouse else { return }
        await model.ensureHomeContentLoaded()
      }
      .toolbar(isRootVisible ? .hidden : .automatic, for: .navigationBar)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if isRootVisible, let item = model.resumeBrowseItem {
          resumeBar(item)
        }
      }
      .navigationDestination(isPresented: $showingSearch) {
        SearchView()
      }
      .navigationDestination(isPresented: $showingFavorites) {
        LibraryView(mode: .favorites)
      }
      .navigationDestination(isPresented: $showingHistory) {
        LibraryView(mode: .history)
      }
      .navigationDestination(
        isPresented: Binding(
          get: { selectedItem != nil },
          set: { if !$0 { selectedItem = nil } }
        )
      ) {
        if let selectedItem {
          DetailView(item: selectedItem)
        }
      }
      .navigationDestination(
        isPresented: Binding(
          get: { selectedFolder != nil },
          set: { if !$0 { selectedFolder = nil } }
        )
      ) {
        if let selectedFolder {
          FolderBrowseView(folder: selectedFolder)
        }
      }
    }
  }

  private var homeLoadToken: String {
    "\(model.currentConnection?.id ?? "")|\(model.configuration.sites.count)|\(model.selectedSite?.key ?? "")"
  }

  private var showsPinnedFilter: Bool {
    guard !model.categoryFilters.isEmpty else { return false }
    guard let typeId = model.selectedCategory?.typeId else { return false }
    return !typeId.contains("recommend")
  }

  private var hasActiveFilters: Bool {
    model.filterSelections.contains { _, value in
      !value.isEmpty
    }
  }

  @ViewBuilder
  private var stickyCategoryChrome: some View {
    VStack(spacing: 10) {
      if !visibleCategories.isEmpty {
        // Chips scroll; 筛选 pins on the trailing edge of the row (not floating).
        HStack(spacing: 0) {
          ScrollView(.horizontal) {
            HStack(spacing: 8) {
              ForEach(visibleCategories) { category in
                BrowseChip(
                  title: category.typeName,
                  selected: model.selectedCategory?.typeId == category.typeId
                ) {
                  Task { await model.loadCategory(category) }
                }
              }
            }
            .padding(.leading)
            .padding(.trailing, showsPinnedFilter ? 8 : 16)
          }
          .scrollIndicators(.hidden)

          if showsPinnedFilter {
            Divider()
              .frame(height: 24)
              .padding(.trailing, 4)
            Button {
              showingFilterSheet = true
            } label: {
              BrowseChipLabel(
                title: "筛选",
                systemImage: "line.3.horizontal.decrease",
                selected: hasActiveFilters,
                showsDot: hasActiveFilters
              )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
          }
        }
      }
    }
    .padding(.bottom, 8)
    .background(.background)
    .sheet(isPresented: $showingFilterSheet) {
      BrowseFilterSheet()
    }
  }

  private var continueWatchingSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("继续观看")
        .font(.headline)
        .padding(.horizontal)
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 10) {
          ForEach(continueWatching) { entry in
            Button {
              Task { await resumeOrOpen(entry) }
            } label: {
              MediaCardView(
                item: entry.item,
                progress: entry.duration > 0
                  ? min(1, max(0, entry.position / entry.duration))
                  : nil,
                subtitle: entry.episodeName,
                compactPosterHeight: 104
              )
              .overlay {
                if resumingHistoryID == entry.id {
                  ZStack {
                    Color.black.opacity(0.25)
                    ProgressView()
                      .tint(.white)
                  }
                  .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
              }
            }
            .buttonStyle(.plain)
            .disabled(resumingHistoryID != nil)
          }
        }
        .padding(.horizontal)
      }
      .scrollIndicators(.hidden)
    }
  }

  private var catalogSection: some View {
    VStack(alignment: .leading, spacing: 22) {
      if model.isLoadingHome {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity)
      }
      if hasActiveFilters {
        Text("年份、地区和类型会交给采集站。站不支持的条件会再在返回结果里筛一次。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal)
      }
      if !highScoreItems.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          Text("高分")
            .font(.headline)
            .padding(.horizontal)
          ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
              ForEach(highScoreItems) { item in
                posterButton(item, compactPosterHeight: 140)
              }
            }
            .padding(.horizontal)
          }
          .scrollIndicators(.hidden)
        }
      }
      VStack(alignment: .leading, spacing: 12) {
        if isRecommendShelf {
          Text("最近更新")
            .font(.headline)
            .padding(.horizontal)
        }
        LazyVGrid(columns: columns, spacing: 18) {
          ForEach(Array(latestItems.enumerated()), id: \.element.id) { index, item in
            posterButton(item)
              .onAppear {
                let threshold = max(0, latestItems.count - 6)
                if index >= threshold {
                  Task { await model.loadMore() }
                }
              }
          }
        }
        .padding(.horizontal)
      }
      if model.isLoadingMore {
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
      } else if model.loadMoreFailed {
        Button("加载失败 · 重试") {
          Task { await model.loadMore() }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
      } else if model.currentPage < (model.homeResult?.pagecount ?? 0) {
        Button("加载更多") {
          Task { await model.loadMore() }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
      }
    }
  }

  private func posterButton(_ item: MediaItem, compactPosterHeight: CGFloat? = nil) -> some View {
    Button {
      Task { await open(item) }
    } label: {
      MediaCardView(
        item: item,
        progress: model.historyProgress(for: item),
        compactPosterHeight: compactPosterHeight
      )
    }
    .buttonStyle(.plain)
  }

  private func open(_ item: MediaItem) async {
    if item.isAction {
      await model.performAction(item)
    } else if item.isFolder {
      selectedFolder = item
    } else {
      model.detailResult = nil
      model.resumeBrowseItem = nil
      selectedItem = item
    }
  }

  private var officialUpdateBanner: some View {
    HStack(spacing: 12) {
      Text("拾萤配置有更新")
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("更新") {
        Task { await model.applyOfficialSource() }
      }
      .buttonStyle(.borderedProminent)
      .tint(.orange)
      .controlSize(.small)
      .disabled(model.isSwitchingConnection)
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(Color.orange.opacity(0.12))
  }

  private func resumeBar(_ item: MediaItem) -> some View {
    HStack(spacing: 12) {
      Button {
        model.detailResult = nil
        selectedItem = item
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "play.fill")
          Text("继续播放 \(item.name)")
            .lineLimit(1)
          Spacer(minLength: 0)
        }
      }
      .buttonStyle(.plain)
      Button {
        model.resumeBrowseItem = nil
      } label: {
        Image(systemName: "xmark")
          .font(.caption.weight(.bold))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("关闭继续播放")
    }
    .font(.subheadline.weight(.semibold))
    .foregroundStyle(.primary)
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.bar)
  }

  @ViewBuilder
  private var emptyContent: some View {
    if model.currentConnection == nil || model.configuration.sites.isEmpty {
      ContentUnavailableView {
        Label("还没有内容", systemImage: "sparkles")
      } description: {
        Text(Self.defaultWarehouseDescription)
      } actions: {
        Button("使用拾萤") {
          Task { await model.applyOfficialSource() }
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(model.isSwitchingConnection)
        Button("去设置添加线路") {
          model.selectedTab = .settings
        }
        .buttonStyle(.bordered)
      }
    } else if model.onDeviceSites.isEmpty {
      ContentUnavailableView(
        "当前配置没有本机可播源",
        systemImage: "iphone.slash",
        description: Text("该配置没有可用的 HTTP/JS 源。请换用自建 iOS 配置仓后重试。")
      )
    } else if model.selectedSite == nil {
      ProgressView("正在加载本机源…")
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    } else if let error = model.errorMessage, !error.isEmpty {
      ContentUnavailableView {
        Label("这个源暂时无法加载", systemImage: "exclamationmark.triangle")
      } description: {
        Text(error)
      } actions: {
        Button("重试") {
          Task { await model.reloadHome() }
        }
        .buttonStyle(.bordered)
      }
    } else {
      ContentUnavailableView {
        Label(
          hasActiveFilters ? "当前筛选没有结果" : emptyCategoryTitle,
          systemImage: "film"
        )
      } description: {
        Text(emptyCategoryMessage)
      } actions: {
        if hasActiveFilters {
          Button("调整筛选") {
            showingFilterSheet = true
          }
          .buttonStyle(.bordered)
        }
      }
    }
  }

  private var emptyCategoryTitle: String {
    let typeId = model.selectedCategory?.typeId ?? ""
    if typeId.hasSuffix("kids") || typeId.hasSuffix("doc") {
      return "这个分类暂时没有内容"
    }
    return "这个源暂时没有内容"
  }

  private var emptyCategoryMessage: String {
    if hasActiveFilters {
      return "类型、地区和年份会交给采集站筛选。站不支持的条件会再在结果里筛一次。可以重置后再看。"
    }
    let typeId = model.selectedCategory?.typeId ?? ""
    if typeId.hasSuffix("kids") || typeId.hasSuffix("doc") {
      return "采集站分类名对不上时，少儿和纪录片会是空的。"
    }
    return "下拉刷新试试。"
  }

  private var pageHeader: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(headerTitle)
            .font(.system(size: 28, weight: .bold))
            .lineLimit(1)
        }
        if !hasActiveWarehouse {
          Text(
            model.currentConnection == nil
              ? Self.defaultWarehouseDescription
              : "当前线路没有本机可播源"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        }
      }
      Spacer(minLength: 8)
      HStack(spacing: 8) {
        Button {
          showingSearch = true
        } label: {
          Image(systemName: "magnifyingglass")
            .font(.title3.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜索")
        .disabled(model.selectedSite == nil)
        .opacity(model.selectedSite == nil ? 0.4 : 1)

        Button {
          showingFavorites = true
        } label: {
          Image(systemName: "heart")
            .font(.title3.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("收藏")

        Button {
          showingHistory = true
        } label: {
          Image(systemName: "clock.arrow.circlepath")
            .font(.title3.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("最近观看")
      }
    }
    .padding(.horizontal)
    .padding(.top, 8)
  }

  /// Prefer the active site name (e.g. 拾萤), then warehouse notice, never a raw host alone.
  private var headerTitle: String {
    guard model.currentConnection != nil else { return "拾萤" }
    if let site = model.selectedSite {
      let name = site.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty { return name }
    }
    if let notice = model.configuration.notice?.trimmingCharacters(in: .whitespacesAndNewlines),
      !notice.isEmpty
    {
      return notice
    }
    if let connection = model.currentConnection {
      let name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty, name != connection.url, URL(string: connection.url)?.host != name {
        return name
      }
    }
    return "拾萤"
  }

  private func resumeOrOpen(_ entry: HistoryEntry) async {
    resumingHistoryID = entry.id
    defer { resumingHistoryID = nil }
    if await model.resumeFromHistory(entry) {
      return
    }
    model.detailResult = nil
    model.resumeBrowseItem = nil
    selectedItem = entry.item
  }

  private static let defaultWarehouseDescription = "在设置中添加配置地址后，点播内容会出现在这里"
}

private struct BrowseChip: View {
  let title: String
  var selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      BrowseChipLabel(title: title, selected: selected)
    }
    .buttonStyle(.plain)
  }
}

private struct BrowseChipLabel: View {
  let title: String
  var systemImage: String? = nil
  var selected: Bool
  var showsDot: Bool = false

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage {
        Image(systemName: systemImage)
      }
      Text(title)
      if showsDot {
        Circle()
          .fill(selected ? Color.white : Color.orange)
          .frame(width: 6, height: 6)
      }
    }
    .font(.subheadline.weight(.semibold))
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .foregroundStyle(selected ? Color.white : Color.primary)
    .background(selected ? Color.orange : Color.secondary.opacity(0.12), in: Capsule())
  }
}
