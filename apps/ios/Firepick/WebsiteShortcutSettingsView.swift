import FirepickCore
import SwiftUI

struct WebsiteShortcutSettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var showingEditor = false
  @State private var editingID: UUID?
  @State private var draftName = ""
  @State private var draftAddress = ""
  @State private var validationMessage: String?

  var body: some View {
    List {
      if model.websiteShortcuts.isEmpty {
        ContentUnavailableView(
          "暂无接口配置",
          systemImage: "bookmark",
          description: Text("添加接口名称和解析网址（如 https://jx.example.com/?url=），在聚合页选择后会与视频链接拼接打开。")
        )
      } else {
        ForEach(model.websiteShortcuts) { shortcut in
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
              Text(shortcut.name)
                .foregroundStyle(.primary)
              Text(shortcut.url.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
              beginEditing(shortcut)
            }

            Toggle(
              isOn: Binding(
                get: { shortcut.isEnabled },
                set: { newValue in
                  model.setWebsiteShortcutEnabled(
                    id: shortcut.id,
                    isEnabled: newValue
                  )
                }
              )
            ) {
              EmptyView()
            }
            .labelsHidden()
          }
        }
        .onDelete { offsets in
          for index in offsets {
            model.deleteWebsiteShortcut(id: model.websiteShortcuts[index].id)
          }
        }
      }
    }
    .navigationTitle("接口配置")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          beginAdding()
        } label: {
          Image(systemName: "plus")
        }
        .accessibilityLabel("添加接口配置")
      }
    }
    .sheet(isPresented: $showingEditor) {
      shortcutEditor
    }
  }

  private var shortcutEditor: some View {
    NavigationStack {
      Form {
        Section {
          TextField("名称", text: $draftName)
          TextField("接口地址", text: $draftAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        } footer: {
          if let validationMessage {
            Text(validationMessage)
              .foregroundStyle(.red)
          } else {
            Text("例如：某解析接口，https://jx.example.com/?url=")
          }
        }
      }
      .navigationTitle(editingID == nil ? "添加接口配置" : "编辑接口配置")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") {
            showingEditor = false
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存", action: save)
            .disabled(
              draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || draftAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
      }
    }
    .presentationDetents([.medium])
  }

  private func beginAdding() {
    editingID = nil
    draftName = ""
    draftAddress = ""
    validationMessage = nil
    showingEditor = true
  }

  private func beginEditing(_ shortcut: WebsiteShortcut) {
    editingID = shortcut.id
    draftName = shortcut.name
    draftAddress = shortcut.url.absoluteString
    validationMessage = nil
    showingEditor = true
  }

  private func save() {
    let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      validationMessage = "名称不能为空"
      return
    }
    guard let url = WebsiteShortcut.normalizedURL(from: draftAddress) else {
      validationMessage = "请输入有效的 HTTP(S) 网址"
      return
    }

    if let editingID {
      model.updateWebsiteShortcut(id: editingID, name: name, url: url)
    } else {
      model.addWebsiteShortcut(name: name, url: url)
    }
    validationMessage = nil
    showingEditor = false
  }
}
