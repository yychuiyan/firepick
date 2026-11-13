import FirepickCore
import SwiftUI

struct MediaCardView: View {
  let item: MediaItem
  var progress: Double? = nil
  var subtitle: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .bottomLeading) {
        CachedRemoteImage(url: item.pic.flatMap(URL.init(string:))) {
          ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(Color.orange.opacity(0.12))
            Text(initials)
              .font(.title3.weight(.bold))
              .foregroundStyle(.orange.opacity(0.85))
          }
        }
        .scaledToFill()
        .frame(maxWidth: .infinity)
        .aspectRatio(item.ratio ?? 0.72, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        if let remarks = item.remarks, !remarks.isEmpty {
          Text(remarks)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
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

      Text(item.name)
        .font(.subheadline.weight(.semibold))
        .lineLimit(2)
        .foregroundStyle(.primary)

      if let subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      } else if let remarks = item.remarks, !remarks.isEmpty, progress == nil {
        // Prefer badge; skip duplicate under title when already shown.
        EmptyView()
      }
    }
  }

  private var initials: String {
    let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return "萤" }
    return String(first)
  }
}
