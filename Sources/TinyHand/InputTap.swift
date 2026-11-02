import AppKit

enum PointerMode: String, CaseIterable {
    case pointer, draw, screenshot

    var title: String {
        switch self {
        case .pointer: return "Pointer"
        case .draw: return "Draw"
        case .screenshot: return "Screenshot"
        }
    }

    var symbol: String {
        switch self {
        case .pointer: return "cursorarrow"
        case .draw: return "pencil.tip"
        case .screenshot: return "viewfinder"
        }
    }
}

final class InputTap {
    var onMouseDown: ((CGPoint) -> Void)?
    var onInteractDown: (() -> Void)?
    var onInteractUp: (() -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onLeftDragged: ((CGPoint) -> Void)?
    var onPassThroughPress: ((CGPoint) -> Void)?

    private let lock = NSLock()
    private var _active = false
    private var _passThroughRects: [CGRect] = []
    private var _interactKey: CGEventFlags = []
    private var _mode = PointerMode.pointer
    private enum Route {
        case native(CGEventFlags), controls, drawing
    }
    private var presses: [Int64: Route] = [:]

    var mode: PointerMode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }

    var passThroughRects: [CGRect] {
        get { lock.withLock { _passThroughRects } }
        set { lock.withLock { _passThroughRects = newValue } }
    }

    private var active: Bool {
        lock.withLock { _active }
    }

    var interactKey: CGEventFlags {
        get { lock.withLock { _interactKey } }
        set { lock.withLock { _interactKey = newValue } }
    }

    var interactPressing: Bool {
        lock.withLock {
            presses.values.contains {
                if case .native(let flags) = $0 { return !flags.isEmpty }
                return false
            }
        }
    }

    private(set) var maxWaitMs: Double = 0
    private var tap: CFMachPort?
    private var thread: Thread?

    private(set) var isInstalled = false

    @discardableResult
    func install() -> Bool {
        guard tap == nil else {
            return true
        }

        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged,
            .rightMouseDragged, .otherMouseDragged,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let me = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }
        CGEvent.tapEnable(tap: tap, enable: false)

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "TinyHand event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        self.tap = tap
        self.thread = thread
        isInstalled = true
        return true
    }

    func setActive(_ value: Bool) {
        lock.withLock {
            _active = value
            presses.removeAll()
        }
        guard let tap = tap else {
            return
        }
        CGEvent.tapEnable(tap: tap, enable: value)
    }

    func simulate(_ type: CGEventType) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left) else {
            return
        }
        let was = active
        lock.withLock { _active = true }
        _ = handle(type: type, event: event)
        lock.withLock { _active = was }
    }

    func resetWait() {
        maxWaitMs = 0
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.timestamp > 0 {
            let wait = Double(DispatchTime.now().uptimeNanoseconds &- event.timestamp) / 1_000_000
            if wait < 600_000 {
                maxWaitMs = max(maxWaitMs, wait)
            }
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if type == .tapDisabledByTimeout {
                Log.write("event tap was disabled by a timeout; re-enabled")
            }
            if active, let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard active else {
            return Unmanaged.passUnretained(event)
        }

        let isDown = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
        let isUp = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type)
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let location = event.location
        // Latch the route and modifier on mouse-down, independently for each button.
        let route: Route = lock.withLock {
            if isDown {
                if _passThroughRects.contains(where: { $0.contains(location) }) {
                    presses[button] = .controls
                } else if _mode == .pointer {
                    presses[button] = .native([])
                } else if !_interactKey.isEmpty && event.flags.contains(_interactKey) {
                    presses[button] = .native(_interactKey)
                } else {
                    presses[button] = .drawing
                }
            }
            let route = presses[button] ?? .native([])
            if isUp { presses[button] = nil }
            return route
        }

        switch route {
        case .native(let modifier):
            event.flags.remove(modifier)
            if isDown {
                DispatchQueue.main.async { [weak self] in self?.onInteractDown?() }
            } else if isUp {
                DispatchQueue.main.async { [weak self] in self?.onInteractUp?() }
            }
            return Unmanaged.passUnretained(event)
        case .controls:
            if isDown {
                DispatchQueue.main.async { [weak self] in self?.onPassThroughPress?(location) }
            }
            return Unmanaged.passUnretained(event)
        case .drawing:
            break
        }

        switch type {
        case .leftMouseDown:
            DispatchQueue.main.async { [weak self] in self?.onMouseDown?(location) }
            return nil
        case .leftMouseUp:
            DispatchQueue.main.async { [weak self] in self?.onMouseUp?(location) }
            return nil
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if type == .leftMouseDragged {
                DispatchQueue.main.async { [weak self] in self?.onLeftDragged?(location) }
            }
            event.type = .mouseMoved
            return Unmanaged.passUnretained(event)
        case .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
