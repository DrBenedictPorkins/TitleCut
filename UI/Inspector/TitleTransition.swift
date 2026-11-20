import TitleCutCore

/// `TitleCutCore.Transition` under a name SwiftUI does not also use.
/// (This file must not import SwiftUI, whose `Transition` would be ambiguous;
/// `TitleCutCore.Transition` cannot be written because the module contains
/// an enum named `TitleCutCore`.)
typealias TitleTransition = Transition

/// `TitleCutCore.TextAlignment`, for the same reason.
typealias TitleTextAlignment = TextAlignment
