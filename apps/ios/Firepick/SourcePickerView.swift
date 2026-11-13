import FirepickCore
import SwiftUI

struct SourcePickerView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  private var onDeviceSources: [SiteConfiguration] {
    filtered(model.onDeviceSites)
  }

  private var bridgeOnlySources: [SiteConfiguration] {
    filtered(model.bridgeOnlySites)
  }

  private func filtered(_ sites: [SiteConfiguration]) -> [SiteConfiguration] {
    guard !query.isEmpty else { return sites }
    return sites.filter {
      $0.name.localizedCaseInsensitiveContains(query)
        || $0.key.localizedCaseInsensitiveContains(query)
        || $0.api.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    NavigationStack {
      List {
        if onDeviceSources.isEmpty, bridgeOnlySources.isEmpty {
          ContentUnavailableView(
            "没有匹配的点播源",
            systemImage: "magnifyingglass",
            description: Text("换一个名称、标识或地址关键词。")
          )
          .listRowBackground(Color.clear)
        } else {
          if !onDeviceSources.isEmpty {
            Section("本机可用") {
              ForEach(onDeviceSources) { site in
                siteButton(site, enabled: true)
              }
            }
          }

          if !bridgeOnlySources.isEmpty {
            Section {
              ForEach(bridgeOnlySources) { site in
                siteButton(site, enabled: false)
              }
            } header: {
              Text("需安卓运行时")
            } footer: {
              Text("这些 Java/Python 等源当前不可用。请改用本机 HTTP/JS，或自建 iOS 配置仓。")
            }
          }

          Section {
            EmptyView()
          } footer: {
            Text(
              "本机 \(model.onDeviceSites.count) · 需安卓 \(model.bridgeOnlySites.count) · 合计 \(model.configuration.sites.count)"
            )
          }
        }
      }
      .navigationTitle("选择点播源")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, prompt: "搜索名称、标识或地址")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { dismiss() }
        }
      }
    }
  }

  @ViewBuilder
  private func siteButton(_ site: SiteConfiguration, enabled: Bool) -> some View {
    Button {
      Task {
        await model.selectSite(site)
        if model.selectedSite?.key == site.key {
          dismiss()
        }
      }
    } label: {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 6) {
            Text(site.name)
              .foregroundStyle(enabled ? .primary : .secondary)
            if site.isHidden {
              Text("已隐藏")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if !enabled {
              Text("不可用")
                .font(.caption2)
                .foregroundStyle(.orange)
            }
          }
          Text(model.routeLabel(for: site))
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(site.api)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        if model.selectedSite?.key == site.key {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.orange)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled || site.isHidden)
    .opacity((!enabled || site.isHidden) ? 0.55 : 1)
  }
}
