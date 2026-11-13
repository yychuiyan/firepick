import SwiftUI
import UIKit

enum SettingsDestination: Hashable {
  case lines
  case connectionDetail(String)
  case addConnection
  case sources
  case downloads
  case playback
}

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @State private var path = NavigationPath()
  @State private var showingClearCacheConfirmation = false

  var body: some View {
    NavigationStack(path: $path) {
      Form {
        linesSection
        downloadsSection
        playbackSection
        storageSection
        ProvisioningExpirySection()
      }
      .contentMargins(.top, 8, for: .scrollContent)
      .navigationTitle("设置")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: SettingsDestination.self) { destination in
        switch destination {
        case .lines:
          ConfigurationManagementView()
        case .connectionDetail(let url):
          if let connection = model.sourceConnections.first(where: { $0.url == url }) {
            ConnectionDetailView(connection: connection) {
              path = NavigationPath()
            }
          } else {
            ContentUnavailableView(
              "线路已删除",
              systemImage: "link.badge.plus",
              description: Text("返回线路列表重试。")
            )
          }
        case .addConnection:
          AddConnectionView()
        case .sources:
          SourceManagementView()
        case .downloads:
          LibraryView(mode: .downloads)
        case .playback:
          PlaybackSettingsView()
        }
      }
      .alert(
        "清理缓存？",
        isPresented: $showingClearCacheConfirmation
      ) {
        Button("清理", role: .destructive) {
          model.clearCache()
        }
        Button("取消", role: .cancel) {}
      } message: {
        Text("不会删除收藏、历史、源配置或本机下载文件。")
      }
      .onAppear {
        model.refreshCacheSize()
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active {
          model.refreshCacheSize()
        }
      }
    }
  }

  @ViewBuilder
  private var linesSection: some View {
    Section {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("当前线路")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(currentLineTitle)
            .foregroundStyle(.primary)
            .lineLimit(1)
          if let connection = model.currentConnection {
            MiddleTruncatingText(
              text: connection.displayAddress,
              font: .preferredFont(forTextStyle: .caption1).monospaced(),
              textColor: .secondaryLabel
            )
            .frame(height: 16)
          } else {
            Text("尚未选择")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        if let connection = model.currentConnection,
          let ms = model.connectionLatencyMS[connection.url]
        {
          Text("\(ms)ms")
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.secondary.opacity(0.12), in: Capsule())
        }
      }
      .accessibilityElement(children: .combine)

      if model.isSwitchingConnection {
        HStack(spacing: 8) {
          ProgressView()
          Text("正在切换线路…")
            .foregroundStyle(.secondary)
        }
      }

      NavigationLink(value: SettingsDestination.lines) {
        LabeledContent(
          "已添加的线路",
          value: "\(model.sourceConnections.count) 个"
        )
      }

      NavigationLink(value: SettingsDestination.addConnection) {
        Label("添加线路", systemImage: "plus.circle")
      }

      if !model.availableDepots.isEmpty {
        ForEach(model.availableDepots, id: \.url) { depot in
          Button {
            Task { await model.loadDepot(depot) }
          } label: {
            Label(
              depot.name.isEmpty ? depot.url : depot.name,
              systemImage: "shippingbox"
            )
          }
        }
      }

      NavigationLink(value: SettingsDestination.sources) {
        LabeledContent(
          "点播源管理",
          value: model.currentConnection == nil
            ? "—"
            : "\(model.configuration.sites.count)"
        )
      }
      .disabled(model.currentConnection == nil)

      if !model.configurationCandidates.isEmpty {
        ForEach(model.configurationCandidates) { candidate in
          Button {
            Task {
              _ = await model.applyConfiguration(
                urlString: candidate.url.absoluteString
              )
            }
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text("检测到的配置")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(candidate.url.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(2)
            }
          }
        }
      }
    } header: {
      Text("线路与源")
    } footer: {
      if let notice = model.configuration.notice?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !notice.isEmpty
      {
        Text(notice)
      }
    }
  }

  private var downloadsSection: some View {
    Section("本机") {
      NavigationLink(value: SettingsDestination.downloads) {
        LabeledContent(
          "本机下载",
          value: "\(model.downloads?.entries.count ?? 0)"
        )
      }
    }
  }

  private var playbackSection: some View {
    Section("播放") {
      NavigationLink(value: SettingsDestination.playback) {
        LabeledContent(
          "播放设置",
          value: model.playbackPreference.title
        )
      }
      NavigationLink {
        DanmakuSettingsView()
      } label: {
        LabeledContent(
          "弹幕设置",
          value: model.danmakuEnabledByDefault ? "默认开" : "默认关"
        )
      }
    }
  }

  private var storageSection: some View {
    Section("存储与关于") {
      Button {
        showingClearCacheConfirmation = true
      } label: {
        HStack {
          Text("清理缓存")
            .foregroundStyle(.red)
          Spacer()
          Text(model.cacheSizeText)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
      .buttonStyle(.plain)
      .contentShape(Rectangle())
      if let status = model.cacheStatus {
        Text(status)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var currentLineTitle: String {
    if let site = model.selectedSite {
      let name = site.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty { return name }
    }
    if let notice = model.configuration.notice?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !notice.isEmpty
    {
      return notice
    }
    if let connection = model.currentConnection {
      let name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty { return name }
    }
    return "尚未选择"
  }
}

private extension UIFont {
  func monospaced() -> UIFont {
    UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
  }
}
