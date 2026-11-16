import SwiftUI
import WebKit

struct InAppWebBrowserView: UIViewRepresentable {
  let browser: InAppWebBrowserModel

  func makeUIView(context: Context) -> WKWebView {
    browser.webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {}
}
