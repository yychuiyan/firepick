import AVFoundation
import FirepickCore
import Foundation
import Observation

public enum PlaybackVideoOutput: String, CaseIterable, Sendable {
  case automatic
  case metal
  case system
}

public enum PlaybackDecode: String, CaseIterable, Sendable {
  case automatic
  case hardware
  case software
}

public struct PlaybackEngineOptions: Equatable, Sendable {
  public var videoOutput: PlaybackVideoOutput
  public var decode: PlaybackDecode
  public var bufferSeconds: Double

  public init(
    videoOutput: PlaybackVideoOutput = .automatic,
    decode: PlaybackDecode = .automatic,
    bufferSeconds: Double = 5
  ) {
    self.videoOutput = videoOutput
    self.decode = decode
    self.bufferSeconds = bufferSeconds.isFinite ? max(1, bufferSeconds) : 5
  }

  /// MPVKit renders through the Metal surface. The system option is only
  /// meaningful for AVPlayer and falls back to the MPV automatic output.
  public var mpvVideoOutput: String {
    switch videoOutput {
    case .automatic, .metal, .system: "gpu-next"
    }
  }

  public var mpvHardwareDecode: String {
    switch decode {
    case .automatic, .hardware: "videotoolbox"
    case .software: "no"
    }
  }
}

@MainActor
public protocol PlaybackEngine: AnyObject {
  var state: PlaybackState { get }
  var currentTime: Double { get }
  var duration: Double { get }

  func load(_ request: PlaybackRequest) async throws
  func play()
  func pause()
  func seek(to seconds: Double) async
  func stop()
  func setPlaybackRate(_ rate: Float)
  func applyOptions(_ options: PlaybackEngineOptions)
}

@MainActor
@Observable
public final class AVPlayerEngine: PlaybackEngine {
  public private(set) var state: PlaybackState = .idle
  public private(set) var currentTime: Double = 0
  public private(set) var duration: Double = 0
  public let player = AVPlayer()
  private var playbackRate: Float = 1

  private var timeObserver: Any?
  private var statusObservation: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var bufferSeconds: Double = 5

  public init() {
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      Task { @MainActor in
        self?.currentTime = time.seconds.isFinite ? max(0, time.seconds) : 0
        self?.duration = self?.player.currentItem?.duration.seconds ?? 0
      }
    }
  }

  public func load(_ request: PlaybackRequest) async throws {
    state = .loading
    #if os(iOS)
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.playback, mode: .moviePlayback)
      try audio.setActive(true)
    #endif
    let headers = request.headers
    let options: [String: Any] =
      headers.isEmpty
      ? [:]
      : [
        "AVURLAssetHTTPHeaderFieldsKey": headers
      ]
    let asset = AVURLAsset(url: request.url, options: options)
    do {
      let playable = try await asset.load(.isPlayable)
      guard playable else {
        throw FirepickError.playback("媒体不可播放")
      }
      let item = AVPlayerItem(asset: asset)
      item.preferredForwardBufferDuration = bufferSeconds
      player.replaceCurrentItem(with: item)
      statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
        Task { @MainActor in
          switch item.status {
          case .readyToPlay:
            self?.state = .ready
          case .failed:
            self?.state = .failed(item.error?.localizedDescription ?? "未知播放错误")
          default:
            break
          }
        }
      }
      if let endObserver {
        NotificationCenter.default.removeObserver(endObserver)
      }
      endObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: item,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.state = .ended
        }
      }
      if request.startPosition > 0 {
        await player.seek(to: CMTime(seconds: request.startPosition, preferredTimescale: 600))
        currentTime = request.startPosition
      }
    } catch {
      state = .failed(error.localizedDescription)
      throw error
    }
  }

  public func play() {
    player.playImmediately(atRate: playbackRate)
    state = .playing
  }

  public func pause() {
    player.pause()
    state = .paused
  }

  public func seek(to seconds: Double) async {
    await player.seek(
      to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    )
    currentTime = max(0, seconds)
  }

  public func stop() {
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      self.endObserver = nil
    }
    player.pause()
    player.replaceCurrentItem(with: nil)
    currentTime = 0
    duration = 0
    state = .idle
  }

  public func setPlaybackRate(_ rate: Float) {
    playbackRate = max(0.25, min(rate, 4))
    player.defaultRate = playbackRate
    if player.timeControlStatus == .playing {
      player.rate = playbackRate
    }
  }

  public func applyOptions(_ options: PlaybackEngineOptions) {
    bufferSeconds = options.bufferSeconds
    player.currentItem?.preferredForwardBufferDuration = bufferSeconds
  }
}

@MainActor
public final class UnavailableMPVEngine: PlaybackEngine {
  public private(set) var state: PlaybackState = .idle
  public private(set) var currentTime: Double = 0
  public private(set) var duration: Double = 0

  public init() {}

  public func load(_ request: PlaybackRequest) async throws {
    state = .failed("MPVKit 尚未链接")
    throw FirepickError.unsupported("MPVKit 尚未链接")
  }

  public func play() {}
  public func pause() {}
  public func seek(to seconds: Double) async {}
  public func stop() { state = .idle }
  public func setPlaybackRate(_ rate: Float) {}
  public func applyOptions(_ options: PlaybackEngineOptions) {}
}
