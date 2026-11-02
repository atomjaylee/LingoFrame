import AppKit
import Testing
@testable import PlaybackNative

struct ASSSubtitleRendererTests {
    static let header = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360
    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Helvetica,36,&H0000FF00,&H0000FF00,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1
    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    """

    @Test func preservesPositionColorAndRepeatedReadOrder() throws {
        let renderer = try #require(ASSSubtitleRenderer(header: Self.header, fonts: []))
        renderer.add(event: "0,0,Default,,0,0,0,,{\\pos(80,60)}Original style", start: 0, end: 2)
        renderer.add(event: "0,0,Default,,0,0,0,,{\\pos(320,240)}Second line", start: 2, end: 4)
        let first = try #require(renderer.render(at: 1, size: CGSize(width: 640, height: 360)).image)
        #expect(first.position.minX > 0.1 && first.position.minX < 0.2)
        #expect(first.position.minY > 0.1 && first.position.minY < 0.3)
        let bitmap = NSBitmapImageRep(cgImage: first.cgImage)
        let colors = (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).compactMap { bitmap.colorAt(x: $0, y: y)?.usingColorSpace(.deviceRGB) }
        }
        #expect(colors.contains { $0.alphaComponent > 0.5 && $0.greenComponent > 0.7
            && $0.redComponent < 0.2 && $0.blueComponent < 0.2 })
        #expect(!renderer.render(at: 1, size: CGSize(width: 640, height: 360)).changed)
        let second = try #require(renderer.render(at: 3, size: CGSize(width: 640, height: 360)).image)
        #expect(second.position.minX > 0.45)
        #expect(second.position.minY > 0.6)
        #expect(renderer.render(at: 5, size: CGSize(width: 640, height: 360)).image == nil)
    }

    @Test func preservesMotionAndRelativePositionAfterResize() throws {
        let renderer = try #require(ASSSubtitleRenderer(header: Self.header, fonts: []))
        renderer.add(event: "0,0,Default,,0,0,0,,{\\move(40,60,340,60)}Moving", start: 0, end: 4)
        let first = try #require(renderer.render(at: 1, size: CGSize(width: 640, height: 360)).image)
        let later = try #require(renderer.render(at: 2, size: CGSize(width: 640, height: 360)).image)
        #expect(later.position.minX > first.position.minX + 0.1)
        let resized = try #require(renderer.render(at: 2, size: CGSize(width: 1280, height: 720)).image)
        #expect(abs(resized.position.minX - later.position.minX) < 0.01)
        #expect(abs(resized.position.minY - later.position.minY) < 0.01)
        #expect(resized.cgImage.width > later.cgImage.width * 18 / 10)
    }

    @Test func keepsSimultaneousLayers() throws {
        let renderer = try #require(ASSSubtitleRenderer(header: Self.header, fonts: []))
        renderer.add(event: "0,0,Default,,0,0,0,,{\\pos(80,60)}Original style", start: 0.1, end: 89.9)
        _ = renderer.render(at: 13, size: CGSize(width: 640, height: 360))
        renderer.add(event: "1,1,Default,,0,0,0,,{\\an5\\pos(320,180)\\c&H0088FF&}Second layer", start: 0.1, end: 89.9)
        let image = try #require(renderer.render(at: 13, size: CGSize(width: 640, height: 360)).image)
        #expect(image.position.height > 0.3)
        let bitmap = NSBitmapImageRep(cgImage: image.cgImage)
        let colors = (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).compactMap { bitmap.colorAt(x: $0, y: y)?.usingColorSpace(.deviceRGB) }
        }
        #expect(colors.contains { $0.alphaComponent > 0.5 && $0.greenComponent > 0.7 && $0.redComponent < 0.2 })
        #expect(colors.contains { $0.alphaComponent > 0.5 && $0.redComponent > 0.7 && $0.greenComponent > 0.2 && $0.blueComponent < 0.2 })
    }
}
