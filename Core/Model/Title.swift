import Foundation

public struct Title: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var anchor: TitleAnchor
    public var duration: Tick
    /// Refers to `Project.styles`.
    public var styleID: UUID
    /// Per-title tweaks (position, size).
    public var styleOverrides: StyleOverrides?
    public var transitionIn: Transition
    public var transitionOut: Transition
    /// What made the title; `nil` for one the person added. Absent from
    /// files written before it existed. Edits keep it.
    public var origin: TitleOrigin?
    /// The spoken words of the text with their times, for the word highlight.
    /// Filled by Auto-Captions; absent from older files and hand-made titles.
    public var words: [TimedWord]?

    public init(id: UUID, text: String, anchor: TitleAnchor, duration: Tick, styleID: UUID,
                styleOverrides: StyleOverrides? = nil,
                transitionIn: Transition = .none, transitionOut: Transition = .none,
                origin: TitleOrigin? = nil, words: [TimedWord]? = nil) {
        self.id = id
        self.text = text
        self.anchor = anchor
        self.duration = duration
        self.styleID = styleID
        self.styleOverrides = styleOverrides
        self.transitionIn = transitionIn
        self.transitionOut = transitionOut
        self.origin = origin
        self.words = words
    }
}

/// A word of a title's text and when it is spoken, in ticks from the title's start.
public struct TimedWord: Codable, Sendable, Equatable {
    /// As it appears in the text, punctuation included.
    public var text: String
    public var start: Tick
    public var end: Tick

    public init(text: String, start: Tick, end: Tick) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A title made by a feature rather than by hand.
public enum TitleOrigin: String, Codable, Sendable, Equatable {
    /// Made by Auto-Captions; replaced when it runs again.
    case autoCaption
}

/// A title's start, relative to a segment (D1, §4.1).
public struct TitleAnchor: Codable, Sendable, Equatable {
    public var segmentID: UUID
    /// From segment start.
    public var offset: Tick

    public init(segmentID: UUID, offset: Tick) {
        self.segmentID = segmentID
        self.offset = offset
    }
}

public struct Transition: Codable, Sendable, Equatable {
    public var kind: TransitionKind
    public var duration: Tick
    public var easing: Easing

    public init(kind: TransitionKind, duration: Tick, easing: Easing) {
        self.kind = kind
        self.duration = duration
        self.easing = easing
    }

    public static let none = Transition(kind: .none, duration: 0, easing: .linear)
}

public enum TransitionKind: Codable, Sendable, Equatable {
    case none
    case fade
    case slide(edge: SlideEdge)
    case scale
    case typewriter
}

/// Edge a slide transition enters from or exits to.
public enum SlideEdge: String, Codable, Sendable, Equatable {
    case top, bottom, leading, trailing
}

/// Per-title overrides of the style. `nil` fields use the style's value.
public struct StyleOverrides: Codable, Sendable, Equatable {
    public var position: NormalizedPosition?
    public var fontSizeRatio: Double?
    /// Left, centre or right: lines the text up and, on a preset position,
    /// places the title at that side.
    public var alignment: TextAlignment?

    public init(position: NormalizedPosition? = nil, fontSizeRatio: Double? = nil,
                alignment: TextAlignment? = nil) {
        self.position = position
        self.fontSizeRatio = fontSizeRatio
        self.alignment = alignment
    }
}
