import SwiftUI
import TitleCutCore
import UniformTypeIdentifiers

extension UTType {
    /// `.titlecut` package, exported by both Dev and Release builds.
    static let titleCutProject = UTType(exportedAs: "com.byteclub.titlecut.project",
                                        conformingTo: .package)
}

/// A `.titlecut` package: `project.json`, a `stills/` folder, a `music/`
/// folder when the music strip is used, and, once a video has been
/// transcribed, `transcripts.json` (§5.1).
///
/// The transcripts sit beside the project, not in it: they are not part of
/// undo, so undoing Auto-Captions keeps the transcription.
struct TitleCutDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.titleCutProject]

    var project: Project
    /// One per video transcribed (`Transcript.source`).
    var transcripts: [Transcript] = []

    init(project: Project = .empty) {
        self.project = project
    }

    init(configuration: ReadConfiguration) throws {
        (project, transcripts) = try ProjectFile.read(package: configuration.file)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Nothing writes new stills before M5; existing ones are kept.
        try ProjectFile.package(project, transcripts: transcripts,
                                existing: configuration.existingFile)
    }
}
