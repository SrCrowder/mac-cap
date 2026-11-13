#if os(macOS)
import AppKit
import AVFoundation
import Carbon.HIToolbox
import UniformTypeIdentifiers

@main
struct MacCap {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

/// What to do with a capture once it is taken.
enum Destination { case save, copy, annotate, text, qr, pin }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var captureInProgress = false
    private var editors: [AnnotationWindowController] = []
    private var restoreIconWork: DispatchWorkItem?
    private let updater = Updater()
    private var autoUpdateItem: NSMenuItem!

    // Option items whose state is refreshed when the menu opens.
    private var delayItems: [NSMenuItem] = []
    private var cursorItem: NSMenuItem!
    private var shadowItem: NSMenuItem!
    private var soundItem: NSMenuItem!
    private var askItem: NSMenuItem!
    private var folderItem: NSMenuItem!
    private var hotKeysItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var permissionSeparator: NSMenuItem!
    private var formatItems: [NSMenuItem] = []
    private var thumbnailItem: NSMenuItem!
    private var historyItem: NSMenuItem!
    private let recentsMenu = NSMenu()
    private var thumbnailCache: [String: NSImage] = [:]
    private var pinnedWindows: [PinnedImageWindow] = []
    // Recording / scrolling capture in progress (RegionRecorder / ScrollCapture, macOS 12.3+).
    private var activeRecorder: AnyObject?
    private var activeScroll: AnyObject?
    private var recordingAsGIF = false
    private var scrollScale: CGFloat = 2
    private var captureControls: CaptureControls?
    private var stopItem: NSMenuItem!
    private var languageItems: [NSMenuItem] = []
    private lazy var thumbnail = CaptureThumbnail(actions: .init(
        annotate: { [weak self] url in
            if Self.isImageFile(url) { self?.annotateImage(at: url) } else { NSWorkspace.shared.open(url) }
        },
        pin: { [weak self] url in self?.pinFile(at: url) },
        copy: { [weak self] url in self?.copyFile(at: url) }))

    private var actionItems: [ShortcutAction: NSMenuItem] = [:]
    private var shortcutsWindow: ShortcutsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("camera.viewfinder")
        statusItem.button?.toolTip = L("MacCap – capturas de pantalla", "MacCap – screenshots")
        statusItem.menu = buildMenu()
        applyHotKeys()
        if CGPreflightScreenCaptureAccess() {
            Settings.suppressPermissionAlert = false
        } else if !Settings.suppressPermissionAlert {
            DispatchQueue.main.async { self.showPermissionHelp(atLaunch: true) }
        }
    }

    // MARK: - Menus

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        stopItem = item(L("■ Detener", "■ Stop"), #selector(stopActiveCapture), symbol: "stop.circle")
        menu.addItem(stopItem)
        permissionItem = item(L("⚠️ Conceder permiso de grabación de pantalla…", "⚠️ Grant screen recording permission…"), #selector(openPermissionSettings))
        permissionSeparator = .separator()
        menu.addItem(permissionItem)
        menu.addItem(permissionSeparator)

        menu.addItem(header(L("Copiar al portapapeles", "Copy to clipboard")))
        menu.addItem(item(L("Zona…", "Area…"), #selector(copySelection), action: .copyZone, symbol: "rectangle.dashed"))
        menu.addItem(item(L("Ventana…", "Window…"), #selector(copyWindow), action: .copyWindow, symbol: "macwindow"))
        menu.addItem(item(L("Pantalla completa", "Full screen"), #selector(copyScreen), action: .copyScreen, symbol: "display"))
        menu.addItem(.separator())

        menu.addItem(header(L("Guardar en archivo", "Save to file")))
        menu.addItem(item(L("Zona…", "Area…"), #selector(saveSelection), action: .saveZone, symbol: "rectangle.dashed"))
        menu.addItem(item(L("Ventana…", "Window…"), #selector(saveWindow), symbol: "macwindow"))
        menu.addItem(item(L("Pantalla completa", "Full screen"), #selector(saveScreen), symbol: "display"))
        menu.addItem(.separator())

        menu.addItem(header(L("Anotar (formas, flechas, texto…)", "Annotate (shapes, arrows, text…)")))
        menu.addItem(item(L("Zona y anotar…", "Area and annotate…"), #selector(annotateSelection), action: .annotateZone, symbol: "pencil.and.outline"))
        menu.addItem(item(L("Ventana y anotar…", "Window and annotate…"), #selector(annotateWindow), symbol: "macwindow.badge.plus"))
        menu.addItem(item(L("Pantalla completa y anotar", "Full screen and annotate"), #selector(annotateScreen), symbol: "display"))
        menu.addItem(item(L("Anotar imagen del portapapeles", "Annotate clipboard image"), #selector(annotateClipboard), symbol: "doc.on.clipboard"))
        menu.addItem(item(L("Anotar imagen de un archivo…", "Annotate image from a file…"), #selector(annotateFile), symbol: "photo"))
        menu.addItem(.separator())

        menu.addItem(header(L("Extras", "Extras")))
        menu.addItem(item(L("Copiar texto de una zona (OCR)…", "Copy text from an area (OCR)…"), #selector(recognizeText), action: .ocr, symbol: "text.viewfinder"))
        menu.addItem(item(L("Leer código QR de una zona…", "Read QR code from an area…"), #selector(readQRCode), action: .qr, symbol: "qrcode.viewfinder"))
        menu.addItem(item(L("Fijar zona en pantalla…", "Pin area on screen…"), #selector(pinSelection), action: .pinZone, symbol: "pin"))
        menu.addItem(item(L("Cuentagotas (copiar color)…", "Color picker (copy color)…"), #selector(pickColor), action: .colorPicker, symbol: "eyedropper"))
        menu.addItem(.separator())

        menu.addItem(header(L("Grabar y medir", "Record and measure")))
        menu.addItem(item(L("Grabar zona en vídeo (MP4)…", "Record area as video (MP4)…"), #selector(recordVideo), action: .recordVideo, symbol: "record.circle"))
        menu.addItem(item(L("Grabar zona como GIF…", "Record area as GIF…"), #selector(recordGIF), action: .recordGIF, symbol: "film"))
        menu.addItem(item(L("Captura con scroll…", "Scrolling capture…"), #selector(startScrollCapture), action: .scrollCapture, symbol: "arrow.down.doc"))
        menu.addItem(item(L("Regla…", "Ruler…"), #selector(showRuler), action: .ruler, symbol: "ruler"))
        menu.addItem(item(L("Herramienta nativa de macOS…", "Native macOS tool…"), #selector(openNativeToolbar), symbol: "camera.aperture"))
        menu.addItem(.separator())
        menu.addItem(item(L("Abrir carpeta de capturas", "Open screenshots folder"), #selector(openSaveFolder), symbol: "folder"))
        let recents = NSMenuItem(title: L("Recientes", "Recent"), action: nil, keyEquivalent: "")
        recents.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        recents.submenu = recentsMenu
        menu.addItem(recents)
        menu.addItem(.separator())

        let options = NSMenuItem(title: L("Opciones", "Options"), action: nil, keyEquivalent: "")
        options.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        options.submenu = buildOptionsMenu()
        menu.addItem(options)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        menu.addItem(header("MacCap \(version)"))
        let check = NSMenuItem(title: L("Buscar actualizaciones…", "Check for updates…"), action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "")
        check.target = updater
        check.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        check.isHidden = !updater.isAvailable
        menu.addItem(check)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Salir de MacCap", "Quit MacCap"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func buildOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let delayMenu = NSMenu()
        for seconds in [0, 3, 5, 10] {
            let entry = item(seconds == 0 ? L("Sin retardo", "No delay") : "\(seconds) " + L("segundos", "seconds"), #selector(setDelay(_:)))
            entry.tag = seconds
            delayMenu.addItem(entry)
            delayItems.append(entry)
        }
        let delay = NSMenuItem(title: L("Retardo antes de capturar", "Delay before capture"), action: nil, keyEquivalent: "")
        delay.submenu = delayMenu
        menu.addItem(delay)

        cursorItem = item(L("Incluir el cursor (pantalla completa)", "Include the pointer (full screen)"), #selector(toggleCursor))
        shadowItem = item(L("Sombra en capturas de ventana", "Shadow in window captures"), #selector(toggleShadow))
        soundItem = item(L("Sonido de obturador", "Shutter sound"), #selector(toggleSound))
        [cursorItem, shadowItem, soundItem].forEach { menu.addItem($0) }
        menu.addItem(.separator())

        let formatMenu = NSMenu()
        for format in ImageFormat.allCases {
            let entry = item(format.title, #selector(setFormat(_:)))
            entry.representedObject = format.rawValue
            formatMenu.addItem(entry)
            formatItems.append(entry)
        }
        let formatItem = NSMenuItem(title: L("Formato al guardar", "Save format"), action: nil, keyEquivalent: "")
        formatItem.submenu = formatMenu
        menu.addItem(formatItem)
        folderItem = item("", #selector(chooseSaveFolder))
        askItem = item(L("Preguntar dónde guardar cada vez", "Ask where to save every time"), #selector(toggleAsk))
        menu.addItem(folderItem)
        menu.addItem(askItem)
        menu.addItem(.separator())
        thumbnailItem = item(L("Mostrar miniatura tras capturar", "Show thumbnail after capture"), #selector(toggleThumbnail))
        historyItem = item(L("Guardar historial de recientes", "Keep recent captures history"), #selector(toggleHistory))
        menu.addItem(thumbnailItem)
        menu.addItem(historyItem)
        menu.addItem(.separator())

        hotKeysItem = item(L("Activar atajos de teclado globales", "Enable global keyboard shortcuts"), #selector(toggleHotKeys))
        menu.addItem(hotKeysItem)
        menu.addItem(item(L("Configurar atajos…", "Configure shortcuts…"), #selector(openShortcuts), symbol: "keyboard"))
        let languageMenu = NSMenu()
        for (code, title) in [("", L("Automático (sistema)", "Automatic (system)")), ("es", "Español"), ("en", "English")] {
            let entry = item(title, #selector(setLanguage(_:)))
            entry.representedObject = code
            languageMenu.addItem(entry)
            languageItems.append(entry)
        }
        let languageItem = NSMenuItem(title: L("Idioma", "Language"), action: nil, keyEquivalent: "")
        languageItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        loginItem = item(L("Abrir al iniciar sesión", "Open at login"), #selector(toggleLoginItem))
        loginItem.isHidden = !LoginItem.isSupported
        menu.addItem(loginItem)
        autoUpdateItem = item(L("Instalar actualizaciones sin preguntar", "Install updates without asking"), #selector(toggleAutoUpdate))
        autoUpdateItem.isHidden = !updater.isAvailable
        menu.addItem(autoUpdateItem)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        stopItem.isHidden = activeRecorder == nil && activeScroll == nil
        stopItem.title = activeScroll != nil ? L("■ Terminar captura con scroll", "■ Finish scrolling capture") : L("■ Detener grabación", "■ Stop recording")
        let granted = CGPreflightScreenCaptureAccess()
        permissionItem.isHidden = granted
        permissionSeparator.isHidden = granted
        let delay = Settings.delay
        delayItems.forEach { $0.state = $0.tag == delay ? .on : .off }
        cursorItem.state = Settings.cursor ? .on : .off
        shadowItem.state = Settings.windowShadow ? .on : .off
        soundItem.state = Settings.sound ? .on : .off
        askItem.state = Settings.askWhereToSave ? .on : .off
        folderItem.title = L("Guardar en: ", "Save to: ") + FileManager.default.displayName(atPath: Settings.saveFolder.path) + "…"
        hotKeysItem.state = Settings.hotKeys ? .on : .off
        loginItem.state = LoginItem.isEnabled ? .on : .off
        refreshMenuShortcuts()
        let language = UserDefaults.standard.string(forKey: Localization.key) ?? ""
        languageItems.forEach { $0.state = ($0.representedObject as? String) == language ? .on : .off }
        autoUpdateItem.state = updater.installsAutomatically ? .on : .off
        let format = Settings.format
        formatItems.forEach { $0.state = ($0.representedObject as? String) == format.rawValue ? .on : .off }
        thumbnailItem.state = Settings.showThumbnail ? .on : .off
        historyItem.state = Settings.keepHistory ? .on : .off
        rebuildRecentsMenu()
    }

    private func rebuildRecentsMenu() {
        recentsMenu.removeAllItems()
        recentsMenu.autoenablesItems = false
        let entries = CaptureHistory.entries()
        if entries.isEmpty {
            let empty = NSMenuItem(title: Settings.keepHistory ? L("Sin capturas recientes", "No recent captures") : L("Historial desactivado", "History turned off"),
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentsMenu.addItem(empty)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        var alive = Set<String>()
        for url in entries {
            alive.insert(url.path)
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let entry = NSMenuItem(title: formatter.string(from: created), action: nil, keyEquivalent: "")
            entry.image = menuThumbnail(for: url)
            let actions = NSMenu()
            for (title, selector) in [(L("Copiar", "Copy"), #selector(copyRecent(_:))), (L("Anotar…", "Annotate…"), #selector(annotateRecent(_:))),
                                      (L("Fijar en pantalla", "Pin on screen"), #selector(pinRecent(_:))),
                                      (L("Guardar como…", "Save as…"), #selector(saveRecent(_:))),
                                      (L("Mostrar en Finder", "Show in Finder"), #selector(revealRecent(_:)))] {
                let action = item(title, selector)
                action.representedObject = url
                actions.addItem(action)
            }
            entry.submenu = actions
            recentsMenu.addItem(entry)
        }
        thumbnailCache = thumbnailCache.filter { alive.contains($0.key) }
        recentsMenu.addItem(.separator())
        recentsMenu.addItem(item(L("Abrir carpeta del historial", "Open history folder"), #selector(openHistoryFolder)))
        let clear = item(L("Borrar historial", "Clear history"), #selector(clearHistory))
        clear.isEnabled = !entries.isEmpty
        recentsMenu.addItem(clear)
    }

    private func menuThumbnail(for url: URL) -> NSImage? {
        if let cached = thumbnailCache[url.path] { return cached }
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        let box = CGSize(width: 48, height: 32)
        let ratio = min(box.width / image.size.width, box.height / image.size.height)
        let size = CGSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))
        let thumbnail = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        thumbnailCache[url.path] = thumbnail
        return thumbnail
    }

    private func item(_ title: String, _ selector: Selector, action: ShortcutAction? = nil,
                      symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        if let symbol = symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        item.target = self
        if let action = action { actionItems[action] = item }
        return item
    }

    /// Shows each action's shortcut next to its menu item.
    private func refreshMenuShortcuts() {
        let shortcuts = Settings.hotKeys ? Settings.shortcuts : [:]
        for (action, item) in actionItems {
            if let shortcut = shortcuts[action], let key = shortcut.menuKeyEquivalent {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = shortcut.modifierMask
            } else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .annotateZone: capture(.selection, to: .annotate)
        case .copyZone: capture(.selection, to: .copy)
        case .saveZone: capture(.selection, to: .save)
        case .ocr: capture(.selection, to: .text)
        case .qr: capture(.selection, to: .qr)
        case .pinZone: capture(.selection, to: .pin)
        case .copyWindow: capture(.window, to: .copy)
        case .copyScreen: capture(.screen, to: .copy)
        case .colorPicker: pickColor()
        case .recordVideo: startRecording(gif: false)
        case .recordGIF: startRecording(gif: true)
        case .scrollCapture: startScrollCapture()
        case .ruler: showRuler()
        }
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        let code = sender.representedObject as? String ?? ""
        guard code != (UserDefaults.standard.string(forKey: Localization.key) ?? "") else { return }
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: Localization.key)
        } else {
            UserDefaults.standard.set(code, forKey: Localization.key)
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Reiniciar MacCap para cambiar el idioma", "Restart MacCap to change the language")
        alert.addButton(withTitle: L("Reiniciar ahora", "Restart now"))
        alert.addButton(withTitle: L("Más tarde", "Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this instance to quit, then open the app again.
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    @objc private func openShortcuts() {
        if shortcutsWindow == nil {
            let controller = ShortcutsWindowController()
            controller.onClose = { [weak self] in
                self?.shortcutsWindow = nil
                self?.applyHotKeys(reportFailures: true)
            }
            shortcutsWindow = controller
            HotKeyCenter.shared.unregisterAll() // so the combinations can be typed in the window
        }
        NSApp.activate(ignoringOtherApps: true)
        shortcutsWindow?.showWindow(nil)
        shortcutsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        item.isEnabled = false
        return item
    }

    /// Hidden main menu so ⌘Z, ⌘C, ⌘V, ⌘S and ⌘W work in the editor window.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: L("Salir de MacCap", "Quit MacCap"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: L("Archivo", "File"))
        fileMenu.addItem(NSMenuItem(title: L("Guardar…", "Save…"), action: #selector(AnnotationWindow.saveAnnotation(_:)), keyEquivalent: "s"))
        fileMenu.addItem(NSMenuItem(title: L("Cerrar", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Edición", "Edit"))
        editMenu.addItem(NSMenuItem(title: L("Deshacer", "Undo"), action: #selector(AnnotationWindow.undoAnnotation(_:)), keyEquivalent: "z"))
        let redo = NSMenuItem(title: L("Rehacer", "Redo"), action: #selector(AnnotationWindow.redoAnnotation(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: L("Cortar", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L("Copiar", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L("Pegar", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L("Seleccionar todo", "Select all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: - Menu actions

    @objc private func copySelection() { capture(.selection, to: .copy) }
    @objc private func copyWindow() { capture(.window, to: .copy) }
    @objc private func copyScreen() { capture(.screen, to: .copy) }
    @objc private func saveSelection() { capture(.selection, to: .save) }
    @objc private func saveWindow() { capture(.window, to: .save) }
    @objc private func saveScreen() { capture(.screen, to: .save) }
    @objc private func annotateSelection() { capture(.selection, to: .annotate) }
    @objc private func annotateWindow() { capture(.window, to: .annotate) }
    @objc private func annotateScreen() { capture(.screen, to: .annotate) }
    @objc private func recognizeText() { capture(.selection, to: .text) }
    @objc private func readQRCode() { capture(.selection, to: .qr) }
    @objc private func pinSelection() { capture(.selection, to: .pin) }

    @objc private func pickColor() {
        NSColorSampler().show { [weak self] color in
            guard let self = self, let rgb = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                             Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            self.flash(text: hex)
        }
    }

    // Recent captures (sender.representedObject is the file URL).
    @objc private func copyRecent(_ sender: NSMenuItem) { (sender.representedObject as? URL).map(copyFile(at:)) }
    @objc private func annotateRecent(_ sender: NSMenuItem) { (sender.representedObject as? URL).map(annotateImage(at:)) }
    @objc private func pinRecent(_ sender: NSMenuItem) { (sender.representedObject as? URL).map(pinFile(at:)) }
    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @objc private func saveRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let data = try? Data(contentsOf: url) else { return }
        save(data, alwaysAsk: true)
    }
    @objc private func openHistoryFolder() {
        try? FileManager.default.createDirectory(at: CaptureHistory.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(CaptureHistory.directory)
    }
    @objc private func clearHistory() {
        CaptureHistory.clear()
        thumbnailCache.removeAll()
    }

    private static func isImageFile(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "heic", "tiff"].contains(url.pathExtension.lowercased())
    }

    private func copyFile(at url: URL) {
        if Self.isImageFile(url), let data = try? Data(contentsOf: url) {
            copy(data)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        }
        flash()
    }

    private func annotateImage(at url: URL) {
        guard let data = try? Data(contentsOf: url), let document = AnnotationImage(data: data) else {
            showError(L("No se pudo abrir la imagen.", "The image could not be opened."), title: "Error")
            return
        }
        openEditor(document)
    }

    private func pinFile(at url: URL) {
        guard Self.isImageFile(url), let data = try? Data(contentsOf: url) else { return }
        pin(data)
    }

    private func pin(_ data: Data) {
        guard let image = NSImage(data: data), let bitmap = NSBitmapImageRep(data: data) else { return }
        let window = PinnedImageWindow(image: image, pointSize: bitmap.size)
        window.onClose = { [weak self, weak window] in self?.pinnedWindows.removeAll { $0 === window } }
        window.onCopy = { [weak self] image in
            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?
                    .representation(using: .png, properties: [:]) else { return }
            self?.copy(png)
            self?.flash()
        }
        window.onAnnotate = { [weak self] image in
            guard let document = AnnotationImage(image: image) else { return }
            self?.openEditor(document)
        }
        pinnedWindows.append(window)
        window.orderFrontRegardless()
        window.makeKey()
    }

    @objc private func annotateClipboard() {
        guard let image = NSImage(pasteboard: .general), let document = AnnotationImage(image: image) else {
            showError(L("El portapapeles no contiene ninguna imagen.", "The clipboard has no image."), title: L("No hay imagen", "No image"))
            return
        }
        openEditor(document)
    }

    @objc private func annotateFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let document = AnnotationImage(data: data)
                ?? NSImage(contentsOf: url).flatMap(AnnotationImage.init(image:)) else {
            showError(L("No se pudo abrir la imagen.", "The image could not be opened."), title: "Error")
            return
        }
        openEditor(document)
    }

    @objc private func openNativeToolbar() {
        let paths = ["/System/Applications/Utilities/Screenshot.app", "/Applications/Utilities/Screenshot.app"]
        if let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init(), completionHandler: nil)
        } else {
            showError(L("No se encontró la aplicación Captura de pantalla de macOS.", "The macOS Screenshot app was not found."), title: "Error")
        }
    }

    // MARK: - Recording, scrolling capture and ruler

    @objc private func showRuler() { ScreenOverlay.showRuler() }
    @objc private func recordVideo() { startRecording(gif: false) }
    @objc private func recordGIF() { startRecording(gif: true) }

    @objc private func stopActiveCapture() {
        if activeScroll != nil { stopScrollCapture() } else { stopRecording() }
    }

    private func startRecording(gif: Bool) {
        guard activeRecorder == nil, activeScroll == nil else { return }
        guard #available(macOS 12.3, *) else {
            showError(RecordingError.unsupported.localizedDescription, title: L("No se puede grabar", "Cannot record"))
            return
        }
        let prompt = (gif ? L("Arrastra para elegir la zona a grabar como GIF · Esc para cancelar", "Drag to choose the area to record as GIF · Esc to cancel")
                           : L("Arrastra para elegir la zona a grabar · Esc para cancelar", "Drag to choose the area to record · Esc to cancel"))
        ScreenOverlay.selectRegion(prompt: prompt) { [weak self] rect, screen in
            guard let self = self, let rect = rect, let screen = screen else { return }
            let movie = FileManager.default.temporaryDirectory.appendingPathComponent("MacCap-\(UUID().uuidString).mp4")
            let recorder = RegionRecorder(outputURL: movie)
            recorder.onUnexpectedStop = { [weak self] _ in self?.stopRecording() }
            self.activeRecorder = recorder
            self.recordingAsGIF = gif
            self.captureControls = CaptureControls(region: rect, color: .systemRed, buttonTitle: L("Detener", "Stop")) { [weak self] in
                self?.stopRecording()
            }
            self.setIcon("record.circle.fill")
            recorder.start(rect: rect, screen: screen, showsCursor: true) { [weak self] error in
                guard let error = error else { return }
                self?.endCaptureSession()
                self?.showError(error.localizedDescription, title: L("No se pudo grabar", "Could not record"))
            }
        }
    }

    private func stopRecording() {
        guard #available(macOS 12.3, *), let recorder = activeRecorder as? RegionRecorder else { return }
        activeRecorder = nil
        captureControls?.setStatus(L("Guardando…", "Saving…"))
        let gif = recordingAsGIF
        recorder.stop { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.endCaptureSession()
                self.showError(error.localizedDescription, title: L("No se pudo grabar", "Could not record"))
            case .success(let movie) where gif:
                self.captureControls?.setStatus(L("Creando GIF…", "Creating GIF…"))
                let output = movie.deletingPathExtension().appendingPathExtension("gif")
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try GIFExporter.convert(movie: movie, to: output) }
                    try? FileManager.default.removeItem(at: movie)
                    DispatchQueue.main.async {
                        self.endCaptureSession()
                        switch result {
                        case .success: self.deliverRecording(output)
                        case .failure(let error): self.showError(error.localizedDescription, title: L("No se pudo crear el GIF", "Could not create the GIF"))
                        }
                    }
                }
            case .success(let movie):
                self.endCaptureSession()
                self.deliverRecording(movie)
            }
        }
    }

    /// Moves a finished recording to the captures folder and shows its thumbnail.
    private func deliverRecording(_ temporary: URL) {
        let name = CaptureNaming.fileName(for: Date(), extension: temporary.pathExtension, prefix: L("Grabación", "Recording"))
        let destination = CaptureNaming.uniqueURL(in: Settings.saveFolder, name: name)
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            showError(error.localizedDescription, title: L("No se pudo guardar la grabación", "Could not save the recording"))
            return
        }
        flash()
        var preview: NSImage?
        if destination.pathExtension == "gif" {
            preview = NSImage(contentsOf: destination)
        } else {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
            generator.appliesPreferredTrackTransform = true
            preview = (try? generator.copyCGImage(at: .zero, actualTime: nil)).map { NSImage(cgImage: $0, size: .zero) }
        }
        if Settings.showThumbnail, let preview = preview {
            thumbnail.show(fileURL: destination, preview: preview)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    @objc private func startScrollCapture() {
        guard activeRecorder == nil, activeScroll == nil else { return }
        guard #available(macOS 12.3, *) else {
            showError(RecordingError.unsupported.localizedDescription, title: L("No se puede capturar", "Cannot capture"))
            return
        }
        let prompt = L("Elige la zona que se desplaza (p. ej. el contenido de la página) · Esc para cancelar", "Choose the area that scrolls (e.g. the page content) · Esc to cancel")
        ScreenOverlay.selectRegion(prompt: prompt) { [weak self] rect, screen in
            guard let self = self, let rect = rect, let screen = screen else { return }
            let capture = ScrollCapture()
            let scale = screen.backingScaleFactor
            self.scrollScale = scale
            self.activeScroll = capture
            let controls = CaptureControls(region: rect, color: .systemBlue, buttonTitle: L("Terminar", "Finish")) { [weak self] in
                self?.stopScrollCapture()
            }
            controls.setStatus(L("Desplázate despacio hacia abajo", "Scroll down slowly"))
            self.captureControls = controls
            capture.onProgress = { [weak controls] height, lost in
                controls?.setStatus(lost ? L("Más despacio…", "Slower…") : "\(Int(CGFloat(height) / scale)) pt")
            }
            capture.onUnexpectedStop = { [weak self] _ in self?.stopScrollCapture() }
            self.setIcon("arrow.down.doc.fill")
            capture.start(rect: rect, screen: screen) { [weak self] error in
                guard let error = error else { return }
                self?.endCaptureSession()
                self?.showError(error.localizedDescription, title: L("No se pudo capturar", "Could not capture"))
            }
        }
    }

    private func stopScrollCapture() {
        guard #available(macOS 12.3, *), let capture = activeScroll as? ScrollCapture else { return }
        let scale = scrollScale
        activeScroll = nil
        captureControls?.setStatus(L("Uniendo…", "Stitching…"))
        capture.stop { [weak self] image in
            guard let self = self else { return }
            self.endCaptureSession()
            guard let image = image else {
                self.showError(L("No se capturó ninguna imagen.", "No image was captured."), title: L("Captura con scroll", "Scrolling capture"))
                return
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            bitmap.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            guard let png = bitmap.representation(using: .png, properties: [:]),
                  let document = AnnotationImage(data: png) else { return }
            self.record(png)
            self.openEditor(document)
        }
    }

    private func endCaptureSession() {
        captureControls?.close()
        captureControls = nil
        activeRecorder = nil
        activeScroll = nil
        setIcon("camera.viewfinder")
    }

    @objc private func openSaveFolder() { NSWorkspace.shared.open(Settings.saveFolder) }

    @objc private func openPermissionSettings() { showPermissionHelp(atLaunch: false) }

    /// Explains the permission and offers to reset it. Resetting fixes the common case where the
    /// entry in System Settings belongs to an older build with a different signature: it looks
    /// enabled, but macOS doesn't apply it to the current app.
    private func showPermissionHelp(atLaunch: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("MacCap necesita permiso de grabación de pantalla", "MacCap needs screen recording permission")
        alert.informativeText = L("""
        1. Pulsa «Restablecer y abrir Ajustes».
        2. Activa MacCap en la lista y, cuando macOS lo ofrezca, elige «Salir y volver a abrir».

        Si MacCap ya aparecía activada, ese permiso es de una versión anterior con otra firma y macOS no lo aplica. \
        Al restablecer se borra para que puedas concederlo de nuevo.
        """, """
        1. Click “Reset and open Settings”.
        2. Turn MacCap on in the list and, when macOS offers it, choose “Quit & Reopen”.

        If MacCap already looked enabled, that permission belongs to an older version with a different signature, \
        so macOS doesn't apply it. Resetting removes it so you can grant it again.
        """)
        alert.addButton(withTitle: L("Restablecer y abrir Ajustes", "Reset and open Settings"))
        alert.addButton(withTitle: L("Solo abrir Ajustes", "Just open Settings"))
        alert.addButton(withTitle: L("Ahora no", "Not now"))
        if atLaunch {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L("No avisar al abrir MacCap", "Don't warn when MacCap opens")
        }
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { Settings.suppressPermissionAlert = true }
        switch response {
        case .alertFirstButtonReturn:
            resetScreenCapturePermission()
            CGRequestScreenCaptureAccess()
            openScreenRecordingSettings()
        case .alertSecondButtonReturn:
            CGRequestScreenCaptureAccess()
            openScreenRecordingSettings()
        default:
            break
        }
    }

    private func resetScreenCapturePermission() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", Bundle.main.bundleIdentifier ?? "com.srCrowder.mac-cap"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("MacCap: tccutil falló: %@", error.localizedDescription)
        }
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func setDelay(_ sender: NSMenuItem) { Settings.delay = sender.tag }
    @objc private func toggleCursor() { Settings.cursor.toggle() }
    @objc private func toggleShadow() { Settings.windowShadow.toggle() }
    @objc private func toggleSound() { Settings.sound.toggle() }
    @objc private func toggleAsk() { Settings.askWhereToSave.toggle() }
    @objc private func toggleThumbnail() { Settings.showThumbnail.toggle() }
    @objc private func toggleHistory() { Settings.keepHistory.toggle() }
    @objc private func setFormat(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let format = ImageFormat(rawValue: raw) { Settings.format = format }
    }

    @objc private func toggleHotKeys() {
        Settings.hotKeys.toggle()
        applyHotKeys()
    }

    @objc private func toggleAutoUpdate() { updater.installsAutomatically.toggle() }

    @objc private func toggleLoginItem() {
        do { try LoginItem.setEnabled(!LoginItem.isEnabled) }
        catch { showError(error.localizedDescription, title: L("No se pudo cambiar el inicio automático", "Could not change open at login")) }
    }

    @objc private func chooseSaveFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.saveFolder
        panel.prompt = L("Elegir", "Choose")
        panel.message = L("Carpeta donde se guardarán las capturas", "Folder where screenshots will be saved")
        if panel.runModal() == .OK, let url = panel.url { Settings.saveFolder = url }
    }

    private func applyHotKeys(reportFailures: Bool = false) {
        guard Settings.hotKeys, shortcutsWindow == nil else {
            HotKeyCenter.shared.unregisterAll()
            return
        }
        let shortcuts = Settings.shortcuts
        let actions = ShortcutAction.allCases.filter { shortcuts[$0] != nil }
        let hotKeys = actions.enumerated().map { index, action -> HotKey in
            let shortcut = shortcuts[action]!
            return HotKey(id: UInt32(index + 1), keyCode: shortcut.keyCode, carbonModifiers: shortcut.carbonModifiers) {
                [weak self] in self?.perform(action)
            }
        }
        let failed = HotKeyCenter.shared.register(hotKeys).compactMap { id -> String? in
            let index = Int(id) - 1
            guard actions.indices.contains(index), let shortcut = shortcuts[actions[index]] else { return nil }
            return "\(shortcut.displayString) (\(actions[index].title))"
        }
        guard !failed.isEmpty else { return }
        NSLog("MacCap: no se pudieron registrar los atajos %@", failed.joined(separator: ", "))
        if reportFailures {
            showError(L("Otra aplicación ya usa estas combinaciones:", "Another app already uses these combinations:") + "\n\(failed.joined(separator: "\n"))\n\n" + L("Elige otras en Opciones → Configurar atajos.", "Choose others in Options → Configure shortcuts."),
                      title: L("Algunos atajos no están disponibles", "Some shortcuts are not available"))
        }
    }

    // MARK: - Capture

    func capture(_ mode: CaptureMode, to destination: Destination) {
        guard !captureInProgress else { return }
        captureInProgress = true
        let options = CaptureOptions(mode: mode, delay: Settings.delay, cursor: Settings.cursor,
                                     windowShadow: Settings.windowShadow, sound: Settings.sound)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.runScreencapture(options)
            var recognized: Result<[String], Error>?
            if destination == .text || destination == .qr, case .success(let data?) = result {
                recognized = Result {
                    guard let cgImage = NSBitmapImageRep(data: data)?.cgImage else { throw CaptureError.invalidImage }
                    if destination == .qr { return try BarcodeReader.read(cgImage) }
                    let text = try TextRecognizer.recognize(cgImage)
                    return text.isEmpty ? [] : [text]
                }
            }
            DispatchQueue.main.async {
                self.captureInProgress = false
                switch result {
                case .failure(let error):
                    self.showError(error.localizedDescription)
                case .success(nil):
                    break // cancelled by the user
                case .success(let data?):
                    self.deliver(data, to: destination, recognized: recognized)
                }
            }
        }
    }

    private func deliver(_ data: Data, to destination: Destination, recognized: Result<[String], Error>?) {
        switch destination {
        case .save:
            let fileURL = record(data)
            if save(data) {
                flash()
                showThumbnail(fileURL)
            }
        case .copy:
            let fileURL = record(data)
            copy(data)
            flash()
            showThumbnail(fileURL)
        case .pin:
            record(data)
            pin(data)
        case .qr:
            switch recognized {
            case .success(let codes)? where !codes.isEmpty:
                let text = codes.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                if codes.count == 1, let url = URL(string: codes[0]), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = L("Enlace copiado", "Link copied")
                    alert.informativeText = codes[0]
                    alert.addButton(withTitle: L("Abrir enlace", "Open link"))
                    alert.addButton(withTitle: L("Cerrar", "Close"))
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
                } else {
                    flash()
                }
            case .failure(let error)?:
                showError(error.localizedDescription, title: L("No se pudo leer el código", "Could not read the code"))
            default:
                showError(L("No se ha encontrado ningún código QR o de barras en la zona seleccionada.", "No QR code or barcode was found in the selected area."), title: L("Sin códigos", "No codes"))
            }
        case .annotate:
            record(data)
            guard let document = AnnotationImage(data: data) else {
                showError(CaptureError.invalidImage.localizedDescription)
                return
            }
            openEditor(document)
        case .text:
            switch recognized {
            case .success(let texts)? where !texts.isEmpty:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(texts.joined(separator: "\n"), forType: .string)
                flash()
            case .failure(let error)?:
                showError(error.localizedDescription, title: L("No se pudo reconocer el texto", "Could not recognize the text"))
            default:
                showError(L("No se ha encontrado texto en la zona seleccionada.", "No text was found in the selected area."), title: L("Sin texto", "No text"))
            }
        }
    }

    /// Returns the PNG data, `nil` if the user cancelled, or an error.
    nonisolated private static func runScreencapture(_ options: CaptureOptions) -> Result<Data?, Error> {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            let output = directory.appendingPathComponent("capture.png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = options.arguments(output: output.path)
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard fileManager.fileExists(atPath: output.path) else {
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus != 0, !message.isEmpty {
                    return .failure(CaptureError.screencapture(message))
                }
                return .success(nil)
            }
            let data = try Data(contentsOf: output)
            guard NSBitmapImageRep(data: data) != nil else { throw CaptureError.invalidImage }
            return .success(data)
        } catch {
            return .failure(error)
        }
    }

    private enum CaptureError: LocalizedError {
        case invalidImage
        case screencapture(String)

        var errorDescription: String? {
            switch self {
            case .invalidImage: return L("No se pudo leer la captura.", "Could not read the screenshot.")
            case .screencapture(let message): return message
            }
        }
    }

    // MARK: - Output

    private func openEditor(_ document: AnnotationImage) {
        let editor = AnnotationWindowController(document: document, save: { [weak self] data in
            guard let self = self, self.save(data, alwaysAsk: true) else { return false }
            self.record(data)
            return true
        }, copy: { [weak self] data in
            self?.record(data)
            self?.copy(data)
            self?.flash()
        })
        editor.onClose = { [weak self, weak editor] in
            self?.editors.removeAll { $0 === editor }
        }
        editors.append(editor)
        NSApp.activate(ignoringOtherApps: true)
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
    }

    /// Adds a capture to the history (or a temporary file when the history is off) and returns its URL,
    /// used by the floating thumbnail.
    @discardableResult
    private func record(_ png: Data) -> URL? {
        if Settings.keepHistory { return CaptureHistory.add(png) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacCap", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = CaptureNaming.uniqueURL(in: directory, name: CaptureNaming.fileName(for: Date()))
        return (try? png.write(to: url, options: .atomic)).map { url }
    }

    private func showThumbnail(_ url: URL?) {
        guard Settings.showThumbnail, let url = url else { return }
        thumbnail.show(fileURL: url)
    }

    /// Saves PNG data in the chosen format.
    @discardableResult
    private func save(_ png: Data, alwaysAsk: Bool = false) -> Bool {
        let format = Settings.format
        guard let data = ImageExporter.data(fromPNG: png, format: format) else {
            showError(L("No se pudo convertir la imagen a ", "Could not convert the image to ") + format.fileExtension.uppercased() + ".",
                      title: L("No se pudo guardar la captura", "Could not save the screenshot"))
            return false
        }
        let name = CaptureNaming.fileName(for: Date(), extension: format.fileExtension)
        let url: URL
        if alwaysAsk || Settings.askWhereToSave {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.directoryURL = Settings.saveFolder
            panel.allowedContentTypes = [UTType(format.typeIdentifier) ?? .png]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            url = chosen
        } else {
            url = CaptureNaming.uniqueURL(in: Settings.saveFolder, name: name)
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            showError(error.localizedDescription, title: L("No se pudo guardar la captura", "Could not save the screenshot"))
            return false
        }
    }

    private func copy(_ data: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var ok = pasteboard.setData(data, forType: .png)
        if let tiff = NSImage(data: data)?.tiffRepresentation {
            ok = pasteboard.setData(tiff, forType: .tiff) || ok
        }
        if !ok { showError(L("No se pudo copiar la captura al portapapeles.", "Could not copy the screenshot to the clipboard.")) }
    }

    // MARK: - Feedback

    private func setIcon(_ symbol: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacCap")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    /// Briefly shows a check mark (and optional text) in the menu bar to confirm an action.
    private func flash(text: String? = nil) {
        restoreIconWork?.cancel()
        setIcon("checkmark.circle.fill")
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.title = text.map { " \($0)" } ?? ""
        let work = DispatchWorkItem { [weak self] in
            self?.setIcon("camera.viewfinder")
            self?.statusItem.button?.title = ""
        }
        restoreIconWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (text == nil ? 1.2 : 3), execute: work)
    }

    private func showError(_ message: String, title: String = L("No se pudo realizar la captura", "Could not take the screenshot")) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
#else
@main
struct MacCap {
    static func main() {
        print(L("MacCap requiere macOS.", "MacCap requires macOS."))
    }
}
#endif
