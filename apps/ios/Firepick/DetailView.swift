import FirepickCore
import FirepickPlayback
import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    @State private var playback: PlaybackRequest?
    @State private var playbackEpisode: Episode?
    @State private var resolvingEpisodeID: Episode.ID?
    @State private var playbackError: String?

    private var detail: MediaItem {
        model.detailResult?.list.first ?? item
    }

    private var lines: [PlaybackLine] {
        EpisodeParser.lines(playFrom: detail.playFrom, playURL: detail.playURL)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 16) {
                        AsyncImage(url: detail.pic.flatMap(URL.init(string:))) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.secondary.opacity(0.1))
                                .overlay { Image(systemName: "film") }
                        }
                        .frame(width: 120, height: 168)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                        VStack(alignment: .leading, spacing: 8) {
                            Text(detail.name)
                                .font(.title2.bold())
                            if let type = detail.typeName { Text(type).foregroundStyle(.secondary) }
                            if let year = detail.year { Text(year).foregroundStyle(.secondary) }
                            Button {
                                guard let sourceKey = detail.sourceKey ?? model.selectedSite?.key else { return }
                                Task { await model.toggleFavorite(sourceKey: sourceKey, item: detail) }
                            } label: {
                                let sourceKey = detail.sourceKey ?? model.selectedSite?.key ?? ""
                                Label(
                                    model.isFavorite(sourceKey: sourceKey, item: detail)
                                        ? "已收藏" : "收藏",
                                    systemImage: model.isFavorite(
                                        sourceKey: sourceKey,
                                        item: detail
                                    ) ? "heart.fill" : "heart"
                                )
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal)

                    if let content = detail.content {
                        Text(Self.plainText(content))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }

                    if lines.isEmpty {
                        ContentUnavailableView(
                            "没有可播放线路",
                            systemImage: "play.slash",
                            description: Text("详情接口没有返回标准选集数据。")
                        )
                    } else {
                        ForEach(lines) { line in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(line.name).font(.headline)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                                    ForEach(line.episodes) { episode in
                                        Button {
                                            resolvingEpisodeID = episode.id
                                            playbackError = nil
                                            Task {
                                                do {
                                                    playback = try await model.resolvePlayback(
                                                        item: detail,
                                                        episode: episode,
                                                        flag: line.name
                                                    )
                                                    playbackEpisode = episode
                                                } catch {
                                                    playbackError = error.localizedDescription
                                                }
                                                resolvingEpisodeID = nil
                                            }
                                        } label: {
                                            if resolvingEpisodeID == episode.id {
                                                ProgressView()
                                                    .frame(maxWidth: .infinity)
                                            } else {
                                                Text(episode.name)
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .lineLimit(1)
                                        .disabled(resolvingEpisodeID != nil)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("详情")
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                "无法开始播放",
                isPresented: Binding(
                    get: { playbackError != nil },
                    set: { if !$0 { playbackError = nil } }
                )
            ) {
                Button("知道了", role: .cancel) {
                    playbackError = nil
                }
            } message: {
                Text(playbackError ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                await model.loadDetail(item)
            }
            .fullScreenCover(item: $playback) { request in
                PlayerView(request: request, item: detail, episode: playbackEpisode)
            }
        }
    }

    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

