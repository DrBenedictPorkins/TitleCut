import AppKit
import Foundation
import TitleCutCore

/// Clip, title and music tools: each is one undo step through the same
/// `ProjectCommand`s the UI uses.
extension MCPSession {
    // MARK: Clips

    func clipTool(_ tool: String, _ args: MCPArguments) async -> MCPReply {
        if tool == "split_at" {
            guard let at = args.ticks("seconds") else { return missing("seconds") }
            let id = UUID()
            return store.perform(.splitSegment(atOutputTime: at, newSegmentID: id))
                ? .text("Split at \(format(Ticks.seconds(at))) s; the second part is \(id.uuidString).")
                : .error("Nothing to split at \(format(Ticks.seconds(at))) s: it is outside the "
                         + "timeline or on a cut.")
        }
        if tool == "freeze_frame" { return await freeze(args) }
        if tool == "insert_card" { return insertCard(args) }
        guard let id = args.id("id") else { return missing("id (a segment ID)") }
        guard let segment = project.segments.first(where: { $0.id == id }) else {
            return .error("No segment has the ID \(id.uuidString).")
        }
        switch tool {
        case "delete_segment":
            return store.perform(.deleteSegment(id: id))
                ? .text("Deleted the segment.") : .error("The segment could not be deleted.")
        case "move_segment":
            guard let to = args.ticks("to_seconds") else { return missing("to_seconds") }
            return store.perform(.moveSegment(id: id, toOutputStart: to))
                ? .json(.object(["start": .seconds(TimelineMath.segmentRange(id, in: project)?
                    .start ?? 0)]))
                : .error("Gaps cannot be moved.")
        case "trim_segment":
            guard let start = args.ticks("source_start"), let end = args.ticks("source_end"),
                  end > start else { return .error("Give source_start and a later source_end.") }
            return store.perform(.trimSegment(id: id,
                                              sourceRange: TickRange(start: start,
                                                                     duration: end - start)))
                ? .text("Trimmed.")
                : .error("Refused: only video clips trim, within the source video, and at "
                         + "least one frame long.")
        case "set_framing":
            let x = args.number("framing"), y = args.number("y"), zoom = args.number("zoom")
            guard x != nil || y != nil || zoom != nil else {
                return missing("framing, y or zoom")
            }
            guard case .video(let video) = segment else {
                return .error("Only video clips have framing.")
            }
            var frame = video.frame
            if let x { frame.x = x }
            if let y { frame.y = y }
            if let zoom { frame.zoom = zoom }
            frame = frame.clamped
            store.perform(.setSegmentFrame(id: id, frame: frame))
            return .text("Framing x \(format(frame.x)), y \(format(frame.y)), "
                         + "zoom \(format(frame.zoom))."
                         + (video.split == nil ? ""
                            : " The clip is split screen, which shows its halves' framing "
                              + "instead; use set_split."))
        case "set_split":
            guard case .video(let video) = segment else {
                return .error("Only video clips can be split screen.")
            }
            guard args.bool("split") ?? true else {
                store.perform(.setSegmentSplit(id: id, split: nil))
                return .text("The clip shows whole.")
            }
            var split = video.split ?? SplitScreen()
            if let x = args.number("first") { split.first.x = x }
            if let y = args.number("first_y") { split.first.y = y }
            if let zoom = args.number("first_zoom") { split.first.zoom = zoom }
            if let x = args.number("second") { split.second.x = x }
            if let y = args.number("second_y") { split.second.y = y }
            if let zoom = args.number("second_zoom") { split.second.zoom = zoom }
            split.first = split.first.clamped
            split.second = split.second.clamped
            store.perform(.setSegmentSplit(id: id, split: split))
            func describe(_ frame: ClipFraming) -> String {
                "x \(format(frame.x)), y \(format(frame.y)), zoom \(format(frame.zoom))"
            }
            return .text("Split screen: first half \(describe(split.first)); "
                         + "second \(describe(split.second)).")
        case "set_clip":
            guard case .video(let video) = segment else {
                return .error("Only video clips have a speed and volume.")
            }
            var commands: [ProjectCommand] = []
            if let speed = args.number("speed") {
                guard VideoSegment.speeds.contains(speed) else {
                    return .error("speed is one of 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 10.")
                }
                if speed != video.rate { commands.append(.setClipSpeed(id: id, speed: speed)) }
            }
            if let volume = args.number("volume") {
                guard (0...VideoSegment.maximumVolume).contains(volume) else {
                    return .error("volume is 0...2 (1 is unchanged, 0 mutes).")
                }
                if volume != (video.volume ?? 1) {
                    commands.append(.setClipVolume(id: id, volume: volume))
                }
            }
            guard args.number("speed") != nil || args.number("volume") != nil else {
                return missing("speed or volume")
            }
            if !commands.isEmpty, !perform(commands, name: "Change Clip") {
                return .error("Refused: at that speed the clip would be shorter than a frame.")
            }
            guard let range = TimelineMath.segmentRange(id, in: project),
                  case .video(let changed)? = project.segments.first(where: { $0.id == id })
            else { return .text("Done.") }
            return .json(.object(["speed": .number(changed.rate),
                                  "volume": .number(changed.volume ?? 1),
                                  "start": .seconds(range.start), "end": .seconds(range.end)]))
        case "set_freeze_length":
            guard let length = args.ticks("seconds") else { return missing("seconds") }
            return store.perform(.setStillDuration(id: id, duration: length))
                ? .text("The freeze is \(format(Ticks.seconds(length))) s long.")
                : .error("Refused: only freezes have a length set this way, of at least a frame.")
        case "set_card":
            guard case .card = segment else { return .error("Only cards are set this way.") }
            var commands: [ProjectCommand] = []
            if let hex = args.string("color") {
                guard let color = Self.rgba(hex) else {
                    return .error("color is #RRGGBB or #RRGGBBAA.")
                }
                commands.append(.setCardColor(id: id, color: color))
            }
            if let length = args.ticks("duration") {
                guard length >= ProjectCommand.minimumSegmentDuration(in: project) else {
                    return .error("duration must be at least one frame.")
                }
                commands.append(.setCardDuration(id: id, duration: length))
            }
            guard !commands.isEmpty else { return .error("Give color, duration or both.") }
            perform(commands, name: commands.count == 1 ? commands[0].actionName : "Change Card")
            let updated = project.segments.first { $0.id == id }
            guard case .card(let now)? = updated else { return .error("The card is gone.") }
            return .text("The card is \(format(Ticks.seconds(now.duration))) s, "
                         + "\(Self.hex(now.color)).")
        case "set_camera", "reset_camera":
            guard case .still(let still) = segment else { return .error("Only freezes have a camera.") }
            if tool == "reset_camera" {
                store.perform(.setStillZoom(id: id, zoom: []))
                return .text("The freeze shows the whole frame, still.")
            }
            guard let x = args.number("center_x"), let y = args.number("center_y"),
                  let scale = args.number("scale") else {
                return .error("Give center_x, center_y and scale.")
            }
            guard let easing = Self.easing(pace: args.string("pace")) else {
                return .error("pace is steady, smooth, speed_up or slow_down.")
            }
            let start = ZoomKeyframe(time: 0, center: CGPoint(x: 0.5, y: 0.5), scale: 1,
                                     easing: .easeInOut)
            let hold = args.ticks("hold") ?? still.hold
            guard (0...ProjectCommand.maximumStillHold).contains(hold) else {
                return .error("hold is 0 to 10 seconds.")
            }
            let motion = still.duration - still.hold
            let end = ZoomKeyframe(time: motion,
                                   center: CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)),
                                   scale: min(max(scale, 0.1), 8), easing: easing)
            perform([.setStillZoom(id: id, zoom: [start, end]),
                     .setStillHold(id: id, hold: hold)], name: "Change Camera Motion")
            return .text("The camera goes from the whole frame to (\(format(end.center.x)), "
                         + "\(format(end.center.y))) at \(format(end.scale))x over "
                         + "\(format(Ticks.seconds(motion))) s, then holds "
                         + "\(format(Ticks.seconds(hold))) s.")
        default:
            return .error("Unknown clip tool \(tool).")
        }
    }

    /// insert_card: a title card at a time, black unless `color` is given.
    private func insertCard(_ args: MCPArguments) -> MCPReply {
        guard let at = args.ticks("seconds") else { return missing("seconds") }
        let length = args.ticks("duration") ?? 3 * Ticks.perSecond
        var color = RGBA(red: 0, green: 0, blue: 0)
        if let hex = args.string("color") {
            guard let parsed = Self.rgba(hex) else { return .error("color is #RRGGBB or #RRGGBBAA.") }
            color = parsed
        }
        let id = UUID()
        guard store.perform(.insertCard(CardSegment(id: id, duration: length, color: color),
                                        splitID: UUID(), atOutputTime: at)) else {
            return .error("The card could not be inserted: the timeline is empty, or the "
                          + "duration is under one frame.")
        }
        let start = TimelineMath.segmentRange(id, in: project)?.start ?? at
        return .text("Inserted a \(format(Ticks.seconds(length))) s card at "
                     + "\(format(Ticks.seconds(start))) s; the card is \(id.uuidString). "
                     + "Add titles on it with add_title.")
    }

    /// freeze_frame: grabs what the frame shows, with the clip's framing or
    /// halves.
    private func freeze(_ args: MCPArguments) async -> MCPReply {
        guard let at = args.ticks("seconds") else { return missing("seconds") }
        let length = args.ticks("duration") ?? 3 * Ticks.perSecond
        guard let (clip, sourceTime) = TimelineMath.sourcePoint(at, in: project),
              let source = project.source(of: clip) else {
            return .error("There is no video clip at \(format(Ticks.seconds(at))) s to freeze.")
        }
        guard let url = sourceURLs()[clip.sourceID] else { return missingVideo }
        let crops = StillFiles.visibleRects(sourceSize: source.naturalSize,
                                            renderSize: renderSize(), clip: clip)
        do {
            let still = try await StillFiles.grab(from: url, at: sourceTime, id: UUID(),
                                                  crops: crops,
                                                  stacked: SplitScreen.isStacked(renderSize()))
            let id = UUID()
            guard store.perform(.insertStill(still, segmentID: id, splitID: UUID(),
                                             atOutputTime: at, duration: length)) else {
                return .error("The freeze could not be inserted there.")
            }
            return .text("Froze \(format(Ticks.seconds(length))) s at "
                         + "\(format(Ticks.seconds(at))) s; the freeze is \(id.uuidString).")
        } catch {
            return .error("The frame could not be frozen: \(error.localizedDescription)")
        }
    }

    // MARK: Clip transitions

    func transitionTool(_ tool: String, _ args: MCPArguments) -> MCPReply {
        guard let at = args.string("at") else { return missing("at") }
        let point: TransitionPoint
        switch at {
        case "start":
            guard let first = project.segments.first else { return .error("The timeline is empty.") }
            point = .before(first.id)
        case "end":
            guard !project.segments.isEmpty else { return .error("The timeline is empty.") }
            point = .end
        default:
            guard let id = UUID(uuidString: at), project.segments.contains(where: { $0.id == id })
            else {
                return .error("at is start, end, or the ID of a segment in get_project.")
            }
            point = .before(id)
        }
        let place = pointName(point)
        if tool == "remove_transition" {
            return store.perform(.setClipTransition(at: point, transition: nil))
                ? .text("Removed the transition at \(place).")
                : .error("There is no transition at \(place).")
        }
        guard let kindName = args.string("kind") else { return missing("kind") }
        guard let kind = Self.clipTransitionKind(kindName) else {
            return .error("kind is dip_to_black, dip_to_white or crossfade.")
        }
        if kind == .crossfade, point.isEdge(in: project) {
            return .error("A crossfade needs a clip on both sides: use it at a cut. At the "
                          + "start or end use dip_to_black or dip_to_white.")
        }
        let existing = point.transition(in: project)?.duration ?? ClipTransition.defaultDuration
        let duration = args.ticks("duration") ?? existing
        guard (ClipTransition.minimumDuration...ClipTransition.maximumDuration)
            .contains(duration) else { return .error("duration is 0.1 to 5 seconds.") }
        let transition = ClipTransition(kind: kind, duration: duration)
        if point.transition(in: project) != transition {
            store.perform(.setClipTransition(at: point, transition: transition))
        }
        return .text("\(kind.name(at: point, in: project)) at \(place), "
                     + "\(format(Ticks.seconds(duration))) s.")
    }

    static func clipTransitionKind(_ name: String) -> ClipTransitionKind? {
        switch name {
        case "dip_to_black": .dipToBlack
        case "dip_to_white": .dipToWhite
        case "crossfade": .crossfade
        default: nil
        }
    }

    static func clipTransitionName(_ kind: ClipTransitionKind) -> String {
        switch kind {
        case .dipToBlack: "dip_to_black"
        case .dipToWhite: "dip_to_white"
        case .crossfade: "crossfade"
        }
    }

    /// "the start", "the end" or "the cut at 12.3 s".
    func pointName(_ point: TransitionPoint) -> String {
        if case .end = point { return "the end" }
        guard let time = point.time(in: project), time > 0 else { return "the start" }
        return "the cut at \(format(Ticks.seconds(time))) s"
    }

    func clipTransitionJSON(_ transition: ClipTransition?) -> JSONValue {
        guard let transition else { return .null }
        return .object(["kind": .string(Self.clipTransitionName(transition.kind)),
                        "duration": .seconds(transition.duration)])
    }

    // MARK: Titles

    /// Library styles first, then the project's own, by name (any case) or ID.
    func style(named key: String?) -> TitleStyle? {
        let all = libraryStyles() + StyleLibrary.builtIns + project.styles
        guard let key else { return all.first { $0.id == defaultStyleID() } }
        if let id = UUID(uuidString: key) { return all.first { $0.id == id } }
        return all.first { $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame }
    }

    func titleTool(_ tool: String, _ args: MCPArguments) -> MCPReply {
        switch tool {
        case "list_styles":
            return .json(libraryStyles().map { style in
                JSONValue.object(["id": .string(style.id.uuidString), "name": .string(style.name),
                                  "default": .bool(style.id == defaultStyleID()),
                                  "look": json(style)])
            })
        case "add_title":
            guard let text = args.string("text") else { return missing("text") }
            guard let at = args.ticks("seconds") else { return missing("seconds") }
            guard let style = style(named: args.string("style")) else {
                return .error("No style is named \(args.string("style") ?? ""). list_styles "
                              + "names them.")
            }
            let id = UUID()
            let duration = args.ticks("duration") ?? ProjectCommand.defaultTitleDuration
            return store.perform(.addTitle(id: id, text: text, atOutputTime: at, style: style,
                                           duration: max(duration, Ticks.perSecond / 10)))
                ? .text("Added title \(id.uuidString).")
                : .error("No title can start at \(format(Ticks.seconds(at))) s: it is past the end.")
        case "update_title":
            return updateTitle(args)
        case "delete_titles":
            let ids = Set((args.strings("ids") ?? []).compactMap(UUID.init(uuidString:)))
            guard !ids.isEmpty else { return missing("ids") }
            return store.perform(.deleteTitles(ids: ids))
                ? .text("Deleted.") : .error("None of those titles exist.")
        case "duplicate_titles":
            let ids = (args.strings("ids") ?? []).compactMap(UUID.init(uuidString:))
            guard !ids.isEmpty else { return missing("ids") }
            let copies = Dictionary(uniqueKeysWithValues: ids.map { ($0, UUID()) })
            return store.perform(.duplicateTitles(newIDs: copies))
                ? .json(.object(copies.reduce(into: [:]) {
                    $0[$1.key.uuidString] = .string($1.value.uuidString)
                }))
                : .error("Refused: a title is missing, or no copy fits before the end.")
        case "set_titles_style":
            let ids = Set((args.strings("ids") ?? []).compactMap(UUID.init(uuidString:)))
            guard !ids.isEmpty else { return missing("ids") }
            guard let style = style(named: args.string("style")) else {
                return .error("No style is named \(args.string("style") ?? "").")
            }
            return store.perform(.setTitleStyle(ids: ids, style: style))
                ? .text("Styled \(ids.count) title(s) \(style.name).")
                : .error("Nothing changed: the titles are missing or already have that style.")
        default:
            return .error("Unknown title tool \(tool).")
        }
    }

    private static let positions: [String: NormalizedPosition?] = [
        "style": nil, "top": .top, "center": .center, "lower_third": .lowerThird,
        "bottom": .bottom,
    ]

    private func updateTitle(_ args: MCPArguments) -> MCPReply {
        guard let id = args.id("id"),
              let title = project.titles.first(where: { $0.id == id }) else {
            return .error("No title has that id. get_project lists them.")
        }
        var commands: [ProjectCommand] = []
        if let text = args.string("text"), text != title.text {
            commands.append(.setTitleText(id: id, text: text))
        }
        if let start = args.ticks("start") {
            commands.append(.moveTitle(id: id, toOutputStart: max(start, 0)))
        }
        if let duration = args.ticks("duration") {
            commands.append(.setTitleDuration(id: id, duration: max(duration, Ticks.perSecond / 10)))
        }

        // Layout overrides: position and size.
        var overrides = title.styleOverrides ?? StyleOverrides()
        if let name = args.string("position") {
            if name == "custom" {
                guard let x = args.number("x"), let y = args.number("y") else {
                    return .error("position custom needs x and y, 0...1.")
                }
                overrides.position = .custom(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
            } else if let preset = Self.positions[name] {
                overrides.position = preset
            } else {
                return .error("position is style, top, center, lower_third, bottom or custom.")
            }
        }
        if let percent = args.number("size_percent"),
           let base = project.styles.first(where: { $0.id == title.styleID })?.fontSizeRatio {
            let clamped = min(max(percent, 25), 300)
            overrides.fontSizeRatio = clamped == 100 ? nil : base * clamped / 100
        }
        // align sets the style's alignment, so the title drops a side of its own.
        if args.has("align") { overrides.alignment = nil }
        // align also moves a title with a custom position, as ALIGN does in the app.
        if args.string("position") == nil,
           let alignment = ["left": TextAlignment.leading, "center": .center,
                            "right": .trailing][args.string("align") ?? ""],
           let style = project.styles.first(where: { $0.id == title.styleID }) {
            var moved = title
            moved.styleOverrides = overrides
            if let move = FrameRenderer.alignmentMoves([moved], to: alignment,
                                                       style: { _ in style },
                                                       renderer: TitleRenderer(),
                                                       renderSize: renderSize()).first,
               case .setTitleStyleOverrides(_, let next?) = move {
                overrides.position = next.position
            }
        }
        let nextOverrides = overrides == StyleOverrides() ? nil : overrides
        if nextOverrides != title.styleOverrides {
            commands.append(.setTitleStyleOverrides(id: id, overrides: nextOverrides))
        }

        for isIn in [true, false] {
            let key = isIn ? "transition_in" : "transition_out"
            let current = isIn ? title.transitionIn : title.transitionOut
            var next = current
            if let name = args.string(key) {
                switch name {
                case "none": next.kind = .none
                case "fade": next.kind = .fade
                case "slide": next.kind = .slide(edge: .bottom)
                case "scale": next.kind = .scale
                case "typewriter": next.kind = .typewriter
                default: return .error("\(key) is none, fade, slide, scale or typewriter.")
                }
                if next.kind != .none, next.duration <= 0 { next.duration = 180 }
            }
            if let seconds = args.ticks(key + "_seconds") { next.duration = max(seconds, 0) }
            if next != current {
                commands.append(isIn ? .setTitleTransitionIn(id: id, transition: next)
                                     : .setTitleTransitionOut(id: id, transition: next))
            }
        }

        switch lookCommand(for: title, args) {
        case .failure(let message): return .error(message)
        case .success(let command?): commands.append(command)
        case .success(nil): break
        }

        guard !commands.isEmpty else { return .text("Nothing to change.") }
        perform(commands, name: "Edit Title")
        return .text("Updated the title.")
    }

    private enum LookResult {
        case success(ProjectCommand?)
        case failure(String)
    }

    /// The look fields as a private style for the title, as Customise does.
    private func lookCommand(for title: Title, _ args: MCPArguments) -> LookResult {
        let keys = ["font", "weight", "color", "outline_color", "outline_width", "box_color",
                    "shadow", "align", "highlight_color"]
        guard keys.contains(where: args.has),
              var look = project.styles.first(where: { $0.id == title.styleID }) else {
            return .success(nil)
        }
        if let font = args.string("font") { look.fontName = font }
        if let weight = args.string("weight") {
            guard let value = FontWeight(rawValue: weight) else { return .failure("Unknown weight.") }
            look.weight = value
        }
        if let hex = args.string("color") {
            guard let color = Self.rgba(hex) else { return .failure("color is #RRGGBB.") }
            look.textColor = color
        }
        if args.has("outline_color") || args.has("outline_width") {
            let width = args.number("outline_width") ?? look.stroke?.widthRatio ?? 0.05
            let color = args.string("outline_color").flatMap(Self.rgba)
                ?? look.stroke?.color ?? RGBA(red: 0, green: 0, blue: 0)
            look.stroke = width > 0 ? Stroke(color: color, widthRatio: width) : nil
        }
        if let hex = args.string("box_color") {
            if hex == "none" {
                look.background = nil
            } else {
                guard let color = Self.rgba(hex) else { return .failure("box_color is #RRGGBB.") }
                look.background = BackgroundBox(color: color,
                                                paddingRatio: look.background?.paddingRatio ?? 0.3,
                                                cornerRadiusRatio: look.background?
                                                    .cornerRadiusRatio ?? 0.2)
            }
        }
        if let shadow = args.bool("shadow") {
            look.shadow = shadow
                ? (look.shadow ?? Shadow(color: RGBA(red: 0, green: 0, blue: 0, alpha: 0.6),
                                         radiusRatio: 0.08, offsetXRatio: 0, offsetYRatio: 0.04))
                : nil
        }
        if let align = args.string("align") {
            let values: [String: TextAlignment] = ["left": .leading, "center": .center,
                                                   "right": .trailing]
            guard let value = values[align] else { return .failure("align is left, center or right.") }
            look.alignment = value
        }
        if let hex = args.string("highlight_color") {
            if hex == "none" {
                look.highlight = nil
            } else {
                guard let color = Self.rgba(hex) else {
                    return .failure("highlight_color is #RRGGBB.")
                }
                look.highlight = TitleHighlight(color: color)
            }
        }
        let libraryIDs = Set((libraryStyles() + StyleLibrary.builtIns).map(\.id))
        return .success(ProjectCommand.titleLook(look, forTitle: title.id, in: project,
                                                 libraryStyleIDs: libraryIDs))
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when not opaque.
    static func hex(_ color: RGBA) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(color.red), byte(color.green),
                         byte(color.blue))
        return color.alpha >= 1 ? rgb : rgb + String(format: "%02X", byte(color.alpha))
    }

    /// `#RRGGBB` or `#RRGGBBAA`.
    static func rgba(_ hex: String) -> RGBA? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else {
            return nil
        }
        let full = digits.count == 6 ? value << 8 | 0xFF : value
        return RGBA(red: Double(full >> 24 & 0xFF) / 255, green: Double(full >> 16 & 0xFF) / 255,
                    blue: Double(full >> 8 & 0xFF) / 255, alpha: Double(full & 0xFF) / 255)
    }

    // MARK: Music

    func musicTool(_ tool: String, _ args: MCPArguments) async -> MCPReply {
        if tool == "add_music" { return await addMusic(args) }
        guard let id = args.id("id"), let clip = project.music.first(where: { $0.id == id }) else {
            return .error("No music piece has that id. get_project lists them.")
        }
        switch tool {
        case "delete_music":
            store.perform(.deleteMusic(id: id))
            return .text("Removed \(clip.name).")
        case "duplicate_music":
            var copy = clip
            copy.id = UUID()
            copy.start = clip.end
            return store.perform(.insertMusic(copy))
                ? .json(musicJSON(project.music.first { $0.id == copy.id } ?? copy))
                : .error("The piece could not be copied.")
        default:
            var edited = clip
            if let start = args.ticks("song_start") {
                edited.songRange = TickRange(start: max(start, 0), duration: clip.duration)
            }
            if let duration = args.ticks("duration") {
                edited.songRange.duration = max(duration, MusicPlacement.minimumDuration)
            }
            if let start = args.ticks("start") { edited.start = max(start, 0) }
            if let volume = args.number("volume") { edited.volume = min(max(volume, 0), 1) }
            if let fade = args.ticks("fade_in") { edited.fadeIn = max(fade, 0) }
            if let fade = args.ticks("fade_out") { edited.fadeOut = max(fade, 0) }
            edited = MusicPlacement.fitFades(edited)
            guard edited != clip else { return .text("Nothing to change.") }
            guard edited.songRange.end <= edited.songDuration else {
                return .error("That runs past the end of the song "
                              + "(\(format(Ticks.seconds(edited.songDuration))) s).")
            }
            return store.perform(.setMusic(edited))
                ? .json(musicJSON(edited))
                : .error("Refused: the piece would overlap another one.")
        }
    }

    private func addMusic(_ args: MCPArguments) async -> MCPReply {
        guard let path = args.string("path") else { return missing("path") }
        guard project.source != nil else { return .error("Open a video first.") }
        let url = URL(fileURLWithPath: path)
        guard MCPFolders.shared.allows(url) else { return .error(MCPFolders.shared.refusal(for: path)) }
        let at = args.ticks("seconds") ?? Ticks.from(seconds: player.currentTime)
        do {
            let id = UUID()
            let imported = try await MusicFiles.importSong(from: url, id: id)
            guard let clip = MusicPlacement.newPiece(
                id: id, fileName: imported.fileName,
                name: url.deletingPathExtension().lastPathComponent,
                songDuration: imported.duration, at: at, among: project.music,
                videoDuration: TimelineMath.outputDuration(project)) else {
                try? FileManager.default.removeItem(at: MusicFiles.url(for: imported.fileName))
                return .error("There is no room on the music strip at "
                              + "\(format(Ticks.seconds(at))) s.")
            }
            store.perform(.addMusic(clip))
            return .json(musicJSON(clip))
        } catch {
            return .error("\(url.lastPathComponent) could not be added: \(error.localizedDescription)")
        }
    }
}
