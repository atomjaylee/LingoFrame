import DesignSystem
import MediaServerKit
import SwiftUI

/// 资源库里的一个媒体库：海报墙，分页加载，滚动到底自动加载下一页。
struct LibraryGridView: View {
    let library: EmbyItem
    @Environment(\.embyClient) private var client
    @Environment(\.theme) private var theme
    @Environment(\.contentLeadingInset) private var inset

    @State private var items: [EmbyItem] = []
    @State private var total: Int?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @AppStorage("library.sort") private var sort: EmbyClient.Sort = .name
    @AppStorage("library.descending") private var descending = false

    private let pageSize = 60

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metrics.space(6)) {
                VStack(alignment: .leading, spacing: theme.metrics.space(1)) {
                    Text(library.displayName).themedFont(.title1)
                    if let total {
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
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: theme.metrics.posterWidth, maximum: theme.metrics.posterWidth * 1.3),
                                             spacing: theme.metrics.space(4))],
                          alignment: .leading, spacing: theme.metrics.space(6)) {
                    ForEach(items) { item in
                        ItemCard(item: item)
                            .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                    }
                }
                .mediaCardStyle(PosterTileStyle())
                if isLoading { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(.leading, inset)
            .padding(.trailing, theme.metrics.space(6))
            .padding(.top, 56)
            .padding(.bottom, theme.metrics.space(8))
        }
        .themedBackground(tint: theme.colors.tintPlum.color)
        .overlay {
            if let errorMessage {
                ContentUnavailableView("加载失败", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                    .padding(.leading, inset)
            } else if !isLoading && items.isEmpty {
                ContentUnavailableView("这个媒体库是空的", systemImage: "film.stack").padding(.leading, inset)
            }
        }
        .task(id: "\(sort.rawValue)-\(descending)") { await reload() }
    }

    private func reload() async {
        items = []
        total = nil
        await loadMore()
    }

    private func loadMore() async {
        guard let client, !isLoading, total.map({ items.count < $0 }) ?? true else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.items(in: library.id, sort: sort, descending: descending,
                                              start: items.count, limit: pageSize)
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            total = page.totalRecordCount ?? items.count
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
