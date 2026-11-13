import FirepickCore
import SwiftUI

struct BrowseFilterSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var draft: [String: String] = [:]

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          ForEach(model.categoryFilters, id: \.key) { filter in
            filterSection(filter)
          }
          Text("年份、地区和类型会交给采集站筛选。站不支持时，会再在返回结果里筛一次。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding()
      }
      .navigationTitle("筛选")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("重置") {
            resetDraft()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") {
            Task { await applyAndClose() }
          }
          .fontWeight(.semibold)
        }
      }
      .safeAreaInset(edge: .bottom) {
        Button {
          Task { await applyAndClose() }
        } label: {
          Text("查看结果")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .padding()
        .background(.bar)
      }
    }
    .presentationDetents([.medium, .large])
    .onAppear {
      draft = model.filterSelections
    }
  }

  private func filterSection(_ filter: SourceFilter) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(filter.name)
        .font(.subheadline.weight(.semibold))
      FlowChipRow(values: filter.value, selected: draft[filter.key] ?? "") { value in
        draft[filter.key] = value.value
      }
    }
  }

  private func resetDraft() {
    draft = model.categoryFilters.reduce(into: [:]) { values, filter in
      values[filter.key] = filter.initValue ?? filter.value.first?.value ?? ""
    }
  }

  private func applyAndClose() async {
    await model.applyFilters(draft)
    dismiss()
  }
}

private struct FlowChipRow: View {
  let values: [FilterValue]
  let selected: String
  let onSelect: (FilterValue) -> Void

  var body: some View {
    FlexibleChipWrap(values: values, selected: selected, onSelect: onSelect)
  }
}

/// Simple wrapping chip layout without extra dependencies.
private struct FlexibleChipWrap: View {
  let values: [FilterValue]
  let selected: String
  let onSelect: (FilterValue) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        HStack(spacing: 8) {
          ForEach(Array(row.enumerated()), id: \.offset) { _, value in
            Button {
              onSelect(value)
            } label: {
              Text(value.name)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                  selected == value.value ? Color.orange : Color.secondary.opacity(0.12),
                  in: Capsule()
                )
                .foregroundStyle(selected == value.value ? Color.white : Color.primary)
            }
            .buttonStyle(.plain)
          }
          Spacer(minLength: 0)
        }
      }
    }
  }

  /// Chunk into rows of ~4 for a stable wrap approximation.
  private var rows: [[FilterValue]] {
    stride(from: 0, to: values.count, by: 4).map { start in
      Array(values[start..<min(start + 4, values.count)])
    }
  }
}
