import FirepickCore
import SwiftUI

struct LibraryView: View {
  enum Mode: String, Identifiable {
    case favorites
    case history

    var id: String { rawValue }
    var title: String {
      switch self {
      case .favorites: "我的收藏"
      case .history: "最近观看"
      }
    }
  }

  @Environment(AppModel.self) private var model
  let mode: Mode
  @State private var selectedItem: MediaItem?
  /// Kept across pop so destination does not become EmptyView mid-transition (闪白).
  @State private var detailDestination: MediaItem?
  @State private var showingClearConfirmation = false
  @State private var isClearing = false

  private var columns: [GridItem] {
    let count = model.posterSizePreference == .large ? 2 : 3
    return Array(repeating: GridItem(.flexible(minimum: 0), spacing: 10), count: count)
  }

  var body: some View {
    posterGrid
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground).ignoresSafeArea())
    .overlay {
      if mode == .history && model.libraryHistoryPrograms.isEmpty
        || mode == .favorites && model.libraryFavoritePrograms.isEmpty
      {
        ContentUnavailableView(
          emptyTitle,
          systemImage: emptyIcon,
          description: Text(emptyDescription)
        )
      }
    }
    .navigationTitle(mode.title)
    .toolbar(.visible, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .toolbarBackground(Color(.systemBackground), for: .navigationBar)
    .toolbar {
      if canClear {
        ToolbarItem(placement: .topBarTrailing) {
          Button(role: .destructive) {
            showingClearConfirmation = true
          } label: {
            Image(systemName: "trash")
          }
          .disabled(isClearing)
          .accessibilityLabel("清空")
        }
      }
    }
    .alert(clearTitle, isPresented: $showingClearConfirmation) {
      Button("清空", role: .destructive) {
        Task { await clearAll() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(clearMessage)
    }
    .task(id: mode) {
      // Warm covers immediately — favorites/history pics are often cold CDN URLs.
      let items: [MediaItem] = {
        switch mode {
        case .favorites:
          return model.libraryFavoritePrograms.map { model.libraryDisplayItem(from: $0.item) }
        case .history:
          return model.libraryHistoryPrograms.map { model.libraryDisplayItem(from: $0.item) }
        }
      }()
      PosterPrefetch.warm(items: items, limit: 24)
    }
    .navigationDestination(
      isPresented: Binding(
        get: { selectedItem != nil },
        set: { presented in
          if !presented { selectedItem = nil }
        }
      )
    ) {
      // Never clear detailDestination here — empty destination paints white during pop.
      if let detailDestination {
        DetailView(item: detailDestination)
      } else {
        FirepickBackdrop()
      }
    }
  }

  private func openDetail(_ item: MediaItem) {
    detailDestination = item
    selectedItem = item
  }

  private var posterGrid: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: 12) {
        if mode == .history {
          // One card per programme — not per 线路 / 每一集.
          ForEach(model.libraryHistoryPrograms) { entry in
            let display = model.libraryDisplayItem(from: entry.item)
            Button {
              // Same Detail + inline player as browse — not RootView fullScreenCover.
              model.detailResult = nil
              openDetail(entry.item)
            } label: {
              MediaCardView(
                item: display,
                progress: entry.duration > 0
                  ? min(1, max(0, entry.position / entry.duration))
                  : nil,
                subtitle: "\(entry.episodeName) · \(format(entry.position))"
              )
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button("打开详情") {
                model.detailResult = nil
                openDetail(entry.item)
              }
              Button("删除", role: .destructive) {
                Task { await model.removeHistory(entry) }
              }
            }
          }
        } else {
          ForEach(model.libraryFavoritePrograms) { entry in
            let display = model.libraryDisplayItem(from: entry.item)
            Button {
              model.detailResult = nil
              openDetail(entry.item)
            } label: {
              MediaCardView(item: display)
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button("取消收藏", role: .destructive) {
                Task { await model.removeFavorite(entry) }
              }
            }
          }
        }
      }
      .padding()
    }
  }

  private var canClear: Bool {
    switch mode {
    case .favorites: !model.libraryFavoritePrograms.isEmpty
    case .history: !model.libraryHistoryPrograms.isEmpty
    }
  }

  private var clearTitle: String {
    mode == .favorites ? "清空收藏？" : "清空观看记录？"
  }

  private var clearMessage: String {
    mode == .favorites
      ? "将移除全部本机收藏，此操作不可撤销。"
      : "将清除全部本机观看记录，此操作不可撤销。"
  }

  private func clearAll() async {
    isClearing = true
    defer { isClearing = false }
    if mode == .favorites {
      await model.clearAllFavorites()
    } else if mode == .history {
      await model.clearAllHistory()
    }
  }

  private var emptyTitle: String {
    switch mode {
    case .favorites: "还没有收藏"
    case .history: "还没有播放记录"
    }
  }

  private var emptyIcon: String {
    switch mode {
    case .favorites: "heart"
    case .history: "clock"
    }
  }

  private var emptyDescription: String {
    switch mode {
    case .favorites: "在详情页点收藏后会出现在这里。"
    case .history: "播放过的内容会显示在这里。"
    }
  }

  private func format(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00" }
    let value = Int(seconds)
    return String(format: "%02d:%02d", value / 60, value % 60)
  }
}
