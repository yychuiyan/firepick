import FirepickCore
import SwiftUI

struct LiveView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    // Keep LivePlaybackShell mounted so shelf/channel memory is not wiped on refresh.
    ZStack {
      LivePlaybackShell()
      if model.isLoadingLive && model.liveGroups.isEmpty {
        Color(.systemBackground).ignoresSafeArea()
        ProgressView("正在加载直播…")
      }
    }
    .toolbar(tabBarVisibility, for: .tabBar)
    .animation(.easeInOut(duration: 0.28), value: model.liveFullscreenActive)
    .task {
      if model.liveGroups.isEmpty {
        await model.ensureLiveSourcesLoaded()
      }
    }
  }

  private var tabBarVisibility: Visibility {
    // Fullscreen always hides the tab bar — no swipe-to-reveal / 收起 affordance.
    model.liveFullscreenActive ? .hidden : .automatic
  }
}
