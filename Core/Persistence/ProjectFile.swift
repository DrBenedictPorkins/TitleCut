import Foundation

/// Reads and writes `project.json` and `transcripts.json` (§5.1).
public enum ProjectFile {
    /// Name of the model file inside the `.titlecut` package.
    public static let projectFileName = "project.json"
    /// Folder for captured stills inside the package.
    public static let stillsFolderName = "stills"
    /// Optional transcripts inside the package, one per video transcribed;
    /// absent until a video is transcribed.
    public static let transcriptsFileName = "transcripts.json"
    /// The one transcript of packages saved before `transcriptsFileName`;
    /// read, never written.
    public static let transcriptFileName = "transcript.json"

    public enum ReadError: LocalizedError, Equatable {
        case newerFormat(found: Int, supported: Int)

        public var errorDescription: String? {
            switch self {
            case let .newerFormat(found, supported):
                "This project was saved by a newer version of TitleCut "
                    + "(format \(found)). This version opens format \(supported) and earlier."
            }
        }

        public var failureReason: String? { errorDescription }

        public var recoverySuggestion: String? {
            switch self {
            case .newerFormat: "Open it with a newer version of TitleCut."
            }
        }
    }

    private struct Header: Decodable {
        var formatVersion: Int
    }

    /// Decodes a project, refusing any format newer than this build supports.
    public static func decode(_ data: Data) throws -> Project {
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.formatVersion <= Project.currentFormatVersion else {
            throw ReadError.newerFormat(found: header.formatVersion,
                                        supported: Project.currentFormatVersion)
        }
        return try JSONDecoder().decode(Project.self, from: data)
    }

    /// Decodes `transcript.json`. A transcript in a newer format, or one that
    /// does not decode, is treated as absent: it can be made again.
    public static func decodeTranscript(_ data: Data) -> Transcript? {
        guard let header = try? JSONDecoder().decode(Header.self, from: data),
              header.formatVersion <= Transcript.currentFormatVersion else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    /// Decodes `transcripts.json`, leaving out any transcript that is in a
    /// newer format or does not decode.
    public static func decodeTranscripts(_ data: Data) -> [Transcript] {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return []
        }
        return items.compactMap { item in
            (try? JSONSerialization.data(withJSONObject: item)).flatMap(decodeTranscript)
        }
    }

    public static func encodeTranscripts(_ transcripts: [Transcript]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(transcripts)
    }

    public static func encodeTranscript(_ transcript: Transcript) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(transcript)
    }

    // MARK: Package

    /// Reads the package: `project.json` (required) and `transcripts.json`,
    /// or `transcript.json` in older packages (optional; missing or
    /// unreadable is none). Songs in `music/` are copied to the
    /// `MusicFiles` cache for playback.
    public static func read(package: FileWrapper) throws -> (Project, [Transcript]) {
        guard let data = package.fileWrappers?[projectFileName]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let files = package.fileWrappers
        let transcripts = files?[transcriptsFileName]?.regularFileContents
            .map(decodeTranscripts)
            ?? files?[transcriptFileName]?.regularFileContents
                .flatMap(decodeTranscript).map { [$0] }
            ?? []
        let project = try decode(data)
        MusicFiles.extract(from: package)
        StillFiles.extract(from: package)
        return (project, transcripts)
    }

    /// The package for `project` and `transcripts`. Stills and songs the
    /// project uses come from `existing` where already saved, otherwise from
    /// the `StillFiles` and `MusicFiles` caches.
    public static func package(_ project: Project, transcripts: [Transcript],
                               existing: FileWrapper?) throws -> FileWrapper {
        let json = FileWrapper(regularFileWithContents: try encode(project))
        json.preferredFilename = projectFileName
        // Never mutate the existing wrapper: setting preferredFilename on a child
        // of the current package raises "mutated while being enumerated".
        let stills: FileWrapper
        if let used = try StillFiles.folder(for: project, existing: existing) {
            stills = used
        } else {
            stills = FileWrapper(directoryWithFileWrappers: [:])
            stills.preferredFilename = stillsFolderName
        }
        var children = [projectFileName: json, stillsFolderName: stills]
        if let music = try MusicFiles.folder(for: project, existing: existing) {
            children[MusicFiles.folderName] = music
        }
        if !transcripts.isEmpty {
            let file = FileWrapper(regularFileWithContents: try encodeTranscripts(transcripts))
            file.preferredFilename = transcriptsFileName
            children[transcriptsFileName] = file
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }

    public static func encode(_ project: Project) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }
}
