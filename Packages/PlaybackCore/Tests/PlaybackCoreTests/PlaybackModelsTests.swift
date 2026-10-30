import Foundation
import Testing
@testable import PlaybackCore

@Test func playbackSourceKeepsTransportData() {
    let source = PlaybackSource(id: "episode-1", url: URL(string: "https://media.test/video.mkv")!,
                                startAt: 42, durationHint: 1_800,
                                httpHeaders: ["Authorization": "MediaBrowser token"])
    #expect(source.id == "episode-1")
    #expect(source.startAt == 42)
    #expect(source.durationHint == 1_800)
    #expect(source.httpHeaders["Authorization"] != nil)
}

@Test func playbackStateReportsActivity() {
    #expect(PlaybackState.playing.isActive)
    #expect(PlaybackState.paused.isActive)
    #expect(!PlaybackState.loading.isActive)
    #expect(PlaybackState.failed("broken").isFailed)
}
