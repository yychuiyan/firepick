import FirepickCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            BrowseView()
                .tabItem { Label("点播", systemImage: "play.rectangle.on.rectangle") }
                .tag(AppModel.Tab.vod)

            LiveView()
                .tabItem { Label("电视", systemImage: "dot.radiowaves.left.and.right") }
                .tag(AppModel.Tab.live)

            SettingsView()
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
                .tag(AppModel.Tab.settings)
        }
        .tint(.orange)
        .alert(
            "出错了",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("知道了", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { model.debugPlaybackRequest != nil },
                set: {
                    if !$0 {
                        model.debugPlaybackRequest = nil
                        model.debugPlaybackItem = nil
                        model.debugPlaybackEpisode = nil
                    }
                }
            )
        ) {
            if let request = model.debugPlaybackRequest,
               let item = model.debugPlaybackItem {
                PlayerView(
                    request: request,
                    item: item,
                    episode: model.debugPlaybackEpisode
                )
            }
        }
    }
}

