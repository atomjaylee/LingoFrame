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
            .hoverTransition(value: isHovered)
            .onTapGesture(perform: action)
            .clickablePointer()
    }
}

/// 从左到右排、放不下就换行、每行居中的布局，用来排可点击的字幕单词。
struct FlowLayout: Layout {
    var spacing: Double = 6
    var lineSpacing: Double = 4
    var alignment: HorizontalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * Double(max(rows.count - 1, 0))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (alignment == .leading ? 0 : (bounds.width - row.width) / 2)
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

/// 字幕学习窗口：前后文跟随播放，当前句单独精听，常用操作固定在底部。
struct LearningPanel: View {
    @Bindable var session: PlaybackSession
    let hide: () -> Void
    @State private var tab = Tab.transcript

    enum Tab: String { case transcript, episodes }

    private var currentLine: Int? {
        session.currentLine
            ?? session.primaryCues.lastIndex { $0.range.start.seconds <= session.engine.absoluteTime }
            ?? session.primaryCues.indices.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            if tab == .transcript {
                VStack(alignment: .leading, spacing: 6) {
                    Text("前后文")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                    TranscriptList(session: session, currentLine: currentLine)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 270, maxHeight: .infinity)

                if let currentLine, session.primaryCues.indices.contains(currentLine) {
                    CurrentSentence(session: session, line: currentLine, cue: session.primaryCues[currentLine])
                }
                StudyControls(session: session)
            } else {
                EpisodeList(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .background(Color(white: 0.075).opacity(0.97))
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("字幕与学习").font(.system(size: 16, weight: .semibold))
                if let currentLine {
                    Text("\(currentLine + 1) / \(session.primaryCues.count)")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, minHeight: 26)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents()
            Button(action: hide) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).clickablePointer()
            .foregroundStyle(.secondary)
            .accessibilityLabel("关闭面板")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if tab == .episodes {
                Button { tab = .transcript } label: { Label("返回字幕", systemImage: "chevron.left") }
                    .buttonStyle(.plain).clickablePointer()
                Spacer()
            } else {
                Picker("画面字幕", selection: $session.subtitleMode) {
                    Text("英文").tag(SubtitleMode.primaryOnly)
                    Text("双语").tag(SubtitleMode.bilingual)
                    Text("遮挡").tag(SubtitleMode.blurPrimary)
                    Text("隐藏").tag(SubtitleMode.off)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("切换播放画面的字幕显示方式")
            }
            Menu {
                if !session.siblings.isEmpty {
                    Button("分集") { tab = .episodes }
                    Divider()
                }
                Menu("主字幕") {
                    ForEach(session.subtitleOptions) { option in
                        Button { session.selectPrimarySubtitle(option) } label: {
                            if option == session.primarySubtitle { Label(option.title, systemImage: "checkmark") }
                            else { Text(option.title) }
                        }
                    }
                }
                Menu("副字幕") {
                    Button { session.selectSecondarySubtitle(nil) } label: {
                        if session.secondarySubtitle == nil { Label("无", systemImage: "checkmark") }
                        else { Text("无") }
                    }
                    Divider()
                    ForEach(session.subtitleOptions) { option in
                        Button { session.selectSecondarySubtitle(option) } label: {
                            if option == session.secondarySubtitle { Label(option.title, systemImage: "checkmark") }
                            else { Text(option.title) }
                        }
                    }
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).clickablePointer().menuIndicator(.hidden)
            .accessibilityLabel("字幕设置与分集")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

/// 当前句保留大字，译文开关与时间同行，避免挤占前后文和复听按钮。
private struct CurrentSentence: View {
    let session: PlaybackSession
    let line: Int
    let cue: SubtitleCue
    @State private var translationOverride: Bool?
    @State private var lookup: WordLookup?
    @State private var showsLookup = false
    @State private var resumeAfterLookup = false

    private var translation: String? {
        session.secondaryCues.first { $0.range.overlaps(cue.range) }?.text
    }
    private var showsTranslation: Bool { translationOverride ?? (session.subtitleMode == .bilingual) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("当前句").font(.system(size: 13, weight: .medium))
                Text(TimeFormat.clock(cue.range.start.seconds))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                Spacer(minLength: 8)
                Button { translationOverride = !showsTranslation } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showsTranslation ? "eye.slash" : "eye")
                        Text(showsTranslation ? "隐藏中文" : "显示中文")
                        Text("T").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.1)))
                }
                .buttonStyle(.plain).clickablePointer()
                .keyboardShortcut("t", modifiers: [])
                .disabled(translation == nil)
                .help(translation == nil ? "请在字幕设置中选择中文字幕轨" : "只显示或隐藏当前句的中文")
            }
            .foregroundStyle(.secondary)

            ScrollView {
                FlowLayout(spacing: 6, lineSpacing: 4, alignment: .leading) {
                    ForEach(Array(SubtitleOverlay.words(cue.text).enumerated()), id: \.offset) { _, word in
                        SubtitleWord(word: word, isSelected: lookup?.word == SubtitleOverlay.bare(word)) {
                            resumeAfterLookup = session.engine.state == .playing
                            session.engine.pause()
                            lookup = WordLookup(word: SubtitleOverlay.bare(word), sentence: cue.text)
                            showsLookup = true
                        }
                    }
                }
                .font(.system(size: 27, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsTranslation, let translation {
                    Text(translation.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
            .scrollIndicators(.never)
            .frame(height: showsTranslation && translation != nil ? 112 : 78)
            .popover(isPresented: $showsLookup) {
                if let lookup {
                    LookupCard(lookup: lookup) { showsLookup = false }
                        .environment(\.colorScheme, .dark)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1).padding(.horizontal, 18) }
        .onChange(of: line) { _, _ in translationOverride = nil }
        .onChange(of: session.subtitleMode) { _, _ in translationOverride = nil }
        .onChange(of: showsLookup) { _, shown in
            if !shown {
                lookup = nil
                if resumeAfterLookup { session.engine.play() }
            }
        }
    }
}

/// 复听、逐句跳转和播放设置保持紧凑，给字幕阅读留出空间。
private struct StudyControls: View {
    @Bindable var session: PlaybackSession

    var body: some View {
        let hasLines = !session.primaryCues.isEmpty
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                step("backward.end.fill", "上一句", prominent: false) { session.previousSentence() }
                step("arrow.counterclockwise", "重播本句", prominent: true) { session.replaySentence() }
                step("forward.end.fill", "下一句", prominent: false) { session.nextSentence() }
            }
            .disabled(!hasLines)
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1).padding(.vertical, 2)
            row("循环次数") {
                Picker("循环次数", selection: $session.loopMode) {
                    ForEach(LoopMode.allCases) { mode in
                        Text(mode == .forever ? "∞" : mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                .disabled(!hasLines)
            }
            row("播放速度") {
                Menu {
                    ForEach(PlaybackSession.rateSteps, id: \.self) { rate in
                        Button { session.setRate(rate) } label: {
                            let title = String(format: "%g×", rate)
                            if abs(session.engine.rate - rate) < 0.001 { Label(title, systemImage: "checkmark") }
                            else { Text(title) }
                        }
                    }
                } label: {
                    Text(String(format: "%g×", session.engine.rate)).monospacedDigit().frame(minWidth: 66)
                }
                .menuStyle(.borderlessButton).fixedSize().clickablePointer()
            }
            row("句末暂停") {
                Toggle("句末暂停", isOn: $session.pauseAfterSentence)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .tint(Color(red: 1, green: 0.68, blue: 0.03))
                    .disabled(!hasLines || session.loopEnabled)
                Text(session.loopEnabled ? "循环时自动接续" : "听完这一句，再继续")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private func step(_ icon: String, _ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .foregroundStyle(prominent ? Color.black : .white)
            .background(prominent ? Color.white : .white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickablePointer()
        .help(title == "重播本句" ? "重播本句（R）" : title)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            content()
        }
        .frame(minHeight: 22)
    }
}

private struct TranscriptList: View {
    let session: PlaybackSession
    let currentLine: Int?

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
            GeometryReader { geometry in
                let rowHeight = max(36, (geometry.size.height - 8) / 7)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(session.primaryCues.enumerated()), id: \.offset) { i, cue in
                                row(i, cue).frame(height: rowHeight).id(i)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: currentLine, initial: true) { _, line in
                        guard let line else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(line, anchor: .center) }
                    }
                    .onChange(of: geometry.size.height) { _, _ in
                        if let currentLine { proxy.scrollTo(currentLine, anchor: .center) }
                    }
                }
            }
        }
    }

    private func row(_ i: Int, _ cue: SubtitleCue) -> some View {
        let isCurrent = i == currentLine
        let amber = Color(red: 1, green: 0.68, blue: 0.03)
        return Button { session.jump(toLine: i) } label: {
            HStack(alignment: .center, spacing: 12) {
                Text(TimeFormat.clock(cue.range.start.seconds))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(isCurrent ? amber : Color.secondary)
                    .frame(width: 43, alignment: .leading)
                Text(cue.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.white : .white.opacity(0.64))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if isCurrent { Capsule().fill(amber).frame(width: 3).padding(.vertical, 4) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickablePointer()
    }
}

/// 分集列表共用每集自己的剧照，并在图上保留播放状态和进度。
struct EpisodeArtwork: View {
    let episode: EmbyItem
    let client: EmbyClient?
    let isCurrent: Bool

    var body: some View {
        let url = client?.imageURL(for: episode, type: .primary, maxWidth: 320)
        RemoteImage(url: url, maxPixelSize: 320)
            .frame(width: 112, height: 63)
            .overlay {
                if url == nil {
                    Image(systemName: "film").font(.system(size: 20)).foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isCurrent || episode.isPlayed {
                    Image(systemName: isCurrent ? "speaker.wave.2.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isCurrent ? Color(red: 1, green: 0.68, blue: 0.03) : .white)
                        .padding(5)
                        .background(.black.opacity(0.65), in: Circle())
                        .padding(4)
                }
            }
            .overlay(alignment: .bottom) {
                if let progress = episode.progress, progress > 0, !episode.isPlayed {
                    ProgressCapsule(value: progress, height: 2).padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
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
                                EpisodeArtwork(episode: ep, client: session.client, isCurrent: isCurrent)
                                VStack(alignment: .leading, spacing: 4) {
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
                        .buttonStyle(.plain).clickablePointer()
                        .id(ep.id)
                    }
                }
            }
            .scrollIndicators(.never)
            .onAppear { proxy.scrollTo(session.item?.id, anchor: .center) }
        }
    }
}
