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

final class AnnotationHistoryTests: XCTestCase {
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
