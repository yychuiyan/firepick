import FirepickCore
import Foundation
import Observation

#if os(iOS)
  import Libmpv
  import SwiftUI
  import UIKit

  public enum MPVPlaybackSupport {
    public static let isAvailable = true
  }

  @MainActor
  @Observable
  public final class MPVPlayerEngine: PlaybackEngine {
    public private(set) var state: PlaybackState = .idle
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0

    @ObservationIgnored private let runtime = MPVRuntime()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var surface: MPVSurfaceView?
    @ObservationIgnored private var options = PlaybackEngineOptions()
    @ObservationIgnored private var surfaceWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    deinit {
      pollTask?.cancel()
    }

    public func attach(_ surface: MPVSurfaceView) {
      guard self.surface !== surface else { return }
      self.surface = surface
      let waiters = surfaceWaiters
      surfaceWaiters.removeAll()
      waiters.forEach { $0.resume() }
      startPolling()
      do {
        try runtime.attach(layer: surface.metalLayer)
      } catch {
        state = .failed(error.localizedDescription)
      }
    }

    public func detach(_ surface: MPVSurfaceView) {
      guard self.surface === surface else { return }
      self.surface = nil
    }

    public func load(_ request: PlaybackRequest) async throws {
      if surface == nil {
        await withCheckedContinuation { continuation in
          surfaceWaiters.append(continuation)
        }
      }
      state = .loading
      currentTime = 0
      duration = 0
      do {
        try await runtime.load(request)
        for (index, subtitle) in request.subtitles.enumerated() {
          runtime.command([
            "sub-add",
            subtitle.url.absoluteString,
            index == 0 ? "select" : "auto",
            subtitle.name,
          ])
        }
        currentTime = max(0, request.startPosition)
        state = .ready
      } catch {
        state = .failed(error.localizedDescription)
        throw error
      }
    }

    public func play() {
      runtime.setFlag("pause", false)
      state = .playing
    }

    public func pause() {
      runtime.setFlag("pause", true)
      state = .paused
    }

    public func seek(to seconds: Double) async {
      let target = max(0, seconds)
      runtime.setDouble("time-pos", target)
      currentTime = target
    }

    public func stop() {
      runtime.command("stop")
      currentTime = 0
      duration = 0
      state = .idle
    }

    public func setPlaybackRate(_ rate: Float) {
      runtime.setDouble("speed", Double(max(0.25, min(rate, 4))))
    }

    public func setPreferredPeakBitRate(_ bitsPerSecond: Double) {
      // HLS peak bitrate is an AVPlayer concept; MPV keeps adaptive default.
      _ = bitsPerSecond
    }

    public func applyOptions(_ options: PlaybackEngineOptions) {
      self.options = options
      runtime.applyOptions(options)
    }

    /// Selects an external subtitle by 0-based index from `PlaybackRequest.subtitles`.
    /// Pass `nil` to disable subtitles (`sid=no`).
    public func selectSubtitleTrack(index: Int?) {
      if let index {
        runtime.command(["set", "sid", "\(index + 1)"])
      } else {
        runtime.command(["set", "sid", "no"])
      }
    }

    private func startPolling() {
      guard pollTask == nil else { return }
      pollTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          guard let self else { return }
          apply(runtime.snapshot())
          try? await Task.sleep(for: .milliseconds(250))
        }
      }
    }

    private func apply(_ snapshot: MPVRuntime.Snapshot) {
      if snapshot.duration.isFinite, snapshot.duration > 0 {
        duration = snapshot.duration
      }
      if snapshot.position.isFinite, snapshot.position >= 0 {
        currentTime = snapshot.position
      }
      if let failure = snapshot.failure, state != .idle {
        state = .failed(failure)
      } else if snapshot.ended, state == .playing || state == .paused {
        state = .ended
      }
    }
  }

  public final class MPVSurfaceView: UIView {
    public let metalLayer = MPVMetalLayer()

    public override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .black
      metalLayer.contentsScale = UIScreen.main.nativeScale
      metalLayer.framebufferOnly = true
      metalLayer.backgroundColor = UIColor.black.cgColor
      layer.addSublayer(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    public override func layoutSubviews() {
      super.layoutSubviews()
      let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
      metalLayer.frame = bounds
      metalLayer.contentsScale = scale
      metalLayer.drawableSize = CGSize(
        width: max(1, bounds.width * scale),
        height: max(1, bounds.height * scale)
      )
    }
  }

  public final class MPVMetalLayer: CAMetalLayer {
    public override var drawableSize: CGSize {
      get { super.drawableSize }
      set {
        if newValue.width > 1, newValue.height > 1 {
          super.drawableSize = newValue
        }
      }
    }

  }

  public struct MPVVideoView: UIViewRepresentable {
    private let engine: MPVPlayerEngine

    public init(engine: MPVPlayerEngine) {
      self.engine = engine
    }

    public func makeUIView(context: Context) -> MPVSurfaceView {
      let view = MPVSurfaceView()
      engine.attach(view)
      return view
    }

    public func updateUIView(_ uiView: MPVSurfaceView, context: Context) {
      engine.attach(uiView)
    }

    public static func dismantleUIView(_ uiView: MPVSurfaceView, coordinator: ()) {
      // The owning engine stops playback when the player view disappears.
    }
  }

  private final class MPVRuntime: @unchecked Sendable {
    struct Snapshot {
      var position: Double
      var duration: Double
      var ended: Bool
      var failure: String?
    }

    private struct PendingLoad {
      var id: UUID
      var didStart: Bool
      var continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private let eventQueue = DispatchQueue(label: "app.firepick.mpv.events", qos: .userInitiated)
    private var handle: OpaquePointer?
    private var attachedLayer: MPVMetalLayer?
    private var pendingLoad: PendingLoad?
    private var position: Double = 0
    private var mediaDuration: Double = 0
    private var ended = false
    private var failure: String?
    private var isDestroyed = false

    func attach(layer: MPVMetalLayer) throws {
      lock.lock()
      let alreadyAttached = handle != nil
      lock.unlock()
      if alreadyAttached { return }

      guard let context = mpv_create() else {
        throw FirepickError.playback("无法创建 MPV 播放上下文")
      }
      attachedLayer = layer
      setOption(context, "config", "no")
      setOption(context, "terminal", "no")
      setOption(context, "input-default-bindings", "no")
      setOption(context, "osc", "no")
      setOption(context, "osd-level", "0")
      setOption(context, "vo", "gpu-next")
      setOption(context, "gpu-api", "vulkan")
      setOption(context, "gpu-context", "moltenvk")
      setOption(context, "hwdec", "videotoolbox")
      setOption(context, "target-colorspace-hint", "yes")
      setOption(context, "subs-match-os-language", "yes")
      setOption(context, "subs-fallback", "yes")
      setOption(context, "sub-auto", "fuzzy")
      setOption(context, "audio-file-auto", "fuzzy")
      _ = mpv_request_log_messages(context, "warn")

      var windowID = Int64(
        bitPattern: UInt64(
          UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque())
        )
      )
      check(
        mpv_set_option(context, "wid", MPV_FORMAT_INT64, &windowID),
        context: context,
        operation: "设置 Metal 渲染目标"
      )
      let status = mpv_initialize(context)
      guard status >= 0 else {
        let message = errorMessage(context, status: status)
        mpv_terminate_destroy(context)
        throw FirepickError.playback("MPV 初始化失败：\(message)")
      }

      lock.lock()
      guard !isDestroyed else {
        lock.unlock()
        mpv_terminate_destroy(context)
        throw FirepickError.playback("MPV 播放器已关闭")
      }
      handle = context
      lock.unlock()

      observe(context, "time-pos", MPV_FORMAT_DOUBLE)
      observe(context, "duration", MPV_FORMAT_DOUBLE)
      observe(context, "eof-reached", MPV_FORMAT_FLAG)
      observe(context, "idle-active", MPV_FORMAT_FLAG)
      observe(context, "paused-for-cache", MPV_FORMAT_FLAG)
      mpv_set_wakeup_callback(
        context,
        { userData in
          guard let userData else { return }
          Unmanaged<MPVRuntime>
            .fromOpaque(userData)
            .takeUnretainedValue()
            .signalEvents()
        },
        Unmanaged.passUnretained(self).toOpaque()
      )
    }

    func load(_ request: PlaybackRequest) async throws {
      let requestID = UUID()
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        lock.lock()
        guard let context = handle else {
          lock.unlock()
          continuation.resume(throwing: FirepickError.playback("MPV 播放器尚未初始化"))
          return
        }
        if pendingLoad != nil {
          lock.unlock()
          continuation.resume(throwing: FirepickError.playback("MPV 正在加载另一个媒体"))
          return
        }
        failure = nil
        ended = false
        position = max(0, request.startPosition)
        mediaDuration = 0
        pendingLoad = PendingLoad(
          id: requestID,
          didStart: false,
          continuation: continuation
        )
        lock.unlock()

        setOption(context, "http-header-fields", headerFields(request.headers))
        setOption(
          context, "user-agent",
          request.headers.first {
            $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame
          }?.value ?? "Firepick/0.1")

        var rawArguments: [UnsafeMutablePointer<CChar>?] = [
          strdup("loadfile"),
          strdup(request.url.absoluteString),
          strdup("replace"),
          strdup("-1"),
        ]
        var perFileOptions: [String] = []
        if request.startPosition > 0 {
          perFileOptions.append("start=\(request.startPosition)")
        }
        if !perFileOptions.isEmpty {
          rawArguments.append(strdup(perFileOptions.joined(separator: ",")))
        }
        rawArguments.append(nil)
        defer {
          for item in rawArguments where item != nil {
            free(item)
          }
        }
        var arguments: [UnsafePointer<CChar>?] = rawArguments.map {
          $0.map { UnsafePointer<CChar>($0) }
        }
        let status = mpv_command(context, &arguments)
        if status < 0 {
          let message = errorMessage(context, status: status)
          finishLoad(
            id: requestID,
            result: .failure(
              FirepickError.playback("MPV 加载失败：\(message)")
            )
          )
        }

        eventQueue.asyncAfter(deadline: .now() + 30) { [weak self] in
          self?.finishLoad(
            id: requestID,
            result: .failure(FirepickError.playback("MPV 媒体加载超时"))
          )
        }
      }
    }

    func command(_ name: String) {
      command([name])
    }

    func command(_ values: [String]) {
      lock.lock()
      guard let context = handle else {
        lock.unlock()
        return
      }
      lock.unlock()
      var rawArguments: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
      rawArguments.append(nil)
      defer {
        for item in rawArguments where item != nil {
          free(item)
        }
      }
      var arguments: [UnsafePointer<CChar>?] = rawArguments.map {
        $0.map { UnsafePointer<CChar>($0) }
      }
      _ = mpv_command(context, &arguments)
    }

    func setFlag(_ name: String, _ value: Bool) {
      lock.lock()
      guard let context = handle else {
        lock.unlock()
        return
      }
      lock.unlock()
      var enabled: Int64 = value ? 1 : 0
      _ = mpv_set_property(context, name, MPV_FORMAT_FLAG, &enabled)
    }

    func setDouble(_ name: String, _ value: Double) {
      lock.lock()
      guard let context = handle else {
        lock.unlock()
        return
      }
      lock.unlock()
      var number = value
      _ = mpv_set_property(context, name, MPV_FORMAT_DOUBLE, &number)
    }

    func applyOptions(_ options: PlaybackEngineOptions) {
      lock.lock()
      guard let context = handle else {
        lock.unlock()
        return
      }
      lock.unlock()
      _ = mpv_set_property_string(context, "vo", options.mpvVideoOutput)
      _ = mpv_set_property_string(context, "hwdec", options.mpvHardwareDecode)
      let seconds = String(format: "%.1f", options.bufferSeconds)
      _ = mpv_set_property_string(context, "cache-secs", seconds)
      _ = mpv_set_property_string(context, "demuxer-readahead-secs", seconds)
    }

    func snapshot() -> Snapshot {
      lock.lock()
      defer { lock.unlock() }
      return Snapshot(
        position: position,
        duration: mediaDuration,
        ended: ended,
        failure: failure
      )
    }

    deinit {
      lock.lock()
      isDestroyed = true
      let context = handle
      handle = nil
      let pending = pendingLoad
      pendingLoad = nil
      lock.unlock()
      pending?.continuation.resume(
        throwing: FirepickError.playback("MPV 播放器已关闭")
      )
      if let context {
        mpv_set_wakeup_callback(context, nil, nil)
        mpv_terminate_destroy(context)
      }
    }

    private func signalEvents() {
      eventQueue.async { [weak self] in
        self?.readEvents()
      }
    }

    private func readEvents() {
      lock.lock()
      guard let context = handle, !isDestroyed else {
        lock.unlock()
        return
      }
      lock.unlock()

      while !isDestroyed {
        guard let event = mpv_wait_event(context, 0) else { return }
        switch event.pointee.event_id {
        case MPV_EVENT_NONE:
          return
        case MPV_EVENT_START_FILE:
          lock.lock()
          if pendingLoad != nil {
            pendingLoad?.didStart = true
          }
          lock.unlock()
        case MPV_EVENT_FILE_LOADED:
          finishLoad(
            id: currentPendingID,
            result: .success(())
          )
        case MPV_EVENT_END_FILE:
          handleEndFile(event.pointee)
        case MPV_EVENT_PROPERTY_CHANGE:
          handlePropertyChange(event.pointee)
        case MPV_EVENT_LOG_MESSAGE:
          handleLogMessage(event.pointee)
        case MPV_EVENT_SHUTDOWN:
          return
        default:
          break
        }
      }
    }

    private var currentPendingID: UUID? {
      lock.lock()
      defer { lock.unlock() }
      return pendingLoad?.id
    }

    private func handlePropertyChange(_ event: mpv_event) {
      guard let data = event.data else { return }
      let property = UnsafeMutablePointer<mpv_event_property>(
        OpaquePointer(data)
      ).pointee
      guard let name = property.name else { return }
      let propertyName = String(cString: name)
      lock.lock()
      defer { lock.unlock() }
      switch propertyName {
      case "time-pos":
        if property.format == MPV_FORMAT_DOUBLE, let raw = property.data {
          position = raw.assumingMemoryBound(to: Double.self).pointee
        }
      case "duration":
        if property.format == MPV_FORMAT_DOUBLE, let raw = property.data {
          mediaDuration = raw.assumingMemoryBound(to: Double.self).pointee
        }
      case "eof-reached", "idle-active":
        if property.format == MPV_FORMAT_FLAG, let raw = property.data {
          ended = raw.assumingMemoryBound(to: Int64.self).pointee != 0
        }
      default:
        break
      }
    }

    private func handleEndFile(_ event: mpv_event) {
      guard let data = event.data else { return }
      let end = UnsafeMutablePointer<mpv_event_end_file>(
        OpaquePointer(data)
      ).pointee

      lock.lock()
      let pending = pendingLoad
      lock.unlock()
      guard let pending else {
        if end.reason == MPV_END_FILE_REASON_EOF {
          lock.lock()
          ended = true
          lock.unlock()
        }
        return
      }
      if !pending.didStart, end.reason == MPV_END_FILE_REASON_STOP {
        return
      }

      switch end.reason {
      case MPV_END_FILE_REASON_EOF:
        lock.lock()
        ended = true
        lock.unlock()
        finishLoad(id: pending.id, result: .success(()))
      case MPV_END_FILE_REASON_ERROR:
        let message =
          mpv_error_string(end.error).map(String.init(cString:))
          ?? "未知 MPV 错误"
        finishLoad(
          id: pending.id,
          result: .failure(FirepickError.playback("MPV 媒体打开失败：\(message)"))
        )
      case MPV_END_FILE_REASON_REDIRECT:
        break
      default:
        finishLoad(
          id: pending.id,
          result: .failure(FirepickError.playback("MPV 播放已停止"))
        )
      }
    }

    private func handleLogMessage(_ event: mpv_event) {
      guard let data = event.data else { return }
      let message = UnsafeMutablePointer<mpv_event_log_message>(
        OpaquePointer(data)
      ).pointee
      guard
        message.log_level == MPV_LOG_LEVEL_ERROR
          || message.log_level == MPV_LOG_LEVEL_FATAL,
        let text = message.text
      else { return }
      let value = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
      print("Firepick MPV log[\(message.log_level)]: \(value)")
      guard message.log_level == MPV_LOG_LEVEL_FATAL else {
        return
      }
      lock.lock()
      failure = value.isEmpty ? "MPV 解码失败" : value
      lock.unlock()
    }

    private func finishLoad(id: UUID?, result: Result<Void, Error>) {
      lock.lock()
      guard let pendingLoad, id == nil || pendingLoad.id == id else {
        lock.unlock()
        return
      }
      self.pendingLoad = nil
      if case .failure(let error) = result {
        failure = error.localizedDescription
      }
      lock.unlock()
      pendingLoad.continuation.resume(with: result)
    }

    private func observe(
      _ context: OpaquePointer,
      _ name: String,
      _ format: mpv_format
    ) {
      _ = mpv_observe_property(context, 0, name, format)
    }

    private func setOption(
      _ context: OpaquePointer,
      _ name: String,
      _ value: String
    ) {
      _ = mpv_set_option_string(context, name, value)
    }

    private func check(
      _ status: Int32,
      context: OpaquePointer,
      operation: String
    ) {
      if status < 0 {
        failure = "\(operation)：\(errorMessage(context, status: status))"
      }
    }

    private func errorMessage(_ context: OpaquePointer, status: Int32) -> String {
      mpv_error_string(status).map(String.init(cString:)) ?? "错误码 \(status)"
    }

    private func headerFields(_ headers: [String: String]) -> String {
      headers
        .filter {
          $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame
        }
        .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        .map { "\($0.key): \($0.value)" }
        .joined(separator: ",")
    }
  }

#else

  public enum MPVPlaybackSupport {
    public static let isAvailable = false
  }

  @MainActor
  @Observable
  public final class MPVPlayerEngine: PlaybackEngine {
    public private(set) var state: PlaybackState = .idle
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0

    public init() {}

    public func load(_ request: PlaybackRequest) async throws {
      throw FirepickError.unsupported("MPV 仅在 iOS 应用中提供")
    }

    public func play() {}
    public func pause() {}
    public func seek(to seconds: Double) async {}
    public func stop() {}
    public func setPlaybackRate(_ rate: Float) {}
    public func applyOptions(_ options: PlaybackEngineOptions) {}
    public func setPreferredPeakBitRate(_ bitsPerSecond: Double) {}
  }

#endif
