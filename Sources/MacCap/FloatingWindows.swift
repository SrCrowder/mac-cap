#if os(macOS)
import AppKit

/// Screen under the mouse pointer (where floating windows should appear).
func screenUnderMouse() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
}

/// Small button with an SF Symbol, used on top of floating images.
private func overlayButton(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(configuration)
    let button = NSButton(image: image ?? NSImage(), target: target, action: action)
    button.isBordered = false
    button.contentTintColor = .white
    button.toolTip = tip
    button.wantsLayer = true
    button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
    button.layer?.cornerRadius = 12
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 24),
                                 button.heightAnchor.constraint(equalToConstant: 24)])
    return button
}

// MARK: - Thumbnail after a capture

/// Floating preview in the corner of the screen after a capture, like macOS's own:
/// click to annotate, drag it into another app, swipe right or wait to dismiss.
final class CaptureThumbnail: NSObject {
    struct Actions {
        var annotate: (URL) -> Void
        var pin: (URL) -> Void
        var copy: (URL) -> Void
    }

    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    private let actions: Actions

    init(actions: Actions) {
        self.actions = actions
    }

    func show(fileURL: URL, preview: NSImage? = nil) {
        guard let image = preview ?? NSImage(contentsOf: fileURL), let screen = screenUnderMouse() else { return }
        dismiss(animated: false)
        let maxSize = CGSize(width: 220, height: 150)
        let ratio = min(maxSize.width / max(image.size.width, 1), maxSize.height / max(image.size.height, 1), 1)
        let size = CGSize(width: max(80, image.size.width * ratio), height: max(50, image.size.height * ratio))
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.maxX - size.width - 20, y: visible.minY + 20, width: size.width, height: size.height)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = ThumbnailView(image: image, fileURL: fileURL)
        view.onClick = { [weak self] in self?.perform(self?.actions.annotate, fileURL) }
        view.onDismiss = { [weak self] in self?.dismiss(animated: true) }
        view.onDragEnded = { [weak self] dropped in if dropped { self?.dismiss(animated: true) } }
        view.onHover = { [weak self] inside in
            if inside { self?.dismissWork?.cancel() } else { self?.scheduleDismiss(after: 3) }
        }
        view.onPin = { [weak self] in self?.perform(self?.actions.pin, fileURL) }
        view.onCopy = { [weak self] in self?.perform(self?.actions.copy, fileURL) }
        panel.contentView = view

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        self.panel = panel
        scheduleDismiss(after: 6)
    }

    private func perform(_ action: ((URL) -> Void)?, _ url: URL) {
        dismiss(animated: false)
        action?(url)
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss(animated: true) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func dismiss(animated: Bool) {
        dismissWork?.cancel()
        guard let panel = panel else { return }
        self.panel = nil
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

private final class ThumbnailView: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onDragEnded: ((Bool) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onPin: (() -> Void)?
    var onCopy: (() -> Void)?

    private let image: NSImage
    private let fileURL: URL
    private var mouseDownEvent: NSEvent?
    private var dragging = false
    private var buttons: [NSButton] = []

    init(image: NSImage, fileURL: URL) {
        self.image = image
        self.fileURL = fileURL
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        toolTip = L("Clic: anotar · Arrastrar: soltar en otra app · Deslizar a la derecha: descartar", "Click: annotate · Drag: drop into another app · Swipe right: dismiss")

        let close = overlayButton("xmark", L("Descartar", "Discard"), self, #selector(closeTapped))
        let pin = overlayButton("pin.fill", L("Fijar en pantalla", "Pin on screen"), self, #selector(pinTapped))
        let copy = overlayButton("doc.on.doc", L("Copiar", "Copy"), self, #selector(copyTapped))
        buttons = [close, pin, copy]
        buttons.forEach { $0.isHidden = true; addSubview($0) }
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            close.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            pin.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            pin.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            copy.topAnchor.constraint(equalTo: pin.bottomAnchor, constant: 6),
            copy.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        buttons.forEach { $0.isHidden = false }
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        buttons.forEach { $0.isHidden = true }
        onHover?(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - start.locationInWindow.x
        let dy = event.locationInWindow.y - start.locationInWindow.y
        guard dx * dx + dy * dy > 16 else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: start, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging { onClick?() }
        dragging = false
    }

    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaX < -15 || event.scrollingDeltaX > 15 { onDismiss?() }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        onDragEnded?(operation != [])
    }

    @objc private func closeTapped() { onDismiss?() }
    @objc private func pinTapped() { onPin?() }
    @objc private func copyTapped() { onCopy?() }
}

// MARK: - Image pinned on screen

/// A capture that floats above every window as a reference. Drag to move, resize from the edges,
/// right-click for options, Esc or ✕ to close.
final class PinnedImageWindow: NSPanel {
    var onClose: (() -> Void)?
    var onAnnotate: ((NSImage) -> Void)?
    var onCopy: ((NSImage) -> Void)?
    private let image: NSImage

    init(image: NSImage, pointSize: CGSize) {
        self.image = image
        let screen = screenUnderMouse()?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let ratio = min(screen.width * 0.6 / max(pointSize.width, 1), screen.height * 0.6 / max(pointSize.height, 1), 1)
        let size = CGSize(width: max(60, pointSize.width * ratio), height: max(40, pointSize.height * ratio))
        let mouse = NSEvent.mouseLocation
        var origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        super.init(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = size
        minSize = CGSize(width: 40, height: 40 * size.height / size.width)

        let view = PinnedImageView(image: image)
        view.closeAction = { [weak self] in self?.close() }
        contentView = view
        let menu = NSMenu()
        menu.addItem(withTitle: L("Copiar", "Copy"), action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Anotar…", "Annotate…"), action: #selector(annotateImage), keyEquivalent: "").target = self
        let opacity = NSMenuItem(title: L("Opacidad", "Opacity"), action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for value in [100, 75, 50, 25] {
            let entry = opacityMenu.addItem(withTitle: "\(value) %", action: #selector(setOpacity(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = value
        }
        opacity.submenu = opacityMenu
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Cerrar", "Close"), action: #selector(closeWindow), keyEquivalent: "").target = self
        view.menu = menu
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    @objc private func copyImage() { onCopy?(image) }
    @objc private func annotateImage() { onAnnotate?(image) }
    @objc private func setOpacity(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }
    @objc private func closeWindow() { close() }
}

private final class PinnedImageView: NSView {
    var closeAction: (() -> Void)?
    private let image: NSImage
    private var closeButton: NSButton!

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
        closeButton = overlayButton("xmark", L("Cerrar (Esc)", "Close (Esc)"), self, #selector(closeTapped))
        closeButton.isHidden = true
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        ])
        toolTip = L("Arrastra para mover · Bordes para redimensionar · Clic derecho: opciones", "Drag to move · Edges to resize · Right-click: options")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }

    @objc private func closeTapped() { closeAction?() }
}
#endif
