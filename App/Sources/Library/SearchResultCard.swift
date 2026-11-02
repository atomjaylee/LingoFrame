import DesignSystem
import MediaServerKit
import SwiftUI

/// 搜索结果用紧凑横卡展示作品信息，所属资源库由上方标签和分组说明。
struct SearchResultCard: View {
    let item: EmbyItem
    @Environment(AppModel.self) private var model
    @Environment(\.embyClient) private var client
    @Environment(\.embyServerID) private var serverID
    @Environment(\.openWindow) private var openWindow
    @State private var isHovered = false

    private var metadata: String {
        [item.kindLabel, item.productionYear.map(String.init), item.genres?.prefix(2).joined(separator: " · ")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        NavigationLink(value: Route.detail(DetailTarget(tmdb: item.tmdbRef, serverID: serverID, item: item))) {
            HStack(spacing: 12) {
                RemoteImage(url: client?.imageURL(for: item, type: .primary, maxWidth: 240), maxPixelSize: 256)
                    .frame(width: 68, height: 102)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.cardTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(metadata)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    rating
                    Text(item.overview.flatMap { $0.isEmpty ? nil : $0 } ?? "暂无简介")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(width: 280, height: 118, alignment: .leading)
            .background(RexChrome.cardFill.color.opacity(isHovered ? 2 : 1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(RexChrome.cardStroke.color.opacity(isHovered ? 0.9 : 0.45), lineWidth: 0.8))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(ClickablePlainButtonStyle())
        .onHover { isHovered = $0 }
        .hoverTransition(value: isHovered)
        .help(item.cardTitle)
        .contextMenu {
            if item.isPlayable {
                Button("播放") { PlayAction(openWindow: openWindow, model: model, serverID: serverID)(item) }
                Button("从头播放") { PlayAction(openWindow: openWindow, model: model, serverID: serverID)(item, resume: false) }
            }
        }
    }

    @ViewBuilder private var rating: some View {
        if let score = item.communityRating, (0...10).contains(score) {
            HStack(spacing: 2) {
                ForEach(0..<5) { index in
                    let value = score.rounded() / 2 - Double(index)
                    Image(systemName: value >= 1 ? "star.fill" : value >= 0.5 ? "star.leadinghalf.filled" : "star")
                        .font(.system(size: 9))
                }
                Text(score, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.leading, 4)
            }
            .foregroundStyle(.yellow)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("评分 \(score.formatted(.number.precision(.fractionLength(1))))，满分 10 分")
        } else {
            Text("暂无评分").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}
