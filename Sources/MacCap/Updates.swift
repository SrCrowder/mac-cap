#if os(macOS)
import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

/// Automatic updates through Sparkle. The feed and public key are in Info.plist
/// (SUFeedURL, SUPublicEDKey); updates are published by the GitHub Actions workflow.
final class Updater: NSObject {
    #if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController?
    #endif

    override init() {
        #if canImport(Sparkle)
        // Only start inside a real bundle with a feed configured (not in `swift run` or tests).
        let configured = Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = configured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        #endif
        super.init()
    }

    var isAvailable: Bool {
        #if canImport(Sparkle)
        return controller != nil
        #else
        return false
        #endif
    }

    var installsAutomatically: Bool {
        get {
            #if canImport(Sparkle)
            return controller?.updater.automaticallyDownloadsUpdates ?? false
            #else
            return false
            #endif
        }
        set {
            #if canImport(Sparkle)
            controller?.updater.automaticallyChecksForUpdates = true
            controller?.updater.automaticallyDownloadsUpdates = newValue
            #endif
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        #if canImport(Sparkle)
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(sender)
        #endif
    }
}
#endif
