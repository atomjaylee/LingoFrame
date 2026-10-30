import SwiftUI

// Rex 组件的 SwiftUI 版本，类名对照设计系统的 bundle.css（rx-btn、rx-chip、rx-seg……）。
// 媒体卡片沿用「样式协议」写法：组件只收集数据，长什么样交给环境里的样式决定。

// MARK: - 按钮

private struct ClickablePointer: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.pointerStyle(isEnabled ? .link : .default)
    }
}

extension View {
    /// 可操作时显示手形，禁用时恢复默认指针；由系统处理移入和移出。
    public func clickablePointer() -> some View { modifier(ClickablePointer()) }
}

/// 主按钮 rx-btn--primary：白色胶囊，一个页面只放一个。
public struct RexPrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var height: Double

    public init(height: Double = 48) { self.height = height }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(theme.colors.onButtonPrimary.color)
            .padding(.horizontal, theme.metrics.space(6))
            .frame(height: height)
            .background(theme.colors.buttonPrimary.color.opacity(isEnabled ? 1 : 0.5), in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Capsule())
            .clickablePointer()
    }
}

/// 中性按钮 rx-btn--neutral：压在较亮海报上时代替主按钮。
public struct RexNeutralButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(theme.colors.onButtonNeutral.color)
            .padding(.horizontal, theme.metrics.space(6))
            .frame(height: 48)
            .background(theme.colors.buttonNeutral.color, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .clickablePointer()
    }
}

/// 主按钮的标准内容：图标 + 标题 + 一行小字（比如播放进度）。
public struct PrimaryButtonLabel: View {
    let title: String
    let subtitle: String?
    let systemImage: String?

    public init(_ title: String, subtitle: String? = nil, systemImage: String? = "play.fill") {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)) }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12, weight: .medium)).opacity(0.7)
                }
            }
        }
    }
}

/// 圆形图标按钮 rx-icon-btn：默认 44px 玻璃圆，用于返回、更多。必须给 accessibilityLabel。
public struct RexIconButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    var diameter: Double
    var glass: Bool

    public init(diameter: Double = 44, glass: Bool = true) {
        self.diameter = diameter
        self.glass = glass
    }

    public func makeBody(configuration: Configuration) -> some View {
        let circle = Circle()
        configuration.label
            .font(.system(size: diameter * 0.4, weight: .semibold))
            .foregroundStyle(theme.colors.ink.color)
            .frame(width: diameter, height: diameter)
            .background(glass ? theme.colors.glassFill.color : .clear, in: circle)
            .background(glass ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.clear), in: circle)
            .overlay(circle.strokeBorder(glass ? theme.colors.glassStroke.color : .clear, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(circle)
            .clickablePointer()
    }
}

/// 文字按钮 rx-btn--text：次要动作。
public struct RexTextButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .themedFont(.subhead)
            .foregroundStyle(theme.colors.inkMuted.color)
            .padding(theme.metrics.space(2))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
            .clickablePointer()
    }
}

/// 胶囊切换 rx-chip：选中是玻璃底 + 高光边 + 主文字色，未选中只显示次要文字。
public struct RexChipStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    var isSelected: Bool
    var height: Double

    public init(isSelected: Bool, height: Double = 36) {
        self.isSelected = isSelected
        self.height = height
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isSelected ? theme.colors.ink.color : theme.colors.inkMuted.color)
            .padding(.horizontal, theme.metrics.space(4))
            .frame(height: height)
            .background(isSelected ? theme.colors.glassFill.color : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? theme.colors.glassStroke.color : .clear, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
            .clickablePointer()
    }
}

/// 玻璃按钮组 rx-btn-group：2–4 个线性图标并排放在一个玻璃胶囊里。
public struct GlassButtonGroup<Content: View>: View {
    @Environment(\.theme) private var theme
    private let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        HStack(spacing: theme.metrics.space(6)) { content }
            .buttonStyle(.plain)
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(theme.colors.ink.color)
            .padding(.horizontal, theme.metrics.space(6))
            .frame(height: 48)
            .rexGlass(cornerRadius: 24)
    }
}

// MARK: - 进度

/// 一条胶囊进度：已看部分 progress-fill，剩余 progress-track。
public struct ProgressCapsule: View {
    @Environment(\.theme) private var theme
    let value: Double
    var height: Double

    public init(value: Double, height: Double = 4) {
        self.value = value
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.colors.progressTrack.color)
                Capsule().fill(theme.colors.progressFill.color)
                    .frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int(value * 100))%")
    }
}

/// 分段进度 rx-seg：每集（或每句）一小段，已完成的是 progress-fill，可以高亮当前这一段。
public struct SegmentedProgress: View {
    @Environment(\.theme) private var theme
    let total: Int
    let done: Int
    var highlight: Int?
    var height: Double

    public init(total: Int, done: Int, highlight: Int? = nil, height: Double = 4) {
        self.total = total
        self.done = done
        self.highlight = highlight
        self.height = height
    }

    public var body: some View {
        HStack(spacing: total > 80 ? 1 : 3) {
            ForEach(0..<max(total, 1), id: \.self) { i in
                Capsule().fill(color(i))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(done) / \(total)")
    }

    private func color(_ i: Int) -> Color {
        if i == highlight { return theme.colors.accentAmber.color }
        return i < done ? theme.colors.progressFill.color : theme.colors.progressTrack.color
    }
}

// MARK: - 小部件

/// 状态圆点：在线、离线、未知。离线时调用方要同时写出文字。
public struct StatusDot: View {
    public enum State: Sendable { case online, offline, idle }

    @Environment(\.theme) private var theme
    let state: State

    public init(_ state: State) { self.state = state }

    public var body: some View {
        Circle()
            .fill(state == .online ? theme.colors.statusOnline.color
                  : state == .offline ? theme.colors.danger.color : theme.colors.inkMuted.color)
            .frame(width: 7, height: 7)
            .accessibilityLabel(state == .online ? "在线" : state == .offline ? "无响应" : "状态未知")
    }
}

/// 胶囊标签 rx-pill。
public struct PillTag: View {
    @Environment(\.theme) private var theme
    let text: String
    let systemImage: String?
    let prominent: Bool

    public init(_ text: String, systemImage: String? = nil, prominent: Bool = false) {
        self.text = text
        self.systemImage = systemImage
        self.prominent = prominent
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(prominent ? theme.colors.onButtonPrimary.color : theme.colors.ink.color)
        .padding(.horizontal, theme.metrics.space(3))
        .frame(height: 28)
        .background(prominent ? theme.colors.buttonPrimary.color : theme.colors.surfaceControl.color, in: Capsule())
    }
}

public struct BadgeModel: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// 普通角标：surface-control 底。
        case neutral
        /// 紫色底（电影、类型、短语）。
        case accent
        /// 琥珀色字（当前最突出的那一项，比如杜比视界）。
        case highlight
    }

    public var text: String
    public var kind: Kind
    public var id: String { text }

    public init(_ text: String, kind: Kind = .neutral) {
        self.text = text
        self.kind = kind
    }
}

/// 角标：caption 字号 + radius-sm。
public struct Badge: View {
    @Environment(\.theme) private var theme
    let model: BadgeModel

    public init(_ model: BadgeModel) { self.model = model }

    public var body: some View {
        Text(model.text)
            .themedFont(.caption)
            .foregroundStyle(model.kind == .highlight ? theme.colors.accentAmber.color : theme.colors.ink.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(model.kind == .accent ? theme.colors.accentViolet.color : theme.colors.surfaceControl.color,
                        in: RoundedRectangle(cornerRadius: theme.metrics.radiusSm, style: .continuous))
    }
}

/// 分组标题：title-2，可带一个「›」表示可以进入更多。
public struct SectionHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    let showsChevron: Bool

    public init(_ title: String, showsChevron: Bool = false) {
        self.title = title
        self.showsChevron = showsChevron
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text(title).themedFont(.title2)
            if showsChevron { Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)) }
        }
        .foregroundStyle(theme.colors.ink.color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 数字 + 单位：数字是重点，单位用次要色小字。
public struct NumberWithUnit: View {
    @Environment(\.theme) private var theme
    let value: String
    let unit: String
    let role: TextRole

    public init(_ value: String, unit: String, role: TextRole = .headline) {
        self.value = value
        self.unit = unit
        self.role = role
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).themedFont(role).foregroundStyle(theme.colors.ink.color)
            Text(unit).themedFont(.subhead).foregroundStyle(theme.colors.inkMuted.color)
        }
    }
}

// MARK: - 媒体卡片（样式协议）

public struct MediaCardConfiguration {
    public var title: String
    public var code: String?
    public var subtitle: String?
    public var imageURL: URL?
    /// 0...1 的观看进度；nil 表示没看过。
    public var progress: Double?
    public var isPlayed: Bool
    public var badge: BadgeModel?
    public var isHovered: Bool
}

public protocol MediaCardStyle: Sendable {
    associatedtype Body: View
    @MainActor @ViewBuilder func makeBody(configuration: MediaCardConfiguration) -> Body
}

public struct AnyMediaCardStyle: Sendable {
    private let make: @MainActor @Sendable (MediaCardConfiguration) -> AnyView

    public init<S: MediaCardStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    @MainActor func makeBody(_ configuration: MediaCardConfiguration) -> AnyView { make(configuration) }
}

extension EnvironmentValues {
    @Entry public var mediaCardStyle = AnyMediaCardStyle(PosterTileStyle())
}

extension View {
    public func mediaCardStyle<S: MediaCardStyle>(_ style: S) -> some View {
        environment(\.mediaCardStyle, AnyMediaCardStyle(style))
    }
}

public struct MediaCard: View {
    @Environment(\.mediaCardStyle) private var style
    @State private var isHovered = false
    private var configuration: MediaCardConfiguration

    public init(title: String, code: String? = nil, subtitle: String? = nil, imageURL: URL?, progress: Double? = nil,
                isPlayed: Bool = false, badge: BadgeModel? = nil) {
        configuration = MediaCardConfiguration(title: title, code: code, subtitle: subtitle, imageURL: imageURL,
                                               progress: progress, isPlayed: isPlayed, badge: badge, isHovered: false)
    }

    public var body: some View {
        var config = configuration
        config.isHovered = isHovered
        return style.makeBody(config)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

/// 海报：竖版海报（圆角 10，无边框无阴影）+ 左对齐片名 + 浅色年份。
public struct PosterTileStyle: MediaCardStyle {
    public init() {}

    public func makeBody(configuration c: MediaCardConfiguration) -> some View {
        PosterTileBody(configuration: c)
    }
}

private struct PosterTileBody: View {
    @Environment(\.theme) private var theme
    let configuration: MediaCardConfiguration

    var body: some View {
        let c = configuration
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: c.imageURL, maxPixelSize: 450)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    if let badge = c.badge { Badge(badge).padding(6) }
                }
                .overlay(alignment: .topTrailing) {
                    if c.isPlayed {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(theme.colors.onButtonPrimary.color, theme.colors.buttonPrimary.color)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let p = c.progress, p > 0, !c.isPlayed {
                        ProgressCapsule(value: p, height: 3).padding(theme.metrics.space(2))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radiusMd, style: .continuous))
                .scaleEffect(c.isHovered ? 1.03 : 1)
                .animation(.easeOut(duration: 0.15), value: c.isHovered)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.colors.ink.color)
                if let subtitle = c.subtitle {
                    Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(RexChrome.inkTertiary.color)
                }
            }
            .lineLimit(1)
        }
    }
}

/// 横版卡片：剧照 16:9（radius-md）里压一条进度，下面是片名 + 集数 + 一行说明。用于「正在观看」。
public struct LandscapeTileStyle: MediaCardStyle {
    public init() {}

    public func makeBody(configuration c: MediaCardConfiguration) -> some View {
        LandscapeTileBody(configuration: c)
    }
}

private struct LandscapeTileBody: View {
    @Environment(\.theme) private var theme
    let configuration: MediaCardConfiguration

    var body: some View {
        let c = configuration
        VStack(alignment: .leading, spacing: theme.metrics.space(2)) {
            RemoteImage(url: c.imageURL, maxPixelSize: 640)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    if let p = c.progress, p > 0 {
                        ProgressCapsule(value: p).padding(.horizontal, theme.metrics.space(3)).padding(.bottom, theme.metrics.space(3))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radiusMd, style: .continuous))
                .scaleEffect(c.isHovered ? 1.02 : 1)
                .animation(.easeOut(duration: 0.15), value: c.isHovered)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(c.title).themedFont(.headline).foregroundStyle(theme.colors.ink.color)
                    if let code = c.code { Text(code).themedFont(.subhead).foregroundStyle(theme.colors.inkMuted.color) }
                }
                if let subtitle = c.subtitle {
                    Text(subtitle).themedFont(.subhead).foregroundStyle(theme.colors.inkMuted.color)
                }
            }
            .lineLimit(1)
        }
    }
}
