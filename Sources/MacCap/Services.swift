#if os(macOS)
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import ImageIO
import Vision

// MARK: - Settings

enum Settings {
    private static let defaults = UserDefaults.standard

    static var delay: Int {
        get { defaults.integer(forKey: "delay") }
        set { defaults.set(newValue, forKey: "delay") }
    }
    static var cursor: Bool {
        get { defaults.bool(forKey: "cursor") }
        set { defaults.set(newValue, forKey: "cursor") }
    }
    static var windowShadow: Bool {
        get { defaults.object(forKey: "windowShadow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "windowShadow") }
    }
    static var sound: Bool {
        get { defaults.bool(forKey: "sound") }
        set { defaults.set(newValue, forKey: "sound") }
    }
    static var askWhereToSave: Bool {
        get { defaults.bool(forKey: "askWhereToSave") }
        set { defaults.set(newValue, forKey: "askWhereToSave") }
    }
    static var format: ImageFormat {
        get { ImageFormat(rawValue: defaults.string(forKey: "format") ?? "") ?? .png }
        set { defaults.set(newValue.rawValue, forKey: "format") }
    }
    static var showThumbnail: Bool {
        get { defaults.object(forKey: "showThumbnail") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showThumbnail") }
    }
    static var keepHistory: Bool {
        get { defaults.object(forKey: "keepHistory") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepHistory") }
    }
    /// User changes to the default shortcuts (`nil` value = shortcut removed).
    static var shortcutOverrides: [ShortcutAction: Shortcut?] {
        get {
            guard let data = defaults.data(forKey: "shortcuts"),
                  let raw = try? JSONDecoder().decode([String: Shortcut?].self, from: data) else { return [:] }
            var result: [ShortcutAction: Shortcut?] = [:]
            for (key, value) in raw {
                if let action = ShortcutAction(rawValue: key) { result[action] = .some(value) }
            }
            return result
        }
        set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            defaults.set(try? JSONEncoder().encode(raw), forKey: "shortcuts")
        }
    }
    static var shortcuts: [ShortcutAction: Shortcut] { ShortcutMap.resolve(shortcutOverrides) }
    static var suppressPermissionAlert: Bool {
        get { defaults.bool(forKey: "suppressPermissionAlert") }
        set { defaults.set(newValue, forKey: "suppressPermissionAlert") }
    }
    static var hotKeys: Bool {
        get { defaults.object(forKey: "hotKeys") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hotKeys") }
    }
    static var saveFolder: URL {
        get {
            if let path = defaults.string(forKey: "saveFolder"), FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        set { defaults.set(newValue.path, forKey: "saveFolder") }
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var isSupported: Bool {
        if #available(macOS 13, *) { return true }
        return false
    }

    static var isEnabled: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13, *) else { return }
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

// MARK: - Text recognition

enum TextRecognizer {
    /// Recognises text synchronously. Call from a background queue.
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13, *) {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = ["es-ES", "en-US"]
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

// MARK: - Image export

enum ImageExporter {
    /// Converts PNG data to `format`, keeping the DPI (so Retina captures keep their size).
    /// JPEG has no transparency, so it is flattened onto white first.
    static func data(fromPNG png: Data, format: ImageFormat) -> Data? {
        if format == .png { return png }
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        if format == .jpeg, let flattened = flatten(image) { image = flattened }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.typeIdentifier as CFString, 1, nil)
        else { return nil }
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let dpi = properties[kCGImagePropertyDPIWidth] {
            options[kCGImagePropertyDPIWidth] = dpi
            options[kCGImagePropertyDPIHeight] = properties[kCGImagePropertyDPIHeight] ?? dpi
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func flatten(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}

// MARK: - QR and barcodes

enum BarcodeReader {
    /// Payloads of every QR/barcode found. Call from a background queue.
    static func read(_ image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var seen = Set<String>()
        return (request.results ?? []).compactMap { $0.payloadStringValue }.filter { seen.insert($0).inserted }
    }
}

// MARK: - History

/// Keeps the latest captures in ~/Library/Application Support/MacCap/History.
enum CaptureHistory {
    static let limit = 20

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MacCap/History", isDirectory: true)
    }

    @discardableResult
    static func add(_ png: Data) -> URL? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = CaptureNaming.uniqueURL(in: directory, name: CaptureNaming.fileName(for: Date()))
            try png.write(to: url, options: .atomic)
            for old in entries().dropFirst(limit) { try? fileManager.removeItem(at: old) }
            return url
        } catch {
            NSLog("MacCap: no se pudo guardar en el historial: %@", error.localizedDescription)
            return nil
        }
    }

    /// Newest first.
    static func entries() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        func date(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        return urls.filter { $0.pathExtension.lowercased() == "png" }.sorted { date($0) > date($1) }
    }

    static func clear() {
        for url in entries() { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Global hot keys

struct HotKey {
    let id: UInt32
    let keyCode: Int
    let carbonModifiers: Int
    let action: () -> Void
}

/// Registers system-wide shortcuts with Carbon (no Accessibility permission needed).
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x4D_43_41_50 // "MCAP"

    private init() {}

    /// Returns the ids that could not be registered (already used by another app).
    @discardableResult
    func register(_ hotKeys: [HotKey]) -> [UInt32] {
        unregisterAll()
        installHandlerIfNeeded()
        var failed: [UInt32] = []
        for hotKey in hotKeys {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(hotKey.keyCode), UInt32(hotKey.carbonModifiers),
                                             EventHotKeyID(signature: signature, id: hotKey.id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref = ref {
                refs.append(ref)
                handlers[hotKey.id] = hotKey.action
            } else {
                failed.append(hotKey.id)
            }
        }
        return failed
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func handle(_ id: UInt32) {
        DispatchQueue.main.async { self.handlers[id]?() }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if status == noErr { HotKeyCenter.shared.handle(hotKeyID.id) }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
#endif
