import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import Vision

public enum CaptureControllerError: Error, LocalizedError {
    case permissionDenied
    case displayUnavailable
    case windowUnavailable(String)
    case ocrFailed(String)
    case imageAnchorNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is missing for on-demand capture"
        case .displayUnavailable:
            return "The main display could not be captured"
        case .windowUnavailable(let name):
            return "No visible window was found for \(name)"
        case .ocrFailed(let message):
            return "Vision OCR failed: \(message)"
        case .imageAnchorNotFound(let path):
            return "No matching image anchor was found for \(path)"
        }
    }
}

public struct CaptureFrame {
    public let image: CGImage
    public let bounds: CGRect
    public let windowID: CGWindowID?
    public let source: String

    public init(image: CGImage, bounds: CGRect, windowID: CGWindowID?, source: String) {
        self.image = image
        self.bounds = bounds
        self.windowID = windowID
        self.source = source
    }
}

public struct OCRMatch: Equatable {
    public let text: String
    public let bounds: CGRect

    public init(text: String, bounds: CGRect) {
        self.text = text
        self.bounds = bounds
    }
}

public struct OCRResult: Equatable {
    public let text: String
    public let matches: [OCRMatch]

    public init(text: String, matches: [OCRMatch]) {
        self.text = text
        self.matches = matches
    }

    public func contains(_ expected: String) -> Bool {
        text.localizedCaseInsensitiveContains(expected)
    }
}

public struct ImageAnchorMatch: Equatable {
    public let bounds: CGRect
    public let score: Double

    public init(bounds: CGRect, score: Double) {
        self.bounds = bounds
        self.score = score
    }
}

public final class CaptureController {
    private let appController: AppController

    public init(appController: AppController = AppController()) {
        self.appController = appController
    }

    public func capture(surface: SurfaceKind, app: String? = nil) throws -> CaptureFrame {
        guard PermissionDiagnostics.hasScreenCaptureAccess() else {
            throw CaptureControllerError.permissionDenied
        }
        switch surface {
        case .macDesktop:
            guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
                throw CaptureControllerError.displayUnavailable
            }
            return CaptureFrame(
                image: image,
                bounds: CGDisplayBounds(CGMainDisplayID()),
                windowID: nil,
                source: "main_display"
            )
        case .macApp, .iphoneMirroring:
            let appName = app ?? (surface == .iphoneMirroring ? "iPhone Mirroring" : "")
            guard let window = visibleWindow(for: appName) else {
                throw CaptureControllerError.windowUnavailable(appName)
            }
            guard let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                window.id,
                [.bestResolution, .boundsIgnoreFraming]
            ) else {
                throw CaptureControllerError.windowUnavailable(appName)
            }
            return CaptureFrame(
                image: image,
                bounds: window.bounds,
                windowID: window.id,
                source: appName
            )
        }
    }

    public func ocr(_ frame: CaptureFrame) throws -> OCRResult {
        var observations: [VNRecognizedTextObservation] = []
        let request = VNRecognizeTextRequest { request, error in
            if error == nil {
                observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            }
        }
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.01
        let handler = VNImageRequestHandler(cgImage: frame.image, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            throw CaptureControllerError.ocrFailed(error.localizedDescription)
        }
        var matches: [OCRMatch] = []
        var textLines: [String] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let normalized = observation.boundingBox
            let imageBounds = CGRect(
                x: normalized.origin.x * CGFloat(frame.image.width),
                y: (1 - normalized.origin.y - normalized.height) * CGFloat(frame.image.height),
                width: normalized.width * CGFloat(frame.image.width),
                height: normalized.height * CGFloat(frame.image.height)
            )
            let scaleX = frame.bounds.width / CGFloat(frame.image.width)
            let scaleY = frame.bounds.height / CGFloat(frame.image.height)
            let globalBounds = CGRect(
                x: frame.bounds.minX + imageBounds.minX * scaleX,
                y: frame.bounds.minY + imageBounds.minY * scaleY,
                width: imageBounds.width * scaleX,
                height: imageBounds.height * scaleY
            )
            matches.append(OCRMatch(text: candidate.string, bounds: globalBounds))
            textLines.append(candidate.string)
        }
        return OCRResult(text: textLines.joined(separator: "\n"), matches: matches)
    }

    public func findImageAnchor(in frame: CaptureFrame, path: String) throws -> ImageAnchorMatch {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: expandedPath) as CFURL,
            nil
        ), let anchor = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureControllerError.imageAnchorNotFound(path)
        }

        let targetPixels = try SampledImage(frame.image)
        let anchorPixels = try SampledImage(anchor)
        let scales = [0.75, 1.0, 1.25, 1.5, 2.0]
        var best = ImageAnchorMatch(bounds: .zero, score: 1.0)

        for scale in scales {
            let width = Int((Double(anchorPixels.width) * scale).rounded())
            let height = Int((Double(anchorPixels.height) * scale).rounded())
            guard width >= 8, height >= 8,
                  width <= targetPixels.width, height <= targetPixels.height else { continue }
            let stride = max(2, min(width, height) / 12)
            let maxX = targetPixels.width - width
            let maxY = targetPixels.height - height
            for y in strideThrough(max: maxY, step: stride) {
                for x in strideThrough(max: maxX, step: stride) {
                    let score = targetPixels.score(
                        against: anchorPixels,
                        at: CGPoint(x: x, y: y),
                        size: CGSize(width: width, height: height)
                    )
                    if score < best.score {
                        best = ImageAnchorMatch(
                            bounds: globalBounds(
                                x: x,
                                y: y,
                                width: width,
                                height: height,
                                frame: frame
                            ),
                            score: score
                        )
                    }
                }
            }
        }

        guard best.score <= 0.22 else {
            throw CaptureControllerError.imageAnchorNotFound(path)
        }
        return best
    }

    public func screenCaptureKitAvailable() -> Bool {
        if #available(macOS 12.3, *) { return true }
        return false
    }

    private struct WindowInfo {
        let id: CGWindowID
        let bounds: CGRect
    }

    private struct SampledImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init(_ image: CGImage) throws {
            width = image.width
            height = image.height
            var rendered = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            let renderedSuccessfully = rendered.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.baseAddress,
                      let context = CGContext(
                          data: baseAddress,
                          width: image.width,
                          height: image.height,
                          bitsPerComponent: 8,
                          bytesPerRow: image.width * 4,
                          space: colorSpace,
                          bitmapInfo: bitmapInfo
                      ) else {
                    return false
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard renderedSuccessfully else {
                throw CaptureControllerError.imageAnchorNotFound("invalid image")
            }
            pixels = rendered
        }

        func score(against anchor: SampledImage, at origin: CGPoint, size: CGSize) -> Double {
            let sampleGrid = 8
            var total = 0.0
            for row in 0..<sampleGrid {
                for column in 0..<sampleGrid {
                    let anchorX = min(
                        anchor.width - 1,
                        Int((Double(column) / Double(sampleGrid - 1) * Double(anchor.width - 1)).rounded())
                    )
                    let anchorY = min(
                        anchor.height - 1,
                        Int((Double(row) / Double(sampleGrid - 1) * Double(anchor.height - 1)).rounded())
                    )
                    let targetX = min(
                        width - 1,
                        Int((
                            Double(origin.x)
                                + Double(column) / Double(sampleGrid - 1) * Double(max(0, size.width - 1))
                        ).rounded())
                    )
                    let targetY = min(
                        height - 1,
                        Int((
                            Double(origin.y)
                                + Double(row) / Double(sampleGrid - 1) * Double(max(0, size.height - 1))
                        ).rounded())
                    )
                    let anchorColor = anchor.color(at: anchorX, y: anchorY)
                    let targetColor = color(at: targetX, y: targetY)
                    total += (
                        abs(Double(anchorColor.0) - Double(targetColor.0))
                            + abs(Double(anchorColor.1) - Double(targetColor.1))
                            + abs(Double(anchorColor.2) - Double(targetColor.2))
                    ) / (255.0 * 3.0)
                }
            }
            return total / Double(sampleGrid * sampleGrid)
        }

        private func color(at x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = (y * width + x) * 4
            return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
        }
    }

    private func strideThrough(max: Int, step: Int) -> [Int] {
        guard max > 0 else { return [0] }
        var values = Array(stride(from: 0, through: max, by: step))
        if values.last != max { values.append(max) }
        return values
    }

    private func globalBounds(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        frame: CaptureFrame
    ) -> CGRect {
        let scaleX = frame.bounds.width / CGFloat(frame.image.width)
        let scaleY = frame.bounds.height / CGFloat(frame.image.height)
        return CGRect(
            x: frame.bounds.minX + CGFloat(x) * scaleX,
            y: frame.bounds.minY + CGFloat(frame.image.height - y - height) * scaleY,
            width: CGFloat(width) * scaleX,
            height: CGFloat(height) * scaleY
        )
    }

    private func visibleWindow(for name: String) -> WindowInfo? {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        let target: AppInfo?
        if name.isEmpty {
            target = nil
        } else {
            target = try? appController.resolve(name)
        }
        let targetPID = target?.processID.map(Int.init)
        for window in rawWindows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowNumber = window[kCGWindowNumber as String] as? UInt32,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                continue
            }
            let ownerPID = (window[kCGWindowOwnerPID as String] as? Int)
                ?? (window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue
            let ownerName = window[kCGWindowOwnerName as String] as? String
            if (targetPID != nil && ownerPID == targetPID) || (targetPID == nil && ownerName == name) {
                return WindowInfo(id: CGWindowID(windowNumber), bounds: bounds)
            }
        }
        return nil
    }
}
