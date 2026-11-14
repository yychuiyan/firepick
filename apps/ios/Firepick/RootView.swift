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
        } else if let message = model.errorMessage, !message.isEmpty,
          model.statusToast == nil
        {
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
    .overlay(alignment: .top) {
      if let toast = model.statusToast {
        StatusToastView(text: toast)
          .padding(.top, 10)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.2), value: model.statusToast)
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

/// Compact status toast with three bouncing dots (配置更新中···).
struct StatusToastView: View {
  var text: String

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      HStack(spacing: 0) {
        Text(text)
          .font(.subheadline.weight(.medium))
        HStack(spacing: 1) {
          ForEach(0..<3, id: \.self) { index in
            Text("·")
              .font(.title3.weight(.bold))
              .offset(y: bounceOffset(index: index, time: t))
          }
        }
        .frame(width: 22, alignment: .leading)
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(.ultraThinMaterial, in: Capsule())
      .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }
    .accessibilityLabel(text)
  }

  private func bounceOffset(index: Int, time: TimeInterval) -> CGFloat {
    let wave = sin((time * 6.0) - Double(index) * 0.55)
    return CGFloat(wave * 3.0)
  }
}
