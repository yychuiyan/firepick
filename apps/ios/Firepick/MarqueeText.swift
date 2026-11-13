import SwiftUI

/// Fixed-width single-line title with soft faded edges (no marquee scroll).
struct PlayerTitleLabel: View {
  let text: String
  var font: Font = .subheadline.weight(.semibold)
  /// Caps the visible title so side chrome keeps a soft fade, not a hard clip.
  var maxWidth: CGFloat? = 200
  var fadeWidth: CGFloat = 18

  var body: some View {
    Text(text)
      .font(font)
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(
        maxWidth: maxWidth ?? .infinity,
        alignment: .center
      )
      .mask {
        HStack(spacing: 0) {
          LinearGradient(
            colors: [.clear, .black],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: fadeWidth)
          Color.black
          LinearGradient(
            colors: [.black, .clear],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: fadeWidth)
        }
      }
      .accessibilityLabel(text)
  }
}
