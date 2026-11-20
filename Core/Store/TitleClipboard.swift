import Foundation

/// Titles as copied, for pasting into this or another document (§7.2).
///
/// Stored on the pasteboard as JSON under `pasteboardType`, alongside the
/// titles' text as a plain string.
public struct TitleClipboard: Codable, Sendable, Equatable {
    /// Private pasteboard type.
    public static let pasteboardType = "com.byteclub.titlecut.titles"

    public struct Entry: Codable, Sendable, Equatable {
        /// As copied; its ID and anchor are replaced on paste.
        public var title: Title
        /// Output start relative to the earliest copied title.
        public var start: Tick

        public init(title: Title, start: Tick) {
            self.title = title
            self.start = start
        }
    }

    /// In output-start order.
    public var entries: [Entry]
    /// The style each title uses, as the source project had it.
    public var styles: [TitleStyle]

    public init(entries: [Entry], styles: [TitleStyle]) {
        self.entries = entries
        self.styles = styles
    }

    /// Copies the titles in `ids` that are on the timeline. `nil` if none are.
    public init?(copying ids: Set<UUID>, from project: Project) {
        let placed = project.titles.compactMap { title -> (Title, Tick)? in
            guard ids.contains(title.id),
                  let range = TimelineMath.titleOutputRange(title, in: project) else { return nil }
            return (title, range.start)
        }
        .sorted { $0.1 < $1.1 }
        guard let earliest = placed.first?.1 else { return nil }
        entries = placed.map { Entry(title: $0.0, start: $0.1 - earliest) }
        let styleIDs = Set(placed.map(\.0.styleID))
        styles = project.styles.filter { styleIDs.contains($0.id) }
    }

    /// The titles' text, one per paragraph, for pasting into other apps.
    public var plainText: String {
        entries.map(\.title.text).joined(separator: "\n\n")
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> TitleClipboard {
        try JSONDecoder().decode(TitleClipboard.self, from: data)
    }
}
