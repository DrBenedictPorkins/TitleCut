import SwiftUI
import TitleCutCore

/// Auto-Captions sheet: language, style, then transcription progress and
/// Cancel. Saved transcripts of the same videos and language are reused.
///
/// Cancel stops the work and closes the sheet without a message. A finished
/// run applies one "Auto-Captions" step and closes the sheet. A failed one
/// says what failed and what to do, and Start tries again.
struct AutoCaptionsSheet: View {
    let store: ProjectStore
    let libraryStyles: [TitleStyle]

    @State private var transcription: Transcription
    @State private var styleID = StyleLibrary.captionID
    @State private var task: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    /// - Parameters:
    ///   - videos: The videos the timeline plays, keyed by `VideoSegment.sourceID`.
    ///   - savedTranscripts: The document's transcripts.
    ///   - saveTranscript: Stores a new transcript in the document.
    init(store: ProjectStore, videos: [(key: UUID?, url: URL)], savedTranscripts: [Transcript],
         libraryStyles: [TitleStyle], saveTranscript: @escaping (Transcript) -> Void) {
        self.store = store
        self.libraryStyles = libraryStyles
        _transcription = State(initialValue: Transcription(
            videos: videos, savedTranscripts: savedTranscripts,
            byHand: "Add captions by hand with + > Title.",
            saveTranscript: saveTranscript))
    }

    var body: some View {
        let isWorking = transcription.isWorking
        VStack(spacing: 0) {
            InspectorHeader(label: "AUTO-CAPTIONS",
                            trailing: transcription.usableWords != nil
                                ? "SAVED TRANSCRIPT" : nil)

            VStack(alignment: .leading, spacing: 0) {
                InstrumentSection("Language") {
                    LanguageMenu(transcription: transcription)
                    if transcription.usableWords != nil, !isWorking {
                        HStack(spacing: 8) {
                            Text("Captions will reuse the saved transcript.")
                                .font(.system(size: 12))
                                .foregroundStyle(Instrument.muted)
                            Spacer()
                            Button("Transcribe again") { transcription.transcribeAgain = true }
                                .buttonStyle(InstrumentButtonStyle(filled: false))
                        }
                    }
                }
                InstrumentSection("Style", trailing: nil) {
                    styleGrid
                }
                .disabled(isWorking)
            }

            VStack(alignment: .leading, spacing: 12) {
                TranscriptionStatus(transcription: transcription)
                HStack(spacing: 8) {
                    Spacer()
                    Button("CANCEL", action: cancel)
                        .buttonStyle(InstrumentButtonStyle(filled: false))
                        .keyboardShortcut(.cancelAction)
                    Button("START", action: start)
                        .buttonStyle(InstrumentButtonStyle(filled: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || transcription.localeID.isEmpty
                                  || !libraryStyles.contains { $0.id == styleID })
                }
            }
            .padding(16)
            .overlay(alignment: .top) { Rectangle().fill(Instrument.divider).frame(height: 1) }
        }
        .frame(width: 600)
        .background(Instrument.background)
        .preferredColorScheme(.light)
        .interactiveDismissDisabled(isWorking)
        .task { await load() }
        .onDisappear { task?.cancel() }
    }

    private var styleGrid: some View {
        ScrollView {
            StyleGrid(styles: libraryStyles, selection: styleID, columns: 3, tileHeight: 96,
                      sample: "Caption", badge: "SELECTED") { styleID = $0.id }
                .padding(2)
        }
        .scrollIndicators(.never)
        .frame(height: 300)
    }

    // MARK: Work

    private func load() async {
        if !libraryStyles.contains(where: { $0.id == styleID }),
           let first = libraryStyles.first {
            styleID = first.id
        }
        await transcription.load()
    }

    private func start() {
        guard task == nil, !transcription.isWorking,
              let style = libraryStyles.first(where: { $0.id == styleID }) else { return }
        task = Task {
            do {
                let words = try await transcription.words()
                let titles = AutoCaptions.titles(for: words, in: store.project, style: style,
                                                 makeID: UUID.init)
                guard !titles.isEmpty else {
                    transcription.phase = .failed(Transcription.Failure(
                        what: "No speech was found in the kept parts of the video.",
                        action: "Check that the language is right, then start again."))
                    task = nil
                    return
                }
                store.perform(.replaceAutoCaptions(titles: titles, style: style))
                dismiss()
            } catch is CancellationError {
                // Cancel closes the sheet; nothing to report.
            } catch {
                transcription.phase = .failed(transcription.failure(for: error))
            }
            task = nil
        }
    }

    private func cancel() {
        task?.cancel()
        dismiss()
    }
}
