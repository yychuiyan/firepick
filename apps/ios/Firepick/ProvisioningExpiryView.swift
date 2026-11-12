import FirepickCore
import SwiftUI

struct ProvisioningExpirySection: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var profile: ProvisioningProfileInfo?

  var body: some View {
    Section {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        if let profile {
          LabeledContent(
            "到期时间",
            value: Self.dateFormatter.string(from: profile.expirationDate)
          )
          LabeledContent(
            "剩余有效期",
            value: remainingText(until: profile.expirationDate, now: context.date)
          )
          .foregroundStyle(
            profile.expirationDate <= context.date
              ? Color.red
              : profile.expirationDate.timeIntervalSince(context.date) < 86_400
                ? Color.orange
                : Color.green
          )
        } else {
          Text("未找到签名描述文件")
            .foregroundStyle(.secondary)
        }
      }
      Text("SideStore 自动续签后，重新回到设置页会刷新该时间。")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .task {
      reload()
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        reload()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        reload()
      }
    }
  }

  private func reload() {
    guard
      let url = Bundle.main.url(
        forResource: "embedded",
        withExtension: "mobileprovision"
      ),
      let data = try? Data(contentsOf: url)
    else {
      profile = nil
      return
    }
    profile = try? ProvisioningProfileParser.parse(data)
  }

  private func remainingText(until expiration: Date, now: Date) -> String {
    let seconds = expiration.timeIntervalSince(now)
    guard seconds > 0 else { return "已过期" }
    if seconds >= 86_400 {
      return "\(Int(seconds / 86_400)) 天"
    }
    if seconds >= 3_600 {
      return "\(Int(seconds / 3_600)) 小时"
    }
    return "\(max(1, Int(seconds / 60))) 分钟"
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()
}
