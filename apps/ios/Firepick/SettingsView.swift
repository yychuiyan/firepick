import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @FocusState private var focusedField: FocusedField?
  @State private var showingSourceMenu = false
  @State private var showingAddConnection = false
  @State private var emptySourceURL = ""
  @State private var libraryMode: LibraryView.Mode?
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
                Text("连接方式")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(model.currentConnection?.name ?? "尚未选择")
                  .foregroundStyle(.primary)
                  .lineLimit(1)
                if let connection = model.currentConnection {
                  Text(connection.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
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
                        Text(connection.url)
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
            SourceManagementView()
          } label: {
            LabeledContent(
              "管理已添加的点播源",
              value: "\(model.configuration.sites.count) 个"
            )
          }

          Button {
            withAnimation(.easeInOut(duration: 0.18)) {
              showingAddConnection.toggle()
            }
          } label: {
            Label("添加新连接", systemImage: "plus.circle")
          }

          if showingAddConnection || model.sourceConnections.isEmpty {
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

        Section {
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
          Toggle(
            "默认显示弹幕",
            isOn: Binding(
              get: { model.danmakuEnabledByDefault },
              set: { model.setDanmakuEnabledByDefault($0) }
            )
          )
          danmakuSlider(
            title: "弹幕透明度",
            value: Binding(
              get: { model.danmakuOpacity },
              set: { model.setDanmakuOpacity($0) }
            ),
            range: 0.2...1,
            step: 0.05,
            displayValue: "\(Int((model.danmakuOpacity * 100).rounded()))%"
          )
          danmakuSlider(
            title: "弹幕大小",
            value: Binding(
              get: { model.danmakuFontScale },
              set: { model.setDanmakuFontScale($0) }
            ),
            range: 0.75...1.75,
            step: 0.05,
            displayValue: "\(Int((model.danmakuFontScale * 100).rounded()))%"
          )
          danmakuSlider(
            title: "弹幕速度",
            value: Binding(
              get: { model.danmakuSpeed },
              set: { model.setDanmakuSpeed($0) }
            ),
            range: 0.5...2,
            step: 0.1,
            displayValue:
              "\(model.danmakuSpeed.formatted(.number.precision(.fractionLength(1))))×"
          )
          Button("恢复弹幕默认值") {
            model.resetDanmakuSettings()
          }
        } footer: {
          Text("这些设置会用于所有视频，播放页内仍可临时关闭弹幕。")
        }

        Section {
          NavigationLink {
            ExtensionSettingsView()
          } label: {
            LabeledContent("Android Bridge", value: bridgeStatus)
          }
        }

        ProvisioningExpirySection()

        Section {
          Text(versionText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
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
      .sheet(item: $libraryMode) { mode in
        LibraryView(mode: mode)
      }
      .confirmationDialog(
        "清理缓存？",
        isPresented: $showingClearCacheConfirmation,
        titleVisibility: .visible
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

  private var bridgeStatus: String {
    guard model.bridgeHealth != nil else { return "未连接" }
    return "已连接"
  }

  private func addSourceFromURL() {
    let value = emptySourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    focusedField = nil
    Task {
      if await model.applyConfiguration(urlString: value) {
        emptySourceURL = ""
        showingAddConnection = false
      }
    }
  }

  private var versionText: String {
    let version =
      Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
      ) as? String ?? "未知"
    let build =
      Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
      ) as? String ?? "未知"
    return "拾萤 \(version)（\(build)）"
  }

  private func danmakuSlider(
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
