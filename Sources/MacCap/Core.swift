import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Capture options

enum CaptureMode: Equatable {
    case screen, selection, window
}

struct CaptureOptions: Equatable {
    var mode: CaptureMode
    var delay = 0
    var cursor = false
    var windowShadow = true
    var sound = false

    /// Arguments for `/usr/sbin/screencapture`.
    func arguments(output: String) -> [String] {
        var result: [String] = []
        if !sound { result.append("-x") }
        switch mode {
        case .screen:
            result.append("-m")
        case .selection:
            result += ["-i", "-s"]
        case .window:
            result += ["-i", "-w"]
            if !windowShadow { result.append("-o") }
        }
        if delay > 0 { result += ["-T", String(delay)] }
        if cursor, mode == .screen { result.append("-C") }
        result.append(output)
        return result
    }
}

// MARK: - File names

enum CaptureNaming {
    static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "Captura %04d-%02d-%02d a las %02d.%02d.%02d.png",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Returns `directory/name`, adding " (2)", " (3)"… before the extension if the file exists.
    static func uniqueURL(in directory: URL, name: String,
                          exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while exists(candidate) {
            let numbered = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            index += 1
        }
        return candidate
    }
}

// MARK: - Annotation model

enum AnnotationTool: String, CaseIterable {
    case rectangle, ellipse, arrow, line, pen, highlighter, text, counter, pixelate

    var title: String {
        switch self {
        case .rectangle: return "Rectángulo"
        case .ellipse: return "Elipse"
        case .arrow: return "Flecha"
        case .line: return "Línea"
        case .pen: return "Lápiz"
        case .highlighter: return "Resaltador"
        case .text: return "Texto"
        case .counter: return "Número"
        case .pixelate: return "Pixelar"
        }
    }

    /// Single-key shortcut inside the editor.
    var key: Character {
        switch self {
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .arrow: return "a"
        case .line: return "l"
        case .pen: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .counter: return "n"
        case .pixelate: return "b"
        }
    }

    var isFreehand: Bool { self == .pen || self == .highlighter }
    var isBoxed: Bool { self == .rectangle || self == .ellipse || self == .pixelate }
    var isLinear: Bool { self == .arrow || self == .line }
}

struct RGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double = 1
}

enum StrokeSize: Int, CaseIterable {
    case small, medium, large

    var title: String {
        switch self {
        case .small: return "Fino"
        case .medium: return "Medio"
        case .large: return "Grueso"
        }
    }

    /// Stroke width in points.
    var lineWidth: CGFloat {
        switch self {
        case .small: return 2
        case .medium: return 4
        case .large: return 8
        }
    }

    /// Font size in points for the text tool.
    var fontSize: CGFloat {
        switch self {
        case .small: return 16
        case .medium: return 24
        case .large: return 38
        }
    }

    /// Circle radius in points for the counter tool.
    var counterRadius: CGFloat {
        switch self {
        case .small: return 11
        case .medium: return 15
        case .large: return 22
        }
    }
}

/// One annotation. All coordinates and sizes are in image pixels, origin at the top-left corner.
struct Annotation: Equatable {
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: RGBA
    var lineWidth: CGFloat
    var fontSize: CGFloat = 0
    var text = ""
    var number = 0
}

enum AnnotationGeometry {
    /// The largest rectangle with the image's aspect ratio centred in `bounds`.
    static func imageRect(image: CGSize, in bounds: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Converts a point in view coordinates to image pixels, clamped to the image.
    static func imagePoint(_ point: CGPoint, imageRect: CGRect, imageSize: CGSize) -> CGPoint {
        guard imageRect.width > 0, imageRect.height > 0 else { return .zero }
        let x = (point.x - imageRect.minX) / imageRect.width * imageSize.width
        let y = (point.y - imageRect.minY) / imageRect.height * imageSize.height
        return CGPoint(x: min(max(x, 0), imageSize.width), y: min(max(y, 0), imageSize.height))
    }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Shift-constrained end point: squares for boxed tools, 45° steps for lines.
    static func constrain(start: CGPoint, end: CGPoint, tool: AnnotationTool) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        if tool.isBoxed {
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
        if tool.isLinear {
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { return end }
            let step = Double.pi / 4
            let angle = (atan2(Double(dy), Double(dx)) / step).rounded() * step
            return CGPoint(x: start.x + length * CGFloat(cos(angle)), y: start.y + length * CGFloat(sin(angle)))
        }
        return end
    }

    /// Whether a finished annotation is big enough to keep (avoids accidental clicks).
    static func isMeaningful(_ annotation: Annotation, minimum: CGFloat = 3) -> Bool {
        switch annotation.tool {
        case .text: return !annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .counter: return !annotation.points.isEmpty
        case .pen, .highlighter: return annotation.points.count > 1
        case .arrow, .line:
            guard annotation.points.count == 2 else { return false }
            let dx = annotation.points[1].x - annotation.points[0].x
            let dy = annotation.points[1].y - annotation.points[0].y
            return (dx * dx + dy * dy).squareRoot() >= minimum
        case .rectangle, .ellipse, .pixelate:
            guard annotation.points.count == 2 else { return false }
            let r = rect(from: annotation.points[0], to: annotation.points[1])
            return r.width >= minimum && r.height >= minimum
        }
    }

    /// The three corners of an arrow head whose tip is at `end`.
    static func arrowHead(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat) -> [CGPoint] {
        let angle = atan2(Double(end.y - start.y), Double(end.x - start.x))
        let length = Double(max(lineWidth * 4, 12))
        let spread = Double.pi / 7
        let left = CGPoint(x: end.x - CGFloat(length * cos(angle - spread)),
                           y: end.y - CGFloat(length * sin(angle - spread)))
        let right = CGPoint(x: end.x - CGFloat(length * cos(angle + spread)),
                            y: end.y - CGFloat(length * sin(angle + spread)))
        return [end, left, right]
    }

    /// Next number for the counter tool.
    static func nextCounter(in annotations: [Annotation]) -> Int {
        (annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
    }

    /// Pixel block size for the pixelate tool.
    static func pixelateBlock(for imageSize: CGSize) -> CGFloat {
        max(8, (max(imageSize.width, imageSize.height) / 90).rounded())
    }
}

/// Undo/redo history for a list of annotations.
struct AnnotationHistory {
    private(set) var items: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func add(_ annotation: Annotation) {
        apply(items + [annotation])
    }

    mutating func clear() {
        guard !items.isEmpty else { return }
        apply([])
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(items)
        items = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
    }

    private mutating func apply(_ newItems: [Annotation]) {
        undoStack.append(items)
        redoStack.removeAll()
        items = newItems
    }
}
