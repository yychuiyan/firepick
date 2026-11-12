import SwiftUI

struct DanmakuSettingsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Form {
      Section {
        Toggle(
          "默认显示弹幕",
          isOn: Binding(
            get: { model.danmakuEnabledByDefault },
            set: { model.setDanmakuEnabledByDefault($0) }
          )
        )
      } footer: {
        Text("新打开的播放页面会使用此开关；播放页内仍可临时关闭弹幕。")
      }

      Section {
        settingSlider(
          title: "透明度",
          value: Binding(
            get: { model.danmakuOpacity },
            set: { model.setDanmakuOpacity($0) }
          ),
          range: 0.2...1,
          step: 0.05,
          displayValue: "\(Int((model.danmakuOpacity * 100).rounded()))%"
        )
        settingSlider(
          title: "大小",
          value: Binding(
            get: { model.danmakuFontScale },
            set: { model.setDanmakuFontScale($0) }
          ),
          range: 0.75...1.75,
          step: 0.05,
          displayValue: "\(Int((model.danmakuFontScale * 100).rounded()))%"
        )
        settingSlider(
          title: "速度",
          value: Binding(
            get: { model.danmakuSpeed },
            set: { model.setDanmakuSpeed($0) }
          ),
          range: 0.5...2,
          step: 0.1,
          displayValue:
            "\(model.danmakuSpeed.formatted(.number.precision(.fractionLength(1))))×"
        )
      }

      Section {
        Button("恢复默认值") {
          model.resetDanmakuSettings()
        }
      }
    }
    .navigationTitle("弹幕设置")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
  }

  private func settingSlider(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    displayValue: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
        Spacer()
        Text(displayValue)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Slider(value: value, in: range, step: step)
        .tint(.orange)
    }
    .padding(.vertical, 3)
  }
}
