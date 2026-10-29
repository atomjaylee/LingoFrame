import DesignSystem
import SwiftUI
import TMDBKit

/// 压在大图底部的信息区，首页和详情页共用，照抄 Rex：
/// 左边片名 Logo、「日期 · 地区 · 时长」、评分行，右边一个胶囊主按钮；
/// 一条细分隔线下面是两行简介，右边一排图标按钮。任何主题下都是深底白字。
struct HeroInfoPanel<Primary: View, Actions: View>: View {
    let title: TMDBTitle?
    var fallbackTitle = ""
    let meta: [String]
    var rating: Double?
    var level: String?
    var note: String?
    var overview: String?
    @ViewBuilder var primary: Primary
    @ViewBuilder var actions: Actions

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 32) {
                VStack(alignment: .leading, spacing: 0) {
                    if let title {
                        TitleLogo(title: title, tmdb: model.tmdb, height: 90, maxWidth: 320)
                    } else {
                        Text(fallbackTitle).font(.system(size: 44, weight: .bold)).lineLimit(2)
                    }
                    metaLine.padding(.top, 12)
                    ratings.padding(.top, 5)
                }
                Spacer(minLength: 0)
                primary
            }
            Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
                .padding(.top, 12)
                .padding(.bottom, 10)
            HStack(alignment: .center, spacing: 32) {
                Text(overview ?? "")
                    .font(.system(size: 14, weight: .medium))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .frame(maxWidth: 790, alignment: .leading)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                HStack(spacing: 28) { actions }
                    .buttonStyle(RexHeroIconButtonStyle())
                    .frame(width: 300)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var metaLine: some View {
        meta.enumerated().reduce(Text("")) { text, pair in
            pair.offset == 0 ? Text(pair.element)
                : text + Text("  ·  ").foregroundStyle(.white.opacity(0.45)) + Text(pair.element)
        }
        .font(.system(size: 14, weight: .semibold))
    }

    @ViewBuilder private var ratings: some View {
        HStack(spacing: 12) {
            if let rating {
                HStack(spacing: 4) {
                    RatingBadge(.tmdb, text: "TMDB")
                    Text(String(format: "%.1f", rating))
                }
            }
            if let level {
                HStack(spacing: 4) {
                    RatingBadge(.level, text: level)
                    Text("难度")
                }
            }
            if let note {
                Text(note).fontWeight(.medium).foregroundStyle(.white.opacity(0.72)).lineLimit(1).layoutPriority(-1)
            }
        }
        .font(.system(size: 13, weight: .semibold))
    }
}

/// 胶囊主按钮里的图标 + 文字。
struct PillLabel: View {
    let title: String
    var systemImage: String?

    init(_ title: String, systemImage: String? = "play.fill") {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 15)) }
            Text(title).lineLimit(1)
        }
    }
}

enum HeroMeta {
    /// 「2005-03-24」「美国」「9 季」「每集约 22 分钟」。
    static func parts(_ t: TMDBTitle?, isSeries: Bool, fallbackYear: Int? = nil, fallbackRuntime: String? = nil,
                      seasonCount: Int? = nil) -> [String] {
        var parts: [String] = []
        if let date = t?.releaseDate { parts.append(date) } else if let y = t?.year ?? fallbackYear { parts.append(String(y)) }
        let regions = (t?.countries ?? []).prefix(2).map { Locale(identifier: "zh_CN").localizedString(forRegionCode: $0) ?? $0 }
        if !regions.isEmpty { parts.append(regions.joined(separator: " / ")) }
        if isSeries, let n = t?.seasonCount ?? seasonCount { parts.append("\(n) 季") }
        if let m = t?.runtimeMinutes { parts.append(isSeries ? "每集约 \(m) 分钟" : "\(m) 分钟") }
        else if let r = fallbackRuntime, !isSeries { parts.append(r) }
        if parts.isEmpty, let genre = t?.genres.first { parts.append(genre) }
        return parts
    }
}

/// 大图：铺满给定区域，左侧和底部压暗，保证上面的白字看得清。
struct HeroBackdrop: View {
    let url: URL?
    /// 底部渐隐到的颜色；nil 表示压成黑色。
    var fadeTo: Color?

    var body: some View {
        // 图片放在 overlay 里，按比例填满时不会把外面的布局撑宽。
        Color.clear
            .overlay { RemoteImage(url: url, maxPixelSize: 3000) }
            .clipped()
            .overlay {
                LinearGradient(stops: [.init(color: .black.opacity(0.25), location: 0),
                                       .init(color: .clear, location: 0.2),
                                       .init(color: .clear, location: 0.38),
                                       .init(color: (fadeTo ?? .black).opacity(fadeTo == nil ? 0.5 : 0.75), location: 0.66),
                                       .init(color: (fadeTo ?? .black).opacity(fadeTo == nil ? 0.8 : 1), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay {
                LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 0.45)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .accessibilityHidden(true)
    }
}
