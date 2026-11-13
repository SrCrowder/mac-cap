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
    private(set) lazy var blurred: NSImage? = makeBlurred()

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
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let block = AnnotationGeometry.pixelateBlock(for: pixelSize, scale: scale)
        // Random grid offset so the block layout can't be predicted by de-pixelation tools.
        let offset = CGPoint(x: CGFloat.random(in: 0..<block), y: CGFloat.random(in: 0..<block))
        let output = Self.pixelate(CIImage(cgImage: cgImage), block: block, offset: offset, noise: true)
        guard let result = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: result, size: pixelSize)
    }

    private func makeBlurred() -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cgImage)
        // A plain Gaussian blur can be partly reversed. Pixelate first (each block becomes an average,
        // with noise and a random grid, so the original pixels are gone), then soften the blocks.
        let block = AnnotationGeometry.pixelateBlock(for: pixelSize, scale: scale)
        let offset = CGPoint(x: CGFloat.random(in: 0..<block), y: CGFloat.random(in: 0..<block))
        let output = Self.pixelate(input, block: block, offset: offset, noise: true)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: block * 0.6])
            .cropped(to: input.extent)
        guard let result = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: result, size: pixelSize)
    }

    /// Mosaic where each block is the average colour of its area, plus optional light noise.
    static func pixelate(_ input: CIImage, block: CGFloat, offset: CGPoint, noise: Bool) -> CIImage {
        let extent = input.extent
        // CIPixellate samples one point per block; blurring first makes each block the area's average.
        let averaged = input.clampedToExtent()
            .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: block / 2])
        var output = averaged
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: block,
                                                        kCIInputCenterKey: CIVector(x: offset.x, y: offset.y)])
            .cropped(to: extent)
        if noise, let random = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let grain = random
                .transformed(by: CGAffineTransform(translationX: CGFloat.random(in: 0..<1000), y: 0))
                .cropped(to: extent)
                .settingAlphaOne(in: extent)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.12, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.12, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.12, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: -0.06, y: -0.06, z: -0.06, w: 1)
                ])
            // The sum has alpha 2; reset it to 1 so the colours stay as computed.
            output = grain.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: output])
                .cropped(to: extent)
                .settingAlphaOne(in: extent)
        }
        return output
    }

    /// Draws the final picture: optional background, the (cropped) image and its annotations.
    /// The current context must be flipped, 1 unit = 1 output pixel.
    func drawComposition(_ state: EditorState, background: ShareBackground) {
        let visible = state.crop ?? CGRect(origin: .zero, size: pixelSize)
        let layout = background.layout(content: visible.size)
        let contentRect = CGRect(origin: layout.contentOrigin, size: visible.size)
        let radius: CGFloat = background == .none ? 0 : 10 * scale
        if let (start, end) = background.colors {
            NSGradient(starting: Self.color(start), ending: Self.color(end))?
                .draw(in: CGRect(origin: .zero, size: layout.size), angle: 60)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 16 * scale
            shadow.shadowOffset = NSSize(width: 0, height: -6 * scale)
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: contentRect, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: contentRect, xRadius: radius, yRadius: radius).addClip()
        let transform = NSAffineTransform()
        transform.translateX(by: layout.contentOrigin.x - visible.minX, yBy: layout.contentOrigin.y - visible.minY)
        transform.concat()
        draw(state.items)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func color(_ c: RGBA) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }

    func textString(_ a: Annotation) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = isDark(a.color) ? NSColor.white.withAlphaComponent(0.85) : NSColor.black.withAlphaComponent(0.75)
        shadow.shadowBlurRadius = a.fontSize / 8
        shadow.shadowOffset = .zero
        return NSAttributedString(string: a.text, attributes: [
            .font: NSFont.systemFont(ofSize: a.fontSize, weight: .bold),
            .foregroundColor: Self.color(a.color),
            .shadow: shadow
        ])
    }

    func textSize(_ a: Annotation) -> CGSize { a.tool == .text ? textString(a).size() : .zero }

    /// Draws the image and annotations in image pixels (origin top-left, flipped context).
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
            textString(a).draw(at: origin)
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
        case .pixelate, .blur:
            guard a.points.count == 2, let filtered = a.tool == .pixelate ? pixelated : blurred else { return }
            let rect = AnnotationGeometry.rect(from: a.points[0], to: a.points[1])
            NSBezierPath(rect: rect).addClip()
            filtered.draw(in: CGRect(origin: .zero, size: pixelSize), from: .zero, operation: .copy,
                          fraction: 1, respectFlipped: true, hints: nil)
        case .select, .crop:
            break
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

    func pngData(with annotations: [Annotation]) -> Data? {
        pngData(EditorState(items: annotations), background: .none)
    }

    /// PNG with the annotations burnt in, keeping the original resolution and DPI.
    func pngData(_ state: EditorState, background: ShareBackground) -> Data? {
        let visible = state.crop ?? CGRect(origin: .zero, size: pixelSize)
        let size = background.layout(content: visible.size).size
        guard size.width >= 1, size.height >= 1,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                                            pixelsHigh: Int(size.height), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        let context = bitmapContext.cgContext
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawComposition(state, background: background)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: size.width / scale, height: size.height / scale)
        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - Canvas

final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    let document: AnnotationImage
    private(set) var history = AnnotationHistory()
    var tool: AnnotationTool = .rectangle {
        didSet {
            commitText()
            selection = nil
            window?.invalidateCursorRects(for: self)
            onStateChange?()
        }
    }
    var color = RGBA(r: 1, g: 0.18, b: 0.18) { didSet { applyStyleToSelection() } }
    var size: StrokeSize = .medium { didSet { applyStyleToSelection() } }
    var background: ShareBackground = .none {
        didSet {
            commitText()
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            onStateChange?()
        }
    }
    var onStateChange: (() -> Void)?
    /// Index of the selected annotation (select tool).
    private(set) var selection: Int? {
        didSet { needsDisplay = true; onStateChange?() }
    }

    private enum Drag {
        case move(start: CGPoint, original: Annotation)
        case resize(point: Int, original: Annotation)
        case crop(start: CGPoint)
    }

    private var current: Annotation?
    private var drag: Drag?
    /// The selected annotation while it is being moved or resized.
    private var preview: Annotation?
    private var cropPreview: CGRect?
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

    var state: EditorState { history.state }

    // MARK: Layout

    /// Part of the image shown (crop), in image pixels.
    private var imageVisibleRect: CGRect { history.crop ?? CGRect(origin: .zero, size: document.pixelSize) }

    private var layout: (size: CGSize, contentOrigin: CGPoint) {
        background.layout(content: imageVisibleRect.size)
    }

    /// Where the whole composition is drawn, in view coordinates.
    private var compositionRect: CGRect {
        let composition = layout.size
        // Never upscale beyond the image's natural size in points.
        let natural = CGSize(width: composition.width / document.scale, height: composition.height / document.scale)
        let fitted = AnnotationGeometry.imageRect(image: composition, in: bounds.insetBy(dx: 8, dy: 8))
        guard fitted.width > natural.width else { return fitted }
        return CGRect(x: bounds.midX - natural.width / 2, y: bounds.midY - natural.height / 2,
                      width: natural.width, height: natural.height).integral
    }

    /// View points per image pixel.
    private var viewScale: CGFloat { compositionRect.width / max(layout.size.width, 1) }

    private func viewPoint(_ p: CGPoint) -> CGPoint {
        let rect = compositionRect, origin = layout.contentOrigin, visible = imageVisibleRect
        return CGPoint(x: rect.minX + (origin.x + p.x - visible.minX) * viewScale,
                       y: rect.minY + (origin.y + p.y - visible.minY) * viewScale)
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(origin: viewPoint(r.origin), size: CGSize(width: r.width * viewScale, height: r.height * viewScale))
    }

    /// The image area (without background) in view coordinates.
    private var imageAreaInView: CGRect { viewRect(imageVisibleRect) }

    /// View point → image pixels, clamped to the visible part of the image.
    private func imagePoint(_ v: CGPoint) -> CGPoint {
        let rect = compositionRect, origin = layout.contentOrigin, visible = imageVisibleRect
        let scale = max(viewScale, 0.0001)
        let x = (v.x - rect.minX) / scale - origin.x + visible.minX
        let y = (v.y - rect.minY) / scale - origin.y + visible.minY
        return CGPoint(x: min(max(x, visible.minX), visible.maxX), y: min(max(y, visible.minY), visible.maxY))
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint { imagePoint(convert(event.locationInWindow, from: nil)) }

    // MARK: Drawing

    /// State as shown right now, including the drag in progress.
    private var displayState: EditorState {
        var shown = history.state
        if let index = selection, let preview = preview, shown.items.indices.contains(index) {
            shown.items[index] = preview
        }
        if let current = current { shown.items.append(current) }
        return shown
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        let rect = compositionRect
        guard rect.width > 0 else { return }
        if background == .none {
            NSGraphicsContext.saveGraphicsState()
            let frameShadow = NSShadow()
            frameShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            frameShadow.shadowBlurRadius = 8
            frameShadow.set()
            NSColor.white.setFill()
            rect.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: viewScale)
        transform.concat()
        document.drawComposition(displayState, background: background)
        NSGraphicsContext.restoreGraphicsState()

        drawSelection()
        drawCropPreview()
    }

    private func drawSelection() {
        guard let index = selection, displayState.items.indices.contains(index) else { return }
        let annotation = displayState.items[index]
        let box = viewRect(AnnotationGeometry.bounds(of: annotation, textSize: document.textSize)).insetBy(dx: -4, dy: -4)
        let outline = NSBezierPath(rect: box)
        outline.lineWidth = 1
        outline.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
        for handle in handles(for: annotation) {
            let circle = NSBezierPath(ovalIn: CGRect(x: handle.x - 5, y: handle.y - 5, width: 10, height: 10))
            NSColor.white.setFill()
            circle.fill()
            circle.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            circle.stroke()
        }
    }

    private func drawCropPreview() {
        guard let crop = cropPreview else { return }
        let area = imageAreaInView, cropRect = viewRect(crop)
        let dim = NSBezierPath(rect: area)
        dim.append(NSBezierPath(rect: cropRect))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()
        let outline = NSBezierPath(rect: cropRect)
        outline.lineWidth = 1.5
        NSColor.white.setStroke()
        outline.stroke()
        let label = NSAttributedString(string: " \(Int(crop.width)) × \(Int(crop.height)) ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6)
        ])
        label.draw(at: CGPoint(x: cropRect.minX, y: max(area.minY, cropRect.minY - 18)))
    }

    /// Resize handles (view coordinates) of an annotation defined by two points.
    private func handles(for annotation: Annotation) -> [CGPoint] {
        guard annotation.tool.hasEndpoints, annotation.points.count == 2 else { return [] }
        return annotation.points.map(viewPoint)
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(imageAreaInView, cursor: cursor)
    }

    override func setFrameSize(_ newSize: NSSize) {
        commitText()
        super.setFrameSize(newSize)
    }

    // MARK: Mouse

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
        let viewLocation = convert(event.locationInWindow, from: nil)
        let point = imagePoint(viewLocation)
        if tool == .select {
            if let index = selection, history.items.indices.contains(index),
               let handle = handles(for: history.items[index]).firstIndex(where: {
                   hypot($0.x - viewLocation.x, $0.y - viewLocation.y) <= 8 }) {
                drag = .resize(point: handle, original: history.items[index])
                return
            }
            if let index = AnnotationGeometry.topmost(in: history.items, at: point, tolerance: 6 / max(viewScale, 0.01),
                                                      textSize: document.textSize) {
                selection = index
                drag = .move(start: point, original: history.items[index])
            } else {
                selection = nil
            }
            return
        }
        guard imageAreaInView.contains(viewLocation) else { return }
        switch tool {
        case .text:
            if !hadText { beginText(at: point) }
        case .counter:
            history.add(newAnnotation(at: point))
            changed()
        case .crop:
            drag = .crop(start: point)
            cropPreview = CGRect(origin: point, size: .zero)
        default:
            current = newAnnotation(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(event)
        let shift = event.modifierFlags.contains(.shift)
        if let drag = drag {
            switch drag {
            case .move(let start, let original):
                preview = AnnotationGeometry.translated(original, by: CGPoint(x: point.x - start.x, y: point.y - start.y))
            case .resize(let index, let original):
                var resized = original
                resized.points[index] = shift
                    ? AnnotationGeometry.constrain(start: original.points[1 - index], end: point, tool: original.tool)
                    : point
                preview = resized
            case .crop(let start):
                let end = shift ? AnnotationGeometry.constrain(start: start, end: point, tool: .crop) : point
                cropPreview = AnnotationGeometry.rect(from: start, to: end).intersection(imageVisibleRect)
            }
            needsDisplay = true
            return
        }
        guard var annotation = current else { return }
        if annotation.tool.isFreehand {
            if let last = annotation.points.last, hypot(last.x - point.x, last.y - point.y) >= 1 {
                annotation.points.append(point)
            }
        } else {
            annotation.points[1] = shift
                ? AnnotationGeometry.constrain(start: annotation.points[0], end: point, tool: annotation.tool)
                : point
        }
        current = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let finished = drag {
            drag = nil
            switch finished {
            case .move, .resize:
                if let index = selection, let preview = preview { history.replace(at: index, with: preview) }
                preview = nil
            case .crop:
                if let crop = cropPreview?.integral.intersection(imageVisibleRect),
                   crop.width >= 8 * document.scale, crop.height >= 8 * document.scale {
                    history.setCrop(crop)
                }
                cropPreview = nil
                window?.invalidateCursorRects(for: self)
            }
            changed()
            return
        }
        guard let annotation = current else { return }
        current = nil
        if AnnotationGeometry.isMeaningful(annotation, minimum: 3 * document.scale) {
            history.add(annotation)
        }
        changed()
    }

    /// Applies the toolbar colour and size to the selected annotation.
    private func applyStyleToSelection() {
        guard tool == .select, let index = selection, history.items.indices.contains(index) else { return }
        var styled = history.items[index]
        let s = document.scale
        if styled.tool != .pixelate && styled.tool != .blur { styled.color = color }
        switch styled.tool {
        case .text: styled.fontSize = size.fontSize * s
        case .counter: styled.fontSize = size.counterRadius * s
        default: styled.lineWidth = size.lineWidth * s
        }
        history.replace(at: index, with: styled)
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
        case 51, 117: // delete / forward delete
            if let index = selection {
                selection = nil
                history.remove(at: index)
                changed()
            } else {
                undo()
            }
        case 53: // escape
            if current != nil || drag != nil {
                current = nil
                drag = nil
                preview = nil
                cropPreview = nil
                needsDisplay = true
            } else if selection != nil {
                selection = nil
            } else {
                super.keyDown(with: event)
            }
        default: super.keyDown(with: event)
        }
    }

    // MARK: Text

    private func beginText(at point: CGPoint) {
        textOrigin = point
        let field = NSTextField(string: "")
        field.placeholderString = L("Escribe y pulsa Intro", "Type and press Return")
        field.font = NSFont.systemFont(ofSize: max(11, size.fontSize * document.scale * viewScale), weight: .bold)
        field.textColor = AnnotationImage.color(color)
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
        field.drawsBackground = true
        field.isBordered = true
        field.focusRingType = .none
        field.delegate = self
        field.sizeToFit()
        let origin = viewPoint(point)
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
        let annotation = Annotation(tool: .text, points: [textOrigin], color: color, lineWidth: 0,
                                    fontSize: size.fontSize * document.scale, text: text)
        if AnnotationGeometry.isMeaningful(annotation) {
            history.add(annotation)
        }
        changed()
    }

    // MARK: Actions

    func undo() { commitText(); selection = nil; history.undo(); changed() }
    func redo() { commitText(); selection = nil; history.redo(); changed() }
    func clear() { commitText(); selection = nil; history.clear(); changed() }

    func pngData() -> Data? {
        commitText()
        return document.pngData(history.state, background: background)
    }

    private func changed() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
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
        (L("Rojo", "Red"), RGBA(r: 1, g: 0.18, b: 0.18)),
        (L("Naranja", "Orange"), RGBA(r: 1, g: 0.58, b: 0)),
        (L("Amarillo", "Yellow"), RGBA(r: 1, g: 0.84, b: 0.04)),
        (L("Verde", "Green"), RGBA(r: 0.2, g: 0.78, b: 0.35)),
        (L("Azul", "Blue"), RGBA(r: 0.04, g: 0.52, b: 1)),
        (L("Morado", "Purple"), RGBA(r: 0.69, g: 0.32, b: 0.87)),
        (L("Negro", "Black"), RGBA(r: 0.1, g: 0.1, b: 0.1)),
        (L("Blanco", "White"), RGBA(r: 1, g: 1, b: 1))
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
    private var exported = EditorState()
    private var exportedBackground = ShareBackground.none
    private var hasUnexportedChanges: Bool {
        canvas.state != exported || canvas.background != exportedBackground
    }
    private let backgroundPopup = NSPopUpButton()

    init(document: AnnotationImage, save: @escaping (Data) -> Bool, copy: @escaping (Data) -> Void) {
        canvas = AnnotationCanvas(document: document)
        saveImage = save
        copyImage = copy

        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let natural = CGSize(width: document.pixelSize.width / document.scale + 40,
                             height: document.pixelSize.height / document.scale + 130)
        let size = CGSize(width: min(max(natural.width, 960), visible.width * 0.92),
                          height: min(max(natural.height, 480), visible.height * 0.92))
        let window = AnnotationWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                      backing: .buffered, defer: false)
        window.title = L("Anotar captura", "Annotate screenshot")
        window.minSize = NSSize(width: 960, height: 420)
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

        undoButton = Self.iconButton("arrow.uturn.backward", L("Deshacer (⌘Z)", "Undo (⌘Z)"), self, #selector(undo))
        redoButton = Self.iconButton("arrow.uturn.forward", L("Rehacer (⇧⌘Z)", "Redo (⇧⌘Z)"), self, #selector(redo))
        clearButton = Self.iconButton("trash", L("Borrar todas las anotaciones", "Delete all annotations"), self, #selector(clearAll))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [toolControl, colorControl, sizeControl, spacer, undoButton, redoButton, clearButton])
        top.orientation = .horizontal
        top.spacing = 10
        top.alignment = .centerY

        let hint = NSTextField(labelWithString: L("V: seleccionar y mover · Mayús: proporciones · Supr: borrar · Letras: herramientas", "V: select and move · Shift: proportions · Delete: remove · Letters: tools"))
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let copy = NSButton(title: L("Copiar", "Copy"), target: self, action: #selector(copyResult))
        let save = NSButton(title: L("Guardar…", "Save…"), target: self, action: #selector(saveResult))
        let done = NSButton(title: L("Copiar y cerrar", "Copy and close"), target: self, action: #selector(copyAndClose))
        done.bezelColor = .controlAccentColor
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = [.command]
        for style in ShareBackground.allCases { backgroundPopup.addItem(withTitle: style.title) }
        backgroundPopup.target = self
        backgroundPopup.action = #selector(backgroundChanged)
        backgroundPopup.toolTip = L("Fondo con margen y sombra para compartir", "Background with padding and shadow for sharing")
        let backgroundLabel = NSTextField(labelWithString: L("Fondo:", "Background:"))
        let bottom = NSStackView(views: [hint, backgroundLabel, backgroundPopup, copy, save, done])
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
        case .select: return "cursorarrow"
        case .blur: return "drop.fill"
        case .crop: return "crop"
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
    @objc private func backgroundChanged() {
        canvas.background = ShareBackground(rawValue: backgroundPopup.indexOfSelectedItem) ?? .none
    }
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
        exported = canvas.state
        exportedBackground = canvas.background
        window?.isDocumentEdited = false
    }

    private func render() -> Data? {
        if let data = canvas.pngData() { return data }
        let alert = NSAlert()
        alert.messageText = L("No se pudo generar la imagen anotada.", "Could not create the annotated image.")
        alert.runModal()
        return nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.commitText()
        guard hasUnexportedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = L("¿Cerrar sin copiar ni guardar?", "Close without copying or saving?")
        alert.informativeText = L("Las anotaciones se perderán.", "The annotations will be lost.")
        alert.addButton(withTitle: L("Copiar y cerrar", "Copy and close"))
        alert.addButton(withTitle: L("Cancelar", "Cancel"))
        alert.addButton(withTitle: L("Descartar", "Discard"))
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
