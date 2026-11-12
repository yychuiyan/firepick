import AVKit
import FirepickCore
import FirepickPlayback
import SwiftUI

struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PlaybackRequest
    let item: MediaItem
    let episode: Episode?
    var alternateURLs: [URL] = []

    @State private var avEngine = AVPlayerEngine()
    @State private var mpvEngine = MPVPlayerEngine()
    @State private var engineKind: PlaybackEngineKind
    @State private var failure: String?
    @State private var playbackRate: Float = 1
    @State private var activeRequest: PlaybackRequest?
    @State private var danmakuComments: [DanmakuComment] = []
    @State private var danmakuEnabled = true
    @State private var showingCast = false

    init(
        request: PlaybackRequest,
        item: MediaItem,
        episode: Episode?,
        alternateURLs: [URL] = []
    ) {
        self.request = request
        self.item = item
        self.episode = episode
        self.alternateURLs = alternateURLs
        let kind = (try? PlayerSelector().select(
            request,
            mpvAvailable: MPVPlaybackSupport.isAvailable
        ).engine) ?? .avPlayer
        _engineKind = State(initialValue: kind)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if engineKind == .mpv {
                    MPVVideoView(engine: mpvEngine)
                        .ignoresSafeArea(edges: .horizontal)
                } else {
                    SystemPlayerView(player: avEngine.player)
                        .ignoresSafeArea(edges: .horizontal)
                }
                DanmakuOverlay(
                    comments: danmakuComments,
                    currentTime: playbackEngine.currentTime,
                    isPlaying: playbackEngine.state == .playing,
                    isEnabled: danmakuEnabled
                )

                if let displayFailure {
                    ContentUnavailableView(
                        "无法播放",
                        systemImage: "exclamationmark.triangle",
                        description: Text(displayFailure)
                    )
                    .foregroundStyle(.white)
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        playbackEngine.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            model.download(
                                request: activeRequest ?? request,
                                item: item,
                                episode: episode
                            )
                        } label: {
                            Label("下载到本机", systemImage: "arrow.down.circle")
                        }
                        Button {
                            showingCast = true
                        } label: {
                            Label("投屏到 DLNA", systemImage: "airplayvideo")
                        }
                        Toggle(isOn: $danmakuEnabled) {
                            Label("弹幕", systemImage: "text.bubble")
                        }
                        .disabled(danmakuComments.isEmpty)
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                            Button {
                                playbackRate = Float(rate)
                                playbackEngine.setPlaybackRate(Float(rate))
                            } label: {
                                if playbackRate == Float(rate) {
                                    Label("\(rate.formatted())×", systemImage: "checkmark")
                                } else {
                                    Text("\(rate.formatted())×")
                                }
                            }
                        }
                    } label: {
                        Label(
                            "\(Double(playbackRate).formatted())×",
                            systemImage: "speedometer"
                        )
                    }
                }
            }
            .task {
                await loadAvailableSource()
            }
            .task(id: request.danmaku.first?.id) {
                await loadDanmaku()
            }
            .sheet(isPresented: $showingCast) {
                DLNACastView(
                    request: activeRequest ?? request,
                    title: item.name
                )
            }
            .onDisappear {
                if let sourceKey = item.sourceKey ?? model.selectedSite?.key {
                    let historyEpisode = episode
                        ?? Episode(
                            name: item.name,
                            value: (activeRequest ?? request).url.absoluteString
                        )
                    Task {
                        await model.saveHistory(
                            sourceKey: sourceKey,
                            item: item,
                            episode: historyEpisode,
                            position: playbackEngine.currentTime,
                            duration: playbackEngine.duration
                        )
                    }
                }
                playbackEngine.stop()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var playbackEngine: any PlaybackEngine {
        engineKind == .mpv ? mpvEngine : avEngine
    }

    private var displayFailure: String? {
        if let failure { return failure }
        switch playbackEngine.state {
        case let .failed(message):
            return message
        default:
            return nil
        }
    }

    private func loadAvailableSource() async {
        var lastError: Error?
        var urls = [request.url]
        urls.append(contentsOf: alternateURLs.filter { !urls.contains($0) })
        for url in urls {
            var candidate = request
            candidate.url = url
            do {
                try await playbackEngine.load(candidate)
                activeRequest = candidate
                failure = nil
                playbackEngine.play()
                return
            } catch {
                lastError = error
            }
        }
        failure = lastError?.localizedDescription ?? "媒体不可播放"
    }

    private func loadDanmaku() async {
        guard let source = request.danmaku.first else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: source.url)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                return
            }
            danmakuComments = DanmakuParser.parse(data)
        } catch {
            danmakuComments = []
        }
    }
}

private struct SystemPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}

