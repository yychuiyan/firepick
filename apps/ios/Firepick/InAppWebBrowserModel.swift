import FirepickCore
import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class InAppWebBrowserModel: NSObject {
  let isIncognito: Bool
  let webView: WKWebView

  var progress = 0.0
  var pageTitle = ""
  var currentURL: URL?
  var canGoBack = false
  var isLoading = false
  var loadError: String?
  var statusMessage: String?

  private var progressObservation: NSKeyValueObservation?
  private var titleObservation: NSKeyValueObservation?

  init(url: URL, incognito: Bool) {
    self.isIncognito = incognito

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = incognito
      ? .nonPersistent()
      : WKWebsiteDataStore(
        forIdentifier: UUID(
          uuidString: "C9DB7F92-A13C-4E17-84B1-1F7E20A76CF8"
        )!
      )
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.allowsInlineMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.preferences.isElementFullscreenEnabled = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

    let webView = WKWebView(frame: .zero, configuration: configuration)
    self.webView = webView
    super.init()

    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    webView.allowsLinkPreview = true
    webView.isInspectable = false
    webView.scrollView.keyboardDismissMode = .interactive

    progressObservation = webView.observe(
      \.estimatedProgress,
      options: [.initial, .new]
    ) { [weak self] webView, _ in
      MainActor.assumeIsolated {
        self?.progress = webView.estimatedProgress
      }
    }
    titleObservation = webView.observe(
      \.title,
      options: [.new]
    ) { [weak self] webView, _ in
      MainActor.assumeIsolated {
        self?.pageTitle = webView.title ?? ""
      }
    }

    load(url)
  }

  func load(_ url: URL) {
    loadError = nil
    statusMessage = nil
    var request = URLRequest(
      url: url,
      cachePolicy: .useProtocolCachePolicy,
      timeoutInterval: 30
    )
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
      forHTTPHeaderField: "User-Agent"
    )
    webView.load(request)
    syncNavigationState()
  }

  func reload() {
    loadError = nil
    statusMessage = nil
    webView.reload()
  }

  func goBack() {
    guard webView.canGoBack else { return }
    webView.goBack()
  }

  func pauseMedia() {
    webView.evaluateJavaScript(
      "document.querySelectorAll('video,audio').forEach(function(node){node.pause()});"
    )
  }

  private func syncNavigationState() {
    currentURL = webView.url
    pageTitle = webView.title ?? pageTitle
    canGoBack = webView.canGoBack
    isLoading = webView.isLoading
    progress = webView.estimatedProgress
  }

  private func setLoadError(_ message: String) {
    loadError = message
    isLoading = false
    syncNavigationState()
  }
}

extension InAppWebBrowserModel: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    guard navigationAction.targetFrame?.isMainFrame != false,
      let url = navigationAction.request.url
    else {
      decisionHandler(.allow)
      return
    }

    let scheme = url.scheme?.lowercased()
    if scheme == "about" || scheme == "data" || scheme == "blob" {
      decisionHandler(.allow)
      return
    }
    if scheme == "http" || scheme == "https" {
      decisionHandler(.allow)
      return
    }

    statusMessage = "此页面需要系统或其他应用打开"
    decisionHandler(.cancel)
  }

  func webView(
    _ webView: WKWebView,
    didStartProvisionalNavigation navigation: WKNavigation!
  ) {
    isLoading = true
    loadError = nil
    statusMessage = nil
    syncNavigationState()
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    syncNavigationState()
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    isLoading = false
    loadError = nil
    syncNavigationState()
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    setLoadError("页面加载失败，请重试。")
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    setLoadError("页面加载失败，请检查网络后重试。")
  }
}

extension InAppWebBrowserModel: WKUIDelegate {
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    guard let url = navigationAction.request.url else { return nil }
    if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
      webView.load(URLRequest(url: url))
    } else {
      statusMessage = "此页面需要系统或其他应用打开"
    }
    return nil
  }
}
