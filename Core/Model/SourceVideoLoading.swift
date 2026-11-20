import AVFoundation

extension SourceVideo {
    public enum LoadError: LocalizedError {
        case noVideoTrack

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The file has no video track."
            }
        }
    }

    /// Reads duration, size and frame rate from `url` and bookmarks it (D6).
    /// The bookmark is security-scoped, so a sandboxed app can open the file
    /// again later; call it while the file is accessible (just chosen in an
    /// open panel, or inside a folder whose access has started).
    public static func load(from url: URL) async throws -> SourceVideo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LoadError.noVideoTrack
        }
        let (stored, transform, rate) = try await track.load(.naturalSize, .preferredTransform,
                                                             .nominalFrameRate)
        // The size as displayed: a phone video stored landscape with a
        // 90-degree transform is portrait.
        let turned = CGRect(origin: .zero, size: stored).applying(transform)
        let size = CGSize(width: abs(turned.width), height: abs(turned.height))
        let duration = try await asset.load(.duration)
        let bookmark = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
        return SourceVideo(bookmark: bookmark, lastKnownPath: url.path,
                           duration: Ticks.from(duration), naturalSize: size,
                           frameRate: rate > 0 ? Double(rate) : Timecode.fallbackFrameRate)
    }

    /// Resolves the bookmark and starts its security-scoped access, which
    /// is never stopped: the file stays open to the app until it quits.
    /// Falls back to a plain bookmark (files saved before the sandbox) and
    /// then `lastKnownPath`; a sandboxed app can read neither, so the video
    /// shows as missing until it is located again.
    /// - Returns: The file URL, or `nil` if the video cannot be found.
    public func resolveURL() -> URL? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark,
                              options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            _ = url.startAccessingSecurityScopedResource()
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale),
           FileManager.default.isReadableFile(atPath: url.path) {
            return url
        }
        let fallback = URL(fileURLWithPath: lastKnownPath)
        return FileManager.default.isReadableFile(atPath: fallback.path) ? fallback : nil
    }
}
