import AppKit
import XCTest
@testable import TinyHand

final class InputTapTests: XCTestCase {
    private var events: [CGEvent] = []

    private func event(_ type: CGEventType, button: CGMouseButton = .left,
                       flags: CGEventFlags = [], point: CGPoint = CGPoint(x: 500, y: 500)) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                                          mouseCursorPosition: point, mouseButton: button))
        event.flags = flags
        // The event-tap callback returns unretained events, owned by its caller.
        events.append(event)
        return event
    }

    func testPointerPassesNativeClicksDragsAndModifiersWithoutReposting() throws {
        let tap = InputTap()
        tap.setActive(true)
        tap.interactKey = .maskAlternate
        for (button, types) in [
            (CGMouseButton.left, [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp]),
            (.right, [.rightMouseDown, .rightMouseDragged, .rightMouseUp]),
            (.center, [.otherMouseDown, .otherMouseDragged, .otherMouseUp]),
        ] {
            for type in types {
                let e = try event(type, button: button, flags: [.maskAlternate, .maskShift])
                e.setIntegerValueField(.mouseEventClickState, value: 2)
                XCTAssertTrue(tap.handle(type: type, event: e)?.takeUnretainedValue() === e)
                XCTAssertEqual(e.type, type)
                XCTAssertEqual(e.flags, [.maskAlternate, .maskShift])
                XCTAssertEqual(e.getIntegerValueField(.mouseEventClickState), 2)
            }
        }
    }

    func testDrawingAndScreenshotConsumeClicksAndDoNotLeakDrags() throws {
        let tap = InputTap()
        tap.setActive(true)
        for mode in [PointerMode.draw, .screenshot] {
            tap.mode = mode
            XCTAssertNil(tap.handle(type: .leftMouseDown, event: try event(.leftMouseDown)))
            let drag = try event(.leftMouseDragged)
            XCTAssertNotNil(tap.handle(type: .leftMouseDragged, event: drag))
            XCTAssertEqual(drag.type, .mouseMoved)
            XCTAssertNil(tap.handle(type: .leftMouseUp, event: try event(.leftMouseUp)))
        }
    }

    func testModifierAndRoutesStayLatchedForEachButton() throws {
        let tap = InputTap()
        tap.setActive(true)
        tap.mode = .draw
        tap.interactKey = .maskAlternate
        let down = try event(.leftMouseDown, flags: [.maskAlternate, .maskShift])
        XCTAssertNotNil(tap.handle(type: .leftMouseDown, event: down))
        XCTAssertEqual(down.flags, .maskShift)
        XCTAssertTrue(tap.interactPressing)
        XCTAssertNil(tap.handle(type: .rightMouseDown, event: try event(.rightMouseDown, button: .right)))
        tap.interactKey = .maskCommand
        let drag = try event(.leftMouseDragged, flags: [.maskAlternate, .maskShift])
        XCTAssertNotNil(tap.handle(type: .leftMouseDragged, event: drag))
        XCTAssertEqual(drag.flags, .maskShift)
        XCTAssertEqual(drag.type, .leftMouseDragged)
        XCTAssertNil(tap.handle(type: .rightMouseUp, event: try event(.rightMouseUp, button: .right)))
        XCTAssertTrue(tap.interactPressing)
        XCTAssertNotNil(tap.handle(type: .leftMouseUp, event: try event(.leftMouseUp)))
        XCTAssertFalse(tap.interactPressing)
    }

    func testToolbarGestureAndModeChangeKeepOriginalRoute() throws {
        let tap = InputTap()
        tap.setActive(true)
        tap.mode = .draw
        tap.passThroughRects = [CGRect(x: 0, y: 0, width: 100, height: 100)]
        XCTAssertNotNil(tap.handle(type: .leftMouseDown, event: try event(.leftMouseDown, point: CGPoint(x: 50, y: 50))))
        XCTAssertNotNil(tap.handle(type: .leftMouseUp, event: try event(.leftMouseUp)))
        XCTAssertNil(tap.handle(type: .leftMouseDown, event: try event(.leftMouseDown)))
        tap.mode = .pointer
        XCTAssertNil(tap.handle(type: .leftMouseUp, event: try event(.leftMouseUp, point: CGPoint(x: 50, y: 50))))
        tap.setActive(false)
        XCTAssertNotNil(tap.handle(type: .leftMouseDown, event: try event(.leftMouseDown)))
    }
}
