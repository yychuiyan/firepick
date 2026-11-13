import FirepickCore
import FirepickPlayback
import SwiftUI

struct BrowseView: View {
  @Environment(AppModel.self) private var model
  @State private var selectedItem: MediaItem?
  @State private var showingSearch = false
  @State private var showingSourcePicker = false

  private var columns: [GridItem] {
    [
      GridItem(
        .adaptive(minimum: model.posterSizePreference.minimumWidth, maximum: 240),
        spacing: 16
      )
    ]
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          pageHeader

          if let categories = model.homeResult?.classes, !categories.isEmpty {
            ScrollView(.horizontal) {
              HStack {
                ForEach(categories) { category in
                  Button(category.typeName) {
                    Task { await model.loadCategory(category) }
                  }
                  .buttonStyle(.bordered)
                  .tint(.secondary)
                }
              }
              .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
          }

          if !model.categoryFilters.isEmpty {
            ScrollView(.horizontal) {
              HStack(spacing: 8) {
                ForEach(model.categoryFilters, id: \.key) { filter in
                  Menu {
                    ForEach(
                      Array(filter.value.enumerated()),
                      id: \.offset
                    ) { entry in
                      let value = entry.element
                      Button {
                        Task {
                          await model.selectFilter(filter, value: value)
                        }
                      } label: {
                        if model.filterSelections[filter.key] == value.value {
                          Label(value.name, systemImage: "checkmark")
                        } else {
                          Text(value.name)
                        }
                      }
                    }
                  } label: {
                    Label(
                      "\(filter.name)：\(model.selectedFilterName(filter))",
                      systemImage: "line.3.horizontal.decrease.circle"
                    )
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.secondary.opacity(0.1), in: Capsule())
                  }
                }
              }
              .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
          }

          if model.isLoading {
            ProgressView("正在读取数据源…")
              .frame(maxWidth: .infinity)
              .padding(.vertical, 48)
          } else if let items = model.homeResult?.list, !items.isEmpty {
            LazyVGrid(columns: columns, spacing: 22) {
              ForEach(items) { item in
                Button {
                  Task {
                    if item.isAction {
                      await model.performAction(item)
                    } else if item.isFolder {
                      await model.openFolder(item)
                    } else {
                      selectedItem = item
                    }
                  }
                } label: {
                  MediaCard(item: item)
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.horizontal)
            if model.currentPage < (model.homeResult?.pagecount ?? 0) {
              Button {
                Task { await model.loadMore() }
              } label: {
                if model.isLoadingMore {
                  ProgressView()
                } else {
                  Text("加载更多")
                }
              }
              .buttonStyle(.bordered)
              .disabled(model.isLoadingMore)
              .padding(.vertical, 8)
            }
          } else {
            ContentUnavailableView(
              "还没有内容",
              systemImage: "sparkles"
            )
          }
        }
        .padding(.vertical)
      }
      .refreshable {
        guard let site = model.selectedSite else { return }
        await model.selectSite(site)
      }
      .toolbar(.hidden, for: .navigationBar)
      .sheet(isPresented: $showingSearch) {
        SearchView()
      }
      .sheet(isPresented: $showingSourcePicker) {
        SourcePickerView()
      }
      .sheet(item: $selectedItem) { item in
        DetailView(item: item)
      }
    }
  }

  private var pageHeader: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        Text(model.selectedSite?.name ?? "拾萤")
          .font(.system(size: 28, weight: .bold))
          .lineLimit(1)
        Button {
          showingSourcePicker = true
        } label: {
          HStack(spacing: 5) {
            if let site = model.selectedSite {
              Text(model.routeLabel(for: site))
            }
            Text(model.selectedSite == nil ? "选择点播源" : "切换点播源")
            Image(systemName: "chevron.down")
              .font(.caption2.weight(.semibold))
          }
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(1)
        }
        .buttonStyle(.plain)
        .disabled(model.configuration.sites.isEmpty)
      }
      Spacer(minLength: 8)
      HStack(spacing: 8) {
        Button {
          showingSearch = true
        } label: {
          Image(systemName: "magnifyingglass")
            .font(.title3.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜索")
        .disabled(model.selectedSite == nil)
        .opacity(model.selectedSite == nil ? 0.4 : 1)

        NavigationLink {
          LibraryView(mode: .history)
        } label: {
          Image(systemName: "clock.arrow.circlepath")
            .font(.title3.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("最近观看")
      }
    }
    .padding(.horizontal)
    .padding(.top, 8)
  }
}

private struct MediaCard: View {
  let item: MediaItem

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      AsyncImage(url: item.pic.flatMap(URL.init(string:))) { image in
        image
          .resizable()
          .scaledToFill()
      } placeholder: {
        ZStack {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.secondary.opacity(0.1))
          Image(systemName: "film")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
        }
      }
      .aspectRatio((item.ratio ?? 0.72), contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

      Text(item.name)
        .font(.subheadline.weight(.semibold))
        .lineLimit(2)
      if let remarks = item.remarks, !remarks.isEmpty {
        Text(remarks)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}
