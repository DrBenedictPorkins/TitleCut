import CoreGraphics
import Foundation
@testable import TitleCutCore

/// Deterministic IDs and projects for tests.
enum Fixture {
    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", n))!
    }

    /// The ID of every fixture project, so equal edits compare equal.
    static let projectID = id(700)

    static let source = SourceVideo(bookmark: Data([1, 2, 3]), lastKnownPath: "/tmp/v.mp4",
                                    duration: 3000, naturalSize: CGSize(width: 640, height: 360),
                                    frameRate: 30)

    static func video(_ n: Int, start: Tick, duration: Tick) -> Segment {
        .video(VideoSegment(id: id(n), sourceRange: TickRange(start: start, duration: duration)))
    }

    static func still(_ n: Int, duration: Tick) -> Segment {
        .still(StillSegment(id: id(n), stillID: id(900), duration: duration))
    }

    static func title(_ n: Int, segment: Int, offset: Tick, duration: Tick = 300) -> Title {
        Title(id: id(n), text: "T\(n)",
              anchor: TitleAnchor(segmentID: id(segment), offset: offset),
              duration: duration, styleID: id(800))
    }

    /// video 1 [0,1200) src 0 | still 2 [1200,1800) | video 3 [1800,3000) src 1200
    static var threeSegments: Project {
        Project(id: projectID, source: source,
                segments: [video(1, start: 0, duration: 1200),
                           still(2, duration: 600),
                           video(3, start: 1200, duration: 1200)],
                titles: [title(10, segment: 1, offset: 100),
                         title(11, segment: 3, offset: 0)])
    }

    /// One segment over the whole source plus titles at 0.5 s, 2 s and 4 s.
    static var single: Project {
        Project(id: projectID, source: source,
                segments: [video(1, start: 0, duration: 3000)],
                titles: [title(10, segment: 1, offset: 300),
                         title(11, segment: 1, offset: 1200),
                         title(12, segment: 1, offset: 2400)])
    }

    /// Every model type populated, for Codable round trips.
    static var everything: Project {
        let style = TitleStyle(
            id: id(800), name: "Lower Third", fontName: "Helvetica Neue", fontSizeRatio: 0.06,
            weight: .semibold, textColor: RGBA(red: 1, green: 1, blue: 1),
            background: BackgroundBox(color: RGBA(red: 0, green: 0, blue: 0, alpha: 0.6),
                                      paddingRatio: 0.3, cornerRadiusRatio: 0.2),
            shadow: Shadow(color: RGBA(red: 0, green: 0, blue: 0, alpha: 0.5),
                           radiusRatio: 0.1, offsetXRatio: 0.02, offsetYRatio: -0.02),
            stroke: Stroke(color: RGBA(red: 0.1, green: 0.2, blue: 0.3), widthRatio: 0.05),
            alignment: .center, position: .custom(x: 0.25, y: 0.8), maxWidthRatio: 0.8)
        var title = title(10, segment: 1, offset: 60)
        title.styleOverrides = StyleOverrides(position: .top, fontSizeRatio: 0.1)
        title.transitionIn = Transition(kind: .slide(edge: .bottom), duration: 150,
                                        easing: .easeOut)
        title.transitionOut = Transition(kind: .typewriter, duration: 90, easing: .easeInOut)
        let still = StillSegment(id: id(2), stillID: id(900), duration: 1800, zoom: [
            ZoomKeyframe(time: 0, center: CGPoint(x: 0.5, y: 0.5), scale: 1, easing: .linear),
            ZoomKeyframe(time: 900, center: CGPoint(x: 0.3, y: 0.7), scale: 2.5, easing: .easeIn),
        ])
        return Project(
            id: projectID,
            source: source,
            segments: [video(1, start: 0, duration: 1500), .still(still),
                       video(3, start: 1500, duration: 1500)],
            titles: [title, Title(id: id(11), text: "Second\nline", anchor:
                                    TitleAnchor(segmentID: id(3), offset: 0),
                                  duration: 600, styleID: id(800),
                                  transitionIn: Transition(kind: .fade, duration: 30,
                                                           easing: .linear),
                                  transitionOut: Transition(kind: .scale, duration: 30,
                                                            easing: .easeIn))],
            styles: [style],
            stills: [StillImage(id: id(900), fileName: "\(id(900).uuidString).png",
                                capturedAt: 1500, pixelSize: CGSize(width: 640, height: 360))],
            output: OutputSettings(size: CGSize(width: 1920, height: 1080), frameRate: 25,
                                   codec: .hevc))
    }
}
