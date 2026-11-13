import FirepickCore
import SwiftUI

struct SourcePickerView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  private var sources: [SiteConfiguration] {
    let sites = model.configuration.sites
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
        if sources.isEmpty {
          ContentUnavailableView(
            "没有匹配的点播源",
            systemImage: "magnifyingglass",
            description: Text("换一个名称、标识或地址关键词。")
          )
          .listRowBackground(Color.clear)
        } else {
          Section {
            ForEach(sources) { site in
              Button {
                Task {
                  await model.selectSite(site)
                  dismiss()
                }
              } label: {
                HStack(alignment: .top, spacing: 12) {
                  VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                      Text(site.name)
                        .foregroundStyle(.primary)
                      if site.isHidden {
                        Text("已隐藏")
                          .font(.caption2)
                          .foregroundStyle(.secondary)
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
              .disabled(site.isHidden)
              .opacity(site.isHidden ? 0.55 : 1)
            }
          } footer: {
            Text("点播源来自当前配置地址，共 \(model.configuration.sites.count) 个。")
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
}
