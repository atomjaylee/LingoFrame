import AppKit
import SwiftUI

// MARK: - 令牌 → SwiftUI

extension ColorToken {
    /// 跟随浅色 / 深色外观自动切换的颜色。
    public var color: Color { Color(nsColor: nsColor) }

    public var nsColor: NSColor {
        let light = Self.parse(light), dark = Self.parse(dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func parse(_ value: String) -> NSColor {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("system:") {
            return systemColors[String(v.dropFirst(7))] ?? .labelColor
        }
        if v.hasPrefix("rgba(") || v.hasPrefix("rgb("), let open = v.firstIndex(of: "("), let close = v.lastIndex(of: ")") {
            let parts = v[v.index(after: open)..<close].split(separator: ",")
                .map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            guard parts.count >= 3 else { return .magenta }
            return NSColor(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255,
                           alpha: parts.count > 3 ? parts[3] : 1)
        }
        var hex = v
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let n = UInt64(hex, radix: 16) else { return .magenta }
        let hasAlpha = hex.count == 8
        let r = Double((n >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((n >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((n >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(n & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static let systemColors: [String: NSColor] = [
        "windowBackgroundColor": .windowBackgroundColor,
        "separatorColor": .separatorColor,
        "labelColor": .labelColor,
        "secondaryLabelColor": .secondaryLabelColor,
        "controlAccentColor": .controlAccentColor,
    ]
}

public enum TextRole: Sendable, CaseIterable {
    case statHero, mediaTitle, title1, title2, headline, body, subhead, caption
}

extension Theme {
    /// 交给 .preferredColorScheme 使用；nil 表示跟随系统。
    public var colorScheme: ColorScheme? {
        switch appearance ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    public func textStyle(_ role: TextRole) -> TextStyleToken {
        switch role {
        case .statHero: typography.statHero
        case .mediaTitle: typography.mediaTitle
        case .title1: typography.title1
        case .title2: typography.title2
        case .headline: typography.headline
        case .body: typography.body
        case .subhead: typography.subhead
        case .caption: typography.caption
        }
    }

    public func font(_ role: TextRole, weight: Font.Weight? = nil) -> Font {
        let style = textStyle(role)
        let family = style.family == .display ? typography.displayFamily : typography.sansFamily
        let base: Font = family.map { .custom($0, size: style.size) } ?? .system(size: style.size)
        return base.weight(weight ?? Self.weight(style.weight))
    }

    static func weight(_ value: Int) -> Font.Weight {
        switch value {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }
}

// MARK: - 环境

extension EnvironmentValues {
    @Entry public var theme: Theme = .standard
}

extension View {
    /// 按主题的文字样式设置字体和行高。
    public func themedFont(_ role: TextRole, weight: Font.Weight? = nil) -> some View {
        modifier(ThemedFont(role: role, weight: weight))
    }

    /// 页面底色 + 大面积柔光。tint 为 nil 时用主题的 bgBase。
    public func themedBackground(tint: Color? = nil) -> some View {
        modifier(ThemedBackground(tint: tint))
    }

    /// 磨砂玻璃：半透明填充 + 1px 高光边，让背景色透上来。
    public func rexGlass(cornerRadius: Double? = nil) -> some View {
        modifier(RexGlass(cornerRadius: cornerRadius))
    }

    /// 浮起的大面板（侧边栏、侧栏面板）：实色底 + 细边 + 浮动阴影。
    public func rexRaised(cornerRadius: Double? = nil) -> some View {
        modifier(RexRaised(cornerRadius: cornerRadius))
    }

    /// 玻璃卡片：内边距 space-4 + 圆角 radius-lg。
    public func rexCard() -> some View {
        modifier(RexCard())
    }

    /// 让系统表单和列表透出主题背景。
    public func themedFormBackground() -> some View {
        scrollContentBackground(.hidden)
    }
}

private struct ThemedFont: ViewModifier {
    @Environment(\.theme) private var theme
    let role: TextRole
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        let style = theme.textStyle(role)
        content
            .font(theme.font(role, weight: weight))
            .lineSpacing(max(0, style.lineHeight - style.size * 1.2))
    }
}

private struct ThemedBackground: ViewModifier {
    @Environment(\.theme) private var theme
    let tint: Color?

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                (tint ?? theme.colors.bgBase.color)
                RadialGradient(colors: [theme.colors.bgGlow.color.opacity(0.9), .clear], center: UnitPoint(x: 0.3, y: 1),
                               startRadius: 0, endRadius: 900)
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: tint)
        }
    }
}

private struct RexGlass: ViewModifier {
    @Environment(\.theme) private var theme
    let cornerRadius: Double?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? theme.metrics.radiusLg, style: .continuous)
        content
            .background(.ultraThinMaterial, in: shape)
            .background(theme.colors.glassFill.color, in: shape)
            .overlay(shape.strokeBorder(theme.colors.glassStroke.color, lineWidth: 1))
    }
}

private struct RexRaised: ViewModifier {
    @Environment(\.theme) private var theme
    let cornerRadius: Double?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? theme.metrics.radiusXl, style: .continuous)
        let s = theme.metrics.shadowFloat
        // 阴影只加在背景形状上：直接对容器加 .shadow 会让里面每个文字、图标都带一层阴影，看起来发虚。
        content
            .clipShape(shape)
            .background {
                shape.fill(theme.colors.surfaceRaised.color)
                    .shadow(color: .black.opacity(s.opacity), radius: s.radius, y: s.y)
            }
            .overlay(shape.strokeBorder(theme.colors.borderHairline.color, lineWidth: 1))
    }
}

private struct RexCard: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(theme.metrics.space(4))
            .rexGlass()
    }
}
