import Foundation

/// Which word of a title is being spoken, and where it is in the text.
public enum WordHighlight {
    /// The ranges of `words` in `text`, matched in order. The text must be
    /// exactly the words separated by whitespace (line breaks included);
    /// anything else, such as an edit that added, removed or changed a word,
    /// gives `nil` and the title is drawn without a highlight.
    public static func ranges(of words: [TimedWord], in text: String) -> [Range<String.Index>]? {
        guard !words.isEmpty else { return nil }
        var ranges: [Range<String.Index>] = []
        var cursor = text.startIndex
        for word in words {
            guard !word.text.isEmpty,
                  let range = text.range(of: word.text, range: cursor..<text.endIndex),
                  text[cursor..<range.lowerBound].allSatisfy(\.isWhitespace)
            else { return nil }
            ranges.append(range)
            cursor = range.upperBound
        }
        return text[cursor...].allSatisfy(\.isWhitespace) ? ranges : nil
    }

    /// The word to highlight `elapsed` ticks after the title starts: the
    /// last word that has started. A word stays highlighted through the
    /// pause after it and after the last word ends; nothing is highlighted
    /// before the first word starts.
    public static func index(at elapsed: Double, in words: [TimedWord]) -> Int? {
        words.lastIndex { Double($0.start) <= elapsed }
    }
}
