import SwiftUI
import UIKit

struct ConfigurationManagementView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    List {
      if model.sourceConnections.isEmpty {
        ContentUnavailableView(
          "还没有线路",
          systemImage: "link.badge.plus",
          description: Text("返回设置，通过「添加线路」粘贴配置地址。")
        )
        .listRowBackground(Color.clear)
      } else {
        Section {
          ForEach(model.sourceConnections) { connection in
            NavigationLink(value: SettingsDestination.connectionDetail(connection.url)) {
              HStack(spacing: 12) {
                Image(systemName: "link")
                  .foregroundStyle(.orange)
                  .frame(width: 22)
                MiddleTruncatingText(
                  text: connection.displayAddress,
                  font: .preferredFont(forTextStyle: .body).monospaced(),
                  textColor: .label
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                latencyBadge(for: connection)
                if model.currentConnection?.id == connection.id {
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.orange)
                }
              }
            }
            .swipeActions {
              Button(role: .destructive) {
                model.removeConnection(connection)
              } label: {
                Label("删除", systemImage: "trash")
              }
            }
          }
        } footer: {
          Text("点进线路可查看播放源并切换。列表延迟为配置地址测速（毫秒）。")
        }
      }
    }
    .navigationTitle("已添加的线路")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .refreshable {
      await model.probeAllConnectionLatencies()
    }
    .task {
      await model.probeAllConnectionLatencies()
    }
  }

  @ViewBuilder
  private func latencyBadge(for connection: SourceConnection) -> some View {
    if model.probingConnectionURLs.contains(connection.url) {
      ProgressView()
        .controlSize(.small)
    } else if let ms = model.connectionLatencyMS[connection.url] {
      Text("\(ms)ms")
        .font(.caption.monospacedDigit().weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.secondary.opacity(0.12), in: Capsule())
    } else {
      Text("—")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }
}

private extension UIFont {
  func monospaced() -> UIFont {
    UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
  }
}
