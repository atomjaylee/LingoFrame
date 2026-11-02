import AetherEngine
import CoreGraphics
import Foundation
import SwiftLibass

/// 用 libass 还原字幕原排版；按事件增量输入，未变化的画面不重复生成图片。
final class ASSSubtitleRenderer {
    private let library: OpaquePointer
    private let renderer: OpaquePointer
    private let track: UnsafeMutablePointer<ASS_Track>
    private var seen: Set<String> = []
    private var size: CGSize = .zero
    private var frameID = 0
    private var needsRedraw = true

    init?(header: String, fonts: [FontAttachment]) {
        guard let library = ass_library_init() else { return nil }
        guard let renderer = ass_renderer_init(library) else { ass_library_done(library); return nil }
        guard let track = ass_new_track(library) else {
            ass_renderer_done(renderer)
            ass_library_done(library)
            return nil
        }
        self.library = library
        self.renderer = renderer
        self.track = track
        for font in fonts {
            font.data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                ass_add_font(library, font.filename, base.assumingMemoryBound(to: CChar.self), Int32(bytes.count))
            }
        }
        ass_set_fonts(renderer, nil, "Helvetica", Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 1)
        var bytes = header.replacingOccurrences(of: "\0", with: "").utf8CString
        let count = Int32(bytes.count - 1)
        bytes.withUnsafeMutableBufferPointer { ass_process_codec_private(track, $0.baseAddress, count) }
    }

    deinit {
        ass_free_track(track)
        ass_renderer_done(renderer)
        ass_library_done(library)
    }

    func add(event: String, start: Double, end: Double) {
        guard start.isFinite, end.isFinite, end > start else { return }
        for line in event.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9, Int(fields[0]) != nil else { continue }
            guard seen.insert("\(start)|\(end)|\(line)").inserted else { continue }
            // 有些片源的每行 ReadOrder 都是 0，分配唯一序号，避免 libass 把后面的对白当成重复行。
            var bytes = ("\(seen.count)," + fields.dropFirst().joined(separator: ",")).utf8CString
            let count = Int32(bytes.count - 1)
            bytes.withUnsafeMutableBufferPointer {
                ass_process_chunk(track, $0.baseAddress, count, Int64((start * 1_000).rounded()),
                                  Int64((max(0, end - start) * 1_000).rounded()))
            }
        }
    }

    func render(at seconds: Double, size: CGSize) -> (changed: Bool, image: NativeSubtitleImage?) {
        guard size.width > 0, size.height > 0, seconds.isFinite else { return (false, nil) }
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        if self.size != size {
            self.size = size
            ass_set_frame_size(renderer, Int32(width), Int32(height))
            ass_set_storage_size(renderer, Int32(width), Int32(height))
            needsRedraw = true
        }
        var changed: Int32 = 0
        let first = ass_render_frame(renderer, track, Int64((seconds * 1_000).rounded()), &changed)
        guard changed != 0 || needsRedraw else { return (false, nil) }
        needsRedraw = false
        guard first != nil else { return (true, nil) }
        var bounds = CGRect.null
        var node = first
        while let pointer = node {
            let image = pointer.pointee
            node = image.next
            guard image.w > 0, image.h > 0 else { continue }
            bounds = bounds.union(CGRect(x: Int(image.dst_x), y: height - Int(image.dst_y + image.h),
                                         width: Int(image.w), height: Int(image.h)))
        }
        let cropped = bounds.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard !cropped.isNull, !cropped.isEmpty else { return (true, nil) }
        // 只合成有字幕的区域，不为每个动画帧分配整张视频大小的透明图片。
        guard let context = CGContext(data: nil, width: Int(cropped.width), height: Int(cropped.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (true, nil) }
        context.translateBy(x: -cropped.minX, y: -cropped.minY)
        node = first
        while let pointer = node {
            let image = pointer.pointee
            node = image.next
            guard image.w > 0, image.h > 0, let bitmap = image.bitmap else { continue }
            // libass 最后一行没有行尾填充，只读取实际分配的字节。
            let count = Int(image.stride * (image.h - 1) + image.w)
            let data = Data(bytes: bitmap, count: count)
            guard let provider = CGDataProvider(data: data as CFData),
                  let mask = CGImage(width: Int(image.w), height: Int(image.h), bitsPerComponent: 8,
                                     bitsPerPixel: 8, bytesPerRow: Int(image.stride),
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { continue }
            let rect = CGRect(x: Int(image.dst_x), y: height - Int(image.dst_y + image.h),
                              width: Int(image.w), height: Int(image.h))
            let color = image.color
            context.saveGState()
            context.clip(to: rect, mask: mask)
            context.setFillColor(red: CGFloat((color >> 24) & 255) / 255,
                                 green: CGFloat((color >> 16) & 255) / 255,
                                 blue: CGFloat((color >> 8) & 255) / 255,
                                 alpha: CGFloat(255 - (color & 255)) / 255)
            context.fill(rect)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return (true, nil) }
        frameID += 1
        let position = CGRect(x: cropped.minX / size.width, y: (CGFloat(height) - cropped.maxY) / size.height,
                              width: cropped.width / size.width, height: cropped.height / size.height)
        return (true, NativeSubtitleImage(id: frameID, cgImage: image, position: position, canvasSize: size))
    }
}
