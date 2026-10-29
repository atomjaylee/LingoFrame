import SwiftUI

// 照着 Rex 截图量出来的窗口外观：渐变窗口底、半透明浮动侧边栏、压在大图上的胶囊按钮和评分角标、信息卡片。
// 尺寸单位都是点（截图约 1.39 像素 = 1 点）。

/// Rex 窗口外观的令牌。只用于窗口外框和大图区，页面内容仍然用 Theme 的令牌。
public enum RexChrome {
    /// 窗口底：左上梅紫、右上深蓝、左下酒红、右下近黑四块柔光。
    public static let glowPlum = ColorToken(light: "#f1dcec", dark: "#5e2c52")
    public static let glowNavy = ColorToken(light: "#dbe3f3", dark: "#2c3a5e")
    public static let glowWine = ColorToken(light: "#f3dde0", dark: "#5a2431")
    public static let glowInk = ColorToken(light: "#ecebef", dark: "#232325")
    public static let windowBase = ColorToken(light: "#f3eef3", dark: "#3a2a3a")
    /// 浮动侧边栏：半透明深底，背景色透上来。
    public static let sidebarFill = ColorToken(light: "rgba(255,255,255,0.55)", dark: "rgba(40,32,38,0.52)")
    public static let sidebarStroke = ColorToken(light: "rgba(0,0,0,0.08)", dark: "rgba(255,255,255,0.10)")
    public static let rowSelected = ColorToken(light: "rgba(0,0,0,0.07)", dark: "rgba(255,255,255,0.10)")
    public static let inkTertiary = ColorToken(light: "rgba(0,0,0,0.45)", dark: "rgba(255,255,255,0.45)")
    public static let separator = ColorToken(light: "rgba(0,0,0,0.08)", dark: "rgba(255,255,255,0.08)")
    /// 资源库卡片描边和填充。
    public static let cardStroke = ColorToken(light: "rgba(0,0,0,0.14)", dark: "rgba(255,255,255,0.20)")
    public static let cardFill = ColorToken(light: "rgba(255,255,255,0.45)", dark: "rgba(255,255,255,0.04)")
    /// 详情页下半部分的底色（大图渐隐到这里）。
    public static let detailBase = ColorToken(light: "#23272d", dark: "#23272d")
    /// 对话框底色。
    public static let sheet = ColorToken(light: "#ffffff", dark: "#232323")
    public static let online = ColorToken(light: "#4fbf2a", dark: "#a8f04a")
    public static let confirm = ColorToken("#7ad03a")
    public static let accentBlue = ColorToken("#2f6fea")

    public static let sidebarWidth = 247.0
    public static let sidebarInset = 10.0
    public static let sidebarRadius = 14.0
    /// 内容区左边距：侧边栏右缘再空 41 点。
    public static let contentLeading = sidebarInset + sidebarWidth + 41
    public static let contentTrailing = 30.0
}

// MARK: - 窗口底与侧边栏

extension View {
    /// Rex 窗口底：四角柔光渐变。
    public func rexWindowBackground() -> some View {
        background {
            RexWindowBackground().ignoresSafeArea()
        }
    }

    /// 浮动侧边栏：磨砂 + 半透明底 + 1 点细边，圆角 14。
    public func rexSidebarPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: RexChrome.sidebarRadius, style: .continuous)
        return self
            .background(RexChrome.sidebarFill.color, in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(RexChrome.sidebarStroke.color, lineWidth: 1))
    }
}

public struct RexWindowBackground: View {
    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let r = max(geo.size.width, geo.size.height) * 0.75
            ZStack {
                RexChrome.windowBase.color
                RadialGradient(colors: [RexChrome.glowPlum.color, .clear], center: UnitPoint(x: 0.08, y: 0), startRadius: 0, endRadius: r)
                RadialGradient(colors: [RexChrome.glowNavy.color, .clear], center: UnitPoint(x: 1, y: 0), startRadius: 0, endRadius: r)
                RadialGradient(colors: [RexChrome.glowWine.color, .clear], center: UnitPoint(x: 0.12, y: 1), startRadius: 0, endRadius: r)
                RadialGradient(colors: [RexChrome.glowInk.color, .clear], center: UnitPoint(x: 1, y: 1), startRadius: 0, endRadius: r * 0.9)
            }
        }
    }
}

// MARK: - 大图区

/// 大图上的胶囊按钮：300×45，磨砂半透明白。
public struct RexPillButtonStyle: ButtonStyle {
    var dimmed: Bool

    public init(dimmed: Bool = false) { self.dimmed = dimmed }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white.opacity(dimmed ? 0.9 : 1))
            .frame(width: 300, height: 45)
            .background(.white.opacity(dimmed ? 0.10 : configuration.isPressed ? 0.24 : 0.16), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
            .contentShape(Capsule())
    }
}

/// 左上角的圆形返回按钮：32 点，压暗磨砂 + 白色细边。
public struct RexBackButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(.black.opacity(configuration.isPressed ? 0.4 : 0.22), in: Circle())
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .contentShape(Circle())
    }
}

/// 大图区右下角那排图标按钮。
public struct RexHeroIconButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.6 : 1))
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
    }
}

/// 评分行里的小角标，比如 IMDb、TMDB、难度等级。
public struct RatingBadge: View {
    public enum Kind: Sendable { case tmdb, imdb, level }

    let kind: Kind
    let text: String

    public init(_ kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: kind == .level ? 9 : 8, weight: .heavy))
            .foregroundStyle(kind == .level ? .white : kind == .imdb ? .black : Color(red: 0.05, green: 0.15, blue: 0.25))
            .padding(.horizontal, kind == .level ? 4 : 3)
            .frame(height: 13)
            .background {
                switch kind {
                case .imdb: Color(red: 0.96, green: 0.77, blue: 0.09)
                case .tmdb: LinearGradient(colors: [Color(red: 0.56, green: 0.81, blue: 0.63), Color(red: 0.0, green: 0.71, blue: 0.89)],
                                           startPoint: .leading, endPoint: .trailing)
                case .level: Color(red: 0.37, green: 0.30, blue: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

// MARK: - 内容区组件

/// 分组标题后面跟的胶囊选项，比如「4K」「第 2 季」。
public struct RexCapsuleChipStyle: ButtonStyle {
    let isSelected: Bool

    public init(isSelected: Bool) { self.isSelected = isSelected }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(.white.opacity(isSelected ? 0.24 : configuration.isPressed ? 0.16 : 0.10), in: Capsule())
            .contentShape(Capsule())
    }
}

/// 视频 / 音频 / 字幕这类信息卡：标题行 + 两列键值。
public struct RexInfoCard: View {
    let title: String
    let systemImage: String
    let rows: [(String, String)]

    public init(_ title: String, systemImage: String, rows: [(String, String)]) {
        self.title = title
        self.systemImage = systemImage
        self.rows = rows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage).font(.system(size: 14, weight: .bold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 5) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0 + "：").foregroundStyle(.white.opacity(0.72)).frame(width: 64, alignment: .leading)
                        Text(row.1).foregroundStyle(.white.opacity(0.88)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.09), lineWidth: 1))
    }
}

/// Emby 的菱形标志。
public struct EmbyMark: View {
    let size: Double

    public init(size: Double = 30) { self.size = size }

    public var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(red: 0.32, green: 0.71, blue: 0.29))
                .frame(width: size * 0.66, height: size * 0.66)
                .rotationEffect(.degrees(45))
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.3))
                .foregroundStyle(.white)
                .offset(x: size * 0.03)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
