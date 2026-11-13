import XCTest
@testable import MacCap

final class CaptureOptionsTests: XCTestCase {
    func testScreenArguments() {
        XCTAssertEqual(CaptureOptions(mode: .screen).arguments(output: "/tmp/image.png"),
                       ["-x", "-m", "/tmp/image.png"])
        XCTAssertEqual(CaptureOptions(mode: .screen, cursor: true).arguments(output: "image.png"),
                       ["-x", "-m", "-C", "image.png"])
    }

    func testInteractiveArguments() {
        XCTAssertEqual(CaptureOptions(mode: .selection, delay: 5, cursor: true).arguments(output: "image.png"),
                       ["-x", "-i", "-s", "-T", "5", "image.png"])
        XCTAssertEqual(CaptureOptions(mode: .window, cursor: true).arguments(output: "image.png"),
                       ["-x", "-i", "-w", "image.png"])
        XCTAssertEqual(CaptureOptions(mode: .window, windowShadow: false, sound: true).arguments(output: "i.png"),
                       ["-i", "-w", "-o", "i.png"])
    }
}

final class NamingTests: XCTestCase {
    func testFileName() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        XCTAssertEqual(CaptureNaming.fileName(for: date, calendar: calendar),
                       "Captura 2023-11-14 a las 22.13.20.png")
    }

    func testFileNameExtension() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(CaptureNaming.fileName(for: date, extension: ImageFormat.jpeg.fileExtension, calendar: calendar),
                       "Captura 2023-11-14 a las 22.13.20.jpg")
    }

    func testUniqueURL() {
        let directory = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        let taken: Set<String> = ["/tmp/x/a.png", "/tmp/x/a (2).png"]
        XCTAssertEqual(CaptureNaming.uniqueURL(in: directory, name: "a.png") { taken.contains($0.path) }.path,
                       "/tmp/x/a (3).png")
        XCTAssertEqual(CaptureNaming.uniqueURL(in: directory, name: "b.png") { taken.contains($0.path) }.path,
                       "/tmp/x/b.png")
    }
}

final class AnnotationGeometryTests: XCTestCase {
    func testImageRectFitsAndCentres() {
        let rect = AnnotationGeometry.imageRect(image: CGSize(width: 200, height: 100),
                                                in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(rect, CGRect(x: 0, y: 25, width: 100, height: 50))
        XCTAssertEqual(AnnotationGeometry.imageRect(image: .zero, in: rect), .zero)
    }

    func testImagePointScalesAndClamps() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(AnnotationGeometry.imagePoint(CGPoint(x: 60, y: 45), imageRect: rect, imageSize: size),
                       CGPoint(x: 100, y: 50))
        XCTAssertEqual(AnnotationGeometry.imagePoint(CGPoint(x: -50, y: 500), imageRect: rect, imageSize: size),
                       CGPoint(x: 0, y: 100))
    }

    func testConstrain() {
        let square = AnnotationGeometry.constrain(start: .zero, end: CGPoint(x: 10, y: -4), tool: .rectangle)
        XCTAssertEqual(square, CGPoint(x: 10, y: -10))
        let horizontal = AnnotationGeometry.constrain(start: .zero, end: CGPoint(x: 10, y: 1), tool: .arrow)
        XCTAssertEqual(horizontal.x, hypot(10, 1), accuracy: 0.0001)
        XCTAssertEqual(horizontal.y, 0, accuracy: 0.0001)
        let diagonal = AnnotationGeometry.constrain(start: .zero, end: CGPoint(x: 10, y: 9), tool: .line)
        XCTAssertEqual(diagonal.x, diagonal.y, accuracy: 0.0001)
        XCTAssertEqual(AnnotationGeometry.constrain(start: .zero, end: CGPoint(x: 3, y: 7), tool: .pen),
                       CGPoint(x: 3, y: 7))
    }

    func testMeaningful() {
        let red = RGBA(r: 1, g: 0, b: 0)
        XCTAssertFalse(AnnotationGeometry.isMeaningful(
            Annotation(tool: .rectangle, points: [.zero, CGPoint(x: 1, y: 50)], color: red, lineWidth: 2)))
        XCTAssertTrue(AnnotationGeometry.isMeaningful(
            Annotation(tool: .ellipse, points: [.zero, CGPoint(x: 10, y: 10)], color: red, lineWidth: 2)))
        XCTAssertFalse(AnnotationGeometry.isMeaningful(
            Annotation(tool: .arrow, points: [.zero, CGPoint(x: 1, y: 1)], color: red, lineWidth: 2)))
        XCTAssertFalse(AnnotationGeometry.isMeaningful(
            Annotation(tool: .text, points: [.zero], color: red, lineWidth: 0, text: "  ")))
        XCTAssertTrue(AnnotationGeometry.isMeaningful(
            Annotation(tool: .pen, points: [.zero, CGPoint(x: 1, y: 0)], color: red, lineWidth: 2)))
    }

    func testArrowHeadTipAndSymmetry() {
        let head = AnnotationGeometry.arrowHead(from: .zero, to: CGPoint(x: 100, y: 0), lineWidth: 4)
        XCTAssertEqual(head[0], CGPoint(x: 100, y: 0))
        XCTAssertLessThan(head[1].x, 100)
        XCTAssertEqual(head[1].y, -head[2].y, accuracy: 0.0001)
    }

    func testCounter() {
        let red = RGBA(r: 1, g: 0, b: 0)
        XCTAssertEqual(AnnotationGeometry.nextCounter(in: []), 1)
        let items = [Annotation(tool: .counter, points: [.zero], color: red, lineWidth: 0, number: 4),
                     Annotation(tool: .pen, points: [.zero], color: red, lineWidth: 0, number: 9)]
        XCTAssertEqual(AnnotationGeometry.nextCounter(in: items), 5)
    }

    func testToolShortcutsAreUnique() {
        XCTAssertEqual(Set(AnnotationTool.allCases.map(\.key)).count, AnnotationTool.allCases.count)
    }
}

final class SelectionGeometryTests: XCTestCase {
    private let red = RGBA(r: 1, g: 0, b: 0)
    private let noText: (Annotation) -> CGSize = { _ in .zero }

    func testHitTestLinesAndBoxes() {
        let line = Annotation(tool: .line, points: [.zero, CGPoint(x: 100, y: 0)], color: red, lineWidth: 4)
        XCTAssertTrue(AnnotationGeometry.hitTest(line, at: CGPoint(x: 50, y: 5), tolerance: 4, textSize: noText))
        XCTAssertFalse(AnnotationGeometry.hitTest(line, at: CGPoint(x: 50, y: 20), tolerance: 4, textSize: noText))
        let box = Annotation(tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)], color: red, lineWidth: 2)
        XCTAssertTrue(AnnotationGeometry.hitTest(box, at: CGPoint(x: 30, y: 30), tolerance: 0, textSize: noText))
        XCTAssertFalse(AnnotationGeometry.hitTest(box, at: CGPoint(x: 90, y: 90), tolerance: 4, textSize: noText))
        let text = Annotation(tool: .text, points: [CGPoint(x: 200, y: 200)], color: red, lineWidth: 0, text: "Hola")
        let size: (Annotation) -> CGSize = { _ in CGSize(width: 50, height: 20) }
        XCTAssertTrue(AnnotationGeometry.hitTest(text, at: CGPoint(x: 240, y: 215), tolerance: 0, textSize: size))
    }

    func testTopmostPrefersLastDrawn() {
        let a = Annotation(tool: .rectangle, points: [.zero, CGPoint(x: 100, y: 100)], color: red, lineWidth: 2)
        let b = Annotation(tool: .ellipse, points: [CGPoint(x: 50, y: 50), CGPoint(x: 80, y: 80)], color: red, lineWidth: 2)
        XCTAssertEqual(AnnotationGeometry.topmost(in: [a, b], at: CGPoint(x: 60, y: 60), tolerance: 0, textSize: noText), 1)
        XCTAssertEqual(AnnotationGeometry.topmost(in: [a, b], at: CGPoint(x: 10, y: 10), tolerance: 0, textSize: noText), 0)
        XCTAssertNil(AnnotationGeometry.topmost(in: [a, b], at: CGPoint(x: 300, y: 10), tolerance: 0, textSize: noText))
    }

    func testTranslatedAndBounds() {
        let counter = Annotation(tool: .counter, points: [CGPoint(x: 10, y: 10)], color: red, lineWidth: 0, fontSize: 5)
        XCTAssertEqual(AnnotationGeometry.bounds(of: counter, textSize: noText), CGRect(x: 5, y: 5, width: 10, height: 10))
        let moved = AnnotationGeometry.translated(counter, by: CGPoint(x: 3, y: -2))
        XCTAssertEqual(moved.points, [CGPoint(x: 13, y: 8)])
    }

    func testBackgroundLayout() {
        XCTAssertEqual(BackgroundStyle.none.layout(content: CGSize(width: 100, height: 50)).size, CGSize(width: 100, height: 50))
        let layout = BackgroundStyle.ocean.layout(content: CGSize(width: 1000, height: 500))
        XCTAssertEqual(layout.contentOrigin, CGPoint(x: 70, y: 70))
        XCTAssertEqual(layout.size, CGSize(width: 1140, height: 640))
    }
}

final class AnnotationHistoryTests: XCTestCase {
    func testReplaceRemoveAndCrop() {
        let red = RGBA(r: 1, g: 0, b: 0)
        let a = Annotation(tool: .counter, points: [.zero], color: red, lineWidth: 0, number: 1)
        var history = AnnotationHistory()
        history.add(a)
        var b = a
        b.number = 7
        history.replace(at: 0, with: b)
        XCTAssertEqual(history.items, [b])
        history.setCrop(CGRect(x: 1, y: 2, width: 3, height: 4))
        history.clear()
        XCTAssertEqual(history.items, [])
        XCTAssertEqual(history.crop, CGRect(x: 1, y: 2, width: 3, height: 4), "clear keeps the crop")
        history.undo()
        history.undo()
        XCTAssertNil(history.crop)
        XCTAssertEqual(history.items, [b])
        history.remove(at: 0)
        XCTAssertTrue(history.items.isEmpty)
        history.undo()
        history.undo()
        XCTAssertEqual(history.items, [a])
    }

    func testUndoRedoClear() {
        let a = Annotation(tool: .counter, points: [.zero], color: RGBA(r: 0, g: 0, b: 0), lineWidth: 0, number: 1)
        var b = a
        b.number = 2
        var history = AnnotationHistory()
        XCTAssertFalse(history.canUndo)
        history.add(a)
        history.add(b)
        XCTAssertEqual(history.items, [a, b])
        history.undo()
        XCTAssertEqual(history.items, [a])
        XCTAssertTrue(history.canRedo)
        history.redo()
        XCTAssertEqual(history.items, [a, b])
        history.clear()
        XCTAssertEqual(history.items, [])
        history.undo()
        XCTAssertEqual(history.items, [a, b])
        history.undo()
        history.add(b)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.items, [a, b])
    }
}

#if os(macOS)
import AppKit
import CoreImage

final class RenderingTests: XCTestCase {
    /// A 400×300 px image (Retina-like: 200×150 pt) with black text-like stripes on white.
    private func makeDocument() throws -> AnnotationImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        CGRect(x: 0, y: 0, width: 400, height: 300).fill()
        NSColor.black.setFill()
        for x in stride(from: 0, to: 400, by: 4) { CGRect(x: x, y: 0, width: 2, height: 300).fill() }
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: 200, height: 150)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return try XCTUnwrap(AnnotationImage(data: data))
    }

    private func pixel(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
        bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    }

    func testExportKeepsSizeAndDrawsEveryTool() throws {
        let document = try makeDocument()
        XCTAssertEqual(document.pixelSize, CGSize(width: 400, height: 300))
        XCTAssertEqual(document.scale, 2)
        let red = RGBA(r: 1, g: 0, b: 0)
        var annotations: [Annotation] = []
        for tool in AnnotationTool.allCases {
            annotations.append(Annotation(tool: tool, points: [CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 90)],
                                          color: red, lineWidth: 8, fontSize: 30, text: "Hola", number: 1))
        }
        let data = try XCTUnwrap(document.pngData(with: annotations))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 400)
        XCTAssertEqual(bitmap.pixelsHigh, 300)
        XCTAssertEqual(bitmap.size, NSSize(width: 200, height: 150))
    }

    func testPixelateHidesStripesAndRectangleIsRed() throws {
        let document = try makeDocument()
        let red = RGBA(r: 1, g: 0, b: 0)
        let pixelate = Annotation(tool: .pixelate, points: [CGPoint(x: 200, y: 100), CGPoint(x: 400, y: 300)],
                                  color: red, lineWidth: 4)
        let rectangle = Annotation(tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 150, y: 80)],
                                   color: red, lineWidth: 8)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(document.pngData(with: [pixelate, rectangle]))))

        // Outside the pixelated area the stripes are intact: adjacent columns differ a lot.
        XCTAssertGreaterThan(abs(pixel(bitmap, 160, 250).redComponent - pixel(bitmap, 162, 250).redComponent), 0.8)
        // Inside, blocks average the stripes to mid grey (plus a little noise).
        for (x, y) in [(260, 160), (300, 200), (350, 260)] {
            let gray = pixel(bitmap, x, y).redComponent
            XCTAssertGreaterThan(gray, 0.2, "(\(x), \(y))")
            XCTAssertLessThan(gray, 0.92, "(\(x), \(y))")
        }
        // Top edge of the rectangle (image coordinates have the origin at the top-left).
        let edge = pixel(bitmap, 80, 10)
        XCTAssertGreaterThan(edge.redComponent, 0.8)
        XCTAssertLessThan(edge.greenComponent, 0.3)
    }

    func testPixelatePipelineAveragesBlocks() throws {
        let document = try makeDocument()
        let cgImage = try XCTUnwrap(document.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let input = CIImage(cgImage: cgImage)
        let context = CIContext()
        for (offset, noise) in [(CGPoint.zero, false), (CGPoint(x: 13, y: 7), false), (CGPoint(x: 13, y: 7), true)] {
            let output = AnnotationImage.pixelate(input, block: 44, offset: offset, noise: noise)
            XCTAssertEqual(output.extent, input.extent)
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(context.createCGImage(output, from: output.extent)))
            let values = [(50, 50), (260, 160), (300, 200)].map { rep.colorAt(x: $0.0, y: $0.1)!.redComponent }
            print("pixelate offset=\(offset) noise=\(noise) ->", values)
            for value in values {
                XCTAssertGreaterThan(value, 0.2, "offset=\(offset) noise=\(noise)")
                XCTAssertLessThan(value, 0.92, "offset=\(offset) noise=\(noise)")
            }
            // Within one 44 px block: flat without noise, varied with noise.
            let row = Set((100..<130).map { Int(rep.colorAt(x: $0, y: 150)!.redComponent * 255) })
            if noise { XCTAssertGreaterThan(row.count, 3, "noise has no effect") } else { XCTAssertLessThanOrEqual(row.count, 2) }
        }
    }

    func testExportFormats() throws {
        let document = try makeDocument()
        let png = try XCTUnwrap(document.pngData(with: []))
        XCTAssertEqual(ImageExporter.data(fromPNG: png, format: .png), png)
        let jpeg = try XCTUnwrap(ImageExporter.data(fromPNG: png, format: .jpeg))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: jpeg))
        XCTAssertEqual(decoded.pixelsWide, 400)
        XCTAssertEqual(decoded.size.width, 200, accuracy: 0.5, "DPI kept")
        // HEIC encoding may be unavailable on CI virtual machines; if it works it must decode.
        if let heic = ImageExporter.data(fromPNG: png, format: .heic) {
            XCTAssertEqual(NSBitmapImageRep(data: heic)?.pixelsWide, 400)
        }
    }

    func testBarcodeReaderFindsQRCode() throws {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("https://example.com/maccap".utf8), forKey: "inputMessage")
        let qr = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let padded = qr.transformed(by: CGAffineTransform(translationX: 40, y: 40))
            .composited(over: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: qr.extent.width + 80,
                                                                        height: qr.extent.height + 80)))
        let cgImage = try XCTUnwrap(CIContext().createCGImage(padded, from: padded.extent))
        XCTAssertEqual(try BarcodeReader.read(cgImage), ["https://example.com/maccap"])
    }

    func testCropAndBackgroundExport() throws {
        let document = try makeDocument()
        let state = EditorState(items: [], crop: CGRect(x: 100, y: 50, width: 200, height: 100))
        let cropped = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(document.pngData(state, background: .none))))
        XCTAssertEqual(cropped.pixelsWide, 200)
        XCTAssertEqual(cropped.pixelsHigh, 100)
        let framed = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(document.pngData(state, background: .sunset))))
        let layout = BackgroundStyle.sunset.layout(content: CGSize(width: 200, height: 100))
        XCTAssertEqual(framed.pixelsWide, Int(layout.size.width))
        // The corner is gradient (warm, not white or black).
        let corner = framed.colorAt(x: 2, y: 2)!.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(corner.redComponent, 0.8)
        XCTAssertLessThan(corner.greenComponent, 0.7)
    }

    func testBlurChangesPixels() throws {
        let document = try makeDocument()
        let blur = Annotation(tool: .blur, points: [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 300)],
                              color: RGBA(r: 1, g: 0, b: 0), lineWidth: 4)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(document.pngData(with: [blur]))))
        let a = bitmap.colorAt(x: 200, y: 150)!.usingColorSpace(.deviceRGB)!.redComponent
        let b = bitmap.colorAt(x: 202, y: 150)!.usingColorSpace(.deviceRGB)!.redComponent
        XCTAssertLessThan(abs(a - b), 0.2, "stripes are blurred")
    }
}
#endif
