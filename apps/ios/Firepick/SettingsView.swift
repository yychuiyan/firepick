import FirepickCore
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @FocusState private var focusedField: FocusedField?
  @State private var showingSourceMenu = false
  @State private var emptySourceURL = ""
  @State private var libraryMode: LibraryView.Mode?

  private enum FocusedField: Hashable {
    case emptySourceURL
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Text("设置")
          .font(.system(size: 34, weight: .bold))
          .frame(maxWidth: .infinity)
          .padding(.top, 8)
          .padding(.bottom, 4)

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
          }

          Section("扩展与连接") {
            NavigationLink {
              ExtensionSettingsView()
            } label: {
              LabeledContent("Android Bridge", value: bridgeStatus)
            }
          }

          ProvisioningExpirySection()
        }
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
      }
      .toolbar(.hidden, for: .navigationBar)
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
