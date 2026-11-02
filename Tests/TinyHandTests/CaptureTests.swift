import AppKit
import XCTest
@testable import TinyHand

final class CaptureTests: XCTestCase {
    func testDrawingSurvivesFadingAndDisplayChangesUntilCleared() throws {
        let ink = Ink()
        ink.color = Ink.red
        ink.origin = CGPoint(x: -100, y: 50)
        ink.begin(at: CGPoint(x: 10, y: 10), width: 4)
        ink.extend(to: CGPoint(x: 40, y: 30))
        ink.end()
        ink.clearVisible()
        XCTAssertEqual(ink.savedStrokes.count, 1)
        XCTAssertEqual(ink.savedStrokes[0].path.boundingBoxOfPath.minX, -90)
        let image = try Capture.drawing(ink.savedStrokes, scale: 2)
        XCTAssertEqual(image.width, 76)
        XCTAssertEqual(image.height, 56)
        let png = try Capture.png(image)
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertTrue(rep.hasAlpha)
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 0, y: 0)).alphaComponent, 0)
        ink.clear()
        XCTAssertThrowsError(try Capture.drawing(ink.savedStrokes, scale: 2))
    }

    func testFreeformCropHasTransparentOutsideAndCorrectOrientationAtRetinaScale() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 160,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 80))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 80, width: 200, height: 80))
        let path = try Capture.selection([
            CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 10), CGPoint(x: 10, y: 70),
        ])
        let image = try Capture.screenshot(XCTUnwrap(context.makeImage()), path: path,
                                           screenSize: CGSize(width: 100, height: 80))
        XCTAssertEqual(image.width, 160)
        XCTAssertEqual(image.height, 120)
        let rep = NSBitmapImageRep(cgImage: image)
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 150, y: 5)).alphaComponent, 0)
        XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x: 5, y: 15)).blueComponent, 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x: 5, y: 105)).redComponent, 0.9)
    }

    func testSelectionRejectsClicksAndLinesButAllowsSelfIntersectingShapes() throws {
        XCTAssertThrowsError(try Capture.selection([]))
        XCTAssertThrowsError(try Capture.selection([.zero, CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30)]))
        XCTAssertThrowsError(try Capture.selection([.zero, CGPoint(x: 2, y: 0), CGPoint(x: 0, y: 2)]))
        XCTAssertNoThrow(try Capture.selection([
            .zero, CGPoint(x: 50, y: 50), CGPoint(x: 0, y: 50), CGPoint(x: 50, y: 0),
        ]))
    }

    func testSelectionIsClippedToDisplayEdges() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 80,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let path = try Capture.selection([
            CGPoint(x: -20, y: -10), CGPoint(x: 40, y: -10),
            CGPoint(x: 40, y: 40), CGPoint(x: -20, y: 40),
        ])
        let image = try Capture.screenshot(XCTUnwrap(context.makeImage()), path: path,
                                           screenSize: CGSize(width: 100, height: 80))
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 40)
        XCTAssertThrowsError(try Capture.drawing([
            Ink.Stroke(path: path, color: Ink.red, width: 4),
        ], scale: .infinity))
    }
}
