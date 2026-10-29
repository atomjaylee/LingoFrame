import DesignSystem
import MediaServerKit
import SwiftUI

struct SearchView: View {
    @Environment(\.embyClient) private var client
    @Environment(\.theme) private var theme
    @Environment(\.contentLeadingInset) private var inset
    @State private var term = ""
    @State private var results: [EmbyItem] = []
    @FocusState private var focused: Bool

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
                    ForEach(results) { ItemCard(item: $0) }
                }
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
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled, let client, !query.isEmpty else {
                results = []
                return
            }
            let found = (try? await client.search(query)) ?? []
            guard !Task.isCancelled, term.trimmingCharacters(in: .whitespaces) == query else { return }
            results = found
        }
    }
}
