import AppKit
import TitleCutCore
import UniformTypeIdentifiers

/// Writing the auto-captions as an .srt file.
@MainActor
enum SubtitleFile {
    static let contentType = UTType(filenameExtension: "srt") ?? .plainText

    /// `movie` with its extension replaced by `.srt`.
    static func url(nextTo movie: URL) -> URL {
        movie.deletingPathExtension().appendingPathExtension("srt")
    }

    /// Writes `project`'s subtitles as UTF-8, replacing any file at `url`.
    static func write(_ project: Project, to url: URL) throws {
        try Data(SRT.make(project).utf8).write(to: url, options: .atomic)
    }

    /// Writes `project`'s subtitles next to `movie`, a file the save panel
    /// opened to the app. A sandboxed app may write that sibling only as a
    /// related item: Info.plist declares .srt with `NSIsRelatedItemType`, and
    /// the write is coordinated through a presenter naming `movie` as primary.
    /// - Returns: Where it was written.
    @discardableResult
    static func write(_ project: Project, nextTo movie: URL) throws -> URL {
        let url = url(nextTo: movie)
        let presenter = RelatedFilePresenter(primary: movie, item: url)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let data = Data(SRT.make(project).utf8)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: presenter).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            // Not atomic: that would need a temporary file in the folder.
            do { try data.write(to: target) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
        return url
    }

    /// File > Export Subtitles…: asks where, in a sheet on `window`, then
    /// writes. A failure the person caused is reported in an alert with what
    /// to do.
    static func export(_ project: Project, documentName: String, in window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(documentName).srt"
        panel.present(in: window) { url in
            do {
                try write(project, to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not save \(url.lastPathComponent)"
                alert.informativeText = error.localizedDescription
                    + " Check that the folder can be written to, or choose another location."
                alert.present(in: window)
            }
        }
    }
}

/// Names a related item and the file it belongs to, for `NSFileCoordinator`.
private final class RelatedFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let primaryPresentedItemURL: URL?
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()

    init(primary: URL, item: URL) {
        primaryPresentedItemURL = primary
        presentedItemURL = item
    }
}
