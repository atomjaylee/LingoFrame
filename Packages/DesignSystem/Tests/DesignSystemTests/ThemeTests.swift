import AppKit
import Foundation
import Testing
@testable import DesignSystem

@Test func parsesHexRgbaAndSystemColors() throws {
    let c = try #require(ColorToken.parse("#FF000080").usingColorSpace(.sRGB))
    #expect(abs(c.redComponent - 1) < 0.01 && abs(c.alphaComponent - 0.5) < 0.01)
    let glass = try #require(ColorToken.parse("rgba(255,255,255,0.12)").usingColorSpace(.sRGB))
    #expect(abs(glass.redComponent - 1) < 0.01 && abs(glass.alphaComponent - 0.12) < 0.01)
    #expect(ColorToken.parse("system:controlAccentColor") == .controlAccentColor)
    #expect(ColorToken.parse("bad") == .magenta)
}

@Test func rexTokensMatchTheDesignSystem() {
    let t = Theme.standard
    #expect(t.appearance == .dark)
    #expect(t.colors.bgBase == ColorToken(light: "#e6e3f2", dark: "#2e2b3c"))
    #expect(t.colors.accentViolet == ColorToken("#5e4cff"))
    #expect(t.metrics.space(4) == 16 && t.metrics.space(6) == 24)
    #expect(t.typography.mediaTitle.weight == 300 && t.typography.statHero.size == 44)
    #expect(Theme.rex(.light).colors == t.colors)
}

@Test func pageTintIsDarkAndKeepsHue() throws {
    let warm = ArtworkColor(red: 0.8, green: 0.5, blue: 0.2)
    let tint = try #require(NSColor(warm.pageTint(dark: true)).usingColorSpace(.sRGB))
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    tint.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    #expect(b <= 0.31)
    #expect(h > 0.05 && h < 0.12)
}

@MainActor
@Test func storeRemembersAppearance() throws {
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let store = ThemeStore(defaults: defaults)
    #expect(store.appearance == .dark)
    store.appearance = .system
    #expect(store.current.colorScheme == nil)
    #expect(ThemeStore(defaults: defaults).appearance == .system)
}
