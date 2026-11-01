import Foundation

/// 文本字幕解析。Emby 能把内嵌和外挂的文本字幕（SRT、ASS、SSA、VTT）统一转成 SRT 输出，这里只需要解析 SRT 和 VTT。
public enum SubtitleParser {
    /// 解析 SRT 或 WebVTT 文本。去掉 HTML 标签和 ASS 样式代码，合并多行，跳过空字幕，按开始时间排序。
    public static func parse(_ text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let range = parseTiming(lines[timingIndex]) else { continue }
            let body = lines[(timingIndex + 1)...].map(clean).filter { !$0.isEmpty }.joined(separator: "\n")
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(range: range, text: body))
        }
        return cues.sorted { $0.range.start < $1.range.start }
    }

    /// 「00:01:02,345 --> 00:01:04,000」或 VTT 的「01:02.345 --> 01:04.000 align:start」。
    static func parseTiming(_ line: String) -> TimeRange? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = parseTime(parts[0]),
              let end = parseTime(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
        else { return nil }
        return TimeRange(startMs: start, endMs: end)
    }

    static func parseTime(_ raw: String) -> Int64? {
        let value = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let fields = value.split(separator: ":")
        guard (2...3).contains(fields.count), let last = fields.last else { return nil }
        let seconds = Double(last) ?? -1
        let minutes = Int64(fields[fields.count - 2]) ?? -1
        let hours = fields.count == 3 ? Int64(fields[0]) ?? -1 : 0
        guard seconds >= 0, minutes >= 0, hours >= 0 else { return nil }
        return (hours * 3600 + minutes * 60) * 1000 + Int64((seconds * 1000).rounded())
    }

    private static let htmlTagPattern = /<[^>]+>/
    private static let assOverridePattern = /\{[^}]*\}/

    /// 去掉 <i>、<font> 等标签和 {\an8} 这类 ASS 覆盖代码，把 \N 换成换行。
    static func clean(_ line: String) -> String {
        var s = line.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
        s.replace(htmlTagPattern, with: "")
        s.replace(assOverridePattern, with: "")
        s = s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        return s.trimmingCharacters(in: .whitespaces)
    }
}

extension Array where Element == SubtitleCue {
    /// 时间点所在的字幕，二分查找。重叠时取开始最晚的一条。
    public func cue(at time: MediaTime) -> SubtitleCue? {
        index(at: time).map { self[$0] }
    }

    public func index(at time: MediaTime) -> Int? {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid].range.start <= time { low = mid + 1 } else { high = mid }
        }
        var i = low - 1
        while i >= 0 {
            if self[i].range.contains(time) { return i }
            if time.ms - self[i].range.start.ms > 30_000 { break }
            i -= 1
        }
        return nil
    }

    /// 开始时间不晚于 time 的最后一条字幕（两句之间的空档里指向刚播完的上一句），二分查找。
    public func latestIndex(atOrBefore time: MediaTime) -> Int? {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid].range.start <= time { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }
}
