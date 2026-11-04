import DesignSystem
import MediaServerKit
import SwiftUI

/// 资源库里的一个媒体库：海报墙，分页加载，滚动到底自动加载下一页。
struct LibraryGridView: View {
    let library: EmbyItem
    @Environment(AppModel.self) private var model
    @Environment(\.embyClient) private var client
    @Environment(\.embyServerID) private var serverID
    @Environment(\.theme) private var theme
    @Environment(\.contentLeadingInset) private var inset

    @AppStorage("library.sort") private var sort: EmbyClient.Sort = .dateAdded
    @AppStorage("library.descending") private var descending = true

    private var list: LibraryList? {
        guard let client, let serverID else { return nil }
        return model.libraryStore.list(for: LibraryListKey(serverID: serverID, libraryID: library.id,
                                                           sort: sort, descending: descending),
                                       client: client)
    }

    var body: some View {
        let list = self.list
        let items = list?.items ?? []
        let loadMoreTriggers = Set(items.suffix(10).map(\.id))
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metrics.space(6)) {
                VStack(alignment: .leading, spacing: theme.metrics.space(1)) {
                    Text(library.displayName).themedFont(.title1)
                    if let total = list?.total {
                        Text("\(total) 部").themedFont(.subhead).foregroundStyle(theme.colors.inkMuted.color)
                    }
                }
                HStack(spacing: theme.metrics.space(1)) {
                    ForEach(EmbyClient.Sort.allCases, id: \.self) { s in
                        Button(s.title) { sort = s }
                            .buttonStyle(RexChipStyle(isSelected: sort == s))
                    }
                    Button { descending.toggle() } label: {
                        Image(systemName: descending ? "arrow.down" : "arrow.up")
                    }
                    .buttonStyle(RexIconButtonStyle(diameter: 36))
                    .accessibilityLabel(descending ? "降序" : "升序")
                    .padding(.leading, theme.metrics.space(2))
                    Button { Task { await list?.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(RexIconButtonStyle(diameter: 36))
                    .help("刷新")
                    .accessibilityLabel("刷新")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: theme.metrics.posterWidth, maximum: theme.metrics.posterWidth * 1.3),
                                             spacing: theme.metrics.space(4))],
                          alignment: .leading, spacing: theme.metrics.space(6)) {
                    ForEach(items) { item in
                        ItemCard(item: item)
                            .onAppear {
                                if loadMoreTriggers.contains(item.id) {
                                    Task { await list?.loadMore() }
                                }
                            }
                    }
                }
                .mediaCardStyle(PosterTileStyle())
                if list?.isLoadingFirstPage == true || list?.isLoadingMore == true {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(.leading, inset)
            .padding(.trailing, theme.metrics.space(6))
            .padding(.top, 56)
            .padding(.bottom, theme.metrics.space(8))
        }
        // 换排序后是另一份列表，从头开始看。
        .id("\(sort.rawValue)-\(descending)")
        .themedBackground(tint: theme.colors.tintPlum.color)
        .overlay {
            if let errorMessage = list?.errorMessage {
                ContentUnavailableView("加载失败", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                    .padding(.leading, inset)
            } else if list?.isConfirmedEmpty == true {
                ContentUnavailableView("这个媒体库是空的", systemImage: "film.stack").padding(.leading, inset)
            }
        }
        .task(id: "\(sort.rawValue)-\(descending)-\(model.watchProgressRevision)") {
            await list?.revalidate(progressRevision: model.watchProgressRevision)
        }
    }
}
