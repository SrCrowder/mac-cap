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

// MARK: - Image formats

enum ImageFormat: String, CaseIterable {
    case png, jpeg, heic

    var title: String {
        switch self {
        case .png: return "PNG (sin pérdida)"
        case .jpeg: return "JPG (más ligero)"
        case .heic: return "HEIC (el más ligero)"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }

    /// Uniform Type Identifier.
    var typeIdentifier: String {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        }
    }
}

// MARK: - File names

enum CaptureNaming {
    static func fileName(for date: Date, extension ext: String = "png", prefix: String = "Captura",
                         calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%@ %04d-%02d-%02d a las %02d.%02d.%02d.%@", prefix,
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ext)
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
    case select, rectangle, ellipse, arrow, line, pen, highlighter, text, counter, pixelate, blur, crop

    var title: String {
        switch self {
        case .select: return "Seleccionar y mover"
        case .blur: return "Difuminar (oculta como el pixelado)"
        case .crop: return "Recortar"

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
        case .select: return "v"
        case .blur: return "d"
        case .crop: return "c"

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
    var isBoxed: Bool { [.rectangle, .ellipse, .pixelate, .blur, .crop].contains(self) }
    /// Tools whose annotation is defined by two points that can be dragged to resize.
    var hasEndpoints: Bool { isBoxed || isLinear }
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
        case .select: return false
        case .rectangle, .ellipse, .pixelate, .blur, .crop:
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

    static func translated(_ annotation: Annotation, by delta: CGPoint) -> Annotation {
        var moved = annotation
        moved.points = annotation.points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        return moved
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Bounding box in image pixels. `textSize` measures text annotations (needs fonts).
    static func bounds(of a: Annotation, textSize: (Annotation) -> CGSize) -> CGRect {
        guard let first = a.points.first else { return .null }
        switch a.tool {
        case .text:
            return CGRect(origin: first, size: textSize(a))
        case .counter:
            return CGRect(x: first.x - a.fontSize, y: first.y - a.fontSize, width: a.fontSize * 2, height: a.fontSize * 2)
        default:
            let xs = a.points.map(\.x), ys = a.points.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            let pad = a.tool == .highlighter ? a.lineWidth * 2 : a.lineWidth / 2
            return box.insetBy(dx: -pad, dy: -pad)
        }
    }

    /// Whether `point` (image pixels) touches the annotation, with `tolerance` pixels of slack.
    static func hitTest(_ a: Annotation, at point: CGPoint, tolerance: CGFloat,
                        textSize: (Annotation) -> CGSize) -> Bool {
        switch a.tool {
        case .line, .arrow, .pen, .highlighter:
            guard let first = a.points.first else { return false }
            let reach = tolerance + (a.tool == .highlighter ? a.lineWidth * 2 : a.lineWidth / 2)
            if a.points.count == 1 { return hypot(point.x - first.x, point.y - first.y) <= reach }
            return zip(a.points, a.points.dropFirst()).contains { distance(from: point, toSegment: $0, $1) <= reach }
        default:
            return bounds(of: a, textSize: textSize).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    /// Index of the topmost annotation under `point`.
    static func topmost(in annotations: [Annotation], at point: CGPoint, tolerance: CGFloat,
                        textSize: (Annotation) -> CGSize) -> Int? {
        annotations.indices.reversed().first {
            hitTest(annotations[$0], at: point, tolerance: tolerance, textSize: textSize)
        }
    }

    /// Pixel block size for the pixelate tool: well above normal text height (≈13 pt) so each block
    /// mixes several glyphs and the text cannot be reconstructed from the averages.
    static func pixelateBlock(for imageSize: CGSize, scale: CGFloat) -> CGFloat {
        max(22 * scale, (max(imageSize.width, imageSize.height) / 70).rounded())
    }
}

/// Everything the user can undo in the editor.
struct EditorState: Equatable {
    var items: [Annotation] = []
    /// Visible part of the image, in image pixels; `nil` = whole image.
    var crop: CGRect?
}

/// Undo/redo history of the editor state.
struct AnnotationHistory {
    private(set) var state = EditorState()
    private var undoStack: [EditorState] = []
    private var redoStack: [EditorState] = []

    var items: [Annotation] { state.items }
    var crop: CGRect? { state.crop }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func add(_ annotation: Annotation) {
        var next = state
        next.items.append(annotation)
        apply(next)
    }

    mutating func replace(at index: Int, with annotation: Annotation) {
        guard state.items.indices.contains(index), state.items[index] != annotation else { return }
        var next = state
        next.items[index] = annotation
        apply(next)
    }

    mutating func remove(at index: Int) {
        guard state.items.indices.contains(index) else { return }
        var next = state
        next.items.remove(at: index)
        apply(next)
    }

    mutating func setCrop(_ crop: CGRect?) {
        guard crop != state.crop else { return }
        var next = state
        next.crop = crop
        apply(next)
    }

    /// Removes every annotation (the crop is kept).
    mutating func clear() {
        guard !state.items.isEmpty else { return }
        apply(EditorState(items: [], crop: state.crop))
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
    }

    private mutating func apply(_ next: EditorState) {
        undoStack.append(state)
        redoStack.removeAll()
        state = next
    }
}

// MARK: - Background for sharing

/// Optional gradient frame around the exported image (padding, rounded corners and shadow).
enum ShareBackground: Int, CaseIterable {
    case none, ocean, sunset, forest, candy, graphite, light

    var title: String {
        switch self {
        case .none: return "Sin fondo"
        case .ocean: return "Océano"
        case .sunset: return "Atardecer"
        case .forest: return "Bosque"
        case .candy: return "Caramelo"
        case .graphite: return "Grafito"
        case .light: return "Claro"
        }
    }

    /// Gradient start and end colours.
    var colors: (RGBA, RGBA)? {
        switch self {
        case .none: return nil
        case .ocean: return (RGBA(r: 0.24, g: 0.55, b: 1), RGBA(r: 0.45, g: 0.25, b: 0.9))
        case .sunset: return (RGBA(r: 1, g: 0.55, b: 0.3), RGBA(r: 0.93, g: 0.25, b: 0.5))
        case .forest: return (RGBA(r: 0.2, g: 0.7, b: 0.5), RGBA(r: 0.1, g: 0.4, b: 0.45))
        case .candy: return (RGBA(r: 1, g: 0.6, b: 0.8), RGBA(r: 0.6, g: 0.7, b: 1))
        case .graphite: return (RGBA(r: 0.3, g: 0.32, b: 0.36), RGBA(r: 0.12, g: 0.13, b: 0.15))
        case .light: return (RGBA(r: 0.96, g: 0.96, b: 0.97), RGBA(r: 0.86, g: 0.87, b: 0.9))
        }
    }

    /// Final canvas size and where the image goes inside it, for an image of `content` pixels.
    func layout(content: CGSize) -> (size: CGSize, contentOrigin: CGPoint) {
        guard self != .none else { return (content, .zero) }
        let padding = max(24, (max(content.width, content.height) * 0.07).rounded())
        return (CGSize(width: content.width + padding * 2, height: content.height + padding * 2),
                CGPoint(x: padding, y: padding))
    }
}

// MARK: - Keyboard shortcuts

/// Actions that can have a global keyboard shortcut.
enum ShortcutAction: String, CaseIterable, Codable {
    case annotateZone, copyZone, saveZone, ocr, qr, pinZone, copyWindow, copyScreen,
         colorPicker, recordVideo, recordGIF, scrollCapture, ruler

    var title: String {
        switch self {
        case .annotateZone: return "Capturar zona y anotar"
        case .copyZone: return "Capturar zona y copiar"
        case .saveZone: return "Capturar zona y guardar"
        case .ocr: return "Copiar texto de una zona (OCR)"
        case .qr: return "Leer código QR"
        case .pinZone: return "Fijar zona en pantalla"
        case .copyWindow: return "Capturar ventana y copiar"
        case .copyScreen: return "Capturar pantalla completa y copiar"
        case .colorPicker: return "Cuentagotas"
        case .recordVideo: return "Grabar zona en vídeo"
        case .recordGIF: return "Grabar zona como GIF"
        case .scrollCapture: return "Captura con scroll"
        case .ruler: return "Regla"
        }
    }
}

struct Shortcut: Codable, Equatable, Hashable {
    /// Virtual key code (kVK_*).
    var keyCode: Int
    var command = false
    var shift = false
    var option = false
    var control = false
    /// Label of the key, e.g. "7" or "F5".
    var key: String

    var displayString: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased()
    }

    /// Global shortcuts need ⌘, ⌥ or ⌃ (or a function key) so normal typing isn't swallowed.
    var isValidGlobal: Bool { command || option || control || Shortcut.functionKeys[keyCode] != nil }

    /// Function keys and other keys without a printable character.
    static let functionKeys: [Int: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15"
    ]
    static let namedKeys: [Int: String] = [
        49: "Espacio", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Inicio", 119: "Fin", 116: "RePág", 121: "AvPág"
    ]
}

/// Default shortcuts plus the user's changes. `overrides` maps an action to its shortcut,
/// or to `nil` when the user removed it.
enum ShortcutMap {
    static let defaults: [ShortcutAction: Shortcut] = [
        .annotateZone: Shortcut(keyCode: 26, command: true, shift: true, key: "7"),
        .copyZone: Shortcut(keyCode: 28, command: true, shift: true, key: "8"),
        .ocr: Shortcut(keyCode: 25, command: true, shift: true, key: "9")
    ]

    static func resolve(_ overrides: [ShortcutAction: Shortcut?]) -> [ShortcutAction: Shortcut] {
        var result = defaults
        for (action, shortcut) in overrides { result[action] = shortcut }
        return result
    }

    /// Assigns `shortcut` to `action`, removing it from any other action that used it.
    static func assign(_ shortcut: Shortcut?, to action: ShortcutAction,
                       in overrides: [ShortcutAction: Shortcut?]) -> [ShortcutAction: Shortcut?] {
        var updated = overrides
        if let shortcut = shortcut {
            for (other, existing) in resolve(overrides) where other != action && existing == shortcut {
                updated[other] = .some(nil)
            }
        }
        updated[action] = .some(shortcut)
        return updated
    }
}
