import SwiftUI

struct ExtensionSettingsView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var pairingFocused: Bool
    @State private var pairingURI = ""
    @State private var showingScanner = false

    var body: some View {
        Form {
            Section {
                LabeledContent("状态", value: bridgeStatus)
                if let health = model.bridgeHealth {
                    LabeledContent("协议", value: "v\(health.protocolVersion)")
                    LabeledContent("版本", value: health.bridgeVersion)
                    LabeledContent(
                        "运行时",
                        value: health.runtimes.map(\.rawValue).joined(separator: ", ")
                    )
                }
            } footer: {
                Text("Android Bridge 是可选扩展，仅在需要运行 QuickJS、Java/JAR、Python、Node.js 等复杂源时使用。")
            }

            Section("配对 Android Bridge") {
                TextField("firepick://pair?...", text: $pairingURI, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($pairingFocused)
                Button {
                    pairingFocused = false
                    showingScanner = true
                } label: {
                    Label("扫描 Bridge 二维码", systemImage: "qrcode.viewfinder")
                }
                Button {
                    pairingFocused = false
                    Task { await model.pairBridge(uriString: pairingURI) }
                } label: {
                    Label("配对 Bridge", systemImage: "link")
                }
                .disabled(
                    pairingURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            Section("首次配置") {
                Text("1. Android 安装拾萤 Bridge。")
                Text("2. 将 Android 与 iPhone/iPad 接入同一 Wi-Fi。")
                Text("3. 在 Android Bridge 页面等待状态显示“运行中”。")
                Text("4. 扫描二维码；Python、Node.js 等运行时可在 Android 页面按需安装。")
            }
            .font(.footnote)
        }
        .navigationTitle("Android Bridge")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .dismissKeyboardOnBackgroundTap()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起") {
                    pairingFocused = false
                }
            }
        }
        .sheet(isPresented: $showingScanner) {
            QRScannerView { code in
                pairingURI = code
                showingScanner = false
                Task { await model.pairBridge(uriString: code) }
            }
            .ignoresSafeArea()
        }
    }

    private var bridgeStatus: String {
        model.bridgeHealth == nil ? "未连接" : "已连接"
    }
}
