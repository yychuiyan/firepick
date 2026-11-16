import FirepickCore
import SwiftUI

struct AggregationView: View {
  private enum InputMode {
    case address
    case title
  }

  @Environment(AppModel.self) private var model
  @State private var titleQuery = ""
  @State private var address = ""
  @State private var inputMode: InputMode = .address
  @State private var browser: InAppWebBrowserModel?
  @State private var inputError: String?
  @State private var titleError: String?
  @State private var isDetectingTitle = false
  @State private var detectedPages: [DetectedPlatformPage] = []
  @State private var selectedDetectedPageID: String?
  @State private var detectionTask: Task<Void, Never>?
  @FocusState private var inputFocused: Bool

  private static let contentSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration)
  }()

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        header
        Divider()
        content
      }
      .background(Color(.systemBackground))
      .toolbar(.hidden, for: .navigationBar)
      .onChange(of: browser?.currentURL) { _, url in
        guard inputMode == .address, let url, !inputFocused else { return }
        address = url.absoluteString
      }
      .onDisappear {
        detectionTask?.cancel()
        detectionTask = nil
        isDetectingTitle = false
        inputFocused = false
        browser?.pauseMedia()
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 9) {
      VStack(alignment: .leading, spacing: 3) {
        Text("聚合视频")
          .font(.title2.weight(.bold))
        Text("选择接口配置，识别片名或输入视频链接后打开")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Image(systemName: "globe")
            .font(
              model.activeWebsiteShortcut != nil
                ? .body.weight(.bold)
                : .body.weight(.medium)
            )
            .foregroundStyle(
              model.activeWebsiteShortcut != nil ? Color.orange : Color.secondary
            )
            .frame(width: 28, height: 32)
            .accessibilityLabel(
              model.activeWebsiteShortcut != nil
                ? "当前接口：\(model.activeWebsiteShortcut?.name ?? "")"
                : "未选择接口配置"
            )

          Button {
            toggleInputMode()
          } label: {
            Image(systemName: "magnifyingglass")
            .font(.body.weight(.medium))
            .foregroundStyle(
              inputMode == .title ? Color.orange : Color.secondary
            )
            .frame(width: 28, height: 32)
            .background(
              inputMode == .title
                ? Color.orange.opacity(0.14)
                : Color.clear,
              in: RoundedRectangle(cornerRadius: 9)
            )
          }
          .buttonStyle(.plain)
          .accessibilityLabel(
            inputMode == .title ? "切换到地址输入" : "切换到片名识别"
          )

          TextField(inputPlaceholder, text: activeInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(inputMode == .address ? .URL : .default)
            .submitLabel(inputMode == .address ? .go : .search)
            .focused($inputFocused)
            .onSubmit(performPrimaryAction)
            .onChange(of: inputTextValue) { _, _ in
              if inputMode == .address {
                inputError = nil
              } else {
                titleError = nil
              }
            }

          if !inputTextValue.isEmpty {
            Button {
              clearInput()
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
              inputMode == .address ? "清除地址" : "清除片名"
            )
          }

          Button(action: performPrimaryAction) {
            Group {
              if isDetectingTitle {
                ProgressView()
                  .controlSize(.small)
                  .tint(.white)
              } else if inputMode == .title {
                Text("识别")
                  .font(.caption.weight(.semibold))
              } else {
                Image(systemName: "arrow.right")
                  .font(.caption.weight(.bold))
              }
            }
            .foregroundStyle(
              isPrimaryActionActive ? Color.white : Color.secondary
            )
            .frame(width: 44, height: 32)
            .background(
              isPrimaryActionActive
                ? Color.orange
                : Color.secondary.opacity(0.12),
              in: Capsule()
            )
          }
          .buttonStyle(.plain)
          .disabled(primaryActionDisabled)
          .accessibilityLabel(
            inputMode == .title ? "识别片名" : "打开或搜索"
          )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
          .secondary.opacity(0.1),
          in: RoundedRectangle(cornerRadius: 15)
        )

        if let modeStatusText {
          HStack(spacing: 6) {
            Text(modeStatusText)
              .font(.caption2)
              .foregroundStyle(modeStatusIsError ? Color.red : Color.secondary)

            if !modeStatusIsError,
              inputMode == .address,
              detectedPages.count > 1
            {
              Menu("切换平台") {
                ForEach(detectedPages) { page in
                  Button(page.platform.displayName) {
                    applyDetectedPage(page)
                  }
                }
              }
              .font(.caption2.weight(.medium))
            }
          }
          .padding(.leading, 72)
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 8)
    .padding(.bottom, 10)
  }

  @ViewBuilder
  private var content: some View {
    if let browser {
      browserContent(browser)
    } else {
      ContentUnavailableView {
        Label("先选择接口配置，再输入或识别视频链接", systemImage: "safari")
      } description: {
        Text("请先在“设置 → 接口配置”中选择接口，输入或识别视频链接后，点击右侧箭头将接口配置与链接拼接并打开。")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func browserContent(_ browser: InAppWebBrowserModel) -> some View {
    VStack(spacing: 0) {
      if browser.isLoading {
        ProgressView(value: browser.progress)
          .progressViewStyle(.linear)
          .tint(.orange)
          .frame(height: 2)
      } else {
        Divider()
      }

      ZStack {
        InAppWebBrowserView(browser: browser)
          .id(ObjectIdentifier(browser))
          .opacity(browser.loadError == nil ? 1 : 0)

        if let loadError = browser.loadError {
          ContentUnavailableView {
            Label("网页加载失败", systemImage: "wifi.exclamationmark")
          } description: {
            Text(loadError)
          } actions: {
            Button("重试") {
              browser.reload()
            }
            .buttonStyle(.borderedProminent)
          }
        }
      }
      .overlay(alignment: .top) {
        if let message = browser.statusMessage {
          Text(message)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
        }
      }
    }
  }

  private var trimmedAddress: String {
    address.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedTitle: String {
    titleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var inputTextValue: String {
    inputMode == .address ? address : titleQuery
  }

  private var activeInput: Binding<String> {
    Binding(
      get: { inputMode == .address ? address : titleQuery },
      set: { value in
        if inputMode == .address {
          address = value
          if let selectedDetectedPage,
            value != selectedDetectedPage.url.absoluteString
          {
            detectedPages = []
            selectedDetectedPageID = nil
          }
        } else {
          titleQuery = value
        }
      }
    )
  }

  private var inputPlaceholder: String {
    inputMode == .address
      ? "输入视频链接"
      : "输入片名识别平台"
  }

  private var primaryActionDisabled: Bool {
    switch inputMode {
    case .address:
      trimmedAddress.isEmpty
    case .title:
      trimmedTitle.isEmpty || isDetectingTitle
    }
  }

  private var isPrimaryActionActive: Bool {
    !primaryActionDisabled || isDetectingTitle
  }

  private var modeStatusText: String? {
    if inputMode == .title, isDetectingTitle {
      return "正在识别片名和平台…"
    }
    if inputMode == .title, let titleError {
      return titleError
    }
    if inputMode == .address, let inputError {
      return inputError
    }
    if inputMode == .address, let selectedDetectedPage {
      return "已识别：\(selectedDetectedPage.platform.displayName)"
    }
    return nil
  }

  private var modeStatusIsError: Bool {
    if inputMode == .title {
      return titleError != nil
    }
    return inputError != nil
  }

  private var selectedDetectedPage: DetectedPlatformPage? {
    detectedPages.first { $0.id == selectedDetectedPageID }
  }

  private func toggleInputMode() {
    inputMode = inputMode == .address ? .title : .address
    inputError = nil
    titleError = nil
    inputFocused = true
  }

  private func performPrimaryAction() {
    switch inputMode {
    case .address:
      openAddress()
    case .title:
      detectTitle()
    }
  }

  private func clearInput() {
    switch inputMode {
    case .address:
      address = ""
      inputError = nil
      browser?.pauseMedia()
      browser = nil
    case .title:
      titleQuery = ""
      titleError = nil
      detectedPages = []
      selectedDetectedPageID = nil
    }
    inputFocused = true
  }

  private func openAddress() {
    guard let interfaceConfig = model.activeWebsiteShortcut else {
      inputError = "未选择接口配置"
      return
    }

    let input = trimmedAddress
    guard !input.isEmpty else {
      inputError = "请输入视频链接"
      return
    }

    guard let url = interfaceConfig.parserURL(for: input) else {
      inputError = "接口配置与地址拼接后不是有效网址"
      return
    }

    openURL(url)
  }

  private func openURL(_ url: URL) {
    inputFocused = false
    inputMode = .address
    inputError = nil
    detectedPages = []
    selectedDetectedPageID = nil
    browser?.pauseMedia()
    address = url.absoluteString
    browser = InAppWebBrowserModel(
      url: url,
      incognito: model.incognitoModeEnabled
    )
  }

  private func detectTitle() {
    let title = trimmedTitle
    guard !title.isEmpty else { return }
    guard title.count <= 80 else {
      titleError = "请输入 1 到 80 个字符的片名"
      return
    }

    detectionTask?.cancel()
    inputFocused = false
    titleError = nil
    isDetectingTitle = true
    detectedPages = []
    selectedDetectedPageID = nil

    detectionTask = Task { @MainActor in
      do {
        let pages = try await VideoPlatformLinkDetector.search(
          title: title,
          session: Self.contentSession
        )
        guard !Task.isCancelled else { return }
        detectedPages = pages
        if let first = pages.first {
          applyDetectedPage(first)
        }
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        detectedPages = []
        selectedDetectedPageID = nil
        titleError = error.localizedDescription
      }
      guard !Task.isCancelled else { return }
      isDetectingTitle = false
      detectionTask = nil
    }
  }

  private func applyDetectedPage(_ page: DetectedPlatformPage) {
    inputMode = .address
    selectedDetectedPageID = page.id
    address = page.url.absoluteString
    inputError = nil
    inputFocused = false
    browser?.pauseMedia()
    browser = nil
  }

}
