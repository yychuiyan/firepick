import FirepickCore
import FirepickPlayback
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
  enum Mode: String, Identifiable {
    case favorites
    case history
    case downloads

    var id: String { rawValue }
    var title: String {
      switch self {
      case .favorites: "我的收藏"
      case .history: "最近观看"
      case .downloads: "本机下载"
      }
    }
  }

  @Environment(AppModel.self) private var model
  let mode: Mode
  @State private var selectedItem: MediaItem?
  @State private var selectedOffline: OfflineMedia?
  @State private var showingImporter = false
  @State private var showingClearConfirmation = false
  @State private var isClearing = false
  @State private var resumingID: String?

  private var columns: [GridItem] {
    [
      GridItem(
        .adaptive(minimum: model.posterSizePreference.minimumWidth, maximum: 240),
        spacing: 14
      )
    ]
  }

  var body: some View {
    Group {
      if mode == .downloads {
        downloadsList
      } else {
        posterGrid
      }
    }
    .overlay {
      if mode == .history && model.history.isEmpty
        || mode == .favorites && model.favorites.isEmpty
        || mode == .downloads && (model.downloads?.entries.isEmpty ?? true)
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
    .toolbar {
      if mode == .downloads {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showingImporter = true
          } label: {
            Image(systemName: "plus")
          }
        }
      } else if canClear {
        ToolbarItem(placement: .topBarTrailing) {
          Button("清空", role: .destructive) {
            showingClearConfirmation = true
          }
          .disabled(isClearing)
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
    .fileImporter(
      isPresented: $showingImporter,
      allowedContentTypes: [.movie, .video],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first else { return }
        do {
          try model.downloads?.importFile(from: url)
        } catch {
          model.errorMessage = error.localizedDescription
        }
      case .failure(let error):
        model.errorMessage = error.localizedDescription
      }
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
    .fullScreenCover(item: $selectedOffline) { entry in
      if let request = model.downloads?.playbackRequest(for: entry) {
        PlayerView(
          request: request,
          item: MediaItem(
            vodId: entry.vodId,
            name: entry.title,
            sourceKey: entry.sourceKey
          ),
          episode: Episode(
            name: entry.episodeName,
            value: entry.episodeId
          )
        )
      }
    }
  }

  private var posterGrid: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: 18) {
        if mode == .history {
          ForEach(model.history) { entry in
            Button {
              Task {
                resumingID = entry.id
                defer { resumingID = nil }
                if await model.resumeFromHistory(entry) {
                  return
                }
                model.detailResult = nil
                selectedItem = entry.item
              }
            } label: {
              MediaCardView(
                item: entry.item,
                progress: entry.duration > 0
                  ? min(1, max(0, entry.position / entry.duration))
                  : nil,
                subtitle: "\(entry.episodeName) · \(format(entry.position))"
              )
              .overlay {
                if resumingID == entry.id {
                  ZStack {
                    Color.black.opacity(0.25)
                    ProgressView().tint(.white)
                  }
                  .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
              }
            }
            .buttonStyle(.plain)
            .disabled(resumingID != nil)
            .contextMenu {
              Button("打开详情") {
                model.detailResult = nil
                selectedItem = entry.item
              }
              Button("删除", role: .destructive) {
                Task { await model.removeHistory(entry) }
              }
            }
          }
        } else {
          ForEach(model.favorites) { entry in
            Button {
              model.detailResult = nil
              selectedItem = entry.item
            } label: {
              MediaCardView(item: entry.item)
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

  private var downloadsList: some View {
    List {
      ForEach(model.downloads?.entries ?? []) { entry in
        Button {
          if entry.status == .completed {
            selectedOffline = entry
          }
        } label: {
          VStack(alignment: .leading, spacing: 5) {
            Text(entry.title)
            HStack {
              Text(entry.episodeName)
              Spacer()
              downloadStatus(entry)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if entry.status == .downloading {
              ProgressView(value: entry.progress)
            }
            if let error = entry.error {
              Text(error)
                .font(.caption2)
                .foregroundStyle(.red)
            }
          }
        }
        .buttonStyle(.plain)
        .swipeActions {
          Button("删除", role: .destructive) {
            model.downloads?.remove(id: entry.id)
          }
          if entry.status == .downloading {
            Button("暂停") {
              model.downloads?.pause(id: entry.id)
            }
          } else if entry.status != .completed {
            Button("重试") {
              model.downloads?.retry(id: entry.id)
            }
          }
        }
      }
    }
  }

  private var canClear: Bool {
    switch mode {
    case .favorites: !model.favorites.isEmpty
    case .history: !model.history.isEmpty
    case .downloads: false
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

  @ViewBuilder
  private func downloadStatus(_ entry: OfflineMedia) -> some View {
    switch entry.status {
    case .queued:
      Text("等待中")
    case .downloading:
      Text("\(Int(entry.progress * 100))%")
    case .paused:
      Text("已暂停")
    case .completed:
      Text(ByteCountFormatter.string(fromByteCount: entry.fileSize, countStyle: .file))
    case .failed:
      Text("失败")
    }
  }

  private var emptyTitle: String {
    switch mode {
    case .favorites: "还没有收藏"
    case .history: "还没有播放记录"
    case .downloads: "还没有下载"
    }
  }

  private var emptyIcon: String {
    switch mode {
    case .favorites: "heart"
    case .history: "clock"
    case .downloads: "arrow.down.circle"
    }
  }

  private var emptyDescription: String {
    switch mode {
    case .favorites: "在详情页点收藏后会出现在这里。"
    case .history: "播放过的内容会显示在这里。"
    case .downloads: "在播放器中下载，或从“文件”导入本地视频。"
    }
  }

  private func format(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00" }
    let value = Int(seconds)
    return String(format: "%02d:%02d", value / 60, value % 60)
  }
}
