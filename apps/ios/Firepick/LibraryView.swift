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

  var body: some View {
    List {
      if mode == .history {
        if !model.history.isEmpty {
          ForEach(model.history) { entry in
            Button {
              selectedItem = entry.item
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(entry.item.name)
                Text("\(entry.episodeName) · \(format(entry.position))")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .buttonStyle(.plain)
            .swipeActions {
              Button("删除", role: .destructive) {
                Task { await model.removeHistory(entry) }
              }
            }
          }
        }

      } else if mode == .favorites {
        if !model.favorites.isEmpty {
          ForEach(model.favorites) { entry in
            Button(entry.item.name) {
              selectedItem = entry.item
            }
            .buttonStyle(.plain)
            .swipeActions {
              Button("取消收藏", role: .destructive) {
                Task { await model.removeFavorite(entry) }
              }
            }
          }
        }
      } else {
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
      }
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
    .sheet(item: $selectedItem) { item in
      DetailView(item: item)
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
    case .favorites: "点播页中的内容会显示在这里。"
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
