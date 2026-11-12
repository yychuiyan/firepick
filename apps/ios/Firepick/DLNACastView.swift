import FirepickPlayback
import SwiftUI

struct DLNACastView: View {
    @Environment(\.dismiss) private var dismiss
    let request: PlaybackRequest
    let title: String

    @State private var devices: [DLNADevice] = []
    @State private var isScanning = false
    @State private var castingID: String?
    @State private var status: String?

    var body: some View {
        NavigationStack {
            List {
                if let status {
                    Section {
                        Text(status)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("局域网 DLNA 设备") {
                    if devices.isEmpty, !isScanning {
                        ContentUnavailableView(
                            "没有发现设备",
                            systemImage: "tv.slash",
                            description: Text("确认电视与 iPhone/iPad 在同一局域网。")
                        )
                    }
                    ForEach(devices) { device in
                        Button {
                            cast(to: device)
                        } label: {
                            HStack {
                                Image(systemName: "tv")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name)
                                    Text(device.location.host ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if castingID == device.id {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(castingID != nil)
                    }
                }
            }
            .navigationTitle("投屏到电视")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await scan() }
                    } label: {
                        if isScanning {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isScanning || castingID != nil)
                }
            }
            .task { await scan() }
        }
    }

    private func scan() async {
        isScanning = true
        status = "正在搜索 DLNA 设备…"
        defer { isScanning = false }
        do {
            devices = try await DLNACastManager.shared.discover()
            status = devices.isEmpty ? "搜索完成，未发现设备" : "已发现 \(devices.count) 台设备"
        } catch {
            status = error.localizedDescription
        }
    }

    private func cast(to device: DLNADevice) {
        castingID = device.id
        status = "正在投屏到 \(device.name)…"
        Task {
            do {
                try await DLNACastManager.shared.cast(
                    request,
                    to: device
                )
                status = "已投屏：\(title)"
                castingID = nil
            } catch {
                status = error.localizedDescription
                castingID = nil
            }
        }
    }
}
