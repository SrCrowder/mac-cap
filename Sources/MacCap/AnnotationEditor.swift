#if os(macOS)
import AppKit
import CoreImage

// MARK: - Image document

/// The captured image plus the data needed to draw and export it.
final class AnnotationImage {
    let image: NSImage
    let pixelSize: CGSize
    /// Pixels per point (2 for Retina captures).
    let scale: CGFloat
    private(set) lazy var pixelated: NSImage? = makePixelated()

    init?(bitmap: NSBitmapImageRep) {
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0, let cgImage = bitmap.cgImage else { return nil }
        pixelSize = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        let pointWidth = bitmap.size.width > 0 ? bitmap.size.width : pixelSize.width
        scale = min(max(pixelSize.width / pointWidth, 1), 3)
        image = NSImage(cgImage: cgImage, size: pixelSize)
    }

    convenience init?(data: Data) {
        guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
        self.init(bitmap: bitmap)
    }

    convenience init?(image: NSImage) {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        self.init(bitmap: bitmap)
    }

    private func makePixelated() -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let filter = CIFilter(name: "CIPixellate") else { return nil }
        let input = CIImage(cgImage: cgImage)
        let block = AnnotationGeometry.pixelateBlock(for: pixelSize, scale: scale)
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(block, forKey: kCIInputScaleKey)
        // Random grid offset so the block layout can't be predicted by de-pixelation tools.
        filter.setValue(CIVector(x: CGFloat.random(in: 0..<block), y: CGFloat.random(in: 0..<block)),
                        forKey: kCIInputCenterKey)
        guard var output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        // Light per-pixel noise on top of the blocks.
        if let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?
            .transformed(by: CGAffineTransform(translationX: CGFloat.random(in: 0..<1000), y: 0))
            .cropped(to: input.extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.12, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.12, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.12, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -0.06, y: -0.06, z: -0.06, w: 1)
            ]) {
            output = noise.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: output])
                .cropped(to: input.extent)
        }
        guard let result = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: result, size: pixelSize)
    }

    /// Draws the image and annotations. The current context must be flipped, 1 unit = 1 image pixel.
    func draw(_ annotations: [Annotation]) {
        image.draw(in: CGRect(origin: .zero, size: pixelSize), from: .zero, operation: .copy,
                   fraction: 1, respectFlipped: true, hints: nil)
        for annotation in annotations { draw(annotation) }
    }

    func draw(_ a: Annotation) {
        let color = NSColor(srgbRed: a.color.r, green: a.color.g, blue: a.color.b, alpha: a.color.a)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        switch a.tool {
        case .rectangle, .ellipse:
            guard a.points.count == 2 else { return }
            let rect = AnnotationGeometry.rect(from: a.points[0], to: a.points[1])
            let path = a.tool == .rectangle
                ? NSBezierPath(roundedRect: rect, xRadius: a.lineWidth, yRadius: a.lineWidth)
                : NSBezierPath(ovalIn: rect)
            path.lineWidth = a.lineWidth
            applyShadow()
            color.setStroke()
            path.stroke()
        case .line, .arrow:
            guard a.points.count == 2 else { return }
            let (start, end) = (a.points[0], a.points[1])
            applyShadow()
            color.set()
            let path = NSBezierPath()
            path.lineWidth = a.lineWidth
            path.lineCapStyle = .round
            path.move(to: start)
            if a.tool == .arrow {
                let head = AnnotationGeometry.arrowHead(from: start, to: end, lineWidth: a.lineWidth)
                // Stop the shaft inside the head so the tip stays sharp.
                let base = CGPoint(x: (head[1].x + head[2].x) / 2, y: (head[1].y + head[2].y) / 2)
                path.line(to: base)
                path.stroke()
                let tip = NSBezierPath()
                tip.move(to: head[0]); tip.line(to: head[1]); tip.line(to: head[2]); tip.close()
                tip.lineJoinStyle = .round
                tip.lineWidth = max(1, a.lineWidth / 2)
                tip.fill()
                tip.stroke()
            } else {
                path.line(to: end)
                path.stroke()
            }
        case .pen, .highlighter:
            guard let first = a.points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            for point in a.points.dropFirst() { path.line(to: point) }
            path.lineJoinStyle = .round
            if a.tool == .highlighter {
                path.lineWidth = a.lineWidth * 4
                path.lineCapStyle = .square
                NSGraphicsContext.current?.cgContext.setBlendMode(.multiply)
                color.withAlphaComponent(0.45).setStroke()
            } else {
                path.lineWidth = a.lineWidth
                path.lineCapStyle = .round
                color.setStroke()
            }
            path.stroke()
        case .text:
            guard let origin = a.points.first else { return }
            let shadow = NSShadow()
            shadow.shadowColor = isDark(a.color) ? NSColor.white.withAlphaComponent(0.85) : NSColor.black.withAlphaComponent(0.75)
            shadow.shadowBlurRadius = a.fontSize / 8
            shadow.shadowOffset = .zero
            NSAttributedString(string: a.text, attributes: [
                .font: NSFont.systemFont(ofSize: a.fontSize, weight: .bold),
                .foregroundColor: color,
                .shadow: shadow
            ]).draw(at: origin)
        case .counter:
            guard let center = a.points.first else { return }
            let radius = a.fontSize
            let circle = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                     width: radius * 2, height: radius * 2))
            applyShadow()
            color.setFill()
            circle.fill()
            NSShadow().set()
            NSColor.white.setStroke()
            circle.lineWidth = max(1, radius / 7)
            circle.stroke()
            let label = NSAttributedString(string: "\(a.number)", attributes: [
                .font: NSFont.systemFont(ofSize: radius * 1.15, weight: .heavy),
                .foregroundColor: isDark(a.color) ? NSColor.white : NSColor.black
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        case .pixelate:
            guard a.points.count == 2, let pixelated = pixelated else { return }
            let rect = AnnotationGeometry.rect(from: a.points[0], to: a.points[1])
            NSBezierPath(rect: rect).addClip()
            pixelated.draw(in: CGRect(origin: .zero, size: pixelSize), from: .zero, operation: .copy,
                           fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func applyShadow() {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -scale)
        shadow.set()
    }

    private func isDark(_ c: RGBA) -> Bool { 0.299 * c.r + 0.587 * c.g + 0.114 * c.b < 0.6 }

    /// PNG with the annotations burnt in, keeping the original resolution and DPI.
    func pngData(with annotations: [Annotation]) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixelSize.width),
                                            pixelsHigh: Int(pixelSize.height), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        let context = bitmapContext.cgContext
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(annotations)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - Canvas

final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    let document: AnnotationImage
    private(set) var history = AnnotationHistory()
    var tool: AnnotationTool = .rectangle {
        didSet { commitText(); window?.invalidateCursorRects(for: self); onStateChange?() }
    }
    var color = RGBA(r: 1, g: 0.18, b: 0.18)
    var size: StrokeSize = .medium
    var onStateChange: (() -> Void)?

    private var current: Annotation?
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero

    init(document: AnnotationImage) {
        self.document = document
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var imageRect: CGRect {
        // Never upscale beyond the image's natural size in points.
        let natural = CGSize(width: document.pixelSize.width / document.scale,
                             height: document.pixelSize.height / document.scale)
        let fitted = AnnotationGeometry.imageRect(image: document.pixelSize, in: bounds.insetBy(dx: 8, dy: 8))
        guard fitted.width > natural.width else { return fitted }
        return CGRect(x: bounds.midX - natural.width / 2, y: bounds.midY - natural.height / 2,
                      width: natural.width, height: natural.height).integral
    }

    /// View points per image pixel.
    private var viewScale: CGFloat { imageRect.width / max(document.pixelSize.width, 1) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        let rect = imageRect
        guard rect.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        let frameShadow = NSShadow()
        frameShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        frameShadow.shadowBlurRadius = 8
        frameShadow.set()
        NSColor.white.setFill()
        rect.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: viewScale)
        transform.concat()
        document.draw(history.items + (current.map { [$0] } ?? []))
        NSGraphicsContext.restoreGraphicsState()
    }

    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: tool == .text ? .iBeam : .crosshair)
    }

    override func setFrameSize(_ newSize: NSSize) {
        commitText()
        super.setFrameSize(newSize)
    }

    // MARK: Mouse

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        AnnotationGeometry.imagePoint(convert(event.locationInWindow, from: nil),
                                      imageRect: imageRect, imageSize: document.pixelSize)
    }

    private func newAnnotation(at point: CGPoint) -> Annotation {
        let s = document.scale
        switch tool {
        case .text:
            return Annotation(tool: tool, points: [point], color: color, lineWidth: 0, fontSize: size.fontSize * s)
        case .counter:
            return Annotation(tool: tool, points: [point], color: color, lineWidth: 0,
                              fontSize: size.counterRadius * s,
                              number: AnnotationGeometry.nextCounter(in: history.items))
        case .pen, .highlighter:
            return Annotation(tool: tool, points: [point], color: color, lineWidth: size.lineWidth * s)
        default:
            return Annotation(tool: tool, points: [point, point], color: color, lineWidth: size.lineWidth * s)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let hadText = textField != nil
        commitText()
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(viewPoint) else { return }
        let point = imagePoint(event)
        switch tool {
        case .text:
            if !hadText { beginText(at: point) }
        case .counter:
            history.add(newAnnotation(at: point))
            changed()
        default:
            current = newAnnotation(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var annotation = current else { return }
        let point = imagePoint(event)
        if annotation.tool.isFreehand {
            if let last = annotation.points.last, hypot(last.x - point.x, last.y - point.y) >= 1 {
                annotation.points.append(point)
            }
        } else {
            annotation.points[1] = event.modifierFlags.contains(.shift)
                ? AnnotationGeometry.constrain(start: annotation.points[0], end: point, tool: annotation.tool)
                : point
        }
        current = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let annotation = current else { return }
        current = nil
        if AnnotationGeometry.isMeaningful(annotation, minimum: 3 * document.scale) {
            history.add(annotation)
        }
        changed()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty || flags == .shift, let key = event.charactersIgnoringModifiers?.lowercased().first {
            if let match = AnnotationTool.allCases.first(where: { $0.key == key }) {
                tool = match
                return
            }
        }
        switch event.keyCode {
        case 51, 117: undo() // delete / forward delete
        case 53: // escape
            if current != nil { current = nil; needsDisplay = true } else { super.keyDown(with: event) }
        default: super.keyDown(with: event)
        }
    }

    // MARK: Text

    private func beginText(at point: CGPoint) {
        textOrigin = point
        let field = NSTextField(string: "")
        field.placeholderString = "Escribe y pulsa Intro"
        field.font = NSFont.systemFont(ofSize: max(11, size.fontSize * document.scale * viewScale), weight: .bold)
        field.textColor = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1)
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
        field.drawsBackground = true
        field.isBordered = true
        field.focusRingType = .none
        field.delegate = self
        field.sizeToFit()
        let rect = imageRect
        let origin = CGPoint(x: rect.minX + point.x * viewScale, y: rect.minY + point.y * viewScale)
        field.frame = CGRect(x: origin.x, y: origin.y, width: max(220, field.frame.width), height: field.frame.height)
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        let width = field.attributedStringValue.size().width + 24
        field.setFrameSize(NSSize(width: max(220, width), height: field.frame.height))
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            textField?.stringValue = ""
            commitText()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        var annotation = newAnnotation(at: textOrigin)
        annotation.tool = .text
        annotation.fontSize = size.fontSize * document.scale
        annotation.text = text
        if AnnotationGeometry.isMeaningful(annotation) {
            history.add(annotation)
        }
        changed()
    }

    // MARK: Actions

    func undo() { commitText(); history.undo(); changed() }
    func redo() { commitText(); history.redo(); changed() }
    func clear() { commitText(); history.clear(); changed() }

    func pngData() -> Data? {
        commitText()
        return document.pngData(with: history.items)
    }

    private func changed() {
        needsDisplay = true
        onStateChange?()
    }
}

// MARK: - Window

/// Window that routes the editor's menu shortcuts (⌘Z, ⌘C, ⌘S…) to its controller.
final class AnnotationWindow: NSWindow {
    weak var editor: AnnotationWindowController?

    @objc func undoAnnotation(_ sender: Any?) { editor?.canvas.undo() }
    @objc func redoAnnotation(_ sender: Any?) { editor?.canvas.redo() }
    @objc func saveAnnotation(_ sender: Any?) { editor?.saveResult() }
    @objc func copy(_ sender: Any?) { editor?.copyResult() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undoAnnotation(_:)): return editor?.canvas.history.canUndo ?? false
        case #selector(redoAnnotation(_:)): return editor?.canvas.history.canRedo ?? false
        default: return super.validateUserInterfaceItem(item)
        }
    }
}

final class AnnotationWindowController: NSWindowController, NSWindowDelegate {
    static let palette: [(String, RGBA)] = [
        ("Rojo", RGBA(r: 1, g: 0.18, b: 0.18)),
        ("Naranja", RGBA(r: 1, g: 0.58, b: 0)),
        ("Amarillo", RGBA(r: 1, g: 0.84, b: 0.04)),
        ("Verde", RGBA(r: 0.2, g: 0.78, b: 0.35)),
        ("Azul", RGBA(r: 0.04, g: 0.52, b: 1)),
        ("Morado", RGBA(r: 0.69, g: 0.32, b: 0.87)),
        ("Negro", RGBA(r: 0.1, g: 0.1, b: 0.1)),
        ("Blanco", RGBA(r: 1, g: 1, b: 1))
    ]

    var onClose: (() -> Void)?
    let canvas: AnnotationCanvas
    private let saveImage: (Data) -> Bool
    private let copyImage: (Data) -> Void
    private let toolControl = NSSegmentedControl()
    private let colorControl = NSSegmentedControl()
    private let sizeControl = NSSegmentedControl()
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var clearButton: NSButton!
    /// Annotations at the last copy/save, to know if there are unsaved changes.
    private var exported: [Annotation] = []
    private var hasUnexportedChanges: Bool { canvas.history.items != exported }

    init(document: AnnotationImage, save: @escaping (Data) -> Bool, copy: @escaping (Data) -> Void) {
        canvas = AnnotationCanvas(document: document)
        saveImage = save
        copyImage = copy

        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let natural = CGSize(width: document.pixelSize.width / document.scale + 40,
                             height: document.pixelSize.height / document.scale + 130)
        let size = CGSize(width: min(max(natural.width, 860), visible.width * 0.92),
                          height: min(max(natural.height, 480), visible.height * 0.92))
        let window = AnnotationWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                      backing: .buffered, defer: false)
        window.title = "Anotar captura"
        window.minSize = NSSize(width: 860, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.editor = self
        window.delegate = self
        buildInterface(in: window.contentView!)
        canvas.onStateChange = { [weak self] in self?.refreshControls() }
        refreshControls()
        window.initialFirstResponder = canvas
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildInterface(in content: NSView) {
        // Tools
        toolControl.segmentCount = AnnotationTool.allCases.count
        toolControl.trackingMode = .selectOne
        for (index, tool) in AnnotationTool.allCases.enumerated() {
            if let image = NSImage(systemSymbolName: Self.symbol(for: tool), accessibilityDescription: tool.title) {
                toolControl.setImage(image, forSegment: index)
                toolControl.setWidth(34, forSegment: index)
            } else {
                toolControl.setLabel(tool.title, forSegment: index)
            }
            toolControl.setToolTip("\(tool.title) (\(String(tool.key).uppercased()))", forSegment: index)
        }
        toolControl.target = self
        toolControl.action = #selector(toolChanged)

        // Colours
        colorControl.segmentCount = Self.palette.count
        colorControl.trackingMode = .selectOne
        for (index, entry) in Self.palette.enumerated() {
            colorControl.setImage(Self.swatch(entry.1), forSegment: index)
            colorControl.setWidth(26, forSegment: index)
            colorControl.setToolTip(entry.0, forSegment: index)
        }
        colorControl.selectedSegment = 0
        colorControl.target = self
        colorControl.action = #selector(colorChanged)

        // Sizes
        sizeControl.segmentCount = StrokeSize.allCases.count
        sizeControl.trackingMode = .selectOne
        for size in StrokeSize.allCases { sizeControl.setLabel(size.title, forSegment: size.rawValue) }
        sizeControl.selectedSegment = canvas.size.rawValue
        sizeControl.target = self
        sizeControl.action = #selector(sizeChanged)

        undoButton = Self.iconButton("arrow.uturn.backward", "Deshacer (⌘Z)", self, #selector(undo))
        redoButton = Self.iconButton("arrow.uturn.forward", "Rehacer (⇧⌘Z)", self, #selector(redo))
        clearButton = Self.iconButton("trash", "Borrar todas las anotaciones", self, #selector(clearAll))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [toolControl, colorControl, sizeControl, spacer, undoButton, redoButton, clearButton])
        top.orientation = .horizontal
        top.spacing = 10
        top.alignment = .centerY

        let hint = NSTextField(labelWithString: "Mayús: formas proporcionales · Supr: deshacer · Letras: cambiar herramienta")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let copy = NSButton(title: "Copiar", target: self, action: #selector(copyResult))
        let save = NSButton(title: "Guardar…", target: self, action: #selector(saveResult))
        let done = NSButton(title: "Copiar y cerrar", target: self, action: #selector(copyAndClose))
        done.bezelColor = .controlAccentColor
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = [.command]
        let bottom = NSStackView(views: [hint, copy, save, done])
        bottom.orientation = .horizontal
        bottom.spacing = 10
        bottom.alignment = .centerY

        for view in [top, canvas, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            canvas.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
    }

    private static func symbol(for tool: AnnotationTool) -> String {
        switch tool {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .pen: return "scribble"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .pixelate: return "square.grid.3x3.fill"
        }
    }

    private static func swatch(_ color: RGBA) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1).setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func iconButton(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let button = NSButton(image: image, target: target, action: action)
        button.bezelStyle = .texturedRounded
        button.toolTip = tip
        return button
    }

    private func refreshControls() {
        toolControl.selectedSegment = AnnotationTool.allCases.firstIndex(of: canvas.tool) ?? 0
        undoButton.isEnabled = canvas.history.canUndo
        redoButton.isEnabled = canvas.history.canRedo
        clearButton.isEnabled = !canvas.history.items.isEmpty
        window?.isDocumentEdited = hasUnexportedChanges
    }

    @objc private func toolChanged() { canvas.tool = AnnotationTool.allCases[toolControl.selectedSegment] }
    @objc private func colorChanged() { canvas.color = Self.palette[colorControl.selectedSegment].1 }
    @objc private func sizeChanged() { canvas.size = StrokeSize(rawValue: sizeControl.selectedSegment) ?? .medium }
    @objc private func undo() { canvas.undo() }
    @objc private func redo() { canvas.redo() }
    @objc private func clearAll() { canvas.clear() }

    @objc func saveResult() {
        guard let data = render() else { return }
        if saveImage(data) { markDone() }
    }

    @objc func copyResult() {
        guard let data = render() else { return }
        copyImage(data)
        markDone()
    }

    @objc private func copyAndClose() {
        guard let data = render() else { return }
        copyImage(data)
        markDone()
        close()
    }

    private func markDone() {
        exported = canvas.history.items
        window?.isDocumentEdited = false
    }

    private func render() -> Data? {
        if let data = canvas.pngData() { return data }
        let alert = NSAlert()
        alert.messageText = "No se pudo generar la imagen anotada."
        alert.runModal()
        return nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.commitText()
        guard hasUnexportedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "¿Cerrar sin copiar ni guardar?"
        alert.informativeText = "Las anotaciones se perderán."
        alert.addButton(withTitle: "Copiar y cerrar")
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: "Descartar")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let data = render() else { return false }
            copyImage(data)
            markDone()
            return true
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
#endif
