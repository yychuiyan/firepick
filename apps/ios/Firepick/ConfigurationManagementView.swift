import SwiftUI

struct ConfigurationManagementView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    List {
      if model.sourceConnections.isEmpty {
        ContentUnavailableView(
          "还没有配置地址",
          systemImage: "link.badge.plus",
          description: Text("返回设置页，在输入框中添加 TVBox 配置地址。")
        )
        .listRowBackground(Color.clear)
      } else {
        Section {
          ForEach(model.sourceConnections) { connection in
            Button {
              Task { await model.loadConnection(connection) }
            } label: {
              HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link")
                  .foregroundStyle(.orange)
                  .frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                  Text(connection.displayAddress)
                    .font(.body.monospaced())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                  Text(connection.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if model.currentConnection?.id == connection.id {
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.orange)
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isLoading)
            .swipeActions {
              Button(role: .destructive) {
                model.removeConnection(connection)
              } label: {
                Label("删除", systemImage: "trash")
              }
            }
          }
        } footer: {
          Text("这里只管理整套配置地址。具体点播源请进入“点播”页面切换。")
        }
      }
    }
    .navigationTitle("配置地址")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
  }
}
