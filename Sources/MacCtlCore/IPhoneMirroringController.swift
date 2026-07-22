import AppKit
import Foundation

public enum IPhoneMirroringError: Error, LocalizedError {
    case unavailable
    case appNotFound(String)
    case appNotVisible(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "iPhone Mirroring is not available in the current Mac session"
        case .appNotFound(let name):
            return "The mirrored iPhone app was not visible through OCR: \(name)"
        case .appNotVisible(let name):
            return "The mirrored iPhone app could not be verified as foreground: \(name)"
        }
    }
}

public struct IPhoneMirroringState: Codable, Equatable {
    public let installed: Bool
    public let running: Bool
    public let foreground: Bool
    public let windowDetected: Bool
    public let deviceBackend: String

    public init(
        installed: Bool,
        running: Bool,
        foreground: Bool,
        windowDetected: Bool,
        deviceBackend: String
    ) {
        self.installed = installed
        self.running = running
        self.foreground = foreground
        self.windowDetected = windowDetected
        self.deviceBackend = deviceBackend
    }
}

public final class IPhoneMirroringController {
    private let appController: AppController
    private let captureController: CaptureController
    private let inputController: InputController

    public init(
        appController: AppController = AppController(),
        captureController: CaptureController? = nil,
        inputController: InputController = InputController()
    ) {
        self.appController = appController
        self.captureController = captureController ?? CaptureController(appController: appController)
        self.inputController = inputController
    }

    public func state() -> IPhoneMirroringState {
        let installed = (try? appController.resolve("iPhone Mirroring")) != nil
        let foreground = appController.foregroundApplication()?.name == "iPhone Mirroring"
        let running = appController.listApplications().first(where: { $0.name == "iPhone Mirroring" })?.isRunning ?? false
        let windowDetected = (try? captureController.capture(surface: .iphoneMirroring)) != nil
        return IPhoneMirroringState(
            installed: installed,
            running: running,
            foreground: foreground,
            windowDetected: windowDetected,
            deviceBackend: "consumer_mirroring"
        )
    }

    @discardableResult
    public func activate() throws -> IPhoneMirroringState {
        guard (try? appController.resolve("iPhone Mirroring")) != nil else {
            throw IPhoneMirroringError.unavailable
        }
        _ = try appController.activate("iPhone Mirroring")
        return state()
    }

    public func openMirroredApp(_ name: String) throws -> OCRMatch {
        _ = try activate()
        let frame = try captureController.capture(surface: .iphoneMirroring)
        let result = try captureController.ocr(frame)
        guard let match = result.matches.first(where: {
            $0.text.localizedCaseInsensitiveContains(name)
        }) else {
            throw IPhoneMirroringError.appNotFound(name)
        }
        try inputController.click(at: CGPoint(x: match.bounds.midX, y: match.bounds.midY))
        return match
    }

    public func verifyMirroredAppVisible(_ name: String) throws -> OCRResult {
        let frame = try captureController.capture(surface: .iphoneMirroring)
        let result = try captureController.ocr(frame)
        guard result.contains(name) else {
            throw IPhoneMirroringError.appNotVisible(name)
        }
        return result
    }

    public func optionalDeveloperDeviceSummary() -> String {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            return "unavailable"
        }
        let result = try? ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["devicectl", "list", "devices"],
            timeout: 5
        )
        guard let result, result.status == 0 else { return "unavailable" }
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.isEmpty ? "available_no_devices" : "available"
    }
}
