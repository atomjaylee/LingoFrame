import Testing
@testable import LearningCore

@Test func parsesSRTWithTagsAndMultipleLines() {
    let srt = """
    1
    00:00:01,000 --> 00:00:02,500
    <i>Hang on,</i> I'm still
    trying to {\\an8}figure it out.

    2
    00:01:02,345 --> 00:01:04,000
    Nothing.

    3
    00:01:05,000 --> 00:01:06,000

    """
    let cues = SubtitleParser.parse(srt)
    #expect(cues.count == 2)
    #expect(cues[0].text == "Hang on, I'm still\ntrying to figure it out.")
    #expect(cues[1].range == TimeRange(startMs: 62_345, endMs: 64_000))
}

@Test func parsesVTTTimingWithoutHours() {
    let vtt = "WEBVTT\n\n01:02.345 --> 01:04.000 align:start\nHello\n"
    let cues = SubtitleParser.parse(vtt)
    #expect(cues.first?.range == TimeRange(startMs: 62_345, endMs: 64_000))
}

@Test func findsCueAtTime() {
    let cues = [
        SubtitleCue(range: TimeRange(startMs: 1000, endMs: 2000), text: "a"),
        SubtitleCue(range: TimeRange(startMs: 3000, endMs: 4000), text: "b"),
    ]
    #expect(cues.cue(at: MediaTime(ms: 3500))?.text == "b")
    #expect(cues.cue(at: MediaTime(ms: 2500)) == nil)
    #expect(cues.latestIndex(atOrBefore: MediaTime(ms: 500)) == nil)
    #expect(cues.latestIndex(atOrBefore: MediaTime(ms: 2500)) == 0)
    #expect(cues.latestIndex(atOrBefore: MediaTime(ms: 3000)) == 1)
}
