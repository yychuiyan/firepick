import FirepickCore
import SwiftUI

struct SearchView: View {
  @Environment(AppModel.self) private var model
  @FocusState private var searchFocused: Bool
  @State private var selectedItem: MediaItem?
  /// Kept across pop so destination does not become EmptyView mid-transition (闪白).
  @State private var detailDestination: MediaItem?
  @State private var selectedHistory = Set<String>()
  @State private var isEditingHistory = false
  @State private var showingDeleteConfirmation = false

  var body: some View {
    @Bindable var model = model
    VStack(spacing: 0) {
      searchBar
      Divider()

      if !model.searchHasRun, !model.isLoadingSearch {
        historyContent
      } else {
        resultsContent
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground).ignoresSafeArea())
    .navigationTitle("搜索")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.visible, for: .navigationBar)
    .toolbarBackground(Color(.systemBackground), for: .navigationBar)
    .scrollDismissesKeyboard(.interactively)
    .dismissKeyboardOnBackgroundTap()
    .task {
      if !model.searchHasRun, model.searchText.isEmpty {
        try? await Task.sleep(for: .milliseconds(250))
        searchFocused = true
      }
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
    .alert("删除选中的查询记录？", isPresented: $showingDeleteConfirmation) {
      Button("删除", role: .destructive) {
        model.removeSearchHistory(selectedHistory)
        selectedHistory.removeAll()
        isEditingHistory = false
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("将删除 \(selectedHistory.count) 条历史查询，不会删除观看记录。")
    }
  }

  private var searchBar: some View {
    @Bindable var model = model
    return HStack(spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("片名、剧名或演员", text: $model.searchText)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.search)
          .focused($searchFocused)
          .onSubmit(runSearch)
          .onChange(of: model.searchText) { _, value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              model.searchHasRun = false
              model.searchSections = []
              model.liveSearchResults = []
              selectedHistory.removeAll()
              isEditingHistory = false
            }
          }
        if !model.searchText.isEmpty {
          Button {
            model.searchText = ""
            searchFocused = true
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.tertiary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
    .background(.background)
  }

  @ViewBuilder
  private var historyContent: some View {
    if model.searchHistory.isEmpty {
      ContentUnavailableView(
        "暂无历史查询",
        systemImage: "clock.arrow.circlepath",
        description: Text("输入片名、剧名或演员后，在键盘上搜索。")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 0) {
        HStack {
          Label("历史查询", systemImage: "clock")
            .font(.headline)
          Spacer()
          if isEditingHistory {
            Button(role: .destructive) {
              showingDeleteConfirmation = true
            } label: {
              Text(
                selectedHistory.isEmpty
                  ? "删除"
                  : "删除 \(selectedHistory.count) 条"
              )
            }
            .disabled(selectedHistory.isEmpty)
            Button("完成") {
              selectedHistory.removeAll()
              isEditingHistory = false
            }
          } else {
            Button("全部删除", role: .destructive) {
              model.clearSearchHistory()
            }
            Button("管理") {
              isEditingHistory = true
            }
          }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)

        List {
          ForEach(model.searchHistory, id: \.self) { keyword in
            Button {
              if isEditingHistory {
                toggleHistorySelection(keyword)
              } else {
                model.searchText = keyword
                runSearch()
              }
            } label: {
              HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                  .foregroundStyle(.secondary)
                Text(keyword)
                  .foregroundStyle(.primary)
                Spacer()
                if isEditingHistory {
                  Image(
                    systemName:
                      selectedHistory.contains(keyword)
                      ? "checkmark.circle.fill"
                      : "circle"
                  )
                  .foregroundStyle(
                    selectedHistory.contains(keyword)
                      ? Color.orange
                      : Color.secondary
                  )
                } else {
                  Image(systemName: "arrow.up.left")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .listStyle(.plain)
      }
    }
  }

  private var resultsContent: some View {
    let columns = [
      GridItem(
        .adaptive(minimum: model.posterSizePreference.minimumWidth, maximum: 240),
        spacing: 14
      )
    ]
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        if model.isLoadingSearch {
          ProgressView("正在搜索…")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
        if !model.liveSearchResults.isEmpty {
          Text("直播")
            .font(.headline)
            .padding(.horizontal)
          ForEach(model.liveSearchResults) { channel in
            Button {
              model.playLiveFromSearch(channel)
            } label: {
              HStack(spacing: 12) {
                CachedRemoteImage(
                  url: channel.logo.flatMap(URL.init(string:)),
                  maxPixelSize: 96
                ) {
                  Image(systemName: "tv")
                    .foregroundStyle(.secondary)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                  Text(channel.name)
                  if let number = channel.number {
                    Text(number)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
                Spacer()
              }
              .padding(.horizontal)
            }
            .buttonStyle(.plain)
          }
        }
        ForEach(model.searchSections) { section in
          Text(section.siteName)
            .font(.headline)
            .padding(.horizontal)
          LazyVGrid(columns: columns, spacing: 18) {
            ForEach(section.result.list) { item in
              Button {
                model.detailResult = nil
                detailDestination = item
                selectedItem = item
              } label: {
                MediaCardView(item: item)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal)
        }
        if !model.searchFailures.isEmpty {
          Text("失败的源")
            .font(.headline)
            .padding(.horizontal)
          ForEach(model.searchFailures) { failure in
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
              VStack(alignment: .leading, spacing: 2) {
                Text(failure.siteName)
                  .font(.subheadline.weight(.semibold))
                Text(failure.message)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
            }
            .padding(.horizontal)
          }
        }
        if model.searchHasRun,
          !model.isLoadingSearch,
          model.searchSections.isEmpty,
          model.liveSearchResults.isEmpty
        {
          ContentUnavailableView {
            Label(
              model.searchFailureCount > 0 ? "搜索失败" : "没有找到结果",
              systemImage: model.searchFailureCount > 0
                ? "exclamationmark.triangle" : "magnifyingglass"
            )
          } description: {
            Text(
              model.searchFailureCount > 0
                ? "全部源都没有返回结果。"
                : "换个关键词试试。"
            )
          } actions: {
            Button("重试", action: runSearch)
              .buttonStyle(.bordered)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 48)
        }
      }
      .padding(.vertical)
    }
  }

  private func runSearch() {
    let keyword = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !keyword.isEmpty else { return }
    searchFocused = false
    Task {
      await model.search()
    }
  }

  private func toggleHistorySelection(_ keyword: String) {
    if selectedHistory.contains(keyword) {
      selectedHistory.remove(keyword)
    } else {
      selectedHistory.insert(keyword)
    }
  }
}
