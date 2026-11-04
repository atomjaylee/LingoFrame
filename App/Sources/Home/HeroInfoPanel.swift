import DesignSystem
import SwiftUI
import TMDBKit

/// 压在大图底部的信息区，首页和详情页共用，照抄 Rex：
/// 左边片名 Logo、「日期 · 地区 · 时长」、评分行，右边一个胶囊主按钮；
/// 一条细分隔线下面是两行简介，右边一排图标按钮。任何主题下都是深底白字。
struct HeroInfoPanel<Primary: View, Actions: View>: View {
    let title: TMDBTitle?
    var fallbackTitle = ""
    var chineseName: String?
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
                    if let chineseName {
                        Text(chineseName)
                            .font(.system(size: 20, weight: .semibold))
                            .lineLimit(1)
                            .padding(.top, 8)
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
/// 图片比区域高时不居中裁切，而是让人脸或画面主体落在上半部分看得见的地方。
struct HeroBackdrop: View {
    let url: URL?
    /// 底部渐隐到的颜色；nil 表示压成黑色。
    var fadeTo: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var artwork: DecodedImage?
    @State private var artworkURL: URL?
    @State private var focus = BackdropFocus.fallback

    /// 焦点在区域里的目标位置：水平居中，竖直放在上部，避开底部的片名和简介。
    private static let target = CGPoint(x: 0.5, y: 0.32)

    var body: some View {
        // 图片放在 overlay 里，按比例填满时不会把外面的布局撑宽。
        Color.clear
            .overlay {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        if let artwork {
                            focusedImage(artwork.cgImage, in: geometry.size)
                                .id(artworkURL)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
            }
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
            .task(id: url) {
                guard let url else { artwork = nil; artworkURL = nil; return }
                let loaded = try? await ImagePipeline.shared.image(for: url, maxPixelSize: 4096)
                guard !Task.isCancelled else { return }
                // 焦点和图片一起换上，避免先居中显示再跳到焦点。
                let point = if let loaded { await BackdropFocus.shared.point(for: loaded.cgImage, url: url) }
                    else { BackdropFocus.fallback }
                guard !Task.isCancelled else { return }
                // 原图加载完成后再交叉淡化，切换时保留上一张，避免中途闪空白。
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.65)) {
                    artwork = loaded
                    artworkURL = url
                    focus = point
                }
            }
    }

    /// 等比放大到铺满，再平移让焦点尽量落在目标位置；平移不会露出图片以外的空白。
    private func focusedImage(_ image: CGImage, in size: CGSize) -> some View {
        let imageWidth = Double(image.width), imageHeight = Double(image.height)
        let scale = max(size.width / imageWidth, size.height / imageHeight)
        let width = imageWidth * scale, height = imageHeight * scale
        func offset(_ target: Double, _ focus: Double, length: Double, container: Double) -> Double {
            min(max(container * target - focus * length, container - length), 0)
        }
        return Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: width, height: height)
            .offset(x: offset(Self.target.x, focus.x, length: width, container: size.width),
                    y: offset(Self.target.y, focus.y, length: height, container: size.height))
    }
}
