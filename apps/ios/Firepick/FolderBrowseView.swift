import FirepickCore
import SwiftUI

struct FolderBrowseView: View {
  @Environment(AppModel.self) private var model
  let folder: MediaItem

  @State private var result: MediaResult?
  @State private var isLoading = true
  @State private var selectedItem: MediaItem?
  /// Kept across pop so destination does not become EmptyView mid-transition (闪白).
  @State private var detailDestination: MediaItem?
  @State private var nestedFolder: MediaItem?

  private var columns: [GridItem] {
    [
      GridItem(
        .adaptive(minimum: model.posterSizePreference.minimumWidth, maximum: 240),
        spacing: 14
      )
    ]
  }

  var body: some View {
    ScrollView {
      if isLoading {
        ProgressView("正在打开文件夹…")
          .frame(maxWidth: .infinity)
          .padding(.vertical, 48)
      } else if let items = result?.list, !items.isEmpty {
        LazyVGrid(columns: columns, spacing: 18) {
          ForEach(items) { item in
            Button {
              Task {
                if item.isAction {
                  await model.performAction(item)
                } else if item.isFolder {
                  nestedFolder = item
                } else {
                  model.detailResult = nil
                  detailDestination = item
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
          }
        }
        .padding()
      } else {
        ContentUnavailableView(
          "文件夹是空的",
          systemImage: "folder",
          description: Text(model.errorMessage ?? "没有可显示的内容。")
        )
        .padding(.vertical, 48)
      }
    }
    .navigationTitle(folder.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .task(id: folder.vodId) {
      isLoading = true
      defer { isLoading = false }
      result = await model.loadFolder(folder)
    }
    .navigationDestination(
      isPresented: Binding(
        get: { selectedItem != nil },
        set: { if !$0 { selectedItem = nil } }
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
        get: { nestedFolder != nil },
        set: { if !$0 { nestedFolder = nil } }
      )
    ) {
      if let nestedFolder {
        FolderBrowseView(folder: nestedFolder)
      } else {
        FirepickBackdrop()
      }
    }
  }
}
