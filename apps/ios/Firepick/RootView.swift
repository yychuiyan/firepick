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
    .safeAreaInset(edge: .top, spacing: 0) {
      VStack(spacing: 0) {
        if !model.isNetworkAvailable, !model.suppressNetworkBanner {
          ErrorBannerView(
            message: "网络不可用",
            retryTitle: "重试",
            onRetry: {
              Task { await model.retryLastRecoverableAction() }
            },
            onDismiss: { model.suppressNetworkBanner = true }
          )
        } else if model.isNetworkConstrained, !model.suppressConstrainedBanner {
          ErrorBannerView(
            message: "低数据模式已开启，播放可能更卡",
            onDismiss: { model.suppressConstrainedBanner = true }
          )
        } else if let message = model.errorMessage, !message.isEmpty {
          ErrorBannerView(
            message: message,
            onRetry: {
              Task { await model.retryLastRecoverableAction() }
            },
            onDismiss: { model.errorMessage = nil }
          )
        }
      }
      .animation(.easeInOut(duration: 0.2), value: model.isNetworkAvailable)
      .animation(.easeInOut(duration: 0.2), value: model.isNetworkConstrained)
      .animation(.easeInOut(duration: 0.2), value: model.errorMessage)
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
        let item = model.debugPlaybackItem
      {
        PlayerView(
          request: request,
          item: item,
          episode: model.debugPlaybackEpisode
        )
      }
    }
  }

}

/// Page background. Kept as a view so browse, detail, and library share one fill.
struct FirepickBackdrop: View {
  var body: some View {
    Color(.systemBackground)
      .ignoresSafeArea()
  }
}
