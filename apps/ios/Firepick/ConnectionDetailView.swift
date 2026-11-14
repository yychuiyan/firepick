import FirepickCore
import SwiftUI

struct ConnectionDetailView: View {
  @Environment(AppModel.self) private var model
  let connection: SourceConnection
  var onSwitched: (() -> Void)?

  @State private var preview: VodConfiguration?
  @State private var loadError: String?
  @State private var siteLatencies: [String: Int] = [:]
  @State private var switchError: String?

  private var isCurrent: Bool {
    model.currentConnection?.id == connection.id
  }

  private var liveConnection: SourceConnection {
    model.sourceConnections.first { $0.id == connection.id } ?? connection
  }

  var body: some View {
    List {
      Section {
        Text(connection.displayAddress)
          .font(.footnote.monospaced())
          .textSelection(.enabled)
        Toggle(
          "启用",
          isOn: Binding(
            get: { liveConnection.enabled },
            set: { enabled in
              Task { await model.setConnectionEnabled(liveConnection, enabled: enabled) }
            }
          )
        )
      } header: {
        Text("线路")
      } footer: {
        Text(
          liveConnection.enabled
            ? "关闭后这条线路不会被选为当前线路。线路本身不做测速；采集站延迟在「采集站管理」查看。"
            : "已禁用。打开后才能切换到这条线路。"
        )
      }

      if let loadError {
        Section {
          Text(loadError)
            .foregroundStyle(.red)
          Button("重试") { Task { await loadPreview() } }
        }
      } else if let preview {
        let stations = model.collectionStations(in: preview)
        overviewSection(preview: preview, stationCount: stations.count)

        Section {
          ForEach(preview.sites, id: \.key) { site in
            let displayName =
              site.name.trimmingCharacters(in: .whitespacesAndNewlines) == "拾萤"
              ? "拾萤精选"
              : site.name
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                Text(model.routeLabel(for: site))
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(site.api)
                  .font(.caption2.monospaced())
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
              }
              Spacer(minLength: 8)
              if let ms = siteLatencies[site.key] {
                Text("\(ms) ms")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }
          }
        } header: {
          Text("点播源 · \(preview.sites.count)")
        } footer: {
          Text("配置仓里的站（如拾萤精选）。延迟为静默探测；采集站列表与测速见「采集站管理」。")
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
            if model.userInitiatedConnectionSwitch {
              ProgressView()
            }
            Text(
              liveConnection.enabled
                ? (isCurrent ? "刷新此线路" : "切换到此线路")
                : "线路已禁用"
            )
              .frame(maxWidth: .infinity)
          }
        }
        .disabled(model.isSwitchingConnection || !liveConnection.enabled)
      }
    }
    .navigationTitle(connection.name)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await loadPreview()
      await probeSitesSilently()
    }
  }

  @ViewBuilder
  private func overviewSection(preview: VodConfiguration, stationCount: Int) -> some View {
    Section {
      LabeledContent("点播源", value: "\(preview.sites.count) 个")
      LabeledContent("采集站", value: "\(stationCount) 个")
      if isCurrent {
        LabeledContent(
          "电视",
          value: "\(model.liveGroups.count) 组 · \(model.liveChannelCount) 频道"
        )
        if model.hiddenSiteCount > 0 {
          LabeledContent("已隐藏点播源", value: "\(model.hiddenSiteCount) 个")
        }
        if let site = model.selectedSite {
          let siteName =
            site.name.trimmingCharacters(in: .whitespacesAndNewlines) == "拾萤"
            ? "拾萤精选"
            : site.name
          LabeledContent("当前点播源", value: siteName)
          LabeledContent("执行路径", value: model.routeLabel(for: site))
        }
      } else if let lives = preview.lives, !lives.isEmpty {
        LabeledContent("直播配置", value: "\(lives.count) 组")
      }
    } header: {
      Text("概况")
    } footer: {
      Text(
        isCurrent
          ? "当前线路的点播与电视概况。采集站明细与测速在「采集站管理」。"
          : "切换到此线路后可看到电视频道数；采集站测速在「采集站管理」。"
      )
    }
  }

  private func loadPreview() async {
    loadError = nil
    do {
      preview = try await model.previewConfiguration(for: connection)
    } catch {
      loadError = error.localizedDescription
      preview = nil
    }
  }

  private func probeSitesSilently() async {
    guard let sites = preview?.sites, !sites.isEmpty else { return }
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
