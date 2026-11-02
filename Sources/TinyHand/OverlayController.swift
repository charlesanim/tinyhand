import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

final class OverlayController {
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let window: OverlayWindow
    private let armView: ArmView
    private let inputTap = InputTap()
    private let tapSound = TapSound()
    private var interactHeld = false
    private var menuHover = false
    private var guardCursorUntil = Date.distantPast
    private var timer: Timer?
    private var currentFrame: CGRect?
    private var downPoint: CGPoint?
    private var buttonSeenDown = false
    private var dragEvents = 0
    private(set) var mode = PointerMode.pointer
    private let selectionLayer = CAShapeLayer()
    private var selectionPoints: [CGPoint] = []
    private var selectionPath: CGPath?
    private var exporting = false
    private var savePanel: NSSavePanel?
    private let makeSavePanel: () -> NSSavePanel
    private var captureTask: Task<Void, Never>?

    private let toolbar = Toolbar()
    private var revealUntil = Date.distantPast
    private var normalCursor = false
    private var ownMenuOpen = false
    private var menuRects: [CGRect] = []
    private var lastMenuScan = Date.distantPast
    private var menuOpeningUntil = Date.distantPast
    private var escHotKey: UInt32?
    private var lastPermissionCheck = Date.distantPast

    private static let busyInterval: TimeInterval = 1.0 / 120.0
    private static let idleInterval: TimeInterval = 1.0 / 20.0
    private static let idleAfter: TimeInterval = 0.5
    private static let menuScanFast: TimeInterval = 0.05
    private static let menuScanSlow: TimeInterval = 0.25
    private var timerInterval: TimeInterval = 0
    private var idleMonitors: [Any] = []
    private var lastMouse: CGPoint?
    private var stillSince = Date()
    private var lastButtonEvent = Date.distantPast

    private(set) var isActive = false
    private var activity: NSObjectProtocol?
    var onActiveChanged: (() -> Void)?
    var onNeedsPermission: (() -> Void)?

    init(makeSavePanel: @escaping () -> NSSavePanel = { NSSavePanel() }) {
        self.makeSavePanel = makeSavePanel
        let frame = (NSScreen.main ?? NSScreen.screens.first).map { $0.frame }
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        armView = ArmView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = armView
        selectionLayer.strokeColor = NSColor.systemBlue.cgColor
        selectionLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        selectionLayer.lineWidth = 2
        selectionLayer.lineDashPattern = [6, 4]
        selectionLayer.fillRule = .evenOdd
        armView.layer?.addSublayer(selectionLayer)

        inputTap.onMouseDown = { [weak self] location in
            guard let self = self, self.isActive, !self.exporting else {
                return
            }
            self.armView.press()
            self.armView.held = true
            self.tapSound.play()
            self.toolbar.hideHint()
            self.downPoint = self.localPoint(location)
            if self.mode == .screenshot {
                self.clearSelection()
                self.selectionPoints = self.downPoint.map { [$0] } ?? []
            }
            self.dragEvents = 0
            Log.write("press at \(self.downPoint.map { "\(Int($0.x)),\(Int($0.y))" } ?? "?")")
            self.noteButtonEvent()
        }
        inputTap.onLeftDragged = { [weak self] location in
            guard let self = self, self.isActive, !self.exporting else { return }
            self.dragEvents += 1
            self.drag(to: self.localPoint(location))
            self.wake()
        }
        inputTap.onMouseUp = { [weak self] location in
            guard let self = self, self.isActive, !self.exporting else { return }
            self.drag(to: self.localPoint(location))
            self.release()
            self.noteButtonEvent()
        }
        inputTap.onInteractDown = { [weak self] in
            guard let self = self, self.isActive, !self.exporting else { return }
            self.armView.press()
            self.armView.held = true
            self.tapSound.play()
            self.noteButtonEvent()
        }
        inputTap.onInteractUp = { [weak self] in
            guard let self = self, self.isActive, !self.exporting else { return }
            self.armView.held = false
            self.guardCursorUntil = Date().addingTimeInterval(2)
            CursorHider.reassert(urgent: true)
            self.noteButtonEvent()
        }
        inputTap.onPassThroughPress = { [weak self] location in
            guard let screen = self?.currentScreen() else {
                return
            }
            let bar = OverlayController.cgRect(OverlayController.menuBarRect(screen))
            if bar.contains(location) {
                self?.menuOpeningUntil = Date().addingTimeInterval(1)
            }
            self?.noteButtonEvent()
        }

        toolbar.onPick = { [weak self] style in
            self?.pick(style)
        }
        toolbar.onToggleSound = { [weak self] in
            self?.soundOn.toggle()
        }
        toolbar.onExit = { [weak self] in
            self?.exit()
        }
        toolbar.onFixPermission = { [weak self] in
            self?.exit()
            self?.onNeedsPermission?()
        }
        toolbar.onModeChanged = { [weak self] in self?.setMode($0) }
        toolbar.onSave = { [weak self] in
            guard let self = self else { return }
            if self.mode == .screenshot { self.saveScreenshot() }
            else { self.saveDrawing() }
        }
        toolbar.onClear = { [weak self] in self?.clearInk() }
        toolbar.select(armView.style)
        tapSound.enabled = soundOn
        toolbar.setSoundOn(soundOn)
        NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
            self?.syncSound()
            self?.inputTap.interactKey = Preferences.interactKey.cgFlags
            self?.armView.updateInkColor()
            self?.tapSound.load(Preferences.tapSound)
            if let self = self, self.armView.style != PointerStyle.saved {
                self.pick(PointerStyle.saved)
            }
        }
    }

    var soundOn: Bool {
        get { armView.style == .laser ? Preferences.laserSound : Preferences.handSound }
        set {
            if armView.style == .laser {
                Preferences.laserSound = newValue
            } else {
                Preferences.handSound = newValue
            }
        }
    }
    var onSoundChanged: (() -> Void)?

    func pick(_ style: PointerStyle) {
        armView.setStyle(style)
        PointerStyle.saved = armView.style
        toolbar.select(armView.style)
        syncSound()
    }

    private func syncSound() {
        tapSound.enabled = soundOn
        toolbar.setSoundOn(soundOn)
        onSoundChanged?()
    }

    var extraPassThrough: (() -> [CGRect])?

    func suspendInput(_ suspended: Bool) {
        guard isActive, inputTap.isInstalled else {
            return
        }
        ownMenuOpen = suspended
        guard !exporting else { return }
        inputTap.setActive(!suspended && !exporting)
        if let screen = currentScreen() {
            updateZones(mouse: NSEvent.mouseLocation, screen: screen)
        }
    }

    func exit() {
        clearInk()
        deactivate()
    }

    private func release() {
        if let start = downPoint {
            let moved = localMouse().map { Int(hypot($0.x - start.x, $0.y - start.y)) } ?? -1
            Log.write("release, drag events=\(dragEvents) moved=\(moved)pt stroke drawn=\(armView.ink.isDrawing)")
        }
        buttonSeenDown = false
        armView.held = false
        downPoint = nil
        armView.ink.end()
        if mode == .screenshot, !selectionPoints.isEmpty {
            do {
                selectionPath = try Capture.selection(selectionPoints)
                revealUntil = Date().addingTimeInterval(10)
            } catch {
                clearSelection()
                Log.write("selection rejected: \(error.localizedDescription)")
                toolbar.showHint([("Draw a shape", "at least 4 points wide and tall")])
            }
        }
        refreshSave()
    }

    var style: PointerStyle { armView.style }

    var tapMaxWaitMs: Double { inputTap.maxWaitMs }

    func resetTapWait() {
        inputTap.resetWait()
    }

    func toolbarButtonCenter(_ style: PointerStyle) -> CGPoint? {
        toolbar.center(of: style)
    }

    func toolbarButtonCenter(_ mode: PointerMode) -> CGPoint? {
        toolbar.center(of: mode)
    }

    var inkStrokes: Int { armView.ink.layer.sublayers?.count ?? 0 }
    var savedInkStrokes: Int { armView.ink.savedStrokes.count }

    var debugState: String {
        "held=\(armView.held) downPoint=\(downPoint != nil) drawing=\(armView.ink.isDrawing) strokes=\(inkStrokes)"
    }

    func clearInk() {
        downPoint = nil
        armView.held = false
        armView.ink.clear()
        clearSelection()
        refreshSave()
    }

    var canSaveDrawing: Bool { !armView.ink.savedStrokes.isEmpty }
    var canSaveScreenshot: Bool { selectionPath != nil }
    var onCaptureChanged: (() -> Void)?

    func setMode(_ mode: PointerMode) {
        guard !exporting else { return }
        release()
        clearSelection()
        self.mode = mode
        inputTap.mode = mode
        // The overlay must never win hit-testing over the Dock in Pointer mode.
        window.ignoresMouseEvents = true
        refreshSave()
        revealUntil = Date().addingTimeInterval(5)
        if isActive {
            let text = mode == .pointer ? "click and drag normally"
                : mode == .draw ? "drag to draw, then save a PNG"
                : "draw a shape, then click Save"
            toolbar.showHint([(mode.title, text)])
        }
    }

    private func refreshSave() {
        toolbar.setMode(mode, canSave: mode == .screenshot ? canSaveScreenshot : canSaveDrawing)
        onCaptureChanged?()
    }

    private func clearSelection() {
        selectionPoints = []
        selectionPath = nil
        selectionLayer.path = nil
    }

    private func drag(to point: CGPoint? = nil) {
        guard !exporting, let start = downPoint, let p = point ?? localMouse() else {
            return
        }
        if mode == .screenshot {
            if let last = selectionPoints.last, hypot(p.x - last.x, p.y - last.y) < 1.5 { return }
            selectionPoints.append(p)
            let path = CGMutablePath()
            path.addLines(between: selectionPoints)
            path.closeSubpath()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            selectionLayer.path = path
            CATransaction.commit()
            return
        }
        guard mode == .draw else { return }
        let ink = armView.ink
        if !ink.isDrawing {
            if hypot(p.x - start.x, p.y - start.y) < 4 {
                return
            }
            ink.begin(at: start, width: armView.inkWidth)
        }
        ink.extend(to: p)
    }

    private func localPoint(_ cgPoint: CGPoint) -> CGPoint? {
        guard let frame = currentFrame else { return nil }
        let point = OverlayController.cgPoint(cgPoint)
        return CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    }

    private func localMouse() -> CGPoint? {
        guard let frame = currentFrame else {
            return nil
        }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - frame.origin.x, y: mouse.y - frame.origin.y)
    }

    func toggle() {
        if isActive {
            deactivate()
            return
        }
        activate()
    }

    static let hintShownKey = "firstRunHintShown"

    @discardableResult
    func activate() -> Bool {
        guard !isActive else {
            return inputTap.isInstalled
        }
        guard AXIsProcessTrusted() else {
            Log.write("activate skipped: not trusted")
            onNeedsPermission?()
            return false
        }
        isActive = true
        currentFrame = nil
        tapSound.warm()

        CursorHider.hide()
        tick()
        window.orderFrontRegardless()

        stillSince = Date()
        runTimer(every: OverlayController.busyInterval)

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "TinyHand pointer is on")
        let installed = inputTap.install()
        inputTap.interactKey = Preferences.interactKey.cgFlags
        inputTap.setActive(installed)
        Log.write("activate trusted=\(AXIsProcessTrusted()) tapInstalled=\(installed)")

        if let screen = currentScreen() {
            toolbar.place(on: screen)
        }
        toolbar.setNeedsPermission(!installed)
        toolbar.show()
        revealUntil = Date().addingTimeInterval(3)
        if installed && !UserDefaults.standard.bool(forKey: OverlayController.hintShownKey) {
            UserDefaults.standard.set(true, forKey: OverlayController.hintShownKey)
            var parts: [(key: String, text: String)] = [("Pointer", "to click"), ("Draw", "to sketch"), ("Screenshot", "to select")]
            parts.append(("Esc", "to exit"))
            toolbar.showHint(parts)
            revealUntil = Date().addingTimeInterval(10)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.toolbar.hideHint()
            }
        }
        setEscEnabled(true)
        onActiveChanged?()
        return installed
    }

    func deactivate() {
        guard isActive else {
            return
        }
        isActive = false
        captureTask?.cancel()
        captureTask = nil
        savePanel?.cancel(nil)

        timer?.invalidate()
        timer = nil
        timerInterval = 0
        removeIdleMonitors()
        inputTap.setActive(false)
        if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        armView.held = false
        downPoint = nil
        armView.ink.clear()
        clearSelection()
        refreshSave()
        window.ignoresMouseEvents = true
        window.orderOut(nil)
        toolbar.hide()
        normalCursor = false
        armView.pointerHidden = false
        inputTap.passThroughRects = []
        setEscEnabled(false)
        ownMenuOpen = false
        CursorHider.show()
        onActiveChanged?()
    }

    private func updateZones(mouse: CGPoint, screen: NSScreen) {
        let f = toolbar.frame
        let near = f.insetBy(dx: -80, dy: 0).union(f.offsetBy(dx: 0, dy: 90)).insetBy(dx: 0, dy: -10).contains(mouse)
        let needsPermission = !inputTap.isInstalled
        let drawing = armView.ink.isDrawing || downPoint != nil
        toolbar.setRevealed(!drawing && (near || Date() < revealUntil || needsPermission))

        let menuLikely = !menuRects.isEmpty || ownMenuOpen || Date() < menuOpeningUntil
            || Date().timeIntervalSince(lastButtonEvent) < 2
            || OverlayController.menuBarRect(screen).insetBy(dx: 0, dy: -40).contains(mouse)
        let scanEvery = menuLikely ? OverlayController.menuScanFast : OverlayController.menuScanSlow
        if Date().timeIntervalSince(lastMenuScan) > scanEvery {
            lastMenuScan = Date()
            menuRects = OverlayController.openMenus()
        }
        let menuBar = OverlayController.menuBarRect(screen)
        let cgMouse = OverlayController.cgPoint(mouse)
        let overMenu = menuBar.contains(mouse) || menuRects.contains { $0.contains(cgMouse) }
            || Date() < menuOpeningUntil
        let key = Preferences.interactKey.cgFlags
        let interacting = mode != .pointer && ((!key.isEmpty && CGEventSource.flagsState(.hidSystemState).contains(key)) || inputTap.interactPressing)
        interactHeld = interacting
        menuHover = overMenu
        let normal = !drawing && !Preferences.interactKeepsHand && (interacting || overMenu || ownMenuOpen)
        setEscEnabled(menuRects.isEmpty && !ownMenuOpen)

        if normal != normalCursor {
            let at = "at \(Int(mouse.x)),\(Int(mouse.y))"
            let why = interacting ? "interact key" : menuBar.contains(mouse) ? "menu bar" : "menu"
            Log.write(normal ? "real cursor (\(why)) \(at)" : "pointer back \(at)")
            normalCursor = normal
            armView.pointerHidden = normal
            if normal {
                CursorHider.show()
            } else {
                CursorHider.hide()
            }
        }

        var rects = (extraPassThrough?() ?? []).map(OverlayController.cgRect)
        rects.append(OverlayController.cgRect(menuBar))
        rects.append(contentsOf: menuRects)
        if toolbar.revealed {
            rects.append(OverlayController.cgRect(f))
        }
        inputTap.passThroughRects = rects
    }

    private func setEscEnabled(_ enabled: Bool) {
        if enabled && isActive && !exporting && escHotKey == nil {
            escHotKey = HotKeyCenter.shared.register(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in
                self?.exit()
            }
        }
        if !enabled, let id = escHotKey {
            HotKeyCenter.shared.unregister(id)
            escHotKey = nil
        }
    }

    private static func menuBarRect(_ screen: NSScreen) -> CGRect {
        let height = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }

    private static func openMenus() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return []
        }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == menuLevel,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                return nil
            }
            return rect
        }
    }

    private static func cgPoint(_ p: CGPoint) -> CGPoint {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryH - p.y)
    }

    private func checkPermission() {
        guard !inputTap.isInstalled, Date().timeIntervalSince(lastPermissionCheck) > 1 else {
            return
        }
        lastPermissionCheck = Date()
        guard AXIsProcessTrusted(), inputTap.install() else {
            return
        }
        Log.write("permission granted while running; tap installed")
        inputTap.setActive(true)
        toolbar.setNeedsPermission(false)
    }

    private static func cgRect(_ r: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    }

    func runClickTest() {
        func time(_ label: String, _ body: () -> Void) {
            let t = CFAbsoluteTimeGetCurrent()
            body()
            print(String(format: "%@: %.1f ms", label, (CFAbsoluteTimeGetCurrent() - t) * 1000))
        }
        func spin(_ seconds: Double) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        tick()
        time("tick") { tick() }
        time("mouseDown (tap callback)") { inputTap.simulate(.leftMouseDown) }
        time("mouseDown (deferred work)") { spin(0.01) }
        time("10 ticks while held") { for _ in 0..<10 { tick() } }
        time("mouseUp (tap callback)") { inputTap.simulate(.leftMouseUp) }
        spin(0.01)
        spin(0.3)
        time("second click (tap callbacks)") {
            inputTap.simulate(.leftMouseDown)
            inputTap.simulate(.leftMouseUp)
        }
        spin(0.05)
        time("drag x50 (tap callbacks)") {
            inputTap.simulate(.leftMouseDown)
            for _ in 0..<50 { inputTap.simulate(.leftMouseDragged) }
            inputTap.simulate(.leftMouseUp)
        }
        spin(0.05)
        time("ticks after up") { for _ in 0..<20 { tick() } }
        print("held after up:", armView.held, "drawing:", armView.ink.isDrawing)
    }

    private func currentScreen() -> NSScreen? {
        if mode == .screenshot, !selectionPoints.isEmpty,
           let screen = NSScreen.screens.first(where: { $0.frame == currentFrame }) {
            return screen
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func runTimer(every interval: TimeInterval) {
        if timer != nil && interval == timerInterval {
            return
        }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerInterval = interval
    }

    private func noteButtonEvent() {
        lastButtonEvent = Date()
        wake()
    }

    private func wake() {
        stillSince = Date()
        guard isActive, timerInterval != OverlayController.busyInterval else {
            return
        }
        removeIdleMonitors()
        runTimer(every: OverlayController.busyInterval)
        tick()
    }

    private func updatePace(busy: Bool) {
        if timerInterval == OverlayController.idleInterval {
            if busy {
                wake()
            }
            return
        }
        let still = Date().timeIntervalSince(stillSince) > OverlayController.idleAfter
        guard still, !busy, !armView.held, !armView.isSettling, !armView.ink.isDrawing else {
            return
        }
        installIdleMonitors()
        runTimer(every: OverlayController.idleInterval)
    }

    private func installIdleMonitors() {
        guard idleMonitors.isEmpty else {
            return
        }
        let events: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .flagsChanged,
        ]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            self?.wake()
        }) {
            idleMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.wake()
            return event
        }) {
            idleMonitors.append(local)
        }
    }

    private func removeIdleMonitors() {
        idleMonitors.forEach(NSEvent.removeMonitor)
        idleMonitors = []
    }

    private func tick() {
        guard !exporting else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = currentScreen() else {
            return
        }

        if currentFrame != screen.frame {
            let moving = currentFrame != nil
            if moving {
                release()
                clearSelection()
                revealUntil = Date().addingTimeInterval(1.5)
            }
            currentFrame = screen.frame
            armView.ink.clearVisible()
            armView.ink.origin = screen.frame.origin
            refreshSave()
            window.setFrame(screen.frame, display: false)
            armView.frame = NSRect(origin: .zero, size: screen.frame.size)
            toolbar.place(on: screen)
        }

        if mouse != lastMouse {
            lastMouse = mouse
            stillSince = Date()
        }

        updateZones(mouse: mouse, screen: screen)
        let overDock = DockArea.contains(OverlayController.cgPoint(mouse))
        let catchMouse = mode != .pointer && overDock && inputTap.isInstalled && !normalCursor && !interactHeld
        if window.ignoresMouseEvents == catchMouse {
            window.ignoresMouseEvents = !catchMouse
        }
        let urgent = interactHeld || menuHover || Date() < guardCursorUntil
        if !normalCursor {
            CursorHider.reassert(fighting: overDock, urgent: urgent)
        }
        checkPermission()

        let local = CGPoint(x: mouse.x - screen.frame.origin.x, y: mouse.y - screen.frame.origin.y)
        armView.aim(cursor: local)
        guard downPoint != nil else {
            let busy = overDock || (!normalCursor && urgent) || CursorHider.isSettling
            updatePace(busy: busy)
            return
        }
        let down = CGEventSource.buttonState(.hidSystemState, button: .left)
        if down {
            buttonSeenDown = true
        }
        if buttonSeenDown && !down {
            release()
            return
        }
        drag()
    }

    func saveDrawing() {
        guard !exporting else { return }
        armView.ink.end()
        do {
            let image = try Capture.drawing(armView.ink.savedStrokes, scale: armView.ink.scale)
            beginExport()
            presentSave(image, name: "TinyHand Drawing")
        } catch {
            beginExport()
            showCaptureError(error)
            finishExport()
        }
    }

    func saveScreenshot() {
        guard !exporting else { return }
        guard let path = selectionPath, let frame = currentFrame,
              let screen = NSScreen.screens.first(where: { $0.frame == frame }),
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            beginExport()
            showCaptureError(selectionPath == nil ? CaptureError.emptySelection : CaptureError.displayUnavailable)
            finishExport()
            return
        }
        beginExport()
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            showCaptureError(CaptureError.permission)
            finishExport()
            return
        }
        captureTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                // Allow our windows to leave the compositor before the macOS 13 fallback.
                try await Task.sleep(nanoseconds: 150_000_000)
                let desktop = try await Capture.screen(id: id, frame: OverlayController.cgRect(frame))
                try Task.checkCancellation()
                let image = try Capture.screenshot(desktop, path: path, screenSize: frame.size)
                self.presentSave(image, name: "TinyHand Screenshot")
            } catch is CancellationError {
                self.finishExport()
            } catch {
                if !Task.isCancelled && self.isActive { self.showCaptureError(error) }
                self.finishExport()
            }
            self.captureTask = nil
        }
    }

    private func beginExport() {
        exporting = true
        inputTap.setActive(false)
        setEscEnabled(false)
        window.orderOut(nil)
        toolbar.hide()
        CursorHider.show()
    }

    private func finishExport() {
        exporting = false
        guard isActive else { return }
        inputTap.setActive(!ownMenuOpen)
        normalCursor = false
        armView.pointerHidden = false
        CursorHider.hide()
        window.orderFrontRegardless()
        toolbar.show()
        revealUntil = Date().addingTimeInterval(5)
        tick()
        refreshSave()
    }

    private func presentSave(_ image: CGImage, name: String) {
        let panel = makeSavePanel()
        panel.title = name
        panel.nameFieldStringValue = "\(name).png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        savePanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self = self else { return }
            defer {
                self.savePanel = nil
                self.finishExport()
            }
            guard response == .OK, let url = panel.url else { return }
            do { try Capture.png(image).write(to: url, options: .atomic) }
            catch { self.showCaptureError(error) }
        }
    }

    private func showCaptureError(_ error: Error) {
        Log.write("capture failed: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = "Couldn't save capture"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if case CaptureError.permission = error {
            alert.addButton(withTitle: "Open Settings")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
