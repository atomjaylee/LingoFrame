import AVFoundation
import CoreServices
import DesignSystem
import LearningCore
import MediaServerKit
import PlaybackKit
import SwiftUI

// 播放页的学习部分（设计稿「精听播放」）：画面上的双语字幕（单词可点查词）、查词卡片、右侧学习面板。

// MARK: - 字幕层

/// 画面底部的双语字幕：英文 30 号半粗、每个词都能点，中文 18 号在下面。
struct SubtitleOverlay: View {
    let session: PlaybackSession
    @Binding var lookup: WordLookup?

    var body: some View {
        let mode = session.subtitleMode
        let line = session.currentLine.flatMap { session.primaryCues.indices.contains($0) ? session.primaryCues[$0] : nil }
        if !session.usesNativePlaybackSubtitles {
            VStack(spacing: 8) {
                if mode != .off, let line {
                    FlowLayout(spacing: 7, lineSpacing: 4) {
                        ForEach(Array(Self.words(line.text).enumerated()), id: \.offset) { _, word in
                            SubtitleWord(word: word, isSelected: lookup?.word == Self.bare(word)) {
                                session.engine.pause()
                                lookup = WordLookup(word: Self.bare(word), sentence: line.text)
                            }
                        }
                    }
                    .font(.system(size: 28, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .blur(radius: mode == .blurPrimary ? 9 : 0)
                } else if mode != .off, let native = session.engine.currentSubtitleText {
                    Text(native)
                        .font(.system(size: 28, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .blur(radius: mode == .blurPrimary ? 9 : 0)
                }
                if mode == .bilingual, let zh = session.currentSecondary {
                    Text(zh)
                        .font(.system(size: 17, weight: .medium))
                        .multilineTextAlignment(.center)
                }
            }
            .shadow(color: .black.opacity(0.85), radius: 1.5, y: 1)
            .shadow(color: .black.opacity(0.45), radius: 7)
            .frame(maxWidth: .infinity)
            .animation(nil, value: session.currentLine)
        }
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 去掉词两端的标点，保留词中间的撇号和连字符（I'm、well-known）。
    static func bare(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).trimmingCharacters(in: CharacterSet(charactersIn: "‘’“”"))
    }
}

/// 光盘位图字幕（PGS / DVB / DVD）按视频内容区域定位，不受控制条和窗口尺寸影响。
struct BitmapSubtitleOverlay: View {
    let engine: NativePlayerEngine

    var body: some View {
        GeometryReader { proxy in
            let videoRect = fittedVideoRect(container: proxy.size, video: engine.presentationSize)
            ForEach(engine.currentSubtitleImages) { subtitle in
                let frame = subtitle.frame(in: videoRect)
                Image(decorative: subtitle.cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
    }

    private func fittedVideoRect(container: CGSize, video: CGSize) -> CGRect {
        guard video.width > 0, video.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / video.width, container.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

private struct SubtitleWord: View {
    let word: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Text(word)
            .foregroundStyle(isSelected ? .black : .white)
            .padding(.horizontal, isSelected ? 8 : 1)
            .background {
                if isSelected { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white) }
                else if isHovered { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.18)) }
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture(perform: action)
    }
}

/// 从左到右排、放不下就换行、每行居中的布局，用来排可点击的字幕单词。
struct FlowLayout: Layout {
    var spacing: Double = 6
    var lineSpacing: Double = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * Double(max(rows.count - 1, 0))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: Double = 0; var height: Double = 0 }

    private func rows(width: Double, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - 查词

struct WordLookup: Equatable {
    let word: String
    let sentence: String
}

/// 查词卡片：单词、朗读、系统词典里的释义，以及这句原文。
struct LookupCard: View {
    let lookup: WordLookup
    let close: () -> Void
    @State private var definition: String?
    @State private var speaker = AVSpeechSynthesizer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(lookup.word).font(.system(size: 20, weight: .semibold))
                Spacer()
                Button {
                    let utterance = AVSpeechUtterance(string: lookup.word)
                    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                    speaker.speak(utterance)
                } label: { Image(systemName: "speaker.wave.2.fill") }
                    .buttonStyle(RexIconButtonStyle(diameter: 36))
                    .accessibilityLabel("朗读")
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(RexIconButtonStyle(diameter: 36))
                    .accessibilityLabel("关闭并继续播放")
            }
            Group {
                if let definition {
                    Text(definition).font(.system(size: 14)).lineLimit(8).textSelection(.enabled)
                } else {
                    Text("系统词典里没有找到这个词").font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(lookup.sentence)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button("继续播放", action: close).buttonStyle(RexChipStyle(isSelected: true))
        }
        .padding(16)
        .frame(width: 360)
        .background(Color(red: 0.27, green: 0.31, blue: 0.34).opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
        .onTapGesture {}
        .task(id: lookup.word) { definition = Self.systemDefinition(lookup.word) }
    }

    /// macOS 自带词典的释义（用户在「词典」App 里启用的那些，比如英汉词典）。
    static func systemDefinition(_ word: String) -> String? {
        guard !word.isEmpty else { return nil }
        let range = CFRange(location: 0, length: (word as NSString).length)
        guard let text = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String? else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 学习面板

/// 右侧字幕栏：整集字幕（点一句就跳过去）、分集、信息；底部是逐句、循环、暂停、字幕显示这些英语学习控制。
struct LearningPanel: View {
    let session: PlaybackSession
    let hide: () -> Void
    @State private var tab = Tab.transcript

    enum Tab: String, CaseIterable { case transcript = "字幕", episodes = "分集", info = "信息" }

    private var tabs: [Tab] { session.siblings.isEmpty ? [.transcript, .info] : Tab.allCases }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(tab.rawValue).font(.system(size: 15, weight: .semibold))
                if tab == .transcript, !session.primaryCues.isEmpty {
                    Text(session.currentLine.map { "\($0 + 1) / \(session.primaryCues.count)" } ?? "共 \(session.primaryCues.count) 句")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: hide) { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("关闭面板")
            }
            .padding(.horizontal, 8)
            Picker("面板", selection: $tab) {
                ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            switch tab {
            case .transcript: TranscriptList(session: session)
            case .episodes: EpisodeList(session: session)
            case .info: PlaybackInfoList(session: session)
            }
            StudyControls(session: session)
        }
        .padding(.top, 12)
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(white: 0.08).opacity(0.96))
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.1)).frame(width: 1) }
    }
}

/// 字幕栏底部的学习控制。播放栏只管视频播放，逐句和循环都在这里。
private struct StudyControls: View {
    @Bindable var session: PlaybackSession

    var body: some View {
        let hasLines = !session.primaryCues.isEmpty
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                step("backward.end.fill", "上一句", prominent: false) { session.previousSentence() }
                step("arrow.counterclockwise", "重播本句", prominent: true) { session.replaySentence() }
                step("forward.end.fill", "下一句", prominent: false) { session.nextSentence() }
            }
            .disabled(!hasLines)
            row("单句循环") {
                Picker("单句循环", selection: $session.loopMode) {
                    ForEach(LoopMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                .disabled(!hasLines)
            }
            row("每句后暂停") {
                Toggle("每句后暂停", isOn: $session.pauseAfterSentence)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(!hasLines || session.loopEnabled)
            }
            row("字幕显示") {
                Picker("字幕显示", selection: $session.subtitleMode) {
                    ForEach(SubtitleMode.allCases) { Text($0.short).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            }
            if !session.subtitleOptions.isEmpty {
                HStack(spacing: 8) { SubtitleTrackMenus(session: session) }
                    .menuStyle(.button).controlSize(.small).fixedSize()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }

    private func step(_ icon: String, _ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(.white.opacity(prominent ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            content()
        }
    }
}

private struct TranscriptList: View {
    let session: PlaybackSession

    var body: some View {
        if session.primaryCues.isEmpty {
            ContentUnavailableView(session.subtitleNote ?? "正在读取字幕", systemImage: "captions.bubble")
                .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(session.primaryCues.enumerated()), id: \.offset) { i, cue in
                            row(i, cue).id(i)
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: session.currentLine) { _, line in
                    guard let line else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(line, anchor: .center) }
                }
                .onAppear { if let line = session.currentLine { proxy.scrollTo(line, anchor: .center) } }
            }
        }
    }

    private func row(_ i: Int, _ cue: SubtitleCue) -> some View {
        let current = session.currentLine
        let state: Int = current.map { i < $0 ? -1 : i == $0 ? 0 : 1 } ?? 1
        let zh = session.subtitleMode == .bilingual ? session.secondaryCues.first { $0.range.overlaps(cue.range) }?.text : nil
        return Button { session.jump(toLine: i) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(TimeFormat.clock(cue.range.start.seconds)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    if state == 0, session.loopEnabled {
                        Text(session.loopMode == .forever ? "循环中" : "循环 \(session.loopPass)/\(session.loopTimes)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(red: 1, green: 0.68, blue: 0.03))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Text(cue.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 13, weight: state == 0 ? .bold : .medium))
                    .foregroundStyle(state < 0 ? .secondary : .primary)
                if let zh {
                    Text(zh.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(state == 0 ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct EpisodeList: View {
    let session: PlaybackSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(session.siblings) { ep in
                        let isCurrent = ep.id == session.item?.id
                        Button {
                            if !isCurrent { Task { await session.play(itemID: ep.id, resume: true) } }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isCurrent ? "speaker.wave.2.fill" : (ep.isPlayed ? "checkmark.circle" : "circle"))
                                    .foregroundStyle(isCurrent ? Color(red: 1, green: 0.68, blue: 0.03) : .secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(ep.episodeCode ?? "").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                    Text(ep.displayName).font(.system(size: 14, weight: isCurrent ? .semibold : .regular)).lineLimit(2)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(isCurrent ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(ep.id)
                    }
                }
            }
            .scrollIndicators(.never)
            .onAppear { proxy.scrollTo(session.item?.id, anchor: .center) }
        }
    }
}

private struct PlaybackInfoList: View {
    let session: PlaybackSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                group("字幕") {
                    if let note = session.subtitleNote { Text(note).foregroundStyle(.secondary) }
                    if !session.subtitleOptions.isEmpty {
                        SubtitleTrackMenus(session: session).menuStyle(.button).fixedSize()
                        row("主字幕句数", "\(session.primaryCues.count)")
                    }
                }
                group("播放") {
                    row("播放方式", session.playMode.isEmpty ? "-" : session.playMode)
                    if let source = session.stream?.mediaSource {
                        row("容器", source.container?.uppercased() ?? "-")
                        if let v = source.videoStream { row("视频", v.displayTitle ?? v.codec ?? "-") }
                        if let a = PlaybackSession.defaultAudio(of: source) { row("音频", a.displayTitle ?? a.codec ?? "-") }
                    }
                    if let d = session.engine.videoDescription { row("解码", d) }
                    if let subtitle = session.engine.nativeSubtitleDescription { row("播放器字幕", subtitle) }
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.never)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .bold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
