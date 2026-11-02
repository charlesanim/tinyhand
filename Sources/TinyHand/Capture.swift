import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case emptyDrawing, emptySelection, imageCreation, displayUnavailable, permission, captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyDrawing: return "Draw something first, then choose Save Drawing."
        case .emptySelection: return "Draw a shape with an area at least 4 points wide and tall."
        case .imageCreation: return "The PNG could not be created. Try a smaller drawing or selection."
        case .displayUnavailable: return "The selected display is no longer available."
        case .permission: return "Allow TinyHand in System Settings > Privacy & Security > Screen Recording, then try again. macOS may require you to quit and reopen TinyHand."
        case .captureFailed(let detail): return "Screen capture failed: \(detail)"
        }
    }
}

enum Capture {
    static func drawing(_ strokes: [Ink.Stroke], scale: CGFloat) throws -> CGImage {
        guard !strokes.isEmpty else { throw CaptureError.emptyDrawing }
        let bounds = strokes.reduce(CGRect.null) {
            $0.union($1.path.boundingBoxOfPath.insetBy(dx: -$1.width / 2 - 2, dy: -$1.width / 2 - 2))
        }.integral
        let context = try bitmap(bounds: bounds, scale: scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            context.setStrokeColor(stroke.color)
            context.setLineWidth(stroke.width)
            context.addPath(stroke.path)
            context.strokePath()
        }
        guard let image = context.makeImage() else { throw CaptureError.imageCreation }
        return image
    }

    static func selection(_ points: [CGPoint]) throws -> CGPath {
        guard points.count >= 3, let first = points.first else { throw CaptureError.emptySelection }
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        let bounds = path.boundingBoxOfPath
        let hasArea = zip(points.dropFirst(), points.dropFirst(2)).contains { pair in
            let a = pair.0, b = pair.1
            let left: CGFloat = (a.x - first.x) * (b.y - first.y)
            let right: CGFloat = (a.y - first.y) * (b.x - first.x)
            return abs(left - right) >= 4
        }
        guard bounds.width >= 4, bounds.height >= 4, hasArea else { throw CaptureError.emptySelection }
        return path
    }

    static func screenshot(_ image: CGImage, path: CGPath, screenSize: CGSize) throws -> CGImage {
        let screen = CGRect(origin: .zero, size: screenSize)
        let bounds = path.boundingBoxOfPath.integral.intersection(screen)
        guard !bounds.isNull, bounds.width >= 4, bounds.height >= 4 else { throw CaptureError.emptySelection }
        let context = try bitmap(bounds: bounds, scale: CGFloat(image.width) / screenSize.width)
        context.addPath(path)
        context.clip(using: .evenOdd)
        context.draw(image, in: screen)
        guard let result = context.makeImage() else { throw CaptureError.imageCreation }
        return result
    }

    private static func bitmap(bounds: CGRect, scale: CGFloat) throws -> CGContext {
        let width = ceil(bounds.width * scale), height = ceil(bounds.height * scale)
        guard scale.isFinite, scale > 0, width.isFinite, height.isFinite,
              width > 0, height > 0, width * height <= 100_000_000,
              let context = CGContext(data: nil, width: Int(width), height: Int(height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.imageCreation
        }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        return context
    }

    static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CaptureError.imageCreation
        }
        return data
    }

    static func screen(id: CGDirectDisplayID, frame: CGRect) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError.displayUnavailable
            }
            let apps = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * CGFloat(filter.pointPixelScale))
            config.height = Int(CGFloat(display.height) * CGFloat(filter.pointPixelScale))
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        // macOS 13 predates SCScreenshotManager. The system tool also omits the cursor.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinyhand-\(UUID().uuidString).png")
                defer {
                    if FileManager.default.fileExists(atPath: url.path) {
                        do { try FileManager.default.removeItem(at: url) }
                        catch { Log.write("temporary screenshot cleanup failed: \(error.localizedDescription)") }
                    }
                }
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", "-R\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))", url.path]
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0,
                          let image = NSBitmapImageRep(data: try Data(contentsOf: url))?.cgImage else {
                        throw CaptureError.captureFailed("screencapture exited with status \(process.terminationStatus)")
                    }
                    continuation.resume(returning: image)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
