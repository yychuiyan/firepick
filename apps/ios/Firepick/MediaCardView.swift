import FirepickCore
import SwiftUI

/// Poster card: tag top-leading, score top-trailing, title under the poster.
struct MediaCardView: View {
  let item: MediaItem
  var progress: Double? = nil
  var subtitle: String? = nil
  var compactPosterHeight: CGFloat? = nil

  private let posterCorner: CGFloat = 8
  private let posterRatio: CGFloat = 3.0 / 4.0

  var body: some View {
    VStack(spacing: 0) {
      poster
      if let progress, progress > 0 {
        GeometryReader { geo in
          Rectangle()
            .fill(Color.white.opacity(0.9))
            .frame(width: max(4, geo.size.width * min(1, max(0, progress))), height: 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 2)
        .background(Color.black.opacity(0.25))
      }
      Text(item.name)
        .font(.caption.weight(.medium))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
    .frame(minWidth: 0, maxWidth: .infinity)
  }

  private var poster: some View {
    Color.clear
      .modifier(PosterSizeModifier(height: compactPosterHeight, ratio: posterRatio))
      .overlay {
        CachedRemoteImage(url: RemoteImageCache.normalizedURL(from: item.pic)) {
          Color.black.opacity(0.12)
            .shimmering()
        }
        .scaledToFill()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
      }
      .overlay(alignment: .topTrailing) {
        if let score = displayScore {
          Text(score)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.orange, in: Capsule())
            .padding(6)
        }
      }
      .overlay(alignment: .bottom) {
        if let strip = bottomStatus {
          Text(strip)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.38))
        }
      }
      .frame(minWidth: 0, maxWidth: .infinity)
      .clipShape(RoundedRectangle(cornerRadius: posterCorner, style: .continuous))
  }

  /// Bottom bar: only update progress / 已完结. Hide quality labels like 正片、TC.
  private var bottomStatus: String? {
    if let subtitle, !subtitle.isEmpty, !isQualityLabel(subtitle) { return subtitle }
    let remarks = item.remarks?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !remarks.isEmpty else { return nil }
    if isCompleted(remarks) { return "已完结" }
    if isQualityLabel(remarks) { return nil }
    return remarks
  }

  private func isCompleted(_ remarks: String) -> Bool {
    if remarks.contains("完结") || remarks.contains("已完结") { return true }
    if remarks.range(of: #"全\s*\d+\s*集"#, options: .regularExpression) != nil,
      !remarks.contains("更新")
    {
      return true
    }
    return false
  }

  private func isQualityLabel(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return false }
    // Exact or near-exact source/quality chips — not episode progress.
    if t.range(
      of: #"^(正片|预告|花絮|TC|TS|CAM|HD|BD|4K|蓝光|高清|超清|抢先|抢先版)$"#,
      options: [.regularExpression, .caseInsensitive]
    ) != nil {
      return true
    }
    return false
  }

  /// Douban first, then site score — same rule as detail.
  private var displayScore: String? {
    if let douban = item.doubanScore, douban > 0 {
      return String(format: "%.1f", douban)
    }
    if let score = item.score, score > 0 {
      return String(format: "%.1f", score)
    }
    return nil
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

extension View {
  func shimmering() -> some View {
    modifier(ShimmerModifier())
  }
}

struct ShimmerModifier: ViewModifier {
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
