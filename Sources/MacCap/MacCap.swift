import Foundation

enum CaptureMode {
    case screen, selection, window
}

struct CaptureOptions {
    var mode: CaptureMode
    var delay = false
    var cursor = false

    func arguments(output: String) -> [String] {
        var result = ["-x"]
        switch mode {
        case .screen: result.append("-m")
        case .selection: result += ["-i", "-s"]
        case .window: result += ["-i", "-w"]
        }
        if delay { result += ["-T", "5"] }
        if cursor { result.append("-C") }
        return result + [output]
    }
}

enum AnnotationGeometry {
    static func imageRect(image: CGSize, in bounds: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func rectangle(from start: CGPoint, to end: CGPoint, in imageRect: CGRect) -> CGRect? {
        guard imageRect.width > 0, imageRect.height > 0, imageRect.contains(start) else { return nil }
        let x = min(max(end.x, imageRect.minX), imageRect.maxX)
        let y = min(max(end.y, imageRect.minY), imageRect.maxY)
        let left = min(start.x, x)
        let top = min(start.y, y)
        let width = abs(start.x - x)
        let height = abs(start.y - y)
        guard width >= 2, height >= 2 else { return nil }
        return CGRect(x: (left - imageRect.minX) / imageRect.width,
                      y: (top - imageRect.minY) / imageRect.height,
                      width: width / imageRect.width, height: height / imageRect.height)
    }

    static func project(_ rectangle: CGRect, into bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + rectangle.minX * bounds.width,
               y: bounds.minY + rectangle.minY * bounds.height,
               width: rectangle.width * bounds.width, height: rectangle.height * bounds.height)
    }
}

#if os(macOS)
import AppKit

@main
struct MacCap {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var delayItem: NSMenuItem!
    private var cursorItem: NSMenuItem!
    private var captureInProgress = false
    private var editors: [AnnotationWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "MacCap")
        statusItem.button?.toolTip = "MacCap"

        let menu = NSMenu()
        addCaptureItems(to: menu, destination: "Guardar", selector: #selector(saveCapture(_:)))
        menu.addItem(.separator())
        addCaptureItems(to: menu, destination: "Copiar", selector: #selector(copyCapture(_:)))
        menu.addItem(.separator())
        let edit = NSMenuItem(title: "Capturar zona y añadir rectángulos…", action: #selector(editCapture), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        menu.addItem(.separator())
        delayItem = NSMenuItem(title: "Retardo de 5 segundos", action: #selector(toggleOption(_:)), keyEquivalent: "")
        delayItem.target = self
        menu.addItem(delayItem)
        cursorItem = NSMenuItem(title: "Incluir cursor", action: #selector(toggleOption(_:)), keyEquivalent: "")
        cursorItem.target = self
        menu.addItem(cursorItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Salir de MacCap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func addCaptureItems(to menu: NSMenu, destination: String, selector: Selector) {
        for (index, title) in ["pantalla principal", "zona", "ventana"].enumerated() {
            let item = NSMenuItem(title: "\(destination) \(title)…", action: selector, keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
    }

    @objc private func toggleOption(_ sender: NSMenuItem) {
        sender.state = sender.state == .on ? .off : .on
    }

    @objc private func saveCapture(_ sender: NSMenuItem) { capture(mode: mode(for: sender.tag), destination: .save) }
    @objc private func copyCapture(_ sender: NSMenuItem) { capture(mode: mode(for: sender.tag), destination: .copy) }
    @objc private func editCapture() { capture(mode: .selection, destination: .edit) }

    private func mode(for tag: Int) -> CaptureMode {
        switch tag {
        case 1: return .selection
        case 2: return .window
        default: return .screen
        }
    }

    private enum Destination { case save, copy, edit }

    private func capture(mode: CaptureMode, destination: Destination) {
        guard !captureInProgress else { return }
        captureInProgress = true
        let options = CaptureOptions(mode: mode, delay: delayItem.state == .on, cursor: cursorItem.state == .on)
        DispatchQueue.global(qos: .userInitiated).async {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: directory)
                DispatchQueue.main.async { self.captureInProgress = false }
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
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
                guard process.terminationStatus == 0 else {
                    if let message = String(data: errorData, encoding: .utf8), !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DispatchQueue.main.async { self.showError(message) }
                    }
                    return
                }
                let data = try Data(contentsOf: output)
                guard NSImage(data: data) != nil else { throw CaptureError.invalidImage }
                DispatchQueue.main.async {
                    switch destination {
                    case .save: self.save(data)
                    case .copy: self.copy(data)
                    case .edit:
                        let editor = AnnotationWindowController(data: data, save: self.save, copy: self.copy)
                        editor.onClose = { [weak self, weak editor] in
                            self?.editors.removeAll { $0 === editor }
                        }
                        self.editors.append(editor)
                        editor.showWindow(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            } catch {
                DispatchQueue.main.async { self.showError(error.localizedDescription) }
            }
        }
    }

    private enum CaptureError: LocalizedError {
        case invalidImage
        var errorDescription: String? { "No se pudo leer la captura." }
    }

    private func save(_ data: Data) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Captura.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) }
        catch { showError(error.localizedDescription) }
    }

    private func copy(_ data: Data) {
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setData(data, forType: .png) {
            showError("No se pudo copiar la captura al portapapeles.")
        }
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "No se pudo realizar la captura"
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
