#if canImport(CoreGraphics)
import CoreGraphics
import Foundation

/// Joins screenshots of a region taken while the user scrolls down into one tall image.
/// Each new frame is compared with the previous one to find how many pixel rows it moved.
final class ScrollStitcher {
    enum AddResult: Equatable {
        case first
        case appended(rows: Int)
        case unchanged
        /// The frame could not be matched (scrolled too fast, or the content changed).
        case lost
    }

    static let columns = 64
    private(set) var frames: [(image: CGImage, y: Int)] = []
    private var lastGrid: [Float]?

    /// Height in pixels of the stitched result so far.
    var height: Int { (frames.last?.y ?? 0) + (frames.first?.image.height ?? 0) }

    func add(_ image: CGImage) -> AddResult {
        guard let grid = Self.grid(image) else { return .lost }
        guard let previous = lastGrid, let last = frames.last else {
            frames.append((image, 0))
            lastGrid = grid
            return .first
        }
        guard image.width == last.image.width, image.height == last.image.height else { return .lost }
        guard let rows = Self.offset(previous: previous, current: grid, rows: image.height) else { return .lost }
        if rows == 0 { return .unchanged }
        frames.append((image, last.y + rows))
        lastGrid = grid
        return .appended(rows: rows)
    }

    /// Luminance of each row, sampled at `columns` points (row 0 = top of the image).
    static func grid(_ image: CGImage) -> [Float]? {
        let rows = image.height
        guard rows > 0, let context = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8,
                                                bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(),
                                                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: columns * rows)
        return (0..<(columns * rows)).map { Float(bytes[$0]) }
    }

    /// Rows that `current` moved up with respect to `previous` (the user scrolled down), or `nil`
    /// when no shift matches well enough.
    static func offset(previous: [Float], current: [Float], rows: Int, threshold: Float = 6) -> Int? {
        let minOverlap = max(16, rows / 8)
        guard rows > minOverlap, previous.count == rows * columns, current.count == rows * columns else { return nil }
        var bestShift = -1
        var bestCost = Float.greatestFiniteMagnitude
        for shift in 0...(rows - minOverlap) {
            let overlap = rows - shift
            let step = max(1, overlap / 160)
            var total: Float = 0
            var samples = 0
            var row = 0
            while row < overlap {
                let a = (shift + row) * columns, b = row * columns
                for column in 0..<columns { total += abs(previous[a + column] - current[b + column]) }
                samples += columns
                row += step
                if total / Float(samples) > bestCost * 2 + threshold { break } // clearly worse, stop early
            }
            let cost = total / Float(max(samples, 1))
            if cost < bestCost {
                bestCost = cost
                bestShift = shift
            }
        }
        return bestCost <= threshold ? bestShift : nil
    }

    /// The stitched image, at most `maxHeight` pixels tall.
    func compose(maxHeight: Int = 30_000) -> CGImage? {
        guard let first = frames.first?.image else { return nil }
        let width = first.width
        let total = min(height, maxHeight)
        guard let context = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        for frame in frames where frame.y < total {
            // Core Graphics has its origin at the bottom-left.
            context.draw(frame.image, in: CGRect(x: 0, y: total - frame.y - frame.image.height,
                                                 width: width, height: frame.image.height))
        }
        return context.makeImage()
    }
}
#endif
