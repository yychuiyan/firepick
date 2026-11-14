import CryptoKit
import FirepickCore
import Foundation

#if canImport(JavaScriptCore)
  @preconcurrency import JavaScriptCore
#endif

/// Full on-device CatVod JS host for iOS/macOS via JavaScriptCore.
///
/// Implements the Spider lifecycle plus the `catvod` module surface used by
/// FongMi-style QuickJS spiders: `Spider`, `net`, `local`, `htmlQuery` /
/// pdfh-family globals, `link` / `page`, and common crypto helpers.
///
/// Intentionally omitted (need UI / WebView / WASM runtime): dialog sheets,
/// in-app WebView, WebAssembly, and Node-compat APIs. Those remain Bridge-only.
public final class OnDeviceJavaScriptHost: QuickJSHost, @unchecked Sendable {
  private let session: URLSession
  private let transportSession: URLSession
  private let defaults: UserDefaults
  private let baseURL: URL?
  private let jsQueue = DispatchQueue(label: "app.firepick.javascript-host")
  private let preparationQueue = DispatchQueue(
    label: "app.firepick.javascript-preparation"
  )
  private var preparedSources: [String: String] = [:]
  private var preparationTasks: [String: Task<String, Error>] = [:]
  #if canImport(JavaScriptCore)
    private final class JavaScriptExceptionState {
      var value: JSValue?
    }

    private final class JavaScriptSession {
      let api: String
      let scriptURL: URL
      let context: JSContext
      let target: JSValue
      let exceptions: JavaScriptExceptionState

      init(
        api: String,
        scriptURL: URL,
        context: JSContext,
        target: JSValue,
        exceptions: JavaScriptExceptionState
      ) {
        self.api = api
        self.scriptURL = scriptURL
        self.context = context
        self.target = target
        self.exceptions = exceptions
      }
    }

    private var currentSession: JavaScriptSession?
  #endif

  public init(
    session: URLSession = .shared,
    defaults: UserDefaults = .standard,
    baseURL: URL? = nil
  ) {
    self.session = session
    // Prefer a copy so tests can inject URLProtocol; otherwise use a clean
    // ephemeral session that never shares URLCache with URLSession.shared.
    let configuration: URLSessionConfiguration
    if session.configuration.protocolClasses?.isEmpty == false {
      configuration =
        (session.configuration.copy() as? URLSessionConfiguration)
        ?? URLSessionConfiguration.ephemeral
    } else {
      configuration = URLSessionConfiguration.ephemeral
    }
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.waitsForConnectivity = false
    self.transportSession = URLSession(configuration: configuration)
    self.defaults = defaults
    self.baseURL = baseURL
  }

  public func invoke(
    api: String,
    ext: JSONValue?,
    method: ProviderMethod,
    arguments: [JSONValue]
  ) async throws -> MediaResult {
    #if canImport(JavaScriptCore)
      let scriptURL = try Self.url(from: api)
      let source = try await downloadScript(from: scriptURL)
      NSLog(
        "Firepick JS prepare begin api=%@ bytes=%ld",
        scriptURL.absoluteString,
        source.utf8.count
      )
      let prepared = try await prepare(source: source, scriptURL: scriptURL)
      NSLog(
        "Firepick JS prepare done api=%@ preparedBytes=%ld",
        scriptURL.absoluteString,
        prepared.utf8.count
      )
      return try await runOnJSQueue {
        let jsSession = try self.session(
          api: api,
          source: prepared,
          scriptURL: scriptURL,
          ext: ext
        )
        NSLog(
          "Firepick JS spider ready api=%@ method=%@",
          api,
          method.rawValue
        )
        let result = try self.invoke(
          session: jsSession,
          method: method,
          arguments: arguments
        )
        NSLog(
          "Firepick JS %@ classes=%ld list=%ld",
          method.rawValue,
          result.classes.count,
          result.list.count
        )
        return result
      }
    #else
      throw FirepickError.unsupported("当前平台没有 JavaScriptCore")
    #endif
  }

  public func destroy() async {
    #if canImport(JavaScriptCore)
      _ = try? await runOnJSQueue {
        guard let session = self.currentSession else { return }
        if session.target.hasProperty("destroy") {
          _ = try? self.awaitJS(
            session.target.invokeMethod("destroy", withArguments: []),
            in: session.context
          )
        }
        self.currentSession = nil
      }
    #endif
  }

  private func downloadScript(from url: URL) async throws -> String {
    // Prefer the app-bundled official list so an old COS copy cannot empty the
    // home grid. Custom hosts with the same filename still load their own JS.
    let officialBundledHost =
      url.host?.lowercased() == "dl.yychuiyan.com"
      || url.host?.lowercased() == "firepick-1302621537.cos.ap-shanghai.myqcloud.com"
    if officialBundledHost,
      url.path.contains("firepick-cms.js"),
      let bundled = Self.bundledScript(for: url)
    {
      NSLog(
        "Firepick JS prefer bundled url=%@ bytes=%ld",
        url.absoluteString,
        bundled.utf8.count
      )
      return bundled
    }
    do {
      let remote = try await fetchRemoteScript(from: url)
      NSLog(
        "Firepick JS download ok url=%@ bytes=%ld",
        url.absoluteString,
        remote.utf8.count
      )
      return remote
    } catch {
      if let bundled = Self.bundledScript(for: url) {
        NSLog(
          "Firepick JS download fallback bundled url=%@ error=%@ bytes=%ld",
          url.absoluteString,
          error.localizedDescription,
          bundled.utf8.count
        )
        return bundled
      }
      NSLog(
        "Firepick JS download failed url=%@ error=%@",
        url.absoluteString,
        error.localizedDescription
      )
      throw error
    }
  }

  private func fetchRemoteScript(from url: URL) async throws -> String {
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: 20
    )
    request.assumesHTTP3Capable = false
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    request.setValue(
      "\"firepick-source-\(UUID().uuidString)\"",
      forHTTPHeaderField: "If-None-Match"
    )
    request.setValue(
      "Thu, 01 Jan 1970 00:00:00 GMT",
      forHTTPHeaderField: "If-Modified-Since"
    )
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
      forHTTPHeaderField: "User-Agent"
    )

    var (data, response) = try await transportSession.data(for: request)
    var status = (response as? HTTPURLResponse)?.statusCode ?? -1
    NSLog(
      "Firepick JS download response url=%@ status=%ld bytes=%ld empty=%@",
      url.absoluteString,
      status,
      data.count,
      data.isEmpty ? "yes" : "no"
    )

    // Simulator proxy/QUIC often yields empty 304 bodies. Retry once with a
    // cache-buster, then fall through to the bundled copy if still empty.
    if status == 304 || data.isEmpty {
      request.url = Self.retryURL(for: url)
      (data, response) = try await transportSession.data(for: request)
      status = (response as? HTTPURLResponse)?.statusCode ?? -1
      NSLog(
        "Firepick JS download retry url=%@ status=%ld bytes=%ld empty=%@",
        request.url?.absoluteString ?? url.absoluteString,
        status,
        data.count,
        data.isEmpty ? "yes" : "no"
      )
    }

    if let http = response as? HTTPURLResponse,
      !(200..<300).contains(http.statusCode)
    {
      throw FirepickError.network("JS 源 HTTP \(http.statusCode)")
    }
    guard !data.isEmpty,
      let text = String(data: data, encoding: .utf8),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw FirepickError.provider(
        "JS 源响应为空（status=\(status)）。Simulator 代理/缓存可能导致空 304。"
      )
    }
    return text
  }

  private static func bundledScript(for url: URL) -> String? {
    let filename = url.deletingPathExtension().lastPathComponent
    // Strip query-only clones: firepick-cms.js?v=4 → firepick-cms
    let resourceName =
      URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .path
      .split(separator: "/")
      .last
      .map { ($0 as NSString).deletingPathExtension }
      ?? filename
    let ext =
      URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .path
      .split(separator: "/")
      .last
      .map { ($0 as NSString).pathExtension }
      ?? url.pathExtension
    guard !resourceName.isEmpty,
      let resource = Bundle.module.url(
        forResource: resourceName,
        withExtension: ext.isEmpty ? "js" : ext
      ),
      let text = try? String(contentsOf: resource, encoding: .utf8),
      !text.isEmpty
    else {
      return nil
    }
    return text
  }

  private static func retryURL(for url: URL) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url
    }
    var query = components.queryItems ?? []
    query.removeAll { $0.name == "_firepick_retry" }
    query.append(
      URLQueryItem(
        name: "_firepick_retry",
        value: String(Int(Date().timeIntervalSince1970))
      )
    )
    components.queryItems = query
    return components.url ?? url
  }

  private func prepare(source: String, scriptURL: URL) async throws -> String {
    let key = scriptURL.absoluteString
    let existing: (String?, Task<String, Error>?) = preparationQueue.sync {
      (preparedSources[key], preparationTasks[key])
    }
    if let cached = existing.0 {
      return cached
    }
    if let task = existing.1 {
      return try await task.value
    }
    let loader = JavaScriptModuleLoader(session: transportSession, baseURL: baseURL)
    let task = Task {
      try await loader.prepare(source: source, scriptURL: scriptURL)
    }
    preparationQueue.sync {
      preparationTasks[key] = task
    }

    do {
      let prepared = try await task.value
      preparationQueue.sync {
        preparedSources[key] = prepared
        preparationTasks.removeValue(forKey: key)
      }
      return prepared
    } catch {
      _ = preparationQueue.sync {
        preparationTasks.removeValue(forKey: key)
      }
      throw error
    }
  }

  private static func url(from api: String) throws -> URL {
    guard let url = URL(string: api), url.scheme == "http" || url.scheme == "https" else {
      throw FirepickError.invalidConfiguration("JS 源地址无效：\(api)")
    }
    return url
  }

  private func runOnJSQueue<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      jsQueue.async {
        do {
          continuation.resume(returning: try work())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  #if canImport(JavaScriptCore)
    private func session(
      api: String,
      source: String,
      scriptURL: URL,
      ext: JSONValue?
    ) throws -> JavaScriptSession {
      if let currentSession, currentSession.api == api {
        return currentSession
      }
      guard let context = JSContext() else {
        throw FirepickError.unsupported("无法创建 JSContext")
      }
      let exceptions = JavaScriptExceptionState()
      context.exceptionHandler = { _, exception in
        exceptions.value = exception
      }

      installRuntime(into: context)
      context.evaluateScript(Self.catvodModuleSource, withSourceURL: URL(string: "catvod.js"))
      context.evaluateScript(Self.wrapSpiderSource(source), withSourceURL: scriptURL)
      if let exception = exceptions.value {
        throw FirepickError.provider("JS 加载失败：\(exception)")
      }

      guard let target = context.objectForKeyedSubscript("__firepickSpider"),
        !target.isUndefined, !target.isNull
      else {
        throw FirepickError.provider("JS 源未导出默认 Spider（需 export default class extends Spider）")
      }

      if target.hasProperty("init") {
        exceptions.value = nil
        let extArg = Self.jsValue(from: ext ?? .string(""), in: context)
        _ = try awaitJS(target.invokeMethod("init", withArguments: [extArg]), in: context)
        if let exception = exceptions.value {
          throw FirepickError.provider("JS init 失败：\(exception)")
        }
      }

      let result = JavaScriptSession(
        api: api,
        scriptURL: scriptURL,
        context: context,
        target: target,
        exceptions: exceptions
      )
      currentSession = result
      return result
    }

    private func invoke(
      session: JavaScriptSession,
      method: ProviderMethod,
      arguments: [JSONValue]
    ) throws -> MediaResult {
      let context = session.context
      guard let methodName = supportedMethod(for: method, target: session.target)
      else {
        throw FirepickError.provider("JS 未实现 \(method.rawValue)")
      }

      let jsArgs = adaptedArguments(
        arguments,
        methodName: methodName,
        in: context
      )
      session.exceptions.value = nil
      let raw = session.target.invokeMethod(methodName, withArguments: jsArgs)
      if let exception = session.exceptions.value {
        throw FirepickError.provider("JS \(method.rawValue) 失败：\(exception)")
      }
      guard let raw else {
        throw FirepickError.provider("JS 未实现 \(method.rawValue)")
      }
      let resolved = try awaitJS(raw, in: context)
      if let exception = session.exceptions.value {
        throw FirepickError.provider("JS \(method.rawValue) 失败：\(exception)")
      }
      if method == .liveContent {
        var result = MediaResult()
        result.rawContent = rawString(from: resolved, in: context)
        return result
      }
      return try Self.decodeMediaResult(
        resolved,
        in: context,
        scriptURL: session.scriptURL
      )
    }

    private func supportedMethod(
      for method: ProviderMethod,
      target: JSValue
    ) -> String? {
      let candidates: [String]
      switch method {
      case .homeContent:
        candidates = ["homeContent", "home"]
      case .homeVideoContent:
        candidates = ["homeVideoContent", "homeVod"]
      case .categoryContent:
        candidates = ["categoryContent", "category"]
      case .searchContent:
        candidates = ["searchContent", "search"]
      case .detailContent:
        candidates = ["detailContent", "detail"]
      case .playerContent:
        candidates = ["playerContent", "play"]
      case .liveContent:
        candidates = ["liveContent", "live"]
      case .action:
        candidates = ["action"]
      default:
        candidates = [method.rawValue]
      }
      return candidates.first { name in
        let value = target.objectForKeyedSubscript(name)
        return value?.isUndefined == false && value?.isNull == false
      }
    }

    private func adaptedArguments(
      _ arguments: [JSONValue],
      methodName: String,
      in context: JSContext
    ) -> [JSValue] {
      if methodName == "detail", let first = arguments.first,
        case .array(let values) = first, let id = values.first
      {
        return [Self.jsValue(from: id, in: context)]
      }
      return arguments.map { Self.jsValue(from: $0, in: context) }
    }

    private func rawString(from value: JSValue, in context: JSContext) -> String {
      if value.isString {
        return value.toString() ?? ""
      }
      if value.isUndefined || value.isNull {
        return ""
      }
      guard let data = try? JSONSerialization.data(withJSONObject: value.toObject() as Any),
        let text = String(data: data, encoding: .utf8)
      else {
        return value.toString() ?? ""
      }
      return text
    }

    private func installRuntime(into context: JSContext) {
      let host = self

      let req: @convention(block) (JSValue?, JSValue?, JSValue?) -> Any? = {
        urlValue, optionsValue, _ in
        guard let context = JSContext.current() else { return nil }
        guard let urlString = urlValue?.toString(),
          let url = URL(string: urlString)
        else {
          return Self.rejectedPromise(in: context, message: "net.req 需要 URL")
        }
        let options = Self.dictionary(from: optionsValue) ?? [:]
        return host.makeRequestPromise(url: url, options: options, in: context)
      }
      context.setObject(req, forKeyedSubscript: "__firepickNetReq" as NSString)

      let pdfh: @convention(block) (JSValue?, JSValue?) -> String = { html, rule in
        CatVodHTMLQuery.pdfh(html?.toString() ?? "", rule: rule?.toString() ?? "")
      }
      let pd: @convention(block) (JSValue?, JSValue?, JSValue?) -> String = { html, rule, key in
        CatVodHTMLQuery.pd(
          html?.toString() ?? "",
          rule: rule?.toString() ?? "",
          urlKey: key?.toString() ?? ""
        )
      }
      let pdfa: @convention(block) (JSValue?, JSValue?) -> [String] = { html, rule in
        CatVodHTMLQuery.pdfa(html?.toString() ?? "", rule: rule?.toString() ?? "")
      }
      let pdfl:
        @convention(block) (JSValue?, JSValue?, JSValue?, JSValue?, JSValue?) -> [[String: String]] =
          { html, rule, texts, urls, key in
            CatVodHTMLQuery.pdfl(
              html?.toString() ?? "",
              rule: rule?.toString() ?? "",
              texts: texts?.toString() ?? "",
              urls: urls?.toString() ?? "",
              urlKey: key?.toString() ?? ""
            )
          }
      context.setObject(pdfh, forKeyedSubscript: "pdfh" as NSString)
      context.setObject(pd, forKeyedSubscript: "pd" as NSString)
      context.setObject(pdfa, forKeyedSubscript: "pdfa" as NSString)
      context.setObject(pdfl, forKeyedSubscript: "pdfl" as NSString)

      let localGet: @convention(block) (JSValue?) -> String = { key in
        host.defaults.string(forKey: Self.localKey(key?.toString() ?? "")) ?? ""
      }
      let localSet: @convention(block) (JSValue?, JSValue?) -> Bool = { key, value in
        host.defaults.set(value?.toString() ?? "", forKey: Self.localKey(key?.toString() ?? ""))
        return true
      }
      let localDelete: @convention(block) (JSValue?) -> Bool = { key in
        host.defaults.removeObject(forKey: Self.localKey(key?.toString() ?? ""))
        return true
      }
      context.setObject(localGet, forKeyedSubscript: "__firepickLocalGet" as NSString)
      context.setObject(localSet, forKeyedSubscript: "__firepickLocalSet" as NSString)
      context.setObject(localDelete, forKeyedSubscript: "__firepickLocalDelete" as NSString)

      let join: @convention(block) (JSValue?, JSValue?) -> String = { base, relative in
        CatVodHTMLQuery.joinURL(base?.toString() ?? "", relative?.toString() ?? "")
      }
      context.setObject(join, forKeyedSubscript: "__firepickJoinURL" as NSString)

      let md5: @convention(block) (JSValue?) -> String = { value in
        Self.md5Hex(value?.toString() ?? "")
      }
      let sha256: @convention(block) (JSValue?) -> String = { value in
        Self.sha256Hex(value?.toString() ?? "")
      }
      let b64e: @convention(block) (JSValue?) -> String = { value in
        Data((value?.toString() ?? "").utf8).base64EncodedString()
      }
      let b64d: @convention(block) (JSValue?) -> String = { value in
        guard let data = Data(base64Encoded: value?.toString() ?? "") else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
      }
      context.setObject(md5, forKeyedSubscript: "__firepickMD5" as NSString)
      context.setObject(sha256, forKeyedSubscript: "__firepickSHA256" as NSString)
      context.setObject(b64e, forKeyedSubscript: "__firepickB64E" as NSString)
      context.setObject(b64d, forKeyedSubscript: "__firepickB64D" as NSString)

      let aesX:
        @convention(block) (
          JSValue?, JSValue?, JSValue?, JSValue?, JSValue?, JSValue?, JSValue?
        ) -> String = { mode, encrypt, input, inBase64, key, iv, outBase64 in
          CatVodCrypto.aes(
            mode: mode?.toString() ?? "",
            encrypt: encrypt?.toBool() ?? false,
            input: input?.toString() ?? "",
            inputBase64: inBase64?.toBool() ?? false,
            key: key?.toString() ?? "",
            iv: iv?.toString() ?? "",
            outputBase64: outBase64?.toBool() ?? false
          )
        }
      let desX:
        @convention(block) (
          JSValue?, JSValue?, JSValue?, JSValue?, JSValue?, JSValue?, JSValue?
        ) -> String = { mode, encrypt, input, inBase64, key, iv, outBase64 in
          CatVodCrypto.des(
            mode: mode?.toString() ?? "",
            encrypt: encrypt?.toBool() ?? false,
            input: input?.toString() ?? "",
            inputBase64: inBase64?.toBool() ?? false,
            key: key?.toString() ?? "",
            iv: iv?.toString() ?? "",
            outputBase64: outBase64?.toBool() ?? false
          )
        }
      let rsaX:
        @convention(block) (
          JSValue?, JSValue?, JSValue?, JSValue?, JSValue?, JSValue?, JSValue?
        ) -> String = { mode, pub, encrypt, input, inBase64, key, outBase64 in
          CatVodCrypto.rsa(
            mode: mode?.toString() ?? "",
            publicKey: pub?.toBool() ?? true,
            encrypt: encrypt?.toBool() ?? false,
            input: input?.toString() ?? "",
            inputBase64: inBase64?.toBool() ?? false,
            key: key?.toString() ?? "",
            outputBase64: outBase64?.toBool() ?? false
          )
        }
      context.setObject(aesX, forKeyedSubscript: "__firepickAESX" as NSString)
      context.setObject(desX, forKeyedSubscript: "__firepickDESX" as NSString)
      context.setObject(rsaX, forKeyedSubscript: "__firepickRSAX" as NSString)

      let log: @convention(block) (JSValue?) -> Void = { value in
        NSLog("Firepick JS: %@", value?.toString() ?? "")
      }
      context.setObject(log, forKeyedSubscript: "__firepickLog" as NSString)

      let sleep: @convention(block) (JSValue?) -> Void = { value in
        let milliseconds = max(0, value?.toDouble() ?? 0)
        Thread.sleep(forTimeInterval: milliseconds / 1000)
      }
      context.setObject(sleep, forKeyedSubscript: "__firepickSleep" as NSString)
    }

    private func makeRequestPromise(url: URL, options: [String: Any], in context: JSContext)
      -> JSValue
    {
      let deferred = context.evaluateScript(
        """
        (function() {
          var d = {};
          d.promise = new Promise(function(resolve, reject) {
            d.resolve = resolve;
            d.reject = reject;
          });
          return d;
        })()
        """
      )!
      let resolve = deferred.objectForKeyedSubscript("resolve")
      let reject = deferred.objectForKeyedSubscript("reject")
      let promise = deferred.objectForKeyedSubscript("promise")!

      // Respect JS timeout (Douban title-match uses ~4s). Floor 4s so a brief
      // cellular blip still retries; the old 12s floor made Promise.all of
      // chart matching blow the 20s category budget →「网络超时 / 源无响应」.
      let requestedTimeoutMs =
        (options["timeout"] as? NSNumber)?.doubleValue
        ?? (options["timeout"] as? Double)
        ?? 15000
      let timeoutMs = max(requestedTimeoutMs, 4_000)
      let method = (options["method"] as? String)?.uppercased() ?? "GET"
      let requestURL = urlApplying(
        params: options["params"] as? [String: Any],
        to: url
      )
      var headers = options["headers"] as? [String: Any] ?? [:]
      let requestBody = requestBody(from: options, headers: &headers)
      let buffer =
        (options["buffer"] as? NSNumber)?.intValue
        ?? (options["buffer"] as? Double).map(Int.init)
        ?? 0

      var request = URLRequest(
        url: requestURL,
        cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
        timeoutInterval: max(1, timeoutMs / 1000)
      )
      request.assumesHTTP3Capable = false
      request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
      request.setValue("no-cache", forHTTPHeaderField: "Pragma")
      request.httpMethod = method
      for (key, value) in headers {
        request.setValue("\(value)", forHTTPHeaderField: key)
      }
      request.httpBody = requestBody

      // Return a pending Promise immediately so JS `Promise.all` can overlap
      // requests. Completions are hoppped onto this thread's RunLoop, which
      // `awaitJS` pumps while waiting — never `jsQueue.async` (same-queue deadlock).
      let runLoop = RunLoop.current
      let cfRunLoop = runLoop.getCFRunLoop()
      let box = RequestBox()
      let settlement = RequestSettlement { data, response, error in
        CFRunLoopPerformBlock(cfRunLoop, CFRunLoopMode.commonModes.rawValue) {
          guard !box.settled else { return }
          box.settled = true
          if let error {
            NSLog(
              "Firepick JS net.req failed url=%@ error=%@",
              requestURL.absoluteString,
              error.localizedDescription
            )
            reject?.call(withArguments: [error.localizedDescription])
            return
          }
          let body = data ?? Data()
          let http = response as? HTTPURLResponse
          NSLog(
            "Firepick JS net.req url=%@ status=%ld bytes=%ld",
            requestURL.absoluteString,
            http?.statusCode ?? 0,
            body.count
          )
          var headerMap: [String: String] = [:]
          http?.allHeaderFields.forEach { key, value in
            headerMap["\(key)"] = "\(value)"
          }
          let payload = JSValue(newObjectIn: context)!
          payload.setObject(http?.statusCode ?? 0, forKeyedSubscript: "code")
          payload.setObject(headerMap, forKeyedSubscript: "headers")
          payload.setObject(
            http?.url?.absoluteString ?? requestURL.absoluteString,
            forKeyedSubscript: "url"
          )
          switch buffer {
          case 1:
            payload.setObject(
              Array(body).map { NSNumber(value: $0) },
              forKeyedSubscript: "content"
            )
          case 2:
            payload.setObject(
              body.base64EncodedString(),
              forKeyedSubscript: "content"
            )
          case 3:
            let bytes = body.map(String.init).joined(separator: ",")
            let arrayBuffer = context.evaluateScript(
              "(function(){ var a = new Uint8Array([\(bytes)]); return a.buffer; })()"
            )
            payload.setObject(arrayBuffer, forKeyedSubscript: "content")
          default:
            payload.setObject(
              String(decoding: body, as: UTF8.self),
              forKeyedSubscript: "content"
            )
          }
          resolve?.call(withArguments: [payload])
        }
        CFRunLoopWakeUp(cfRunLoop)
      }

      transportSession.dataTask(with: request) { data, response, error in
        settlement.settle(data, response, error)
      }.resume()

      let timeoutSeconds = max(1.0, timeoutMs / 1000) + 5
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
        settlement.settle(nil, nil, RequestError.timeout)
      }

      return promise
    }

    private func urlApplying(params: [String: Any]?, to url: URL) -> URL {
      guard let params, !params.isEmpty,
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      else {
        return url
      }
      var query = components.queryItems ?? []
      for key in params.keys.sorted() {
        let value = params[key]
        if let values = value as? [Any] {
          query.append(
            contentsOf: values.map {
              URLQueryItem(name: key, value: "\($0)")
            })
        } else {
          query.append(URLQueryItem(name: key, value: "\(value ?? "")"))
        }
      }
      components.queryItems = query
      return components.url ?? url
    }

    private func requestBody(
      from options: [String: Any],
      headers: inout [String: Any]
    ) -> Data? {
      if let body = options["body"] {
        if let text = body as? String {
          return Data(text.utf8)
        }
        if let values = body as? [NSNumber] {
          return Data(values.map(\.uint8Value))
        }
        if let values = body as? [Int] {
          return Data(values.map { UInt8(clamping: $0) })
        }
      }
      guard let data = options["data"] else { return nil }
      if let text = data as? String {
        return Data(text.utf8)
      }
      let postType = (options["postType"] as? String)?.lowercased() ?? "json"
      if postType == "form", let object = data as? [String: Any] {
        var components = URLComponents()
        components.queryItems =
          object
          .sorted { $0.key < $1.key }
          .map { URLQueryItem(name: $0.key, value: "\($0.value)") }
        if headers.keys.first(where: {
          $0.caseInsensitiveCompare("Content-Type") == .orderedSame
        }) == nil {
          headers["Content-Type"] = "application/x-www-form-urlencoded"
        }
        return components.percentEncodedQuery?.data(using: .utf8)
      }
      guard JSONSerialization.isValidJSONObject(data),
        let encoded = try? JSONSerialization.data(withJSONObject: data)
      else {
        return nil
      }
      if headers.keys.first(where: {
        $0.caseInsensitiveCompare("Content-Type") == .orderedSame
      }) == nil {
        headers["Content-Type"] = "application/json"
      }
      return encoded
    }

    private final class RequestBox: @unchecked Sendable {
      var settled = false
      var data: Data?
      var response: URLResponse?
      var error: Error?
    }

    private final class RequestSettlement: @unchecked Sendable {
      private let action: (Data?, URLResponse?, Error?) -> Void

      init(action: @escaping (Data?, URLResponse?, Error?) -> Void) {
        self.action = action
      }

      func settle(_ data: Data?, _ response: URLResponse?, _ error: Error?) {
        action(data, response, error)
      }
    }

    private enum RequestError: LocalizedError {
      case timeout

      var errorDescription: String? {
        "JS 网络请求超时"
      }
    }

    private static func rejectedPromise(in context: JSContext, message: String) -> JSValue {
      context.evaluateScript("Promise.reject(\(Self.jsStringLiteral(message)))")!
    }

    private static func jsStringLiteral(_ value: String) -> String {
      let escaped =
        value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")
        .replacingOccurrences(of: "\n", with: "\\n")
      return "'\(escaped)'"
    }

    private func awaitJS(_ value: JSValue?, in context: JSContext) throws -> JSValue {
      guard let value else {
        return JSValue(nullIn: context)
      }
      // hasProperty on undefined/null raises TypeError in JSC and pollutes exceptionHandler.
      if value.isUndefined || value.isNull {
        return value
      }
      if !value.hasProperty("then") {
        return value
      }
      let lock = DispatchSemaphore(value: 0)
      var resolved: JSValue?
      var rejected: String?
      let onResolve: @convention(block) (JSValue?) -> Void = { result in
        resolved = result ?? JSValue(nullIn: context)
        lock.signal()
      }
      let onReject: @convention(block) (JSValue?) -> Void = { error in
        rejected = error?.toString() ?? "Promise rejected"
        lock.signal()
      }
      guard let resolveValue = JSValue(object: onResolve, in: context),
        let rejectValue = JSValue(object: onReject, in: context)
      else {
        throw FirepickError.provider("无法绑定 Promise 回调")
      }
      value.invokeMethod("then", withArguments: [resolveValue])
      value.invokeMethod("catch", withArguments: [rejectValue])
      // Pump the concurrent request queue while waiting for JS promises that
      // depend on __firepickNetReq completing on a background queue.
      let deadline = Date().addingTimeInterval(60)
      while lock.wait(timeout: .now() + 0.05) == .timedOut {
        if Date() > deadline {
          throw FirepickError.provider("JS Promise 超时")
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
      }
      if let rejected {
        throw FirepickError.provider(rejected)
      }
      return resolved ?? JSValue(nullIn: context)
    }

    private static func wrapSpiderSource(_ source: String) -> String {
      var text = source
      text = text.replacingOccurrences(
        of: #"import\s*\{([^}]*)\}\s*from\s*['"]catvod['"]\s*;?"#,
        with: "var {$1} = requireCatvod();",
        options: .regularExpression
      )
      text = text.replacingOccurrences(
        of: #"import\s+\*\s+as\s+(\w+)\s+from\s*['"]catvod['"]\s*;?"#,
        with: "var $1 = requireCatvod();",
        options: .regularExpression
      )

      var defaultClassName: String?
      if let regex = try? NSRegularExpression(
        pattern: #"export\s+default\s+class\s+(\w+)"#,
        options: []
      ) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range),
          match.numberOfRanges > 1,
          let nameRange = Range(match.range(at: 1), in: text)
        {
          defaultClassName = String(text[nameRange])
        }
        text = regex.stringByReplacingMatches(
          in: text,
          options: [],
          range: range,
          withTemplate: "class $1"
        )
      } else {
        text = text.replacingOccurrences(
          of: #"export\s+default\s+class"#,
          with: "class",
          options: .regularExpression
        )
      }
      text = text.replacingOccurrences(
        of: #"export\s+default\s+"#,
        with: "var __firepickExport = ",
        options: .regularExpression
      )

      // Top-level `class Name` is script-scoped in JSC (not on globalThis).
      // Bind it explicitly so the bootstrap can `new` the default export.
      let exportBinding =
        defaultClassName.map { name in
          "var __firepickExport = \(name);"
        } ?? ""

      return """
        \(text)
        ;
        \(exportBinding)
        (function() {
          var exported = null;
          if (typeof __firepickExport !== 'undefined') {
            exported = __firepickExport;
          }
          if (exported) {
            __firepickSpider = (typeof exported === 'function') ? new exported() : exported;
            return;
          }
          var g = (typeof globalThis !== 'undefined') ? globalThis : this;
          var names = Object.getOwnPropertyNames(g);
          var found = null;
          for (var i = 0; i < names.length; i++) {
            try {
              var value = g[names[i]];
              if (typeof value === 'function'
                  && value !== Spider
                  && value.prototype
                  && typeof value.prototype.homeContent === 'function') {
                found = value;
              }
            } catch (e) {}
          }
          if (found) __firepickSpider = new found();
        })();
        """
    }

    private static let catvodModuleSource = """
      var __firepickSpider = null;
      function Spider() {}
      Spider.prototype.init = function(ext) {};
      Spider.prototype.homeContent = function(filter) { return { class: [], list: [] }; };
      Spider.prototype.homeVideoContent = function() { return { list: [] }; };
      Spider.prototype.categoryContent = function(tid, pg, filter, extend) { return { list: [] }; };
      Spider.prototype.detailContent = function(ids) { return { list: [] }; };
      Spider.prototype.searchContent = function(key, quick, pg) { return { list: [] }; };
      Spider.prototype.playerContent = function(flag, id, vipFlags) { return {}; };
      Spider.prototype.action = function(action) { return { list: [] }; };
      Spider.prototype.liveContent = function(url) { return ''; };
      Spider.prototype.destroy = function() {};

      var net = {
        req: function(url, options) { return __firepickNetReq(url, options || {}); }
      };
      function req(url, options) { return __firepickNetReq(url, options || {}); }
      function http(url, options, callback) {
        var promise = __firepickNetReq(url, options || {});
        if (typeof callback === 'function') {
          promise.then(function(result) {
            callback(null, result);
            return result;
          }, function(error) {
            callback(error, null);
          });
        }
        return promise;
      }
      var local = {
        get: function(key) { return __firepickLocalGet(key); },
        set: function(key, value) { return __firepickLocalSet(key, value); },
        delete: function(key) { return __firepickLocalDelete(key); }
      };
      var htmlQuery = {
        pdfh: function(html, rule) { return pdfh(html, rule); },
        pd: function(html, rule, key) { return pd(html, rule, key || ''); },
        pdfa: function(html, rule) { return pdfa(html, rule); },
        pdfl: function(html, rule, texts, urls, key) { return pdfl(html, rule, texts, urls, key || ''); }
      };
      function link(base, relative) { return __firepickJoinURL(base, relative); }
      function joinUrl(base, relative) { return __firepickJoinURL(base, relative); }
      function page(p) { return String(p == null ? 1 : p); }
      function md5X(text) { return __firepickMD5(String(text)); }
      function sha256X(text) { return __firepickSHA256(String(text)); }
      function randomX(n) {
        n = n || 8;
        var chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
        var out = '';
        for (var i = 0; i < n; i++) out += chars.charAt(Math.floor(Math.random() * chars.length));
        return out;
      }
      function setTimeout(callback, milliseconds) {
        __firepickSleep(milliseconds || 0);
        if (typeof callback === 'function') {
          callback.apply(null, Array.prototype.slice.call(arguments, 2));
        }
        return 0;
      }
      function clearTimeout() {}
      function setInterval(callback, milliseconds) {
        return setTimeout(callback, milliseconds);
      }
      function clearInterval() {}
      function setImmediate(callback) {
        return setTimeout(callback, 0);
      }
      function queueMicrotask(callback) {
        Promise.resolve().then(callback);
      }
      function aesX(mode, encrypt, input, inBase64, key, iv, outBase64) {
        return __firepickAESX(mode, !!encrypt, String(input), !!inBase64, String(key || ''), String(iv || ''), !!outBase64);
      }
      function desX(mode, encrypt, input, inBase64, key, iv, outBase64) {
        return __firepickDESX(mode, !!encrypt, String(input), !!inBase64, String(key || ''), String(iv || ''), !!outBase64);
      }
      function rsaX(mode, pub, encrypt, input, inBase64, key, outBase64) {
        return __firepickRSAX(mode, !!pub, !!encrypt, String(input), !!inBase64, String(key || ''), !!outBase64);
      }
      function requireCatvod() {
        return {
          Spider: Spider,
          net: net,
          local: local,
          htmlQuery: htmlQuery,
          link: link,
          joinUrl: joinUrl,
        req: req,
        http: http,
          page: page,
          aesX: aesX,
          desX: desX,
          rsaX: rsaX,
          md5X: md5X,
          sha256X: sha256X,
          randomX: randomX,
          md5: md5X,
          base64Encode: function(v) { return __firepickB64E(String(v)); },
          base64Decode: function(v) { return __firepickB64D(String(v)); }
        };
      }
      if (typeof console === 'undefined') {
        var console = { log: function() { __firepickLog(Array.prototype.join.call(arguments, ' ')); } };
      }
      """

    private static func localKey(_ key: String) -> String {
      "firepick.js.local.\(key)"
    }

    private static func dictionary(from value: JSValue?) -> [String: Any]? {
      guard let value, value.isObject, let object = value.toObject() as? [String: Any] else {
        return nil
      }
      return object
    }

    private static func jsValue(from value: JSONValue, in context: JSContext) -> JSValue {
      switch value {
      case .null:
        return JSValue(nullIn: context)
      case .bool(let flag):
        return JSValue(bool: flag, in: context)
      case .number(let number):
        return JSValue(double: number, in: context)
      case .string(let string):
        return JSValue(object: string, in: context)
      case .array, .object:
        guard let data = try? JSONEncoder().encode(value),
          let json = String(data: data, encoding: .utf8),
          let parsed = context.evaluateScript("(\(json))")
        else {
          return JSValue(nullIn: context)
        }
        return parsed
      }
    }

    private static func decodeMediaResult(
      _ value: JSValue,
      in context: JSContext,
      scriptURL: URL
    ) throws -> MediaResult {
      let jsonValue: Any
      if value.isString, let string = value.toString() {
        guard let data = string.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data)
        else {
          throw FirepickError.provider("JS 返回的字符串不是 JSON")
        }
        jsonValue = object
      } else if value.isUndefined || value.isNull {
        return MediaResult()
      } else if let object = value.toObject() {
        jsonValue = object
      } else {
        throw FirepickError.provider("JS 返回了无法解析的结果")
      }
      let data = try JSONSerialization.data(withJSONObject: jsonValue)
      do {
        return try JSONDecoder().decode(MediaResult.self, from: data)
      } catch {
        throw FirepickError.provider(
          "JS 结果无法映射为 MediaResult（\(scriptURL.lastPathComponent)）：\(error.localizedDescription)"
        )
      }
    }

    private static func md5Hex(_ string: String) -> String {
      Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ string: String) -> String {
      SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
  #endif
}
