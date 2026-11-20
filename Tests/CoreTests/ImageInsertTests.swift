import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TitleCutCore

/// Pictures dropped from outside: `StillFiles.importImage` and `insertImage`.
@MainActor
struct ImageInsertTests {
    private let image = StillImage(id: Fixture.id(70), fileName: "picture.png", capturedAt: nil,
                                   pixelSize: CGSize(width: 400, height: 300))

    @Test func insideAClipSplitsItAndAddsTheStill() {
        var project = Fixture.single
        #expect(ProjectCommand.insertImage(image, segmentID: Fixture.id(50), splitID: Fixture.id(99),
                                           atOutputTime: 900, duration: 1800).apply(to: &project))
        #expect(project.segments.map(\.id) == [Fixture.id(1), Fixture.id(50), Fixture.id(99)])
        #expect(project.segments.map(\.duration) == [900, 1800, 2100])
        guard case .still(let still) = project.segments[1] else {
            Issue.record("Not a still")
            return
        }
        #expect(still.stillID == image.id)
        #expect(project.stills == [image])
    }

    @Test func pastTheEndItIsAppended() {
        var project = Fixture.single
        #expect(ProjectCommand.insertImage(image, segmentID: Fixture.id(50), splitID: Fixture.id(99),
                                           atOutputTime: 99_999, duration: 1800).apply(to: &project))
        #expect(project.segments.last?.id == Fixture.id(50))
    }

    @Test func importTurnsAJPEGIntoAStoredPNG() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let jpeg = folder.appending(path: "photo.jpg")
        let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let writer = CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString,
                                                     1, nil)!
        CGImageDestinationAddImage(writer, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(writer))

        let id = UUID()
        let still = try StillFiles.importImage(from: jpeg, id: id)
        defer { try? FileManager.default.removeItem(at: StillFiles.url(for: still.fileName)) }
        #expect(still.fileName == "\(id.uuidString).png")
        #expect(still.pixelSize == CGSize(width: 64, height: 32))
        #expect(still.capturedAt == nil)
        #expect(FileManager.default.fileExists(atPath: StillFiles.url(for: still.fileName).path))
    }

    @Test func aFileThatIsNotAPictureIsRefused() throws {
        let text = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        try "not a picture".write(to: text, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: text) }
        #expect(throws: StillFiles.GrabError.unreadableImage) {
            try StillFiles.importImage(from: text, id: UUID())
        }
    }
}
