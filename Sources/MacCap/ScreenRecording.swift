#if os(macOS)
import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import ImageIO
import ScreenCaptureKit

enum RecordingError: LocalizedError {
    case unsupported
    case noDisplay
    case noFrames
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: return L("Esta función necesita macOS 12.3 o posterior.", "This feature needs macOS 12.3 or later.")
        case .noDisplay: return L("No se encontró la pantalla de la zona seleccionada.", "The display of the selected area was not found.")
        case .noFrames: return L("No se grabó ningún fotograma (la zona no cambió o falta el permiso de grabación).", "No frames were recorded (the area didn't change or screen recording permission is missing).")
        case .writer(let message): return message
        }
    }
}

/// Region in display-local coordinates (points, top-left origin), as ScreenCaptureKit expects.
func displayLocalRect(_ rect: CGRect, on screen: NSScreen) -> CGRect {
    CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
}

// MARK: - Capture stream of a region

/// Streams frames of a screen region with ScreenCaptureKit. MacCap's own windows (frame, controls)
/// are excluded from the capture.
@available(macOS 12.3, *)
final class RegionStream: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "MacCap.RegionStream")
    /// Called on `queue` for every complete frame.
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onStop: ((Error) -> Void)?
    private var stream: SCStream?
    private(set) var pixelSize: CGSize = .zero

    func start(rect: CGRect, screen: NSScreen, fps: Int, showsCursor: Bool,
               completion: @escaping (Error?) -> Void) {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let scale = screen.backingScaleFactor
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let content = content else {
                DispatchQueue.main.async { completion(error ?? RecordingError.noDisplay) }
                return
            }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first
            else {
                DispatchQueue.main.async { completion(RecordingError.noDisplay) }
                return
            }
            let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = displayLocalRect(rect, on: screen)
            // Even dimensions keep H.264 happy.
            let width = Int((rect.width * scale).rounded()) & ~1
            let height = Int((rect.height * scale).rounded()) & ~1
            configuration.width = max(width, 2)
            configuration.height = max(height, 2)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            configuration.showsCursor = showsCursor
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.queueDepth = 6
            self.pixelSize = CGSize(width: configuration.width, height: configuration.height)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                DispatchQueue.main.async { completion(error) }
                return
            }
            self.stream = stream
            stream.startCapture { error in DispatchQueue.main.async { completion(error) } }
        }
    }

    func stop(completion: @escaping () -> Void) {
        guard let stream = stream else { queue.async(execute: completion); return }
        self.stream = nil
        stream.stopCapture { _ in self.queue.async(execute: completion) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        onFrame?(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStop?(error) }
    }
}

// MARK: - Video recording

/// Records a region to an H.264 MP4 file.
@available(macOS 12.3, *)
final class RegionRecorder {
    let outputURL: URL
    private let stream = RegionStream()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    var onUnexpectedStop: ((Error) -> Void)?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start(rect: CGRect, screen: NSScreen, showsCursor: Bool, completion: @escaping (Error?) -> Void) {
        stream.onStop = { [weak self] error in self?.onUnexpectedStop?(error) }
        stream.onFrame = { [weak self] sampleBuffer in self?.append(sampleBuffer) }
        stream.start(rect: rect, screen: screen, fps: 30, showsCursor: showsCursor) { [weak self] error in
            guard let self = self else { return }
            if let error = error { completion(error); return }
            do {
                try self.makeWriter(size: self.stream.pixelSize)
                completion(nil)
            } catch {
                self.stream.stop {}
                completion(error)
            }
        }
    }

    private func makeWriter(size: CGSize) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, Int(size.width * size.height) * 4)]
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.writer(L("No se pudo preparar el vídeo.", "Could not prepare the video.")) }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RecordingError.writer(L("No se pudo empezar a escribir el vídeo.", "Could not start writing the video."))
        }
        // Frames arrive on the stream queue; set up there to avoid races.
        stream.queue.sync {
            self.writer = writer
            self.input = input
        }
    }

    /// Runs on the stream queue.
    private func append(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = writer, let input = input, writer.status == .writing else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        stream.stop { [self] in
            // On the stream queue: no more frames will arrive.
            guard let writer = writer, let input = input, sessionStarted else {
                writer?.cancelWriting()
                DispatchQueue.main.async { completion(.failure(RecordingError.noFrames)) }
                return
            }
            // ScreenCaptureKit only sends frames when something changes; extend the video to "now".
            writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
            input.markAsFinished()
            writer.finishWriting {
                let result: Result<URL, Error> = writer.status == .completed
                    ? .success(self.outputURL)
                    : .failure(writer.error ?? RecordingError.writer(L("No se pudo guardar el vídeo.", "Could not save the video.")))
                DispatchQueue.main.async { completion(result) }
            }
        }
    }
}

// MARK: - GIF

enum GIFExporter {
    /// Converts a video to an animated GIF (loops forever). Call from a background queue.
    static func convert(movie: URL, to output: URL, fps: Double = 12, maxWidth: CGFloat = 800) throws {
        let asset = AVURLAsset(url: movie)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else { throw RecordingError.noFrames }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        let count = max(1, Int((duration * fps).rounded(.down)))
        try? FileManager.default.removeItem(at: output)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "com.compuserve.gif" as CFString,
                                                                count, nil) else {
            throw RecordingError.writer(L("No se pudo crear el GIF.", "Could not create the GIF."))
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]
        ] as CFDictionary
        var last: CGImage?
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) / fps, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) { last = image }
            guard let frame = last else { continue }
            CGImageDestinationAddImage(destination, frame, frameProperties)
        }
        guard last != nil, CGImageDestinationFinalize(destination) else {
            throw RecordingError.writer(L("No se pudo crear el GIF.", "Could not create the GIF."))
        }
    }
}

// MARK: - Scrolling capture

/// Captures a region repeatedly while the user scrolls, and stitches the frames.
@available(macOS 12.3, *)
final class ScrollCapture {
    private let stream = RegionStream()
    private let stitcher = ScrollStitcher()
    private let context = CIContext()
    /// Height in pixels so far, and whether the last frame could not be matched. Main queue.
    var onProgress: ((Int, Bool) -> Void)?
    var onUnexpectedStop: ((Error) -> Void)?

    func start(rect: CGRect, screen: NSScreen, completion: @escaping (Error?) -> Void) {
        stream.onStop = { [weak self] error in self?.onUnexpectedStop?(error) }
        stream.onFrame = { [weak self] sampleBuffer in self?.process(sampleBuffer) }
        stream.start(rect: rect, screen: screen, fps: 8, showsCursor: false, completion: completion)
    }

    private func process(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let result = stitcher.add(image)
        let height = stitcher.height
        DispatchQueue.main.async { self.onProgress?(height, result == .lost) }
    }

    func stop(completion: @escaping (CGImage?) -> Void) {
        stream.stop { [self] in
            let image = stitcher.compose()
            DispatchQueue.main.async { completion(image) }
        }
    }
}

// MARK: - On-screen controls

/// Coloured frame around the region being captured (not part of the capture) plus a small
/// panel with a timer and a Stop button.
final class CaptureControls: NSObject {
    private var frameWindow: NSWindow?
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private let started = Date()
    private let onStop: () -> Void

    init(region: CGRect, color: NSColor, buttonTitle: String, onStop: @escaping () -> Void) {
        self.onStop = onStop
        super.init()
        let border = region.insetBy(dx: -4, dy: -4)
        let frameWindow = NSWindow(contentRect: border, styleMask: .borderless, backing: .buffered, defer: false)
        frameWindow.isOpaque = false
        frameWindow.backgroundColor = .clear
        frameWindow.ignoresMouseEvents = true
        frameWindow.level = .statusBar
        frameWindow.hasShadow = false
        frameWindow.isReleasedWhenClosed = false
        frameWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let borderView = NSView()
        borderView.wantsLayer = true
        borderView.layer?.borderWidth = 3
        borderView.layer?.borderColor = color.cgColor
        borderView.layer?.cornerRadius = 4
        frameWindow.contentView = borderView
        frameWindow.orderFrontRegardless()
        self.frameWindow = frameWindow

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        let button = NSButton(title: buttonTitle, target: self, action: #selector(stopTapped))
        button.bezelColor = color
        let stack = NSStackView(views: [label, button])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)
        let size = CGSize(width: 330, height: 44)
        let screen = NSScreen.screens.first { $0.frame.intersects(region) }?.visibleFrame ?? region
        var origin = CGPoint(x: region.midX - size.width / 2, y: border.minY - size.height - 8)
        if origin.y < screen.minY { origin.y = min(border.maxY + 8, screen.maxY - size.height) }
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.appearance = NSAppearance(named: .vibrantDark)
        panel.contentView = background
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        panel.orderFrontRegardless()
        self.panel = panel
        setStatus("")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshTime() }
    }

    private var status = ""

    func setStatus(_ text: String) {
        status = text
        refreshTime()
    }

    private func refreshTime() {
        let seconds = Int(Date().timeIntervalSince(started))
        let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
        label.stringValue = status.isEmpty ? "● \(time)" : "● \(time)  \(status)"
    }

    @objc private func stopTapped() { onStop() }

    func close() {
        timer?.invalidate()
        timer = nil
        frameWindow?.orderOut(nil)
        panel?.orderOut(nil)
        frameWindow = nil
        panel = nil
    }
}
#endif
