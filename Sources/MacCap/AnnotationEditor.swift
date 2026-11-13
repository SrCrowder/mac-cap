#if os(macOS)
import AppKit

final class AnnotationWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let canvas: AnnotationView
    private let saveImage: (Data) -> Void
    private let copyImage: (Data) -> Void

    init(data: Data, save: @escaping (Data) -> Void, copy: @escaping (Data) -> Void) {
        canvas = AnnotationView(data: data)
        saveImage = save
        copyImage = copy
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Anotar captura"
        window.minSize = NSSize(width: 400, height: 300)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        let content = window.contentView!
        let instructions = NSTextField(labelWithString: "Arrastra sobre la imagen para dibujar rectángulos.")
        let clear = NSButton(title: "Borrar rectángulos", target: self, action: #selector(clearAnnotations))
        let copy = NSButton(title: "Copiar", target: self, action: #selector(copyResult))
        let save = NSButton(title: "Guardar…", target: self, action: #selector(saveResult))
        let controls = NSStackView(views: [instructions, clear, copy, save])
        controls.orientation = .horizontal
        controls.spacing = 12
        controls.alignment = .centerY
        canvas.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(canvas)
        content.addSubview(controls)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            canvas.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            canvas.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) { onClose?() }

    @objc private func clearAnnotations() {
        canvas.rectangles.removeAll()
        canvas.needsDisplay = true
    }

    @objc private func saveResult() { export(using: saveImage) }
    @objc private func copyResult() { export(using: copyImage) }

    private func export(using action: (Data) -> Void) {
        guard let data = canvas.pngData() else {
            let alert = NSAlert()
            alert.messageText = "No se pudo generar la imagen anotada."
            alert.runModal()
            return
        }
        action(data)
    }
}

final class AnnotationView: NSView {
    private let image: NSImage
    private let pixels: CGSize
    var rectangles: [CGRect] = []
    private var start: CGPoint?
    private var preview: CGRect?

    init(data: Data) {
        image = NSImage(data: data)!
        let bitmap = NSBitmapImageRep(data: data)!
        pixels = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        image.size = pixels
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let imageRect = AnnotationGeometry.imageRect(image: pixels, in: bounds)
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        drawRectangles(rectangles + (preview.map { [$0] } ?? []), in: imageRect, lineWidth: 3)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let imageRect = AnnotationGeometry.imageRect(image: pixels, in: bounds)
        start = imageRect.contains(point) ? point : nil
        preview = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = start else { return }
        preview = AnnotationGeometry.rectangle(from: start, to: convert(event.locationInWindow, from: nil),
                                                in: AnnotationGeometry.imageRect(image: pixels, in: bounds))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let start = start, let rectangle = AnnotationGeometry.rectangle(
            from: start, to: convert(event.locationInWindow, from: nil),
            in: AnnotationGeometry.imageRect(image: pixels, in: bounds)) {
            rectangles.append(rectangle)
        }
        start = nil
        preview = nil
        needsDisplay = true
    }

    private func drawRectangles(_ rectangles: [CGRect], in bounds: CGRect, lineWidth: CGFloat) {
        NSColor.systemRed.setStroke()
        for rectangle in rectangles {
            let path = NSBezierPath(rect: AnnotationGeometry.project(rectangle, into: bounds))
            path.lineWidth = lineWidth
            path.stroke()
        }
    }

    func pngData() -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width),
                                           pixelsHigh: Int(pixels.height), bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        let context = bitmapContext.cgContext
        context.translateBy(x: 0, y: pixels.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let imageRect = CGRect(origin: .zero, size: pixels)
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        drawRectangles(rectangles, in: imageRect, lineWidth: max(2, pixels.width / 300))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif
