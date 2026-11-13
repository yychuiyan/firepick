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
        Picker(
          "智能去广",
          selection: Binding(
            get: { model.adSkipPreference },
            set: { model.setAdSkipPreference($0) }
          )
        ) {
          ForEach(AppModel.AdSkipPreference.allCases) { value in
            Text(value.title).tag(value)
          }
        }
        Text("基于本机标记的片头片尾跳过，不是云端广告识别。")
          .font(.footnote)
          .foregroundStyle(.secondary)
        if model.adSkipPreference != .off {
          Button("清除全部片头片尾标记", role: .destructive) {
            showingClearSkipMarks = true
          }
        }
      } header: {
        Text("智能去广")
      }

      Section("播放行为") {
        Toggle(
          "后台播放",
          isOn: Binding(
            get: { model.backgroundPlaybackEnabled },
            set: { model.setBackgroundPlaybackEnabled($0) }
          )
        )
        Toggle(
          "无痕模式",
          isOn: Binding(
            get: { model.incognitoModeEnabled },
            set: { model.setIncognitoModeEnabled($0) }
          )
        )
        Text("无痕开启后不写入最近观看。")
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
