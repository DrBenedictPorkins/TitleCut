import AppKit
import SwiftUI
import TitleCutCore
import UniformTypeIdentifiers

/// Export sheet (§9): MP4 (size, codec, subtitles) or animated GIF (loop, width,
/// frame rate) first; Next asks where to save and starts the export, with
/// progress and Cancel.
///
/// Cancel stops a running export and closes the sheet without a message. A
/// finished export closes the sheet. A failed one says what failed and what
/// to do, and Export tries again. With auto-captions on the timeline, an
/// .srt can be saved next to the MP4; if only that fails, the sheet says so
/// and offers Done.
struct ExportSheet: View {
    let project: Project
    /// Every video's file, keyed by `VideoSegment.sourceID`.
    let sourceURLs: [UUID?: URL]
    /// Default file name, without extension.
    let documentName: String

    @State private var format = Format.mp4
    @State private var codec: Codec
    /// MP4 size, remembered between exports.
    @AppStorage("export.size") private var size = ExportSize.medium
    @State private var gif = GIFExporter.Settings()
    /// About how big the GIF will be, for `gif`; `nil` while working it out.
    @State private var gifEstimate: Int?
    @State private var destination: URL?
    @State private var phase = Phase.ready
    @State private var exportTask: Task<Void, Never>?
    /// Save an .srt next to the MP4. Offered only when there are auto-captions.
    @State private var saveSubtitles: Bool
    /// Why the last purchase or restore the person asked for failed.
    @State private var purchaseFailure: Failure?
    private var unlock: Unlock { .shared }
    @Environment(\.dismiss) private var dismiss

    private enum Format { case mp4, gif }

    private enum Phase {
        case ready
        case exporting(fraction: Double)
        case failed(Failure)
        /// The MP4 was written; the .srt was not.
        case subtitlesFailed(Failure)
    }

    private struct Failure {
        let what: String
        let action: String
    }

    init(project: Project, sourceURLs: [UUID?: URL], documentName: String) {
        self.project = project
        self.sourceURLs = sourceURLs
        self.documentName = documentName
        _codec = State(initialValue: project.output.codec)
        _saveSubtitles = State(initialValue: false)
    }

    private var hasSubtitles: Bool { SRT.hasCues(project) }

    private var subtitlesFailed: Bool {
        if case .subtitlesFailed = phase { return true }
        return false
    }

    private var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(label: format == .mp4 ? "EXPORT MP4" : "EXPORT GIF",
                            trailing: unlock.isUnlocked ? nil : "WATERMARKED")
            VStack(alignment: .leading, spacing: 0) {
                InstrumentSection("Format") {
                    ChipRow(options: [(value: Format.mp4, label: "MP4"),
                                      (value: Format.gif, label: "GIF")],
                            selection: format) { format = $0 }
                }
                .disabled(isExporting || subtitlesFailed)
                if format == .mp4 {
                    mp4Sections
                } else {
                    gifSections
                }
                if !unlock.isUnlocked {
                    watermarkSection
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                status
                HStack(spacing: 8) {
                    Spacer()
                    if subtitlesFailed {
                        Button("DONE") { dismiss() }
                            .buttonStyle(InstrumentButtonStyle(filled: true))
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("CANCEL", action: cancel)
                            .buttonStyle(InstrumentButtonStyle(filled: false))
                            .keyboardShortcut(.cancelAction)
                        Button("NEXT", action: export)
                            .buttonStyle(InstrumentButtonStyle(filled: true))
                            .keyboardShortcut(.defaultAction)
                            .disabled(isExporting)
                            .help("Choose where to save, then export")
                    }
                }
            }
            .padding(16)
            .overlay(alignment: .top) { Rectangle().fill(Instrument.divider).frame(height: 1) }
        }
        .frame(width: 400)
        .background(Instrument.background)
        .preferredColorScheme(.light)
        .interactiveDismissDisabled(isExporting)
        .task(id: format == .gif ? gif : nil) { await estimateGIF() }
        .onDisappear { exportTask?.cancel() }
    }

    /// Size, codec, and subtitles when there are auto-captions.
    @ViewBuilder private var mp4Sections: some View {
        InstrumentSection("Size") {
            ChipRow(options: ExportSize.allCases.map { (value: $0, label: $0.label) },
                    selection: size) { size = $0 }
            Text(sizeDescription)
                .font(Instrument.mono(12))
                .foregroundStyle(Instrument.text)
            Text(size == .original
                 ? "Full size and frame rate at the highest quality."
                 : "Scaled for phones, at up to 30 fps. Small suits Messages and Slack.")
                .font(.system(size: 12))
                .foregroundStyle(Instrument.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(isExporting || subtitlesFailed)
        InstrumentSection("Codec") {
            ChipRow(options: [(value: Codec.h264, label: "H.264"),
                              (value: Codec.hevc, label: "HEVC")],
                    selection: codec) { codec = $0 }
            Text(codec == .h264 ? "Plays everywhere." : "Smaller files; newer devices.")
                .font(.system(size: 12))
                .foregroundStyle(Instrument.muted)
        }
        .disabled(isExporting || subtitlesFailed)
        if hasSubtitles {
            InstrumentSection("Subtitles") {
                Toggle("Also save subtitles (.srt) next to the video", isOn: $saveSubtitles)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(Instrument.text)
                    .help("Saves the auto-captions next to the MP4, with the same name")
            }
            .disabled(isExporting || subtitlesFailed)
        }
    }

    /// The chosen size's frame and, for a scaled size, its estimated file.
    private var sizeDescription: String {
        let frame = CompositionBuilder.renderSize(size.scaled(project))
        let pixels = "\(Int(frame.width)) × \(Int(frame.height))"
        guard let bytes = size.estimatedBytes(of: project, codec: codec) else {
            return pixels + " · size depends on the footage"
        }
        return pixels + " · about "
            + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Looping, width and frame rate. A GIF has no sound.
    @ViewBuilder private var gifSections: some View {
        Group {
            InstrumentSection("Loop") {
                ChipRow(options: [(value: true, label: "Forever"), (value: false, label: "Once")],
                        selection: gif.loops) { gif.loops = $0 }
            }
            InstrumentSection("Width") {
                ChipRow(options: GIFExporter.Settings.widths.map { (value: $0, label: "\($0) px") },
                        selection: gif.width) { gif.width = $0 }
                Text("Height follows the video's shape. A GIF has no sound.")
                    .font(.system(size: 12))
                    .foregroundStyle(Instrument.muted)
            }
            InstrumentSection("Frame rate") {
                ChipRow(options: GIFExporter.Settings.framesPerSecondChoices.map {
                            (value: $0, label: "\($0) fps") },
                        selection: gif.framesPerSecond) { gif.framesPerSecond = $0 }
                Text("Lower rates make smaller files.")
                    .font(.system(size: 12))
                    .foregroundStyle(Instrument.muted)
            }
            InstrumentSection("Size") {
                Text(gifEstimate.map {
                    "About " + ByteCountFormatter.string(fromByteCount: Int64($0),
                                                         countStyle: .file)
                } ?? "Estimating…")
                    .font(Instrument.mono(12))
                    .foregroundStyle(Instrument.text)
                if TimelineMath.outputDuration(project) > GIFExporter.longDuration {
                    Text("This video is over 15 seconds, long for a GIF. For a smaller "
                         + "file, trim the video or choose a lower width or frame rate.")
                        .font(.system(size: 12))
                        .foregroundStyle(Instrument.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .disabled(isExporting)
    }

    /// Works out `gifEstimate` for the current GIF options. A failure
    /// leaves it unknown; the export itself reports what went wrong.
    private func estimateGIF() async {
        guard format == .gif else { return }
        gifEstimate = nil
        let project = project, sourceURLs = sourceURLs, settings = gif
        let watermark = !unlock.isUnlocked
        gifEstimate = try? await GIFExporter.estimatedSize(of: project, sourceURLs: sourceURLs,
                                                           settings: settings,
                                                           watermark: watermark)
    }

    /// The watermark, and the purchase that removes it.
    private var watermarkSection: some View {
        InstrumentSection("Watermark") {
            Text("Exports carry a TitleCut watermark across the middle. A one-time "
                 + "purchase removes it from every export.")
                .font(.system(size: 12))
                .foregroundStyle(Instrument.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let product = unlock.product {
                    Button("REMOVE WATERMARK · \(product.displayPrice)") {
                        run { try await unlock.purchase() }
                    }
                    .buttonStyle(InstrumentButtonStyle(filled: true))
                }
                Button("RESTORE PURCHASE") {
                    run(ifNotUnlocked: Failure(
                        what: "No purchase of the unlock was found for this Apple Account.",
                        action: "Sign in to the App Store app with the account that bought "
                            + "it, then restore again.")) { try await unlock.restore() }
                }
                    .buttonStyle(InstrumentButtonStyle(filled: false))
                    .help("Unlock with a purchase already made on this Apple Account")
            }
            .disabled(unlock.isBusy || isExporting)
            if let purchaseFailure {
                VStack(alignment: .leading, spacing: 4) {
                    Text(purchaseFailure.what)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Instrument.text)
                    Text(purchaseFailure.action)
                        .font(.system(size: 12))
                        .foregroundStyle(Instrument.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Runs a purchase or restore; a failure stays on the sheet until the
    /// next try. `ifNotUnlocked` is shown when it ends without an unlock (a
    /// cancelled purchase shows nothing).
    private func run(ifNotUnlocked: Failure? = nil,
                     _ action: @escaping @MainActor () async throws -> Bool) {
        purchaseFailure = nil
        Task {
            do {
                if try await !action() { purchaseFailure = ifNotUnlocked }
            } catch {
                purchaseFailure = Failure(
                    what: "The App Store could not complete it: \(error.localizedDescription)",
                    action: "Check the internet connection and that you are signed in to the "
                        + "App Store, then try again.")
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .ready:
            EmptyView()
        case .exporting(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                if let destination {
                    Text("Exporting to \(destination.lastPathComponent)…")
                        .font(.system(size: 12))
                        .foregroundStyle(Instrument.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 10) {
                    ProgressView(value: fraction)
                        .tint(Instrument.neon)
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(Instrument.mono(12))
                        .foregroundStyle(Instrument.muted)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        case .failed(let failure), .subtitlesFailed(let failure):
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.what)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Instrument.text)
                Text(failure.action)
                    .font(.system(size: 12))
                    .foregroundStyle(Instrument.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Shows the save panel. Returns `false` if the person cancelled it.
    private func chooseDestination() -> Bool {
        let panel = NSSavePanel()
        let ext = format == .mp4 ? "mp4" : "gif"
        panel.allowedContentTypes = [format == .mp4 ? .mpeg4Movie : .gif]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = destination.map {
            $0.deletingPathExtension().appendingPathExtension(ext).lastPathComponent
        } ?? "\(documentName).\(ext)"
        if let destination { panel.directoryURL = destination.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        destination = url
        return true
    }

    /// Next: asks where to save, then exports there. Cancelling the save
    /// panel returns to the options.
    private func export() {
        guard !isExporting, chooseDestination(), let destination else { return }
        let project = project, sourceURLs = sourceURLs, codec = codec, gif = gif, size = size
        let isGIF = format == .gif
        let subtitles = !isGIF && hasSubtitles && saveSubtitles
        phase = .exporting(fraction: 0)
        exportTask = Task {
            do {
                let watermark = !(await Unlock.shared.refresh())
                let progress: @Sendable (Double) -> Void = { fraction in
                    Task { @MainActor in progressed(fraction) }
                }
                if isGIF {
                    try await GIFExporter.export(project, sourceURLs: sourceURLs,
                                                 to: destination,
                                                 settings: gif, watermark: watermark,
                                                 progress: progress)
                } else {
                    try await Exporter.export(project, sourceURLs: sourceURLs, to: destination,
                                              codec: codec, size: size, watermark: watermark,
                                              progress: progress)
                }
                if subtitles {
                    let url = SubtitleFile.url(nextTo: destination)
                    do {
                        try SubtitleFile.write(project, nextTo: destination)
                    } catch {
                        phase = .subtitlesFailed(Failure(
                            what: "\(destination.lastPathComponent) was saved, but "
                                + "\(url.lastPathComponent) could not be: "
                                + error.localizedDescription,
                            action: "Use File > Export Subtitles… to save the subtitles "
                                + "to a folder that can be written to."))
                        exportTask = nil
                        return
                    }
                }
                dismiss()
            } catch is CancellationError {
                // Cancel closes the sheet; nothing to report.
            } catch {
                phase = .failed(failure(for: error, destination: destination))
            }
            exportTask = nil
        }
    }

    /// Progress arrives from the session's thread; late or out-of-order
    /// updates never move the bar backwards.
    private func progressed(_ fraction: Double) {
        guard case .exporting(let current) = phase, fraction > current else { return }
        phase = .exporting(fraction: fraction)
    }

    private func cancel() {
        exportTask?.cancel()
        dismiss()
    }

    private func failure(for error: Error, destination: URL) -> Failure {
        switch error as? Exporter.ExportError {
        case .sourceUnreadable:
            Failure(what: project.addedSources.isEmpty ? "The source video could not be read."
                                                       : "A video could not be read.",
                    action: "Check that "
                        + (project.addedSources.isEmpty
                           ? sourceURLs[UUID?.none].map(\.path) ?? "the video"
                           : "the project's videos are still there and open")
                        + ", then export again.")
        case .nothingToExport:
            Failure(what: "The timeline is empty.",
                    action: "Add video to the timeline, then export again.")
        case .codecUnavailable(let codec):
            Failure(what: "This Mac cannot export \(codec == .hevc ? "HEVC" : "H.264") to MP4.",
                    action: "Choose the other codec, then Next.")
        case nil:
            Failure(what: "Could not write \(destination.lastPathComponent): "
                        + error.localizedDescription,
                    action: "Check that the folder can be written to and the disk has "
                        + "free space, or choose another location, then export again.")
        }
    }
}
