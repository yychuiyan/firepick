import FirepickCore
import SwiftUI

struct ConnectionDetailView: View {
  @Environment(AppModel.self) private var model
  let connection: SourceConnection
  var onSwitched: (() -> Void)?

  @State private var preview: VodConfiguration?
  @State private var loadError: String?
  @State private var isLoadingPreview = false
  @State private var siteLatencies: [String: Int] = [:]
  @State private var isProbingSites = false
  @State private var switchError: String?

  private var isCurrent: Bool {
    model.currentConnection?.id == connection.id
  }

  var body: some View {
    List {
      Section {
        Text(connection.displayAddress)
          .font(.footnote.monospaced())
          .textSelection(.enabled)
        HStack {
          Text("线路延迟")
          Spacer()
          if let ms = model.connectionLatencyMS[connection.url] {
            Text("\(ms) ms")
              .foregroundStyle(.secondary)
              .monospacedDigit()
          } else if model.probingConnectionURLs.contains(connection.url) {
            ProgressView()
          } else {
            Text("—")
              .foregroundStyle(.secondary)
          }
        }
        Button("重新测速") {
          Task { await model.probeConnectionLatency(connection) }
        }
      } header: {
        Text("线路")
      }

      if isLoadingPreview {
        Section {
          HStack {
            ProgressView()
            Text("正在读取播放源…")
              .foregroundStyle(.secondary)
          }
        }
      } else if let loadError {
        Section {
          Text(loadError)
            .foregroundStyle(.red)
          Button("重试") { Task { await loadPreview() } }
        }
      } else if let preview {
        Section("播放源 · \(preview.sites.count)") {
          ForEach(preview.sites, id: \.key) { site in
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(site.name)
                Text(site.api)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer()
              if let ms = siteLatencies[site.key] {
                Text("\(ms) ms")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
        if let lives = preview.lives, !lives.isEmpty {
          Section("直播") {
            Text("\(lives.count) 组直播源")
              .foregroundStyle(.secondary)
          }
        }
      }

      if let switchError {
        Section {
          Text(switchError)
            .foregroundStyle(.red)
        }
      }

      Section {
        Button {
          Task { await switchToConnection() }
        } label: {
          HStack {
            if model.isSwitchingConnection {
              ProgressView()
            }
            Text(isCurrent ? "刷新此线路" : "切换到此线路")
              .frame(maxWidth: .infinity)
          }
        }
        .disabled(model.isSwitchingConnection)
      }
    }
    .navigationTitle(connection.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(isProbingSites ? "测速中…" : "测播放源") {
          Task { await probeSites() }
        }
        .disabled(isProbingSites || preview?.sites.isEmpty != false)
      }
    }
    .task { await loadPreview() }
  }

  private func loadPreview() async {
    isLoadingPreview = true
    loadError = nil
    defer { isLoadingPreview = false }
    do {
      preview = try await model.previewConfiguration(for: connection)
    } catch {
      loadError = error.localizedDescription
      preview = nil
    }
  }

  private func probeSites() async {
    guard let sites = preview?.sites, !sites.isEmpty else { return }
    isProbingSites = true
    defer { isProbingSites = false }
    siteLatencies = await model.probeSiteLatencies(sites)
  }

  private func switchToConnection() async {
    switchError = nil
    await model.loadConnection(connection)
    if model.currentConnection?.id == connection.id {
      onSwitched?()
    } else if let message = model.errorMessage {
      switchError = message
    } else {
      switchError = "切换失败，请稍后重试"
    }
  }
}
