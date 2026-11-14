import FirepickCore
import SwiftUI

/// FongMi `dialog_filter`: a short bottom sheet of horizontal chip rows.
struct BrowseFilterSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  private var visibleFilters: [SourceFilter] {
    model.categoryFilters.filter { filter in
      let key = filter.key.lowercased()
      let name = filter.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if key == "source" || key == "site" || key == "provider" { return false }
      if name == "源站" || name == "站点" || name == "来源" { return false }
      return true
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(visibleFilters, id: \.key) { filter in
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(filter.value, id: \.value) { value in
              let selected = (model.filterSelections[filter.key] ?? filter.initValue ?? "") == value.value
              Button(value.name) {
                Task { await model.selectFilter(filter, value: value) }
              }
              .buttonStyle(.plain)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(selected ? Color.white : Color.primary)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(
                selected ? Color.orange : Color.secondary.opacity(0.12),
                in: Capsule()
              )
            }
          }
          .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.systemBackground))
    .presentationDetents([.height(sheetHeight)])
    .presentationDragIndicator(.visible)
    .presentationBackground(Color(.systemBackground))
  }

  private var sheetHeight: CGFloat {
    let rows = CGFloat(max(visibleFilters.count, 1))
    return min(360, 36 + rows * 52)
  }
}
