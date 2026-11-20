import AVFoundation
import CoreImage
import Metal
import Synchronization

/// The custom compositor that draws every preview and export frame (§6.2).
///
/// Requests are rendered on a private serial queue. The render context and
/// the cancel flag live in `Mutex`es so the type is `Sendable` as
/// `AVVideoCompositing` requires.
public final class TitleCutCompositor: NSObject, AVVideoCompositing {
    /// One Metal-backed context for the life of the compositor.
    ///
    /// Colour management is off: pixels keep the source encoding, and the
    /// source's colour attachments are copied to the output buffer. An
    /// unscaled video frame therefore passes through unchanged, as in M1.
    private let ciContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    /// Title bitmaps, cached for the life of the compositor.
    private let titleRenderer = TitleRenderer()

    private let queue = DispatchQueue(label: "com.byteclub.titlecut.compositor",
                                      qos: .userInitiated)
    private let renderContext = Mutex<AVVideoCompositionRenderContext?>(nil)
    /// Set by `cancelAllPendingVideoCompositionRequests`; cleared once the
    /// requests queued before the cancel have been drained.
    private let cancelPending = Mutex(false)

    private static let pixelFormat = Int(kCVPixelFormatType_32BGRA)

    /// Decoded stills by file, kept for the life of the compositor.
    private let stills = Mutex<[URL: CIImage]>([:])

    /// The still at `url`, decoded once; `nil` if it cannot be read.
    private func stillImage(at url: URL) -> CIImage? {
        if let cached = stills.withLock({ $0[url] }) { return cached }
        guard let image = CIImage(contentsOf: url) else { return nil }
        stills.withLock { $0[url] = image }
        return image
    }

    public let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: TitleCutCompositor.pixelFormat,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: TitleCutCompositor.pixelFormat,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    override public init() {
        super.init()
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext.withLock { $0 = newRenderContext }
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            if cancelPending.withLock({ $0 }) {
                request.finishCancelledRequest()
                return
            }
            render(request)
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        cancelPending.withLock { $0 = true }
        // Runs after every request queued before the cancel, which therefore
        // finish as cancelled. Blocking here is what the protocol requires.
        queue.sync { cancelPending.withLock { $0 = false } }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? TitleCutInstruction else {
            request.finish(with: CompositorError.unknownInstruction)
            return
        }
        let context = renderContext.withLock { $0 } ?? request.renderContext
        guard let output = context.newPixelBuffer() else {
            request.finish(with: CompositorError.noOutputBuffer)
            return
        }
        let size = context.size

        let main = instruction.content
        if let trackID = main.trackID {
            guard let source = request.sourceFrame(byTrackID: trackID) else {
                request.finish(with: CompositorError.missingSourceFrame)
                return
            }
            CVBufferPropagateAttachments(source, output)
        }
        guard var image = draw(main, request: request, size: size) else {
            request.finish(with: CompositorError.missingSourceFrame)
            return
        }
        image = apply(instruction.effect, to: image, of: instruction, request: request,
                      size: size)
        let outputTime = request.compositionTime.seconds * Double(Ticks.perSecond)
        let composed = instruction.titles.isEmpty ? image : FrameRenderer.composite(
            instruction.titles, over: image, at: outputTime, renderSize: size,
            titleRenderer: titleRenderer)

        ciContext.render(composed, to: output, bounds: CGRect(origin: .zero, size: size),
                         colorSpace: nil)
        request.finish(withComposedVideoFrame: output)
    }

    /// One content's frame at the request's time; `nil` if its source
    /// frame is missing.
    private func draw(_ content: TitleCutInstruction.Content,
                      request: AVAsynchronousVideoCompositionRequest, size: CGSize) -> CIImage? {
        switch content {
        case let .video(trackID, transform, framing, split):
            guard let source = request.sourceFrame(byTrackID: trackID) else { return nil }
            let frame = CIImage(cvPixelBuffer: source, options: [.colorSpace: NSNull()])
            return FrameRenderer.render(source: frame, preferredTransform: transform,
                                        renderSize: size, frame: framing, split: split)
        case let .still(url, zoom, origin):
            guard let still = stillImage(at: url) else { return FrameRenderer.black(renderSize: size) }
            let time = CMTimeSubtract(request.compositionTime, origin).seconds
            return StillRenderer.render(still, zoom: zoom, at: time * Double(Ticks.perSecond),
                                        renderSize: size)
        case .card(let color):
            return FrameRenderer.solid(color, renderSize: size)
        case .gap:
            return FrameRenderer.black(renderSize: size)
        }
    }

    /// `image` with a clip transition's dip or blend at the request's time.
    /// A blend whose other frame is missing leaves `image` as it is.
    private func apply(_ effect: TitleCutInstruction.Effect, to image: CIImage,
                       of instruction: TitleCutInstruction,
                       request: AVAsynchronousVideoCompositionRequest, size: CGSize) -> CIImage {
        let range = instruction.timeRange
        let elapsed = CMTimeSubtract(request.compositionTime, range.start).seconds
        let progress = range.duration.seconds > 0
            ? min(max(elapsed / range.duration.seconds, 0), 1) : 0
        switch effect {
        case .none:
            return image
        case let .dip(white, from, to):
            let colour = CIImage(color: white ? .white : .black)
                .cropped(to: CGRect(origin: .zero, size: size))
            return FrameRenderer.mix(image, with: colour, amount: from + (to - from) * progress)
        case let .blend(other, from, to):
            guard let frame = draw(other, request: request, size: size) else { return image }
            return FrameRenderer.mix(image, with: frame, amount: from + (to - from) * progress)
        }
    }

    enum CompositorError: Error {
        case unknownInstruction
        case noOutputBuffer
        case missingSourceFrame
    }
}
