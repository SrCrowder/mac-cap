#if os(macOS)
import AppKit

extension Shortcut {
    /// Builds a shortcut from a key press, or `nil` for a lone modifier.
    init?(event: NSEvent) {
        let code = Int(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let label: String
        if let name = Shortcut.functionKeys[code] ?? Shortcut.namedKeys[code] {
            label = name
        } else if let characters = event.characters(byApplyingModifiers: []), let first = characters.first,
                  !first.isWhitespace, first.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            label = String(first)
        } else {
            return nil
        }
        self.init(keyCode: code, command: flags.contains(.command), shift: flags.contains(.shift),
                  option: flags.contains(.option), control: flags.contains(.control), key: label)
    }

    var carbonModifiers: Int {
        (command ? 0x0100 : 0) | (shift ? 0x0200 : 0) | (option ? 0x0800 : 0) | (control ? 0x1000 : 0)
    }

    var modifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if command { mask.insert(.command) }
        if shift { mask.insert(.shift) }
        if option { mask.insert(.option) }
        if control { mask.insert(.control) }
        return mask
    }

    /// Menu key equivalent (only for keys with a printable character).
    var menuKeyEquivalent: String? {
        guard Shortcut.functionKeys[keyCode] == nil, Shortcut.namedKeys[keyCode] == nil, key.count == 1 else { return nil }
        return key.lowercased()
    }
}

/// Click, then press the new combination. Esc cancels, ⌫ removes the shortcut.
final class ShortcutField: NSView {
    var shortcut: Shortcut? { didSet { needsDisplay = true } }
    var onChange: ((Shortcut?) -> Void)?
    var onInvalid: (() -> Void)?
    private var recording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        box.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        box.lineWidth = 1
        box.stroke()
        let text = recording ? L("Pulsa el atajo…", "Press the shortcut…") : (shortcut?.displayString ?? "—")
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: recording ? .regular : .medium),
            .foregroundColor: recording || shortcut == nil ? NSColor.secondaryLabelColor : NSColor.labelColor
        ])
        let size = label.size()
        label.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case 53 where flags.isEmpty: // Esc
            recording = false
            return
        case 51 where flags.isEmpty, 117 where flags.isEmpty: // delete
            recording = false
            shortcut = nil
            onChange?(nil)
            return
        default:
            break
        }
        guard let new = Shortcut(event: event) else { return }
        guard new.isValidGlobal else { onInvalid?(); return }
        recording = false
        shortcut = new
        onChange?(new)
    }
}

/// Window to change every global shortcut. Global shortcuts are paused while it is open so the
/// combinations can be typed.
final class ShortcutsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private var fields: [ShortcutAction: ShortcutField] = [:]
    private let message = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("Atajos de teclado", "Keyboard shortcuts")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build(in: window.contentView!)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build(in content: NSView) {
        let intro = NSTextField(wrappingLabelWithString:
            L("Haz clic en un atajo y pulsa la nueva combinación (con ⌘, ⌥ o ⌃). ⌫ lo quita, Esc cancela.", "Click a shortcut and press the new combination (with ⌘, ⌥ or ⌃). ⌫ removes it, Esc cancels."))
        intro.textColor = .secondaryLabelColor
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        let shortcuts = Settings.shortcuts
        for action in ShortcutAction.allCases {
            let label = NSTextField(labelWithString: action.title)
            let field = ShortcutField()
            field.shortcut = shortcuts[action]
            field.onChange = { [weak self] shortcut in self?.assign(shortcut, to: action) }
            field.onInvalid = { [weak self] in
                self?.message.stringValue = L("Usa al menos ⌘, ⌥ o ⌃ (o una tecla de función).", "Use at least ⌘, ⌥ or ⌃ (or a function key).")
            }
            fields[action] = field
            grid.addRow(with: [label, field])
        }
        grid.column(at: 0).xPlacement = .trailing
        message.textColor = .systemOrange
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 2
        let reset = NSButton(title: L("Restablecer predeterminados", "Restore defaults"), target: self, action: #selector(resetDefaults))
        let stack = NSStackView(views: [intro, grid, message, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            intro.widthAnchor.constraint(equalToConstant: 430),
            message.widthAnchor.constraint(equalToConstant: 430)
        ])
    }

    private func assign(_ shortcut: Shortcut?, to action: ShortcutAction) {
        let previous = Settings.shortcuts
        Settings.shortcutOverrides = ShortcutMap.assign(shortcut, to: action, in: Settings.shortcutOverrides)
        let current = Settings.shortcuts
        message.stringValue = ""
        for (other, field) in fields {
            field.shortcut = current[other]
            if other != action, previous[other] != nil, current[other] == nil {
                message.stringValue = L("Se ha quitado de «\(other.title)», que usaba la misma combinación.", "Removed from “\(other.title)”, which used the same combination.")
            }
        }
    }

    @objc private func resetDefaults() {
        Settings.shortcutOverrides = [:]
        let current = Settings.shortcuts
        for (action, field) in fields { field.shortcut = current[action] }
        message.stringValue = ""
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
#endif
