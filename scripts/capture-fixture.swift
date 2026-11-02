import AppKit

final class FixtureView: NSView {
    override func draw(_ rect: NSRect) {
        NSColor(srgbRed: 0.13, green: 0.22, blue: 0.31, alpha: 1).setFill()
        bounds.fill()
        ("TinyHand" as NSString).draw(at: CGPoint(x: bounds.midX - 165, y: bounds.height * 0.74),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 64, weight: .semibold),
                                                     .foregroundColor: NSColor.white])
        ("Pointer  /  Draw  /  Screenshot" as NSString).draw(
            at: CGPoint(x: bounds.midX - 192, y: bounds.height * 0.68),
            withAttributes: [.font: NSFont.systemFont(ofSize: 25, weight: .medium),
                             .foregroundColor: NSColor(srgbRed: 0.76, green: 0.85, blue: 0.91, alpha: 1)])
        ("Captured" as NSString).draw(
            at: CGPoint(x: bounds.midX - 105, y: bounds.midY - 20),
            withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium),
                             .foregroundColor: NSColor.white])
        ("Native macOS capture fixture - no personal desktop content" as NSString).draw(
            at: CGPoint(x: bounds.midX - 232, y: bounds.height * 0.20),
            withAttributes: [.font: NSFont.systemFont(ofSize: 16),
                             .foregroundColor: NSColor(srgbRed: 0.76, green: 0.85, blue: 0.91, alpha: 1)])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard let screen = NSScreen.screens.first else { exit(1) }
let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
window.contentView = FixtureView(frame: CGRect(origin: .zero, size: screen.frame.size))
window.level = .screenSaver
window.ignoresMouseEvents = true
window.isOpaque = true
window.orderFrontRegardless()
Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { _ in app.terminate(nil) }
print("fixture ready")
fflush(stdout)
app.run()
