import SwiftUI
import TitleCutCore

/// The "Instrument" inspector docked right of the preview. It follows the
/// selection: no title shows the style library, one title shows its editor,
/// several show the same editor applied to all of them.
struct InspectorPanel: View {
    let store: ProjectStore
    /// Library styles, in picker order. LOOK offers only these; a title's
    /// private style is never offered to other titles.
    let libraryStyles: [TitleStyle]
    /// The default style for new titles.
    @Binding var defaultStyleID: UUID
    let renderSize: CGSize
    /// Shared layout cache, for resting positions of preset-placed titles.
    let titleRenderer: TitleRenderer
    /// Reloads `libraryStyles` after a style is saved to the library.
    let onLibraryChanged: () -> Void
    /// Opens the camera window of a frozen frame.
    let editCamera: (UUID) -> Void
    /// What the clip inspector's framing map needs; `nil` while a video's
    /// file is missing.
    let framing: ClipFramingContext?

    private var selectedTitles: [Title] {
        store.project.titles.filter { store.selectedTitleIDs.contains($0.id) }
    }

    var body: some View {
        let titles = selectedTitles
        Group {
            if titles.isEmpty, let id = store.selectedSegmentID,
               case .still(let still)? = store.project.segments.first(where: { $0.id == id }) {
                FreezeInspector(store: store, still: still, editCamera: { editCamera(still.id) })
            } else if titles.isEmpty, let id = store.selectedSegmentID,
                      case .card(let card)? = store.project.segments.first(where: { $0.id == id }) {
                CardInspector(store: store, card: card)
            } else if titles.isEmpty, let id = store.selectedSegmentID,
                      case .video(let clip)? = store.project.segments.first(where: { $0.id == id }) {
                ClipInspector(store: store, clip: clip, renderSize: renderSize, framing: framing)
            } else if titles.isEmpty, let point = store.selectedTransition,
                      let transition = point.transition(in: store.project) {
                TransitionInspector(store: store, point: point, transition: transition)
            } else if titles.isEmpty, let id = store.selectedMusicID,
               let clip = store.project.music.first(where: { $0.id == id }) {
                MusicInspector(store: store, clip: clip)
            } else if titles.isEmpty {
                StylesInspector(styles: libraryStyles, defaultStyleID: $defaultStyleID,
                                onLibraryChanged: onLibraryChanged)
            } else {
                TitleInspector(store: store, titles: titles, styles: libraryStyles,
                               libraryStyleIDs: Set((libraryStyles + StyleLibrary.builtIns)
                                   .map(\.id)),
                               renderSize: renderSize, titleRenderer: titleRenderer,
                               onLibraryChanged: onLibraryChanged)
            }
        }
        .frame(width: Instrument.panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Instrument.background, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Instrument.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}

/// Neon dot, a mono label and an optional trailing readout.
struct InspectorHeader: View {
    let label: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Instrument.neon)
                .frame(width: 8, height: 8)
                .shadow(color: Instrument.neon, radius: 4)
            Text(label)
                .font(Instrument.mono(11))
                .tracking(1.3)
                .foregroundStyle(Instrument.muted)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(Instrument.mono(11))
                    .foregroundStyle(Instrument.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Instrument.divider).frame(height: 1) }
    }
}

// MARK: Styles (no title selected)

/// Style tiles with live thumbnails. Clicking a tile makes it the default
/// style for new titles (§7.5). Right-clicking one renames it, deletes a
/// saved style, or reverts a changed built-in. Titles already using a style
/// keep the copy embedded in their project (§5.2).
private struct StylesInspector: View {
    let styles: [TitleStyle]
    @Binding var defaultStyleID: UUID
    /// Reloads `styles` after the library file changes.
    let onLibraryChanged: () -> Void

    @State private var renaming: TitleStyle?
    @State private var newName = ""
    @State private var deleting: TitleStyle?
    @State private var reverting: TitleStyle?
    @State private var libraryError: String?

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(label: "STYLES", trailing: "\(styles.count)")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let libraryError {
                        Text(libraryError)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.selectedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    StyleGrid(styles: styles, selection: defaultStyleID, badge: "DEFAULT",
                              menu: menu, onSelect: makeDefault)
                }
                .padding(16)
            }
            .scrollIndicators(.never)
        }
        .alert("Rename Style", isPresented: isShown($renaming)) {
            TextField("Name", text: $newName)
            Button("Rename") { if let style = renaming { rename(style) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \u{201C}\(deleting?.name ?? "")\u{201D}?",
                            isPresented: isShown($deleting)) {
            Button("Delete", role: .destructive) {
                if let style = deleting { change { try $0.remove(id: style.id) } }
            }
        } message: {
            Text("Titles already using it keep their look.")
        }
        .confirmationDialog("Revert \u{201C}\(reverting?.name ?? "")\u{201D} to its original look?",
                            isPresented: isShown($reverting)) {
            Button("Revert") {
                if let style = reverting { change { try $0.remove(id: style.id) } }
            }
        } message: {
            Text("Titles already using it keep their current look.")
        }
    }

    private func menu(_ style: TitleStyle) -> [StyleMenuAction] {
        var actions = [StyleMenuAction(label: "Rename\u{2026}") {
            newName = style.name
            renaming = style
        }]
        if StyleLibrary.isChangedBuiltIn(style) {
            actions.append(StyleMenuAction(label: "Revert to Original\u{2026}") {
                reverting = style
            })
        }
        if !StyleLibrary.isBuiltIn(style.id) {
            actions.append(StyleMenuAction(label: "Delete\u{2026}", role: .destructive) {
                deleting = style
            })
        }
        return actions
    }

    private func rename(_ style: TitleStyle) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != style.name else { return }
        change { try $0.rename(id: style.id, to: name) }
    }

    /// Writes the library file, then reloads the styles.
    private func change(_ write: (StyleLibrary) throws -> Void) {
        do {
            try write(StyleLibrary())
            libraryError = nil
        } catch {
            libraryError = "Could not change the style library: \(error.localizedDescription) "
                + "Check that ~/Library/Application Support/TitleCut can be written to, "
                + "then try again."
        }
        onLibraryChanged()
    }

    /// Shown while `item` is set; dismissing clears it.
    private func isShown<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } })
    }

    private func makeDefault(_ style: TitleStyle) {
        StyleLibrary().setDefaultStyleID(style.id)
        defaultStyleID = style.id
    }
}

// MARK: Clip

/// The selected video clip: its speed, the volume of its sound, and split
/// screen.
/// The player, video files and Frame Faces action for the clip
/// inspector's `FramingMap`.
struct ClipFramingContext {
    let player: PlayerController
    /// Every video's file, keyed as `VideoSegment.sourceID`.
    let sourceURLs: [UUID?: URL]
    /// Frames the largest face in every clip; `nil` while that runs, or
    /// when no clip's picture is wider than the frame.
    let frameFaces: (() -> Void)?
    /// Frame Faces is running.
    let findingFaces: Bool
}

private struct ClipInspector: View {
    let store: ProjectStore
    let clip: VideoSegment
    let renderSize: CGSize
    let framing: ClipFramingContext?

    /// The map fills the section's width.
    private static let mapWidth = Instrument.panelWidth - 32

    /// This clip as the project has it now, for the map's drags.
    private var selectedClip: VideoSegment? {
        guard case .video(let video)? = store.project.segments.first(where: { $0.id == clip.id })
        else { return nil }
        return video
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(label: "CLIP",
                            trailing: String(format: "%.1f S", Ticks.seconds(clip.outputDuration)))
            ScrollView {
                VStack(spacing: 0) {
                    InstrumentSection("Speed") {
                        ChipRow(options: VideoSegment.speeds.map { (value: $0, label: label($0)) },
                                selection: clip.rate) { speed in
                            store.perform(.setClipSpeed(id: clip.id, speed: speed))
                        }
                        Text("Speech keeps its pitch. Titles on the clip stay with the "
                             + "footage they were on.")
                            .font(.system(size: 12))
                            .foregroundStyle(Instrument.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    InstrumentSection("Sound", trailing: clip.volume == 0 ? "Unmute" : "Mute",
                                      onTrailing: {
                        store.perform(.setClipVolume(id: clip.id,
                                                     volume: clip.volume == 0 ? nil : 0))
                    }) {
                        TickSlider(label: "VOLUME", value: (clip.volume ?? 1) * 100,
                                   range: 0...(VideoSegment.maximumVolume * 100),
                                   format: { String(format: "%.0f%%", $0) },
                                   onBegin: { store.beginGesture(named: "Change Clip Volume") },
                                   onChange: { percent in
                                       store.perform(.setClipVolume(id: clip.id,
                                                                    volume: percent / 100))
                                   },
                                   onEnd: { store.endGesture() })
                        Text("Above 100% makes quiet speech louder.")
                            .font(.system(size: 12))
                            .foregroundStyle(Instrument.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    InstrumentSection("Screen") {
                        if let framing {
                            FramingMap(store: store, player: framing.player,
                                       sourceURLs: framing.sourceURLs,
                                       target: { selectedClip },
                                       framedSize: clip.split == nil
                                           ? renderSize : SplitScreen.halfSize(of: renderSize),
                                       frameFaces: framing.frameFaces,
                                       findingFaces: framing.findingFaces, width: Self.mapWidth)
                        }
                        ChipRow(options: [(value: false, label: "WHOLE"),
                                          (value: true, label: "SPLIT")],
                                selection: clip.split != nil) { split in
                            store.perform(.setSegmentSplit(id: clip.id,
                                                           split: split ? SplitScreen() : nil))
                        }
                        Text("Split shows two parts of the clip at once, stacked in a tall or "
                             + "square frame, side by side in a wide one. Drag boxes 1 and 2 "
                             + "in the map to choose the parts; drag a box's corner "
                             + "to zoom that part.")
                            .font(.system(size: 12))
                            .foregroundStyle(Instrument.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    /// "0.5×", "1×", "1.25×".
    private func label(_ speed: Double) -> String {
        let number = speed == speed.rounded() ? String(format: "%.0f", speed)
            : String(format: "%g", speed)
        return number + "\u{00D7}"
    }
}

// MARK: Freeze

/// The selected title card: its colour and length.
private struct CardInspector: View {
    let store: ProjectStore
    let card: CardSegment

    /// Ends the open colour-well gesture once the colour stops changing.
    @State private var pickGestureEnd: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(label: "TITLE CARD",
                            trailing: String(format: "%.1f S", Ticks.seconds(card.duration)))
            ScrollView {
                VStack(spacing: 0) {
                    InstrumentSection("Colour") {
                        ColourRow(colour: card.color,
                                  onSelect: { store.perform(.setCardColor(id: card.id, color: $0)) },
                                  onPick: pick)
                    }
                    InstrumentSection("Length") {
                        TickSlider(label: "LENGTH", value: Ticks.seconds(card.duration),
                                   range: 0.5...15, format: { String(format: "%.1f S", $0) },
                                   onBegin: { store.beginGesture(named: "Change Card Length") },
                                   onChange: { seconds in
                                       store.perform(.setCardDuration(
                                           id: card.id, duration: Ticks.from(seconds: seconds)))
                                   },
                                   onEnd: { store.endGesture() })
                    }
                    Text("Put titles on the card with + > Title while the playhead is "
                         + "on it. Drag its ends on the timeline to change its length.")
                        .font(.system(size: 12))
                        .foregroundStyle(Instrument.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Instrument.divider).frame(height: 1)
                        }
                }
            }
            .scrollIndicators(.never)
        }
        .onChange(of: card.id) { _, _ in endPickGesture() }
        .onDisappear { endPickGesture() }
    }

    /// The colour well reports a drag as a stream of changes with no end
    /// event: the gesture closes 0.6 s after the last one.
    private func pick(_ color: RGBA) {
        if pickGestureEnd == nil { store.beginGesture(named: "Change Card Colour") }
        pickGestureEnd?.cancel()
        store.perform(.setCardColor(id: card.id, color: color))
        pickGestureEnd = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            store.endGesture()
            pickGestureEnd = nil
        }
    }

    private func endPickGesture() {
        guard let task = pickGestureEnd else { return }
        task.cancel()
        pickGestureEnd = nil
        store.endGesture()
    }
}

/// The selected frozen frame: its camera motion's pace, and Reset.
private struct FreezeInspector: View {
    let store: ProjectStore
    let still: StillSegment
    let editCamera: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(label: "FREEZE",
                            trailing: String(format: "%.1f S", Ticks.seconds(still.duration)))
            ScrollView {
                VStack(spacing: 0) {
                    InstrumentSection("Camera") {
                        Text(still.zoom.count > 1
                             ? "The camera glides from the whole frame to where it ends."
                             : "The whole frame shows, still. Choose where the camera ends "
                                + "to add motion.")
                            .font(.system(size: 12))
                            .foregroundStyle(Instrument.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("EDIT CAMERA…", action: editCamera)
                            .buttonStyle(InstrumentButtonStyle(filled: false, fullWidth: true))
                            .help("Or double-click the freeze on the timeline")
                    }
                    if still.zoom.count > 1, let end = still.zoom.last {
                        InstrumentSection("Pace", trailing: "Reset", onTrailing: {
                            store.perform(.setStillZoom(id: still.id, zoom: []))
                        }) {
                            ChipRow(options: [(value: Easing.linear, label: "STEADY"),
                                              (value: .easeInOut, label: "SMOOTH"),
                                              (value: .easeIn, label: "SPEED UP"),
                                              (value: .easeOut, label: "SLOW DOWN")],
                                    selection: end.easing) { easing in
                                var zoom = still.zoom
                                zoom[zoom.count - 1].easing = easing
                                store.perform(.setStillZoom(id: still.id, zoom: zoom))
                            }
                        }
                        InstrumentSection("Hold") {
                            TickSlider(label: "HOLD", value: Ticks.seconds(still.hold),
                                       range: 0...Ticks.seconds(ProjectCommand.maximumStillHold),
                                       format: { String(format: "%.1f S", $0) },
                                       onBegin: { store.beginGesture(named: "Change Freeze Hold") },
                                       onChange: { seconds in
                                           store.perform(.setStillHold(
                                               id: still.id, hold: Ticks.from(seconds: seconds)))
                                       },
                                       onEnd: { store.endGesture() })
                            Text("The last view stays this long after the camera stops; the "
                                 + "freeze grows to fit.")
                                .font(.system(size: 12))
                                .foregroundStyle(Instrument.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("Drag the ends of the freeze on the timeline to change its length.")
                        .font(.system(size: 12))
                        .foregroundStyle(Instrument.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Instrument.divider).frame(height: 1)
                        }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: Music

/// The selected music piece: volume, fades, and Remove.
private struct MusicInspector: View {
    let store: ProjectStore
    let clip: MusicClip

    private static let gesture = "Change Music"

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(label: "MUSIC",
                            trailing: String(format: "%.1f S", Ticks.seconds(clip.duration)))
            ScrollView {
                VStack(spacing: 0) {
                    InstrumentSection("Song") {
                        Text(clip.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Instrument.text)
                            .lineLimit(2)
                        Text("Plays \(time(clip.songRange.start)) to \(time(clip.songRange.end)) "
                             + "of \(time(clip.songDuration)). Drag the ends on the timeline "
                             + "to change which part plays.")
                            .font(.system(size: 12))
                            .foregroundStyle(Instrument.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    InstrumentSection("Level") {
                        VStack(spacing: 14) {
                            slider("VOLUME", value: clip.volume * 100, range: 0...100,
                                   format: { String(format: "%.0f%%", $0) }) { clip, value in
                                clip.volume = value / 100
                            }
                            slider("FADE IN", value: Ticks.seconds(clip.fadeIn), range: 0...5,
                                   format: { String(format: "%.1f S", $0) }) { clip, value in
                                clip.fadeIn = min(Ticks.from(seconds: value),
                                                  clip.duration - clip.fadeOut)
                            }
                            slider("FADE OUT", value: Ticks.seconds(clip.fadeOut), range: 0...5,
                                   format: { String(format: "%.1f S", $0) }) { clip, value in
                                clip.fadeOut = min(Ticks.from(seconds: value),
                                                   clip.duration - clip.fadeIn)
                            }
                        }
                    }
                    Button("REMOVE MUSIC") { store.deleteSelectedMusic() }
                        .buttonStyle(InstrumentButtonStyle(filled: false, fullWidth: true))
                        .padding(16)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Instrument.divider).frame(height: 1)
                        }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func time(_ ticks: Tick) -> String {
        let seconds = Int(Ticks.seconds(ticks).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// A slider whose drag is one undo step; `change` edits a copy of the
    /// piece as it was when the drag began.
    private func slider(_ label: String, value: Double, range: ClosedRange<Double>,
                        format: @escaping (Double) -> String,
                        change: @escaping (inout MusicClip, Double) -> Void) -> some View {
        TickSlider(label: label, value: value, range: range, format: format,
                   onBegin: { store.beginGesture(named: Self.gesture) },
                   onChange: { newValue in
                       guard let current = store.project.music.first(where: { $0.id == clip.id })
                       else { return }
                       var edited = current
                       change(&edited, newValue)
                       store.perform(.setMusic(MusicPlacement.fitFades(edited)))
                   },
                   onEnd: { store.endGesture() })
    }
}

// MARK: Clip transition

/// The selected clip transition: its kind, its length, and Remove.
private struct TransitionInspector: View {
    let store: ProjectStore
    let point: TransitionPoint
    let transition: ClipTransition

    private static let gesture = "Change Transition"
    private static let lengthRange = Ticks.seconds(ClipTransition.minimumDuration)...Ticks
        .seconds(ClipTransition.maximumDuration)

    var body: some View {
        let project = store.project
        VStack(spacing: 0) {
            InspectorHeader(label: "TRANSITION", trailing: place(in: project))
            ScrollView {
                VStack(spacing: 0) {
                    InstrumentSection("Kind") {
                        VStack(spacing: 4) {
                            ForEach(ClipTransitionKind.allCases.filter {
                                $0 != .crossfade || !point.isEdge(in: project)
                            }, id: \.self) { kind in
                                kindRow(kind, in: project)
                            }
                        }
                        Text(point.isEdge(in: project)
                             ? "Plays over the start of the first clip or the end of the last."
                             : "Plays across the cut, half before it and half after. "
                                + "The video's length does not change.")
                            .font(.system(size: 12))
                            .foregroundStyle(Instrument.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    InstrumentSection("Length") {
                        TickSlider(
                            label: "LENGTH", value: Ticks.seconds(transition.duration),
                            range: Self.lengthRange,
                            format: { String(format: "%.1f S", $0) },
                            onBegin: { store.beginGesture(named: Self.gesture) },
                            onChange: { seconds in
                                guard var changed = point.transition(in: store.project) else {
                                    return
                                }
                                changed.duration = min(max(Ticks.from(seconds: seconds),
                                                           ClipTransition.minimumDuration),
                                                       ClipTransition.maximumDuration)
                                store.perform(.setClipTransition(at: point, transition: changed))
                            },
                            onEnd: { store.endGesture() })
                    }
                    Button("REMOVE TRANSITION") { store.deleteSelectedTransition() }
                        .buttonStyle(InstrumentButtonStyle(filled: false, fullWidth: true))
                        .padding(16)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Instrument.divider).frame(height: 1)
                        }
                }
            }
            .scrollIndicators(.never)
        }
    }

    /// A kind as the Transitions palette shows it: its badge and name.
    private func kindRow(_ kind: ClipTransitionKind, in project: Project) -> some View {
        let selected = kind == transition.kind
        return Button {
            var changed = transition
            changed.kind = kind
            store.perform(.setClipTransition(at: point, transition: changed))
        } label: {
            HStack(spacing: 10) {
                TransitionBadgeView(kind: kind)
                Text(kind.name(at: point, in: project))
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Instrument.text)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Instrument.neon)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? Instrument.neon.opacity(0.1) : Instrument.field,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Instrument.neon : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "START", "END" or the cut's time.
    private func place(in project: Project) -> String {
        if case .end = point { return "END" }
        guard let time = point.time(in: project), time > 0 else { return "START" }
        let seconds = Ticks.seconds(time)
        return String(format: "CUT AT %d:%04.1f", Int(seconds) / 60,
                      seconds.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: Titles

/// The editor for one title, or for several at once.
///
/// One title: text, look, landing, motion, size and duration. Text is
/// committed as one `setTitleText` when editing ends (focus leaves the field,
/// the selection changes, or the panel closes), so a whole editing session is
/// a single undo step.
///
/// Several titles: look, customise, size, landing presets and in/out motion,
/// each action or drag applied to all of them as one undo step. Chips whose
/// value differs between the titles show nothing selected; sliders show the
/// first title's value, and a change sets every title to it.
///
/// Look edits under CUSTOMISE change only the selected titles: the first
/// gives them a private copy of their style (`ProjectCommand.titlesLook`).
private struct TitleInspector: View {
    let store: ProjectStore
    /// The selected titles, in project order; never empty.
    let titles: [Title]
    let styles: [TitleStyle]
    /// Built-in and saved library styles; these are never edited in place.
    let libraryStyleIDs: Set<UUID>
    let renderSize: CGSize
    let titleRenderer: TitleRenderer
    let onLibraryChanged: () -> Void

    @State private var draft = ""
    /// The title the draft belongs to, so a late commit never lands elsewhere.
    @State private var draftTitleID: UUID?
    @FocusState private var textFocused: Bool
    /// Whether a lifeline drag has opened its gesture yet.
    @State private var lifelineGestureOpen = false
    /// Each title's duration when a group duration drag began.
    @State private var durationBase: [UUID: Tick] = [:]
    /// The group duration drag's scale; 100 at rest.
    @State private var durationPercent: Double = 100
    @State private var isCustomising = false
    @State private var isPickingStyle = false
    /// Ends the open colour-well gesture once the colour stops changing.
    @State private var pickGestureEnd: Task<Void, Never>?
    /// The name being typed for "Save as new style"; `nil` when not saving.
    @State private var newStyleName: String?
    @State private var saveError: String?

    private static let layoutGesture = "Change Title Layout"
    private static let lookGesture = "Change Title Look"
    private static let durationGesture = "Change Title Duration"
    private static let styleGesture = "Change Title Style"

    /// The first selected title: the one shown when values differ.
    private var title: Title { titles[0] }
    private var ids: Set<UUID> { Set(titles.map(\.id)) }
    private var isGroup: Bool { titles.count > 1 }

    private func style(of title: Title) -> TitleStyle? {
        store.project.styles.first { $0.id == title.styleID }
            ?? styles.first { $0.id == title.styleID }
    }

    private var style: TitleStyle? { style(of: title) }

    /// The value every selected title shares, or `nil` when they differ.
    private func common<Value: Equatable>(_ value: (Title) -> Value?) -> Value? {
        let first = value(title)
        return titles.allSatisfy { value($0) == first } ? first : nil
    }

    /// A style value every selected title shares, or `nil` when they differ.
    private func commonLook<Value: Equatable>(_ value: (TitleStyle) -> Value) -> Value? {
        common { style(of: $0).map(value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isGroup {
                InspectorHeader(label: "\(titles.count) TITLES")
            } else {
                InspectorHeader(label: headerLabel, trailing: rangeLabel)
            }
            ScrollView {
                VStack(spacing: 0) {
                    if !isGroup, title.origin == .autoCaption {
                        Button("SELECT ALL CAPTIONS", action: selectAllCaptions)
                            .buttonStyle(InstrumentButtonStyle(filled: false, fullWidth: true))
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }
                    if !isGroup { textField }
                    stylePicker
                    customise
                    landing
                    motion
                    VStack(spacing: 14) {
                        sizeSlider
                        if isGroup { groupDurationSlider } else { durationSlider }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Instrument.divider).frame(height: 1)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .onAppear { loadDraft() }
        .onChange(of: title.id) { _, _ in
            commitDraft()
            loadDraft()
            endPickGesture()
            newStyleName = nil
            saveError = nil
        }
        .onChange(of: ids) { _, _ in endPickGesture() }
        .onChange(of: title.text) { _, newText in
            // Undo, redo or another editor changed the text; follow it unless typing.
            if !textFocused { draft = newText }
        }
        .onChange(of: textFocused) { _, focused in
            if !focused { commitDraft() }
        }
        .onDisappear {
            commitDraft()
            endPickGesture()
        }
    }

    /// Applies `commands` as one undo step named `name`, or as part of the
    /// gesture already open (a slider drag).
    private func run(_ commands: [ProjectCommand], name: String) {
        guard !commands.isEmpty else { return }
        store.beginGesture(named: name)
        for command in commands { store.perform(command) }
        store.endGesture()
    }

    private func selectAllCaptions() {
        commitDraft()
        store.selectedTitleIDs = AutoCaptions.titleIDs(in: store.project)
        store.selectedSegmentID = nil
    }

    // MARK: Header

    /// "TITLE 02": 1-based position in output order.
    private var headerLabel: String {
        let ordered = store.project.titles
            .map { ($0.id, TimelineMath.titleOutputRange($0, in: store.project)?.start ?? .max) }
            .enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
        let index = ordered.firstIndex { $0.element.0 == title.id } ?? 0
        return String(format: "TITLE %02d", index + 1)
    }

    private var rangeLabel: String? {
        guard let range = TimelineMath.titleOutputRange(title, in: store.project) else { return nil }
        let rate = store.project.source?.frameRate ?? Timecode.fallbackFrameRate
        return Timecode.string(seconds: Ticks.seconds(range.start), frameRate: rate) + " — "
            + Timecode.string(seconds: Ticks.seconds(range.end), frameRate: rate)
    }

    // MARK: Text

    private var textField: some View {
        TextEditor(text: $draft)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Instrument.text)
            .scrollContentBackground(.hidden)
            .padding(.leading, 8)
            .padding(.vertical, 4)
            .frame(height: 62)
            .background(Instrument.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) {
                Rectangle().fill(Instrument.neon).frame(width: 2)
            }
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(textFocused ? Instrument.neonSoft : Instrument.border))
            .focused($textFocused)
            .accessibilityLabel("Title text")
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
    }

    private func loadDraft() {
        draft = title.text
        draftTitleID = title.id
    }

    private func commitDraft() {
        guard let id = draftTitleID,
              let current = store.project.titles.first(where: { $0.id == id }),
              current.text != draft else { return }
        store.perform(.setTitleText(id: id, text: draft))
    }

    // MARK: Style

    /// The current style's name, "CUSTOM" for a title's own look, or
    /// "MIXED" when the titles differ.
    private var styleReadout: String {
        guard let id = common({ $0.styleID }) else { return "MIXED" }
        return styles.first { $0.id == id }?.name.uppercased() ?? "CUSTOM"
    }

    /// Foldable style tiles; a click gives every selected title that style.
    private var stylePicker: some View {
        VStack(spacing: 0) {
            foldHeader("STYLE", readout: styleReadout, isOpen: $isPickingStyle)
            if isPickingStyle {
                StyleGrid(styles: styles, selection: common { $0.styleID }, tileHeight: 64,
                          badge: "SELECTED") {
                    store.perform(.setTitleStyle(ids: ids, style: $0))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
    }

    /// A divider and a clickable mono label with a chevron, for a fold.
    private func foldHeader(_ label: String, readout: String? = nil,
                            isOpen: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Instrument.divider).frame(height: 1)
            Button { isOpen.wrappedValue.toggle() } label: {
                HStack(spacing: 8) {
                    Text(label)
                        .font(Instrument.mono(10))
                        .tracking(1.4)
                        .foregroundStyle(Instrument.dim)
                    Spacer()
                    if let readout {
                        Text(readout)
                            .font(Instrument.mono(10, weight: .medium))
                            .foregroundStyle(Instrument.neon)
                            .lineLimit(1)
                    }
                    Image(systemName: isOpen.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Instrument.dim)
                }
                .padding(.horizontal, 16)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isOpen.wrappedValue ? .isSelected : [])
        }
    }

    // MARK: Customise

    private var customise: some View {
        VStack(spacing: 0) {
            foldHeader("CUSTOMISE", isOpen: $isCustomising)
            if isCustomising, let style {
                lookSections(style)
            }
        }
    }

    /// `style` is the first title's; chips show only values all titles share.
    @ViewBuilder private func lookSections(_ style: TitleStyle) -> some View {
        InstrumentSection("FONT") {
            FontFamilyPicker(fontName: style.fontName) { family in
                setLook { $0.fontName = family }
            }
            ChipRow(options: [(value: FontWeight.light, label: "LIGHT"),
                              (value: .regular, label: "REGULAR"),
                              (value: .medium, label: "MEDIUM"),
                              (value: .semibold, label: "SEMIBOLD"),
                              (value: .bold, label: "BOLD"),
                              (value: .heavy, label: "HEAVY"),
                              (value: .black, label: "BLACK")],
                    selection: commonLook(\.weight)) { weight in setLook { $0.weight = weight } }
        }
        InstrumentSection("COLOUR") {
            ColourRow(colour: style.textColor,
                      onSelect: { colour in setLook { $0.textColor = colour } },
                      onPick: { colour in pickLook { $0.textColor = colour } })
        }
        InstrumentSection("OUTLINE") {
            onOff(commonLook { $0.stroke != nil }) { on in
                setLook { $0.stroke = on ? Stroke(color: RGBA(red: 0, green: 0, blue: 0),
                                                  widthRatio: 0.03) : nil }
            }
            if let stroke = style.stroke {
                ColourRow(colour: stroke.color,
                          onSelect: { colour in setLook { $0.stroke?.color = colour } },
                          onPick: { colour in pickLook { $0.stroke?.color = colour } })
                lookSlider("THICKNESS", value: stroke.widthRatio, range: 0...0.15,
                           format: { String(format: "%.3f", $0) }) { $0.stroke?.widthRatio = $1 }
            }
        }
        InstrumentSection("BOX") {
            onOff(commonLook { $0.background != nil }) { on in
                setLook {
                    $0.background = on
                        ? BackgroundBox(color: RGBA(red: 0, green: 0, blue: 0, alpha: 0.6),
                                        paddingRatio: 0.35, cornerRadiusRatio: 0.15)
                        : nil
                }
            }
            if let box = style.background {
                ColourRow(colour: box.color,
                          onSelect: { colour in setLook { $0.background?.color = colour } },
                          onPick: { colour in pickLook { $0.background?.color = colour } })
                lookSlider("PADDING", value: box.paddingRatio, range: 0...1,
                           format: { String(format: "%.2f", $0) }) {
                    $0.background?.paddingRatio = $1
                }
                lookSlider("CORNERS", value: box.cornerRadiusRatio, range: 0...0.6,
                           format: { String(format: "%.2f", $0) }) {
                    $0.background?.cornerRadiusRatio = $1
                }
                // 0 fits the text; otherwise percent of the frame's width.
                lookSlider("WIDTH", value: (box.widthRatio ?? 0) * 100, range: 0...100,
                           format: { $0 < 1 ? "FIT" : String(format: "%.0f%%", $0) }) {
                    $0.background?.widthRatio = $1 < 1 ? nil : $1 / 100
                }
            }
        }
        InstrumentSection("SHADOW") {
            onOff(commonLook { $0.shadow != nil }) { on in
                setLook {
                    $0.shadow = on
                        ? Shadow(color: RGBA(red: 0, green: 0, blue: 0, alpha: 0.6),
                                 radiusRatio: 0.08, offsetXRatio: 0, offsetYRatio: -0.04)
                        : nil
                }
            }
            if let shadow = style.shadow {
                ColourRow(colour: shadow.color,
                          onSelect: { colour in setLook { $0.shadow?.color = colour } },
                          onPick: { colour in pickLook { $0.shadow?.color = colour } })
                lookSlider("BLUR", value: shadow.radiusRatio, range: 0...0.5,
                           format: { String(format: "%.2f", $0) }) { $0.shadow?.radiusRatio = $1 }
                lookSlider("OFFSET X", value: shadow.offsetXRatio, range: -0.2...0.2,
                           format: { String(format: "%+.2f", $0) }) {
                    $0.shadow?.offsetXRatio = $1
                }
                // Shown with down positive; the model's offset is y-up.
                lookSlider("OFFSET Y", value: -shadow.offsetYRatio, range: -0.2...0.2,
                           format: { String(format: "%+.2f", $0) }) {
                    $0.shadow?.offsetYRatio = -$1
                }
            }
        }
        InstrumentSection("HIGHLIGHT") {
            onOff(commonLook { $0.highlight != nil }) { on in
                setLook {
                    $0.highlight = on
                        ? TitleHighlight(color: RGBA(red: 1, green: 0.84, blue: 0.1)) : nil
                }
            }
            if let highlight = style.highlight {
                ColourRow(colour: highlight.color,
                          onSelect: { colour in setLook { $0.highlight?.color = colour } },
                          onPick: { colour in pickLook { $0.highlight?.color = colour } })
            }
        }
        InstrumentSection("ALIGN") {
            ChipRow(options: [(value: TitleTextAlignment.leading, label: "LEFT"),
                              (value: .center, label: "CENTRE"),
                              (value: .trailing, label: "RIGHT")],
                    selection: common { self.style(of: $0)?.applying($0.styleOverrides).alignment }) {
                alignment in
                setAlignment(alignment)
            }
            lookSlider("WRAP", value: style.maxWidthRatio * 100, range: 20...100,
                       format: { String(format: "%.0f%%", $0) }) { $0.maxWidthRatio = $1 / 100 }
        }
        saveAsNewStyle(style)
    }

    private func onOff(_ isOn: Bool?, set: @escaping (Bool) -> Void) -> some View {
        ChipRow(options: [(value: true, label: "ON"), (value: false, label: "OFF")],
                selection: isOn, onSelect: set)
    }

    /// A slider whose drag is one "Change Title Look" step.
    private func lookSlider(_ label: String, value: Double, range: ClosedRange<Double>,
                            format: @escaping (Double) -> String,
                            change: @escaping (inout TitleStyle, Double) -> Void) -> some View {
        TickSlider(label: label, value: value, range: range, format: format,
                   onBegin: { store.beginGesture(named: Self.lookGesture) },
                   onChange: { newValue in setLook { change(&$0, newValue) } },
                   onEnd: { store.endGesture() })
    }

    /// Applies `change` to the first title's style and gives the result to
    /// every selected title, forking it first unless it is already private
    /// to them.
    private func setLook(_ change: (inout TitleStyle) -> Void) {
        guard let current = style else { return }
        var look = current
        change(&look)
        guard look != current || common({ $0.styleID }) == nil,
              let command = ProjectCommand.titlesLook(look, forTitles: ids, in: store.project,
                                                      libraryStyleIDs: libraryStyleIDs)
        else { return }
        store.perform(command)
    }

    /// Sets the alignment, clears titles' own sides so they follow it, and
    /// moves titles with a custom position across to match, as one step.
    private func setAlignment(_ alignment: TitleTextAlignment) {
        let cleared = titles.map { title -> Title in
            var title = title
            title.styleOverrides?.alignment = nil
            if title.styleOverrides == StyleOverrides() { title.styleOverrides = nil }
            return title
        }
        let moves = FrameRenderer.alignmentMoves(cleared, to: alignment, style: style(of:),
                                                 renderer: titleRenderer,
                                                 renderSize: renderSize)
        let moved = Set(moves.compactMap { move -> UUID? in
            if case .setTitleStyleOverrides(let id, _) = move { id } else { nil }
        })
        let clears = zip(titles, cleared).compactMap { old, new -> ProjectCommand? in
            old.styleOverrides == new.styleOverrides || moved.contains(new.id)
                ? nil : .setTitleStyleOverrides(id: new.id, overrides: new.styleOverrides)
        }
        store.beginGesture(named: Self.lookGesture)
        setLook { $0.alignment = alignment }
        for command in clears + moves { store.perform(command) }
        store.endGesture()
    }

    /// `setLook` for the colour well, which reports a drag as a stream of
    /// changes with no end event: the gesture closes 0.6 s after the last one.
    private func pickLook(_ change: (inout TitleStyle) -> Void) {
        if pickGestureEnd == nil { store.beginGesture(named: Self.lookGesture) }
        pickGestureEnd?.cancel()
        setLook(change)
        pickGestureEnd = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            store.endGesture()
            pickGestureEnd = nil
        }
    }

    private func endPickGesture() {
        guard let task = pickGestureEnd else { return }
        task.cancel()
        pickGestureEnd = nil
        store.endGesture()
    }

    // MARK: Save as new style

    @ViewBuilder private func saveAsNewStyle(_ style: TitleStyle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = newStyleName {
                TextField("Style name", text: Binding(get: { name },
                                                      set: { newStyleName = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Instrument.text)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(Instrument.field, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Instrument.neonSoft))
                    .onSubmit { saveNewStyle() }
                    .accessibilityLabel("New style name")
                HStack(spacing: 8) {
                    Spacer()
                    Button("CANCEL") {
                        newStyleName = nil
                        saveError = nil
                    }
                    .buttonStyle(InstrumentButtonStyle(filled: false))
                    Button("SAVE") { saveNewStyle() }
                        .buttonStyle(InstrumentButtonStyle(filled: true))
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                if let origin = libraryOrigin {
                    Button("UPDATE \(origin.name.uppercased())") { updateLibraryStyle(origin) }
                        .buttonStyle(InstrumentButtonStyle(filled: false, fullWidth: true))
                        .help("Save this look over the library style, and use it for every "
                              + "title on that style in this project")
                }
                Button("SAVE AS NEW STYLE") {
                    let suffix = " (custom)"
                    newStyleName = style.name.hasSuffix(suffix)
                        ? String(style.name.dropLast(suffix.count)) : style.name
                }
                .buttonStyle(InstrumentButtonStyle(filled: false, fullWidth: true))
            }
            if let saveError {
                Text(saveError)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.selectedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    /// The library style the selected titles' shared look was customised
    /// from, if it is still in the library.
    private var libraryOrigin: TitleStyle? {
        guard let look = style, common({ $0.styleID }) == look.id,
              let base = look.basedOn else { return nil }
        return styles.first { $0.id == base }
    }

    /// Writes the first title's look, with its SIZE folded in, over
    /// `origin` in the library, and gives it to the selected titles and every
    /// title on `origin` in this project (one undo step; the library file is
    /// not undone).
    private func updateLibraryStyle(_ origin: TitleStyle) {
        guard let updated = ProjectCommand.updatedLibraryStyle(
            fromTitle: title.id, applyingTo: ids, in: store.project, name: origin.name)
        else { return }
        do {
            try StyleLibrary().save(updated.style)
        } catch {
            saveError = "Could not update the style: \(error.localizedDescription) "
                + "Check that ~/Library/Application Support/TitleCut can be written to, "
                + "then update again."
            return
        }
        onLibraryChanged()
        run(updated.commands, name: Self.styleGesture)
        saveError = nil
    }

    /// Writes the first title's look, with its SIZE folded in, to the library
    /// as a new style and points every selected title at it (one undo step;
    /// the library file is not undone).
    private func saveNewStyle() {
        guard let name = newStyleName?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              let saved = ProjectCommand.newStyle(fromTitle: title.id, applyingTo: ids,
                                                  in: store.project, newID: UUID(), name: name)
        else { return }
        do {
            try StyleLibrary().save(saved.style)
        } catch {
            saveError = "Could not save the style: \(error.localizedDescription) "
                + "Check that ~/Library/Application Support/TitleCut can be written to, "
                + "then save again."
            return
        }
        onLibraryChanged()
        run(saved.commands, name: Self.styleGesture)
        newStyleName = nil
        saveError = nil
    }

    // MARK: Landing

    /// A preset height on the frame, a row of the placement grid.
    private enum PlacementRow: CaseIterable {
        case top, center, lowerThird, bottom

        var position: NormalizedPosition {
            switch self {
            case .top: .top
            case .center: .center
            case .lowerThird: .lowerThird
            case .bottom: .bottom
            }
        }

        var label: String {
            switch self {
            case .top: "TOP"
            case .center: "CENTRE"
            case .lowerThird: "LOWER 3RD"
            case .bottom: "BOTTOM"
            }
        }
    }

    /// A cell of the placement grid: a preset height at one side.
    private struct Placement: Hashable {
        var row: PlacementRow
        var alignment: TitleTextAlignment
    }

    /// Where a title shows, as a grid cell; `nil` for a custom position,
    /// which no cell shows.
    private func placement(_ title: Title) -> Placement? {
        guard let effective = style(of: title)?.applying(title.styleOverrides),
              let row = PlacementRow.allCases.first(where: { $0.position == effective.position })
        else { return nil }
        return Placement(row: row, alignment: effective.alignment)
    }

    /// Whether a title shows where its style puts it.
    private func usesStylePlacement(_ title: Title) -> Bool {
        title.styleOverrides?.position == nil && title.styleOverrides?.alignment == nil
    }

    /// The title's resting centre, normalised with a top-left origin. Preset
    /// positions are laid out as the compositor draws them.
    private var restingCentre: CGPoint {
        guard let style else { return CGPoint(x: 0.5, y: 0.5) }
        let effective = style.applying(title.styleOverrides)
        if case let .custom(x, y) = effective.position { return CGPoint(x: x, y: y) }
        guard renderSize.width > 0, renderSize.height > 0,
              let rendered = titleRenderer.render(title, style: style, renderSize: renderSize)
        else { return CGPoint(x: 0.5, y: 0.5) }
        let frame = FrameRenderer.titleFrame(contentSize: rendered.contentRect.size,
                                             position: effective.position,
                                             alignment: effective.alignment,
                                             renderSize: renderSize)
        return CGPoint(x: frame.midX / renderSize.width, y: frame.midY / renderSize.height)
    }

    /// Target pad at the first title's resting centre, a grid of preset
    /// heights by side, and STYLE to go back to the style's placement. A
    /// drag or cell sets every selected title.
    private var landing: some View {
        let hasOverride = !titles.allSatisfy(usesStylePlacement)
        return InstrumentSection("LANDING", trailing: hasOverride ? "RESET" : nil,
                                 onTrailing: hasOverride ? { setPlacement(nil) } : nil) {
            VStack(alignment: .leading, spacing: 10) {
                TargetPad(position: restingCentre,
                          aspect: renderSize.height > 0
                              ? renderSize.width / renderSize.height : 16 / 9,
                          onBegin: { store.beginGesture(named: Self.layoutGesture) },
                          onChange: { point in
                              setPosition(.custom(x: point.x, y: point.y))
                          },
                          onEnd: { store.endGesture() })
                let selected = common(placement)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(PlacementRow.allCases, id: \.self) { row in
                        HStack(spacing: 8) {
                            Text(row.label)
                                .font(Instrument.mono(10.5))
                                .foregroundStyle(Instrument.dim)
                                .frame(width: 70, alignment: .leading)
                            ChipRow(options: [
                                (value: Placement(row: row, alignment: .leading), label: "LEFT"),
                                (value: Placement(row: row, alignment: .center), label: "CENTRE"),
                                (value: Placement(row: row, alignment: .trailing), label: "RIGHT"),
                            ], selection: selected) { setPlacement($0) }
                        }
                    }
                }
                ChipRow(options: [(value: true, label: "STYLE")],
                        selection: titles.allSatisfy(usesStylePlacement) ? true : nil) { _ in
                    setPlacement(nil)
                }
            }
        }
    }

    /// Sets every selected title's height and side; `nil` returns to the
    /// style's placement.
    private func setPlacement(_ placement: Placement?) {
        setOverrides { _, overrides in
            overrides.position = placement?.row.position
            overrides.alignment = placement?.alignment
        }
    }

    /// Sets every selected title's position override; `nil` returns to the
    /// style's position.
    private func setPosition(_ position: NormalizedPosition?) {
        setOverrides { _, overrides in overrides.position = position }
    }

    /// Changes every selected title's overrides as one step, clearing them
    /// entirely where nothing is left overridden.
    private func setOverrides(_ change: (Title, inout StyleOverrides) -> Void) {
        let commands = titles.compactMap { title -> ProjectCommand? in
            var overrides = title.styleOverrides ?? StyleOverrides()
            change(title, &overrides)
            let next = overrides == StyleOverrides() ? nil : overrides
            return next == title.styleOverrides
                ? nil : .setTitleStyleOverrides(id: title.id, overrides: next)
        }
        run(commands, name: Self.layoutGesture)
    }

    // MARK: Motion

    /// The lifeline, drawn for the first title; a drag sets every selected
    /// title's in and out durations. Then the IN and OUT cards.
    private var motion: some View {
        InstrumentSection("LIFELINE") {
            VStack(spacing: 12) {
                Lifeline(total: Ticks.seconds(title.duration),
                         inDuration: Ticks.seconds(title.transitionIn.duration),
                         outDuration: Ticks.seconds(title.transitionOut.duration),
                         onBegin: { lifelineGestureOpen = false },
                         onChange: { inSeconds, outSeconds in
                             setLifeline(in: inSeconds, out: outSeconds)
                         },
                         onEnd: {
                             if lifelineGestureOpen { store.endGesture() }
                             lifelineGestureOpen = false
                         })
                HStack(alignment: .top, spacing: 8) {
                    TransitionCard(label: "IN", transitions: titles.map(\.transitionIn)) {
                        setTransitions(isIn: true, $0)
                    }
                    TransitionCard(label: "OUT", transitions: titles.map(\.transitionOut)) {
                        setTransitions(isIn: false, $0)
                    }
                }
            }
        }
    }

    /// Changes the in or out transition of every selected title as one step.
    private func setTransitions(isIn: Bool, _ change: (inout TitleTransition) -> Void) {
        let commands = titles.compactMap { title -> ProjectCommand? in
            let current = isIn ? title.transitionIn : title.transitionOut
            var next = current
            change(&next)
            guard next != current else { return nil }
            return isIn ? .setTitleTransitionIn(id: title.id, transition: next)
                        : .setTitleTransitionOut(id: title.id, transition: next)
        }
        run(commands, name: isIn ? "Change Transition In" : "Change Transition Out")
    }

    /// One drag moves one end. The gesture opens on the first change, named
    /// for whichever transition that change touches.
    ///
    /// Every selected title gets the dragged end's duration, shortened where
    /// needed to fit inside a shorter title.
    private func setLifeline(in inSeconds: Double, out outSeconds: Double) {
        let inTicks = max(Ticks.from(seconds: inSeconds), 0)
        let outTicks = max(Ticks.from(seconds: outSeconds), 0)
        // Only the end being dragged is copied to the other titles.
        let movesIn = inTicks != title.transitionIn.duration
        let movesOut = outTicks != title.transitionOut.duration
        let commands: [ProjectCommand] = titles.flatMap { title -> [ProjectCommand] in
            var transitionIn = title.transitionIn
            var transitionOut = title.transitionOut
            if movesIn { transitionIn.duration = min(inTicks, title.duration) }
            if movesOut {
                transitionOut.duration = min(outTicks, title.duration - transitionIn.duration)
            }
            return [
                transitionIn != title.transitionIn
                    ? .setTitleTransitionIn(id: title.id, transition: transitionIn) : nil,
                transitionOut != title.transitionOut
                    ? .setTitleTransitionOut(id: title.id, transition: transitionOut) : nil,
            ].compactMap { $0 }
        }
        guard let first = commands.first else { return }
        if !lifelineGestureOpen {
            store.beginGesture(named: first.actionName)
            lifelineGestureOpen = true
        }
        for command in commands { store.perform(command) }
    }

    // MARK: Size and duration

    /// Percent of each title's own style size; shows the first title's.
    private var sizeSlider: some View {
        let base = style?.fontSizeRatio ?? 0
        let ratio = title.styleOverrides?.fontSizeRatio ?? base
        return TickSlider(label: "SIZE",
                          value: base > 0 ? ratio / base * 100 : 100,
                          range: 25...300,
                          format: { String(format: "%.0f%%", $0) },
                          onBegin: { store.beginGesture(named: Self.layoutGesture) },
                          onChange: { percent in
                              setOverrides { title, overrides in
                                  guard let base = style(of: title)?.fontSizeRatio, base > 0
                                  else { return }
                                  overrides.fontSizeRatio = base * percent / 100
                              }
                          },
                          onEnd: { store.endGesture() })
    }

    private var durationSlider: some View {
        let seconds = Ticks.seconds(title.duration)
        return TickSlider(label: "DURATION",
                          value: seconds,
                          range: 0.1...max(15, seconds),
                          format: { String(format: "%.2f S", $0) },
                          onBegin: { store.beginGesture(named: Self.durationGesture) },
                          onChange: { value in
                              store.perform(.setTitleDuration(
                                  id: title.id, duration: max(Ticks.from(seconds: value), 1)))
                          },
                          onEnd: { store.endGesture() })
    }

    /// Several titles: scales every title's duration by the same percentage
    /// of its length when the drag began. Rests at 100%.
    private var groupDurationSlider: some View {
        TickSlider(label: "DURATION",
                   value: durationPercent,
                   range: 25...400,
                   format: { String(format: "%.0f%%", $0) },
                   onBegin: {
                       durationBase = Dictionary(uniqueKeysWithValues:
                           titles.map { ($0.id, $0.duration) })
                       store.beginGesture(named: Self.durationGesture)
                   },
                   onChange: { percent in
                       durationPercent = percent
                       for (id, base) in durationBase {
                           let scaled = Tick((Double(base) * percent / 100).rounded())
                           store.perform(.setTitleDuration(
                               id: id, duration: max(scaled, Ticks.perSecond / 10)))
                       }
                   },
                   onEnd: {
                       store.endGesture()
                       durationBase = [:]
                       durationPercent = 100
                   })
    }
}

/// Kind, slide edge and easing for the in or out transition of one or more
/// titles. A chip shows a value only when every title has it; a choice
/// changes only that part of each title's transition.
private struct TransitionCard: View {
    let label: String
    /// One per selected title.
    let transitions: [TitleTransition]
    let change: ((inout TitleTransition) -> Void) -> Void

    private enum Kind: Hashable {
        case none, fade, slide, scale, typewriter
    }

    private static let defaultDuration: Tick = 180

    private static func kind(of transition: TitleTransition) -> Kind {
        switch transition.kind {
        case .none: .none
        case .fade: .fade
        case .slide: .slide
        case .scale: .scale
        case .typewriter: .typewriter
        }
    }

    private static func edge(of transition: TitleTransition) -> SlideEdge? {
        if case .slide(let edge) = transition.kind { return edge }
        return nil
    }

    private func common<Value: Equatable>(_ value: (TitleTransition) -> Value) -> Value? {
        guard let first = transitions.first.map(value) else { return nil }
        return transitions.allSatisfy { value($0) == first } ? first : nil
    }

    var body: some View {
        let kind = common(Self.kind)
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(Instrument.mono(10))
                .tracking(1.2)
                .foregroundStyle(Instrument.dim)
            ChipRow(options: [(value: Kind.none, label: "NONE"), (value: .fade, label: "FADE"),
                              (value: .slide, label: "SLIDE"), (value: .scale, label: "SCALE"),
                              (value: .typewriter, label: "TYPE")],
                    selection: kind) { setKind($0) }
            if kind == .slide {
                ChipRow(options: [(value: SlideEdge.leading, label: "←"),
                                  (value: .trailing, label: "→"),
                                  (value: .top, label: "↑"),
                                  (value: .bottom, label: "↓")],
                        selection: common(Self.edge) ?? nil) { edge in
                    change { $0.kind = .slide(edge: edge) }
                }
            }
            ChipRow(options: [(value: Easing.linear, label: "LINEAR"),
                              (value: .easeIn, label: "EASE IN"),
                              (value: .easeOut, label: "EASE OUT"),
                              (value: .easeInOut, label: "IN-OUT")],
                    selection: common(\.easing)) { easing in change { $0.easing = easing } }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Instrument.border))
    }

    /// A slide keeps each title's edge, or enters from the bottom.
    private func setKind(_ newKind: Kind) {
        change { transition in
            switch newKind {
            case .none: transition.kind = .none
            case .fade: transition.kind = .fade
            case .slide: transition.kind = .slide(edge: Self.edge(of: transition) ?? .bottom)
            case .scale: transition.kind = .scale
            case .typewriter: transition.kind = .typewriter
            }
            if newKind != .none, transition.duration <= 0 {
                transition.duration = Self.defaultDuration
            }
        }
    }
}

/// Mono uppercase button: neon outline, or neon fill for the main action.
struct InstrumentButtonStyle: ButtonStyle {
    var filled: Bool
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Instrument.mono(11, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(filled ? Instrument.onNeon : Instrument.neon)
            .padding(.horizontal, 12)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: 30)
            .background(filled ? Instrument.neon : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(filled ? .clear : Instrument.neon))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}
