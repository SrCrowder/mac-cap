#if os(macOS)
import AppKit

/// Full-screen transparent overlay to pick a region (for recording and scrolling capture)
/// or to measure distances (ruler). One window per display.
final class ScreenOverlay: NSObject {
    enum Mode {
        /// Drag a rectangle; calls back with it in global screen coordinates (points, bottom-left origin).
        case select(prompt: String, completion: (CGRect?, NSScreen?) -> Void)
        /// Drag to measure; Esc to exit.
        case ruler
    }

    private static var active: ScreenOverlay?
    private var windows: [OverlayWindow] = []
    private let mode: Mode

    private init(mode: Mode) {
        self.mode = mode
    }

    static func selectRegion(prompt: String, completion: @escaping (CGRect?, NSScreen?) -> Void) {
        present(ScreenOverlay(mode: .select(prompt: prompt, completion: completion)))
    }

    static func showRuler() {
        present(ScreenOverlay(mode: .ruler))
    }

    private static func present(_ overlay: ScreenOverlay) {
        active?.finish(nil, screen: nil)
        active = overlay
        NSApp.activate(ignoringOtherApps: true)
        let isRuler: Bool
        let prompt: String
        switch overlay.mode {
        case .ruler:
            isRuler = true
            prompt = "Arrastra para medir · Mayús: solo horizontal/vertical · Esc para salir"
        case .select(let text, _):
            isRuler = false
            prompt = text
        }
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen)
            let view = OverlayView(isRuler: isRuler, prompt: prompt, scale: screen.backingScaleFactor)
            view.onFinish = { [weak overlay, weak window] rect in
                guard let overlay = overlay else { return }
                let global = rect.map { $0.offsetBy(dx: window?.frame.minX ?? 0, dy: window?.frame.minY ?? 0) }
                overlay.finish(global, screen: global == nil ? nil : screen)
            }
            window.contentView = view
            window.orderFrontRegardless()
            overlay.windows.append(window)
        }
        (overlay.windows.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? overlay.windows.first)?
            .makeKey()
    }

    private func finish(_ rect: CGRect?, screen: NSScreen?) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if Self.active === self { Self.active = nil }
        if case .select(_, let completion) = mode {
            completion(rect, screen)
        }
    }
}

private final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private let isRuler: Bool
    private let prompt: String
    private let scale: CGFloat
    private var start: CGPoint?
    private var end: CGPoint?

    init(isRuler: Bool, prompt: String, scale: CGFloat) {
        self.isRuler = isRuler
        self.prompt = prompt
        self.scale = scale
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: CGRect? {
        guard let start = start, let end = end else { return nil }
        return AnnotationGeometry.rect(from: start, to: end)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if !isRuler, let selection = selection { dim.append(NSBezierPath(rect: selection)) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(isRuler ? 0.12 : 0.3).setFill()
        dim.fill()

        drawLabel(prompt, at: CGPoint(x: bounds.midX, y: bounds.maxY - 60), centered: true, size: 14)

        guard let start = start, let end = end else { return }
        NSColor.systemYellow.setStroke()
        if isRuler {
            let line = NSBezierPath()
            line.move(to: start)
            line.line(to: end)
            line.lineWidth = 2
            line.stroke()
            for point in [start, end] {
                NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
            }
            let box = NSBezierPath(rect: AnnotationGeometry.rect(from: start, to: end))
            box.setLineDash([4, 4], count: 2, phase: 0)
            box.lineWidth = 1
            box.stroke()
            let dx = abs(end.x - start.x), dy = abs(end.y - start.y)
            let length = hypot(dx, dy)
            let text = String(format: "%.0f × %.0f pt · %.0f pt  (%.0f × %.0f px)",
                              dx, dy, length, dx * scale, dy * scale)
            drawLabel(text, at: CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + 14), centered: true, size: 13)
        } else if let selection = selection {
            let outline = NSBezierPath(rect: selection)
            outline.lineWidth = 1.5
            NSColor.white.setStroke()
            outline.stroke()
            drawLabel(String(format: "%.0f × %.0f", selection.width, selection.height),
                      at: CGPoint(x: selection.minX, y: selection.maxY + 6), centered: false, size: 12)
        }
    }

    private func drawLabel(_ text: String, at point: CGPoint, centered: Bool, size: CGFloat) {
        let label = NSAttributedString(string: " \(text) ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.white
        ])
        let labelSize = label.size()
        var origin = CGPoint(x: centered ? point.x - labelSize.width / 2 : point.x, y: point.y)
        origin.x = min(max(origin.x, 4), bounds.maxX - labelSize.width - 4)
        origin.y = min(max(origin.y, 4), bounds.maxY - labelSize.height - 4)
        let background = CGRect(origin: origin, size: labelSize).insetBy(dx: -4, dy: -3)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6).fill()
        label.draw(at: origin)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        end = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = start else { return }
        var point = convert(event.locationInWindow, from: nil)
        if isRuler, event.modifierFlags.contains(.shift) {
            if abs(point.x - start.x) > abs(point.y - start.y) { point.y = start.y } else { point.x = start.x }
        }
        end = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isRuler else { return }
        if let selection = selection, selection.width >= 10, selection.height >= 10 {
            onFinish?(selection.integral)
        } else {
            start = nil
            end = nil
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }
}
#endif
