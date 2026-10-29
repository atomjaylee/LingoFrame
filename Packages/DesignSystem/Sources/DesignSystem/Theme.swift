import Foundation

// 主题 = 一组设计令牌，命名和取值来自设计系统 Rex（深紫影院底 + 磨砂玻璃卡片 + 琥珀橙 / 电光紫点缀 + 大圆角胶囊）。
// 所有界面只引用令牌（theme.colors.ink、theme.metrics.radiusLg），不写死具体颜色和尺寸。
// 外观只有深色、浅色、跟随系统三种，令牌本身带浅色和深色两套值。

/// 颜色令牌：浅色、深色模式各一个值。
/// 值可以是 "#RRGGBB"、"#RRGGBBAA"、"rgba(r,g,b,a)"，或者 "system:<名字>" 跟随 macOS 系统色。
public struct ColorToken: Hashable, Codable, Sendable {
    public var light: String
    public var dark: String

    public init(light: String, dark: String) {
        self.light = light
        self.dark = dark
    }

    public init(_ both: String) {
        self.init(light: both, dark: both)
    }
}

/// 颜色令牌，名称与 Rex 的 tokens.json 一一对应（kebab-case 改成 camelCase）。
public struct ThemeColors: Hashable, Codable, Sendable {
    /// 页面最底层背景。
    public var bgBase: ColorToken
    /// 铺在背景上的大面积柔光。
    public var bgGlow: ColorToken
    /// 实色卡片（固定背景上用）。
    public var surfaceCard: ColorToken
    /// 侧边栏、底部面板这类浮在页面上的大面板。
    public var surfaceRaised: ColorToken
    /// 胶囊导航、圆形按钮的底色。
    public var surfaceControl: ColorToken
    /// 选中行、选中项的底色。
    public var surfaceSelected: ColorToken
    /// 卡片和面板外圈 1px 细边、分隔线。
    public var borderHairline: ColorToken
    /// 主文字。
    public var ink: ColorToken
    /// 次要文字。
    public var inkMuted: ColorToken
    /// 琥珀橙：剧集、当前最突出的那一项。
    public var accentAmber: ColorToken
    /// 电光紫：电影、图表、短语标记。只做图形不做小字。
    public var accentViolet: ColorToken
    public var accentVioletDim: ColorToken
    public var success: ColorToken
    public var danger: ColorToken
    public var statusOnline: ColorToken
    /// 主按钮（白色胶囊），一个页面只放一个。
    public var buttonPrimary: ColorToken
    public var onButtonPrimary: ColorToken
    public var buttonNeutral: ColorToken
    public var onButtonNeutral: ColorToken
    /// 海报底部压暗的终点色。
    public var scrim: ColorToken
    /// 磨砂玻璃的填充和高光边。
    public var glassFill: ColorToken
    public var glassStroke: ColorToken
    public var progressFill: ColorToken
    public var progressTrack: ColorToken
    public var popoverFill: ColorToken
    /// 背景随内容取色失败时的默认底色。
    public var tintPlum: ColorToken
    public var tintNavy: ColorToken
    public var tintUmber: ColorToken
    public var tintDusk: ColorToken
}

/// 一种文字样式：字号、行高、字重，以及用正文字体还是展示字体。
public struct TextStyleToken: Hashable, Codable, Sendable {
    public enum Family: String, Hashable, Codable, Sendable { case sans, display }

    public var size: Double
    public var lineHeight: Double
    /// 100–900。
    public var weight: Int
    public var family: Family

    public init(size: Double, lineHeight: Double, weight: Int, family: Family = .sans) {
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.family = family
    }
}

public struct ThemeTypography: Hashable, Codable, Sendable {
    /// 正文字体族；nil 表示系统字体（英文数字 SF Pro，中文苹方）。
    public var sansFamily: String?
    /// 展示字体族；nil 表示系统字体。
    public var displayFamily: String?
    /// 统计大数字。
    public var statHero: TextStyleToken
    /// 压在海报上的片名（细体大字）。
    public var mediaTitle: TextStyleToken
    /// 页面标题。
    public var title1: TextStyleToken
    /// 分组标题。
    public var title2: TextStyleToken
    /// 卡片名。
    public var headline: TextStyleToken
    /// 正文、简介。
    public var body: TextStyleToken
    /// 线路、日期、说明。
    public var subhead: TextStyleToken
    /// 角标。
    public var caption: TextStyleToken
}

public enum Density: String, Hashable, Codable, Sendable, CaseIterable {
    case compact, regular, comfortable

    public var scale: Double {
        switch self {
        case .compact: 0.8
        case .regular: 1
        case .comfortable: 1.25
        }
    }
}

public struct ShadowToken: Hashable, Codable, Sendable {
    public var radius: Double
    public var y: Double
    public var opacity: Double
}

public struct ThemeMetrics: Hashable, Codable, Sendable {
    /// 图标底块、角标。
    public var radiusSm: Double
    /// 海报缩略图、选中行。
    public var radiusMd: Double
    /// 所有卡片。
    public var radiusLg: Double
    /// 侧边栏、大面板、底部弹出面板。
    public var radiusXl: Double
    /// 间距基本单位 4px：space(1)=4、space(2)=8、space(3)=12、space(4)=16、space(6)=24、space(8)=32。
    public var spaceUnit: Double
    public var density: Density
    public var posterWidth: Double
    public var sidebarWidth: Double
    /// 浮动面板离窗口边缘的距离。
    public var floatingInset: Double
    /// 浮在内容上的面板阴影。
    public var shadowFloat: ShadowToken

    /// 乘以密度后的间距，参数是 Rex 的 space-N 里的 N。
    public func space(_ n: Double) -> Double { spaceUnit * n * density.scale }
}

public enum ThemeAppearance: String, Hashable, Codable, Sendable, CaseIterable {
    case dark, light, system

    public var title: String {
        switch self {
        case .dark: "深色"
        case .light: "浅色"
        case .system: "自动"
        }
    }
}

public struct Theme: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    /// 缺省为跟随系统。
    public var appearance: ThemeAppearance?
    public var colors: ThemeColors
    public var typography: ThemeTypography
    public var metrics: ThemeMetrics

    public init(id: String, name: String, appearance: ThemeAppearance? = nil, colors: ThemeColors,
                typography: ThemeTypography, metrics: ThemeMetrics) {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.colors = colors
        self.typography = typography
        self.metrics = metrics
    }
}

// MARK: - Rex 主题

extension Theme {
    /// 取值来自 Rex 的 tokens.json（深色 · 影院 / 浅色 · 磨砂）。
    static let rexColors = ThemeColors(
        bgBase: ColorToken(light: "#e6e3f2", dark: "#2e2b3c"),
        bgGlow: ColorToken(light: "#f4ecf6", dark: "#4a3451"),
        surfaceCard: ColorToken(light: "#fcf5fe", dark: "#2f2538"),
        surfaceRaised: ColorToken(light: "#fefefe", dark: "#432d45"),
        surfaceControl: ColorToken(light: "#e6e6e5", dark: "#2a2638"),
        surfaceSelected: ColorToken(light: "#e6e6e5", dark: "#544258"),
        borderHairline: ColorToken(light: "rgba(0,0,0,0.08)", dark: "rgba(255,255,255,0.12)"),
        ink: ColorToken(light: "#111111", dark: "#ffffff"),
        // 浅色的原始取值 #9d9da5 对比度不够，正文场景按设计系统的建议加深。
        inkMuted: ColorToken(light: "#6e6e78", dark: "#ac9bb1"),
        accentAmber: ColorToken(light: "#fbb016", dark: "#ffad08"),
        accentViolet: ColorToken("#5e4cff"),
        accentVioletDim: ColorToken(light: "#d9d4ff", dark: "#3b3363"),
        success: ColorToken(light: "#23cd53", dark: "#40b370"),
        danger: ColorToken("#ff4439"),
        statusOnline: ColorToken(light: "#4fbf2a", dark: "#b8fe3c"),
        buttonPrimary: ColorToken(light: "#111111", dark: "#ffffff"),
        onButtonPrimary: ColorToken(light: "#ffffff", dark: "#111111"),
        buttonNeutral: ColorToken(light: "#e6e6e5", dark: "#b8b8b8"),
        onButtonNeutral: ColorToken(light: "#111111", dark: "#4a4a4a"),
        scrim: ColorToken(light: "rgba(0,0,0,0.55)", dark: "rgba(0,0,0,0.85)"),
        glassFill: ColorToken(light: "rgba(255,255,255,0.75)", dark: "rgba(255,255,255,0.12)"),
        glassStroke: ColorToken(light: "rgba(255,255,255,0.9)", dark: "rgba(255,255,255,0.18)"),
        progressFill: ColorToken(light: "#0e0e0e", dark: "#ffffff"),
        progressTrack: ColorToken(light: "rgba(0,0,0,0.12)", dark: "rgba(255,255,255,0.22)"),
        popoverFill: ColorToken(light: "rgba(255,255,255,0.92)", dark: "rgba(70,78,87,0.92)"),
        tintPlum: ColorToken(light: "#ece4f0", dark: "#47384e"),
        tintNavy: ColorToken(light: "#e3e8f2", dark: "#23354c"),
        tintUmber: ColorToken(light: "#f1e8dc", dark: "#48321a"),
        tintDusk: ColorToken("#413f61"))

    static let rexTypography = ThemeTypography(
        sansFamily: nil, displayFamily: nil,
        statHero: TextStyleToken(size: 44, lineHeight: 48, weight: 600, family: .display),
        mediaTitle: TextStyleToken(size: 48, lineHeight: 56, weight: 300, family: .display),
        title1: TextStyleToken(size: 28, lineHeight: 34, weight: 700, family: .display),
        title2: TextStyleToken(size: 20, lineHeight: 26, weight: 600),
        headline: TextStyleToken(size: 17, lineHeight: 22, weight: 600),
        body: TextStyleToken(size: 15, lineHeight: 22, weight: 400),
        subhead: TextStyleToken(size: 13, lineHeight: 18, weight: 500),
        caption: TextStyleToken(size: 11, lineHeight: 14, weight: 500))

    static let rexMetrics = ThemeMetrics(
        radiusSm: 8, radiusMd: 10, radiusLg: 18, radiusXl: 32, spaceUnit: 4, density: .regular,
        posterWidth: 150, sidebarWidth: 247, floatingInset: 10,
        shadowFloat: ShadowToken(radius: 14, y: 8, opacity: 0.22))

    /// Rex 主题：同一套令牌，外观决定取浅色值还是深色值。
    public static func rex(_ appearance: ThemeAppearance) -> Theme {
        let name = switch appearance {
        case .dark: "深色"
        case .light: "浅色"
        case .system: "自动"
        }
        return Theme(id: "rex.\(appearance.rawValue)", name: name, appearance: appearance,
                     colors: rexColors, typography: rexTypography, metrics: rexMetrics)
    }

    public static let standard = rex(.dark)
}
