import SwiftUI
import TitleCutCore

/// Transcribing the speech of the videos the timeline plays, for a sheet:
/// the languages this Mac offers, the chosen one, saved transcripts to
/// reuse, and progress. Auto-Captions and Remove Filler Words share it,
/// with `LanguageMenu` and `TranscriptionStatus` as their views.
@MainActor
@Observable
final class Transcription {
    enum Phase {
        case loading
        case ready
        case working(Transcriber.Phase)
        case failed(Failure)
    }

    struct Failure {
        let what: String
        let action: String
    }

    /// Each video to transcribe: the key its clips use
    /// (`VideoSegment.sourceID`) and its file.
    let videos: [(key: UUID?, url: URL)]
    /// The document's transcripts; a new one is added when saved.
    private(set) var savedTranscripts: [Transcript]
    @ObservationIgnored private let saveTranscript: (Transcript) -> Void
    /// What to do instead when this Mac or video cannot be transcribed.
    @ObservationIgnored private let byHand: String

    private(set) var locales: [(id: String, name: String)] = []
    var localeID = ""
    private(set) var fingerprints: [UUID?: SourceFingerprint] = [:]
    var transcribeAgain = false
    var phase = Phase.loading
    /// The file being read, for a failure's advice.
    @ObservationIgnored private var currentURL: URL?

    init(videos: [(key: UUID?, url: URL)], savedTranscripts: [Transcript], byHand: String,
         saveTranscript: @escaping (Transcript) -> Void) {
        self.videos = videos
        self.savedTranscripts = savedTranscripts
        self.byHand = byHand
        self.saveTranscript = saveTranscript
    }

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    /// The saved transcript of video `key` in the chosen language.
    private func saved(_ key: UUID?) -> Transcript? {
        guard let fingerprint = fingerprints[key] else { return nil }
        return savedTranscripts.first { $0.matches(fingerprint, locale: localeID) }
    }

    /// Every video's words from saved transcripts in the chosen language,
    /// keyed by `VideoSegment.sourceID`; `nil` unless every video has one.
    var usableWords: [UUID?: [TranscriptWord]]? {
        guard !transcribeAgain, !videos.isEmpty else { return nil }
        var words: [UUID?: [TranscriptWord]] = [:]
        for video in videos {
            guard let transcript = saved(video.key) else { return nil }
            words[video.key] = transcript.words
        }
        return words
    }

    var languageName: String {
        locales.first { $0.id == localeID }?.name ?? localeID
    }

    /// Supported languages, the default one, and the videos' fingerprints.
    /// With `preferSaved`, a saved transcript of one of the videos chooses
    /// the language instead of the Mac's.
    func load(preferSaved: Bool = false) async {
        let supported = await Transcriber.supportedLocales()
        locales = supported
            .map { locale in
                let id = locale.identifier(.bcp47)
                return (id, Locale.current.localizedString(forIdentifier: id) ?? id)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let preferred = await Transcriber.supportedLocale(equivalentTo: .current)?
            .identifier(.bcp47)
        localeID = locales.first { $0.id == preferred }?.id ?? locales.first?.id ?? ""
        for video in videos {
            fingerprints[video.key] = try? await SourceFingerprint.of(video.url)
        }
        if preferSaved, let saved = savedTranscripts.first(where: { transcript in
            fingerprints.values.contains(transcript.source)
                && locales.contains { $0.id == transcript.locale }
        }) {
            localeID = saved.locale
        }
        if locales.isEmpty {
            phase = .failed(failure(for: Transcriber.TranscribeError.unavailable))
        } else if case .loading = phase {
            phase = .ready
        }
    }

    /// Every video's words, keyed by `VideoSegment.sourceID`: from its saved
    /// transcript in the chosen language, or transcribed and saved. A video
    /// without sound has none. Sets `phase` to working; the caller sets it
    /// after.
    /// - Throws: `CancellationError` when the calling task is cancelled, or
    ///   what `Transcriber.transcribe` throws (`noAudio` only when no video
    ///   has sound).
    func words() async throws -> [UUID?: [TranscriptWord]] {
        if let reuse = usableWords {
            phase = .working(.transcribing(1))
            return reuse
        }
        let localeID = localeID
        let again = transcribeAgain
        var words: [UUID?: [TranscriptWord]] = [:]
        var silent = 0
        for (index, video) in videos.enumerated() {
            if !again, let reuse = saved(video.key) {
                words[video.key] = reuse.words
                continue
            }
            phase = .working(.preparing)
            currentURL = video.url
            let source: SourceFingerprint
            if let known = fingerprints[video.key] {
                source = known
            } else {
                source = try await SourceFingerprint.of(video.url)
                fingerprints[video.key] = source
            }
            let share = 1 / Double(videos.count)
            let found: [TranscriptWord]
            do {
                found = try await Transcriber.transcribe(
                    audioOf: video.url, locale: Locale(identifier: localeID)
                ) { work in
                    // One bar across every video.
                    let overall: Transcriber.Phase = switch work {
                    case .transcribing(let fraction):
                        .transcribing((Double(index) + fraction) * share)
                    default: work
                    }
                    Task { @MainActor [weak self] in self?.progressed(overall) }
                }
            } catch Transcriber.TranscribeError.noAudio {
                silent += 1
                words[video.key] = []
                continue
            }
            let transcript = Transcript(locale: localeID, source: source, words: found)
            saveTranscript(transcript)
            savedTranscripts = savedTranscripts.replacing(with: transcript)
            words[video.key] = found
        }
        if silent == videos.count { throw Transcriber.TranscribeError.noAudio }
        transcribeAgain = false
        return words
    }

    /// Progress arrives from other threads; late updates after the work has
    /// ended, and fractions that would move a bar backwards, are ignored.
    private func progressed(_ work: Transcriber.Phase) {
        guard case .working(let current) = phase else { return }
        switch (current, work) {
        case let (.downloading(old), .downloading(new)), let (.transcribing(old), .transcribing(new)):
            if new > old { phase = .working(work) }
        default:
            phase = .working(work)
        }
    }

    func failure(for error: Error) -> Failure {
        switch error as? Transcriber.TranscribeError {
        case .unavailable:
            Failure(what: "Speech transcription is not available on this Mac.",
                    action: byHand)
        case .unsupportedLocale:
            Failure(what: "\(languageName) cannot be transcribed on this Mac.",
                    action: "Choose another language and start again.")
        case .noAudio:
            Failure(what: videos.count == 1 ? "The video has no audio track."
                                             : "None of the videos has an audio track.",
                    action: byHand)
        case .unreadableAudio:
            Failure(what: "The video's audio could not be read.",
                    action: "Check that \((currentURL ?? videos.first?.url)?.path ?? "the video") "
                        + "still plays, then start again.")
        case nil:
            Failure(what: "Transcription failed: \(error.localizedDescription)",
                    action: "If the speech model was downloading, check the internet "
                        + "connection, then start again.")
        }
    }
}

/// The language menu for a `Transcription`.
struct LanguageMenu: View {
    let transcription: Transcription

    var body: some View {
        Menu {
            ForEach(transcription.locales, id: \.id) { locale in
                Button(locale.name) { transcription.localeID = locale.id }
            }
        } label: {
            HStack {
                Text(transcription.locales.isEmpty ? "Loading languages…"
                                                   : transcription.languageName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Instrument.text)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Instrument.dim)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Instrument.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Instrument.outline))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(transcription.locales.isEmpty || transcription.isWorking)
    }
}

/// Progress or failure of a `Transcription`; empty otherwise.
struct TranscriptionStatus: View {
    let transcription: Transcription

    var body: some View {
        switch transcription.phase {
        case .loading, .ready:
            EmptyView()
        case .working(let work):
            VStack(alignment: .leading, spacing: 6) {
                switch work {
                case .preparing:
                    label("Reading the audio…")
                    ProgressView().progressViewStyle(.linear).tint(Instrument.neon)
                case .downloading(let fraction):
                    label("Downloading the \(transcription.languageName) speech model…")
                    bar(fraction)
                case .transcribing(let fraction):
                    label("Transcribing…")
                    bar(fraction)
                }
            }
        case .failed(let failure):
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

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Instrument.muted)
    }

    private func bar(_ fraction: Double) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: fraction)
                .tint(Instrument.neon)
            Text(fraction, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Instrument.muted)
                .frame(width: 36, alignment: .trailing)
        }
    }
}
