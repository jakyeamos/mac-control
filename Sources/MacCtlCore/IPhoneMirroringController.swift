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
        try inputController.key("cmd+1")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try inputController.key("cmd+3")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try inputController.key("cmd+a")
        try inputController.type(name)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let spotlightFrame = try captureController.capture(surface: .iphoneMirroring)
        let spotlightResult = try captureController.ocr(spotlightFrame)
        guard let spotlightMatch = spotlightResult.matches.first(where: {
            $0.text.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw IPhoneMirroringError.appNotFound(name)
        }
        // Spotlight's result bounds are in the captured image's coordinate space,
        // while CGEvent coordinates are in global display space. Move focus from
        // the search field to the matched result, then open it with Return.
        try inputController.key("down")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try inputController.key("return")
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        return spotlightMatch
    }

    public func verifyMirroredAppVisible(_ name: String) throws -> OCRResult {
        let frame = try captureController.capture(surface: .iphoneMirroring)
        let result = try captureController.ocr(frame)
        if result.contains(name) {
            return result
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedName == "tinder" {
            let markers = ["Swipe", "Explore", "Likes", "Chat", "Profile"]
            let visibleMarkers = markers.filter(result.contains)
            guard visibleMarkers.count >= 3 else {
                throw IPhoneMirroringError.appNotVisible(name)
            }
            return result
        }
        throw IPhoneMirroringError.appNotVisible(name)
    }

    public func verifyMirroredAppForeground(_ name: String) throws -> IPhoneMirroringState {
        let current = state()
        if current.foreground && current.windowDetected {
            return current
        }
        _ = try activate()
        let restored = state()
        guard restored.foreground && restored.windowDetected else {
            throw IPhoneMirroringError.appNotVisible(name)
        }
        return restored
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
