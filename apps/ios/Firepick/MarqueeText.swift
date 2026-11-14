import SwiftUI

/// Single-line player title: scrolls in a loop when text overflows the cap width.
struct PlayerTitleLabel: View {
  let text: String
  var font: Font = .subheadline.weight(.semibold)
  /// Caps the visible title so side chrome keeps room for controls.
  var maxWidth: CGFloat? = 200
  var fadeWidth: CGFloat = 18
  /// Points per second while marquee is active.
  var speed: CGFloat = 28
  var gap: CGFloat = 36

  @State private var textWidth: CGFloat = 0
  @State private var containerWidth: CGFloat = 0

  private var capWidth: CGFloat { maxWidth ?? 200 }

  private var needsMarquee: Bool {
    textWidth > 1 && containerWidth > 1 && textWidth > containerWidth - 2
  }

  var body: some View {
    ZStack(alignment: .leading) {
      // Hidden measurer (full intrinsic width).
      Text(text)
        .font(font)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .opacity(0)
        .accessibilityHidden(true)
        .overlay {
          GeometryReader { geo in
            Color.clear.preference(key: TitleTextWidthKey.self, value: geo.size.width)
          }
        }

      if needsMarquee {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
          let cycle = max(textWidth + gap, 1)
          let elapsed = context.date.timeIntervalSinceReferenceDate
          let travel = CGFloat(elapsed) * speed
          let x = -(travel.truncatingRemainder(dividingBy: cycle))
          HStack(spacing: gap) {
            Text(text)
              .font(font)
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
            Text(text)
              .font(font)
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
              .accessibilityHidden(true)
          }
          .offset(x: x)
        }
      } else {
        Text(text)
          .font(font)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .center)
      }
    }
    .frame(width: capWidth, alignment: .leading)
    .clipped()
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
    .background {
      GeometryReader { geo in
        Color.clear.preference(key: TitleContainerWidthKey.self, value: geo.size.width)
      }
    }
    .onPreferenceChange(TitleTextWidthKey.self) { textWidth = $0 }
    .onPreferenceChange(TitleContainerWidthKey.self) { containerWidth = $0 }
    .onChange(of: text) { _, _ in
      textWidth = 0
    }
    .accessibilityLabel(text)
  }
}

private struct TitleTextWidthKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct TitleContainerWidthKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}
