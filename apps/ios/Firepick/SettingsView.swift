import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @FocusState private var focusedField: FocusedField?
  @State private var showingSourceMenu = false
  @State private var emptySourceURL = ""
  @State private var showingClearCacheConfirmation = false

  private enum FocusedField: Hashable {
    case emptySourceURL
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Button {
            focusedField = nil
            withAnimation(.easeInOut(duration: 0.18)) {
              showingSourceMenu.toggle()
            }
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text("当前线路")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(model.currentConnection?.displayAddress ?? "尚未选择")
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
          .buttonStyle(.plain)
          .contentShape(Rectangle())
          .disabled(model.sourceConnections.isEmpty)

          if showingSourceMenu {
            ScrollView {
              LazyVStack(spacing: 0) {
                ForEach(model.sourceConnections) { connection in
                  HStack(spacing: 12) {
                    Button {
                      showingSourceMenu = false
                      Task { await model.loadConnection(connection) }
                    } label: {
                      VStack(alignment: .leading, spacing: 3) {
                        Text(connection.name)
                          .foregroundStyle(.primary)
                          .lineLimit(1)
                        Text(connection.displayAddress)
                          .font(.caption)
                          .foregroundStyle(.secondary)
                          .lineLimit(1)
                      }
                      Spacer()
                      if model.currentConnection?.id == connection.id {
                        Image(systemName: "checkmark.circle.fill")
                          .foregroundStyle(.orange)
                      }
                    }
                    .buttonStyle(.plain)
                    Button(role: .destructive) {
                      model.removeConnection(connection)
                    } label: {
                      Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                  }
                  .padding(.vertical, 9)
                  if connection.id != model.sourceConnections.last?.id {
                    Divider()
                  }
                }
              }
            }
            .frame(maxHeight: 280)
          }

          NavigationLink {
            ConfigurationManagementView()
          } label: {
            LabeledContent(
              "已添加的线路",
              value: "\(model.sourceConnections.count) 个"
            )
          }

          TextField("输入线路地址", text: $emptySourceURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .submitLabel(.go)
            .focused($focusedField, equals: .emptySourceURL)
            .onSubmit(addSourceFromURL)
          Button(action: addSourceFromURL) {
            HStack(spacing: 8) {
              if model.isLoading {
                ProgressView()
              }
              Text(model.isLoading ? "正在添加源…" : "添加源地址")
                .frame(maxWidth: .infinity)
            }
          }
          .disabled(
            emptySourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || model.isLoading
          )
          if !model.availableDepots.isEmpty {
            Text("仓库线路")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.secondary)
            ForEach(model.availableDepots, id: \.url) { depot in
              Button(depot.name.isEmpty ? depot.url : depot.name) {
                Task { await model.loadDepot(depot) }
              }
            }
          }
        }

        Section {
          NavigationLink {
            LibraryView(mode: .favorites)
          } label: {
            Label("收藏", systemImage: "heart")
          }
          NavigationLink {
            LibraryView(mode: .history)
          } label: {
            Label("最近观看", systemImage: "clock.arrow.circlepath")
          }
        }

        if !model.configurationCandidates.isEmpty {
          Section("检测到的配置入口") {
            ForEach(model.configurationCandidates) { candidate in
              Button {
                Task {
                  _ = await model.applyConfiguration(
                    urlString: candidate.url.absoluteString
                  )
                }
              } label: {
                Text(candidate.url.absoluteString)
                  .font(.caption.monospaced())
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
          .font(.footnote)
        }

        Section {
          Picker(
            "播放引擎",
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
          Button {
            showingClearCacheConfirmation = true
          } label: {
            HStack {
              Text("清理缓存")
                .foregroundStyle(.red)
              Spacer()
              Text(model.cacheSizeText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
          }
          .buttonStyle(.plain)
          .contentShape(Rectangle())
          if let status = model.cacheStatus {
            Text(status)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }

        Section {
          NavigationLink {
            DanmakuSettingsView()
          } label: {
            LabeledContent(
              "默认显示弹幕",
              value: model.danmakuEnabledByDefault ? "已开启" : "已关闭"
            )
          }
        }

        ProvisioningExpirySection()
      }
      .contentMargins(.top, 8, for: .scrollContent)
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
      .alert(
        "清理缓存？",
        isPresented: $showingClearCacheConfirmation
      ) {
        Button("清理", role: .destructive) {
          model.clearCache()
        }
        Button("取消", role: .cancel) {}
      } message: {
        Text("不会删除收藏、历史、源配置或本机下载文件。")
      }
      .onAppear {
        model.refreshCacheSize()
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active {
          model.refreshCacheSize()
        }
      }
      .toolbar(.hidden, for: .navigationBar)
    }
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
