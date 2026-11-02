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
    @State private var selectedSourceID: String?
    @State private var isSearching = false
    @State private var failedSourceIDs: Set<String> = []
    @State private var retryRevision = 0
    @FocusState private var focused: Bool

    private struct SearchSource: Identifiable, Sendable {
        let id: String
        let name: String
        let client: EmbyClient
        let isAvailable: Bool
    }

    private struct SearchResult: Identifiable, Sendable {
        let source: SearchSource
        let item: EmbyItem
        var id: String { "\(source.id):\(item.id)" }
    }

    private struct SearchResponse: Sendable {
        let source: SearchSource
        let items: [EmbyItem]
        let failed: Bool
    }

    private struct SearchRequest: Hashable {
        let query: String
        let sourceID: String?
        let availableSourceIDs: [String]
        let retryRevision: Int
    }

    private enum ResultKind: String, CaseIterable, Identifiable {
        case movie = "电影", series = "电视剧"
        var id: String { rawValue }
        var itemKind: EmbyItem.Kind { self == .movie ? .movie : .series }
    }

    private var sources: [SearchSource] {
        if let scopedClient, let scopedServerID {
            return [SearchSource(id: scopedServerID, name: model.server(scopedServerID)?.name ?? "当前资源库",
                                 client: scopedClient, isAvailable: true)]
        }
        return model.servers.map {
            SearchSource(id: $0.id, name: $0.name, client: $0.client, isAvailable: $0.state != .offline)
        }
    }

    private var searchRequest: SearchRequest {
        SearchRequest(query: term.trimmingCharacters(in: .whitespacesAndNewlines), sourceID: selectedSourceID,
                      availableSourceIDs: sources.filter(\.isAvailable).map(\.id), retryRevision: retryRevision)
    }

    var body: some View {
        let request = searchRequest
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: theme.metrics.space(2)) {
                    Group {
                        if isSearching { ProgressView().controlSize(.small) }
                        else { Image(systemName: "magnifyingglass").foregroundStyle(theme.colors.inkMuted.color) }
                    }
                    .frame(width: 16, height: 16)
                    TextField("剧集、电影", text: $term)
                        .textFieldStyle(.plain)
                        .themedFont(.body)
                        .focused($focused)
                    if !term.isEmpty {
                        Button { term = ""; focused = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(ClickablePlainButtonStyle())
                        .accessibilityLabel("清空搜索")
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                .frame(maxWidth: 440)
                .rexGlass(cornerRadius: 16)
                .frame(maxWidth: .infinity)

                sourceFilter

                ForEach(sources) { source in
                    ForEach(ResultKind.allCases) { kind in
                        let hits = results.filter {
                            $0.source.id == source.id && $0.item.kind == kind.itemKind
                        }
                        if !hits.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(selectedSourceID == nil && sources.count > 1 ? "\(source.name) · \(kind.rawValue)" : kind.rawValue)
                                        .font(.system(size: 15, weight: .semibold))
                                    Text("\(hits.count) 部").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                ScrollView(.horizontal) {
                                    LazyHStack(spacing: 12) {
                                        ForEach(hits) { result in
                                            SearchResultCard(item: result.item)
                                                .environment(\.embyClient, source.client)
                                                .environment(\.embyServerID, source.id)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .scrollIndicators(.never)
                                .accessibilityLabel("\(source.name)的\(kind.rawValue)搜索结果")
                            }
                        }
                    }
                    if failedSourceIDs.contains(source.id) {
                        HStack {
                            Label("\(source.name) 搜索失败", systemImage: "exclamationmark.circle")
                            Button("重试") { retryRevision += 1 }.buttonStyle(ClickablePlainButtonStyle())
                        }
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }

                let offline = sources.filter { !$0.isAvailable && (selectedSourceID == nil || $0.id == selectedSourceID) }
                if !offline.isEmpty {
                    Text("\(offline.map(\.name).joined(separator: "、")) 未连接，暂未参与搜索")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if request.query.isEmpty {
                    ContentUnavailableView("搜索你的资源库", systemImage: "magnifyingglass",
                                           description: Text("输入片名，同时查找所有资源库，也可以只搜索其中一个。"))
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if !isSearching && results.isEmpty && failedSourceIDs.isEmpty {
                    if request.availableSourceIDs.isEmpty {
                        ContentUnavailableView("没有可搜索的资源库", systemImage: "externaldrive.badge.exclamationmark",
                                               description: Text("请先在资源库页面检查连接。"))
                    } else {
                        ContentUnavailableView.search(text: request.query)
                    }
                }
            }
            .padding(.leading, inset)
            .padding(.trailing, theme.metrics.space(6))
            .padding(.top, 24)
            .padding(.bottom, theme.metrics.space(8))
        }
        .onAppear { focused = true }
        .task(id: request) { await search(request) }
    }

    private var sourceFilter: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button("全部资源库") { selectedSourceID = nil }
                    .buttonStyle(RexCapsuleChipStyle(isSelected: selectedSourceID == nil))
                ForEach(sources) { source in
                    Button(source.name) { selectedSourceID = source.id }
                        .buttonStyle(RexCapsuleChipStyle(isSelected: selectedSourceID == source.id))
                        .disabled(!source.isAvailable)
                }
            }
        }
        .scrollIndicators(.never)
        .accessibilityLabel("搜索范围")
    }

    private func search(_ request: SearchRequest) async {
        results = []
        failedSourceIDs = []
        isSearching = !request.query.isEmpty
        defer { if !Task.isCancelled && searchRequest == request { isSearching = false } }
        guard !request.query.isEmpty else { return }
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        let targets = sources.filter { $0.isAvailable && (request.sourceID == nil || $0.id == request.sourceID) }
        await withTaskGroup(of: SearchResponse.self) { group in
            for source in targets {
                group.addTask {
                    do {
                        let items = try await source.client.search(request.query)
                        return SearchResponse(source: source, items: items, failed: false)
                    } catch {
                        return SearchResponse(source: source, items: [], failed: true)
                    }
                }
            }
            for await response in group {
                guard !Task.isCancelled, searchRequest == request else { group.cancelAll(); return }
                if response.failed { failedSourceIDs.insert(response.source.id) }
                else { results += response.items.map { SearchResult(source: response.source, item: $0) } }
            }
        }
    }
}
