import SwiftUI

/// Quiet branded artwork used only after every real poster candidate fails.
/// It keeps missing covers readable without pretending to be a programme poster.
struct DefaultPosterArtwork: View {
  private let ink = Color(red: 0.10, green: 0.12, blue: 0.15)
  private let umber = Color(red: 0.25, green: 0.18, blue: 0.13)
  private let ember = Color(red: 0.96, green: 0.53, blue: 0.22)

  var body: some View {
    GeometryReader { geometry in
      let compact = min(geometry.size.width, geometry.size.height) < 150
      ZStack {
        LinearGradient(
          colors: [ink, umber],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )

        RadialGradient(
          colors: [ember.opacity(0.30), .clear],
          center: .topLeading,
          startRadius: 0,
          endRadius: max(geometry.size.width, geometry.size.height) * 0.82
        )

        LinearGradient(
          colors: [.white.opacity(0.04), .clear, .black.opacity(0.20)],
          startPoint: .top,
          endPoint: .bottom
        )

        filmStrip(compact: compact)

        VStack(spacing: compact ? 7 : 11) {
          Spacer(minLength: compact ? 12 : 20)

          ZStack {
            RoundedRectangle(cornerRadius: compact ? 11 : 15, style: .continuous)
              .fill(.white.opacity(0.08))
              .overlay {
                RoundedRectangle(cornerRadius: compact ? 11 : 15, style: .continuous)
                  .strokeBorder(.white.opacity(0.13), lineWidth: 0.7)
              }
            Image(systemName: "play.rectangle.on.rectangle.fill")
              .font(.system(size: compact ? 21 : 29, weight: .medium))
              .foregroundStyle(.white.opacity(0.76))
          }
          .frame(width: compact ? 46 : 64, height: compact ? 46 : 64)

          Text("拾萤")
            .font((compact ? Font.caption2 : Font.caption).weight(.semibold))
            .tracking(compact ? 2.2 : 3.2)
            .foregroundStyle(.white.opacity(0.58))

          Spacer(minLength: compact ? 12 : 20)
        }
        .padding(.horizontal, compact ? 10 : 16)
      }
    }
    .clipped()
    .accessibilityHidden(true)
  }

  private func filmStrip(compact: Bool) -> some View {
    HStack {
      Spacer()
      VStack(spacing: compact ? 8 : 12) {
        ForEach(0..<6, id: \.self) { _ in
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(.white.opacity(0.055))
            .frame(width: compact ? 6 : 8, height: compact ? 10 : 15)
        }
      }
      .padding(.trailing, compact ? 7 : 11)
      .padding(.vertical, compact ? 12 : 18)
    }
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(.white.opacity(0.035))
        .frame(width: compact ? 19 : 28)
    }
  }
}
