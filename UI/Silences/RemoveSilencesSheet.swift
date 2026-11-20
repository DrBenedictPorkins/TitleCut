import AVFoundation
import SwiftUI
import TitleCutCore

/// Remove Silences sheet: loudness threshold, shortest pause and shortest
/// clip left between cuts. A strip shows the timeline's sound with every
/// planned cut shaded, and a preview plays the result before anything is
/// changed. Shift-dragging the strip limits cuts and preview to a range.
/// Slider values are remembered. Remove applies every cut as one
/// undo step and closes the sheet.
struct RemoveSilencesSheet: View {
    let store: ProjectStore
    /// Each video's sound, keyed by `VideoSegment.sourceID`.
    let waveforms: [UUID?: Waveform]
    /// Each video's file, keyed by `VideoSegment.sourceID`.
    let sourceURLs: [UUID?: URL]
    let renderSize: CGSize
    /// The window's own player, paused while the preview plays.
    let mainPlayer: PlayerController

    @AppStorage("silences.quieterThan") private var thresholdDecibels = 30.0
    @AppStorage("silences.longerThan") private var minimumSeconds = 0.6
    @AppStorage("silences.shortestClip") private var minimumKeptSeconds = 1.5
    @State private var preview = PlayerController()
    /// Part of the uncut timeline the cuts are limited to; nil for all of it.
    @State private var range: TickRange?
    @Environment(\.dismiss) private var dismiss

    private var settings: SilenceRemoval.Settings {
        .init(thresholdDecibels: thresholdDecibels, minimumSeconds: minimumSeconds,
              minimumKeptSeconds: minimumKeptSeconds)
    }

    private var cuts: [TickRange] {
        let settings = settings
        // With a range, loudness is measured against the range's loudest part.
        let loudest = range.map {
            SilenceRemoval.loudest(in: $0, of: store.project, waveforms: waveforms)
        } ?? [:]
        var silences: [UUID?: [TickRange]] = [:]
        for (key, waveform) in waveforms {
            silences[key] = SilenceRemoval.silences(in: waveform, settings: settings,
                                                    loudest: loudest[key] ?? 1)
        }
        return SilenceRemoval.cuts(SilenceRemoval.cuts(for: silences, in: store.project),
                                   within: range)
    }

    /// The range's ends in preview (cut) time, in seconds.
    private func previewBounds(_ cuts: [TickRange]) -> ClosedRange<Double>? {
        guard let range else { return nil }
        return Ticks.seconds(SilenceRemoval.keptTime(range.start, cuts: cuts))
            ... Ticks.seconds(SilenceRemoval.keptTime(range.end, cuts: cuts))
    }

    var body: some View {
        let cuts = cuts
        let saved = cuts.reduce(0) { $0 + $1.duration }
        VStack(spacing: 0) {
            InspectorHeader(label: "REMOVE SILENCES")
            VStack(alignment: .leading, spacing: 0) {
                InstrumentSection("Preview") {
                    VStack(spacing: 10) {
                        PreviewVideo(player: preview.player)
                            .aspectRatio(renderSize.width / max(renderSize.height, 1),
                                         contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 280)
                        CutStrip(project: store.project, waveforms: waveforms, cuts: cuts,
                                 range: $range,
                                 playhead: SilenceRemoval.originalTime(
                                     Ticks.from(seconds: preview.currentTime), cuts: cuts),
                                 scrub: { original in
                                     preview.seek(toSeconds: Ticks.seconds(
                                         SilenceRemoval.keptTime(original, cuts: cuts)))
                                 })
                            .frame(height: 64)
                        HStack(spacing: 12) {
                            Button(preview.isPlaying ? "PAUSE" : "PLAY") {
                                if !preview.isPlaying, let bounds = previewBounds(cuts),
                                   !bounds.contains(preview.currentTime)
                                    || preview.currentTime >= bounds.upperBound - 0.05 {
                                    preview.seek(toSeconds: bounds.lowerBound)
                                }
                                preview.togglePlayPause()
                            }
                            .buttonStyle(InstrumentButtonStyle(filled: false))
                            .keyboardShortcut(.space, modifiers: [])
                            .disabled(!preview.hasMedia)
                            Text("\(preview.currentTimecode) / \(preview.durationTimecode)")
                                .font(Instrument.mono(11))
                                .foregroundStyle(Instrument.muted)
                            Spacer()
                            if let range {
                                Text(String(format: "RANGE %.1f–%.1f S",
                                            Ticks.seconds(range.start), Ticks.seconds(range.end)))
                                    .font(Instrument.mono(11))
                                    .foregroundStyle(Instrument.neon)
                                Button("CLEAR RANGE") { self.range = nil }
                                    .buttonStyle(InstrumentButtonStyle(filled: false))
                            } else {
                                Text("Shift-drag the strip to work on a range.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Instrument.muted)
                            }
                        }
                    }
                }
                InstrumentSection("Silence") {
                    VStack(spacing: 14) {
                        TickSlider(label: "QUIETER THAN",
                                   value: thresholdDecibels,
                                   range: 6...45,
                                   format: { String(format: "-%.0f DB", $0) },
                                   onBegin: {}, onChange: { thresholdDecibels = $0 },
                                   onEnd: {})
                        TickSlider(label: "LONGER THAN",
                                   value: minimumSeconds,
                                   range: 0.3...3,
                                   format: { String(format: "%.1f S", $0) },
                                   onBegin: {}, onChange: { minimumSeconds = $0 },
                                   onEnd: {})
                        TickSlider(label: "SHORTEST CLIP",
                                   value: minimumKeptSeconds,
                                   range: 0...5,
                                   format: { $0 < 0.05 ? "ANY" : String(format: "%.1f S", $0) },
                                   onBegin: {}, onChange: { minimumKeptSeconds = $0 },
                                   onEnd: {})
                    }
                    Text(range != nil
                         ? "Loudness is measured against the loudest part of the range."
                         : waveforms.count > 1
                         ? "Loudness is measured against the loudest part of each video."
                         : "Loudness is measured against the loudest part of the video.")
                        .font(.system(size: 12))
                        .foregroundStyle(Instrument.muted)
                }
                InstrumentSection("Result") {
                    HStack(alignment: .firstTextBaseline, spacing: 24) {
                        readout("\(cuts.count)", label: cuts.count == 1 ? "CUT" : "CUTS")
                        readout(String(format: "%.1f S", Ticks.seconds(saved)), label: "REMOVED")
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("CANCEL") { dismiss() }
                    .buttonStyle(InstrumentButtonStyle(filled: false))
                    .keyboardShortcut(.cancelAction)
                Button("REMOVE") { remove(cuts) }
                    .buttonStyle(InstrumentButtonStyle(filled: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(cuts.isEmpty)
            }
            .padding(16)
            .overlay(alignment: .top) { Rectangle().fill(Instrument.divider).frame(height: 1) }
        }
        .frame(width: 720)
        .background(Instrument.background)
        .preferredColorScheme(.light)
        .onAppear {
            if mainPlayer.isPlaying { mainPlayer.togglePlayPause() }
            updatePreview(cuts)
        }
        .onChange(of: cuts) { _, new in updatePreview(new) }
        .onChange(of: range) { _, _ in
            if let bounds = previewBounds(cuts) { preview.seek(toSeconds: bounds.lowerBound) }
        }
        .onChange(of: preview.currentTime) { _, time in
            // Playback stops at the end of the range.
            if preview.isPlaying, let bounds = previewBounds(cuts), time >= bounds.upperBound {
                preview.togglePlayPause()
                preview.seek(toSeconds: bounds.lowerBound)
            }
        }
        .onDisappear { preview.player.pause() }
    }

    private func updatePreview(_ cuts: [TickRange]) {
        preview.update(project: SilenceRemoval.project(store.project, removing: cuts),
                       sourceURLs: sourceURLs)
    }

    private func readout(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Instrument.mono(20, weight: .medium))
                .foregroundStyle(Instrument.neon)
            Text(label)
                .font(Instrument.mono(10))
                .tracking(1.4)
                .foregroundStyle(Instrument.dim)
        }
    }

    private func remove(_ cuts: [TickRange]) {
        preview.player.pause()
        let commands = SilenceRemoval.commands(removing: cuts, from: store.project)
        guard !commands.isEmpty else { return }
        store.beginGesture(named: "Remove Silences")
        for command in commands { store.perform(command) }
        store.endGesture()
        dismiss()
    }
}

/// The preview's picture: an `AVPlayerLayer` on black.
private struct PreviewVideo: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}

/// The uncut timeline's sound across the full width, planned cuts shaded
/// red, and the preview's playhead. Click or drag to move the preview.
private struct CutStrip: View {
    let project: Project
    let waveforms: [UUID?: Waveform]
    let cuts: [TickRange]
    @Binding var range: TickRange?
    /// Uncut output time of the preview's playhead.
    let playhead: Tick
    let scrub: (Tick) -> Void

    var body: some View {
        GeometryReader { geometry in
            let total = max(TimelineMath.outputDuration(project), 1)
            let scale = geometry.size.width / CGFloat(total)
            Canvas { context, size in
                let all = CGRect(origin: .zero, size: size)
                context.fill(Path(roundedRect: all, cornerRadius: 6),
                             with: .color(Instrument.thumbnail))
                var clipped = context
                clipped.clip(to: Path(roundedRect: all, cornerRadius: 6))
                drawWaveforms(scale: scale, size: size, context: clipped)
                for cut in cuts {
                    let rect = CGRect(x: CGFloat(cut.start) * scale, y: 0,
                                      width: max(CGFloat(cut.duration) * scale, 1),
                                      height: size.height)
                    clipped.fill(Path(rect), with: .color(.red.opacity(0.45)))
                }
                if let range {
                    let left = CGFloat(range.start) * scale, right = CGFloat(range.end) * scale
                    let shade = GraphicsContext.Shading.color(.black.opacity(0.55))
                    clipped.fill(Path(CGRect(x: 0, y: 0, width: left, height: size.height)),
                                 with: shade)
                    clipped.fill(Path(CGRect(x: right, y: 0, width: size.width - right,
                                             height: size.height)), with: shade)
                    clipped.stroke(Path(CGRect(x: left, y: 1, width: right - left,
                                               height: size.height - 2)),
                                   with: .color(Instrument.neon), lineWidth: 2)
                }
                let x = CGFloat(playhead) * scale
                clipped.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)),
                             with: .color(Instrument.neon))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                func tick(_ x: CGFloat) -> Tick {
                    Tick((Double(min(max(x, 0), geometry.size.width)) / Double(scale)).rounded())
                }
                if NSEvent.modifierFlags.contains(.shift) {
                    let a = tick(drag.startLocation.x), b = tick(drag.location.x)
                    let start = min(a, b), end = max(a, b)
                    range = end > start ? TickRange(start: start, duration: end - start) : nil
                } else {
                    scrub(tick(drag.location.x))
                }
            })
        }
    }

    private func drawWaveforms(scale: CGFloat, size: CGSize, context: GraphicsContext) {
        guard scale > 0 else { return }
        let ticksPerPoint = 1 / Double(scale)
        var bars = Path()
        var cursor: Tick = 0
        for segment in project.segments {
            defer { cursor += segment.duration }
            guard case .video(let video) = segment,
                  let waveform = waveforms[video.sourceID] else { continue }
            let startX = CGFloat(cursor) * scale
            let endX = CGFloat(cursor + segment.duration) * scale
            let pointSeconds = Ticks.seconds(Tick(ticksPerPoint.rounded(.up))) * video.rate
            var x = startX.rounded(.down)
            while x < endX {
                let offset = Tick((Double(x - startX) * ticksPerPoint).rounded())
                let from = Ticks.seconds(video.sourceRange.start
                                         + video.sourceOffset(atOutput: max(offset, 0)))
                let peak = CGFloat(waveform.peak(fromSeconds: from, toSeconds: from + pointSeconds))
                let half = max(peak * (size.height - 8) / 2, 0.5)
                bars.addRect(CGRect(x: x, y: size.height / 2 - half, width: 1, height: half * 2))
                x += 1
            }
        }
        context.fill(bars, with: .color(.white.opacity(0.55)))
    }
}
