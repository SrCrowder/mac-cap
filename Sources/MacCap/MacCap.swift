#if os(macOS)
import AppKit
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
enum Destination { case save, copy, annotate, text }

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

    private lazy var hotKeys: [HotKey] = [
        HotKey(id: 1, keyCode: kVK_ANSI_7, carbonModifiers: cmdKey | shiftKey, keyEquivalent: "7",
               modifierMask: [.command, .shift]) { [weak self] in self?.capture(.selection, to: .annotate) },
        HotKey(id: 2, keyCode: kVK_ANSI_8, carbonModifiers: cmdKey | shiftKey, keyEquivalent: "8",
               modifierMask: [.command, .shift]) { [weak self] in self?.capture(.selection, to: .copy) },
        HotKey(id: 3, keyCode: kVK_ANSI_9, carbonModifiers: cmdKey | shiftKey, keyEquivalent: "9",
               modifierMask: [.command, .shift]) { [weak self] in self?.capture(.selection, to: .text) }
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("camera.viewfinder")
        statusItem.button?.toolTip = "MacCap – capturas de pantalla"
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

        permissionItem = item("⚠️ Conceder permiso de grabación de pantalla…", #selector(openPermissionSettings))
        permissionSeparator = .separator()
        menu.addItem(permissionItem)
        menu.addItem(permissionSeparator)

        menu.addItem(header("Copiar al portapapeles"))
        menu.addItem(item("Zona…", #selector(copySelection), hotKey: hotKeys[1], symbol: "rectangle.dashed"))
        menu.addItem(item("Ventana…", #selector(copyWindow), symbol: "macwindow"))
        menu.addItem(item("Pantalla completa", #selector(copyScreen), symbol: "display"))
        menu.addItem(.separator())

        menu.addItem(header("Guardar en archivo"))
        menu.addItem(item("Zona…", #selector(saveSelection), symbol: "rectangle.dashed"))
        menu.addItem(item("Ventana…", #selector(saveWindow), symbol: "macwindow"))
        menu.addItem(item("Pantalla completa", #selector(saveScreen), symbol: "display"))
        menu.addItem(.separator())

        menu.addItem(header("Anotar (formas, flechas, texto…)"))
        menu.addItem(item("Zona y anotar…", #selector(annotateSelection), hotKey: hotKeys[0], symbol: "pencil.and.outline"))
        menu.addItem(item("Ventana y anotar…", #selector(annotateWindow), symbol: "macwindow.badge.plus"))
        menu.addItem(item("Pantalla completa y anotar", #selector(annotateScreen), symbol: "display"))
        menu.addItem(item("Anotar imagen del portapapeles", #selector(annotateClipboard), symbol: "doc.on.clipboard"))
        menu.addItem(item("Anotar imagen de un archivo…", #selector(annotateFile), symbol: "photo"))
        menu.addItem(.separator())

        menu.addItem(header("Extras"))
        menu.addItem(item("Copiar texto de una zona (OCR)…", #selector(recognizeText), hotKey: hotKeys[2], symbol: "text.viewfinder"))
        menu.addItem(item("Grabar pantalla / herramienta nativa…", #selector(openNativeToolbar), symbol: "record.circle"))
        menu.addItem(item("Abrir carpeta de capturas", #selector(openSaveFolder), symbol: "folder"))
        menu.addItem(.separator())

        let options = NSMenuItem(title: "Opciones", action: nil, keyEquivalent: "")
        options.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        options.submenu = buildOptionsMenu()
        menu.addItem(options)
        let check = NSMenuItem(title: "Buscar actualizaciones…", action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "")
        check.target = updater
        check.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        check.isHidden = !updater.isAvailable
        menu.addItem(check)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir de MacCap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func buildOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let delayMenu = NSMenu()
        for seconds in [0, 3, 5, 10] {
            let entry = item(seconds == 0 ? "Sin retardo" : "\(seconds) segundos", #selector(setDelay(_:)))
            entry.tag = seconds
            delayMenu.addItem(entry)
            delayItems.append(entry)
        }
        let delay = NSMenuItem(title: "Retardo antes de capturar", action: nil, keyEquivalent: "")
        delay.submenu = delayMenu
        menu.addItem(delay)

        cursorItem = item("Incluir el cursor (pantalla completa)", #selector(toggleCursor))
        shadowItem = item("Sombra en capturas de ventana", #selector(toggleShadow))
        soundItem = item("Sonido de obturador", #selector(toggleSound))
        [cursorItem, shadowItem, soundItem].forEach { menu.addItem($0) }
        menu.addItem(.separator())

        folderItem = item("", #selector(chooseSaveFolder))
        askItem = item("Preguntar dónde guardar cada vez", #selector(toggleAsk))
        menu.addItem(folderItem)
        menu.addItem(askItem)
        menu.addItem(.separator())

        hotKeysItem = item("Atajos globales (⇧⌘7, ⇧⌘8, ⇧⌘9)", #selector(toggleHotKeys))
        menu.addItem(hotKeysItem)
        loginItem = item("Abrir al iniciar sesión", #selector(toggleLoginItem))
        loginItem.isHidden = !LoginItem.isSupported
        menu.addItem(loginItem)
        autoUpdateItem = item("Instalar actualizaciones sin preguntar", #selector(toggleAutoUpdate))
        autoUpdateItem.isHidden = !updater.isAvailable
        menu.addItem(autoUpdateItem)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        let granted = CGPreflightScreenCaptureAccess()
        permissionItem.isHidden = granted
        permissionSeparator.isHidden = granted
        let delay = Settings.delay
        delayItems.forEach { $0.state = $0.tag == delay ? .on : .off }
        cursorItem.state = Settings.cursor ? .on : .off
        shadowItem.state = Settings.windowShadow ? .on : .off
        soundItem.state = Settings.sound ? .on : .off
        askItem.state = Settings.askWhereToSave ? .on : .off
        folderItem.title = "Guardar en: \(FileManager.default.displayName(atPath: Settings.saveFolder.path))…"
        hotKeysItem.state = Settings.hotKeys ? .on : .off
        loginItem.state = LoginItem.isEnabled ? .on : .off
        autoUpdateItem.state = updater.installsAutomatically ? .on : .off
    }

    private func item(_ title: String, _ action: Selector, hotKey: HotKey? = nil, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: hotKey?.keyEquivalent ?? "")
        if let hotKey = hotKey { item.keyEquivalentModifierMask = hotKey.modifierMask }
        if let symbol = symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        item.target = self
        return item
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
        appMenu.addItem(NSMenuItem(title: "Salir de MacCap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Archivo")
        fileMenu.addItem(NSMenuItem(title: "Guardar…", action: #selector(AnnotationWindow.saveAnnotation(_:)), keyEquivalent: "s"))
        fileMenu.addItem(NSMenuItem(title: "Cerrar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edición")
        editMenu.addItem(NSMenuItem(title: "Deshacer", action: #selector(AnnotationWindow.undoAnnotation(_:)), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Rehacer", action: #selector(AnnotationWindow.redoAnnotation(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
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

    @objc private func annotateClipboard() {
        guard let image = NSImage(pasteboard: .general), let document = AnnotationImage(image: image) else {
            showError("El portapapeles no contiene ninguna imagen.", title: "No hay imagen")
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
            showError("No se pudo abrir la imagen.", title: "Error")
            return
        }
        openEditor(document)
    }

    @objc private func openNativeToolbar() {
        let paths = ["/System/Applications/Utilities/Screenshot.app", "/Applications/Utilities/Screenshot.app"]
        if let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init(), completionHandler: nil)
        } else {
            showError("No se encontró la aplicación Captura de pantalla de macOS.", title: "Error")
        }
    }

    @objc private func openSaveFolder() { NSWorkspace.shared.open(Settings.saveFolder) }

    @objc private func openPermissionSettings() { showPermissionHelp(atLaunch: false) }

    /// Explains the permission and offers to reset it. Resetting fixes the common case where the
    /// entry in System Settings belongs to an older build with a different signature: it looks
    /// enabled, but macOS doesn't apply it to the current app.
    private func showPermissionHelp(atLaunch: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MacCap necesita permiso de grabación de pantalla"
        alert.informativeText = """
        1. Pulsa «Restablecer y abrir Ajustes».
        2. Activa MacCap en la lista y, cuando macOS lo ofrezca, elige «Salir y volver a abrir».

        Si MacCap ya aparecía activada, ese permiso es de una versión anterior con otra firma y macOS no lo aplica. \
        Al restablecer se borra para que puedas concederlo de nuevo.
        """
        alert.addButton(withTitle: "Restablecer y abrir Ajustes")
        alert.addButton(withTitle: "Solo abrir Ajustes")
        alert.addButton(withTitle: "Ahora no")
        if atLaunch {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "No avisar al abrir MacCap"
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

    @objc private func toggleHotKeys() {
        Settings.hotKeys.toggle()
        applyHotKeys()
    }

    @objc private func toggleAutoUpdate() { updater.installsAutomatically.toggle() }

    @objc private func toggleLoginItem() {
        do { try LoginItem.setEnabled(!LoginItem.isEnabled) }
        catch { showError(error.localizedDescription, title: "No se pudo cambiar el inicio automático") }
    }

    @objc private func chooseSaveFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.saveFolder
        panel.prompt = "Elegir"
        panel.message = "Carpeta donde se guardarán las capturas"
        if panel.runModal() == .OK, let url = panel.url { Settings.saveFolder = url }
    }

    private func applyHotKeys() {
        guard Settings.hotKeys else {
            HotKeyCenter.shared.unregisterAll()
            return
        }
        let failed = HotKeyCenter.shared.register(hotKeys)
        if !failed.isEmpty {
            NSLog("MacCap: no se pudieron registrar los atajos %@", failed.map(String.init).joined(separator: ", "))
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
            var recognized: Result<String, Error>?
            if destination == .text, case .success(let data?) = result {
                recognized = Result {
                    guard let cgImage = NSBitmapImageRep(data: data)?.cgImage else { throw CaptureError.invalidImage }
                    return try TextRecognizer.recognize(cgImage)
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

    private func deliver(_ data: Data, to destination: Destination, recognized: Result<String, Error>?) {
        switch destination {
        case .save:
            if save(data) { flash() }
        case .copy:
            copy(data)
            flash()
        case .annotate:
            guard let document = AnnotationImage(data: data) else {
                showError(CaptureError.invalidImage.localizedDescription)
                return
            }
            openEditor(document)
        case .text:
            switch recognized {
            case .success(let text)? where !text.isEmpty:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                flash()
            case .failure(let error)?:
                showError(error.localizedDescription, title: "No se pudo reconocer el texto")
            default:
                showError("No se ha encontrado texto en la zona seleccionada.", title: "Sin texto")
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
            case .invalidImage: return "No se pudo leer la captura."
            case .screencapture(let message): return message
            }
        }
    }

    // MARK: - Output

    private func openEditor(_ document: AnnotationImage) {
        let editor = AnnotationWindowController(document: document, save: { [weak self] data in
            self?.save(data, alwaysAsk: true) ?? false
        }, copy: { [weak self] data in
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

    @discardableResult
    private func save(_ data: Data, alwaysAsk: Bool = false) -> Bool {
        let name = CaptureNaming.fileName(for: Date())
        let url: URL
        if alwaysAsk || Settings.askWhereToSave {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.directoryURL = Settings.saveFolder
            panel.allowedContentTypes = [.png]
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
            showError(error.localizedDescription, title: "No se pudo guardar la captura")
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
        if !ok { showError("No se pudo copiar la captura al portapapeles.") }
    }

    // MARK: - Feedback

    private func setIcon(_ symbol: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacCap")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    /// Briefly shows a check mark in the menu bar to confirm a copy or save.
    private func flash() {
        restoreIconWork?.cancel()
        setIcon("checkmark.circle.fill")
        let work = DispatchWorkItem { [weak self] in self?.setIcon("camera.viewfinder") }
        restoreIconWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func showError(_ message: String, title: String = "No se pudo realizar la captura") {
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
        print("MacCap requiere macOS.")
    }
}
#endif
