import Foundation
import Observation

/// 外观设置：深色、浅色、跟随系统三选一。颜色、字体、圆角都来自设计系统 Rex，不提供自定义。
@MainActor
@Observable
public final class ThemeStore {
    public var appearance: ThemeAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.key) }
    }

    private let defaults: UserDefaults
    private static let key = "theme.appearance"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Self.key).flatMap(ThemeAppearance.init(rawValue:)) ?? .dark
    }

    public var current: Theme { Theme.rex(appearance) }
}
