import FirepickCore
import SwiftUI

struct SourceManagementView: View {
  @Environment(AppModel.self) private var model
  @State private var query = ""

  private var stations: [AppModel.CollectionStation] {
    let all = model.collectionStations
    guard !query.isEmpty else { return all }
    return all.filter {
      $0.name.localizedCaseInsensitiveContains(query)
        || $0.detail.localizedCaseInsensitiveContains(query)
    }
  }

  private var usesFirepickCMS: Bool {
    model.configuration.sites.contains(where: { $0.key == "firepick_cms" })
  }

  private var isProbing: Bool {
    model.isCollectionProbeRunning || !model.probingCollectionStationIDs.isEmpty
  }

  var body: some View {
    List {
      Section {
        if stations.isEmpty {
          ContentUnavailableView(
            query.isEmpty ? "还没有采集站" : "没有匹配的采集站",
            systemImage: query.isEmpty ? "antenna.radiowaves.left.and.right" : "magnifyingglass",
            description: Text(
              query.isEmpty
                ? "当前线路没有可展示的采集站。"
                : "换个名称再试。"
            )
          )
        } else {
          ForEach(stations) { station in
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                  .foregroundStyle(.primary)
                Text(station.detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer(minLength: 8)
              latencyBadge(for: station)
            }
            .padding(.vertical, 2)
          }
        }
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("当前线路 · \(stations.count)")
          if let status = model.collectionStationProbeStatus {
            Text(status)
              .font(.caption)
              .foregroundStyle(.secondary)
              .textCase(nil)
          } else if usesFirepickCMS {
            Text("展示获取到的最佳采集站。点右上角可重新获取最佳线路。概况请到「线路管理」打开具体线路查看。")
              .font(.caption)
              .foregroundStyle(.secondary)
              .textCase(nil)
          } else if !stations.isEmpty {
            Text("当前线路下的本机可播源。延迟为采集接口往返时间。")
              .font(.caption)
              .foregroundStyle(.secondary)
              .textCase(nil)
          }
        }
      }
    }
    .navigationTitle("采集站管理")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(isProbing ? "获取中…" : "获取最佳线路") {
          Task { await model.probeCollectionStationLatencies() }
        }
        .disabled((stations.isEmpty && !usesFirepickCMS) || isProbing)
      }
    }
    .searchable(text: $query, prompt: "搜索采集站")
    .task(id: model.currentConnection?.id) {
      // First enter: 获取最佳线路 (full candidate race). Fresh pool → badge-only refresh.
      if usesFirepickCMS {
        await model.ensureBestCMSLinesOnEnter()
      } else {
        await model.probeCollectionStationLatencies()
      }
    }
    .refreshable {
      await model.probeCollectionStationLatencies()
    }
  }

  @ViewBuilder
  private func latencyBadge(for station: AppModel.CollectionStation) -> some View {
    if let ms = model.collectionStationLatencyMS[station.id] {
      Text("\(ms)ms")
        .font(.caption.monospacedDigit().weight(.medium))
        .foregroundStyle(latencyColor(ms))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(latencyColor(ms).opacity(0.12), in: Capsule())
    } else if model.probingCollectionStationIDs.contains(station.id) || isProbing {
      Text("…")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    } else if model.didProbeCollectionStations {
      Text("失败")
        .font(.caption2.weight(.medium))
        .foregroundStyle(.red.opacity(0.85))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.red.opacity(0.10), in: Capsule())
    } else {
      Text("—")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }

  private func latencyColor(_ ms: Int) -> Color {
    if ms < 800 { return .green }
    if ms < 2000 { return .orange }
    return .red
  }
}
