import FirepickCore
import FirepickPlayback
import SwiftUI

struct SearchView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @FocusState private var searchFocused: Bool
  @State private var selectedItem: MediaItem?
  @State private var selectedLive: LiveChannel?
  @State private var selectedHistory = Set<String>()
  @State private var isEditingHistory = false
  @State private var showingDeleteConfirmation = false

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      VStack(spacing: 0) {
        searchBar
        Divider()

        if !model.searchHasRun, !model.isLoading {
          historyContent
        } else {
          resultsContent
        }
      }
      .toolbar(.hidden, for: .navigationBar)
      .task {
        resetForNewSearch()
        try? await Task.sleep(for: .milliseconds(250))
        searchFocused = true
      }
      .sheet(item: $selectedItem) { item in
        DetailView(item: item)
      }
      .fullScreenCover(item: $selectedLive) { channel in
        if let url = channel.playableURL {
          PlayerView(
            request: PlaybackRequest(url: url, headers: channel.headers),
            item: MediaItem(
              vodId: channel.id,
              name: channel.name,
              sourceKey: "live"
            ),
            episode: nil,
            alternateURLs: channel.urls.dropFirst().compactMap(URL.init(string:))
          )
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

      Button("查询", action: runSearch)
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(
          model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.isLoading
        )

      Button("取消") {
        searchFocused = false
        dismiss()
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
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
        description: Text("输入片名、剧名或演员后点击查询。")
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
    List {
      if model.isLoading {
        ProgressView()
          .frame(maxWidth: .infinity)
          .listRowSeparator(.hidden)
      }
      if !model.liveSearchResults.isEmpty {
        Section("直播") {
          ForEach(model.liveSearchResults) { channel in
            Button {
              selectedLive = channel
            } label: {
              Text(channel.name)
            }
          }
        }
      }
      ForEach(model.searchSections) { section in
        Section(section.siteName) {
          ForEach(section.result.list) { item in
            Button {
              selectedItem = item
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                if let remarks = item.remarks {
                  Text(remarks)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      }
    }
    .listStyle(.plain)
    .overlay {
      if !model.isLoading, model.searchSections.isEmpty,
        model.liveSearchResults.isEmpty
      {
        Text("没有找到结果")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
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

  private func resetForNewSearch() {
    model.searchText = ""
    model.searchHasRun = false
    model.searchSections = []
    model.liveSearchResults = []
    selectedHistory.removeAll()
    isEditingHistory = false
  }

  private func toggleHistorySelection(_ keyword: String) {
    if selectedHistory.contains(keyword) {
      selectedHistory.remove(keyword)
    } else {
      selectedHistory.insert(keyword)
    }
  }
}
