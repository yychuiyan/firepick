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
  /// Cap adaptive stream bitrate (0 = automatic / uncapped).
  func setPreferredPeakBitRate(_ bitsPerSecond: Double)
}

@MainActor
@Observable
public final class AVPlayerEngine: PlaybackEngine {
  public private(set) var state: PlaybackState = .idle
  public private(set) var currentTime: Double = 0
  public private(set) var duration: Double = 0
  /// First decoded frame attached — false while black/blank after replaceCurrentItem.
  public private(set) var isReadyForDisplay: Bool = false
  public let player = AVPlayer()
  private var playbackRate: Float = 1

  private var timeObserver: Any?
  private var statusObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  private var presentationSizeObservation: NSKeyValueObservation?
  private var bufferEmptyObservation: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var bufferSeconds: Double = 5
  private var preferredPeakBitRate: Double = 0

  public init() {
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      Task { @MainActor in
        guard let self else { return }
        self.currentTime = time.seconds.isFinite ? max(0, time.seconds) : 0
        self.duration = Self.readableDuration(self.player.currentItem) ?? self.duration
        self.syncStateFromPlayer()
        if !self.isReadyForDisplay {
          self.refreshReadyForDisplay()
        }
      }
    }
    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
      [weak self] _, _ in
      Task { @MainActor in
        self?.syncStateFromPlayer()
      }
    }
  }

  public func load(_ request: PlaybackRequest) async throws {
    // Mid-playback URL switch: avoid flipping to .loading (UI spinner / black cover).
    // Never pre-attach the same AVPlayerItem to a second AVPlayer — that aborts with
    // "An AVPlayerItem cannot be associated with more than one instance of AVPlayer".
    let seamless = player.currentItem != nil
    if !seamless {
      state = .loading
    }
    // New item starts black until video dimensions / buffer look real.
    isReadyForDisplay = false
    presentationSizeObservation?.invalidate()
    presentationSizeObservation = nil
    bufferEmptyObservation?.invalidate()
    bufferEmptyObservation = nil
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
      // Prefetch on the asset only (safe). Do not warm via a throwaway AVPlayer.
      let playable = try await asset.load(.isPlayable)
      guard playable else {
        throw FirepickError.playback("媒体不可播放")
      }
      _ = try? await asset.load(.duration)
      let item = AVPlayerItem(asset: asset)
      item.preferredForwardBufferDuration = bufferSeconds
      item.preferredPeakBitRate = preferredPeakBitRate
      player.replaceCurrentItem(with: item)
      presentationSizeObservation = item.observe(\.presentationSize, options: [.new]) {
        [weak self] _, _ in
        Task { @MainActor in
          self?.refreshReadyForDisplay()
        }
      }
      bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) {
        [weak self] _, _ in
        Task { @MainActor in
          self?.refreshReadyForDisplay()
        }
      }
      refreshReadyForDisplay()
      statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
        Task { @MainActor in
          switch item.status {
          case .readyToPlay:
            // Do not clobber .playing / .paused — play() may already have started.
            if let self, self.state == .loading || self.state == .idle {
              self.state = .ready
            }
            if let known = Self.readableDuration(item) {
              self?.duration = known
            }
            self?.refreshReadyForDisplay()
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
      if let known = Self.readableDuration(item) {
        duration = known
      } else {
        Task { [weak self] in
          guard let known = try? await asset.load(.duration),
            known.seconds.isFinite,
            known.seconds > 0
          else { return }
          self?.duration = known.seconds
        }
      }
      if seamless, state == .loading || state == .idle {
        state = .ready
      }
    } catch {
      if !seamless {
        state = .failed(error.localizedDescription)
      }
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
    presentationSizeObservation?.invalidate()
    presentationSizeObservation = nil
    bufferEmptyObservation?.invalidate()
    bufferEmptyObservation = nil
    isReadyForDisplay = false
    player.pause()
    player.replaceCurrentItem(with: nil)
    currentTime = 0
    duration = 0
    state = .idle
  }

  /// Proxy for “first frame”: video size known and buffer not empty.
  private func refreshReadyForDisplay() {
    guard let item = player.currentItem, item.status == .readyToPlay else {
      isReadyForDisplay = false
      return
    }
    let size = item.presentationSize
    let hasVideo = size.width > 1 && size.height > 1
    if hasVideo {
      isReadyForDisplay = !item.isPlaybackBufferEmpty || item.isPlaybackLikelyToKeepUp
      return
    }
    // Audio-only / size not yet reported: accept once the buffer looks healthy.
    isReadyForDisplay = item.isPlaybackLikelyToKeepUp && !item.isPlaybackBufferEmpty
  }

  public func setPlaybackRate(_ rate: Float) {
    playbackRate = max(0.25, min(rate, 4))
    player.defaultRate = playbackRate
    if player.timeControlStatus == .playing {
      player.rate = playbackRate
    }
  }

  public func setPreferredPeakBitRate(_ bitsPerSecond: Double) {
    preferredPeakBitRate = max(0, bitsPerSecond)
    player.currentItem?.preferredPeakBitRate = preferredPeakBitRate
  }

  public func applyOptions(_ options: PlaybackEngineOptions) {
    bufferSeconds = options.bufferSeconds
    player.currentItem?.preferredForwardBufferDuration = bufferSeconds
    player.currentItem?.preferredPeakBitRate = preferredPeakBitRate
  }

  /// Keep SwiftUI icons aligned with the real AVPlayer clock.
  private func syncStateFromPlayer() {
    switch state {
    case .loading, .failed, .idle, .ended:
      return
    default:
      break
    }
    // Prefer rate: HLS often sits in .waitingToPlayAtSpecifiedRate while frames
    // already advance, which used to leave the UI stuck on the play icon.
    if player.rate != 0 {
      if state != .playing { state = .playing }
      return
    }
    switch player.timeControlStatus {
    case .playing:
      if state != .playing { state = .playing }
    case .paused:
      if player.currentItem != nil, state != .paused, state != .ready {
        state = .paused
      }
    case .waitingToPlayAtSpecifiedRate:
      break
    @unknown default:
      break
    }
  }

  /// True when AVPlayer is actually outputting, not only when our enum says so.
  public var isActivelyPlaying: Bool {
    if player.rate != 0 { return true }
    if state == .playing {
      return player.timeControlStatus == .playing
        || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }
    return false
  }

  /// HLS often reports `duration` as NaN until the playlist is parsed.
  /// The seekable range end is the duration the progress bar can use.
  private static func readableDuration(_ item: AVPlayerItem?) -> Double? {
    guard let item else { return nil }
    let seconds = item.duration.seconds
    if seconds.isFinite, seconds > 0 { return seconds }
    guard let range = item.seekableTimeRanges.last?.timeRangeValue else { return nil }
    let end = range.end.seconds
    guard end.isFinite, end > 0 else { return nil }
    return end
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
  public func setPreferredPeakBitRate(_ bitsPerSecond: Double) {}
}
