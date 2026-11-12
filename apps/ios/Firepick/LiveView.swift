import FirepickCore
import FirepickPlayback
import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedGroup: String?
    @State private var selectedChannel: LiveChannel?

    private var groups: [LiveGroup] {
        model.liveGroups
    }

    private var group: LiveGroup? {
        groups.first(where: { $0.name == selectedGroup }) ?? groups.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    pageHeader

                if groups.isEmpty {
                    ContentUnavailableView(
                        "没有直播源",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("导入包含直播频道、M3U 或 TXT 的配置后，频道会显示在这里。")
                    )
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 360)
                } else {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(groups) { item in
                                    Button(item.name) {
                                        selectedGroup = item.name
                                    }
                                    .buttonStyle(.bordered)
                                    .tint((group?.name == item.name) ? .orange : .secondary)
                                }
                            }
                            .padding(.horizontal)
                        }
                        .scrollIndicators(.hidden)

                        ForEach(group?.channels ?? []) { channel in
                            Button {
                                selectedChannel = channel
                            } label: {
                                HStack(spacing: 12) {
                                    AsyncImage(url: channel.logo.flatMap(URL.init(string:))) { image in
                                        image.resizable().scaledToFit()
                                    } placeholder: {
                                        Image(systemName: "tv")
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(width: 34, height: 34)
                                    Text(channel.name)
                                    VStack(alignment: .leading, spacing: 2) {
                                        if let program = model.currentProgram(for: channel) {
                                            Text(program.title)
                                        } else if let next = model.nextProgram(for: channel) {
                                            Text("即将 · \(next.title)")
                                        }
                                        if model.currentProgram(for: channel) != nil,
                                           let next = model.nextProgram(for: channel) {
                                            Text("下一档 · \(next.title)")
                                                .opacity(0.75)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    Spacer()
                                    if let number = channel.number {
                                        Text(number).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                            .padding(.vertical, 9)

                            if channel.id != group?.channels.last?.id {
                                Divider()
                                    .padding(.leading, 58)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .refreshable {
                await model.refreshLiveSources()
                if let group {
                    await model.loadEPG(for: group)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: groups.map(\.name)) {
                if selectedGroup == nil
                    || !groups.contains(where: { $0.name == selectedGroup }) {
                    selectedGroup = groups.first?.name
                }
            }
            .task(id: group?.id) {
                if let group {
                    await model.loadEPG(for: group)
                }
            }
            .fullScreenCover(item: $selectedChannel) { channel in
                if let url = channel.playableURL {
                    PlayerView(
                        request: PlaybackRequest(url: url, headers: channel.headers),
                        item: MediaItem(
                            vodId: channel.id,
                            name: channel.name,
                            sourceKey: "live"
                        ),
                        episode: nil,
                        alternateURLs: channel.urls.dropFirst().compactMap(URL.init(string:))
                    )
                }
            }
        }
    }

    private var pageHeader: some View {
        Text("电视")
            .font(.system(size: 34, weight: .bold))
            .padding(.horizontal)
            .padding(.top, 8)
    }
}

