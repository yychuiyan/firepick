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
  @State private var showingSourcePicker = false
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
    guard !continueWatching.isEmpty else { return false }
    guard let typeId = model.selectedCategory?.typeId else { return true }
    return typeId.contains("recommend")
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
    return result
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        pageHeader
          .padding(.bottom, 8)

        if hasActiveWarehouse {
          stickyCategoryChrome
        }

        ScrollView {
          LazyVStack(alignment: .leading, spacing: 20) {
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
              ZStack {
                LazyVGrid(columns: columns, spacing: 18) {
                  ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                      Task {
                        if item.isAction {
                          await model.performAction(item)
                        } else if item.isFolder {
                          selectedFolder = item
                        } else {
                          model.detailResult = nil
                          selectedItem = item
                        }
                      }
                    } label: {
                      MediaCardView(
                        item: item,
                        progress: model.historyProgress(for: item)
                      )
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                      let threshold = max(0, items.count - 6)
                      if index >= threshold {
                        Task { await model.loadMore() }
                      }
                    }
                  }
                }
                .padding(.horizontal)
                .opacity(model.isLoadingHome ? 0.45 : 1)

                if model.isLoadingHome {
                  ProgressView()
                    .padding(.vertical, 48)
                }
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
                .padding(.vertical, 8)
              } else if model.currentPage < (model.homeResult?.pagecount ?? 0) {
                Button("加载更多") {
                  Task { await model.loadMore() }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
              }
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

  @ViewBuilder
  private var stickyCategoryChrome: some View {
    VStack(spacing: 10) {
      if let categories = model.homeResult?.classes, !categories.isEmpty {
        ScrollView(.horizontal) {
          HStack {
            ForEach(categories) { category in
              Button(category.typeName) {
                Task { await model.loadCategory(category) }
              }
              .buttonStyle(.bordered)
              .tint(model.selectedCategory?.typeId == category.typeId ? .orange : .secondary)
            }
          }
          .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
      }

      if !model.categoryFilters.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(model.categoryFilters, id: \.key) { filter in
              Menu {
                ForEach(
                  Array(filter.value.enumerated()),
                  id: \.offset
                ) { entry in
                  let value = entry.element
                  Button {
                    Task {
                      await model.selectFilter(filter, value: value)
                    }
                  } label: {
                    if model.filterSelections[filter.key] == value.value {
                      Label(value.name, systemImage: "checkmark")
                    } else {
                      Text(value.name)
                    }
                  }
                }
              } label: {
                Label(
                  "\(filter.name)：\(model.selectedFilterName(filter))",
                  systemImage: "line.3.horizontal.decrease.circle"
                )
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.secondary.opacity(0.1), in: Capsule())
              }
            }
          }
          .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
      }
    }
    .padding(.bottom, 8)
    .background(.background)
  }

  private var continueWatchingSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("继续观看")
        .font(.headline)
        .padding(.horizontal)
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 12) {
          ForEach(continueWatching) { entry in
            Button {
              Task { await resumeOrOpen(entry) }
            } label: {
              MediaCardView(
                item: entry.item,
                progress: entry.duration > 0
                  ? min(1, max(0, entry.position / entry.duration))
                  : nil,
                subtitle: entry.episodeName
              )
              .frame(width: model.posterSizePreference.minimumWidth + 12)
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

  @ViewBuilder
  private var emptyContent: some View {
    if model.currentConnection == nil || model.configuration.sites.isEmpty {
      ContentUnavailableView {
        Label("还没有内容", systemImage: "sparkles")
      } description: {
        Text(Self.defaultWarehouseDescription)
      } actions: {
        Button("去设置添加线路") {
          model.selectedTab = .settings
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
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
      ContentUnavailableView(
        "这个源暂时没有内容",
        systemImage: "film",
        description: Text("下拉刷新试试。")
      )
    }
  }

  private var pageHeader: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(headerTitle)
            .font(.system(size: 28, weight: .bold))
            .lineLimit(1)
          if model.onDeviceSites.count > 1 {
            Button {
              showingSourcePicker = true
            } label: {
              Text("源")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.secondary.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换点播源")
          }
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

  /// Prefer the active site name (e.g. 拾萤精选), then warehouse notice, never a raw host alone.
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
    selectedItem = entry.item
  }

  private static let defaultWarehouseDescription = "在设置中添加配置地址后，点播内容会出现在这里"
}
