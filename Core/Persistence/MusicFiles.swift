import AVFoundation
import Foundation

/// Song files for the music strip.
///
/// They are saved in the package at `music/<fileName>`. While a project is
/// open, playback and export read them from a cache folder, since an unsaved
/// document has no package on disk. File names are fresh UUIDs, so projects
/// sharing the cache never collide.
public enum MusicFiles {
    public static let folderName = "music"

    public enum ImportError: LocalizedError, Equatable {
        case noAudio

        public var errorDescription: String? {
            switch self {
            case .noAudio: "The file has no audio that TitleCut can play."
            }
        }
    }

    /// `~/Library/Caches/<bundle>/Music`, created on demand.
    public static var cacheFolder: URL { PackageFiles.cacheFolder("Music") }

    public static func url(for fileName: String) -> URL {
        cacheFolder.appending(path: fileName)
    }

    /// Copies the song at `url` into the cache as `<id>.<ext>`.
    /// - Returns: The new file name and the song's length.
    public static func importSong(from url: URL, id: UUID) async throws
        -> (fileName: String, duration: Tick) {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw ImportError.noAudio
        }
        let duration = Ticks.from(try await asset.load(.duration))
        guard duration > 0 else { throw ImportError.noAudio }
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
        let fileName = "\(id.uuidString).\(ext)"
        let destination = Self.url(for: fileName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        return (fileName, duration)
    }

    /// Writes the package's song files into the cache where missing.
    static func extract(from package: FileWrapper) {
        PackageFiles.extract(folderName, from: package, to: cacheFolder)
    }

    /// The package's `music/` folder: every song the project uses, from the
    /// existing package where it is already saved, otherwise from the cache.
    /// Songs no piece uses are left out. `nil` when there are none.
    static func folder(for project: Project, existing: FileWrapper?) throws -> FileWrapper? {
        try PackageFiles.folder(folderName, names: Set(project.music.map(\.fileName)),
                                existing: existing, cache: cacheFolder)
    }
}

/// A package folder of media files mirrored in a cache folder, for
/// `MusicFiles` and `StillFiles`.
enum PackageFiles {
    /// `~/Library/Caches/<bundle>/<name>`, created on demand.
    static func cacheFolder(_ name: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "com.byteclub.titlecut"
        let folder = caches.appending(path: bundle).appending(path: name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Writes the files in the package's `folderName` folder into `cache`
    /// where missing.
    static func extract(_ folderName: String, from package: FileWrapper, to cache: URL) {
        guard let files = package.fileWrappers?[folderName]?.fileWrappers else { return }
        for (name, file) in files {
            let destination = cache.appending(path: name)
            guard !FileManager.default.fileExists(atPath: destination.path),
                  let data = file.regularFileContents else { continue }
            try? data.write(to: destination)
        }
    }

    /// The package folder holding `names`, each from the existing package
    /// where already saved, otherwise from `cache`. `nil` when `names` is empty.
    static func folder(_ folderName: String, names: Set<String>, existing: FileWrapper?,
                       cache: URL) throws -> FileWrapper? {
        guard !names.isEmpty else { return nil }
        let saved = existing?.fileWrappers?[folderName]?.fileWrappers ?? [:]
        var children: [String: FileWrapper] = [:]
        for name in names.sorted() {
            let file: FileWrapper
            if let current = saved[name], let data = current.regularFileContents {
                // A fresh wrapper: children of the current package must not be reused.
                file = FileWrapper(regularFileWithContents: data)
            } else {
                file = try FileWrapper(url: cache.appending(path: name), options: .immediate)
            }
            file.preferredFilename = name
            children[name] = file
        }
        let folder = FileWrapper(directoryWithFileWrappers: children)
        folder.preferredFilename = folderName
        return folder
    }
}
