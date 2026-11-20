import SwiftUI
import TitleCutCore

/// Remove Filler Words sheet. Fillers are found in transcripts: saved ones
/// of the videos are used; without one, the person chooses a language and
/// presses Transcribe, and nothing runs until then. Then it shows the count
/// and time saved, and Remove applies every cut, with auto-captions rebuilt,
/// as one undo step and closes the sheet.
struct RemoveFillersSheet: View {
    let store: ProjectStore

    @State private var transcription: Transcription
    @State private var task: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    /// - Parameters:
    ///   - videos: The videos the timeline plays, keyed by `VideoSegment.sourceID`.
    ///   - savedTranscripts: The document's transcripts.
    ///   - saveTranscript: Stores a new transcript in the document.
    init(store: ProjectStore, videos: [(key: UUID?, url: URL)], savedTranscripts: [Transcript],
         saveTranscript: @escaping (Transcript) -> Void) {
        self.store = store
        _transcription = State(initialValue: Transcription(
            videos: videos, savedTranscripts: savedTranscripts,
            byHand: "Cut filler words by hand with Split and Delete.",
            saveTranscript: saveTranscript))
    }

    var body: some View {
        let words = transcription.isWorking ? nil : transcription.usableWords
        VStack(spacing: 0) {
            InspectorHeader(label: "REMOVE FILLER WORDS",
                            trailing: words != nil ? "SAVED TRANSCRIPT" : nil)
            VStack(alignment: .leading, spacing: 0) {
                if let words {
                    result(FillerRemoval.cuts(for: words, in: store.project))
                } else {
                    InstrumentSection("Language") {
                        LanguageMenu(transcription: transcription)
                        Text("Filler words are found in a transcript of the speech. "
                             + "Transcribing runs on this Mac and is saved with the project.")
                            .font(.system(size: 12))
                            .foregroundStyle(Instrument.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                TranscriptionStatus(transcription: transcription)
                HStack(spacing: 8) {
                    Spacer()
                    Button("CANCEL", action: cancel)
                        .buttonStyle(InstrumentButtonStyle(filled: false))
                        .keyboardShortcut(.cancelAction)
                    if let words {
                        let cuts = FillerRemoval.cuts(for: words, in: store.project)
                        Button("REMOVE") { remove(cuts, words: words) }
                            .buttonStyle(InstrumentButtonStyle(filled: true))
                            .keyboardShortcut(.defaultAction)
                            .disabled(cuts.isEmpty)
                    } else {
                        Button("TRANSCRIBE", action: transcribe)
                            .buttonStyle(InstrumentButtonStyle(filled: true))
                            .keyboardShortcut(.defaultAction)
                            .disabled(transcription.isWorking
                                      || transcription.localeID.isEmpty)
                    }
                }
            }
            .padding(16)
            .overlay(alignment: .top) { Rectangle().fill(Instrument.divider).frame(height: 1) }
        }
        .frame(width: 400)
        .background(Instrument.background)
        .preferredColorScheme(.light)
        .interactiveDismissDisabled(transcription.isWorking)
        .task { await transcription.load(preferSaved: true) }
        .onDisappear { task?.cancel() }
    }

    private func result(_ cuts: [TickRange]) -> some View {
        let saved = cuts.reduce(0) { $0 + $1.duration }
        return InstrumentSection("Result") {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                readout("\(cuts.count)", label: cuts.count == 1 ? "CUT" : "CUTS")
                readout(String(format: "%.1f S", Ticks.seconds(saved)), label: "REMOVED")
            }
            Text("Cuts um, uh, er, ah, hmm and similar sounds. Auto-captions are made "
                 + "again without them.")
                .font(.system(size: 12))
                .foregroundStyle(Instrument.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    // MARK: Work

    private func transcribe() {
        guard task == nil, !transcription.isWorking else { return }
        task = Task {
            do {
                _ = try await transcription.words()
                transcription.phase = .ready
            } catch is CancellationError {
                // Cancel closes the sheet; nothing to report.
            } catch {
                transcription.phase = .failed(transcription.failure(for: error))
            }
            task = nil
        }
    }

    private func remove(_ cuts: [TickRange], words: [UUID?: [TranscriptWord]]) {
        let commands = FillerRemoval.commands(removing: cuts, from: store.project, words: words)
        guard !commands.isEmpty else { return }
        store.beginGesture(named: "Remove Filler Words")
        for command in commands { store.perform(command) }
        store.endGesture()
        dismiss()
    }

    private func cancel() {
        task?.cancel()
        dismiss()
    }
}
