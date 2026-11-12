import FirepickCore
import FirepickPlayback
import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var selectedItem: MediaItem?
    @State private var selectedLive: LiveChannel?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                Divider()

                List {
                    if model.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                    }
                    if !model.liveSearchResults.isEmpty {
                        Section("直播") {
                            ForEach(model.liveSearchResults) { channel in
                                Button {
                                    selectedLive = channel
                                } label: {
                                    Text(channel.name)
                                }
                            }
                        }
                    }
                    ForEach(model.searchSections) { section in
                        Section(section.siteName) {
                            ForEach(section.result.list) { item in
                                Button {
                                    selectedItem = item
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name)
                                        if let remarks = item.remarks {
                                            Text(remarks)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if !model.isLoading,
                       model.searchHasRun,
                       model.searchSections.isEmpty {
                        Text("没有找到结果")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                searchFocused = true
            }
            .sheet(item: $selectedItem) { item in
                DetailView(item: item)
            }
            .fullScreenCover(item: $selectedLive) { channel in
                if let url = channel.playableURL {
                    PlayerView(
                        request: PlaybackRequest(url: url, headers: channel.headers),
                        item: MediaItem(vodId: channel.id, name: channel.name, sourceKey: "live"),
                        episode: nil,
                        alternateURLs: channel.urls.dropFirst().compactMap(URL.init(string:))
                    )
                }
            }
        }
    }

    private var searchBar: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("片名、剧名或演员", text: $model.searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit {
                        Task { await model.search() }
                    }
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            Button("取消") {
                searchFocused = false
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.background)
    }
}

