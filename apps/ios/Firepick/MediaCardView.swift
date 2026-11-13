import FirepickCore
import SwiftUI

struct MediaCardView: View {
  let item: MediaItem
  var progress: Double? = nil
  var subtitle: String? = nil
  /// Compact continue-watching: fixed poster height (~55–65% of grid).
  var compactPosterHeight: CGFloat? = nil

  private let posterCorner: CGFloat = 12
  private let posterRatio: CGFloat = 2.0 / 3.0

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      poster
      titleBlock
    }
  }

  private var poster: some View {
    ZStack {
      CachedRemoteImage(url: item.pic.flatMap(URL.init(string:))) {
        posterSkeleton
      }
      .scaledToFill()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()

      if let score = displayScore {
        Text(score)
          .font(.caption2.weight(.bold))
          .foregroundStyle(.white)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(Color.orange, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          .padding(6)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }

      if let remarks = item.remarks, !remarks.isEmpty {
        Text(remarks)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(.black.opacity(0.55), in: Capsule())
          .padding(6)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      }

      if let progress, progress > 0 {
        GeometryReader { geo in
          Capsule()
            .fill(Color.orange)
            .frame(width: max(4, geo.size.width * min(1, max(0, progress))), height: 3)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
      }
    }
    .frame(maxWidth: .infinity)
    .modifier(PosterSizeModifier(height: compactPosterHeight, ratio: posterRatio))
    .clipShape(RoundedRectangle(cornerRadius: posterCorner, style: .continuous))
  }

  private var posterSkeleton: some View {
    RoundedRectangle(cornerRadius: posterCorner, style: .continuous)
      .fill(Color.secondary.opacity(0.12))
      .overlay {
        RoundedRectangle(cornerRadius: posterCorner, style: .continuous)
          .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
      }
      .shimmering()
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(item.name)
        .font(
          compactPosterHeight == nil
            ? .subheadline.weight(.semibold) : .caption.weight(.semibold)
        )
        .lineLimit(2)
        .frame(
          minHeight: compactPosterHeight == nil ? 36 : 0,
          alignment: .topLeading
        )
        .foregroundStyle(.primary)

      if let subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }

  private var displayScore: String? {
    guard let douban = item.doubanScore, douban > 0 else { return nil }
    return String(format: "%.1f", douban)
  }
}

private struct PosterSizeModifier: ViewModifier {
  let height: CGFloat?
  let ratio: CGFloat

  func body(content: Content) -> some View {
    if let height {
      content
        .frame(height: height)
        .frame(width: height * ratio)
    } else {
      content.aspectRatio(ratio, contentMode: .fit)
    }
  }
}

private extension View {
  func shimmering() -> some View {
    modifier(ShimmerModifier())
  }
}

private struct ShimmerModifier: ViewModifier {
  @State private var phase: CGFloat = -1

  func body(content: Content) -> some View {
    content
      .overlay {
        GeometryReader { geo in
          LinearGradient(
            colors: [
              .clear,
              Color.white.opacity(0.35),
              .clear,
            ],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: geo.size.width * 0.45)
          .offset(x: phase * geo.size.width)
        }
        .clipped()
      }
      .onAppear {
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
          phase = 1.2
        }
      }
  }
}
