import SwiftUI
import UIKit

struct ConfigurationManagementView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    List {
      if model.sourceConnections.isEmpty {
        ContentUnavailableView {
          Label("还没有线路", systemImage: "link.badge.plus")
        } description: {
          Text("粘贴配置地址后，这条线路会出现在这里。")
        } actions: {
          NavigationLink(value: SettingsDestination.addConnection) {
            Text("添加线路")
          }
          .buttonStyle(.borderedProminent)
          .tint(.orange)
        }
        .listRowBackground(Color.clear)
      } else {
        Section {
          ForEach(model.sourceConnections) { connection in
            HStack(spacing: 12) {
              NavigationLink(value: SettingsDestination.connectionDetail(connection.url)) {
                HStack(spacing: 12) {
                  Image(systemName: "link")
                    .foregroundStyle(connection.enabled ? .orange : .secondary)
                    .frame(width: 22)
                  VStack(alignment: .leading, spacing: 2) {
                    MiddleTruncatingText(
                      text: connection.displayAddress,
                      font: .preferredFont(forTextStyle: .body).monospaced(),
                      textColor: connection.enabled ? .label : .secondaryLabel
                    )
                    if !connection.enabled {
                      Text("已禁用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  latencyBadge(for: connection)
                  if model.currentConnection?.id == connection.id {
                    Image(systemName: "checkmark.circle.fill")
                      .foregroundStyle(.orange)
                  }
                }
              }
              Toggle(
                "启用",
                isOn: Binding(
                  get: { connection.enabled },
                  set: { enabled in
                    Task { await model.setConnectionEnabled(connection, enabled: enabled) }
                  }
                )
              )
              .labelsHidden()
              .fixedSize()
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
          Text("点进线路可查看播放源并切换。关闭开关即禁用，当前线路被禁用时会改用下一条。列表延迟为配置地址测速（毫秒）。")
        }
      }
    }
    .navigationTitle("已添加的线路")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink(value: SettingsDestination.addConnection) {
          Image(systemName: "plus")
        }
        .accessibilityLabel("添加线路")
      }
    }
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
