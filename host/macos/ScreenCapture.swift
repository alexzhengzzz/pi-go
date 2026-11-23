import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenCapture {
    static func writeResult(to directory: URL) async {
        let status: String
        if !CGPreflightScreenCaptureAccess() {
            status = "permission_denied"
        } else {
            do {
                status = try await capture(to: directory.appendingPathComponent("screenshot.jpg"))
            } catch {
                status = "capture_failed"
            }
        }
        try? Data(status.utf8).write(to: directory.appendingPathComponent("status"), options: .atomic)
    }

    private static func capture(to output: URL) async throws -> String {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
            return "display_unavailable"
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        let height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        guard width > 0, height > 0 else { return "display_unavailable" }
        let scale = min(1, 1920.0 / Double(max(width, height)))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(Double(width) * scale))
        configuration.height = max(1, Int(Double(height) * scale))
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let encoder = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return "capture_failed"
        }
        CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        return CGImageDestinationFinalize(encoder) ? "ok" : "capture_failed"
    }
}
