import AppKit
import Foundation
import Observation

/// Folders the person lets MCP clients use. The app is sandboxed, so it can
/// only open and save the paths MCP tools name inside folders chosen here
/// (open_video, add_music, export, export_subtitles), or inside Movies and
/// Music, which the entitlements grant.
///
/// Kept as security-scoped bookmarks in user defaults; access to each starts
/// at launch, or when it is added, and lasts until the app quits.
@MainActor
@Observable
final class MCPFolders {
    static let shared = MCPFolders()

    private(set) var folders: [URL] = []

    /// Movies and Music in the person's home folder, granted by the
    /// entitlements (assets.movies, assets.music). Always allowed.
    static let builtIn: [URL] = {
        // NSHomeDirectory() is the container inside the sandbox.
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return [] }
        let root = URL(fileURLWithPath: String(cString: home), isDirectory: true)
        return [root.appending(path: "Movies", directoryHint: .isDirectory),
                root.appending(path: "Music", directoryHint: .isDirectory)]
    }()
    @ObservationIgnored private var bookmarks: [Data] = []

    private static let defaultsKey = "MCPFolders"

    private init() {}

    /// Resolves the saved folders and starts access to each. Folders that
    /// no longer resolve are dropped.
    func restore() {
        let saved = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [Data] ?? []
        for data in saved {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: [.withSecurityScope, .withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            let current = stale ? (try? Self.bookmark(url)) ?? data : data
            folders.append(url)
            bookmarks.append(current)
        }
        save()
    }

    /// Asks for a folder and adds it.
    func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder Claude may open videos and songs from and save exports to"
        panel.prompt = "Allow"
        guard panel.runModal() == .OK, let url = panel.url,
              !folders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }),
              let data = try? Self.bookmark(url) else { return }
        _ = url.startAccessingSecurityScopedResource()
        folders.append(url)
        bookmarks.append(data)
        save()
    }

    func remove(_ url: URL) {
        guard let index = folders.firstIndex(of: url) else { return }
        folders[index].stopAccessingSecurityScopedResource()
        folders.remove(at: index)
        bookmarks.remove(at: index)
        save()
    }

    /// Whether `url` (which need not exist yet) is inside one of the folders.
    func allows(_ url: URL) -> Bool {
        let file = url.standardizedFileURL
        let path = file.deletingLastPathComponent().resolvingSymlinksInPath()
            .appending(path: file.lastPathComponent).path
        return (Self.builtIn + folders).contains { folder in
            let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// The error for a path outside the folders.
    func refusal(for path: String) -> String {
        let list = (Self.builtIn + folders).map(\.path).joined(separator: ", ")
        return "\(path) is outside the folders the person has allowed (\(list)). "
            + "TitleCut runs in the macOS App Sandbox, which lets it open a file only "
            + "after the person chooses it; a path sent over MCP is not a choice. Ask "
            + "the person to add its folder (MCP button > Folders > Add Folder), or to "
            + "open the file in TitleCut themselves."
    }

    private func save() {
        UserDefaults.standard.set(bookmarks, forKey: Self.defaultsKey)
    }

    private static func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                             relativeTo: nil)
    }
}
