import SwiftUI

struct AddConnectionView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var urlText = ""
  @FocusState private var focused: Bool

  var body: some View {
    Form {
      Section {
        TextField("https://…/ios-sources.json", text: $urlText)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .submitLabel(.go)
          .focused($focused)
          .onSubmit(submit)
      } footer: {
        Text("粘贴 CatVod / TVBox 配置直链。添加成功后会设为当前线路。")
      }

      Section {
        Button(action: submit) {
          HStack {
            if model.isSwitchingConnection {
              ProgressView()
            }
            Text(model.isSwitchingConnection ? "正在添加…" : "添加并切换")
              .frame(maxWidth: .infinity)
          }
        }
        .disabled(
          urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.isSwitchingConnection
        )
      }
    }
    .navigationTitle("添加线路")
    .navigationBarTitleDisplayMode(.inline)
    .scrollDismissesKeyboard(.interactively)
    .dismissKeyboardOnBackgroundTap()
    .task { focused = true }
  }

  private func submit() {
    let value = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    focused = false
    Task {
      if await model.applyConfiguration(urlString: value) {
        dismiss()
      }
    }
  }
}
