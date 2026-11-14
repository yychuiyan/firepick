import FirepickCore
import SwiftUI

struct LiveView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Group {
      if model.isLoadingLive && model.liveGroups.isEmpty {
        ZStack {
          Color(.systemBackground).ignoresSafeArea()
          ProgressView("正在加载直播…")
        }
      } else {
        LivePlaybackShell()
      }
    }
    .toolbar(tabBarVisibility, for: .tabBar)
    .animation(.easeInOut(duration: 0.28), value: model.liveFullscreenActive)
    .animation(.easeInOut(duration: 0.28), value: model.liveShowsTabBarInFullscreen)
    .task {
      if model.liveGroups.isEmpty {
        await model.ensureLiveSourcesLoaded()
      }
    }
  }

  private var tabBarVisibility: Visibility {
    if model.liveFullscreenActive && !model.liveShowsTabBarInFullscreen {
      return .hidden
    }
    return .automatic
  }
}
