import MCP

/// Every tool the helper offers, and the get_instructions text (§10).
enum ToolCatalog {
    private enum Kind: String { case string, number, boolean, array, object }

    private struct Field {
        let name: String
        let kind: Kind
        let about: String
        var required = false
        var choices: [String]? = nil
    }

    private static func field(_ name: String, _ kind: Kind, _ about: String,
                              required: Bool = false, choices: [String]? = nil) -> Field {
        Field(name: name, kind: kind, about: about, required: required, choices: choices)
    }

    /// Every tool can name a project by ID or name; required when more than one is open.
    private static let project = field(
        "project", .string, "Project ID (preferred) or name, as list_projects shows them. Required "
        + "when more than one project is open; otherwise the only one.")

    private static func tool(_ name: String, _ about: String, _ fields: [Field] = [],
                             readOnly: Bool = false) -> Tool {
        var properties: [String: Value] = [:]
        for field in fields + [project] {
            var schema: [String: Value] = ["type": .string(field.kind.rawValue),
                                           "description": .string(field.about)]
            if field.kind == .array { schema["items"] = .object(["type": .string("string")]) }
            if let choices = field.choices { schema["enum"] = .array(choices.map(Value.string)) }
            properties[field.name] = .object(schema)
        }
        let required = fields.filter(\.required).map { Value.string($0.name) }
        return Tool(name: name, description: about,
                    inputSchema: .object(["type": .string("object"),
                                          "properties": .object(properties),
                                          "required": .array(required)]),
                    annotations: .init(readOnlyHint: readOnly))
    }

    private static let seconds = "Seconds of finished-video (output) time"
    private static let positions = ["style", "top", "center", "lower_third", "bottom", "custom"]
    private static let transitions = ["none", "fade", "slide", "scale", "typewriter"]
    private static let paces = ["steady", "smooth", "speed_up", "slow_down"]
    private static let clipTransitions = ["dip_to_black", "dip_to_white", "crossfade"]
    private static let transitionPoint = field(
        "at", .string, "Where: start (the video's start), end (the video's end), or a "
        + "segment ID for the cut before that segment (the first segment's ID is the start)",
        required: true)

    static let tools: [Tool] = [
        tool("get_instructions", "Read first: the full manual — what TitleCut is, every tool with its parameters, conventions and examples.",
             readOnly: true),

        // Session
        tool("list_projects", "Open projects, front window first: ID, name, whether a video "
             + "is set, saved state.", readOnly: true),
        tool("get_project", "Full snapshot as JSON: the first video (source) and added "
             + "videos, shape, playhead, selection, saved state, undo/redo names, every clip "
             + "(output and source times, its video, framing, freeze camera, transition at its "
             + "start), the end transition, title (times, text, full look), music piece, "
             + "transcripts, running jobs.", readOnly: true),
        tool("new_project", "Opens a new untitled project window and brings it to the front. "
             + "Call list_projects for its ID."),
        tool("undo", "Undoes the last edit (any edit, by Claude or the person)."),
        tool("redo", "Redoes the last undone edit."),
        tool("save", "Saves the project. An untitled project asks the person where to save."),

        // Video, shape, playback
        tool("open_video", "Sets the source video of a project that has none.",
             [field("path", .string, "Absolute path of a video file", required: true)]),
        tool("add_video", "Adds another video as one clip at the end of the timeline, the "
             + "whole video. Split, trim and move it like any clip. The first video still "
             + "sets the shape; others fill the frame, cropped.",
             [field("path", .string, "Absolute path of a video file", required: true)]),
        tool("set_shape", "Output frame shape. The video fills it, cropped at the centre.",
             [field("shape", .string, "Frame shape", required: true,
                    choices: ["original", "16:9", "9:16", "1:1"])]),
        tool("seek", "Moves the playhead.", [field("seconds", .number, seconds, required: true)]),
        tool("play", "Starts playback."),
        tool("pause", "Pauses playback."),

        // Clips
        tool("split_at", "Splits the clip under a time into two.",
             [field("seconds", .number, seconds, required: true)]),
        tool("delete_segment", "Deletes a clip, freeze or gap and the titles on it; later "
             + "clips close up.", [field("id", .string, "Segment ID", required: true)]),
        tool("move_segment", "Moves a clip, freeze or card, as in Final Cut: its old place "
             + "closes up, and to_seconds is measured on the timeline without it. On another "
             + "clip it goes in at that clip's nearer edge and later clips slide right; in a "
             + "gap it takes that place; past the end it is appended.",
             [field("id", .string, "Segment ID", required: true),
              field("to_seconds", .number, seconds, required: true)]),
        tool("trim_segment", "Sets which part of the source video a clip plays. Other clips "
             + "stay put: a shortened edge leaves a gap on that side (closing up at the "
             + "video's start and end); a lengthened edge fills the gap, then pushes later "
             + "clips right.",
             [field("id", .string, "Video segment ID", required: true),
              field("source_start", .number, "Seconds into the source video", required: true),
              field("source_end", .number, "Seconds into the source video", required: true)]),
        tool("frame_faces", "Sets every video clip's framing so the largest face in it is "
             + "centred, for a 9:16 or 1:1 frame. Where the face settles somewhere new for a "
             + "second or more, the clip is split there and each part framed. Clips without a "
             + "face keep theirs. One undo step. Takes a few seconds."),
        tool("set_framing", "Where the frame sits on a clip and how far it is magnified. "
             + "framing is across the picture (0 left edge, 0.5 centre, 1 right edge), y down "
             + "it (0 top, 1 bottom), zoom 1...6 (2 shows half the width and height, "
             + "magnified). Give at least one; the others keep their values.",
             [field("id", .string, "Video segment ID", required: true),
              field("framing", .number, "0...1, across; optional"),
              field("y", .number, "0...1, down; optional"),
              field("zoom", .number, "1...6; optional")]),
        tool("set_split", "Split screen: shows a clip as two halves of the frame at once, "
             + "stacked in a tall or square frame (first on top), side by side in a wide one "
             + "(first on the left). Each half has its own framing as in set_framing (x across, "
             + "y down, zoom 1...6), e.g. an interviewer and a guest. split false shows the "
             + "clip whole again.",
             [field("id", .string, "Video segment ID", required: true),
              field("split", .boolean, "Default true"),
              field("first", .number, "0...1, top or left half; default 0.25, or unchanged"),
              field("second", .number, "0...1, bottom or right half; default 0.75, or "
                    + "unchanged"),
              field("first_y", .number, "0...1, top or left half, down; default 0.5, or "
                    + "unchanged"),
              field("first_zoom", .number, "1...6, top or left half; default 1, or unchanged"),
              field("second_y", .number, "0...1, bottom or right half, down; default 0.5, or "
                    + "unchanged"),
              field("second_zoom", .number, "1...6, bottom or right half; default 1, or "
                    + "unchanged")]),
        tool("set_clip", "Sets a video clip's speed and the volume of its sound. Speed changes "
             + "the clip's length (later clips move); speech keeps its pitch; titles on it "
             + "stay with their footage. One undo step.",
             [field("id", .string, "Video segment ID", required: true),
              field("speed", .number, "0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8 or 10"),
              field("volume", .number, "0...2: 1 unchanged, 0 mute, 2 twice as loud")]),
        tool("freeze_frame", "Freezes what the frame shows at a time into a still segment "
             + "inserted there; everything after moves later. Silent.",
             [field("seconds", .number, seconds, required: true),
              field("duration", .number, "Seconds; default 3")]),
        tool("insert_card", "Inserts a title card, a length of solid colour for titles, at a "
             + "time: at a cut it goes before the clip there; inside a clip it splits it; at "
             + "the end it is appended. Everything after moves later. Silent.",
             [field("seconds", .number, seconds, required: true),
              field("duration", .number, "Seconds; default 3"),
              field("color", .string, "#RRGGBB or #RRGGBBAA; default black")]),
        tool("set_card", "Changes a title card's colour or length.",
             [field("id", .string, "Card segment ID", required: true),
              field("color", .string, "#RRGGBB or #RRGGBBAA"),
              field("duration", .number, "Seconds")]),
        tool("set_freeze_length", "Sets a freeze's length; its camera motion stretches.",
             [field("id", .string, "Freeze segment ID", required: true),
              field("seconds", .number, "New length", required: true)]),
        tool("set_camera", "Camera motion of a freeze: from the whole frame to this view, "
             + "then holding it for `hold` seconds to the freeze's end.",
             [field("id", .string, "Freeze segment ID", required: true),
              field("center_x", .number, "0...1 across the still, left to right", required: true),
              field("center_y", .number, "0...1 down the still, top to bottom", required: true),
              field("scale", .number, "Zoom, 1 (fills the frame) to 8; below 1 down to the scale that fits the whole picture with bars", required: true),
              field("hold", .number, "Seconds the last view stays after the motion, 0 to "
                    + "10; the freeze grows to fit. Default the current hold"),
              field("pace", .string, "Default smooth", choices: paces)]),
        tool("reset_camera", "Removes a freeze's camera motion.",
             [field("id", .string, "Freeze segment ID", required: true)]),
        tool("set_transition", "Puts a transition at a cut between segments, the video's "
             + "start or its end, replacing any there. It plays across the cut, half before "
             + "and half after, and never changes the video's length; at the start or end "
             + "a dip is a fade from or to the colour. A crossfade blends the two clips, "
             + "each run on past its cut in the source; cuts only.",
             [transitionPoint,
              field("kind", .string, "Transition", required: true, choices: clipTransitions),
              field("duration", .number, "Seconds, 0.1 to 5; default 1, or the length of the "
                    + "transition already there. Each half is shortened as it plays to at "
                    + "most half the segment on its side")]),
        tool("remove_transition", "Removes the transition at a cut, the start or the end.",
             [transitionPoint]),

        // Titles
        tool("list_styles", "Title styles: library styles and the default for new titles.",
             readOnly: true),
        tool("add_title", "Adds a title at a time.",
             [field("text", .string, "Title text; newlines allowed", required: true),
              field("seconds", .number, seconds, required: true),
              field("duration", .number, "Seconds; default 3"),
              field("style", .string, "Style name or ID; default the default style")]),
        tool("update_title", "Changes one title. Only the fields given change. Look fields "
             + "give the title its own look, as Customise does in the app.",
             [field("id", .string, "Title ID", required: true),
              field("text", .string, "New text"),
              field("start", .number, seconds),
              field("duration", .number, "Seconds"),
              field("position", .string, "Landing spot", choices: positions),
              field("x", .number, "With position custom: 0...1 across"),
              field("y", .number, "With position custom: 0...1 down"),
              field("size_percent", .number, "Percent of the style's size, 25...300"),
              field("transition_in", .string, "In motion", choices: transitions),
              field("transition_in_seconds", .number, "In motion length"),
              field("transition_out", .string, "Out motion", choices: transitions),
              field("transition_out_seconds", .number, "Out motion length"),
              field("font", .string, "Font family name"),
              field("weight", .string, "Font weight",
                    choices: ["ultraLight", "thin", "light", "regular", "medium", "semibold",
                              "bold", "heavy", "black"]),
              field("color", .string, "Text colour, #RRGGBB or #RRGGBBAA"),
              field("outline_color", .string, "Outline colour; with outline_width"),
              field("outline_width", .number,
                    "Outline width as a fraction of the font size, e.g. 0.05; 0 removes"),
              field("box_color", .string, "Background box colour; \"none\" removes it"),
              field("shadow", .boolean, "Drop shadow on or off"),
              field("align", .string, "Text alignment; also places the title at the left "
                    + "margin, centre or right margin, keeping its height",
                    choices: ["left", "center", "right"]),
              field("highlight_color", .string,
                    "Word highlight colour for captions; \"none\" turns it off")]),
        tool("delete_titles", "Deletes titles.",
             [field("ids", .array, "Title IDs", required: true)]),
        tool("duplicate_titles", "Duplicates titles, each right after itself.",
             [field("ids", .array, "Title IDs", required: true)]),
        tool("set_titles_style", "Gives titles a library style (drops their own looks).",
             [field("ids", .array, "Title IDs", required: true),
              field("style", .string, "Style name or ID", required: true)]),

        // Captions
        tool("auto_captions", "Starts transcribing the video's speech on this Mac and replaces "
             + "earlier auto-captions with timed captions. Returns at once; poll job_status.",
             [field("language", .string, "BCP-47 code such as en-US; default the Mac's"),
              field("style", .string, "Style name or ID; default Subtitle")]),
        tool("get_transcript", "Every transcribed word with its source time, per video on "
             + "the timeline.", readOnly: true),
        tool("export_subtitles", "Saves the auto-captions as an .srt file.",
             [field("path", .string, "Absolute path ending in .srt", required: true)]),

        // Silences
        tool("find_silences", "Dry run: the pauses Remove Silences would cut, how many and "
             + "how many seconds, without changing anything.",
             [field("quieter_than_db", .number, "dB below the loudest part; default 30"),
              field("longer_than_seconds", .number, "Shortest pause cut; default 0.6")],
             readOnly: true),
        tool("remove_silences", "Cuts those pauses and closes up, as one undo step. Titles in "
             + "a cut move to the join.",
             [field("quieter_than_db", .number, "dB below the loudest part; default 30"),
              field("longer_than_seconds", .number, "Shortest pause cut; default 0.6")]),

        // Filler words
        tool("find_fillers", "Dry run: the filler sounds (um, uh, er, ah, hmm) Remove Filler "
             + "Words would cut, how many and how many seconds, without changing anything. "
             + "Needs a transcript (auto_captions).", readOnly: true),
        tool("remove_fillers", "Cuts those filler sounds and closes up, as one undo step. "
             + "Auto-captions are made again without them."),

        // Music
        tool("add_music", "Adds a song to the music strip (copied into the project).",
             [field("path", .string, "Absolute path of an audio file", required: true),
              field("seconds", .number, seconds + "; default the playhead")]),
        tool("update_music", "Changes a music piece. Pieces never overlap; moves and trims "
             + "stop at neighbours and the song's ends.",
             [field("id", .string, "Music piece ID", required: true),
              field("start", .number, seconds),
              field("song_start", .number, "Seconds into the song where the piece begins"),
              field("duration", .number, "Seconds"),
              field("volume", .number, "0...1"),
              field("fade_in", .number, "Seconds"),
              field("fade_out", .number, "Seconds")]),
        tool("delete_music", "Removes a music piece.",
             [field("id", .string, "Music piece ID", required: true)]),
        tool("duplicate_music", "Copies a music piece right after itself; later pieces move "
             + "right.", [field("id", .string, "Music piece ID", required: true)]),

        // Output
        tool("render_frame", "PNG of the finished frame at a time, titles included, so you "
             + "can see the result.",
             [field("seconds", .number, seconds, required: true),
              field("max_width", .number, "Pixels; default 960")], readOnly: true),
        tool("export", "Starts exporting an MP4 or an animated GIF without sound "
             + "(watermarked until the app is unlocked). Returns at once; poll job_status.",
             [field("path", .string, "Absolute path ending in .mp4 or .gif", required: true),
              field("format", .string, "Default from the path's extension",
                    choices: ["mp4", "gif"]),
              field("codec", .string, "MP4 only. Default the project's",
                    choices: ["h264", "hevc"]),
              field("subtitles", .boolean,
                    "MP4 only. Also save the auto-captions as .srt next to it"),
              field("loop", .boolean, "GIF only. true plays forever (default), false once"),
              field("gif_width", .number, "GIF only. 320, 480 (default) or 720 pixels; "
                    + "height follows the shape"),
              field("gif_fps", .number, "GIF only. 10, 15 (default) or 24")]),
        tool("job_status", "Progress or result of auto_captions and export.", readOnly: true),
    ]

    static let names = Set(tools.map(\.name))

    static let instructions = """
        TitleCut is a macOS video editor for quick social videos: cut a talking video, add \
        styled timed titles and auto-captions, remove silences, freeze frames with camera \
        moves, add background music, and export MP4 in 16:9, 9:16 or 1:1. These tools drive \
        the running app live: every edit shows in its window at once and is one undo step \
        (the person can press Cmd-Z, or call undo).

        Model
        - Times are seconds of finished-video (output) time unless a field says source.
        - A project's timeline is segments in order: video clips (a range of one of the \
        project's videos), \
        freezes (a still frame for a length, optional camera move), title cards (solid \
        colour for titles, silent) and gaps (black).
        - Titles are anchored to segments, so they move with their clip.
        - Music lives on its own strip in output time; cutting video never moves it.
        - IDs are UUID strings from get_project.

        Tools
        - Session: list_projects, get_project, new_project, undo, redo, save.
        - Video: open_video, add_video, set_shape, seek, play, pause.
        - Clips: split_at, delete_segment, move_segment, trim_segment, set_framing, set_split \
        (split screen), set_clip \
        (speed, volume), frame_faces, \
        freeze_frame, set_freeze_length, set_camera, reset_camera.
        - Title cards: insert_card, set_card (solid colour; put titles on it with add_title).
        - Transitions: set_transition, remove_transition (dips, fades, crossfades at \
        cuts, the start and the end).
        - Titles: list_styles, add_title, update_title, delete_titles, duplicate_titles, \
        set_titles_style.
        - Captions: auto_captions (job), get_transcript, export_subtitles.
        - Silences: find_silences (dry run), remove_silences.
        - Filler words: find_fillers (dry run), remove_fillers.
        - Music: add_music, update_music, delete_music, duplicate_music.
        - Output: render_frame, export (job, MP4 or GIF), job_status.
        Every tool takes a project ID or name, required when more than one project \
        is open.

        Workflow example
        1. get_project to see what is open (or new_project, then open_video).
        2. find_silences, report the count and seconds, then remove_silences if wanted.
        3. auto_captions, then job_status until done; list captions via get_project.
        4. add_title for a hook at 0 s; update_title to restyle it.
        5. set_shape 9:16; set_framing per clip if the subject is off centre.
        6. render_frame at a few times to check the result.
        7. export to a path, then job_status until done.
        """
}

// MARK: Manual

extension ToolCatalog {
    /// get_instructions: the overview, every tool with its parameters, the
    /// conventions, and worked examples. Built from `tools`, so it always
    /// matches what the server offers.
    static let manual: String = {
        var text = instructions
        text += "\n\n" + conventions
        text += "\n\nTool reference\n"
        text += "(name — description; then each parameter: type, required or optional, "
            + "allowed values, meaning. Every tool also takes an optional `project`.)\n"
        for tool in tools where tool.name != "get_instructions" {
            text += "\n" + reference(tool)
        }
        text += "\n" + examples
        return text
    }()

    private static func reference(_ tool: Tool) -> String {
        var lines = ["\(tool.name)\(tool.annotations.readOnlyHint == true ? " (read-only)" : "")"
                     + " — \(tool.description ?? "")"]
        guard case .object(let schema) = tool.inputSchema,
              case .object(let properties)? = schema["properties"] else {
            return lines.joined(separator: "\n")
        }
        var required: Set<String> = []
        if case .array(let names)? = schema["required"] {
            required = Set(names.compactMap { if case .string(let n) = $0 { n } else { nil } })
        }
        for name in properties.keys.sorted(by: { a, b in
            // Required first, then alphabetical; `project` last.
            if (a == "project") != (b == "project") { return b == "project" }
            if required.contains(a) != required.contains(b) { return required.contains(a) }
            return a < b
        }) where name != "project" {
            guard case .object(let field)? = properties[name] else { continue }
            var line = "  - \(name): "
            if case .string(let type)? = field["type"] { line += type }
            line += required.contains(name) ? ", required" : ", optional"
            if case .array(let choices)? = field["enum"] {
                let values = choices.compactMap { if case .string(let v) = $0 { v } else { nil } }
                line += ", one of " + values.joined(separator: " | ")
            }
            if case .string(let about)? = field["description"] { line += ". " + about }
            lines.append(line)
        }
        if lines.count == 1 { lines.append("  (no parameters)") }
        return lines.joined(separator: "\n")
    }

    private static let conventions = """
        Conventions
        - Call get_instructions once per session; every other tool refuses until then.
        - The app must be open. With one project open, tools act on it. With \
        more than one, every tool except list_projects and new_project needs `project` \
        (list_projects gives them); without it the call errors and nothing changes.
        - Prefer the project ID to the name. The ID is saved in the project file and \
        stays the same when the person renames, moves or saves it; the name follows the \
        file name, and several untitled or same-named projects can be open at once. A \
        Finder copy opened beside its original gets a new ID.
        - Results are JSON text unless noted; render_frame returns a PNG image plus a line \
        of text. An error result (isError true) says what was wrong and how to fix it; \
        nothing changed when a tool errors.
        - Every successful edit is exactly one undo step, named as the app's Edit menu \
        names it. undo and redo work on the person's edits too.
        - Seconds are decimal numbers. Output time is the finished video's clock; source \
        time is the clock of the clip's own video (trim_segment, get_transcript).
        - Snapshots go stale after edits: call get_project again for fresh IDs and times. \
        Splitting gives the second part a new ID; deleting a segment deletes its titles.
        - A segment's transition_in sits at the cut before it and moves with it; the end \
        transition stays at the video's end whatever is last. Transitions change the \
        picture only; the sound cuts as before.
        - auto_captions and export are jobs: they return at once; poll job_status until \
        state is done or failed. One job runs at a time per project.
        - After open_video the audio is read in the background: get_project shows \
        source.has_audio null until then, and find_silences and remove_silences error \
        until then.
        - find_silences changes nothing; use it to report what remove_silences would cut.
        - find_fillers and remove_fillers use the saved transcript; without one they error. \
        Words like "like" are never cut.
        - Shapes crop the video at the centre; set_framing slides a clip across and down \
        inside a 9:16 or 1:1 frame and zooms it (zoom 1-6; 2 shows half the width and \
        height, magnified). set_split shows two parts of a clip, one per half, \
        each with its own x, y and zoom; set_framing does not change a split clip. freeze_frame \
        captures what the frame shows.
        - Colours are #RRGGBB or #RRGGBBAA. Title positions: style (the style's own), top, \
        center, lower_third, bottom, or custom with x and y from 0 to 1 (top-left origin).
        - Exports are watermarked until the app is unlocked.
        - Files: TitleCut is sandboxed. open_video, add_video, add_music, export and \
        export_subtitles take absolute paths inside folders the person has allowed \
        (MCP button > Folders in the app); any other path errors and names the allowed \
        folders. Ask the person to add a folder rather than guessing another path.
        """

    private static let examples = """

        Examples (arguments as JSON)
        - Cut 2.5 s in: split_at {"seconds": 2.5}
        - Remove a clip: get_project, then delete_segment {"id": "<segment id>"}
        - Report silences: find_silences {"quieter_than_db": 30, "longer_than_seconds": 0.6}
        - Captions: auto_captions {"language": "en-US"}, then job_status until done
        - Hook title: add_title {"text": "Wait for it", "seconds": 0, "duration": 2.5, \
        "style": "Meme"}
        - Restyle it: update_title {"id": "<title id>", "position": "top", \
        "size_percent": 140, "color": "#FFD60A", "transition_in": "scale"}
        - Vertical: set_shape {"shape": "9:16"}, then set_framing {"id": "<clip id>", \
        "framing": 0.3}
        - Fade in and out: set_transition {"at": "start", "kind": "dip_to_black"} and \
        set_transition {"at": "end", "kind": "dip_to_black", "duration": 2}
        - Crossfade a cut: set_transition {"at": "<id of the clip after the cut>", \
        "kind": "crossfade", "duration": 0.5}
        - Freeze and zoom: freeze_frame {"seconds": 4, "duration": 3}, then set_camera \
        {"id": "<freeze id>", "center_x": 0.5, "center_y": 0.35, "scale": 2.5}
        - Music: add_music {"path": "/Users/me/Music/bed.m4a", "seconds": 0}, then \
        update_music {"id": "<piece id>", "volume": 0.3, "fade_out": 2}
        - Check: render_frame {"seconds": 1.5}
        - Export: export {"path": "/Users/me/Desktop/clip.mp4", "subtitles": true}, then \
        job_status
        """
}
