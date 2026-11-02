import AppKit

final class Toolbar {
    var onPick: ((PointerStyle) -> Void)?
    var onToggleSound: (() -> Void)?
    var onExit: (() -> Void)?
    var onFixPermission: (() -> Void)?
    var onModeChanged: ((PointerMode) -> Void)?
    var onSave: (() -> Void)?
    var onClear: (() -> Void)?

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class Button: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private let panel: Panel
    private let stack = NSStackView()
    private var styleButtons: [PointerStyle: Button] = [:]
    private var shownStyles: [PointerStyle] = []
    private var current: PointerStyle?
    private var inkButton: Button?
    private var swatches: [InkChoice: Button] = [:]
    private var inkOpen = false
    private let permissionButton = Button()
    private var soundButton: Button?
    private var saveButton: Button?
    private let modes = NSSegmentedControl(labels: PointerMode.allCases.map(\.title),
                                           trackingMode: .selectOne, target: nil, action: nil)
    private(set) var revealed = false

    private let tray: Panel
    private let trayStack = NSStackView()
    private var hint: Panel?

    var frame: CGRect { inkOpen ? panel.frame.union(tray.frame) : panel.frame }

    init() {
        panel = Panel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 56),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.alphaValue = 0

        let background = NSVisualEffectView.darkGlass(radius: 16)
        panel.contentView = background

        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        tray = Panel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40),
                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        tray.isOpaque = false
        tray.backgroundColor = .clear
        tray.hasShadow = true
        tray.hidesOnDeactivate = false
        tray.isFloatingPanel = true
        tray.becomesKeyOnlyIfNeeded = true
        tray.level = panel.level
        tray.collectionBehavior = panel.collectionBehavior
        tray.alphaValue = 0
        let trayBackground = NSVisualEffectView.darkGlass(radius: 14)
        tray.contentView = trayBackground
        trayStack.orientation = .horizontal
        trayStack.spacing = 2
        trayStack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        trayStack.translatesAutoresizingMaskIntoConstraints = false
        trayBackground.addSubview(trayStack)
        NSLayoutConstraint.activate([
            trayStack.leadingAnchor.constraint(equalTo: trayBackground.leadingAnchor),
            trayStack.trailingAnchor.constraint(equalTo: trayBackground.trailingAnchor),
            trayStack.topAnchor.constraint(equalTo: trayBackground.topAnchor),
            trayStack.bottomAnchor.constraint(equalTo: trayBackground.bottomAnchor),
        ])

        stack.addArrangedSubview(Toolbar.divider())
        modes.selectedSegment = 0
        for (index, width) in [CGFloat(72), 58, 104].enumerated() {
            modes.setWidth(width, forSegment: index)
        }
        modes.segmentStyle = .rounded
        modes.appearance = NSAppearance(named: .darkAqua)
        modes.target = self
        modes.action = #selector(modeChanged)
        modes.setAccessibilityLabel("Pointer mode")
        modes.setToolTip("Click and drag in macOS normally", forSegment: 0)
        modes.setToolTip("Draw without clicking the app underneath", forSegment: 1)
        modes.setToolTip("Draw a shape, then save the area inside it", forSegment: 2)
        stack.addArrangedSubview(modes)
        stack.addArrangedSubview(Toolbar.divider())
        let ink = makeButton(image: nil, tip: "Ink colour") { [weak self] in
            self?.toggleInk()
        }
        inkButton = ink
        stack.addArrangedSubview(ink)
        let save = makeButton(symbol: "square.and.arrow.down", tip: "Save Drawing as PNG") { [weak self] in
            self?.onSave?()
        }
        save.isEnabled = false
        saveButton = save
        stack.addArrangedSubview(save)
        stack.addArrangedSubview(makeButton(symbol: "trash", tip: "Clear Drawing and Selection") { [weak self] in
            self?.onClear?()
        })
        let sound = makeButton(symbol: "speaker.wave.2.fill", tip: "Tap sound") { [weak self] in
            self?.onToggleSound?()
        }
        soundButton = sound
        stack.addArrangedSubview(sound)
        stack.addArrangedSubview(makeButton(symbol: "xmark", tip: "Exit  (Esc)") { [weak self] in
            self?.onExit?()
        })

        permissionButton.bezelStyle = .rounded
        permissionButton.isBordered = false
        permissionButton.wantsLayer = true
        permissionButton.layer?.cornerRadius = 10
        permissionButton.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        permissionButton.attributedTitle = NSAttributedString(string: "  Allow clicks & drawing  ", attributes: [
            .foregroundColor: NSColor.black,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
        permissionButton.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        permissionButton.imagePosition = .imageLeading
        permissionButton.contentTintColor = .black
        permissionButton.toolTip = "TinyHand needs Accessibility permission to intercept clicks and draw"
        permissionButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        permissionButton.target = self
        permissionButton.action = #selector(fixPermission)
        permissionButton.isHidden = true
        stack.addArrangedSubview(permissionButton)

        rebuildStyles()
        background.removeFocusRings()
        resize()
        refreshInk()
        NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildStyles()
            self?.refreshInk()
        }
    }

    @objc private func modeChanged() {
        guard PointerMode.allCases.indices.contains(modes.selectedSegment) else { return }
        onModeChanged?(PointerMode.allCases[modes.selectedSegment])
    }

    func setMode(_ mode: PointerMode, canSave: Bool) {
        modes.selectedSegment = PointerMode.allCases.firstIndex(of: mode) ?? 0
        let tip = mode == .screenshot ? "Save Selected Area as PNG" : "Save Drawing as PNG"
        saveButton?.toolTip = tip
        saveButton?.setAccessibilityLabel(tip)
        saveButton?.isEnabled = canSave
    }

    private func toggleInk() {
        setInkOpen(!inkOpen)
    }

    private func setInkOpen(_ open: Bool) {
        guard open != inkOpen, let ink = inkButton else {
            return
        }
        inkOpen = open
        if open {
            if swatches.isEmpty {
                for choice in InkChoice.allCases {
                    let b = makeButton(image: nil, tip: choice.title, side: 30) { [weak self] in
                        Preferences.inkChoice = choice
                        self?.setInkOpen(false)
                    }
                    b.layer?.cornerRadius = 15
                    swatches[choice] = b
                    trayStack.addArrangedSubview(b)
                }
                tray.contentView?.removeFocusRings()
                trayStack.layoutSubtreeIfNeeded()
                tray.setContentSize(trayStack.fittingSize)
            }
            refreshInk()
            let r = panel.convertToScreen(ink.convert(ink.bounds, to: nil))
            let size = tray.frame.size
            tray.setFrameOrigin(CGPoint(x: r.midX - size.width / 2, y: panel.frame.maxY + 8))
            tray.invalidateShadow()
            tray.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                tray.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                tray.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self = self, !self.inkOpen else {
                    return
                }
                self.tray.orderOut(nil)
            })
        }
        refreshInk()
    }

    private func refreshInk() {
        guard let ink = inkButton else {
            return
        }
        let style = current ?? PointerStyle.saved
        ink.image = Toolbar.inkDot(Preferences.inkChoice.resolved(for: style))
        ink.layer?.backgroundColor = inkOpen ? NSColor(white: 1, alpha: 0.18).cgColor : NSColor.clear.cgColor
        let hidden = !Preferences.showInkButton
        if ink.isHidden != hidden {
            ink.isHidden = hidden
            if hidden {
                setInkOpen(false)
            }
            resizeKeepingCenter()
        }
        for (choice, b) in swatches {
            b.image = choice.color.map(Toolbar.inkDot) ?? Toolbar.rainbowDot()
            b.layer?.backgroundColor = choice == Preferences.inkChoice ? NSColor(white: 1, alpha: 0.2).cgColor : NSColor.clear.cgColor
        }
    }

    private func resizeKeepingCenter() {
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.minY)
        resize()
        panel.setFrameOrigin(CGPoint(x: center.x - panel.frame.width / 2, y: center.y))
    }

    private func rebuildStyles() {
        var styles = Preferences.pinnedStyles
        if let c = current, !styles.contains(c) {
            styles.append(c)
        }
        if styles == shownStyles {
            return
        }
        shownStyles = styles
        for b in styleButtons.values {
            actions[b] = nil
            b.removeFromSuperview()
        }
        styleButtons = [:]
        for (i, style) in styles.enumerated() {
            let b = makeButton(image: Toolbar.icon(for: style), tip: style.title) { [weak self] in
                self?.onPick?(style)
            }
            styleButtons[style] = b
            stack.insertArrangedSubview(b, at: i)
        }
        if let c = current {
            highlight(c)
        }
        resizeKeepingCenter()
    }

    func setSoundOn(_ on: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let name = on ? "speaker.wave.2.fill" : "speaker.slash.fill"
        let tip = on ? "Tap sound on — click to mute" : "Tap sound off — click to unmute"
        soundButton?.image = NSImage(systemSymbolName: name, accessibilityDescription: tip)?.withSymbolConfiguration(config)
        soundButton?.toolTip = tip
        soundButton?.contentTintColor = NSColor(white: 1, alpha: on ? 0.85 : 0.45)
    }

    func center(of style: PointerStyle) -> CGPoint? {
        guard let b = styleButtons[style], let w = b.window else {
            return nil
        }
        let r = w.convertToScreen(b.convert(b.bounds, to: nil))
        return CGPoint(x: r.midX, y: r.midY)
    }

    func center(of mode: PointerMode) -> CGPoint? {
        guard let index = PointerMode.allCases.firstIndex(of: mode) else { return nil }
        let r = panel.convertToScreen(modes.convert(modes.bounds, to: nil))
        let widths = PointerMode.allCases.indices.map { modes.width(forSegment: $0) }
        let padding = (r.width - widths.reduce(0, +)) / 2
        return CGPoint(x: r.minX + padding + widths.prefix(index).reduce(0, +) + widths[index] / 2, y: r.midY)
    }

    func snapshot() -> NSBitmapImageRep? {
        guard let view = panel.contentView else {
            return nil
        }
        view.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        view.layer?.backgroundColor = nil
        return rep
    }

    func snapshotInkTray() -> NSBitmapImageRep? {
        setInkOpen(true)
        guard let view = tray.contentView else {
            return nil
        }
        view.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    func showHint(_ parts: [(key: String, text: String)]) {
        hideHint()
        let p = Panel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 36),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = panel.level
        p.collectionBehavior = panel.collectionBehavior
        p.alphaValue = 0
        let bg = NSVisualEffectView.darkGlass(radius: 12)
        p.contentView = bg
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 9, left: 16, bottom: 9, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        for part in parts {
            let text = NSMutableAttributedString(string: part.key, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
            text.append(NSAttributedString(string: " " + part.text, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: NSColor(white: 1, alpha: 0.7),
            ]))
            row.addArrangedSubview(NSTextField(labelWithAttributedString: text))
        }
        bg.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            row.topAnchor.constraint(equalTo: bg.topAnchor),
            row.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        row.layoutSubtreeIfNeeded()
        p.setContentSize(row.fittingSize)
        p.setFrameOrigin(CGPoint(x: panel.frame.midX - p.frame.width / 2, y: panel.frame.maxY + 12))
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
        hint = p
    }

    func snapshotHint() -> NSBitmapImageRep? {
        guard let view = hint?.contentView else {
            return nil
        }
        view.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    func hideHint() {
        guard let p = hint else {
            return
        }
        hint = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    func select(_ style: PointerStyle) {
        current = style
        rebuildStyles()
        highlight(style)
        refreshInk()
    }

    private func highlight(_ style: PointerStyle) {
        for (s, b) in styleButtons {
            b.layer?.backgroundColor = s == style ? NSColor(white: 1, alpha: 0.18).cgColor : NSColor.clear.cgColor
        }
    }

    func setNeedsPermission(_ needed: Bool) {
        guard permissionButton.isHidden == needed else {
            return
        }
        permissionButton.isHidden = !needed
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.minY)
        resize()
        panel.setFrameOrigin(CGPoint(x: center.x - panel.frame.width / 2, y: center.y))
    }

    func place(on screen: NSScreen) {
        setInkOpen(false)
        let f = panel.frame
        panel.setFrameOrigin(CGPoint(x: screen.frame.midX - f.width / 2, y: screen.visibleFrame.minY + 14))
    }

    func show() {
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func hide() {
        setInkOpen(false)
        tray.orderOut(nil)
        hint?.orderOut(nil)
        hideHint()
        revealed = false
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    func setRevealed(_ value: Bool) {
        guard value != revealed else {
            return
        }
        revealed = value
        if !value {
            setInkOpen(false)
        }
        panel.ignoresMouseEvents = !value
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = value ? 0.15 : 0.35
            panel.animator().alphaValue = value ? 1 : 0
        }
    }

    private func resize() {
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        panel.setContentSize(size)
        panel.invalidateShadow()
    }

    private var actions: [Button: () -> Void] = [:]

    private func makeButton(image: NSImage? = nil, symbol: String? = nil, tip: String, side: CGFloat = 40, action: @escaping () -> Void) -> Button {
        let b = Button()
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imageScaling = .scaleProportionallyUpOrDown
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.wantsLayer = true
        b.layer?.cornerRadius = 10
        if let image = image {
            b.image = image
        }
        if let symbol = symbol {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
            b.contentTintColor = NSColor(white: 1, alpha: 0.85)
            b.imageScaling = .scaleNone
        }
        b.widthAnchor.constraint(equalToConstant: side).isActive = true
        b.heightAnchor.constraint(equalToConstant: side).isActive = true
        b.target = self
        b.action = #selector(tapped(_:))
        actions[b] = action
        return b
    }

    @objc private func tapped(_ sender: Button) {
        actions[sender]?()
    }

    @objc private func fixPermission() {
        onFixPermission?()
    }

    private static func inkDot(_ color: CGColor) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r: CGFloat = 13
            NSColor(white: 0, alpha: 0.35).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - r - 1.5, y: c.y - r - 2.5, width: 2 * r + 3, height: 2 * r + 3)).fill()
            (NSColor(cgColor: color) ?? .white).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
            NSColor(white: 1, alpha: 0.35).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - r * 0.55, y: c.y + r * 0.15, width: r * 0.7, height: r * 0.5)).fill()
            return true
        }
    }

    private static func rainbowDot() -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r: CGFloat = 13
            NSColor(white: 0, alpha: 0.35).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - r - 1.5, y: c.y - r - 2.5, width: 2 * r + 3, height: 2 * r + 3)).fill()
            let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
            for (i, color) in colors.enumerated() {
                let path = NSBezierPath()
                path.move(to: c)
                path.appendArc(withCenter: c, radius: r, startAngle: CGFloat(i) * 60 + 90, endAngle: CGFloat(i + 1) * 60 + 90)
                path.close()
                color.setFill()
                path.fill()
            }
            return true
        }
    }

    private static func divider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return v
    }

    static func icon(for style: PointerStyle) -> NSImage? {
        if let name = style.assetName {
            return HandAsset.thumbnail(name)
        }
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let red = NSColor(cgColor: Ink.red) ?? .systemRed
            let glow = NSGradient(colors: [red.withAlphaComponent(0.55), red.withAlphaComponent(0)])
            glow?.draw(in: NSBezierPath(ovalIn: rect.insetBy(dx: 14, dy: 14)), relativeCenterPosition: .zero)
            red.setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)).fill()
            NSColor(srgbRed: 1, green: 0.86, blue: 0.82, alpha: 0.95).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)).fill()
            return true
        }
    }
}
