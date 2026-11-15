import SwiftUI

struct AIEnhancementSettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var keyInput = ""
  @State private var showingRemoveConfirmation = false

  var body: some View {
    @Bindable var model = model
    Form {
      Section {
        Toggle("AI 后台增强", isOn: $model.aiEnhancementEnabled)
          .disabled(!model.aiEnhancementReady)
          .onChange(of: model.aiEnhancementEnabled) { _, enabled in
            model.setAIEnhancementEnabled(enabled)
          }
        LabeledContent("模型", value: "deepseek-flash")
        if let status = model.aiEnhancementStatus, !status.isEmpty {
          Text(status)
            .font(.footnote)
            .foregroundStyle(
              status.contains("无效") || status.contains("失败")
                ? Color.red : Color.secondary
            )
        }
      } footer: {
        Text("默认关闭。开启后，仅在搜索、换源、封面或选集无法由本地规则判断时后台调用，不会显示 AI 对话或推荐理由。")
      }

      Section {
        SecureField("DeepSeek API Key", text: $keyInput)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .privacySensitive()
        Button(model.aiEnhancementTesting ? "正在验证…" : "保存并验证") {
          Task {
            let valid = await model.saveDeepSeekAPIKey(keyInput)
            if valid {
              keyInput = ""
            }
          }
        }
        .disabled(
          keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.aiEnhancementTesting
        )
        Button("测试连接") {
          Task { _ = await model.testDeepSeekConnection() }
        }
        .disabled(!model.aiEnhancementKeyConfigured || model.aiEnhancementTesting)
        if model.aiEnhancementKeyConfigured {
          Button("移除 API Key", role: .destructive) {
            showingRemoveConfirmation = true
          }
        }
      } header: {
        Text("API Key")
      } footer: {
        Text("Key 仅保存在系统钥匙串。不会发送观看历史、收藏、播放地址、源配置或请求头。")
      }

      Section("数据说明") {
        Text("标准、成人和无痕模式均允许调用 AI。无痕模式只使用内存缓存，不把 AI 结果写入磁盘。")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Text("发送内容包括当前搜索词、片名、年份、类型、地区、最多 3 个演员，以及必要的候选标题和选集名称。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("AI 增强")
    .navigationBarTitleDisplayMode(.inline)
    .alert("移除 DeepSeek API Key？", isPresented: $showingRemoveConfirmation) {
      Button("移除", role: .destructive) {
        model.clearDeepSeekAPIKey()
        keyInput = ""
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("移除后会立即关闭 AI 增强，现有搜索、换源和播放功能不受影响。")
    }
  }
}
