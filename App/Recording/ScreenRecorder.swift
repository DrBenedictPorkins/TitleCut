import AppKit
import AVFoundation
import Observation
import ScreenCaptureKit
import TitleCutCore

/// Record Screen: the person drags out a part of a screen, records it with
/// the system sound and the microphone, and the movie, saved in
/// Movies/TitleCut Recordings, is handed to the window that asked. One
/// recording at a time across the app. TitleCut's own windows are left out
/// of the picture and its own sound out of the audio.
@MainActor
@Observable
final class ScreenRecorder {
    static let shared = ScreenRecorder()

    enum Phase: Equatable {
        case idle
        /// The region picker is up.
        case choosing
        case recording(since: Date)
        /// The movie is being written.
        case finishing
    }

    private(set) var phase: Phase = .idle

    @ObservationIgnored private var picker: RegionPicker?
    @ObservationIgnored private var indicator: RecordingIndicator?
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var writer: RecordingWriter?
    /// The window that asked, for alerts.
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var deliver: ((URL) -> Void)?

    var isRecording: Bool {
        if case .recording = phase { true } else { false }
    }

    /// Shows the region picker; `deliver` gets the finished movie.
    func start(in window: NSWindow?, deliver: @escaping (URL) -> Void) {
        guard phase == .idle else { return }
        self.window = window
        self.deliver = deliver
        phase = .choosing
        let picker = RegionPicker(
            choose: { [weak self] region, screen in
                self?.closePicker()
                Task { await self?.record(region, on: screen) }
            },
            cancel: { [weak self] in
                self?.closePicker()
                self?.reset()
            })
        self.picker = picker
        picker.show()
    }

    /// Ends the recording and hands the movie over.
    func stop() {
        guard isRecording, let stream, let writer else { return }
        phase = .finishing
        indicator?.close()
        indicator = nil
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        Task {
            try? await stream.stopCapture()
            await finish(writer, at: end)
        }
    }

    private func closePicker() {
        picker?.close()
        picker = nil
    }

    private func reset() {
        stream = nil
        writer = nil
        deliver = nil
        phase = .idle
    }

    // MARK: Recording

    private func record(_ region: CGRect, on screen: NSScreen) async {
        guard let microphone = await microphoneAllowed() else { return reset() }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            showScreenRecordingOff()
            return reset()
        }
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == number }) else {
            showFailure("The screen you chose is no longer connected.",
                        action: "Choose a part of another screen.")
            return reset()
        }
        let ownApp = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp,
                                     exceptingWindows: [])

        let rect = ScreenRegion.displayRect(region, screenSize: screen.frame.size)
        let pixels = ScreenRegion.pixelSize(rect.size, scale: screen.backingScaleFactor)
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int(pixels.width)
        config.height = Int(pixels.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: RecordingWriter.frameRate)
        config.queueDepth = 8
        config.showsCursor = true
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        if microphone, let device = AVCaptureDevice.default(for: .audio) {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = device.uniqueID
        }

        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-\(UUID().uuidString).mov")
        do {
            let writer = try RecordingWriter(url: raw, pixelSize: pixels,
                                             microphone: config.captureMicrophone)
            let stream = SCStream(filter: filter, configuration: config, delegate: writer)
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
            if config.captureMicrophone {
                try stream.addStreamOutput(writer, type: .microphone,
                                           sampleHandlerQueue: writer.queue)
            }
            writer.stoppedBySystem = { [weak self] in
                Task { @MainActor in self?.stop() }
            }
            try await stream.startCapture()
            self.writer = writer
            self.stream = stream
        } catch {
            try? FileManager.default.removeItem(at: raw)
            showFailure("Recording could not start.", action: error.localizedDescription)
            return reset()
        }
        phase = .recording(since: .now)
        let globalRegion = region.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        indicator = RecordingIndicator(region: globalRegion, on: screen) { [weak self] in
            self?.stop()
        }
    }

    private func finish(_ writer: RecordingWriter, at end: CMTime) async {
        defer { reset() }
        do {
            guard try await writer.finish(at: end) else { return }
            let movie = try Self.recordingURL()
            try await RecordingMixdown.run(from: writer.url, to: movie)
            try? FileManager.default.removeItem(at: writer.url)
            deliver?(movie)
        } catch {
            showFailure("The recording could not be saved.",
                        action: "\(error.localizedDescription) Record again.")
        }
    }

    /// Whether to record the microphone; `nil` when the person cancels.
    /// Without access it asks whether to record without it.
    private func microphoneAllowed() async -> Bool? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return true }
        default: break
        }
        let alert = NSAlert()
        alert.messageText = "TitleCut cannot use the microphone."
        alert.informativeText = "To record your voice, turn on TitleCut in System Settings > "
            + "Privacy & Security > Microphone, then record again."
        alert.addButton(withTitle: "Record Without Microphone")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? false : nil
    }

    private func showScreenRecordingOff() {
        let alert = NSAlert()
        alert.messageText = "TitleCut cannot record the screen."
        alert.informativeText = "Turn on TitleCut in System Settings > Privacy & Security > "
            + "Screen & System Audio Recording, then record again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security"
                         + "?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showFailure(_ what: String, action: String) {
        let alert = NSAlert()
        alert.messageText = what
        alert.informativeText = action
        alert.present(in: window)
    }

    /// A new file in Movies/TitleCut Recordings, named for the time.
    private static func recordingURL() throws -> URL {
        // The real home, not the sandbox container's.
        let home = getpwuid(getuid())?.pointee.pw_dir.map { String(cString: $0) }
            ?? NSHomeDirectory()
        let folder = URL(fileURLWithPath: home)
            .appendingPathComponent("Movies/TitleCut Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Screen Recording \(formatter.string(from: .now))"
        var url = folder.appendingPathComponent(name).appendingPathExtension("mov")
        var count = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(count)").appendingPathExtension("mov")
            count += 1
        }
        return url
    }
}
