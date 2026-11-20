import Foundation

/// Every edit to a `Project`. UI and (later) MCP both go through these.
///
/// Commands carry any new IDs they need, so applying one is deterministic.
public enum ProjectCommand: Sendable, Equatable {
    /// Sets the source of a project that has none, with one video segment
    /// covering the whole source. Output settings follow the source.
    case setSource(SourceVideo, segmentID: UUID)
    /// Points video `sourceID` (`VideoSegment.sourceID`; `nil` is
    /// `Project.source`) at `source`'s file (Locate Video), keeping
    /// everything else. Refused for a missing video, or if the file is
    /// shorter than the parts of it the timeline plays.
    case relinkSource(SourceVideo, sourceID: UUID? = nil)
    /// Adds video `source` at the end of the timeline as clip `segmentID`,
    /// covering the whole video. A video already in the project (same file
    /// path) is reused; otherwise `source` joins `Project.addedSources`.
    /// Refused without `Project.source` (`setSource` opens the first video)
    /// or if `segmentID` is in use.
    case addVideo(SourceVideo, segmentID: UUID)
    /// Sets the output frame size (`OutputShape`). Refused for an empty size.
    case setOutputSize(CGSize)
    /// Freezes the frame at `atOutputTime`: splits the video segment there
    /// (its later part gets `splitID`) and puts a still segment `segmentID`
    /// of `duration` between the halves, showing `still`. Everything after
    /// moves later; titles stay with their segments. Refused outside a video
    /// segment, or for a duration under `minimumSegmentDuration`.
    case insertStill(StillImage, segmentID: UUID, splitID: UUID, atOutputTime: Tick,
                     duration: Tick)
    /// Sets still segment `id`'s length; its camera motion keeps its shape,
    /// stretched to fit.
    case setStillDuration(id: UUID, duration: Tick)
    /// Sets still segment `id`'s camera motion (`ZoomKeyframe`s; empty is
    /// the whole frame, still).
    case setStillZoom(id: UUID, zoom: [ZoomKeyframe])
    /// Sets how long still segment `id` holds its camera's last view: its
    /// length becomes the motion's length plus `hold`, the motion unchanged.
    /// Refused without camera motion, for a negative hold, or above
    /// `maximumStillHold`.
    case setStillHold(id: UUID, hold: Tick)
    /// Inserts title card `card` at `atOutputTime`: at a cut it goes before
    /// the segment there and takes the cut's transition; inside a clip or
    /// freeze it splits it (the later part gets `splitID`); inside a gap it
    /// splits the gap; at or past the end it is appended. Everything after
    /// moves later. Refused on an empty timeline, for a duration under
    /// `minimumSegmentDuration`, or for IDs in use.
    case insertCard(CardSegment, splitID: UUID, atOutputTime: Tick)
    /// Inserts `image` (a picture from outside the video) as still segment
    /// `segmentID` of `duration` at `atOutputTime`, placed as `insertCard`
    /// places a card. Refused for a duration under `minimumSegmentDuration`.
    case insertImage(StillImage, segmentID: UUID, splitID: UUID, atOutputTime: Tick,
                     duration: Tick)
    /// Sets title card `id`'s length.
    case setCardDuration(id: UUID, duration: Tick)
    /// Sets title card `id`'s colour.
    case setCardColor(id: UUID, color: RGBA)
    /// Adds a piece to the music strip. Refused if it is malformed
    /// (`MusicClip.isValid`), its ID is taken, or it overlaps another piece.
    case addMusic(MusicClip)
    /// Replaces the piece with `clip.id` (move, trim, volume, fades), under
    /// the same rules as `addMusic`.
    case setMusic(MusicClip)
    case deleteMusic(id: UUID)
    /// Pastes or duplicates a piece at `clip.start`: after the piece that
    /// covers that time, if any. Later pieces move right just enough to make
    /// room, keeping their spacing. Refused if malformed or the ID is taken.
    case insertMusic(MusicClip)
    /// Sets where the frame sits across video segment `id` (`VideoSegment.framing`),
    /// clamped to 0...1; `nil` centres it. Refused for a still or gap.
    case setSegmentFraming(id: UUID, framing: Double?)
    /// Sets video segment `id`'s position and zoom (`VideoSegment.frame`),
    /// clamped (`ClipFraming.clamped`). Refused for another kind of segment.
    case setSegmentFrame(id: UUID, frame: ClipFraming)
    /// Shows video segment `id` as two halves (`VideoSegment.split`), each
    /// framing clamped (`ClipFraming.clamped`); `nil` shows it whole again.
    /// Refused for another kind of segment.
    case setSegmentSplit(id: UUID, split: SplitScreen?)
    /// Sets video segment `id`'s speed (`VideoSegment.speeds`; 1 or `nil`
    /// is normal), changing its length. Titles anchored to it keep their
    /// place in the footage; auto-captions also scale their length and
    /// word timings. Refused for another kind of segment, a speed not in
    /// `VideoSegment.speeds`, or a length under `minimumSegmentDuration`.
    case setClipSpeed(id: UUID, speed: Double?)
    /// Sets video segment `id`'s volume, clamped to
    /// 0...`VideoSegment.maximumVolume`; 1 or `nil` is unchanged sound.
    /// Refused for another kind of segment.
    case setClipVolume(id: UUID, volume: Double?)
    /// Splits the segment under `outputTime`. Titles re-anchor to the half
    /// that contains their start (D1).
    case splitSegment(atOutputTime: Tick, newSegmentID: UUID)
    /// Deletes a segment and the titles anchored to it (D1). Later segments
    /// close up, so deleting a gap closes it.
    case deleteSegment(id: UUID)
    /// Puts a copy of clip `id` (video, freeze or card) right after it, as
    /// `newID`, with no transition at the cut between them. Later segments
    /// move right; titles stay with their segments and are not copied.
    /// Refused for a gap, a missing ID, or a taken `newID`.
    case duplicateSegment(id: UUID, newID: UUID)
    /// Sets the source range of video segment `id`.
    ///
    /// An edge that moves out first eats into the gap on that side, then
    /// pushes later segments right. An edge that moves in widens the gap on
    /// that side, or opens one (none before the first segment or after the
    /// last: those close up). `newGapIDs`
    /// name opened gaps, in order; two always suffice.
    ///
    /// Titles anchored to it keep their source frame: moving the start by `d`
    /// moves their offsets by `-d`, clamped into the new range. Refused for a
    /// still or gap, a range outside the source, or one shorter than
    /// `minimumSegmentDuration`.
    case trimSegment(id: UUID, sourceRange: TickRange, newGapIDs: [UUID] = [UUID(), UUID()])
    /// Moves clip `id` (video, freeze or card) to `toOutputStart`, clamped
    /// to 0, measured on the timeline without it: lifting it closes up its
    /// place, as in Final Cut.
    ///
    /// On another clip it goes in at that clip's nearer edge, and later
    /// segments slide right. In a gap it takes that place, pushing later
    /// segments right only by what does not fit; at or past the end it is
    /// appended. Titles anchored to it move with it. `newGapIDs[0]` names a
    /// gap left after it in a gap; two must be given. Refused for a gap or
    /// a missing ID.
    case moveSegment(id: UUID, toOutputStart: Tick, newGapIDs: [UUID] = [UUID(), UUID()])
    /// Moves clip `id` and everything after it together, so the clip starts
    /// at `toOutputStart`. Later moves open or widen the gap before it
    /// (`newGapID` names an opened one); earlier ones narrow that gap, at
    /// most closing it. Titles move with their segments; music stays.
    /// Refused for the first segment or a gap. Applies, changing nothing,
    /// when there is nowhere to go, so a drag back to its start undoes itself.
    case shiftSegments(fromID: UUID, toOutputStart: Tick, newGapID: UUID = UUID())
    /// Puts `transition` at `point`, replacing any there; `nil` removes it.
    /// Refused for a missing segment, a duration outside
    /// `ClipTransition.minimumDuration...maximumDuration`, or a crossfade at
    /// the video's start or end.
    case setClipTransition(at: TransitionPoint, transition: ClipTransition?)

    /// Adds a title at `atOutputTime`, anchored to the segment there. Copies
    /// `style` into `Project.styles` if no style with its ID is present (§5.2).
    case addTitle(id: UUID, text: String, atOutputTime: Tick, style: TitleStyle,
                  duration: Tick = ProjectCommand.defaultTitleDuration,
                  transitionIn: Transition = ProjectCommand.defaultTransitionIn,
                  transitionOut: Transition = ProjectCommand.defaultTransitionOut)
    /// Moves a title to a new output start, re-anchoring it to the segment
    /// containing that start. The start is clamped to `0..<outputDuration`.
    case moveTitle(id: UUID, toOutputStart: Tick)
    /// Sets a title's duration. Must be positive.
    case setTitleDuration(id: UUID, duration: Tick)
    case setTitleText(id: UUID, text: String)
    case setTitleTransitionIn(id: UUID, transition: Transition)
    case setTitleTransitionOut(id: UUID, transition: Transition)
    /// `nil` removes all overrides.
    case setTitleStyleOverrides(id: UUID, overrides: StyleOverrides?)
    /// Sets the style of every title in `ids`, copying `style` into
    /// `Project.styles` if absent. Refused if any ID is missing.
    case setTitleStyle(ids: Set<UUID>, style: TitleStyle)
    /// Gives title `id` the look `style`: points it at `style.id`, replacing
    /// the project style with that ID or appending it. Refused if the title
    /// is missing or another title uses `style.id`, so a look edit never
    /// reaches another title. See `titleLook(_:forTitle:in:libraryStyleIDs:forkID:)`.
    case setTitleLook(id: UUID, style: TitleStyle)
    /// `setTitleLook` for a group: every title in `ids` gets `style`. Refused
    /// if `ids` is empty, any title in it is missing, or a title outside it
    /// uses `style.id`. See `titlesLook(_:forTitles:in:libraryStyleIDs:forkID:)`.
    case setTitlesLook(ids: Set<UUID>, style: TitleStyle)
    /// Deletes the titles in `ids`. Missing IDs are ignored; refused if none exist.
    case deleteTitles(ids: Set<UUID>)
    /// Removes every title marked `.autoCaption` and adds `titles` (made by
    /// `AutoCaptions.titles`), embedding `style` if absent. Hand-made titles
    /// are untouched. Refused if a new title is not marked, uses another
    /// style, names a missing segment, or reuses the ID of a title that stays.
    case replaceAutoCaptions(titles: [Title], style: TitleStyle)
    /// Adds copies of `clipboard`'s titles, the earliest starting at
    /// `atOutputTime` and the others at their copied distance from it. Copy
    /// `i` gets `newIDs[i]` and is anchored to the segment at its start;
    /// text, style, overrides and transitions are kept. Missing styles are
    /// copied into `Project.styles`. Copies starting at or past the timeline
    /// end are dropped. Refused if none land, or if `newIDs` does not match
    /// the entries or names an existing title.
    case pasteTitles(TitleClipboard, atOutputTime: Tick, newIDs: [UUID])
    /// Adds a copy of each title in `newIDs` (original ID to copy ID) starting
    /// where the original ends. Copies starting at or past the timeline end
    /// are dropped. Refused if none land, an original is missing, or a copy ID
    /// is taken.
    case duplicateTitles(newIDs: [UUID: UUID])

    /// 3 s.
    public static let defaultTitleDuration: Tick = 3 * Ticks.perSecond
    /// 0.3 s fade, easing out.
    public static let defaultTransitionIn = Transition(kind: .fade, duration: 180,
                                                       easing: .easeOut)
    /// 0.3 s fade, easing in.
    public static let defaultTransitionOut = Transition(kind: .fade, duration: 180,
                                                        easing: .easeIn)

    /// Longest hold `setStillHold` accepts: 10 s.
    public static let maximumStillHold: Tick = 10 * Ticks.perSecond

    /// One frame at the output frame rate, rounded up to a whole tick.
    public static func minimumSegmentDuration(in project: Project) -> Tick {
        let rate = project.output.frameRate
        let frameRate = rate.isFinite && rate > 0 ? rate : Timecode.fallbackFrameRate
        return max(Tick((Double(Ticks.perSecond) / frameRate).rounded(.up)), 1)
    }

    /// Undo menu name, e.g. "Undo Split Segment".
    public var actionName: String {
        switch self {
        case .setSource: "Open Video"
        case .relinkSource: "Locate Video"
        case .addVideo: "Add Video"
        case .setOutputSize: "Change Shape"
        case .insertStill: "Freeze Frame"
        case .setStillDuration: "Change Freeze Length"
        case .setStillZoom: "Change Camera Motion"
        case .setStillHold: "Change Freeze Hold"
        case .insertCard: "Insert Title Card"
        case .insertImage: "Insert Image"
        case .setCardDuration: "Change Card Length"
        case .setCardColor: "Change Card Colour"
        case .addMusic: "Add Music"
        case .setMusic: "Change Music"
        case .deleteMusic: "Delete Music"
        case .insertMusic: "Paste Music"
        case .setSegmentFraming: "Reframe Clip"
        case .setSegmentFrame: "Reframe Clip"
        case .setSegmentSplit: "Split Screen"
        case .setClipSpeed: "Change Clip Speed"
        case .setClipVolume: "Change Clip Volume"
        case .splitSegment: "Split Segment"
        case .deleteSegment: "Delete Segment"
        case .duplicateSegment: "Duplicate Segment"
        case .trimSegment: "Trim Segment"
        case .moveSegment: "Move Segment"
        case .shiftSegments: "Move Segments"
        case .setClipTransition(_, let transition):
            transition == nil ? "Remove Transition" : "Set Transition"
        case .addTitle: "Add Title"
        case .moveTitle: "Move Title"
        case .setTitleDuration: "Change Title Duration"
        case .setTitleText: "Edit Title Text"
        case .setTitleTransitionIn: "Change Transition In"
        case .setTitleTransitionOut: "Change Transition Out"
        case .setTitleStyleOverrides: "Change Title Layout"
        case .setTitleStyle(let ids, _): ids.count == 1 ? "Change Title Style" : "Change Title Styles"
        case .setTitleLook, .setTitlesLook: "Change Title Look"
        case .deleteTitles(let ids): ids.count == 1 ? "Delete Title" : "Delete Titles"
        case .replaceAutoCaptions: "Auto-Captions"
        case .pasteTitles(let clipboard, _, _):
            clipboard.entries.count == 1 ? "Paste Title" : "Paste Titles"
        case .duplicateTitles(let ids): ids.count == 1 ? "Duplicate Title" : "Duplicate Titles"
        }
    }

    /// Applies the command. Returns `false` and leaves `project` unchanged
    /// when the command does not apply.
    ///
    /// Afterwards every style no title uses is removed from `Project.styles`,
    /// so a command that leaves a style unused takes it with it and undo
    /// restores it. (Clipboards carry their own styles, and applying a
    /// library style embeds it again.) The video's end transition moves to
    /// whichever segment is now last.
    @discardableResult
    public func apply(to project: inout Project) -> Bool {
        let end = project.segments.last?.transitionOut
        guard applyEdit(to: &project) else { return false }
        keepEndTransition(end, in: &project)
        let used = Set(project.titles.map(\.styleID))
        project.styles.removeAll { !used.contains($0.id) }
        let shown = Set(project.segments.compactMap { segment -> UUID? in
            if case .still(let still) = segment { still.stillID } else { nil }
        })
        project.stills.removeAll { !shown.contains($0.id) }
        let played = Set(project.segments.compactMap { segment -> UUID? in
            if case .video(let video) = segment { video.sourceID } else { nil }
        })
        project.addedSources.removeAll { !played.contains($0.id) }
        return true
    }

    /// Puts `segment` at `outputTime`: at the end past the last segment,
    /// inside a gap by splitting it, else by splitting the segment there
    /// (its later part gets `splitID`). At a cut it takes the cut's
    /// transition. Titles stay with their segments.
    private static func insert(_ segment: Segment, splitID: UUID, at outputTime: Tick,
                               in project: inout Project) -> Bool {
        var segment = segment
        let total = TimelineMath.outputDuration(project)
        guard outputTime < total,
              let location = TimelineMath.locate(max(outputTime, 0), in: project) else {
            project.segments.append(segment)
            return true
        }
        var index = location.index
        if location.offset > 0 {
            if case .gap(var gap) = project.segments[index] {
                let rest = GapSegment(id: splitID, duration: gap.duration - location.offset)
                gap.duration = location.offset
                project.segments.replaceSubrange(index...index,
                                                 with: [.gap(gap), segment, .gap(rest)])
                for titleIndex in project.titles.indices
                where project.titles[titleIndex].anchor.segmentID == gap.id
                    && project.titles[titleIndex].anchor.offset >= location.offset {
                    project.titles[titleIndex].anchor = TitleAnchor(
                        segmentID: splitID,
                        offset: project.titles[titleIndex].anchor.offset - location.offset)
                }
                return true
            }
            guard ProjectCommand.splitSegment(atOutputTime: outputTime, newSegmentID: splitID)
                .applyEdit(to: &project) else { return false }
            index += 1
        }
        // At a cut the segment takes the cut, and its transition.
        segment.transitionIn = project.segments[index].transitionIn
        project.segments[index].transitionIn = nil
        project.segments.insert(segment, at: index)
        return true
    }

    private func applyEdit(to project: inout Project) -> Bool {
        switch self {
        case let .setSource(source, segmentID):
            guard project.source == nil else { return false }
            project.source = source
            project.segments = [.video(VideoSegment(
                id: segmentID, sourceRange: TickRange(start: 0, duration: source.duration)))]
            project.titles = []
            project.output = OutputSettings(size: source.naturalSize,
                                            frameRate: source.frameRate,
                                            codec: project.output.codec)
            return true

        case let .relinkSource(new, sourceID):
            guard var source = project.source(id: sourceID) else { return false }
            let used = project.segments.compactMap { segment -> Tick? in
                if case .video(let video) = segment, video.sourceID == sourceID {
                    video.sourceRange.end
                } else {
                    nil
                }
            }.max() ?? 0
            guard new.duration >= used,
                  new.bookmark != source.bookmark || new.lastKnownPath != source.lastKnownPath
            else { return false }
            source.bookmark = new.bookmark
            source.lastKnownPath = new.lastKnownPath
            if let index = project.addedSources.firstIndex(where: { $0.id == sourceID }) {
                project.addedSources[index] = source
            } else {
                project.source = source
            }
            return true

        case let .addVideo(new, segmentID):
            guard let primary = project.source,
                  !project.segments.contains(where: { $0.id == segmentID }) else { return false }
            let existing = primary.lastKnownPath == new.lastKnownPath
                ? (key: UUID?.none, video: primary)
                : project.addedSources.first { $0.lastKnownPath == new.lastKnownPath }
                    .map { (key: UUID?.some($0.id), video: $0) }
            let video = existing?.video ?? new
            guard video.duration >= Self.minimumSegmentDuration(in: project) else { return false }
            let sourceID = existing.map(\.key) ?? new.id
            if existing == nil { project.addedSources.append(new) }
            let duration = video.duration
            project.segments.append(.video(VideoSegment(
                id: segmentID, sourceID: sourceID,
                sourceRange: TickRange(start: 0, duration: duration))))
            return true

        case let .setOutputSize(size):
            guard size.width > 0, size.height > 0, size != project.output.size else {
                return false
            }
            project.output.size = size
            return true

        case let .insertStill(still, segmentID, splitID, outputTime, duration):
            guard duration >= Self.minimumSegmentDuration(in: project),
                  let location = TimelineMath.locate(outputTime, in: project),
                  location.offset < project.segments[location.index].duration,
                  case .video = project.segments[location.index],
                  !project.segments.contains(where: { $0.id == segmentID || $0.id == splitID })
            else { return false }
            var index = location.index
            if location.offset > 0 {
                guard ProjectCommand.splitSegment(atOutputTime: outputTime, newSegmentID: splitID)
                    .applyEdit(to: &project) else { return false }
                index += 1
            }
            // At a clip's start the still takes the cut, and its transition.
            let transitionIn = location.offset == 0 ? project.segments[index].transitionIn : nil
            if location.offset == 0 { project.segments[index].transitionIn = nil }
            project.segments.insert(.still(StillSegment(id: segmentID, stillID: still.id,
                                                        duration: duration,
                                                        transitionIn: transitionIn)), at: index)
            if !project.stills.contains(where: { $0.id == still.id }) {
                project.stills.append(still)
            }
            return true

        case let .setStillDuration(id, duration):
            guard duration >= Self.minimumSegmentDuration(in: project),
                  let index = project.segments.firstIndex(where: { $0.id == id }),
                  case .still(var still) = project.segments[index],
                  duration != still.duration else { return false }
            let stretch = Double(duration) / Double(max(still.duration, 1))
            still.zoom = still.zoom.map { keyframe in
                var stretched = keyframe
                stretched.time = Tick((Double(keyframe.time) * stretch).rounded())
                return stretched
            }
            still.duration = duration
            project.segments[index] = .still(still)
            return true

        case let .setStillZoom(id, zoom):
            guard let index = project.segments.firstIndex(where: { $0.id == id }),
                  case .still(var still) = project.segments[index],
                  zoom != still.zoom else { return false }
            still.zoom = zoom.sorted { $0.time < $1.time }
            project.segments[index] = .still(still)
            return true

        case let .setStillHold(id, hold):
            guard (0...Self.maximumStillHold).contains(hold),
                  let index = project.segments.firstIndex(where: { $0.id == id }),
                  case .still(var still) = project.segments[index],
                  still.zoom.count > 1, let motionEnd = still.zoom.last?.time,
                  motionEnd + hold >= Self.minimumSegmentDuration(in: project),
                  motionEnd + hold != still.duration else { return false }
            still.duration = motionEnd + hold
            project.segments[index] = .still(still)
            return true

        case let .duplicateSegment(id, newID):
            guard let index = project.segments.firstIndex(where: { $0.id == id }),
                  !project.segments.contains(where: { $0.id == newID }) else { return false }
            let copy: Segment
            switch project.segments[index] {
            case .video(var video):
                video.id = newID
                video.transitionIn = nil
                video.transitionOut = nil
                copy = .video(video)
            case .still(var still):
                still.id = newID
                still.transitionIn = nil
                still.transitionOut = nil
                copy = .still(still)
            case .card(var card):
                card.id = newID
                card.transitionIn = nil
                card.transitionOut = nil
                copy = .card(card)
            case .gap:
                return false
            }
            project.segments.insert(copy, at: index + 1)
            return true

        case let .insertCard(card, splitID, outputTime):
            guard card.duration >= Self.minimumSegmentDuration(in: project),
                  !project.segments.isEmpty, card.id != splitID,
                  !project.segments.contains(where: { $0.id == card.id || $0.id == splitID })
            else { return false }
            var card = card
            card.transitionIn = nil
            card.transitionOut = nil
            return Self.insert(.card(card), splitID: splitID, at: outputTime, in: &project)

        case let .insertImage(image, segmentID, splitID, outputTime, duration):
            guard duration >= Self.minimumSegmentDuration(in: project),
                  !project.segments.isEmpty, segmentID != splitID,
                  !project.segments.contains(where: { $0.id == segmentID || $0.id == splitID })
            else { return false }
            let still = StillSegment(id: segmentID, stillID: image.id, duration: duration)
            guard Self.insert(.still(still), splitID: splitID, at: outputTime, in: &project)
            else { return false }
            if !project.stills.contains(where: { $0.id == image.id }) {
                project.stills.append(image)
            }
            return true

        case let .setCardDuration(id, duration):
            guard duration >= Self.minimumSegmentDuration(in: project),
                  let index = project.segments.firstIndex(where: { $0.id == id }),
                  case .card(var card) = project.segments[index],
                  duration != card.duration else { return false }
            card.duration = duration
            project.segments[index] = .card(card)
            return true

        case let .setCardColor(id, color):
            guard let index = project.segments.firstIndex(where: { $0.id == id }),
                  case .card(var card) = project.segments[index],
                  color != card.color else { return false }
            card.color = color
            project.segments[index] = .card(card)
            return true

        case let .addMusic(clip):
            guard clip.isValid, !project.music.contains(where: { $0.id == clip.id }),
                  Self.fits(clip, among: project.music) else { return false }
            project.music.append(clip)
            project.music.sort { $0.start < $1.start }
            return true

        case let .setMusic(clip):
            guard let index = project.music.firstIndex(where: { $0.id == clip.id }),
                  project.music[index] != clip, clip.isValid,
                  Self.fits(clip, among: project.music.filter { $0.id != clip.id })
            else { return false }
            project.music[index] = clip
            project.music.sort { $0.start < $1.start }
            return true

        case var .insertMusic(clip):
            guard clip.isValid, !project.music.contains(where: { $0.id == clip.id }) else {
                return false
            }
            if let covering = project.music.first(where: {
                $0.start <= clip.start && clip.start < $0.end
            }) {
                clip.start = covering.end
            }
            let next = project.music.filter { $0.start >= clip.start }.map(\.start).min()
            if let next, clip.end > next {
                let shift = clip.end - next
                for index in project.music.indices where project.music[index].start >= clip.start {
                    project.music[index].start += shift
                }
            }
            project.music.append(clip)
            project.music.sort { $0.start < $1.start }
            return true

        case let .deleteMusic(id):
            guard let index = project.music.firstIndex(where: { $0.id == id }) else {
                return false
            }
            project.music.remove(at: index)
            return true

        case let .setSegmentFraming(id, framing):
            guard let index = project.segments.firstIndex(where: { $0.id == id }),
                  case .video(var video) = project.segments[index] else { return false }
            let clamped = framing.map { min(max($0, 0), 1) }
            guard clamped != video.framing else { return false }
            video.framing = clamped
            project.segments[index] = .video(video)
            return true

        case let .setSegmentFrame(id, frame):
            guard let index = project.segments.firstIndex(where: { $0.id == id }),
                  case .video(var video) = project.segments[index] else { return false }
            let before = video
            video.frame = frame
            guard video != before else { return false }
            project.segments[index] = .video(video)
            return true

        case let .setSegmentSplit(id, split):
            guard let index = project.segments.firstIndex(where: { $0.id == id }),
                  case .video(var video) = project.segments[index] else { return false }
            let clamped = split.map { SplitScreen(first: $0.first.clamped, second: $0.second.clamped) }
            guard clamped != video.split else { return false }
            video.split = clamped
            project.segments[index] = .video(video)
            return true

        case let .setClipSpeed(id, speed):
            let new = speed == 1 ? nil : speed
            guard new.map({ VideoSegment.speeds.contains($0) }) ?? true,
                  let index = project.segments.firstIndex(where: { $0.id == id }),
                  case .video(var video) = project.segments[index],
                  new != video.speed else { return false }
            let ratio = video.rate / (new ?? 1)
            video.speed = new
            guard video.outputDuration >= Self.minimumSegmentDuration(in: project) else {
                return false
            }
            project.segments[index] = .video(video)
            let scale = { (ticks: Tick) in Tick((Double(ticks) * ratio).rounded()) }
            for titleIndex in project.titles.indices
            where project.titles[titleIndex].anchor.segmentID == id {
                var title = project.titles[titleIndex]
                title.anchor.offset = min(scale(title.anchor.offset),
                                          max(video.outputDuration - 1, 0))
                if title.origin == .autoCaption {
                    title.duration = max(scale(title.duration), 1)
                    title.words = title.words?.map { word in
                        var word = word
                        word.start = scale(word.start)
                        word.end = scale(word.end)
                        return word
                    }
                }
                project.titles[titleIndex] = title
            }
            return true

        case let .setClipVolume(id, volume):
            let clamped = volume.map { min(max($0, 0), VideoSegment.maximumVolume) }
            let new = clamped == 1 ? nil : clamped
            guard let index = project.segments.firstIndex(where: { $0.id == id }),
                  case .video(var video) = project.segments[index],
                  new != video.volume else { return false }
            video.volume = new
            project.segments[index] = .video(video)
            return true

        case let .splitSegment(outputTime, newID):
            guard let location = TimelineMath.locate(outputTime, in: project),
                  let (first, second) = TimelineMath.split(project.segments[location.index],
                                                           at: location.offset, newID: newID)
            else { return false }
            let originalID = location.segmentID
            project.segments.replaceSubrange(location.index...location.index,
                                             with: [first, second])
            // The first half's length, not `location.offset`: at another
            // speed they can differ by a rounded tick.
            let cut = first.duration
            for index in project.titles.indices
            where project.titles[index].anchor.segmentID == originalID
                && project.titles[index].anchor.offset >= cut {
                project.titles[index].anchor = TitleAnchor(
                    segmentID: newID,
                    offset: project.titles[index].anchor.offset - cut)
            }
            return true

        case let .deleteSegment(id):
            guard let index = project.segments.firstIndex(where: { $0.id == id }) else {
                return false
            }
            project.segments.remove(at: index)
            project.titles.removeAll { $0.anchor.segmentID == id }
            Self.normalizeGaps(in: &project)
            return true

        case let .trimSegment(id, range, newGapIDs):
            guard let index = project.segments.firstIndex(where: { $0.id == id }),
                  case .video(var video) = project.segments[index],
                  let source = project.source(of: video),
                  range.start >= 0, range.end <= source.duration,
                  range.duration >= Self.minimumSegmentDuration(in: project),
                  Self.areFresh(newGapIDs, in: project)
            else { return false }
            let gapTitles = Self.gapTitleStarts(project)
            // Growth on each side in output ticks (source ticks at another speed).
            let oldDuration = video.outputDuration
            let grownLeft = video.outputOffset(ofSource: video.sourceRange.start)
                - video.outputOffset(ofSource: range.start)
            video.sourceRange = range
            guard video.outputDuration >= Self.minimumSegmentDuration(in: project) else {
                return false
            }
            let grownRight = video.outputDuration - oldDuration - grownLeft
            project.segments[index] = .video(video)
            for titleIndex in project.titles.indices
            where project.titles[titleIndex].anchor.segmentID == id {
                let offset = project.titles[titleIndex].anchor.offset + grownLeft
                project.titles[titleIndex].anchor.offset = min(max(offset, 0),
                                                               video.outputDuration - 1)
            }
            var newIDs = newGapIDs.makeIterator()
            var clipIndex = index
            if Self.resizeGap(before: clipIndex, by: -grownLeft, in: &project.segments,
                              newID: &newIDs) {
                clipIndex += 1
            }
            Self.resizeGap(after: clipIndex, by: -grownRight, in: &project.segments,
                           newID: &newIDs)
            Self.relocate(gapTitles, in: &project)
            Self.normalizeGaps(in: &project)
            return true

        case let .moveSegment(id, outputStart, newGapIDs):
            guard newGapIDs.count >= 2, Self.areFresh(newGapIDs, in: project),
                  let index = project.segments.firstIndex(where: { $0.id == id }),
                  !project.segments[index].isGap
            else { return false }
            // Lift the clip out; the timeline closes up behind it. A gap left
            // last stays until the clip is placed, so it can land in it.
            let clip = project.segments.remove(at: index)
            Self.normalizeGaps(in: &project, keepingTrailingGap: true)
            let gapTitles = Self.gapTitleStarts(project)

            let target = max(outputStart, 0)
            if target >= TimelineMath.outputDuration(project) {
                project.segments.append(clip)
            } else if let location = TimelineMath.locate(target, in: project) {
                if case .gap(var gap) = project.segments[location.index] {
                    // In a gap: take that place, pushing later clips by what does not fit.
                    let remainder = gap.duration - location.offset
                    gap.duration = location.offset
                    var placed: [Segment] = [.gap(gap), clip]
                    if remainder > clip.duration {
                        placed.append(.gap(GapSegment(id: newGapIDs[0],
                                                      duration: remainder - clip.duration)))
                    }
                    project.segments.replaceSubrange(location.index...location.index, with: placed)
                } else {
                    // On a clip: go in at its nearer edge; later clips slide right.
                    let duration = project.segments[location.index].duration
                    let before = location.offset * 2 < duration
                    project.segments.insert(clip, at: before ? location.index : location.index + 1)
                }
            }
            Self.relocate(gapTitles, in: &project)
            Self.normalizeGaps(in: &project)
            return true

        case let .shiftSegments(id, outputStart, newGapID):
            guard let index = project.segments.firstIndex(where: { $0.id == id }), index > 0,
                  !project.segments[index].isGap,
                  let start = TimelineMath.segmentStart(id, in: project),
                  Self.areFresh([newGapID], in: project)
                  || project.segments[index - 1].id == newGapID
            else { return false }
            var delta = outputStart - start
            if case .gap(let gap) = project.segments[index - 1] {
                delta = max(delta, -gap.duration)
            } else {
                delta = max(delta, 0)
            }
            guard delta != 0 else { return true }
            let gapTitles = Self.gapTitleStarts(project)
            var newIDs = [newGapID].makeIterator()
            Self.resizeGap(before: index, by: delta, in: &project.segments, newID: &newIDs)
            Self.relocate(gapTitles, in: &project)
            Self.normalizeGaps(in: &project)
            return true

        case let .setClipTransition(point, transition):
            if let transition {
                guard (ClipTransition.minimumDuration...ClipTransition.maximumDuration)
                        .contains(transition.duration),
                      transition.kind != .crossfade || !point.isEdge(in: project)
                else { return false }
            }
            switch point {
            case .before(let id):
                guard let index = project.segments.firstIndex(where: { $0.id == id }),
                      project.segments[index].transitionIn != transition else { return false }
                project.segments[index].transitionIn = transition
            case .end:
                guard let index = project.segments.indices.last,
                      !project.segments[index].isGap,
                      project.segments[index].transitionOut != transition else { return false }
                project.segments[index].transitionOut = transition
            }
            return true

        case let .addTitle(id, text, outputTime, style, duration, transitionIn, transitionOut):
            guard duration > 0, !project.titles.contains(where: { $0.id == id }),
                  outputTime < TimelineMath.outputDuration(project),
                  let location = TimelineMath.locate(outputTime, in: project)
            else { return false }
            Self.embed(style, in: &project)
            project.titles.append(Title(
                id: id, text: text,
                anchor: TitleAnchor(segmentID: location.segmentID, offset: location.offset),
                duration: duration, styleID: style.id,
                transitionIn: transitionIn, transitionOut: transitionOut))
            return true

        case let .moveTitle(id, outputStart):
            let total = TimelineMath.outputDuration(project)
            guard total > 0, let index = project.titles.firstIndex(where: { $0.id == id }),
                  let location = TimelineMath.locate(min(max(outputStart, 0), total - 1),
                                                     in: project)
            else { return false }
            project.titles[index].anchor = TitleAnchor(segmentID: location.segmentID,
                                                       offset: location.offset)
            return true

        case let .setTitleDuration(id, duration):
            guard duration > 0 else { return false }
            return Self.edit(id, in: &project) { $0.duration = duration }

        case let .setTitleText(id, text):
            return Self.edit(id, in: &project) { $0.text = text }

        case let .setTitleTransitionIn(id, transition):
            return Self.edit(id, in: &project) { $0.transitionIn = transition }

        case let .setTitleTransitionOut(id, transition):
            return Self.edit(id, in: &project) { $0.transitionOut = transition }

        case let .setTitleStyleOverrides(id, overrides):
            return Self.edit(id, in: &project) { $0.styleOverrides = overrides }

        case let .setTitleStyle(ids, style):
            guard !ids.isEmpty,
                  ids.isSubset(of: project.titles.map(\.id)) else { return false }
            Self.embed(style, in: &project)
            for index in project.titles.indices where ids.contains(project.titles[index].id) {
                project.titles[index].styleID = style.id
            }
            return true

        case let .setTitleLook(id, style):
            return Self.setTitlesLook(ids: [id], style: style).applyEdit(to: &project)

        case let .setTitlesLook(ids, style):
            guard !ids.isEmpty, ids.isSubset(of: project.titles.map(\.id)),
                  !project.titles.contains(where: { !ids.contains($0.id) && $0.styleID == style.id })
            else { return false }
            if let styleIndex = project.styles.firstIndex(where: { $0.id == style.id }) {
                project.styles[styleIndex] = style
            } else {
                project.styles.append(style)
            }
            for index in project.titles.indices where ids.contains(project.titles[index].id) {
                project.titles[index].styleID = style.id
            }
            return true

        case let .deleteTitles(ids):
            guard project.titles.contains(where: { ids.contains($0.id) }) else { return false }
            project.titles.removeAll { ids.contains($0.id) }
            return true

        case let .replaceAutoCaptions(titles, style):
            let kept = project.titles.filter { $0.origin != .autoCaption }
            let keptIDs = Set(kept.map(\.id))
            let segmentIDs = Set(project.segments.map(\.id))
            guard Set(titles.map(\.id)).count == titles.count,
                  titles.allSatisfy({ $0.origin == .autoCaption && $0.styleID == style.id
                      && $0.duration > 0 && segmentIDs.contains($0.anchor.segmentID)
                      && !keptIDs.contains($0.id) })
            else { return false }
            if !titles.isEmpty { Self.embed(style, in: &project) }
            project.titles = kept + titles
            return true

        case let .pasteTitles(clipboard, outputTime, newIDs):
            guard newIDs.count == clipboard.entries.count, Set(newIDs).count == newIDs.count,
                  outputTime >= 0, !project.titles.contains(where: { newIDs.contains($0.id) })
            else { return false }
            let copies = zip(clipboard.entries, newIDs).map { entry, id in
                (entry.title, id, outputTime + entry.start)
            }
            return Self.insertCopies(copies, styles: clipboard.styles, in: &project)

        case let .duplicateTitles(newIDs):
            guard !newIDs.isEmpty, Set(newIDs.values).count == newIDs.count,
                  !project.titles.contains(where: { newIDs.values.contains($0.id) })
            else { return false }
            var copies: [(Title, UUID, Tick)] = []
            for title in project.titles {
                guard let id = newIDs[title.id],
                      let range = TimelineMath.titleOutputRange(title, in: project) else { continue }
                copies.append((title, id, range.start + title.duration))
            }
            guard copies.count == newIDs.count else { return false }
            return Self.insertCopies(copies, styles: [], in: &project)
        }
    }

    /// The library style "Save as new style" writes for title `id`: its
    /// current style with ID `newID`, `name`, and the title's size override
    /// folded in. `commands` then clear that override (keeping the position
    /// override) and point the title at the new style; perform them as one
    /// undo step. `nil` if the title or its style is missing.
    ///
    /// With `others`, those titles get the new style too, and their size
    /// overrides are cleared the same way.
    public static func newStyle(fromTitle id: UUID, applyingTo others: Set<UUID> = [],
                                in project: Project, newID: UUID,
                                name: String) -> (style: TitleStyle, commands: [ProjectCommand])? {
        guard let title = project.titles.first(where: { $0.id == id }),
              let current = project.styles.first(where: { $0.id == title.styleID })
        else { return nil }
        var style = current.applying(StyleOverrides(fontSizeRatio:
            title.styleOverrides?.fontSizeRatio))
        style.id = newID
        style.name = name
        style.basedOn = nil
        let ids = others.union([id])
        var commands: [ProjectCommand] = []
        for title in project.titles where ids.contains(title.id) {
            guard title.styleOverrides?.fontSizeRatio != nil else { continue }
            var overrides = title.styleOverrides ?? StyleOverrides()
            overrides.fontSizeRatio = nil
            commands.append(.setTitleStyleOverrides(
                id: title.id, overrides: overrides == StyleOverrides() ? nil : overrides))
        }
        commands.append(.setTitleStyle(ids: ids, style: style))
        return (style, commands)
    }

    /// The library style "Update <name>" writes for title `id`, whose style
    /// is a customised copy of a library style (`basedOn`): the title's look
    /// with its size override folded in, under the library style's ID and
    /// `name`. `commands` clear the size overrides of `id` and `others`, then
    /// give them, and every title already on the library style, that look.
    /// Perform them as one undo step. `nil` if the title is missing or its
    /// style is not a customised copy.
    public static func updatedLibraryStyle(fromTitle id: UUID, applyingTo others: Set<UUID> = [],
                                           in project: Project, name: String)
        -> (style: TitleStyle, commands: [ProjectCommand])? {
        guard let title = project.titles.first(where: { $0.id == id }),
              let base = project.styles.first(where: { $0.id == title.styleID })?.basedOn,
              let saved = newStyle(fromTitle: id, applyingTo: others, in: project, newID: base,
                                   name: name)
        else { return nil }
        let ids = others.union([id])
            .union(project.titles.filter { $0.styleID == base }.map(\.id))
        return (saved.style, saved.commands.dropLast() + [.setTitlesLook(ids: ids, style: saved.style)])
    }

    /// `true` when title `id`'s style is its own: not a library style and
    /// used by no other title. Such a style is edited in place.
    public static func titleHasPrivateStyle(_ id: UUID, in project: Project,
                                            libraryStyleIDs: Set<UUID>) -> Bool {
        guard let title = project.titles.first(where: { $0.id == id }),
              !libraryStyleIDs.contains(title.styleID) else { return false }
        return !project.titles.contains { $0.id != id && $0.styleID == title.styleID }
    }

    /// `true` when the titles in `ids` all use one style that is not a library
    /// style and that no other title uses. Such a style is edited in place.
    public static func titlesHavePrivateStyle(_ ids: Set<UUID>, in project: Project,
                                              libraryStyleIDs: Set<UUID>) -> Bool {
        let group = project.titles.filter { ids.contains($0.id) }
        guard !ids.isEmpty, group.count == ids.count,
              let styleID = group.first?.styleID, !libraryStyleIDs.contains(styleID),
              group.allSatisfy({ $0.styleID == styleID }) else { return false }
        return !project.titles.contains { !ids.contains($0.id) && $0.styleID == styleID }
    }

    /// The command that applies `edited` (a changed copy of the first
    /// selected title's style) to the titles in `ids` and no others. A style
    /// private to the group keeps its ID; otherwise the whole group gets one
    /// fork, `forkID`, named "<name> (custom)", whose `basedOn` names the
    /// library style it came from. One title uses
    /// `titleLook(_:forTitle:in:libraryStyleIDs:forkID:)`.
    /// - Returns: `nil` if `ids` is empty or names a missing title.
    public static func titlesLook(_ edited: TitleStyle, forTitles ids: Set<UUID>,
                                  in project: Project, libraryStyleIDs: Set<UUID>,
                                  forkID: UUID = UUID()) -> ProjectCommand? {
        if ids.count == 1, let id = ids.first {
            return titleLook(edited, forTitle: id, in: project, libraryStyleIDs: libraryStyleIDs,
                             forkID: forkID)
        }
        guard !ids.isEmpty, ids.isSubset(of: project.titles.map(\.id)) else { return nil }
        if titlesHavePrivateStyle(ids, in: project, libraryStyleIDs: libraryStyleIDs) {
            return .setTitlesLook(ids: ids, style: edited)
        }
        var fork = edited
        fork.basedOn = libraryStyleIDs.contains(edited.id) ? edited.id : edited.basedOn
        fork.id = forkID
        let suffix = " (custom)"
        if !fork.name.hasSuffix(suffix) { fork.name += suffix }
        return .setTitlesLook(ids: ids, style: fork)
    }

    /// The `setTitleLook` that applies `edited`, a changed copy of title
    /// `id`'s style, to that title only. A private style keeps its ID; any
    /// other is forked to `forkID`, named "<name> (custom)".
    /// - Returns: `nil` if the title is missing.
    public static func titleLook(_ edited: TitleStyle, forTitle id: UUID, in project: Project,
                                 libraryStyleIDs: Set<UUID>,
                                 forkID: UUID = UUID()) -> ProjectCommand? {
        guard project.titles.contains(where: { $0.id == id }) else { return nil }
        if titleHasPrivateStyle(id, in: project, libraryStyleIDs: libraryStyleIDs) {
            return .setTitleLook(id: id, style: edited)
        }
        var fork = edited
        fork.basedOn = libraryStyleIDs.contains(edited.id) ? edited.id : edited.basedOn
        fork.id = forkID
        let suffix = " (custom)"
        if !fork.name.hasSuffix(suffix) { fork.name += suffix }
        return .setTitleLook(id: id, style: fork)
    }

    /// Appends a copy of each title with the given ID, anchored at the given
    /// output start. Copies at or past the timeline end are skipped; styles
    /// are embedded only for copies that land.
    /// - Returns: `false`, leaving `project` unchanged, if none land or a
    ///   landing copy's style is in neither the project nor `styles`.
    private static func insertCopies(_ copies: [(title: Title, id: UUID, start: Tick)],
                                     styles: [TitleStyle], in project: inout Project) -> Bool {
        let total = TimelineMath.outputDuration(project)
        var next = project
        var added = 0
        for copy in copies where copy.start < total {
            guard copy.title.duration > 0,
                  let location = TimelineMath.locate(copy.start, in: project) else { continue }
            if !next.styles.contains(where: { $0.id == copy.title.styleID }) {
                guard let style = styles.first(where: { $0.id == copy.title.styleID }) else {
                    return false
                }
                embed(style, in: &next)
            }
            var title = copy.title
            title.id = copy.id
            title.anchor = TitleAnchor(segmentID: location.segmentID, offset: location.offset)
            next.titles.append(title)
            added += 1
        }
        guard added > 0 else { return false }
        project = next
        return true
    }

    /// Copies `style` into the project unless a style with its ID is already there.
    /// An existing copy is kept as is: the project's copy wins (§5.2).
    private static func embed(_ style: TitleStyle, in project: inout Project) {
        if !project.styles.contains(where: { $0.id == style.id }) {
            project.styles.append(style)
        }
    }

    /// `true` if `ids` are distinct and name no segment in `project`.
    private static func areFresh(_ ids: [UUID], in project: Project) -> Bool {
        Set(ids).count == ids.count
            && !project.segments.contains { ids.contains($0.id) }
    }

    /// Grows the gap before `index` by `amount` (shrinks it for a negative
    /// amount, to no less than zero), or opens one there for a positive amount.
    /// Opens none before the first segment.
    /// - Returns: `true` if a gap was inserted, shifting the clip to `index + 1`.
    @discardableResult
    private static func resizeGap(before index: Int, by amount: Tick, in segments: inout [Segment],
                                  newID: inout IndexingIterator<[UUID]>) -> Bool {
        if index > 0, case .gap(var gap) = segments[index - 1] {
            gap.duration = max(gap.duration + amount, 0)
            segments[index - 1] = .gap(gap)
        } else if index > 0, amount > 0, let id = newID.next() {
            segments.insert(.gap(GapSegment(id: id, duration: amount)), at: index)
            return true
        }
        return false
    }

    /// As `resizeGap(before:)`, for the gap after `index`. Opens none after
    /// the last segment.
    private static func resizeGap(after index: Int, by amount: Tick, in segments: inout [Segment],
                                  newID: inout IndexingIterator<[UUID]>) {
        let next = index + 1
        guard next < segments.count else { return }
        if case .gap(var gap) = segments[next] {
            gap.duration = max(gap.duration + amount, 0)
            segments[next] = .gap(gap)
        } else if amount > 0, let id = newID.next() {
            segments.insert(.gap(GapSegment(id: id, duration: amount)), at: next)
        }
    }

    /// Where each title anchored to a gap starts, with that gap's ID and duration.
    private static func gapTitleStarts(
        _ project: Project
    ) -> [UUID: (gapID: UUID, duration: Tick, start: Tick)] {
        var result: [UUID: (gapID: UUID, duration: Tick, start: Tick)] = [:]
        var cursor: Tick = 0
        for segment in project.segments {
            if segment.isGap {
                for title in project.titles where title.anchor.segmentID == segment.id {
                    result[title.id] = (segment.id, segment.duration, cursor + title.anchor.offset)
                }
            }
            cursor += segment.duration
        }
        return result
    }

    /// Titles on a gap that an edit resized or removed keep their output start,
    /// re-anchored to whatever is there now. Titles on an untouched gap move with it.
    private static func relocate(_ starts: [UUID: (gapID: UUID, duration: Tick, start: Tick)],
                                 in project: inout Project) {
        let unchanged = starts.filter { _, recorded in
            project.segments.contains { $0.id == recorded.gapID && $0.isGap
                && $0.duration == recorded.duration }
        }
        reanchor(starts.filter { unchanged[$0.key] == nil }.mapValues(\.start), in: &project)
    }

    /// Anchors each title in `starts` to the segment at its output start,
    /// clamped to the timeline. Deletes them when the timeline is empty.
    /// Whether `clip` overlaps none of `others`.
    private static func fits(_ clip: MusicClip, among others: [MusicClip]) -> Bool {
        !others.contains { $0.start < clip.end && clip.start < $0.end }
    }

    private static func reanchor(_ starts: [UUID: Tick], in project: inout Project) {
        guard !starts.isEmpty else { return }
        let total = TimelineMath.outputDuration(project)
        guard total > 0 else {
            project.titles.removeAll { starts[$0.id] != nil }
            return
        }
        for index in project.titles.indices {
            guard let start = starts[project.titles[index].id],
                  let location = TimelineMath.locate(min(max(start, 0), total - 1),
                                                     in: project) else { continue }
            project.titles[index].anchor = TitleAnchor(segmentID: location.segmentID,
                                                       offset: location.offset)
        }
    }

    /// Merges adjacent gaps (the first keeps its ID; titles keep their output
    /// start) and drops empty gaps and, unless `keepingTrailingGap`, a
    /// trailing gap, re-anchoring their titles.
    private static func normalizeGaps(in project: inout Project,
                                      keepingTrailingGap: Bool = false) {
        var merged: [Segment] = []
        for segment in project.segments {
            if case .gap(let gap) = segment, case .gap(var previous)? = merged.last {
                for index in project.titles.indices
                where project.titles[index].anchor.segmentID == gap.id {
                    project.titles[index].anchor = TitleAnchor(
                        segmentID: previous.id,
                        offset: project.titles[index].anchor.offset + previous.duration)
                }
                previous.duration += gap.duration
                merged[merged.count - 1] = .gap(previous)
            } else {
                merged.append(segment)
            }
        }
        project.segments = merged

        var dropped = Set(merged.filter { $0.isGap && $0.duration <= 0 }.map(\.id))
        if !keepingTrailingGap, let last = merged.last, last.isGap { dropped.insert(last.id) }
        guard !dropped.isEmpty else { return }
        var starts: [UUID: Tick] = [:]
        for title in project.titles where dropped.contains(title.anchor.segmentID) {
            if let start = TimelineMath.segmentStart(title.anchor.segmentID, in: project) {
                starts[title.id] = start + title.anchor.offset
            }
        }
        project.segments.removeAll { dropped.contains($0.id) }
        reanchor(starts, in: &project)
    }

    private var removesEndTransition: Bool {
        if case .setClipTransition(.end, .none) = self { true } else { false }
    }

    /// Keeps the video's end transition on the last segment, wherever an
    /// edit left it, and off every other. `previous` is the one before the
    /// edit, restored if the edit deleted the segment that held it.
    private func keepEndTransition(_ previous: ClipTransition?, in project: inout Project) {
        guard let last = project.segments.indices.last else { return }
        var end = project.segments[last].transitionOut
            ?? project.segments.lazy.compactMap(\.transitionOut).last
        if end == nil, !removesEndTransition { end = previous }
        for index in project.segments.indices where index != last {
            project.segments[index].transitionOut = nil
        }
        project.segments[last].transitionOut = end
    }

    private static func edit(_ id: UUID, in project: inout Project,
                             _ change: (inout Title) -> Void) -> Bool {
        guard let index = project.titles.firstIndex(where: { $0.id == id }) else { return false }
        change(&project.titles[index])
        return true
    }
}
