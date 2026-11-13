#if os(macOS)
import AppKit
import Carbon.HIToolbox
import ServiceManagement
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

// MARK: - Global hot keys

struct HotKey {
    let id: UInt32
    let keyCode: Int
    let carbonModifiers: Int
    /// For displaying in menus.
    let keyEquivalent: String
    let modifierMask: NSEvent.ModifierFlags
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
