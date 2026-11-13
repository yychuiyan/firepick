import FirepickCore
import SwiftUI

struct LiveView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Group {
      if model.isLoadingLive && model.liveGroups.isEmpty {
        ZStack {
          Color.black.ignoresSafeArea()
          ProgressView("正在加载直播…")
            .tint(.white)
            .foregroundStyle(.white)
        }
      } else {
        LivePlaybackShell()
      }
    }
    .task {
      if model.liveGroups.isEmpty {
        await model.refreshLiveSources()
      }
    }
  }
}
