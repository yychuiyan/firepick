import FirepickCore
import SwiftUI

struct SourceManagementView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var showingURLImporter = false
    @State private var showingEditor = false
    @State private var editingSite: SiteConfiguration?
    @State private var sitePendingDeletion: SiteConfiguration?
    @State private var showingClearConfirmation = false

    private var sites: [SiteConfiguration] {
        guard !query.isEmpty else { return model.configuration.sites }
        return model.configuration.sites.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.key.localizedCaseInsensitiveContains(query)
                || $0.api.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                Button {
                    showingURLImporter = true
                } label: {
                    Label("从配置地址添加", systemImage: "link.badge.plus")
                }
                Button {
                    editingSite = nil
                    showingEditor = true
                } label: {
                    Label("手动添加点播源", systemImage: "plus.circle")
                }
            } footer: {
                Text("加载完整配置会替换当前点播源列表；单源添加只增加一个站点。")
            }

            if !model.availableDepots.isEmpty {
                Section("配置仓库线路") {
                    ForEach(model.availableDepots, id: \.url) { depot in
                        Button(depot.name.isEmpty ? depot.url : depot.name) {
                            Task { await model.loadDepot(depot) }
                        }
                    }
                }
            }

            Section {
                if sites.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "还没有点播源" : "没有匹配的源",
                        systemImage: query.isEmpty ? "rectangle.stack.badge.plus" : "magnifyingglass",
                        description: Text(
                            query.isEmpty
                                ? "从配置地址添加，或手动新增一个点播源。"
                                : "换个名称、标识或地址关键词。"
                        )
                    )
                }
                ForEach(sites) { site in
                    sourceRow(site)
                }
            } header: {
                Text("点播源")
            } footer: {
                if !sites.isEmpty {
                    Text("点击切换当前源，左滑编辑或删除；当前源会同步显示在点播页。")
                }
            }

            Section("源诊断") {
                LabeledContent("点播源", value: "\(model.configuration.sites.count) 个")
                LabeledContent("已隐藏", value: "\(model.hiddenSiteCount) 个")
                LabeledContent(
                    "电视",
                    value: "\(model.liveGroups.count) 组 · \(model.liveChannelCount) 频道"
                )
                ForEach(model.sourceRouteCounts) { item in
                    LabeledContent(model.runtimeLabel(item.runtime), value: "\(item.count) 个")
                }
                if let site = model.selectedSite {
                    LabeledContent("当前点播源", value: site.name)
                    LabeledContent("执行路径", value: model.routeLabel(for: site))
                }
                Button {
                    Task { await model.testSelectedSource() }
                } label: {
                    if model.sourceTestIsRunning {
                        HStack {
                            ProgressView()
                            Text("正在测试当前源…")
                        }
                    } else {
                        Text("测试当前源")
                    }
                }
                .disabled(model.selectedSite == nil || model.sourceTestIsRunning)
                if let status = model.sourceTestStatus {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !model.sourceRouteCounts.isEmpty,
                   model.bridgeHealth == nil,
                   model.sourceRouteCounts.contains(where: { $0.runtime != .http }) {
                    Text("Java、Python、Node.js 和兼容 QuickJS 源需要连接 Firepick Bridge。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if !model.configuration.sites.isEmpty {
                Section {
                    Button("清空全部点播源", role: .destructive) {
                        showingClearConfirmation = true
                    }
                } footer: {
                    Text("只清空点播源，直播源和媒体库数据会保留。")
                }
            }
        }
        .navigationTitle("点播源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .searchable(text: $query, prompt: "搜索名称、标识或地址")
        .sheet(isPresented: $showingURLImporter) {
            ConfigurationURLView()
        }
        .sheet(isPresented: $showingEditor) {
            SourceEditorView(site: editingSite)
        }
        .confirmationDialog(
            "删除点播源？",
            isPresented: Binding(
                get: { sitePendingDeletion != nil },
                set: { if !$0 { sitePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let site = sitePendingDeletion {
                Button("删除“\(site.name)”", role: .destructive) {
                    sitePendingDeletion = nil
                    Task { await model.removeSite(site) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后可以通过重新加载配置恢复。")
        }
        .confirmationDialog(
            "清空全部点播源？",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                Task { await model.clearVodSources() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前点播源列表将被清空，直播源不会受影响。")
        }
    }

    private func sourceRow(_ site: SiteConfiguration) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.selectSite(site) }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(site.name)
                                .foregroundStyle(.primary)
                            if site.isHidden {
                                Text("已隐藏")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(model.routeLabel(for: site))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(site.api)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if model.selectedSite?.key == site.key {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(site.isHidden)
            .opacity(site.isHidden ? 0.55 : 1)

            Menu {
                Button {
                    editingSite = site
                    showingEditor = true
                } label: {
                    Label("修改", systemImage: "pencil")
                }
                Button {
                    Task { await model.setHidden(!site.isHidden, for: site) }
                } label: {
                    Label(site.isHidden ? "显示" : "隐藏", systemImage: site.isHidden ? "eye" : "eye.slash")
                }
                Button(role: .destructive) {
                    sitePendingDeletion = site
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                sitePendingDeletion = site
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                editingSite = site
                showingEditor = true
            } label: {
                Label("修改", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }
}

private struct ConfigurationURLView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var urlString = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/config.json", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(load)
                } footer: {
                    Text("支持 CatVod/TVBox JSON、配置仓库 JSON、直播 JSON、M3U 和 TXT。")
                }
            }
            .navigationTitle("从配置地址添加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加载", action: load)
                        .disabled(trimmedURL.isEmpty || model.isLoading)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起") { focused = false }
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                focused = true
            }
            .dismissKeyboardOnBackgroundTap()
        }
    }

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() {
        guard !trimmedURL.isEmpty else { return }
        focused = false
        Task {
            if await model.applyConfiguration(urlString: trimmedURL) {
                dismiss()
            }
        }
    }
}

private struct SourceEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private let originalSite: SiteConfiguration?
    @State private var key: String
    @State private var name: String
    @State private var api: String
    @State private var type: Int
    @State private var jar: String

    init(site: SiteConfiguration?) {
        originalSite = site
        _key = State(initialValue: site?.key ?? "")
        _name = State(initialValue: site?.name ?? "")
        _api = State(initialValue: site?.api ?? "")
        _type = State(initialValue: site?.effectiveType ?? 0)
        _jar = State(initialValue: site?.jar ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("源标识", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(originalSite != nil)
                    TextField("显示名称", text: $name)
                        .focused($focused)
                    TextField("接口地址或 csp_/js/py/node 地址", text: $api, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .lineLimit(2...4)
                }

                Section {
                    Picker("类型", selection: $type) {
                        Text("0 · 自动/HTTP").tag(0)
                        Text("1 · HTTP/JSON").tag(1)
                        Text("2 · 兼容/旧版").tag(2)
                        Text("3 · Spider/JAR").tag(3)
                        Text("4 · 扩展 HTTP").tag(4)
                    }
                    TextField("Jar 地址（可选）", text: $jar)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("执行方式")
                } footer: {
                    Text("QuickJS、Python、Node.js 和 csp_/JAR 通常需要 Android Bridge。")
                }
            }
            .navigationTitle(originalSite == nil ? "新增点播源" : "修改点播源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(!canSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起") { focused = false }
                }
            }
            .dismissKeyboardOnBackgroundTap()
        }
    }

    private var canSave: Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !api.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        var site = originalSite ?? SiteConfiguration(
            key: key,
            name: name,
            type: type,
            api: api
        )
        site.name = name
        site.api = api
        site.type = type
        let trimmedJar = jar.trimmingCharacters(in: .whitespacesAndNewlines)
        site.jar = trimmedJar.isEmpty ? nil : trimmedJar

        focused = false
        Task {
            let saved = if originalSite == nil {
                await model.addSite(site)
            } else {
                await model.updateSite(site)
            }
            if saved {
                dismiss()
            }
        }
    }
}
