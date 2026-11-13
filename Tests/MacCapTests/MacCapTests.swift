import XCTest
@testable import MacCap

final class MacCapTests: XCTestCase {
    func testCaptureArguments() {
        XCTAssertEqual(CaptureOptions(mode: .screen).arguments(output: "/tmp/image.png"),
                       ["-x", "-m", "/tmp/image.png"])
        XCTAssertEqual(CaptureOptions(mode: .selection, delay: true, cursor: true).arguments(output: "image.png"),
                       ["-x", "-i", "-s", "-T", "5", "-C", "image.png"])
        XCTAssertEqual(CaptureOptions(mode: .window).arguments(output: "image.png"),
                       ["-x", "-i", "-w", "image.png"])
    }

    func testAnnotationGeometryFitsAndClamps() {
        let imageRect = AnnotationGeometry.imageRect(image: CGSize(width: 200, height: 100),
                                                     in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(imageRect, CGRect(x: 0, y: 25, width: 100, height: 50))
        let rectangle = AnnotationGeometry.rectangle(from: CGPoint(x: 80, y: 65),
                                                     to: CGPoint(x: -10, y: 20), in: imageRect)
        XCTAssertEqual(rectangle, CGRect(x: 0, y: 0, width: 0.8, height: 0.8))
        XCTAssertEqual(AnnotationGeometry.project(rectangle!, into: CGRect(x: 0, y: 0, width: 200, height: 100)),
                       CGRect(x: 0, y: 0, width: 160, height: 80))
    }

    func testAnnotationGeometryRejectsInvalidDrags() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(AnnotationGeometry.rectangle(from: CGPoint(x: -1, y: 0), to: .zero, in: rect))
        XCTAssertNil(AnnotationGeometry.rectangle(from: .zero, to: CGPoint(x: 1, y: 1), in: rect))
        XCTAssertNil(AnnotationGeometry.rectangle(from: .zero, to: CGPoint(x: 5, y: 5), in: .zero))
        XCTAssertEqual(AnnotationGeometry.imageRect(image: .zero, in: rect), .zero)
    }
}
