import AppKit

enum E2ETest {
    private final class CatcherView: NSView {
        var clicks = 0
        var drags = 0
        var rightClicks = 0
        var scrolls = 0
        override func mouseDown(with event: NSEvent) {
            clicks += 1
        }
        override func mouseDragged(with event: NSEvent) { drags += 1 }
        override func rightMouseDown(with event: NSEvent) { rightClicks += 1 }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func scrollWheel(with event: NSEvent) {
            scrolls += 1
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0.95, alpha: 1).setFill()
            dirtyRect.fill()
        }
    }

    static func run() -> Int32 {
        setlinebuf(stdout)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        guard let screen = NSScreen.screens.first else {
            print("no screen")
            return 1
        }
        guard AXIsProcessTrusted() else {
            print("FAIL: Accessibility permission is required for the live E2E test")
            return 1
        }
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            print("\(value ? "PASS" : "FAIL"): \(message)")
            if !value { failures += 1 }
        }
        let output = ProcessInfo.processInfo.environment["TH_CAPTURE_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let size = CGSize(width: 520, height: 360)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        let catcher = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let catcherView = CatcherView(frame: CGRect(origin: .zero, size: size))
        catcher.contentView = catcherView
        catcher.level = .statusBar
        catcher.orderFrontRegardless()

        let saved = CGEvent(source: nil)?.location ?? .zero
        let source = CGEventSource(stateID: .hidSystemState)
        let start = CGPoint(x: screen.frame.midX - 150, y: screen.frame.height - screen.frame.midY)

        func pump(_ seconds: Double) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                if let e = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) {
                    app.sendEvent(e)
                }
            }
        }
        func post(_ type: CGEventType, _ p: CGPoint) {
            let button: CGMouseButton = type == .rightMouseDown || type == .rightMouseUp ? .right : .left
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)?
                .post(tap: .cghidEventTap)
        }
        func state(_ label: String, _ overlay: OverlayController) {
            let m = NSEvent.mouseLocation
            let down = CGEventSource.buttonState(.hidSystemState, button: .left)
            print(String(format: "%-14@ mouse=(%.0f,%.0f) hidDown=%@ %@", label as NSString, m.x, m.y,
                         down ? "yes" : "no", overlay.debugState))
        }
        func savePanel(to directory: URL) {
            guard let panel = app.windows.compactMap({ $0 as? NSSavePanel }).first(where: { $0.isVisible }) else {
                check(false, "capture opens a save dialog")
                return
            }
            pump(0.5)
            let destination = directory.appendingPathComponent(panel.nameFieldStringValue)
            guard panel.directoryURL?.standardizedFileURL == directory.standardizedFileURL,
                  destination.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                  !FileManager.default.fileExists(atPath: destination.path) else {
                check(false, "save destination is the empty test output directory")
                panel.cancel(nil)
                return
            }
            guard panel.isKeyWindow else {
                check(false, "the save dialog owns keyboard focus")
                panel.cancel(nil)
                return
            }
            // Modern macOS hosts the save UI out of process; its public ok: is unavailable.
            for down in [true, false] {
                let key = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: down)
                key?.flags = []
                key?.post(tap: .cghidEventTap)
            }
            pump(1)
            check(FileManager.default.fileExists(atPath: destination.path), "native save dialog writes \(destination.lastPathComponent)")
            if panel.isVisible { panel.cancel(nil) }
        }

        let savedStyle = PointerStyle.saved
        PointerStyle.saved = .lavender
        let overlay = OverlayController(makeSavePanel: {
            let panel = NSSavePanel()
            if let output = output { panel.directoryURL = output }
            return panel
        })
        func selectMode(_ mode: PointerMode) {
            guard let center = overlay.toolbarButtonCenter(mode) else {
                check(false, "\(mode.title) control is available")
                return
            }
            let p = CGPoint(x: center.x, y: screen.frame.height - center.y)
            post(.mouseMoved, p)
            pump(0.3)
            post(.leftMouseDown, p)
            post(.leftMouseUp, p)
            pump(0.2)
            check(overlay.mode == mode, "clicking the toolbar selects \(mode.title) mode")
            post(.mouseMoved, start)
            pump(0.1)
        }
        let installed = overlay.activate()
        print("tap installed:", installed)
        guard installed else {
            overlay.deactivate()
            PointerStyle.saved = savedStyle
            catcher.orderOut(nil)
            return 1
        }
        pump(0.3)

        post(.mouseMoved, start)
        pump(0.2)
        post(.leftMouseDown, start)
        pump(0.05)
        post(.leftMouseDragged, CGPoint(x: start.x + 10, y: start.y))
        pump(0.05)
        post(.leftMouseUp, start)
        post(.rightMouseDown, start)
        post(.rightMouseUp, start)
        pump(0.2)
        check(catcherView.clicks == 1 && catcherView.drags > 0 && catcherView.rightClicks == 1,
              "Pointer delivers native left clicks, drags, and right clicks")
        check(!overlay.canSaveDrawing, "Pointer gestures do not draw")
        catcherView.clicks = 0
        selectMode(.draw)
        state("before press", overlay)

        post(.leftMouseDown, start)
        pump(0.1)
        state("pressed", overlay)

        for k in 1...40 {
            let p = CGPoint(x: start.x + CGFloat(k) * 6, y: start.y + 30 * sin(CGFloat(k) / 6))
            post(.leftMouseDragged, p)
            pump(0.016)
        }
        state("dragged", overlay)

        post(.leftMouseUp, CGPoint(x: start.x + 240, y: start.y))
        pump(0.2)
        state("released", overlay)

        for _ in 0..<5 {
            CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: -2, wheel2: 0, wheel3: 0)?
                .post(tap: .cghidEventTap)
            pump(0.03)
        }
        pump(0.1)
        print("scroll ticks right after drawing that reached the app (of 5):", catcherView.scrolls)
        check(catcherView.scrolls == 5, "scrolling still reaches the app")
        check(overlay.canSaveDrawing, "completed drawing is exportable")

        overlay.saveDrawing()
        pump(0.5)
        let drawingPanel = app.windows.compactMap { $0 as? NSSavePanel }.first { $0.isVisible }
        check(drawingPanel != nil, "Save Drawing opens a native save dialog")
        drawingPanel?.cancel(nil)
        pump(0.2)
        check(overlay.canSaveDrawing && overlay.isActive, "cancelling Save preserves the drawing and pointer")
        if let output = output {
            overlay.saveDrawing()
            pump(0.5)
            savePanel(to: output)
        }

        let before = overlay.savedInkStrokes
        post(.leftMouseDown, start)
        pump(0.05)
        post(.leftMouseUp, start)
        pump(0.2)
        state("plain click", overlay)
        print("plain click added strokes:", overlay.savedInkStrokes - before)
        check(overlay.savedInkStrokes == before, "a drawing-mode tap does not create a stroke")

        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        if let c = overlay.toolbarButtonCenter(.laser) {
            let p = CGPoint(x: c.x, y: primaryH - c.y)
            post(.mouseMoved, p)
            pump(0.2)
            post(.leftMouseDown, p)
            post(.leftMouseUp, p)
            pump(0.4)
        }
        print("style after clicking the toolbar's laser button:", overlay.style.rawValue)
        print("clicks that leaked to the catcher window:", catcherView.clicks)
        check(overlay.style == .laser, "toolbar remains clickable in Draw mode")
        check(catcherView.clicks == 0, "Draw mode does not click the underlying app")

        let clickPoint = start
        overlay.resetTapWait()
        Thread.detachNewThread {
            for _ in 0..<3 {
                usleep(400_000)
                post(.leftMouseDown, clickPoint)
                usleep(30_000)
                post(.leftMouseUp, clickPoint)
            }
        }
        Thread.sleep(forTimeInterval: 2)
        pump(0.3)
        var count: UInt32 = 0
        CGGetEventTapList(0, nil, &count)
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        CGGetEventTapList(count, &taps, &count)
        if let mine = taps.first(where: { $0.tappingProcess == getpid() && $0.enabled }) {
            print(String(format: "tap latency while the main thread was frozen: avg %.1f ms, max %.1f ms",
                         mine.avgUsecLatency / 1000, mine.maxUsecLatency / 1000))
        }
        print(String(format: "longest a click waited to reach the tap during the stall: %.1f ms", overlay.tapMaxWaitMs))
        print("clicks that leaked during the stall:", catcherView.clicks)
        check(catcherView.clicks == 0, "Draw mode consumes clicks while the main thread stalls")

        selectMode(.screenshot)
        post(.leftMouseDown, start)
        pump(0.05)
        for p in [CGPoint(x: start.x + 160, y: start.y),
                  CGPoint(x: start.x + 80, y: start.y + 100), start] {
            post(.leftMouseDragged, p)
            pump(0.05)
        }
        post(.leftMouseUp, start)
        pump(0.2)
        check(overlay.canSaveScreenshot, "a freeform screen selection is ready to capture")
        check(catcherView.clicks == 0, "Screenshot mode does not click the underlying app")
        if let output = output {
            if CGPreflightScreenCaptureAccess() {
                overlay.saveScreenshot()
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline && !app.windows.contains(where: { $0 is NSSavePanel && $0.isVisible }) {
                    pump(0.1)
                }
                if let panel = app.windows.compactMap({ $0 as? NSSavePanel }).first(where: { $0.isVisible }) {
                    panel.cancel(nil)
                    pump(0.2)
                    check(overlay.canSaveScreenshot && overlay.isActive, "cancelling screenshot Save preserves the selection")
                    overlay.saveScreenshot()
                    let deadline = Date().addingTimeInterval(10)
                    while Date() < deadline && !app.windows.contains(where: { $0 is NSSavePanel && $0.isVisible }) {
                        pump(0.1)
                    }
                    savePanel(to: output)
                    let url = output.appendingPathComponent("TinyHand Screenshot.png")
                    do {
                        let data = try Data(contentsOf: url)
                        if let rep = NSBitmapImageRep(data: data),
                           let inside = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 4)?.usingColorSpace(.deviceRGB),
                           let outside = rep.colorAt(x: 0, y: rep.pixelsHigh - 2) {
                            check(outside.alphaComponent == 0, "the saved freeform screenshot is transparent outside the shape")
                            check(abs(inside.redComponent - 0.13) < 0.1 && abs(inside.blueComponent - 0.31) < 0.1,
                                  "screen capture contains the separate fixture, not TinyHand overlays")
                        } else {
                            check(false, "saved screenshot can be decoded")
                        }
                    } catch {
                        check(false, "saved screenshot can be read: \(error.localizedDescription)")
                    }
                } else {
                    check(false, "ScreenCaptureKit completes and opens Save")
                }
            } else {
                check(false, "Screen Recording permission is required for capture evidence")
            }
        }
        overlay.clearInk()
        check(!overlay.canSaveScreenshot && !overlay.canSaveDrawing, "Clear discards both drawing and selection")

        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 0x35, keyDown: down)?.post(tap: .cghidEventTap)
            pump(0.1)
        }
        pump(0.2)
        print("active after Esc:", overlay.isActive)
        check(!overlay.isActive, "Escape turns off the pointer")

        overlay.deactivate()
        PointerStyle.saved = savedStyle
        catcher.orderOut(nil)
        CGWarpMouseCursorPosition(saved)
        pump(0.1)
        return failures == 0 ? 0 : 1
    }
}
