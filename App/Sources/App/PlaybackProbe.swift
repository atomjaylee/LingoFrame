#if DEBUG
import Foundation
import MediaServerKit
import PlaybackKit

/// 仅开发版：把资源库里的一批电影和剧集第一集逐个试播，记录每个片源的容器、编码和结果。
/// 用 -debugRoute playtest[:数量] 启动，结果写到临时目录的 playtest.txt。
@MainActor
enum PlaybackProbe {
    static func run(server: ServerConnection, limit: Int, resumeOnly: Bool = false, title: String? = nil) async {
        for _ in 0..<90 where server.catalog.isEmpty { try? await Task.sleep(for: .seconds(1)) }
        var targets: [EmbyItem] = []
        if let title {
            for match in server.catalog.filter({ $0.cardTitle.contains(title) }).prefix(limit) {
                if match.kind == .series, let first = try? await server.client.episodes(of: match.id, season: nil).first {
                    targets.append(first)
                } else if match.kind == .movie {
                    targets.append(match)
                }
            }
        } else if resumeOnly {
            targets = Array(((try? await server.client.resumeItems()) ?? []).prefix(limit))
        } else {
            targets = server.catalog.filter { $0.kind == .movie }.prefix(limit).map { $0 }
            for series in server.catalog.filter({ $0.kind == .series }).prefix(limit) {
                if let first = try? await server.client.episodes(of: series.id, season: nil).first { targets.append(first) }
            }
        }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("playtest.txt")
        var lines: [String] = []
        for item in targets {
            let session = PlaybackSession(client: server.client, serverID: server.id, engine: MPVPlayerEngine())
            let started = ContinuousClock.now
            await session.play(itemID: item.id, resume: resumeOnly)
            var result = "超时"
            for _ in 0..<50 {
                if let error = session.errorMessage { result = "失败(会话): \(error)"; break }
                if case .failed(let e) = session.engine.state { result = "失败(播放器): \(e)"; break }
                if session.engine.state == .playing { result = "成功"; break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            let playingAt = ContinuousClock.now
            if result == "成功", (session.subtitleNote?.contains("识别") == true || session.subtitleNote?.contains("读取") == true) {
                for _ in 0..<40 where session.primaryCues.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
            }
            let ocrWait = playingAt.duration(to: .now)
            let sample = session.primaryCues.first { $0.range.start.seconds >= session.engine.absoluteTime }?.text
                ?? session.primaryCues.last?.text ?? ""
            let position = String(format: "位置 %.0f", session.engine.absoluteTime)
            let source = session.stream?.mediaSource
            let video = source?.videoStream
            let audio = source?.audioStreams.first
            let videoParts: [String?] = [video?.codec, video?.profile, video?.videoRangeType, video?.bitDepth.map { "\($0)bit" }]
            let audioParts: [String?] = [audio?.codec, audio?.profile, audio?.channels.map { "\($0)ch" }]
            let fields: [String] = [
                result, "\(started.duration(to: .now))", item.cardTitle, source?.container ?? "-",
                videoParts.compactMap { $0 }.joined(separator: "/"),
                audioParts.compactMap { $0 }.joined(separator: "/"),
                session.playMode,
                "字幕 \(session.primaryCues.count)/\(session.secondaryCues.count) \(session.subtitleNote ?? "") 识别等待 \(ocrWait) 「\(sample.replacingOccurrences(of: "\n", with: " / ").prefix(60))」",
                position,
                session.engine.diagnostics().playbackType ?? "-",
                (source?.subtitleStreams ?? []).map { "\($0.codec ?? "?")/\($0.language ?? "?")\($0.isExternal == true ? "外" : "")\($0.isTextSubtitleStream == true ? "文" : "图")" }.joined(separator: ","),
            ]
            let line = fields.joined(separator: " | ")
            NSLog("playtest %@", line)
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            session.close()
        }
        NSLog("playtest done %@", out.path)
    }

    /// 快速连续切两集，验证较慢的旧请求不会覆盖最后一次点击。
    static func runSwitchTest(server: ServerConnection) async {
        guard let series = server.catalog.first(where: { $0.kind == .series }),
              let episodes = try? await server.client.episodes(of: series.id, season: nil), episodes.count >= 2 else {
            NSLog("switchtest 没有可用的两集")
            return
        }
        let engine = MPVPlayerEngine()
        let session = PlaybackSession(client: server.client, serverID: server.id, engine: engine)
        let first = Task { await session.play(itemID: episodes[0].id, resume: false) }
        try? await Task.sleep(for: .milliseconds(30))
        await session.play(itemID: episodes[1].id, resume: false)
        await first.value
        for _ in 0..<40 where engine.state != .playing { try? await Task.sleep(for: .milliseconds(250)) }
        NSLog("switchtest 目标=%@ 实际=%@ 状态=%@", episodes[1].id, session.item?.id ?? "-", "\(engine.state)")
        session.close()
    }
}
#endif
