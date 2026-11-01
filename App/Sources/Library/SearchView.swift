import DesignSystem
import MediaServerKit
import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.embyClient) private var scopedClient
    @Environment(\.embyServerID) private var scopedServerID
    @Environment(\.theme) private var theme
    @Environment(\.contentLeadingInset) private var inset
    @State private var term = ""
    @State private var results: [SearchResult] = []
    @FocusState private var focused: Bool

    private struct SearchResult: Identifiable {
        let serverID: String
        let client: EmbyClient
        let item: EmbyItem
        var id: String { "\(serverID):\(item.id)" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metrics.space(6)) {
                Text("搜索").themedFont(.title1)
                HStack(spacing: theme.metrics.space(2)) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.colors.inkMuted.color)
                    TextField("剧集、电影、单集", text: $term)
                        .textFieldStyle(.plain)
                        .themedFont(.body)
                        .focused($focused)
                }
                .padding(.horizontal, theme.metrics.space(4))
                .frame(height: 44)
                .frame(maxWidth: 520)
                .rexGlass(cornerRadius: 22)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: theme.metrics.posterWidth, maximum: theme.metrics.posterWidth * 1.3),
                                             spacing: theme.metrics.space(4))],
                          alignment: .leading, spacing: theme.metrics.space(6)) {
                    ForEach(results) { result in
                        ItemCard(item: result.item)
                            .environment(\.embyClient, result.client)
                            .environment(\.embyServerID, result.serverID)
                    }
                }
                .mediaCardStyle(PosterTileStyle())
            }
            .padding(.leading, inset)
            .padding(.trailing, theme.metrics.space(6))
            .padding(.top, 56)
            .padding(.bottom, theme.metrics.space(8))
        }
        .overlay {
            if !term.isEmpty && results.isEmpty { ContentUnavailableView.search(text: term).padding(.leading, inset) }
        }
        .onAppear { focused = true }
        .task(id: term) {
            let query = term.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else {
                results = []
                return
            }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }
            let targets: [(id: String, client: EmbyClient)]
            if let scopedClient, let scopedServerID {
                targets = [(scopedServerID, scopedClient)]
            } else {
                targets = model.servers.filter { $0.state != .offline }.map { ($0.id, $0.client) }
            }
            guard !targets.isEmpty else {
                results = []
                return
            }
            var found: [SearchResult] = []
            for target in targets {
                let items = (try? await target.client.search(query)) ?? []
                guard !Task.isCancelled else { return }
                found += items.map { SearchResult(serverID: target.id, client: target.client, item: $0) }
            }
            guard !Task.isCancelled, term.trimmingCharacters(in: .whitespaces) == query else { return }
            results = found
        }
    }
}
