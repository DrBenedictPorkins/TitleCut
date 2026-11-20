import CoreImage
import Foundation

/// Draws a still segment's frame: the part of the image its camera motion
/// shows at a moment, scaled to fill the output (§4.4).
public enum StillRenderer {
    /// The camera at `time` (relative to the segment start): centre and
    /// scale interpolated between the surrounding keyframes with the later
    /// one's easing, holding the first before it and the last after it.
    /// No keyframes: the whole frame.
    public static func camera(_ zoom: [ZoomKeyframe], at time: Double)
        -> (center: CGPoint, scale: Double) {
        guard let first = zoom.first, let last = zoom.last else {
            return (CGPoint(x: 0.5, y: 0.5), 1)
        }
        if time <= Double(first.time) { return (first.center, first.scale) }
        if time >= Double(last.time) { return (last.center, last.scale) }
        let index = zoom.firstIndex { Double($0.time) > time } ?? zoom.count - 1
        let from = zoom[index - 1], to = zoom[index]
        let span = Double(to.time - from.time)
        let t = to.easing.value(at: span > 0 ? (time - Double(from.time)) / span : 1)
        return (CGPoint(x: from.center.x + (to.center.x - from.center.x) * t,
                        y: from.center.y + (to.center.y - from.center.y) * t),
                from.scale + (to.scale - from.scale) * t)
    }

    /// The largest output-shaped area of an image of `imageSize`,
    /// normalised: one side is 1.
    private static func fillSize(imageSize: CGSize, renderSize: CGSize) -> CGSize {
        let output = renderSize.width / renderSize.height
        let image = imageSize.width / imageSize.height
        return image > output ? CGSize(width: output / image, height: 1)
                              : CGSize(width: 1, height: image / output)
    }

    /// The scale at which the whole image fits the output, with bars on
    /// two sides: at most 1. Smaller scales are shown at this one.
    public static func fitScale(imageSize: CGSize, renderSize: CGSize) -> Double {
        guard imageSize.width > 0, imageSize.height > 0,
              renderSize.width > 0, renderSize.height > 0 else { return 1 }
        let fill = fillSize(imageSize: imageSize, renderSize: renderSize)
        return Double(min(fill.width, fill.height))
    }

    /// The part of an image of `imageSize` that a camera at `center`
    /// (normalised, top-left origin) and `scale` shows in an output of
    /// `renderSize`, normalised with a top-left origin. At scale 1 it is the
    /// largest output-shaped area, centred on `center`; it never leaves the
    /// image. Below 1, down to `fitScale`, it is larger than the image on
    /// one side, centred there, and the output shows bars.
    public static func viewRect(center: CGPoint, scale: Double, imageSize: CGSize,
                                renderSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              renderSize.width > 0, renderSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let fill = fillSize(imageSize: imageSize, renderSize: renderSize)
        let zoom = CGFloat(max(scale, fitScale(imageSize: imageSize, renderSize: renderSize)))
        let size = CGSize(width: fill.width / zoom, height: fill.height / zoom)
        func origin(_ centre: CGFloat, _ length: CGFloat) -> CGFloat {
            length >= 1 ? (1 - length) / 2 : min(max(centre - length / 2, 0), 1 - length)
        }
        return CGRect(x: origin(center.x, size.width), y: origin(center.y, size.height),
                      width: size.width, height: size.height)
    }

    /// `image` as the camera sees it at `time`, filling `renderSize`.
    public static func render(_ image: CIImage, zoom: [ZoomKeyframe], at time: Double,
                              renderSize: CGSize) -> CIImage {
        let extent = image.extent
        let camera = camera(zoom, at: time)
        let view = viewRect(center: camera.center, scale: camera.scale,
                            imageSize: extent.size, renderSize: renderSize)
        // Core Image's origin is bottom-left.
        let crop = CGRect(x: extent.minX + view.minX * extent.width,
                          y: extent.minY + (1 - view.maxY) * extent.height,
                          width: view.width * extent.width,
                          height: view.height * extent.height)
        let canvas = CGRect(origin: .zero, size: renderSize)
        guard crop.width > 0, crop.height > 0 else { return FrameRenderer.black(renderSize: renderSize) }
        let scaled = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: renderSize.width / crop.width,
                                               y: renderSize.height / crop.height))
        return scaled
            .composited(over: CIImage(color: .black).cropped(to: canvas))
            .cropped(to: canvas)
    }
}
