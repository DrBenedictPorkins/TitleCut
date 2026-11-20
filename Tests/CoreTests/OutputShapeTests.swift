import CoreImage
import Foundation
import Testing
@testable import TitleCutCore

struct OutputShapeTests {
    private func source(_ width: CGFloat, _ height: CGFloat) -> SourceVideo {
        SourceVideo(bookmark: Data(), lastKnownPath: "/tmp/v.mp4", duration: 600,
                    naturalSize: CGSize(width: width, height: height), frameRate: 30)
    }

    @Test func shapesAreSizedFromTheShortSide() {
        let hd = source(1920, 1080)
        #expect(OutputShape.portrait.size(for: hd) == CGSize(width: 1080, height: 1920))
        #expect(OutputShape.square.size(for: hd) == CGSize(width: 1080, height: 1080))
        #expect(OutputShape.landscape.size(for: hd) == CGSize(width: 1920, height: 1080))
        let phone = source(1080, 1920)
        #expect(OutputShape.landscape.size(for: phone) == CGSize(width: 1920, height: 1080))
    }

    @Test func originalIsAlwaysOfferedAndWinsWhenAFixedShapeMatches() {
        #expect(OutputShape.offered(for: source(1920, 1080))
                == [.original, .landscape, .portrait, .square])
        #expect(OutputShape.offered(for: source(1440, 1080)).first == .original)
        #expect(OutputShape.of(CGSize(width: 1920, height: 1080), source: source(1920, 1080))
                == .original)
        #expect(OutputShape.of(CGSize(width: 1080, height: 1920), source: source(1920, 1080))
                == .portrait)
    }

    @MainActor @Test func changingShapeIsOneUndoStep() {
        let original = Fixture.single
        let store = ProjectStore(project: original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        #expect(store.perform(.setOutputSize(CGSize(width: 360, height: 640))))
        #expect(store.project.output.size == CGSize(width: 360, height: 640))
        #expect(undo.undoActionName == "Change Shape")
        undo.undo()
        #expect(store.project == original)
        #expect(!store.perform(.setOutputSize(.zero)))
    }

    @Test func wideVideoFillsATallFrameCroppedAtTheCentre() {
        // Left half red, right half blue, 16x9.
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 9))
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 8, y: 0, width: 8, height: 9))
        let frame = FrameRenderer.render(source: blue.composited(over: red),
                                         preferredTransform: .identity,
                                         renderSize: CGSize(width: 9, height: 16))
        #expect(frame.extent == CGRect(x: 0, y: 0, width: 9, height: 16))
        let pixels = RenderFixture.pixels(of: CIContext().createCGImage(frame, from: frame.extent)!)
        // No black bars: top and bottom rows are colour, not black.
        for y in [0, 15] {
            let p = pixels.rgb(x: 0, y: y)
            #expect(p.r + p.g + p.b > 100, "row \(y): \(p)")
        }
    }
}
