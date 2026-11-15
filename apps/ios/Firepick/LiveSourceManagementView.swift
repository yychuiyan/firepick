import FirepickCore
import SwiftUI

struct LiveSourceManagementView: View {
  @Environment(AppModel.self) private var model
  @State private var showingAddSource = false

  var body: some View {
    List {
      if model.standaloneLiveSources.isEmpty {
        ContentUnavailableView {
          Label("还没有独立直播源", systemImage: "tv")
        } description: {
          Text("添加 M3U、TXT 或包含 lives 的 JSON 直播配置。不会替换当前点播线路。")
        } actions: {
          Button("添加直播源") { showingAddSource = true }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .listRowBackground(Color.clear)
      } else {
        Section {
          ForEach(Array(model.standaloneLiveSources.enumerated()), id: \.offset) { _, source in
            VStack(alignment: .leading, spacing: 4) {
              Text(source.name)
                .font(.body.weight(.medium))
              Text(source.url ?? source.api ?? "内嵌频道")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            .swipeActions {
              Button(role: .destructive) {
                Task { await model.removeStandaloneLiveSource(source) }
              } label: {
                Label("删除", systemImage: "trash")
              }
            }
          }
        } footer: {
          Text("这些频道会与当前点播线路中的 lives 合并。切换点播线路不会删除这里添加的直播源。")
        }
      }

      if let status = model.liveRefreshStatus {
        Section {
          Text(status)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle("直播源管理")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          Task { await model.refreshStandaloneLiveSources() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(model.standaloneLiveSources.isEmpty || model.isLoadingLive)

        Button {
          showingAddSource = true
        } label: {
          Image(systemName: "plus")
        }
      }
    }
    .sheet(isPresented: $showingAddSource) {
      AddLiveSourceSheet()
    }
  }
}

private struct AddLiveSourceSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var urlText = ""
  @State private var isSaving = false
  @State private var errorText: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("https://…/live.m3u", text: $urlText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        } footer: {
          Text("支持 M3U、TXT、JSON lives 配置。添加后会与当前点播线路的直播频道合并。")
        }

        if let errorText {
          Section {
            Text(errorText)
              .font(.footnote)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("添加直播源")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            add()
          } label: {
            if isSaving {
              ProgressView()
            } else {
              Text("添加")
            }
          }
          .disabled(
            isSaving
              || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
        }
      }
    }
  }

  private func add() {
    let value = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    isSaving = true
    errorText = nil
    Task {
      let ok = await model.addStandaloneLiveSource(urlString: value)
      isSaving = false
      if ok {
        dismiss()
      } else {
        errorText = model.errorMessage ?? "直播源添加失败"
      }
    }
  }
}
