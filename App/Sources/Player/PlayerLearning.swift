import AVFoundation
import CoreServices
import DesignSystem
import LearningCore
import MediaServerKit
import PlaybackKit
import SwiftUI
import Translation

// 视频保留原字幕；双语、查词和逐句精听由独立学习面板提供。

// MARK: - 字幕层

/// 视频只显示内核当前选中的原字幕，不读取学习窗口的识别和翻译结果。
struct PlaybackSubtitleOverlay: View {
    let engine: NativePlayerEngine

    var body: some View {
        if let text = engine.currentSubtitleText {
            Text(text)
                .font(.system(size: 28, weight: .semibold))
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.85), radius: 1.5, y: 1)
                .shadow(color: .black.opacity(0.45), radius: 7)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
    }
}

private enum SubtitleText {
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
    let color: Color
    @Binding var lookup: WordLookup?
    let identity: WordLookup
    let action: () -> Void
    @State private var isHovered = false

    private var isSelected: Bool { lookup == identity }

    var body: some View {
        Text(word)
            .foregroundStyle(isSelected ? .black : color)
            .padding(.horizontal, 1)
            .background {
                if isSelected { RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white) }
                else if isHovered { RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.18)) }
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .hoverTransition(value: isHovered)
            .onTapGesture(perform: action)
            .clickablePointer()
            .popover(isPresented: Binding(get: { isSelected }, set: { if !$0 { lookup = nil } })) {
                LookupCard(lookup: identity) { lookup = nil }
                    .environment(\.colorScheme, .dark)
            }
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
    let line: Int
    let index: Int
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

/// 字幕学习窗口：布局对应设计稿 Player 画板的字幕栏，字幕列表跟随播放，常用操作固定在底部。
struct LearningPanel: View {
    @Bindable var session: PlaybackSession
    let hide: () -> Void

    private var currentLine: Int? {
        session.activeLine ?? session.primaryCues.indices.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if session.subtitleMode == .bilingual, let note = session.translationNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            if session.subtitleMode == .off {
                ContentUnavailableView("学习字幕已隐藏", systemImage: "captions.bubble")
                    .frame(maxWidth: .infinity, minHeight: 270, maxHeight: .infinity)
            } else {
                TranscriptList(session: session, currentLine: currentLine)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 270, maxHeight: .infinity)
            }
            StudyControls(session: session)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .background(Color(white: 0.075).opacity(0.97))
        .background(.ultraThinMaterial)
        .modifier(SubtitleTranslation(session: session))
        .onAppear { session.setLearningPanelVisible(true) }
        .onDisappear { session.setLearningPanelVisible(false) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("字幕").font(.system(size: 15, weight: .semibold))
                if let currentLine {
                    Text("第 \(currentLine + 1) 句 / 共 \(session.primaryCues.count) 句")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, minHeight: 26)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents()
            subtitleMenu
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
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var subtitleMenu: some View {
        Menu {
            Menu("主字幕") {
                ForEach(session.subtitleOptions) { option in
                    Button { session.selectPrimarySubtitle(option) } label: {
                        if option == session.learningPrimarySubtitle { Label(option.title, systemImage: "checkmark") }
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
                .font(.system(size: 14))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).clickablePointer().menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .accessibilityLabel("字幕设置")
    }
}

/// 翻译会话只存在于学习窗口中，窗口关闭后系统任务随视图取消。
struct SubtitleTranslation: ViewModifier {
    let session: PlaybackSession
    @State private var configuration: TranslationSession.Configuration?
    @State private var nextConfiguration = TranslationSession.Configuration(source: Locale.Language(identifier: "en"),
                                                                           target: Locale.Language(identifier: "zh-Hans"))

    func body(content: Content) -> some View {
        content
            .onChange(of: session.systemTranslationID, initial: true) { _, id in
                if id == nil { configuration = nil }
                else {
                    nextConfiguration.invalidate()
                    configuration = nextConfiguration
                }
            }
            .translationTask(configuration) { translator in
                await session.translateSubtitles(using: translator)
            }
    }
}

/// 逐句跳转和学习设置固定在面板底部，给字幕阅读留出空间。
private struct StudyControls: View {
    @Bindable var session: PlaybackSession

    private static let segmentWidth: Double = 190

    var body: some View {
        let hasLines = !session.primaryCues.isEmpty
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geometry in
                // 三个按钮按 1 : 1.3 : 1 分配，重播本句最宽。
                let unit = (geometry.size.width - 12) / 3.3
                HStack(spacing: 6) {
                    step("backward.end.fill", "上一句", prominent: false) { session.previousSentence() }
                        .frame(width: unit)
                    step("arrow.counterclockwise", "重播本句", prominent: true) { session.replaySentence() }
                        .frame(width: unit * 1.3)
                    step("forward.end.fill", "下一句", prominent: false) { session.nextSentence() }
                        .frame(width: unit)
                }
            }
            .frame(height: 38)
            .disabled(!hasLines)
            row("单句循环") {
                Picker("单句循环", selection: $session.loopMode) {
                    ForEach(LoopMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .frame(width: Self.segmentWidth)
                .disabled(!hasLines)
            }
            row("每句后暂停") {
                Toggle("每句后暂停", isOn: $session.pauseAfterSentence)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .tint(Color(red: 1, green: 0.68, blue: 0.03))
                    .disabled(!hasLines || session.loopEnabled)
                    .help(session.loopEnabled ? "循环时自动接续" : "听完这一句，再继续")
            }
            row("字幕显示") {
                Picker("字幕显示", selection: $session.subtitleMode) {
                    Text("双语").tag(SubtitleMode.bilingual)
                    Text("英文").tag(SubtitleMode.primaryOnly)
                    Text("遮挡").tag(SubtitleMode.blurPrimary)
                    Text("隐藏").tag(SubtitleMode.off)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .frame(width: Self.segmentWidth)
                .help("只切换学习窗口的字幕显示方式，不影响视频字幕")
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
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }

    private func step(_ icon: String, _ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(.white.opacity(prominent ? 0.18 : 0.08),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickablePointer()
        .help(title == "重播本句" ? "重播本句（R）" : title)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 8)
            content()
        }
        .frame(minHeight: 22)
    }
}

private struct TranscriptList: View {
    let session: PlaybackSession
    let currentLine: Int?
    @State private var lookup: WordLookup?
    @State private var resumeAfterLookup = false

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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(session.primaryCues.enumerated()), id: \.offset) { i, cue in
                                row(i, cue).id(i)
                            }
                        }
                        .padding(.horizontal, 6)
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
            .onChange(of: lookup) { old, new in
                if old != nil, new == nil, resumeAfterLookup { session.engine.play() }
            }
        }
    }

    /// 一行：时间 + 英文，双语时译文排在英文下面；行高随内容，整句都显示。
    private func row(_ i: Int, _ cue: SubtitleCue) -> some View {
        let isCurrent = i == currentLine
        let isPast = currentLine.map { i < $0 } ?? false
        let amber = Color(red: 1, green: 0.68, blue: 0.03)
        let color = Color.white.opacity(isPast ? 0.5 : 1)
        // 单词是流式排版，没有可靠的首行基线，时间改用顶对齐再微调。
        return HStack(alignment: .top, spacing: 6) {
            Text(TimeFormat.clock(cue.range.start.seconds))
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(isCurrent ? amber : .white.opacity(0.4))
                .frame(width: 40, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                FlowLayout(spacing: 2, lineSpacing: 3, alignment: .leading) {
                    ForEach(Array(SubtitleText.words(cue.text).enumerated()), id: \.offset) { index, word in
                        let bare = SubtitleText.bare(word)
                        let identity = WordLookup(word: bare, sentence: cue.text, line: i, index: index)
                        SubtitleWord(word: word, color: color, lookup: $lookup, identity: identity) {
                            guard !bare.isEmpty else { return }
                            resumeAfterLookup = session.engine.state == .playing
                            session.engine.pause()
                            lookup = identity
                        }
                    }
                }
                .font(.system(size: 13, weight: isCurrent ? .bold : .medium))
                .blur(radius: session.subtitleMode == .blurPrimary ? 5 : 0)
                .allowsHitTesting(session.subtitleMode != .blurPrimary)
                if session.subtitleMode == .bilingual, let translation = session.translation(for: cue) {
                    Text(translation.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isCurrent { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.12)) }
        }
        .contentShape(Rectangle())
        // 点单词查词，点行内其他位置跳到这一句。
        .onTapGesture { session.jump(toLine: i) }
        .clickablePointer()
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "跳到这一句") { session.jump(toLine: i) }
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
            .frame(width: 80, height: 45)
            .overlay {
                if url == nil {
                    Image(systemName: "film").font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isCurrent || episode.isPlayed {
                    Image(systemName: isCurrent ? "speaker.wave.2.fill" : "checkmark.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isCurrent ? Color(red: 1, green: 0.68, blue: 0.03) : .white)
                        .padding(3)
                        .background(.black.opacity(0.65), in: Circle())
                        .padding(3)
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
