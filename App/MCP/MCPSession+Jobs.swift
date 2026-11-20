import AVFoundation
import AppKit
import Foundation
import TitleCutCore

/// Captions, silences, rendering and export. The long ones (auto_captions,
/// export) run as a job that `job_status` reports.
extension MCPSession {
    private var isBusy: Bool { job?.state == .running }

    private func busy() -> MCPReply {
        .error("A \(job?.kind ?? "job") is still running. Poll job_status until it is done.")
    }

    // MARK: Captions

    func startAutoCaptions(_ args: MCPArguments) async -> MCPReply {
        guard !isBusy else { return busy() }
        guard project.source != nil, !project.segments.isEmpty else {
            return .error("Open a video first.")
        }
        guard allVideosFound else { return missingVideo }
        guard let style = style(named: args.string("style") ?? StyleLibrary.captionID.uuidString)
        else { return .error("No style is named \(args.string("style") ?? "").") }
        let locale: Locale
        if let code = args.string("language") {
            guard let supported = await Transcriber.supportedLocale(
                equivalentTo: Locale(identifier: code)) else {
                return .error("\(code) cannot be transcribed on this Mac.")
            }
            locale = supported
        } else {
            guard let supported = await Transcriber.supportedLocale(equivalentTo: .current) else {
                return .error("The Mac's language cannot be transcribed; give language.")
            }
            locale = supported
        }
        let localeID = locale.identifier(.bcp47)
        job = MCPJob(kind: "auto_captions", message: "Reading the audio")
        jobTask = Task { [weak self] in
            guard let self else { return }
            await self.runAutoCaptions(videos: self.usedVideos(), localeID: localeID, style: style)
        }
        return .text("Auto-captions started (\(localeID)). Poll job_status.")
    }

    /// Transcribes each of `videos` that has no saved transcript in
    /// `localeID`, then makes captions from all of them.
    private func runAutoCaptions(videos: [(key: UUID?, url: URL)], localeID: String,
                                 style: TitleStyle) async {
        do {
            var words: [UUID?: [TranscriptWord]] = [:]
            for (index, video) in videos.enumerated() {
                let fingerprint = try await SourceFingerprint.of(video.url)
                if let saved = transcripts().first(where: {
                    $0.matches(fingerprint, locale: localeID)
                }) {
                    words[video.key] = saved.words
                    continue
                }
                let share = 1 / Double(videos.count)
                let found: [TranscriptWord]
                do {
                    found = try await Transcriber.transcribe(
                        audioOf: video.url, locale: Locale(identifier: localeID)
                    ) { phase in
                        let overall: Transcriber.Phase = switch phase {
                        case .transcribing(let fraction):
                            .transcribing((Double(index) + fraction) * share)
                        default: phase
                        }
                        Task { @MainActor [weak self] in self?.captionProgress(overall) }
                    }
                } catch Transcriber.TranscribeError.noAudio where videos.count > 1 {
                    words[video.key] = []
                    continue
                }
                setTranscript(Transcript(locale: localeID, source: fingerprint, words: found))
                words[video.key] = found
            }
            let titles = AutoCaptions.titles(for: words, in: project, style: style,
                                             makeID: UUID.init)
            guard !titles.isEmpty else {
                finish(failed: "No speech was found in the kept parts of the video.")
                return
            }
            store.perform(.replaceAutoCaptions(titles: titles, style: style))
            let count = words.values.reduce(0) { $0 + $1.count }
            job?.state = .done
            job?.progress = 1
            job?.message = "\(titles.count) captions from \(count) words."
        } catch {
            finish(failed: "Transcription failed: \(error.localizedDescription)")
        }
    }

    private func captionProgress(_ phase: Transcriber.Phase) {
        guard job?.state == .running else { return }
        switch phase {
        case .preparing: job?.message = "Reading the audio"
        case .downloading(let fraction):
            job?.message = "Downloading the speech model"
            job?.progress = fraction
        case .transcribing(let fraction):
            job?.message = "Transcribing"
            let current = job?.progress ?? 0
            job?.progress = max(current, fraction)
        }
    }

    private func finish(failed message: String) {
        job?.state = .failed
        job?.message = message
    }

    func transcriptReply() async -> MCPReply {
        var videos: [JSONValue] = []
        for video in usedVideos() {
            guard let fingerprint = try? await SourceFingerprint.of(video.url),
                  let transcript = transcripts().last(where: { $0.source == fingerprint })
            else { continue }
            videos.append(.object([
                "video": video.key.map { .string($0.uuidString) } ?? .string("first"),
                "path": .string(video.url.path),
                "language": .string(transcript.locale),
                "words": .array(transcript.words.map {
                    .object(["text": .string($0.text), "start": .seconds($0.start),
                             "end": .seconds($0.end)])
                }),
            ]))
        }
        guard !videos.isEmpty else {
            return .error("There is no transcript yet. Call auto_captions first.")
        }
        return .json(.object([
            "note": .string("One entry per video on the timeline; times are seconds of that "
                            + "video. A clip's video is its video field in get_project."),
            "videos": .array(videos),
        ]))
    }

    func exportSubtitles(_ args: MCPArguments) -> MCPReply {
        guard let path = args.string("path") else { return missing("path") }
        guard SRT.hasCues(project) else { return .error("There are no auto-captions to save.") }
        guard MCPFolders.shared.allows(URL(fileURLWithPath: path)) else {
            return .error(MCPFolders.shared.refusal(for: path))
        }
        do {
            try SubtitleFile.write(project, to: URL(fileURLWithPath: path))
            return .text("Saved \(path).")
        } catch {
            return .error("\(path) could not be written: \(error.localizedDescription)")
        }
    }

    // MARK: Silences

    func silences(_ args: MCPArguments, remove: Bool) -> MCPReply {
        let waveforms = waveforms()
        guard !waveforms.isEmpty else {
            return .error("The audio is still being read, or the video has none. Try again in "
                          + "a moment.")
        }
        var settings = SilenceRemoval.Settings()
        if let db = args.number("quieter_than_db") { settings.thresholdDecibels = min(max(db, 6), 45) }
        if let seconds = args.number("longer_than_seconds") {
            settings.minimumSeconds = min(max(seconds, 0.1), 10)
        }
        let cuts = SilenceRemoval.cuts(for: waveforms.mapValues {
            SilenceRemoval.silences(in: $0, settings: settings)
        }, in: project)
        let total = cuts.reduce(0) { $0 + $1.duration }
        var result: [String: JSONValue] = [
            "cuts": .number(Double(cuts.count)),
            "seconds_removed": .seconds(total),
            "ranges": .array(cuts.map { .object(["start": .seconds($0.start),
                                                  "end": .seconds($0.end)]) }),
        ]
        if remove {
            let commands = SilenceRemoval.commands(removing: cuts, from: project)
            perform(commands, name: "Remove Silences")
            result["removed"] = .bool(!commands.isEmpty)
            result["new_duration"] = .seconds(TimelineMath.outputDuration(project))
        }
        return .json(.object(result))
    }

    // MARK: Faces

    func frameFaces() async -> MCPReply {
        guard project.source != nil else { return .error("Open a video first.") }
        guard allVideosFound else { return missingVideo }
        let cropped = project.segments.contains { segment in
            guard case .video(let video) = segment, let source = project.source(of: video)
            else { return false }
            return FaceFraming.framing(centering: 0.5, sourceSize: source.naturalSize,
                                       renderSize: renderSize()) != nil
        }
        guard cropped else {
            return .error("The frame shows the videos' full width, so there is nothing to "
                          + "reframe. Call set_shape with 9:16 or 1:1 first.")
        }
        do {
            let plan = try await FaceFraming.find(in: project, urls: sourceURLs())
            let clips = project.segments.filter { if case .video = $0 { true } else { false } }
            let commands = FaceFraming.commands(plan, in: project)
            let splits = commands.filter { if case .splitSegment = $0 { true } else { false } }
            perform(commands, name: "Frame Faces")
            return .json(.object([
                "clips": .number(Double(clips.count)),
                "with_faces": .number(Double(plan.count)),
                "splits": .number(Double(splits.count)),
                "changed": .number(Double(commands.count - splits.count)),
            ]))
        } catch {
            return .error("A video could not be read: \(error.localizedDescription)")
        }
    }

    // MARK: Filler words

    func fillers(remove: Bool) async -> MCPReply {
        guard project.source != nil else { return .error("Open a video first.") }
        guard allVideosFound else { return missingVideo }
        var words: [UUID?: [TranscriptWord]] = [:]
        for video in usedVideos() {
            guard let fingerprint = try? await SourceFingerprint.of(video.url),
                  let transcript = transcripts().last(where: { $0.source == fingerprint }) else {
                return .error("A video on the timeline has no transcript yet. Call auto_captions "
                              + "(it also makes captions), or ask the person to transcribe in "
                              + "Timeline > Remove Filler Words.")
            }
            words[video.key] = transcript.words
        }
        let cuts = FillerRemoval.cuts(for: words, in: project)
        let total = cuts.reduce(0) { $0 + $1.duration }
        var result: [String: JSONValue] = [
            "cuts": .number(Double(cuts.count)),
            "seconds_removed": .seconds(total),
            "ranges": .array(cuts.map { .object(["start": .seconds($0.start),
                                                  "end": .seconds($0.end)]) }),
        ]
        if remove {
            let commands = FillerRemoval.commands(removing: cuts, from: project, words: words)
            perform(commands, name: "Remove Filler Words")
            result["removed"] = .bool(!commands.isEmpty)
            result["new_duration"] = .seconds(TimelineMath.outputDuration(project))
        }
        return .json(.object(result))
    }

    // MARK: Render

    func renderFrame(_ args: MCPArguments) async -> MCPReply {
        guard let at = args.number("seconds") else { return missing("seconds") }
        guard project.source != nil else { return .error("Open a video first.") }
        guard allVideosFound else { return missingVideo }
        let maxWidth = min(max(args.number("max_width") ?? 960, 64), 3840)
        let project = project
        do {
            let sources = try await Exporter.loadSources(of: project, from: sourceURLs())
            let built = try CompositionBuilder.build(project, sources: sources)
            let generator = AVAssetImageGenerator(asset: built.composition)
            generator.videoComposition = built.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
            let total = Ticks.seconds(TimelineMath.outputDuration(project))
            let time = CMTime(seconds: min(max(at, 0), max(total - 0.001, 0)),
                              preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                return .error("The frame could not be encoded.")
            }
            return MCPReply(isError: false,
                            content: [.png(png),
                                      .text("Frame at \(format(at)) s, \(image.width)x\(image.height).")])
        } catch {
            return .error("The frame could not be rendered: \(error.localizedDescription)")
        }
    }

    // MARK: Export

    func startExport(_ args: MCPArguments) -> MCPReply {
        guard !isBusy else { return busy() }
        guard let path = args.string("path") else { return missing("path") }
        guard project.source != nil, !project.segments.isEmpty else {
            return .error("Open a video first.")
        }
        guard allVideosFound else { return missingVideo }
        let urls = sourceURLs()
        let codec: Codec
        switch args.string("codec") {
        case nil: codec = project.output.codec
        case "h264": codec = .h264
        case "hevc": codec = .hevc
        default: return .error("codec is h264 or hevc.")
        }
        let destination = URL(fileURLWithPath: path)
        guard MCPFolders.shared.allows(destination) else {
            return .error(MCPFolders.shared.refusal(for: path))
        }
        let isGIF: Bool
        switch args.string("format") {
        case nil: isGIF = destination.pathExtension.lowercased() == "gif"
        case "mp4": isGIF = false
        case "gif": isGIF = true
        default: return .error("format is mp4 or gif.")
        }
        var gif = GIFExporter.Settings()
        if let loop = args.bool("loop") { gif.loops = loop }
        if let width = args.number("gif_width") {
            guard GIFExporter.Settings.widths.contains(Int(width)) else {
                return .error("gif_width is 320, 480 or 720.")
            }
            gif.width = Int(width)
        }
        if let fps = args.number("gif_fps") {
            guard GIFExporter.Settings.framesPerSecondChoices.contains(Int(fps)) else {
                return .error("gif_fps is 10, 15 or 24.")
            }
            gif.framesPerSecond = Int(fps)
        }
        let subtitles = !isGIF && args.bool("subtitles") == true && SRT.hasCues(project)
        let project = project
        job = MCPJob(kind: "export", message: "Exporting to \(destination.lastPathComponent)")
        jobTask = Task { [weak self] in
            guard let self else { return }
            do {
                let watermark = !(await Unlock.shared.refresh())
                let progress: @Sendable (Double) -> Void = { fraction in
                    Task { @MainActor [weak self] in
                        if self?.job?.state == .running { self?.job?.progress = fraction }
                    }
                }
                if isGIF {
                    try await GIFExporter.export(project, sourceURLs: urls, to: destination,
                                                 settings: gif, watermark: watermark,
                                                 progress: progress)
                } else {
                    try await Exporter.export(project, sourceURLs: urls, to: destination,
                                              codec: codec, watermark: watermark,
                                              progress: progress)
                }
                let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[
                    .size] as? Int) ?? nil
                var message = "Saved \(destination.path)"
                    + (bytes.map { " (" + ByteCountFormatter.string(fromByteCount: Int64($0),
                                                                   countStyle: .file) + ")" } ?? "")
                    + "."
                if subtitles {
                    let srt = SubtitleFile.url(nextTo: destination)
                    try SubtitleFile.write(project, to: srt)
                    message += " Subtitles: \(srt.path)."
                }
                job?.state = .done
                job?.progress = 1
                job?.message = message
            } catch {
                finish(failed: "Export failed: \(error.localizedDescription)")
            }
        }
        return .text("Export started to \(path)"
                     + (Unlock.shared.isUnlocked ? "" : " (watermarked)") + ". Poll job_status.")
    }

    func jobStatus() -> MCPReply {
        guard let job else { return .text("No job has run in this project.") }
        return .json(job.json)
    }
}
