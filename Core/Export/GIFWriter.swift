import CoreGraphics
import Foundation

/// Writes an animated GIF one frame at a time, so memory stays at a few
/// frames however long the video is.
///
/// Each frame gets its own palette of up to 255 colours (median cut over a
/// 5-bit-per-channel histogram, no dithering). Pixels that look the same as
/// what is already on screen are left transparent, and only the box around
/// the rest is stored, which is what keeps talking-head GIFs small.
final class GIFWriter {
    let width: Int
    let height: Int
    private let sink: Sink
    /// What is on screen after the frames so far, as 15-bit colours;
    /// `nil` before the first frame.
    private var shown: [UInt16]?
    /// The RGBA bitmap frames are drawn into.
    private let context: CGContext

    /// Where bytes go: a file, or nowhere but a count (for estimates).
    enum Sink {
        case file(FileHandle)
        case count

        var handle: FileHandle? { if case .file(let handle) = self { handle } else { nil } }
    }

    /// Bytes written so far.
    private(set) var byteCount = 0
    private var buffer = Data()

    /// - Parameter loops: Plays forever when `true`; once when `false`
    ///   (no NETSCAPE2.0 block).
    init(width: Int, height: Int, loops: Bool, sink: Sink) throws {
        guard width > 0, height > 0, width < 65536, height < 65536,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        context.interpolationQuality = .high
        self.width = width
        self.height = height
        self.sink = sink
        self.context = context
        append(Array("GIF89a".utf8))
        append16(width)
        append16(height)
        append([0x00, 0x00, 0x00])           // no global colour table
        if loops {
            append([0x21, 0xFF, 0x0B])
            append(Array("NETSCAPE2.0".utf8))
            append([0x03, 0x01, 0x00, 0x00, 0x00])  // loop count 0: forever
        }
        try flush()
    }

    /// Adds `image`, scaled to the GIF's size, shown for `delay` hundredths
    /// of a second.
    func add(_ image: CGImage, delay: Int) throws {
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw CocoaError(.fileWriteUnknown) }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let count = width * height
        var keys = [UInt16](repeating: 0, count: count)
        for i in 0..<count {
            keys[i] = UInt16(pixels[i * 4] >> 3) << 10 | UInt16(pixels[i * 4 + 1] >> 3) << 5
                | UInt16(pixels[i * 4 + 2] >> 3)
        }
        try add(keys: keys, pixels: pixels, delay: delay)
    }

    /// Ends the file.
    func finish() throws {
        append([0x3B])
        try flush()
    }

    // MARK: Frames

    private func add(keys: [UInt16], pixels: UnsafePointer<UInt8>, delay: Int) throws {
        // Which pixels changed from what is on screen, and the box around them.
        var changed = [Bool](repeating: true, count: keys.count)
        var box = (minX: 0, minY: 0, maxX: width - 1, maxY: height - 1)
        if let shown {
            box = (width, height, -1, -1)
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    if Self.close(keys[i], shown[i]) {
                        changed[i] = false
                    } else {
                        box.minX = min(box.minX, x)
                        box.maxX = max(box.maxX, x)
                        box.minY = min(box.minY, y)
                        box.maxY = max(box.maxY, y)
                    }
                }
            }
            // Nothing changed: one transparent pixel holds the delay.
            if box.maxX < 0 { box = (0, 0, 0, 0) }
        }

        var histogram = [UInt32](repeating: 0, count: 32768)
        for y in box.minY...box.maxY {
            for x in box.minX...box.maxX where changed[y * width + x] {
                histogram[Int(keys[y * width + x])] += 1
            }
        }
        let palette = Self.palette(histogram, size: 255)
        var lookup = [UInt8](repeating: 0, count: 32768)
        for key in 0..<32768 where histogram[key] > 0 {
            lookup[key] = UInt8(Self.nearest(UInt16(key), in: palette))
        }
        let transparent = UInt8(palette.count)

        let boxWidth = box.maxX - box.minX + 1, boxHeight = box.maxY - box.minY + 1
        var indices = [UInt8](repeating: transparent, count: boxWidth * boxHeight)
        var next = shown ?? keys
        for y in box.minY...box.maxY {
            for x in box.minX...box.maxX {
                let i = y * width + x
                guard changed[i] else { continue }
                let index = lookup[Int(keys[i])]
                indices[(y - box.minY) * boxWidth + x - box.minX] = index
                next[i] = palette[Int(index)]
            }
        }
        shown = next

        // Graphic control: keep the previous frame (disposal 1), transparent index.
        append([0x21, 0xF9, 0x04, 0x05])
        append16(max(delay, 0))
        append([transparent, 0x00])
        // Image descriptor with a local colour table just big enough for the
        // palette and the transparent entry.
        var bits = 1
        while 1 << bits < palette.count + 1 { bits += 1 }
        append([0x2C])
        append16(box.minX)
        append16(box.minY)
        append16(boxWidth)
        append16(boxHeight)
        append([0x80 | UInt8(bits - 1)])
        for entry in 0..<(1 << bits) {
            if entry < palette.count {
                let key = palette[entry]
                append([Self.expand(key >> 10), Self.expand(key >> 5), Self.expand(key)])
            } else {
                append([0, 0, 0])
            }
        }
        let minimumCodeSize = max(bits, 2)
        append([UInt8(minimumCodeSize)])
        var blocks = LZW.encode(indices, minimumCodeSize: minimumCodeSize)
        while !blocks.isEmpty {
            let length = min(255, blocks.count)
            append([UInt8(length)])
            append(Array(blocks.prefix(length)))
            blocks.removeFirst(length)
        }
        append([0x00])
        try flush()
    }

    /// Two 15-bit colours no more than one 5-bit step apart in each channel.
    private static func close(_ a: UInt16, _ b: UInt16) -> Bool {
        func channel(_ value: UInt16, _ shift: UInt16) -> Int { Int((value >> shift) & 31) }
        return abs(channel(a, 10) - channel(b, 10)) <= 1
            && abs(channel(a, 5) - channel(b, 5)) <= 1
            && abs(channel(a, 0) - channel(b, 0)) <= 1
    }

    /// A 5-bit channel of `key` as 8 bits.
    private static func expand(_ key: UInt16) -> UInt8 {
        let value = UInt8(key & 31)
        return value << 3 | value >> 2
    }

    // MARK: Palette

    /// Up to `size` 15-bit colours by median cut: the box with the most
    /// pixels splits at the median of its widest channel, until there are
    /// `size` boxes or none can split; each box gives its weighted mean.
    static func palette(_ histogram: [UInt32], size: Int) -> [UInt16] {
        var colours: [(key: UInt16, count: UInt32)] = []
        for key in 0..<histogram.count where histogram[key] > 0 {
            colours.append((UInt16(key), histogram[key]))
        }
        guard !colours.isEmpty else { return [0] }
        if colours.count <= size { return colours.map(\.key) }

        func channel(_ key: UInt16, _ c: Int) -> Int { Int(key >> UInt16(10 - c * 5)) & 31 }
        func total(_ box: ArraySlice<(key: UInt16, count: UInt32)>) -> UInt64 {
            box.reduce(0) { $0 + UInt64($1.count) }
        }
        var boxes: [ArraySlice<(key: UInt16, count: UInt32)>] = [colours[...]]
        var totals = [total(colours[...])]
        while boxes.count < size {
            guard let index = boxes.indices.filter({ boxes[$0].count > 1 })
                .max(by: { totals[$0] < totals[$1] })
            else { break }
            let box = boxes[index]
            let widest = (0..<3).max { a, b in
                let ra = box.map { channel($0.key, a) }, rb = box.map { channel($0.key, b) }
                return ra.max()! - ra.min()! < rb.max()! - rb.min()!
            }!
            let sorted = box.sorted { channel($0.key, widest) < channel($1.key, widest) }
            let pixels = totals[index]
            var running: UInt64 = 0
            var cut = 1
            for (offset, colour) in sorted.enumerated() {
                running += UInt64(colour.count)
                if running * 2 >= pixels { cut = max(1, min(offset + 1, sorted.count - 1)); break }
            }
            boxes[index] = sorted[0..<cut]
            boxes.append(sorted[cut...])
            totals[index] = total(boxes[index])
            totals.append(total(boxes[boxes.count - 1]))
        }
        return boxes.map { box in
            var sums = [UInt64](repeating: 0, count: 3)
            var total: UInt64 = 0
            for colour in box {
                for c in 0..<3 { sums[c] += UInt64(channel(colour.key, c)) * UInt64(colour.count) }
                total += UInt64(colour.count)
            }
            let mean = sums.map { UInt16(($0 + total / 2) / total) }
            return mean[0] << 10 | mean[1] << 5 | mean[2]
        }
    }

    private static func nearest(_ key: UInt16, in palette: [UInt16]) -> Int {
        func channel(_ value: UInt16, _ shift: UInt16) -> Int { Int((value >> shift) & 31) }
        var best = 0, bestDistance = Int.max
        for (index, entry) in palette.enumerated() {
            let r = channel(key, 10) - channel(entry, 10)
            let g = channel(key, 5) - channel(entry, 5)
            let b = channel(key, 0) - channel(entry, 0)
            let distance = 2 * r * r + 4 * g * g + b * b
            if distance < bestDistance {
                best = index
                bestDistance = distance
                if distance == 0 { break }
            }
        }
        return best
    }

    // MARK: Output

    private func append(_ bytes: [UInt8]) { buffer.append(contentsOf: bytes) }

    private func append16(_ value: Int) { append([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }

    private func flush() throws {
        byteCount += buffer.count
        if let handle = sink.handle { try handle.write(contentsOf: buffer) }
        buffer.removeAll(keepingCapacity: true)
    }
}

/// GIF's variable-length LZW. Indices must be below `1 << minimumCodeSize`
/// (2...8).
enum LZW {
    static func encode(_ indices: [UInt8], minimumCodeSize: Int = 8) -> [UInt8] {
        let clear = 1 << minimumCodeSize, end = clear + 1
        var output: [UInt8] = []
        output.reserveCapacity(indices.count / 2)
        var bitBuffer = 0, bitCount = 0
        var codeSize = minimumCodeSize + 1
        var nextCode = clear + 2
        // (prefix << 8 | byte) -> code, valid when its generation matches.
        var table = [Int32](repeating: 0, count: 4096 * 256)
        var generation = [UInt16](repeating: 0, count: 4096 * 256)
        var current: UInt16 = 1

        func emit(_ code: Int) {
            bitBuffer |= code << bitCount
            bitCount += codeSize
            while bitCount >= 8 {
                output.append(UInt8(bitBuffer & 0xFF))
                bitBuffer >>= 8
                bitCount -= 8
            }
        }

        emit(clear)
        guard var prefix = indices.first.map(Int.init) else {
            emit(end)
            if bitCount > 0 { output.append(UInt8(bitBuffer & 0xFF)) }
            return output
        }
        for byte in indices.dropFirst() {
            let key = prefix << 8 | Int(byte)
            if generation[key] == current {
                prefix = Int(table[key])
                continue
            }
            emit(prefix)
            if nextCode < 4096 {
                table[key] = Int32(nextCode)
                generation[key] = current
                // The decoder widens a code later than the encoder adds it.
                if nextCode == 1 << codeSize, codeSize < 12 { codeSize += 1 }
                nextCode += 1
            } else {
                emit(clear)
                current &+= 1
                if current == 0 {
                    generation = [UInt16](repeating: 0, count: generation.count)
                    current = 1
                }
                codeSize = minimumCodeSize + 1
                nextCode = clear + 2
            }
            prefix = Int(byte)
        }
        emit(prefix)
        emit(end)
        if bitCount > 0 { output.append(UInt8(bitBuffer & 0xFF)) }
        return output
    }
}
