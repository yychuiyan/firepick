import SwiftUI

struct ErrorBannerView: View {
  let message: String
  var retryTitle: String = "重试"
  var onRetry: (() -> Void)? = nil
  var onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let onRetry {
        Button(retryTitle, action: onRetry)
          .font(.subheadline.weight(.semibold))
      }
      Button {
        onDismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("关闭")
    }
    .padding(12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
    )
    .padding(.horizontal)
    .padding(.vertical, 6)
  }
}
