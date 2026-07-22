import ApplicationServices
import AppKit
import Foundation

public enum IPhoneMirroringError: Error, LocalizedError {
    case unavailable
    case connectionRequired(String)
    case appNotFound(String)
    case appNotVisible(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "iPhone Mirroring is not available in the current Mac session"
        case .connectionRequired(let message):
            return message
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
    public let connectionStatus: String
    public let recoveryReason: String?

    public init(
        installed: Bool,
        running: Bool,
        foreground: Bool,
        windowDetected: Bool,
        deviceBackend: String,
        connectionStatus: String = "unknown",
        recoveryReason: String? = nil
    ) {
        self.installed = installed
        self.running = running
        self.foreground = foreground
        self.windowDetected = windowDetected
        self.deviceBackend = deviceBackend
        self.connectionStatus = connectionStatus
        self.recoveryReason = recoveryReason
    }
}

public final class IPhoneMirroringController {
    static let searchFallbackPoint = NormalizedPoint(x: 0.5, y: 0.82)
    static let searchFieldFallbackPoint = NormalizedPoint(x: 0.5, y: 0.93)

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
        let app = try? appController.resolve("iPhone Mirroring")
        let installed = app != nil
        let foreground = appController.foregroundApplication()?.name == "iPhone Mirroring"
        let running = appController.listApplications().first(where: { $0.name == "iPhone Mirroring" })?.isRunning ?? false
        let windowDetected = (try? captureController.capture(surface: .iphoneMirroring)) != nil
        let recoveryReason = app.flatMap { mirroringRecoveryReason(pid: $0.processID) }
        return IPhoneMirroringState(
            installed: installed,
            running: running,
            foreground: foreground,
            windowDetected: windowDetected,
            deviceBackend: "consumer_mirroring",
            connectionStatus: recoveryReason == nil
                ? (windowDetected ? "available" : "unavailable")
                : "blocked",
            recoveryReason: recoveryReason
        )
    }

    @discardableResult
    public func activate() throws -> IPhoneMirroringState {
        guard (try? appController.resolve("iPhone Mirroring")) != nil else {
            throw IPhoneMirroringError.unavailable
        }
        let app = try appController.activate("iPhone Mirroring")
        if let processID = app.processID {
            focusWindow(processID: pid_t(processID))
        }
        return state()
    }

    public func openMirroredApp(_ name: String) throws -> OCRMatch {
        _ = try activate()
        if let recoveryReason = mirroringRecoveryReason() {
            throw IPhoneMirroringError.connectionRequired(recoveryReason)
        }
        try inputController.key("cmd+1")
        wait(0.4)

        let homeFrame = try captureController.capture(surface: .iphoneMirroring)
        let homeOCR = try captureController.ocr(homeFrame)
        if let searchMatch = homeOCR.matches.first(where: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Search") == .orderedSame
        }) {
            try inputController.click(at: CGPoint(x: searchMatch.bounds.midX, y: searchMatch.bounds.midY))
        } else {
            let fallbackPoint = try CoordinateMapper.windowPoint(
                normalized: Self.searchFallbackPoint,
                in: homeFrame.bounds
            )
            try inputController.click(at: fallbackPoint)
        }
        wait(0.3)
        let spotlightFrame = try captureController.capture(surface: .iphoneMirroring)
        let spotlightOCR = try captureController.ocr(spotlightFrame)
        if let searchField = spotlightOCR.matches.first(where: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Search") == .orderedSame
                && $0.bounds.minY > spotlightFrame.bounds.minY + spotlightFrame.bounds.height * 0.75
        }) {
            try inputController.click(at: CGPoint(x: searchField.bounds.midX, y: searchField.bounds.midY))
        } else {
            let fallbackPoint = try CoordinateMapper.windowPoint(
                normalized: Self.searchFieldFallbackPoint,
                in: spotlightFrame.bounds
            )
            try inputController.click(at: fallbackPoint)
        }
        wait(0.2)
        try inputController.type(name)
        wait(0.6)

        let resultFrame = try captureController.capture(surface: .iphoneMirroring)
        let spotlightResult = try captureController.ocr(resultFrame)
        guard let spotlightMatch = spotlightResult.matches.first(where: {
            $0.text.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw IPhoneMirroringError.appNotFound(name)
        }
        try inputController.click(at: CGPoint(x: spotlightMatch.bounds.midX, y: spotlightMatch.bounds.midY))
        wait(1.0)
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

    private func mirroringRecoveryReason(pid: pid_t? = nil) -> String? {
        let resolvedPID = pid ?? (try? appController.resolve("iPhone Mirroring"))?.processID
        guard let resolvedPID else { return nil }
        let application = AXUIElementCreateApplication(resolvedPID)
        var values: [String] = []
        collectAccessibilityText(from: application, values: &values, visited: 0)
        let text = values.joined(separator: " ").lowercased()
        if text.contains("ended due to iphone use") || text.contains("lock your iphone to connect") {
            return "iPhone Mirroring is paused because the iPhone is in use. Lock your iPhone to connect."
        }
        if text.contains("connect your iphone") {
            return "iPhone Mirroring is waiting for the iPhone to connect."
        }
        return nil
    }

    private func focusWindow(processID: pid_t) {
        let application = AXUIElementCreateApplication(processID)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return
        }
        let displayBounds = CGDisplayBounds(CGMainDisplayID())
        let safeBounds = displayBounds.insetBy(dx: 20, dy: 40)
        for window in windows {
            repositionIfNeeded(window, inside: safeBounds)
            _ = AXUIElementSetAttributeValue(
                window,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            _ = AXUIElementSetAttributeValue(
                window,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        wait(0.2)
    }

    private func repositionIfNeeded(_ window: AXUIElement, inside safeBounds: CGRect) {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                  window,
                  kAXSizeAttribute as CFString,
                  &sizeValue
              ) == .success,
              let positionValue,
              let sizeValue else {
            return
        }
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return
        }
        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(
            positionAXValue,
            .cgPoint,
            &position
        ), AXValueGetValue(
            sizeAXValue,
            .cgSize,
            &size
        ) else {
            return
        }
        let frame = CGRect(origin: position, size: size)
        guard !safeBounds.contains(frame) else { return }
        let target = CGPoint(
            x: safeBounds.maxX - min(size.width, safeBounds.width),
            y: safeBounds.minY
        )
        var mutableTarget = target
        if let targetValue = AXValueCreate(.cgPoint, &mutableTarget) {
            _ = AXUIElementSetAttributeValue(
                window,
                kAXPositionAttribute as CFString,
                targetValue
            )
        }
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func collectAccessibilityText(
        from element: AXUIElement,
        values: inout [String],
        visited: Int
    ) {
        guard visited < 5_000 else { return }
        for attribute in [kAXTitleAttribute, kAXValueAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let string = value as? String,
               !string.isEmpty {
                values.append(string)
            }
        }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return
        }
        for child in children {
            collectAccessibilityText(from: child, values: &values, visited: visited + 1)
        }
    }
}
