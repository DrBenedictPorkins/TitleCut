import Foundation
import Testing
@testable import TitleCutCore

struct SubtitleExportTests {
    private func caption(_ n: Int, segment: Int, offset: Tick, duration: Tick,
                         text: String) -> Title {
        var title = Fixture.title(n, segment: segment, offset: offset, duration: duration)
        title.text = text
        title.origin = .autoCaption
        return title
    }

    @Test func timestampsRoundToTheNearestMillisecond() {
        #expect(SRT.timestamp(0) == "00:00:00,000")
        #expect(SRT.timestamp(1) == "00:00:00,002")      // 1.667 ms
        #expect(SRT.timestamp(2) == "00:00:00,003")      // 3.333 ms
        #expect(SRT.timestamp(600) == "00:00:01,000")
        #expect(SRT.timestamp(600 * 3723 + 300) == "01:02:03,500")
        #expect(SRT.timestamp(-5) == "00:00:00,000")
    }

    @Test func exactFormatOrderedByOutputStart() {
        var project = Fixture.single                     // one segment, source 0...3000
        project.titles = [caption(20, segment: 1, offset: 1200, duration: 300, text: "Second"),
                          caption(21, segment: 1, offset: 300, duration: 900,
                                  text: "First\r\nline two\n\n"),
                          caption(22, segment: 1, offset: 1300, duration: 600, text: "Overlaps")]
        #expect(SRT.make(project) == """
            1
            00:00:00,500 --> 00:00:02,000
            First
            line two

            2
            00:00:02,000 --> 00:00:02,500
            Second

            3
            00:00:02,167 --> 00:00:03,167
            Overlaps

            """)
    }

    @Test func outputTimesFollowTrimsMovesAndGaps() {
        // gap 600 | v1 src [600,1200) | v2 src [0,600): captions sit at output times.
        let project = MoveFixture.with(
            [MoveFixture.gap(5, duration: 600), Fixture.video(1, start: 600, duration: 600),
             Fixture.video(2, start: 0, duration: 600)],
            titles: [caption(20, segment: 2, offset: 60, duration: 120, text: "On v2"),
                     caption(21, segment: 1, offset: 0, duration: 300, text: "On v1"),
                     caption(22, segment: 5, offset: 300, duration: 300, text: "Over the gap")])
        #expect(SRT.make(project) == """
            1
            00:00:00,500 --> 00:00:01,000
            Over the gap

            2
            00:00:01,000 --> 00:00:01,500
            On v1

            3
            00:00:02,100 --> 00:00:02,300
            On v2

            """)
    }

    @Test func excludesHandMadeEmptyAndOffTimelineTitles() {
        var project = Fixture.single
        var handMade = Fixture.title(20, segment: 1, offset: 0)
        handMade.text = "By hand"
        project.titles = [handMade,
                          caption(21, segment: 1, offset: 0, duration: 300, text: "  \n "),
                          caption(22, segment: 99, offset: 0, duration: 300, text: "No segment"),
                          caption(23, segment: 1, offset: 3000, duration: 300, text: "Past end"),
                          caption(24, segment: 1, offset: 2900, duration: 300, text: "Clamped")]
        #expect(SRT.make(project) == "1\n00:00:04,833 --> 00:00:05,000\nClamped\n")
        #expect(SRT.hasCues(project))
        project.titles.removeLast()
        #expect(SRT.make(project) == "")
        #expect(!SRT.hasCues(project))
        #expect(SRT.make(.empty) == "")
    }
}
