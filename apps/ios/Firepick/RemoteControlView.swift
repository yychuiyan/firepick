import FirepickBridge
import SwiftUI

struct RemoteControlView: View {
    @Environment(AppModel.self) private var model
    @State private var status: FongmiRemoteStatus?
    @State private var error: String?
    @State private var seekPosition = 0.0
    @State private var speed = 1.0
    @State private var busy = false

    private var client: FongmiRemoteClient? {
        guard let url = model.fongmiRemoteBaseURL else { return nil }
        return FongmiRemoteClient(baseURL: url)
    }

    var body: some View {
        Form {
            if status?.active == true {
                Section("正在播放") {
                    LabeledContent("标题", value: status?.title ?? "未知")
                    if let subtitle = status?.subtitle, !subtitle.isEmpty {
                        LabeledContent("剧集", value: subtitle)
                    }
                    LabeledContent("播放器", value: status?.engine ?? "FongMi")
                    if let video = status?.video, !video.isEmpty {
                        LabeledContent("画面", value: video)
                    }
                    LabeledContent("状态", value: stateLabel)
                    if !(status?.live ?? false) {
                        Slider(
                            value: $seekPosition,
                            in: 0...max(1, Double(status?.duration ?? 0) / 1_000)
                        )
                        HStack {
                            Text(format(seekPosition))
                            Spacer()
                            Text(format(Double(status?.duration ?? 0) / 1_000))
                        }
                        .font(.caption.monospacedDigit())
                        Button("跳转到此位置") {
                            run(.seek, position: Int64(seekPosition * 1_000))
                        }
                    }
                }

                Section("遥控") {
                    HStack {
                        transportButton("上一集", icon: "backward.end", command: .prev)
                        transportButton("播放", icon: "play.fill", command: .play)
                        transportButton("暂停", icon: "pause.fill", command: .pause)
                        transportButton("下一集", icon: "forward.end", command: .next)
                    }
                    Button("停止播放", role: .destructive) {
                        run(.stop)
                    }
                    Menu("倍速：\(speed.formatted())×") {
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { value in
                            Button("\(value.formatted())×") {
                                speed = value
                                run(.speed, speed: value)
                            }
                        }
                    }
                    .disabled(status?.canSetSpeed == false || status?.live == true)
                    Button(
                        status?.repeatOne == true ? "关闭单集循环" : "开启单集循环"
                    ) {
                        run(status?.repeatOne == true ? .repeatOff : .repeatOn)
                    }
                }
            } else {
                ContentUnavailableView(
                    "电视当前没有播放",
                    systemImage: "tv",
                    description: Text("在 FongMi Android 开始播放后，这里会显示遥控器。")
                )
            }

            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("遥控")
        .task {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await refresh()
            }
        }
    }

    private var stateLabel: String {
        if status?.playWhenReady == true { return "播放中" }
        switch status?.state {
        case 2: return "缓冲中"
        case 4: return "已结束"
        default: return "已暂停"
        }
    }

    private func transportButton(
        _ title: String,
        icon: String,
        command: FongmiRemoteCommand
    ) -> some View {
        Button {
            run(command)
        } label: {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
        }
        .disabled(
            busy
                || (command == .prev || command == .next)
                    && status?.canNavigate == false
        )
    }

    private func run(
        _ command: FongmiRemoteCommand,
        position: Int64 = 0,
        speed: Double = 1
    ) {
        guard let client else { return }
        busy = true
        Task {
            do {
                apply(try await client.control(
                    command,
                    position: position,
                    speed: speed
                ))
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func refresh() async {
        guard let client else { return }
        do {
            apply(try await client.status())
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ value: FongmiRemoteStatus) {
        status = value
        seekPosition = Double(value.position) / 1_000
        speed = value.speed ?? 1
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let value = max(0, Int(seconds))
        if value >= 3_600 {
            return String(
                format: "%02d:%02d:%02d",
                value / 3_600,
                value % 3_600 / 60,
                value % 60
            )
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
