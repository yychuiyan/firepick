import SwiftUI

struct PlaybackSettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var showingClearSkipMarks = false

  var body: some View {
    Form {
      Section("播放引擎") {
        Picker(
          "引擎",
          selection: Binding(
            get: { model.playbackPreference },
            set: { model.setPlaybackPreference($0) }
          )
        ) {
          ForEach(AppModel.PlaybackPreference.allCases) { value in
            Text(value.title).tag(value)
          }
        }
        Picker(
          "视频输出",
          selection: Binding(
            get: { model.videoOutputPreference },
            set: { model.setVideoOutputPreference($0) }
          )
        ) {
          ForEach(model.availableVideoOutputPreferences, id: \.self) { value in
            Text(value.title).tag(value)
          }
        }
        .disabled(model.playbackPreference == .avPlayer)
        if model.playbackPreference == .avPlayer {
          Text("AVPlayer 使用系统图层，输出选项对 MPV 更有效。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          Text("MPVKit 使用 Metal 输出；“系统层”仅用于 AVPlayer。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Picker(
          "解码",
          selection: Binding(
            get: { model.decodePreference },
            set: { model.setDecodePreference($0) }
          )
        ) {
          ForEach(AppModel.DecodePreference.allCases) { value in
            Text(value.title).tag(value)
          }
        }
        .disabled(model.playbackPreference == .avPlayer)
        if model.playbackPreference == .avPlayer {
          Text("AVPlayer 解码由系统决定。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      Section {
        Toggle(
          "智能去广",
          isOn: Binding(
            get: { model.cloudAdSkipEnabled },
            set: { model.setCloudAdSkipEnabled($0) }
          )
        )
        Text("开启后，若片源或云端返回片中广告时间轴，播到广告段会自动跳过。无广告轴时不会有额外提示。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } header: {
        Text("智能去广")
      }

      Section {
        Picker(
          "片头片尾",
          selection: Binding(
            get: { model.adSkipPreference },
            set: { model.setAdSkipPreference($0) }
          )
        ) {
          ForEach(AppModel.AdSkipPreference.allCases) { value in
            Text(value.title).tag(value)
          }
        }
        Text("在播放页菜单标记片头/片尾后，按此偏好自动跳过。与片中广告无关。")
          .font(.footnote)
          .foregroundStyle(.secondary)
        if model.adSkipPreference != .off {
          Button("清除全部片头片尾标记", role: .destructive) {
            showingClearSkipMarks = true
          }
        }
      } header: {
        Text("片头片尾")
      }

      Section {
        Toggle(
          "后台播放",
          isOn: Binding(
            get: { model.backgroundPlaybackEnabled },
            set: { model.setBackgroundPlaybackEnabled($0) }
          )
        )
        Text("开启后切到后台或锁屏时继续出声；关闭则进入后台时自动暂停。")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Toggle(
          "无痕模式",
          isOn: Binding(
            get: { model.incognitoModeEnabled },
            set: { model.setIncognitoModeEnabled($0) }
          )
        )
        Text("开启后不写入最近观看；收藏不受影响。")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Toggle(
          "搜索包含全部本机源",
          isOn: Binding(
            get: { model.multiSourceSearchEnabled },
            set: { model.setMultiSourceSearchEnabled($0) }
          )
        )
        Text("开启后搜索更全，也可能更慢。")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Picker(
          "缓冲时间",
          selection: Binding(
            get: { model.bufferPreference },
            set: { model.setBufferPreference($0) }
          )
        ) {
          ForEach(AppModel.BufferPreference.allCases) { value in
            Text(value.title).tag(value)
          }
        }
      } header: {
        Text("播放行为")
      }

      Section("字幕特效") {
        Picker(
          "字号",
          selection: Binding(
            get: { model.subtitleFontPreference },
            set: { model.setSubtitleFontPreference($0) }
          )
        ) {
          ForEach(AppModel.SubtitleFontPreference.allCases) { value in
            Text(value.title).tag(value)
          }
        }
        Picker(
          "颜色",
          selection: Binding(
            get: { model.subtitleColorPreference },
            set: { model.setSubtitleColorPreference($0) }
          )
        ) {
          ForEach(AppModel.SubtitleColorPreference.allCases) { value in
            Text(value.title).tag(value)
          }
        }
        Toggle(
          "描边",
          isOn: Binding(
            get: { model.subtitleOutlineEnabled },
            set: { model.setSubtitleOutlineEnabled($0) }
          )
        )
        Text("部分效果在 MPV 下更完整；AVPlayer 能力有限。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Section("界面") {
        Picker(
          "海报尺寸",
          selection: Binding(
            get: { model.posterSizePreference },
            set: { model.setPosterSizePreference($0) }
          )
        ) {
          ForEach(AppModel.PosterSizePreference.allCases) { value in
            Text(value.title).tag(value)
          }
        }
      }

      Section {
        NavigationLink {
          DanmakuSettingsView()
        } label: {
          LabeledContent(
            "弹幕设置",
            value: model.danmakuEnabledByDefault ? "默认开" : "默认关"
          )
        }
      }
    }
    .navigationTitle("播放设置")
    .navigationBarTitleDisplayMode(.inline)
    .alert("清除片头片尾标记？", isPresented: $showingClearSkipMarks) {
      Button("清除", role: .destructive) {
        model.clearSkipMarks()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("仅清除本机保存的跳过位置，不影响收藏与历史。")
    }
  }
}
