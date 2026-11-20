import AVFoundation
import Observation
import os
import TitleCutCore

/// Owns the preview `AVPlayer` for one document window: transport, scrubbing
/// and the playhead (Q2). All times here are output time in seconds.
///
/// The player item is rebuilt from the project on every model change
/// (debounced, §3.1), preserving playhead time and play state (§6.5).
/// Changes that leave the timeline alone (titles only) keep the item and
/// swap its video composition at once, so the picture never blanks.
@MainActor
@Observable
final class PlayerController {
    /// Output duration in seconds.
    private(set) var duration: Double = 0
    /// Source nominal frame rate.
    private(set) var frameRate: Double = Timecode.fallbackFrameRate
    /// Playhead in output seconds, as last reported by the player or set by a seek.
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false

    let player = AVPlayer()

    private static let log = Logger(subsystem: "com.byteclub.titlecut", category: "preview")

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var seeks = SeekCoalescer<CMTime>()
    /// Incremented per player item so completions from an old item are ignored.
    @ObservationIgnored private var itemGeneration = 0
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    /// Tracks of the videos read so far, by file, reused across rebuilds.
    @ObservationIgnored private var loadedSources: [URL: CompositionBuilder.SourceTracks] = [:]
    /// The tracks the installed item was built from, keyed by `VideoSegment.sourceID`.
    @ObservationIgnored private var installedSources: [UUID?: CompositionBuilder.SourceTracks] = [:]
    /// Song tracks of the installed item, reused when only volumes or fades change.
    @ObservationIgnored private var loadedMusic = CompositionBuilder.MusicTracks.none
    /// What the current item's composition was built from, besides titles.
    @ObservationIgnored private var installedTimeline: TimelineKey?

    /// The parts of a project that shape the composition's tracks and timing.
    /// What needs a new player item when it changes. Clip framing, split
    /// screen, music volume and fades are left out: like titles, they only
    /// need a new video composition or audio mix.
    private struct TimelineKey: Equatable {
        let sourceURLs: [UUID?: URL]
        let source: SourceVideo?
        let addedSources: [SourceVideo]
        let segments: [Segment]
        let output: OutputSettings
        /// Where each music piece plays from and to.
        let music: [String]

        init(sourceURLs: [UUID?: URL], project: Project) {
            self.music = project.music.map {
                "\($0.fileName) \($0.start) \($0.songRange.start) \($0.songRange.duration)"
            }
            self.sourceURLs = sourceURLs
            self.source = project.source
            self.addedSources = project.addedSources
            self.segments = project.segments.map { segment in
                guard case .video(var video) = segment else { return segment }
                video.frame = .centred
                video.framing = nil
                video.split = nil
                return .video(video)
            }
            self.output = project.output
        }
    }

    var hasMedia: Bool { duration > 0 }

    var currentTimecode: String {
        Timecode.string(seconds: currentTime, frameRate: frameRate)
    }

    var durationTimecode: String {
        Timecode.string(seconds: duration, frameRate: frameRate)
    }

    init() {
        player.actionAtItemEnd = .pause
    }

    isolated deinit {
        rebuildTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    // MARK: Model

    /// Rebuilds the player item for `project` after a short debounce.
    /// - Parameter sourceURLs: Every video's resolved file, keyed by
    ///   `VideoSegment.sourceID`; empty when the first is missing or absent.
    func update(project: Project, sourceURLs: [UUID?: URL], debounce: Bool = true) {
        rebuildTask?.cancel()
        if let installedTimeline, player.currentItem != nil,
           installedTimeline == TimelineKey(sourceURLs: sourceURLs, project: project) {
            refreshTitles(project: project, sources: installedSources, music: loadedMusic)
            return
        }
        rebuildTask = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            await rebuild(project: project, sourceURLs: sourceURLs)
        }
    }

    private func rebuild(project: Project, sourceURLs: [UUID?: URL]) async {
        guard sourceURLs[UUID?.none] != nil, let source = project.source,
              !project.segments.isEmpty else {
            clear()
            return
        }
        do {
            var sources: [UUID?: CompositionBuilder.SourceTracks] = [:]
            for (key, url) in sourceURLs {
                if let loaded = loadedSources[url] {
                    sources[key] = loaded
                    continue
                }
                guard let loaded = try await CompositionBuilder.SourceTracks.load(
                    from: AVURLAsset(url: url)) else { continue }
                if Task.isCancelled { return }
                loadedSources[url] = loaded
                sources[key] = loaded
            }
            guard sources[UUID?.none] != nil else { clear(); return }
            let music = await CompositionBuilder.MusicTracks.load(for: project)
            if Task.isCancelled { return }
            loadedMusic = music
            let built = try CompositionBuilder.build(project, sources: sources, music: music)
            installedSources = sources
            installedTimeline = TimelineKey(sourceURLs: sourceURLs, project: project)
            install(built,
                    duration: Ticks.seconds(TimelineMath.outputDuration(project)),
                    frameRate: source.frameRate)
        } catch {
            // Reading the source failed after it resolved; the preview stays empty.
            Self.log.error("Preview rebuild failed: \(error, privacy: .public)")
            clear()
        }
    }

    /// Swaps the current item's video composition for one with `project`'s
    /// titles, keeping the item, playhead and play state.
    private func refreshTitles(project: Project,
                               sources: [UUID?: CompositionBuilder.SourceTracks],
                               music: CompositionBuilder.MusicTracks) {
        guard let item = player.currentItem else { return }
        do {
            let built = try CompositionBuilder.build(project, sources: sources, music: music)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
        } catch {
            Self.log.error("Preview title refresh failed: \(error, privacy: .public)")
            return
        }
        // A paused item keeps showing the old frame until it is asked for one.
        if player.timeControlStatus == .paused {
            seek(toSeconds: currentTime)
        }
    }

    private func install(_ built: CompositionBuilder.Output, duration newDuration: Double,
                         frameRate newRate: Double) {
        let wasPlaying = player.timeControlStatus != .paused || (isScrubbing && resumeAfterScrub)
        let time = min(currentTime, newDuration)

        player.pause()
        seeks.reset()
        itemGeneration += 1
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        player.replaceCurrentItem(with: item)
        duration = newDuration
        if frameRate != newRate || timeObserver == nil {
            frameRate = newRate
            installTimeObserver()
        }
        currentTime = time
        if time > 0 { seek(toSeconds: time) }
        if wasPlaying && !isScrubbing && time < newDuration {
            player.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
    }

    private func clear() {
        installedTimeline = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        seeks.reset()
        itemGeneration += 1
        duration = 0
        currentTime = 0
        isPlaying = false
    }

    private func installTimeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        let interval = CMTime(seconds: 1 / frameRate, preferredTimescale: 600)
        // Also fires on time jumps and when playback starts or stops.
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated {
                self?.playerTimeChanged(time)
            }
        }
    }

    private func playerTimeChanged(_ time: CMTime) {
        isPlaying = player.timeControlStatus != .paused
        // With no item the player still reports its last time; ignore it.
        guard player.currentItem != nil, !isScrubbing, !seeks.isSeeking, time.isNumeric
        else { return }
        currentTime = time.seconds
    }

    // MARK: Transport

    func togglePlayPause() {
        guard hasMedia else { return }
        if player.timeControlStatus != .paused {
            player.pause()
            isPlaying = false
            return
        }
        if currentTime >= duration - 1 / frameRate {
            seek(toSeconds: 0)
        }
        player.play()
        isPlaying = true
    }

    /// Steps by whole frames; negative counts step backwards. Pauses playback.
    func step(frames count: Int) {
        guard hasMedia, let item = player.currentItem else { return }
        player.pause()
        isPlaying = false
        item.step(byCount: count)
    }

    /// Moves the playhead by `delta` seconds, clamped to the timeline.
    func jump(by delta: Double) {
        guard hasMedia else { return }
        seek(toSeconds: currentTime + delta)
    }

    // MARK: Scrubbing

    func beginScrub() {
        guard hasMedia, !isScrubbing else { return }
        isScrubbing = true
        resumeAfterScrub = player.timeControlStatus != .paused
        player.pause()
    }

    func scrub(to seconds: Double) {
        guard hasMedia else { return }
        seek(toSeconds: seconds)
    }

    func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        if resumeAfterScrub {
            player.play()
            isPlaying = true
        }
        resumeAfterScrub = false
    }

    /// Exact seek, coalesced so at most one seek is in flight and only the
    /// latest pending target is issued next.
    func seek(toSeconds seconds: Double) {
        guard hasMedia else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        // Nearest tick: CMTime(seconds:preferredTimescale:) truncates, which put
        // e.g. 1.0333 s at 619/600, part-way through the previous frame.
        let target = Ticks.cmTime(Ticks.from(seconds: clamped))
        if let now = seeks.request(target) {
            issueSeek(now, generation: itemGeneration)
        }
    }

    private func issueSeek(_ target: CMTime, generation: Int) {
        Task {
            _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            guard generation == itemGeneration else { return }
            if let next = seeks.complete() {
                issueSeek(next, generation: generation)
            } else if !isScrubbing {
                let time = player.currentTime()
                if time.isNumeric { currentTime = time.seconds }
            }
        }
    }
}
