import SwiftUI
import UIKit

enum SettingsDestination: Hashable {
  case lines
  case connectionDetail(String)
  case addConnection
  case sources
  case playback
  case aiEnhancement
  case websiteShortcuts
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
        playbackSection
        contentSection
        aiSection
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
        case .playback:
          PlaybackSettingsView()
        case .aiEnhancement:
          AIEnhancementSettingsView()
        case .websiteShortcuts:
          WebsiteShortcutSettingsView()
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
        Text("不会删除收藏、历史或源配置。")
      }
      .onAppear {
        model.refreshCacheSize()
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active {
          model.refreshCacheSize()
          Task { await model.maybeAutoProbeCollectionStations() }
        }
      }
    }
  }

  @ViewBuilder
  private var linesSection: some View {
    Section {
      if let connection = model.currentConnection {
        VStack(alignment: .leading, spacing: 4) {
          Text("当前线路")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(currentLineTitle)
            .foregroundStyle(.primary)
            .lineLimit(1)
          MiddleTruncatingText(
            text: connection.displayAddress,
            font: .preferredFont(forTextStyle: .caption1).monospaced(),
            textColor: .secondaryLabel
          )
          .frame(height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
      } else {
        LabeledContent("当前线路", value: "尚未选择")
      }

      // Only after user taps 切换/添加 — silent restore/auto-update stays quiet.
      if model.userInitiatedConnectionSwitch {
        HStack(spacing: 8) {
          ProgressView()
          Text("正在切换线路…")
            .foregroundStyle(.secondary)
        }
      }

      NavigationLink(value: SettingsDestination.lines) {
        Text("线路管理")
      }

      NavigationLink(value: SettingsDestination.addConnection) {
        Text("添加线路")
      }

      if model.currentConnection == nil {
        Button("使用拾萤精选") {
          Task { await model.applyOfficialSource() }
        }
        .disabled(model.isSwitchingConnection)
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
          "采集站管理",
          value: model.currentConnection == nil
            ? "—"
            : model.collectionStationSummary
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
      NavigationLink {
        LiveSourceManagementView()
      } label: {
        LabeledContent(
          "直播源",
          value: model.standaloneLiveSourceSummary
        )
      }
    }
  }

  private var contentSection: some View {
    Section("内容") {
      NavigationLink {
        ContentModeSettingsView()
      } label: {
        LabeledContent(
          "内容模式",
          value: model.contentMode.title
        )
      }
      NavigationLink(value: SettingsDestination.websiteShortcuts) {
        LabeledContent(
          "接口配置",
          value: model.websiteShortcuts.isEmpty
            ? "未添加"
            : "\(model.websiteShortcuts.count) 个"
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

  private var aiSection: some View {
    Section("智能") {
      NavigationLink(value: SettingsDestination.aiEnhancement) {
        LabeledContent(
          "AI 增强",
          value: model.aiEnhancementEnabled ? "已开启" : "关闭"
        )
      }
    }
  }

  private var currentLineTitle: String {
    if let notice = model.configuration.notice?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !notice.isEmpty
    {
      return notice == "拾萤" ? "拾萤精选" : notice
    }
    if let connection = model.currentConnection {
      let name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty {
        return name == "拾萤" ? "拾萤精选" : name
      }
    }
    return "尚未选择"
  }
}

private struct ContentModeSettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var showingAdultModeConfirmation = false

  var body: some View {
    Form {
      Section {
        Toggle(isOn: .constant(true)) {
          Label("标准模式", systemImage: "checkmark.shield")
        }
        .disabled(true)
      } footer: {
        Text("标准模式默认开启且不可关闭。成人线路不会参与测速、推荐、分类、搜索、详情或播放。")
      }

      Section {
        Toggle(isOn: adultModeBinding) {
          Label("成人模式", systemImage: "exclamationmark.shield")
        }
        .tint(.red)
      } footer: {
        Text(
          model.contentMode == .adult
            ? "成人线路已完全放开，并集中显示在“成人”菜单。"
            : "默认关闭。开启后，成人线路将参与测速、成人菜单、搜索、详情和播放。"
        )
      }
    }
    .navigationTitle("内容模式")
    .navigationBarTitleDisplayMode(.inline)
    .alert(
      "开启成人模式？",
      isPresented: $showingAdultModeConfirmation
    ) {
      Button("开启", role: .destructive) {
        Task { await model.setContentMode(.adult) }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("成人线路将参与测速、成人菜单、搜索、详情和播放。最佳线路会在后台更新，不会重载当前菜单。")
    }
  }

  private var adultModeBinding: Binding<Bool> {
    Binding(
      get: { model.contentMode == .adult },
      set: { enabled in
        if enabled {
          showingAdultModeConfirmation = true
          return
        }
        Task { await model.setContentMode(.standard) }
      }
    )
  }
}

private extension UIFont {
  func monospaced() -> UIFont {
    UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
  }
}
