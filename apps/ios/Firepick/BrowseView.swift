import FirepickCore
import SwiftUI

struct BrowseView: View {
  @Environment(AppModel.self) private var model
  @State private var selectedItem: MediaItem?
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
    (model.homeResult?.classes ?? []).filter { category in
      let id = category.typeId
      return !id.hasSuffix("kids") && !id.hasSuffix("doc")
    }
  }

  private var latestItems: [MediaItem] {
    model.homeResult?.list ?? []
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
          } else if let items = model.homeResult?.list, !items.isEmpty {
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
      .background(FirepickBackdrop())
      .task(id: homeLoadToken) {
        guard hasActiveWarehouse else { return }
        await model.ensureHomeContentLoaded()
      }
      .toolbar(isRootVisible ? .hidden : .automatic, for: .navigationBar)
      // Detail hides the tab bar; without an explicit restore the glass chrome can stay clear.
      .toolbar(isRootVisible ? .visible : .automatic, for: .tabBar)
      .toolbarBackground(.visible, for: .tabBar)
      .onChange(of: isRootVisible) { _, visible in
        guard visible else { return }
        TabBarChrome.restore()
      }
      .onAppear {
        if isRootVisible {
          TabBarChrome.restore()
        }
      }
      .sheet(isPresented: $showingSourcePicker) {
        SourcePickerView()
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
          set: { presented in
            if !presented {
              Task { @MainActor in selectedItem = nil }
            }
          }
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

  private var catalogSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      LazyVGrid(columns: columns, spacing: 12) {
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

  private static let defaultWarehouseDescription = "在设置中添加配置地址后，点播内容会出现在这里"
}
