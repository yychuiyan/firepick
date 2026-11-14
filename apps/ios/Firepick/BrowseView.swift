import FirepickCore
import SwiftUI

struct BrowseView: View {
  @Environment(AppModel.self) private var model
  @State private var selectedItem: MediaItem?
  /// Kept across pop so destination does not become EmptyView mid-transition (闪白).
  @State private var detailDestination: MediaItem?
  @State private var selectedFolder: MediaItem?
  @State private var showingSearch = false
  @State private var showingFavorites = false
  @State private var showingHistory = false
  @State private var showingFilterSheet = false
  @State private var showingSourcePicker = false

  private var columns: [GridItem] {
    let count = model.posterSizePreference == .large ? 2 : 3
    return Array(repeating: GridItem(.flexible(minimum: 0), spacing: 10), count: count)
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

  private var visibleCategories: [FirepickCore.Category] {
    let preferred = ["bucket|recommend", "bucket|tv", "bucket|movie", "bucket|variety", "bucket|anime"]
    let raw = (model.homeResult?.classes ?? []).filter { category in
      let id = category.typeId
      return !id.hasSuffix("kids") && !id.hasSuffix("doc")
    }
    // Prefer fixed 拾萤 menu order when present; drop stray CMS classes.
    let buckets = preferred.compactMap { id in raw.first(where: { $0.typeId == id }) }
    if buckets.count >= 3 { return buckets }
    return raw
  }

  private var latestItems: [MediaItem] {
    model.homeResult?.list ?? []
  }

  /// Chip/filters moved ahead of list — show skeleton instead of wrong-tab posters.
  private var showsBrowseSkeleton: Bool {
    model.isBrowseContentStale
  }

  /// Full-screen loader only before the first grid appears — category/filter
  /// switches keep posters and refresh silently (no「正在加载中」flash).
  private var isInitialHomeLoading: Bool {
    // Cold start: restore has not finished — never flash “还没有内容”.
    if model.isRestoringSession {
      return model.homeResult == nil
    }
    // Require homeResult == nil so an in-flight category fetch that still holds
    // the previous list (or briefly empties) never replaces the grid with a spinner.
    return hasActiveWarehouse && model.isLoadingHome && model.homeResult == nil
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        VStack(spacing: 0) {
          pageHeader
            .padding(.bottom, 4)
          // Keep tabs visible while a category fetch runs (list cleared → loading).
          if hasActiveWarehouse, !visibleCategories.isEmpty {
            stickyCategoryChrome
          }
        }
        .background(Color(.systemBackground))

        Group {
          if isInitialHomeLoading {
            // Keep ProgressView OUT of ScrollView+refreshable — otherwise iOS shows
            // both the system refresh spinner and our labeled ProgressView.
            ProgressView("正在加载中")
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else if !hasActiveWarehouse {
            ScrollView {
              emptyContent
                .padding(.vertical)
                .padding(.bottom, 72)
            }
          } else if showsBrowseSkeleton {
            ScrollView {
              browseSkeletonGrid
                .padding(.vertical)
                .padding(.bottom, 72)
            }
          } else if !latestItems.isEmpty {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 28) {
                catalogSection
              }
              .padding(.vertical)
              .padding(.bottom, 72)
            }
            .refreshable {
              await model.reloadHome()
            }
          } else {
            ScrollView {
              emptyContent
                .padding(.vertical)
                .padding(.bottom, 72)
            }
            .refreshable {
              await model.reloadHome()
            }
          }
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if let fab = browseFab {
          Button {
            switch fab {
            case .filter:
              showingFilterSheet = true
            case .link:
              showingSourcePicker = true
            }
          } label: {
            Image(systemName: fab.symbol)
              .font(.title3.weight(.semibold))
              .foregroundStyle(.white)
              .frame(width: 52, height: 52)
              .background(Color.orange, in: Circle())
              .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
          }
          .buttonStyle(.plain)
          .padding(.trailing, 16)
          .padding(.bottom, 12)
          .accessibilityLabel(fab.label)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(.systemBackground).ignoresSafeArea())
      .task(id: homeLoadToken) {
        guard hasActiveWarehouse else { return }
        await model.ensureHomeContentLoaded()
      }
      .toolbar(isRootVisible ? .hidden : .automatic, for: .navigationBar)
      // Detail hides the tab bar; without an explicit restore the glass chrome can stay clear.
      .toolbar(isRootVisible ? .visible : .automatic, for: .tabBar)
      .toolbarBackground(.visible, for: .tabBar)
      .toolbarBackground(Color(.systemBackground), for: .navigationBar)
      .onChange(of: isRootVisible) { _, visible in
        guard visible else { return }
        TabBarChrome.restore()
        // Pop from 收藏/历史 remounts LazyVGrid — warm first-screen covers to avoid blank cards.
        PosterPrefetch.warm(items: latestItems, limit: 18)
      }
      .onChange(of: latestItems.map(\.id)) { _, _ in
        // Filter / tab swap — prefetch posters immediately for 秒级显示.
        guard isRootVisible, !latestItems.isEmpty else { return }
        PosterPrefetch.warm(items: latestItems, limit: 18)
      }
      .onAppear {
        if isRootVisible {
          TabBarChrome.restore()
        }
      }
      .onChange(of: showingFavorites) { _, showing in
        if showing {
          PosterPrefetch.warm(
            items: model.libraryFavoritePrograms.map(\.item),
            limit: 24
          )
        }
      }
      .onChange(of: showingHistory) { _, showing in
        if showing {
          PosterPrefetch.warm(
            items: model.libraryHistoryPrograms.map(\.item),
            limit: 24
          )
        }
      }
      .sheet(isPresented: $showingSourcePicker) {
        SourcePickerView()
      }
      .navigationDestination(isPresented: $showingSearch) {
        SearchView()
          .background(FirepickBackdrop())
      }
      .navigationDestination(isPresented: $showingFavorites) {
        LibraryView(mode: .favorites)
          .background(FirepickBackdrop())
      }
      .navigationDestination(isPresented: $showingHistory) {
        LibraryView(mode: .history)
          .background(FirepickBackdrop())
      }
      .navigationDestination(
        isPresented: Binding(
          get: { selectedItem != nil },
          set: { presented in
            if !presented {
              Task { @MainActor in selectedItem = nil }
            }
          }
        )
      ) {
        if let detailDestination {
          DetailView(item: detailDestination)
        } else {
          FirepickBackdrop()
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
        } else {
          FirepickBackdrop()
        }
      }
    }
  }

  private var homeLoadToken: String {
    // Don't include selectedSite — it changes mid-selectSite and would double-load.
    "\(model.currentConnection?.id ?? "")|\(model.configuration.sites.count)"
  }

  private var showsPinnedFilter: Bool {
    guard !model.categoryFilters.isEmpty else { return false }
    guard let typeId = model.selectedCategory?.typeId else { return false }
    return !typeId.contains("recommend")
  }

  private var hasActiveFilters: Bool {
    model.hasActiveCategoryFilters
  }

  private enum BrowseFab {
    case filter
    case link

    var symbol: String {
      switch self {
      case .filter: "line.3.horizontal.decrease"
      case .link: "link"
      }
    }

    var label: String {
      switch self {
      case .filter: "筛选"
      case .link: "点播源"
      }
    }
  }

  private var browseFab: BrowseFab? {
    guard hasActiveWarehouse, isRootVisible else { return nil }
    if showsPinnedFilter { return .filter }
    if model.onDeviceSites.count > 1 { return .link }
    return nil
  }

  @ViewBuilder
  private var stickyCategoryChrome: some View {
    if !visibleCategories.isEmpty {
      VStack(spacing: 0) {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(visibleCategories) { category in
              let selected = model.selectedCategory?.typeId == category.typeId
              Button {
                guard model.selectedCategory?.typeId != category.typeId else { return }
                Task { await model.loadCategory(category) }
              } label: {
                Text(category.typeName)
                  .font(.subheadline.weight(.semibold))
                  .foregroundStyle(selected ? Color.white : Color.primary)
                  .lineLimit(1)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  .background(
                    selected ? Color.orange : Color.secondary.opacity(0.12),
                    in: Capsule()
                  )
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, 12)
          .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
      }
      .sheet(isPresented: $showingFilterSheet) {
        BrowseFilterSheet()
      }
    }
  }

  private var browseSkeletonGrid: some View {
    LazyVGrid(columns: columns, spacing: 12) {
      ForEach(0..<12, id: \.self) { _ in
        VStack(spacing: 6) {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .shimmering()
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.secondary.opacity(0.10))
            .frame(height: 12)
            .padding(.horizontal, 2)
        }
      }
    }
    .padding(.horizontal)
    .accessibilityLabel("正在加载分类")
  }

  private var catalogSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      LazyVGrid(columns: columns, spacing: 12) {
        ForEach(Array(latestItems.enumerated()), id: \.element.id) { index, item in
          posterButton(item)
            .onAppear {
              // First screen stays at ~12. More pages only when the user scrolls
              // to the last row — never prefetch mid-grid.
              guard latestItems.count >= 12 else { return }
              guard !model.isLoadingMore, !model.isLoadingHome else { return }
              guard model.currentPage < (model.homeResult?.pagecount ?? 0) else { return }
              let nearEnd = index >= latestItems.count - 2
              if nearEnd {
                Task { await model.loadMore() }
              }
            }
        }
      }
      .padding(.horizontal)
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
      }
    }
  }

  private func posterButton(_ item: MediaItem) -> some View {
    Button {
      Task { await open(item) }
    } label: {
      MediaCardView(
        item: item,
        progress: model.historyProgress(for: item)
      )
    }
    .buttonStyle(.plain)
    .frame(minWidth: 0, maxWidth: .infinity)
  }

  private func open(_ item: MediaItem) async {
    if item.isAction {
      await model.performAction(item)
    } else if item.isFolder {
      selectedFolder = item
    } else {
      model.detailResult = nil
      detailDestination = item
      selectedItem = item
    }
  }

  @ViewBuilder
  private var emptyContent: some View {
    if model.currentConnection == nil || model.configuration.sites.isEmpty {
      ContentUnavailableView {
        Label("还没有内容", systemImage: "sparkles")
      } description: {
        Text(Self.defaultWarehouseDescription)
      } actions: {
        Button("使用拾萤精选") {
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
    } else if model.selectedSite == nil || model.isRestoringSession {
      // Same label as the full-screen loader — avoid a second distinct "本机源" flash.
      ProgressView("正在加载中")
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
    HStack(spacing: 10) {
      Image(systemName: "square.stack.3d.up.fill")
        .font(.body.weight(.semibold))
        .foregroundStyle(.orange)
        .frame(width: 32, height: 32)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      Text(headerTitle)
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
      Spacer(minLength: 8)
      headerIcon("magnifyingglass", label: "搜索") {
        showingSearch = true
      }
      .disabled(model.selectedSite == nil)
      .opacity(model.selectedSite == nil ? 0.4 : 1)
      headerIcon("heart", label: "收藏") {
        showingFavorites = true
      }
      headerIcon("clock.arrow.circlepath", label: "最近观看") {
        showingHistory = true
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 4)
    .padding(.bottom, 6)
  }

  private func headerIcon(_ system: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: system)
        .font(.body.weight(.semibold))
        .foregroundStyle(.orange)
        .frame(width: 36, height: 36)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  /// Prefer the active site name (e.g. 拾萤精选), then warehouse notice, never a raw host alone.
  private var headerTitle: String {
    guard model.currentConnection != nil else { return "拾萤精选" }
    if let site = model.selectedSite {
      let name = Self.brandDisplayName(site.name)
      if !name.isEmpty { return name }
    }
    if let notice = model.configuration.notice {
      let name = Self.brandDisplayName(notice)
      if !name.isEmpty { return name }
    }
    if let connection = model.currentConnection {
      let name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty, name != connection.url, URL(string: connection.url)?.host != name {
        return Self.brandDisplayName(name)
      }
    }
    return "拾萤精选"
  }

  /// Cached remote config may still say「拾萤」— show 拾萤精选 until republish.
  private static func brandDisplayName(_ raw: String) -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if name == "拾萤" { return "拾萤精选" }
    return name
  }

  private static let defaultWarehouseDescription = "在设置中添加配置地址后，点播内容会出现在这里"
}
