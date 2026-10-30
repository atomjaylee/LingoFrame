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

/// 字幕学习窗口：顶部显示学习状态，中间浏览字幕或分集，底部集中放逐句学习工具。
struct LearningPanel: View {
    let session: PlaybackSession
    let hide: () -> Void
    @State private var tab = Tab.transcript

    enum Tab: String, CaseIterable { case transcript = "字幕", episodes = "分集" }

    private var tabs: [Tab] { session.siblings.isEmpty ? [.transcript] : Tab.allCases }

    var body: some View {
        VStack(spacing: 0) {
            header
            if tabs.count > 1 {
                HStack(spacing: 4) {
                    ForEach(tabs, id: \.self) { item in
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { tab = item }
                        } label: {
                            Text(item.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(item == tab ? .white.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            Group {
                switch tab {
                case .transcript: TranscriptList(session: session)
                case .episodes: EpisodeList(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if tab == .transcript {
                StudyControls(session: session)
            }
        }
        .background(Color(white: 0.075).opacity(0.97))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.68, blue: 0.03))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("字幕与学习").font(.system(size: 14, weight: .semibold))
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: hide) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.07), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("关闭面板")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }

    private var statusText: String {
        guard !session.primaryCues.isEmpty else { return session.subtitleNote ?? "正在准备字幕" }
        return session.currentLine.map { "第 \($0 + 1) 句，共 \(session.primaryCues.count) 句" }
            ?? "共 \(session.primaryCues.count) 句"
    }
}

/// 独立于播放栏的学习工具，只保留精听真正需要的控制。
private struct StudyControls: View {
    @Bindable var session: PlaybackSession

    var body: some View {
        let hasLines = !session.primaryCues.isEmpty
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("学习工具").font(.system(size: 12, weight: .semibold))
                Spacer()
                if !hasLines {
                    Text("等待文本字幕").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                step("backward.end.fill", "上一句", prominent: false) { session.previousSentence() }
                step("arrow.counterclockwise", "重播本句", prominent: true) { session.replaySentence() }
                step("forward.end.fill", "下一句", prominent: false) { session.nextSentence() }
            }
            .disabled(!hasLines)

            HStack(spacing: 8) {
                Menu {
                    ForEach(LoopMode.allCases) { mode in
                        Button {
                            session.loopMode = mode
                        } label: {
                            if session.loopMode == mode { Label(mode.rawValue, systemImage: "checkmark") }
                            else { Text(mode.rawValue) }
                        }
                    }
                } label: {
                    settingChip("repeat", "循环", session.loopMode.rawValue, isOn: session.loopEnabled)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .disabled(!hasLines)

                Button { session.pauseAfterSentence.toggle() } label: {
                    settingChip("pause.circle", "句末暂停", session.pauseAfterSentence ? "开" : "关",
                                isOn: session.pauseAfterSentence)
                }
                .buttonStyle(.plain)
                    .disabled(!hasLines || session.loopEnabled)

                Menu {
                    ForEach(SubtitleMode.allCases) { mode in
                        Button {
                            session.subtitleMode = mode
                        } label: {
                            if session.subtitleMode == mode { Label(mode.short, systemImage: "checkmark") }
                            else { Text(mode.short) }
                        }
                    }
                } label: {
                    settingChip("captions.bubble", "画面字幕", session.subtitleMode.short,
                                isOn: session.subtitleMode != .off)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            }

            if !session.subtitleOptions.isEmpty {
                HStack(spacing: 8) {
                    primarySubtitleMenu
                    secondarySubtitleMenu
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.035))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }

    private func step(_ icon: String, _ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(prominent ? Color(red: 1, green: 0.68, blue: 0.03).opacity(0.2) : .white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(prominent ? 0.14 : 0.06), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingChip(_ icon: String, _ title: String, _ value: String, isOn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .font(.system(size: 10, weight: .medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .frame(height: 42)
        .background(.white.opacity(isOn ? 0.1 : 0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }

    private var primarySubtitleMenu: some View {
        Menu {
            ForEach(session.subtitleOptions) { option in
                Button {
                    session.selectPrimarySubtitle(option)
                } label: {
                    if option == session.primarySubtitle { Label(option.title, systemImage: "checkmark") }
                    else { Text(option.title) }
                }
            }
        } label: {
            subtitleChip("主字幕", session.primarySubtitle?.title ?? "未选择")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }

    private var secondarySubtitleMenu: some View {
        Menu {
            Button {
                session.selectSecondarySubtitle(nil)
            } label: {
                if session.secondarySubtitle == nil { Label("无", systemImage: "checkmark") }
                else { Text("无") }
            }
            Divider()
            ForEach(session.subtitleOptions) { option in
                Button {
                    session.selectSecondarySubtitle(option)
                } label: {
                    if option == session.secondarySubtitle { Label(option.title, systemImage: "checkmark") }
                    else { Text(option.title) }
                }
            }
        } label: {
            subtitleChip("副字幕", session.secondarySubtitle?.title ?? "无")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }

    private func subtitleChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct TranscriptList: View {
    let session: PlaybackSession

    var body: some View {
        if session.primaryCues.isEmpty {
            VStack(spacing: 10) {
                if session.subtitleNote?.contains("正在") == true {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.secondary)
                }
                Text("暂无可学习的文本字幕")
                    .font(.system(size: 14, weight: .semibold))
                Text(session.subtitleNote ?? "正在读取字幕")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 230)
            }
                .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(session.primaryCues.enumerated()), id: \.offset) { i, cue in
                            row(i, cue).id(i)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
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
            HStack(alignment: .top, spacing: 9) {
                Text(TimeFormat.clock(cue.range.start.seconds))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(state == 0 ? Color(red: 1, green: 0.68, blue: 0.03) : .secondary)
                    .frame(width: 42, alignment: .leading)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(cue.text.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 13, weight: state == 0 ? .semibold : .regular))
                            .foregroundStyle(state < 0 ? .secondary : .primary)
                        if state == 0, session.loopEnabled {
                            Text(session.loopMode == .forever ? "循环" : "\(session.loopPass)/\(session.loopTimes)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color(red: 1, green: 0.68, blue: 0.03))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.white.opacity(0.08), in: Capsule())
                        }
                    }
                    if let zh {
                        Text(zh.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(state == 0 ? Color.white.opacity(0.09) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) {
                if state == 0 {
                    Capsule().fill(Color(red: 1, green: 0.68, blue: 0.03)).frame(width: 3).padding(.vertical, 8)
                }
            }
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
