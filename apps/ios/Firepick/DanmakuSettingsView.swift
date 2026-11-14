import FirepickCore
import SwiftUI

struct DanmakuSettingsView: View {
  @Environment(AppModel.self) private var model
  /// When opened from the player menu, toggles this session's overlay.
  var sessionEnabled: Binding<Bool>? = nil
  var hasComments: Bool = true

  var body: some View {
    Form {
      if let sessionEnabled {
        Section {
          Toggle("显示弹幕", isOn: sessionEnabled)
            .disabled(!hasComments)
        } footer: {
          Text(hasComments ? "只影响当前播放页。" : "当前影片没有弹幕。")
        }
      }

      Section {
        Toggle(
          "默认显示弹幕",
          isOn: Binding(
            get: { model.danmakuEnabledByDefault },
            set: { model.setDanmakuEnabledByDefault($0) }
          )
        )
        Toggle(
          "自动匹配弹幕",
          isOn: Binding(
            get: { model.danmakuAutoMatch },
            set: { model.setDanmakuAutoMatch($0) }
          )
        )
      } footer: {
        Text("新打开的播放页使用默认开关。自动匹配会按片名在 B 站找同集弹幕；填了下方聚合 API 时优先用它（可覆盖爱优腾芒哔）。")
      }

      Section {
        TextField(
          "https://host/token",
          text: Binding(
            get: { model.danmakuCustomAPIBase },
            set: { model.setDanmakuCustomAPIBase($0) }
          )
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
      } header: {
        Text("弹幕聚合 API（可选）")
      } footer: {
        Text("兼容弹弹play / danmu_api：/api/v2/search/episodes 与 /api/v2/comment/{id}。留空则只用内置 B 站匹配。")
      }

      Section {
        Picker(
          "显示区域",
          selection: Binding(
            get: { model.danmakuDisplayArea },
            set: { model.setDanmakuDisplayArea($0) }
          )
        ) {
          ForEach(DanmakuDisplayArea.allCases) { area in
            Text(area.title).tag(area)
          }
        }
        .pickerStyle(.navigationLink)
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
      } header: {
        Text("显示")
      } footer: {
        Text("显示区域参考 B 站：从满屏到最少「一行」。")
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
