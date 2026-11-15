import Foundation
import WebKit

/// Last-resort resolver for player pages that fetch their HLS URL only after
/// JavaScript runs. It observes the page rather than embedding a visible player.
@MainActor
final class DynamicPlaybackPageResolver {
  static let shared = DynamicPlaybackPageResolver()

  private var inFlight: [String: Task<URL?, Never>] = [:]

  func resolve(
    pageURL: URL,
    headers: [String: String],
    timeout: TimeInterval = 8
  ) async -> URL? {
    let key = pageURL.absoluteString
    if let task = inFlight[key] {
      return await task.value
    }
    let task = Task<URL?, Never> { @MainActor in
      await DynamicPlaybackResolutionSession(
        pageURL: pageURL,
        headers: headers,
        timeout: timeout
      ).run()
    }
    inFlight[key] = task
    let result = await task.value
    inFlight.removeValue(forKey: key)
    return result
  }
}

@MainActor
private final class DynamicPlaybackResolutionSession: NSObject,
  WKNavigationDelegate, WKScriptMessageHandler
{
  private static let messageName = "firepickMedia"
  private let pageURL: URL
  private let headers: [String: String]
  private let timeout: TimeInterval
  private var webView: WKWebView?
  private var continuation: CheckedContinuation<URL?, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var validationTask: Task<Void, Never>?
  private var candidates = Set<String>()
  private var didFinish = false

  init(pageURL: URL, headers: [String: String], timeout: TimeInterval) {
    self.pageURL = pageURL
    self.headers = headers
    self.timeout = timeout
  }

  func run() async -> URL? {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      start()
    }
  }

  private func start() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    let controller = WKUserContentController()
    controller.add(self, name: Self.messageName)
    controller.addUserScript(
      WKUserScript(
        source: Self.observerScript(messageName: Self.messageName),
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
      )
    )
    configuration.userContentController = controller

    let webView = WKWebView(
      frame: CGRect(x: 0, y: 0, width: 390, height: 844),
      configuration: configuration
    )
    webView.isHidden = true
    webView.navigationDelegate = self
    self.webView = webView

    var request = URLRequest(
      url: pageURL,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: timeout
    )
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
      forHTTPHeaderField: "User-Agent"
    )
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    webView.load(request)

    timeoutTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(self?.timeout ?? 8))
      guard !Task.isCancelled else { return }
      self?.finish(nil)
    }
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard !didFinish, message.name == Self.messageName,
      let raw = message.body as? String,
      let candidate = URL(string: raw, relativeTo: webView?.url ?? pageURL)?.absoluteURL,
      let scheme = candidate.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      candidate.absoluteString.lowercased().contains(".m3u8"),
      candidates.insert(candidate.absoluteString).inserted
    else { return }

    if validationTask != nil { return }
    validationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      if await Self.validateHLS(candidate, referer: pageURL) {
        finish(candidate)
      } else {
        validationTask = nil
      }
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    webView.evaluateJavaScript(Self.rescanScript) { _, _ in }
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    finish(nil)
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    finish(nil)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    finish(nil)
  }

  private func finish(_ result: URL?) {
    guard !didFinish else { return }
    didFinish = true
    timeoutTask?.cancel()
    timeoutTask = nil
    validationTask?.cancel()
    validationTask = nil
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.configuration.userContentController.removeScriptMessageHandler(
      forName: Self.messageName
    )
    webView?.removeFromSuperview()
    webView = nil
    let continuation = continuation
    self.continuation = nil
    continuation?.resume(returning: result)
  }

  private static func validateHLS(_ url: URL, referer: URL) async -> Bool {
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: 3
    )
    request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
    request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse,
        (200..<300).contains(http.statusCode)
      else { return false }
      if (http.mimeType ?? "").lowercased().contains("mpegurl") {
        return true
      }
      return String(data: data.prefix(1024), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .hasPrefix("#EXTM3U") == true
    } catch {
      return false
    }
  }

  private static func observerScript(messageName: String) -> String {
    #"""
    (function() {
      if (window.__firepickMediaObserver) return;
      window.__firepickMediaObserver = true;
      const send = function(value) {
        try {
          if (!value) return;
          const url = new URL(String(value), document.baseURI).href;
          if (!/\.m3u8(?:[?#]|$)/i.test(url)) return;
          window.webkit.messageHandlers.\#(messageName).postMessage(url);
        } catch (_) {}
      };
      const originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = function(input) {
          try { send(typeof input === "string" ? input : input && input.url); } catch (_) {}
          return originalFetch.apply(this, arguments);
        };
      }
      const originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        send(url);
        return originalOpen.apply(this, arguments);
      };
      const mediaDescriptor = window.HTMLMediaElement
        ? Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "src")
        : null;
      if (mediaDescriptor && mediaDescriptor.set && window.HTMLMediaElement) {
        Object.defineProperty(HTMLMediaElement.prototype, "src", {
          configurable: true,
          enumerable: mediaDescriptor.enumerable,
          get: mediaDescriptor.get,
          set: function(value) {
            send(value);
            return mediaDescriptor.set.call(this, value);
          }
        });
      }
      const scan = function() {
        try {
          document.querySelectorAll("video,source").forEach(function(node) {
            send(node.src || node.getAttribute("src"));
          });
          performance.getEntriesByType("resource").forEach(function(entry) {
            send(entry.name);
          });
          if (window.Hls && window.Hls.prototype) {
            const originalLoadSource = window.Hls.prototype.loadSource;
            if (originalLoadSource && !originalLoadSource.__firepickWrapped) {
              const wrapped = function(source) {
                send(source);
                return originalLoadSource.apply(this, arguments);
              };
              wrapped.__firepickWrapped = true;
              window.Hls.prototype.loadSource = wrapped;
            }
          }
        } catch (_) {}
      };
      setInterval(scan, 500);
      document.addEventListener("DOMContentLoaded", scan);
      const observeDocument = function() {
        if (!document.documentElement) return false;
        new MutationObserver(scan).observe(document.documentElement, {
          childList: true, subtree: true, attributes: true, attributeFilter: ["src"]
        });
        return true;
      };
      if (!observeDocument()) {
        document.addEventListener("readystatechange", observeDocument);
      }
      scan();
    })();
    """#
  }

  private static let rescanScript = "window.dispatchEvent(new Event('DOMContentLoaded'));"
}
