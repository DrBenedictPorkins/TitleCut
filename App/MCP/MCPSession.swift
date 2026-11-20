import AppKit
import Foundation
import TitleCutCore

/// One open project as the MCP tools see it. Created by its window's
/// `ContentView`, which supplies the window state the store does not hold.
@MainActor
final class MCPSession {
    let store: ProjectStore
    let player: PlayerController
    weak var window: NSWindow?

    var name: () -> String = { "Untitled" }
    var isEdited: () -> Bool = { false }
    /// Every video's resolved file, keyed by `VideoSegment.sourceID`; a
    /// missing video has none.
    var sourceURLs: () -> [UUID?: URL] = { [:] }
    /// One per video transcribed.
    var transcripts: () -> [Transcript] = { [] }
    /// Stores a transcript in place of any earlier one of its video.
    var setTranscript: (Transcript) -> Void = { _ in }
    var renderSize: () -> CGSize = { .zero }
    var libraryStyles: () -> [TitleStyle] = { StyleLibrary.builtIns }
    var defaultStyleID: () -> UUID = { StyleLibrary.lowerThirdID }
    /// Each video's audio peaks, keyed by `VideoSegment.sourceID`.
    var waveforms: () -> [UUID?: Waveform] = { [:] }
    /// Gives the project a new ID and marks the document for saving.
    var renewProjectID: () -> Void = {}

    /// The latest auto_captions or export run.
    var job: MCPJob?
    var jobTask: Task<Void, Never>?

    init(store: ProjectStore, player: PlayerController) {
        self.store = store
        self.player = player
    }

    var project: Project { store.project }

    // MARK: Dispatch

    func handle(_ tool: String, _ args: MCPArguments) async -> MCPReply {
        switch tool {
        case "get_project": return .json(snapshot)
        case "undo", "redo": return undoOrRedo(tool == "undo")
        case "save": return save()
        case "open_video": return await openVideo(args)
        case "add_video": return await addVideo(args)
        case "set_shape": return setShape(args)
        case "seek":
            guard let seconds = args.number("seconds") else { return missing("seconds") }
            player.seek(toSeconds: max(seconds, 0))
            return .text("Playhead at \(format(seconds)) s.")
        case "play", "pause":
            if player.isPlaying != (tool == "play") { player.togglePlayPause() }
            return .text(tool == "play" ? "Playing." : "Paused.")
        case "split_at", "delete_segment", "move_segment", "trim_segment", "set_framing",
             "set_split", "set_clip",
             "freeze_frame", "set_freeze_length", "set_camera", "reset_camera", "insert_card",
             "set_card":
            return await clipTool(tool, args)
        case "set_transition", "remove_transition":
            return transitionTool(tool, args)
        case "list_styles", "add_title", "update_title", "delete_titles", "duplicate_titles",
             "set_titles_style":
            return titleTool(tool, args)
        case "auto_captions": return await startAutoCaptions(args)
        case "get_transcript": return await transcriptReply()
        case "export_subtitles": return exportSubtitles(args)
        case "find_silences", "remove_silences":
            return silences(args, remove: tool == "remove_silences")
        case "frame_faces": return await frameFaces()
        case "find_fillers", "remove_fillers":
            return await fillers(remove: tool == "remove_fillers")
        case "add_music", "update_music", "delete_music", "duplicate_music":
            return await musicTool(tool, args)
        case "render_frame": return await renderFrame(args)
        case "export": return startExport(args)
        case "job_status": return jobStatus()
        default: return .error("TitleCut does not know the tool \(tool).")
        }
    }

    // MARK: Helpers

    func missing(_ field: String) -> MCPReply { .error("Give \(field).") }

    /// The first video's file, if found.
    func sourceURL() -> URL? { sourceURLs()[UUID?.none] }

    /// Whether the project has a video and every video's file is found.
    var allVideosFound: Bool {
        let urls = sourceURLs()
        return project.source != nil && project.sourcesByKey.allSatisfy { urls[$0.key] != nil }
    }

    /// The videos the timeline plays, with their files.
    func usedVideos() -> [(key: UUID?, url: URL)] {
        let urls = sourceURLs()
        return project.usedSourceKeys.compactMap { key in urls[key].map { (key, $0) } }
    }

    /// The error when a video's file is missing.
    var missingVideo: MCPReply {
        .error("A video of this project cannot be found. get_project lists each video with "
               + "found; ask the person to locate it in TitleCut.")
    }

    func format(_ seconds: Double) -> String { String(format: "%.3g", seconds) }

    /// Runs `commands` as one undo step named `name`. Returns whether any applied.
    @discardableResult
    func perform(_ commands: [ProjectCommand], name: String) -> Bool {
        guard !commands.isEmpty else { return false }
        if commands.count == 1 { return store.perform(commands[0]) }
        return store.perform(commands, named: name)
    }

    /// Converts any `Encodable` to JSON for a reply.
    func json<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return decoded
    }

    private func undoOrRedo(_ undo: Bool) -> MCPReply {
        guard let manager = store.undoManager else { return .error("Undo is not available.") }
        if undo {
            guard manager.canUndo else { return .error("Nothing to undo.") }
            let name = manager.undoActionName
            manager.undo()
            return .text("Undid \(name.isEmpty ? "the last edit" : name).")
        }
        guard manager.canRedo else { return .error("Nothing to redo.") }
        let name = manager.redoActionName
        manager.redo()
        return .text("Redid \(name.isEmpty ? "the last edit" : name).")
    }

    private func save() -> MCPReply {
        guard let window, let document = NSDocumentController.shared.document(for: window) else {
            return .error("This project's window could not be found.")
        }
        let untitled = document.fileURL == nil
        document.save(nil)
        return .text(untitled ? "The save panel is open in TitleCut; the person chooses where."
                              : "Saved \(name()).")
    }

    private func openVideo(_ args: MCPArguments) async -> MCPReply {
        guard let path = args.string("path") else { return missing("path") }
        guard project.source == nil else {
            return .error("This project already has a video. Call new_project first.")
        }
        guard MCPFolders.shared.allows(URL(fileURLWithPath: path)) else {
            return .error(MCPFolders.shared.refusal(for: path))
        }
        do {
            let source = try await SourceVideo.load(from: URL(fileURLWithPath: path))
            store.perform(.setSource(source, segmentID: UUID()))
            return .text("Opened \(URL(fileURLWithPath: path).lastPathComponent): "
                         + "\(format(Ticks.seconds(source.duration))) s, "
                         + "\(Int(source.naturalSize.width))x\(Int(source.naturalSize.height)).")
        } catch {
            return .error("\(path) could not be opened: \(error.localizedDescription)")
        }
    }

    private func addVideo(_ args: MCPArguments) async -> MCPReply {
        guard let path = args.string("path") else { return missing("path") }
        guard project.source != nil else { return .error("Open a video first with open_video.") }
        let url = URL(fileURLWithPath: path)
        guard MCPFolders.shared.allows(url) else { return .error(MCPFolders.shared.refusal(for: path)) }
        do {
            let source = try await SourceVideo.load(from: url)
            let id = UUID()
            guard store.perform(.addVideo(source, segmentID: id)),
                  let range = TimelineMath.segmentRange(id, in: project) else {
                return .error("\(url.lastPathComponent) is too short to add.")
            }
            return .text("Added \(url.lastPathComponent) at the end, "
                         + "\(format(Ticks.seconds(range.start)))–\(format(Ticks.seconds(range.end))) s; "
                         + "the clip is \(id.uuidString).")
        } catch {
            return .error("\(path) could not be added: \(error.localizedDescription)")
        }
    }

    private func setShape(_ args: MCPArguments) -> MCPReply {
        guard let source = project.source else { return .error("Open a video first.") }
        let shapes: [String: OutputShape] = ["original": .original, "16:9": .landscape,
                                             "9:16": .portrait, "1:1": .square]
        guard let name = args.string("shape"), let shape = shapes[name] else {
            return .error("shape is one of original, 16:9, 9:16, 1:1.")
        }
        let size = shape.size(for: source)
        if size != project.output.size { store.perform(.setOutputSize(size)) }
        return .text("Shape \(name): \(Int(size.width))x\(Int(size.height)).")
    }

    // MARK: Snapshot

    /// Everything about the project, for get_project.
    var snapshot: JSONValue {
        var root: [String: JSONValue] = [
            "id": .string(project.id.uuidString),
            "name": .string(name()),
            "saved": .bool(!isEdited()),
            "output": .object([
                "width": .number(renderSize().width), "height": .number(renderSize().height),
                "shape": .string(shapeName),
                "frame_rate": .number(project.output.frameRate),
                "codec": .string(project.output.codec.rawValue),
                "duration": .seconds(TimelineMath.outputDuration(project)),
            ]),
            "playhead": .number((player.currentTime * 1000).rounded() / 1000),
            "playing": .bool(player.isPlaying),
            "undo": .string(store.undoManager?.canUndo == true
                            ? store.undoManager?.undoActionName ?? "" : ""),
            "redo": .string(store.undoManager?.canRedo == true
                            ? store.undoManager?.redoActionName ?? "" : ""),
            "selection": .object([
                "titles": .array(store.selectedTitleIDs.map { .string($0.uuidString) }),
                "segment": store.selectedSegmentID.map { .string($0.uuidString) } ?? .null,
                "music": store.selectedMusicID.map { .string($0.uuidString) } ?? .null,
                "transition": store.selectedTransition.map { .string(pointName($0)) } ?? .null,
            ]),
            "segments": .array(segmentsJSON),
            "end_transition": clipTransitionJSON(project.segments.last?.transitionOut),
            "titles": .array(titlesJSON),
            "music": .array(project.music.map(musicJSON)),
            "transcripts": transcriptSummary,
            "default_style": .string(libraryStyles().first { $0.id == defaultStyleID() }?.name
                                     ?? ""),
        ]
        root["source"] = project.source.map { videoJSON($0, key: nil) } ?? .null
        root["added_videos"] = .array(project.addedSources.map { videoJSON($0, key: $0.id) })
        root["job"] = job.map(\.json) ?? .null
        return .object(root)
    }

    /// A video, with `id` for the clips that play it (`video` on a
    /// segment); the first video has none.
    private func videoJSON(_ source: SourceVideo, key: UUID?) -> JSONValue {
        let url = sourceURLs()[key]
        var item: [String: JSONValue] = [
            "path": .string(url?.path ?? source.lastKnownPath),
            "found": .bool(url != nil),
            "duration": .seconds(source.duration),
            "width": .number(source.naturalSize.width),
            "height": .number(source.naturalSize.height),
            "frame_rate": .number(source.frameRate),
            "has_audio": waveforms()[key].map { _ in JSONValue.bool(true) } ?? .null,
        ]
        if let key { item["id"] = .string(key.uuidString) }
        return .object(item)
    }

    private var shapeName: String {
        guard let source = project.source,
              let shape = OutputShape.of(project.output.size, source: source) else { return "" }
        return shape.label.lowercased()
    }

    private var segmentsJSON: [JSONValue] {
        var cursor: Tick = 0
        return project.segments.map { segment in
            defer { cursor += segment.duration }
            var item: [String: JSONValue] = [
                "id": .string(segment.id.uuidString),
                "start": .seconds(cursor), "end": .seconds(cursor + segment.duration),
                "duration": .seconds(segment.duration),
                "transition_in": clipTransitionJSON(segment.transitionIn),
            ]
            switch segment {
            case .video(let video):
                item["kind"] = .string("video")
                item["video"] = video.sourceID.map { .string($0.uuidString) } ?? .string("first")
                item["source_start"] = .seconds(video.sourceRange.start)
                item["source_end"] = .seconds(video.sourceRange.end)
                item["framing"] = .number(video.framing ?? 0.5)
                item["framing_y"] = .number(video.frame.y)
                item["zoom"] = .number(video.frame.zoom)
                func halfJSON(_ frame: ClipFraming) -> JSONValue {
                    .object(["x": .number(frame.x), "y": .number(frame.y),
                             "zoom": .number(frame.zoom)])
                }
                item["split"] = video.split.map {
                    .object(["first": halfJSON($0.first), "second": halfJSON($0.second)])
                } ?? .null
                item["speed"] = .number(video.rate)
                item["volume"] = .number(video.volume ?? 1)
            case .still(let still):
                item["kind"] = .string("freeze")
                if let end = still.zoom.last, still.zoom.count > 1 {
                    item["camera"] = .object([
                        "center_x": .number(end.center.x), "center_y": .number(end.center.y),
                        "scale": .number(end.scale), "pace": .string(Self.paceName(end.easing)),
                        "hold": .seconds(still.hold),
                    ])
                } else {
                    item["camera"] = .null
                }
            case .card(let card):
                item["kind"] = .string("card")
                item["color"] = .string(Self.hex(card.color))
            case .gap:
                item["kind"] = .string("gap")
            }
            return .object(item)
        }
    }

    private var titlesJSON: [JSONValue] {
        project.titles.compactMap { title -> JSONValue? in
            let range = TimelineMath.titleOutputRange(title, in: project)
            let style = project.styles.first { $0.id == title.styleID }
            let library = libraryStyles().contains { $0.id == title.styleID }
                || StyleLibrary.builtIns.contains { $0.id == title.styleID }
            var item: [String: JSONValue] = [
                "id": .string(title.id.uuidString),
                "text": .string(title.text),
                "start": range.map { .seconds($0.start) } ?? .null,
                "end": range.map { .seconds($0.end) } ?? .null,
                "duration": .seconds(title.duration),
                "segment": .string(title.anchor.segmentID.uuidString),
                "style": .string(style?.name ?? ""),
                "own_look": .bool(!library),
                "caption": .bool(title.origin == .autoCaption),
                "transition_in": transitionJSON(title.transitionIn),
                "transition_out": transitionJSON(title.transitionOut),
                "look": style.map { json($0.applying(title.styleOverrides)) } ?? .null,
            ]
            if let position = title.styleOverrides?.position {
                item["position"] = positionJSON(position)
            }
            if let size = title.styleOverrides?.fontSizeRatio, let base = style?.fontSizeRatio,
               base > 0 {
                item["size_percent"] = .number((size / base * 100).rounded())
            }
            return .object(item)
        }
    }

    private func transitionJSON(_ transition: Transition) -> JSONValue {
        .object(["kind": .string(Self.transitionName(transition.kind)),
                 "seconds": .seconds(transition.duration)])
    }

    private func positionJSON(_ position: NormalizedPosition) -> JSONValue {
        switch position {
        case .top: .string("top")
        case .center: .string("center")
        case .lowerThird: .string("lower_third")
        case .bottom: .string("bottom")
        case let .custom(x, y): .object(["x": .number(x), "y": .number(y)])
        }
    }

    func musicJSON(_ clip: MusicClip) -> JSONValue {
        .object([
            "id": .string(clip.id.uuidString), "name": .string(clip.name),
            "start": .seconds(clip.start), "end": .seconds(clip.end),
            "song_start": .seconds(clip.songRange.start), "song_end": .seconds(clip.songRange.end),
            "song_length": .seconds(clip.songDuration), "volume": .number(clip.volume),
            "fade_in": .seconds(clip.fadeIn), "fade_out": .seconds(clip.fadeOut),
        ])
    }

    private var transcriptSummary: JSONValue {
        .array(transcripts().map { transcript in
            .object(["language": .string(transcript.locale),
                     "words": .number(Double(transcript.words.count))])
        })
    }

    static func transitionName(_ kind: TransitionKind) -> String {
        switch kind {
        case .none: "none"
        case .fade: "fade"
        case .slide: "slide"
        case .scale: "scale"
        case .typewriter: "typewriter"
        }
    }

    static func paceName(_ easing: Easing) -> String {
        switch easing {
        case .linear: "steady"
        case .easeInOut: "smooth"
        case .easeIn: "speed_up"
        case .easeOut: "slow_down"
        }
    }

    static func easing(pace: String?) -> Easing? {
        switch pace {
        case nil, "smooth": .easeInOut
        case "steady": .linear
        case "speed_up": .easeIn
        case "slow_down": .easeOut
        default: nil
        }
    }
}

/// An auto_captions or export run, for job_status.
struct MCPJob {
    enum State: String { case running, done, failed }

    let kind: String
    var state: State = .running
    var progress: Double = 0
    var message = ""

    var json: JSONValue {
        .object(["kind": .string(kind), "state": .string(state.rawValue),
                 "progress": .number((progress * 100).rounded() / 100),
                 "message": .string(message)])
    }
}
