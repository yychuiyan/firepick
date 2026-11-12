import FirepickBridge
import FirepickCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focusedField: FocusedField?
    @State private var showingSourceMenu = false
    @State private var emptySourceURL = ""
    @State private var pairingURI = ""
    @State private var showingScanner = false
    @State private var fongmiServerURL = ""
    @State private var libraryMode: LibraryView.Mode?

    private enum FocusedField: Hashable {
        case emptySourceURL
        case pairingURI
        case fongmiServerURL
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("点播源") {
                    Button {
                        focusedField = nil
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showingSourceMenu.toggle()
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("当前源")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(model.selectedSite?.name ?? "尚未选择")
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(showingSourceMenu ? 180 : 0))
                        }
                    }
                    .disabled(visibleSites.isEmpty)

                    if showingSourceMenu {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(visibleSites) { site in
                                    Button {
                                        showingSourceMenu = false
                                        guard model.selectedSite?.key != site.key else { return }
                                        Task { await model.selectSite(site) }
                                    } label: {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(site.name)
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                Text(model.routeLabel(for: site))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            if model.selectedSite?.key == site.key {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                        .padding(.vertical, 9)
                                    }
                                    .buttonStyle(.plain)
                                    if site.id != visibleSites.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 280)
                    }

                    NavigationLink {
                        SourceManagementView()
                    } label: {
                        LabeledContent(
                            "管理已添加的点播源",
                            value: "\(model.configuration.sites.count) 个"
                        )
                    }

                    if visibleSites.isEmpty {
                        TextField("输入点播配置地址", text: $emptySourceURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .focused($focusedField, equals: .emptySourceURL)
                            .onSubmit(addSourceFromURL)
                        Button(action: addSourceFromURL) {
                            HStack {
                                if model.isLoading {
                                    ProgressView()
                                }
                                Text(model.isLoading ? "正在添加源…" : "添加源地址")
                            }
                        }
                        .disabled(
                            emptySourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || model.isLoading
                        )
                        if !model.availableDepots.isEmpty {
                            Text("配置仓库线路")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(model.availableDepots, id: \.url) { depot in
                                Button(depot.name.isEmpty ? depot.url : depot.name) {
                                    Task { await model.loadDepot(depot) }
                                }
                            }
                        }
                    }
                }

                Section("媒体库") {
                    Button {
                        focusedField = nil
                        libraryMode = .favorites
                    } label: {
                        Label("收藏", systemImage: "heart")
                    }
                    Button {
                        focusedField = nil
                        libraryMode = .history
                    } label: {
                        Label("最近观看", systemImage: "clock.arrow.circlepath")
                    }
                    Button {
                        focusedField = nil
                        libraryMode = .downloads
                    } label: {
                        Label("下载与本地文件", systemImage: "arrow.down.circle")
                    }
                }

                Section("Android Bridge") {
                    LabeledContent("状态", value: bridgeStatus)
                    if let health = model.bridgeHealth {
                        LabeledContent("协议", value: "v\(health.protocolVersion)")
                        LabeledContent("版本", value: health.bridgeVersion)
                        LabeledContent("运行时", value: health.runtimes.map(\.rawValue).joined(separator: ", "))
                    }
                    TextField("firepick://pair?...", text: $pairingURI, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .pairingURI)
                    Button("扫描 Bridge 二维码") {
                        focusedField = nil
                        showingScanner = true
                    }
                    Button("配对 Bridge") {
                        focusedField = nil
                        Task { await model.pairBridge(uriString: pairingURI) }
                    }
                    .disabled(pairingURI.isEmpty)
                }

                Section("FongMi Android 服务") {
                    LabeledContent("状态", value: model.fongmiServerStatus)
                    TextField("http://192.168.1.8:9978", text: $fongmiServerURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .fongmiServerURL)
                        .onSubmit {
                            focusedField = nil
                            Task {
                                await model.connectFongmiServer(urlString: fongmiServerURL)
                            }
                        }
                    Button("连接现有 FongMi/TV") {
                        focusedField = nil
                        Task { await model.connectFongmiServer(urlString: fongmiServerURL) }
                    }
                    .disabled(fongmiServerURL.isEmpty)
                    if model.fongmiRemoteBaseURL != nil {
                        NavigationLink("遥控当前 FongMi 播放") {
                            RemoteControlView()
                        }
                    }
                    Text("在 Android FongMi/TV 开启局域网服务后填写设备地址。Java、Python、QuickJS 和 JAR 源会通过该服务执行。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("分发") {
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                    Text("免费 Personal Team 签名约 7 天有效。SideStore 用于设备端续签，每位用户使用自己的 Apple ID。")
                        .font(.footnote)
                }

                Section("许可") {
                    Text("拾萤以 GPL-3.0-only 发布。上游组件和来源责任见 NOTICE.md。")
                        .font(.footnote)
                }
            }
            .navigationTitle("设置")
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnBackgroundTap()
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起") {
                        focusedField = nil
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
            .sheet(item: $libraryMode) { mode in
                LibraryView(mode: mode)
            }
        }
    }

    private var bridgeStatus: String {
        guard model.bridgeHealth != nil else { return "未连接" }
        return "已连接"
    }

    private var visibleSites: [SiteConfiguration] {
        model.configuration.sites.filter { !$0.isHidden }
    }

    private func addSourceFromURL() {
        let value = emptySourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        focusedField = nil
        Task {
            if await model.applyConfiguration(urlString: value) {
                emptySourceURL = ""
            }
        }
    }
}

