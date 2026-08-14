import ApplicationServices
import AppKit
import CoreGraphics
import CryptoKit
import Foundation

public enum NativeWindowLayoutName: String, Codable, CaseIterable, Equatable {
    case maximize
    case center
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"
    case leftThird = "left-third"
    case centerThird = "center-third"
    case rightThird = "right-third"
    case leftTwoThirds = "left-two-thirds"
    case rightTwoThirds = "right-two-thirds"
    case topLeftQuarter = "top-left-quarter"
    case topRightQuarter = "top-right-quarter"
    case bottomLeftQuarter = "bottom-left-quarter"
    case bottomRightQuarter = "bottom-right-quarter"
}

public struct NativeWindowFrame: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ frame: CGRect) {
        self.init(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct NativeWindowDisplay: Codable, Equatable {
    public let id: UInt32
    public let name: String
    public let visibleFrame: NativeWindowFrame

    public init(id: UInt32, name: String, visibleFrame: NativeWindowFrame) {
        self.id = id
        self.name = name
        self.visibleFrame = visibleFrame
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case visibleFrame = "visible_frame"
    }
}

public struct NativeWindowDisplayCatalog: Codable, Equatable {
    public let schemaVersion = "macctl-window-displays/v1"
    public let displays: [NativeWindowDisplay]
    public let layouts: [String]

    public init(displays: [NativeWindowDisplay]) {
        self.displays = displays.sorted { $0.id < $1.id }
        self.layouts = NativeWindowLayoutName.allCases.map(\.rawValue)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case displays, layouts
    }
}

public protocol NativeWindowDisplayProviding {
    func connectedDisplays() -> [NativeWindowDisplay]
}

public struct SystemNativeWindowDisplayProvider: NativeWindowDisplayProviding {
    public init() {}

    public func connectedDisplays() -> [NativeWindowDisplay] {
        _ = NSApplication.shared
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(number.uint32Value)
            let displayBounds = CGDisplayBounds(id)
            let screenFrame = screen.frame
            let visible = screen.visibleFrame
            // AX and Core Graphics use a top-left global coordinate system;
            // NSScreen uses bottom-left coordinates. Preserve the usable insets
            // while anchoring them to the authoritative Core Graphics display.
            let left = visible.minX - screenFrame.minX
            let right = screenFrame.maxX - visible.maxX
            let top = screenFrame.maxY - visible.maxY
            let bottom = visible.minY - screenFrame.minY
            let usable = CGRect(
                x: displayBounds.minX + left,
                y: displayBounds.minY + top,
                width: max(0, displayBounds.width - left - right),
                height: max(0, displayBounds.height - top - bottom)
            )
            return NativeWindowDisplay(
                id: id,
                name: screen.localizedName,
                visibleFrame: NativeWindowFrame(usable)
            )
        }
    }
}

public enum NativeWindowLayoutResolver {
    public static func frame(
        for layout: NativeWindowLayoutName,
        in visibleFrame: NativeWindowFrame
    ) -> NativeWindowFrame {
        let bounds = visibleFrame.cgRect
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NativeWindowFrame {
            let minX = rounded(x)
            let minY = rounded(y)
            let maxX = rounded(x + width)
            let maxY = rounded(y + height)
            return NativeWindowFrame(CGRect(
                x: minX, y: minY,
                width: max(0, maxX - minX), height: max(0, maxY - minY)
            ).intersection(bounds))
        }
        let halfWidth = bounds.width / 2
        let halfHeight = bounds.height / 2
        let thirdWidth = bounds.width / 3
        switch layout {
        case .maximize:
            return NativeWindowFrame(bounds)
        case .center:
            let width = bounds.width * 0.8
            let height = bounds.height * 0.8
            return rect(bounds.midX - width / 2, bounds.midY - height / 2, width, height)
        case .leftHalf:
            return rect(bounds.minX, bounds.minY, halfWidth, bounds.height)
        case .rightHalf:
            return rect(bounds.midX, bounds.minY, bounds.maxX - bounds.midX, bounds.height)
        case .topHalf:
            return rect(bounds.minX, bounds.minY, bounds.width, halfHeight)
        case .bottomHalf:
            return rect(bounds.minX, bounds.midY, bounds.width, bounds.maxY - bounds.midY)
        case .leftThird:
            return rect(bounds.minX, bounds.minY, thirdWidth, bounds.height)
        case .centerThird:
            return rect(bounds.minX + thirdWidth, bounds.minY, thirdWidth, bounds.height)
        case .rightThird:
            return rect(bounds.minX + 2 * thirdWidth, bounds.minY, bounds.maxX - (bounds.minX + 2 * thirdWidth), bounds.height)
        case .leftTwoThirds:
            return rect(bounds.minX, bounds.minY, 2 * thirdWidth, bounds.height)
        case .rightTwoThirds:
            return rect(bounds.minX + thirdWidth, bounds.minY, bounds.maxX - (bounds.minX + thirdWidth), bounds.height)
        case .topLeftQuarter:
            return rect(bounds.minX, bounds.minY, halfWidth, halfHeight)
        case .topRightQuarter:
            return rect(bounds.midX, bounds.minY, bounds.maxX - bounds.midX, halfHeight)
        case .bottomLeftQuarter:
            return rect(bounds.minX, bounds.midY, halfWidth, bounds.maxY - bounds.midY)
        case .bottomRightQuarter:
            return rect(bounds.midX, bounds.midY, bounds.maxX - bounds.midX, bounds.maxY - bounds.midY)
        }
    }

    private static func rounded(_ value: CGFloat) -> CGFloat {
        value.rounded(.toNearestOrAwayFromZero)
    }
}

public struct NativeWindowSnapshot: Codable, Equatable {
    public let schemaVersion = "macctl-window-snapshot/v1"
    public let processID: Int32
    public let identityDigest: String
    public let frame: NativeWindowFrame
    public let displayID: UInt32?
    public let movable: Bool
    public let resizable: Bool
    public let minimized: Bool
    public let fullscreen: Bool

    public init(
        processID: Int32,
        identityDigest: String,
        frame: NativeWindowFrame,
        displayID: UInt32?,
        movable: Bool,
        resizable: Bool,
        minimized: Bool,
        fullscreen: Bool
    ) {
        self.processID = processID
        self.identityDigest = identityDigest
        self.frame = frame
        self.displayID = displayID
        self.movable = movable
        self.resizable = resizable
        self.minimized = minimized
        self.fullscreen = fullscreen
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case processID = "process_id"
        case identityDigest = "identity_digest"
        case frame
        case displayID = "display_id"
        case movable, resizable, minimized, fullscreen
    }
}

public enum NativeWindowControlError: Error, LocalizedError, Equatable {
    case permissionDenied
    case targetMissing
    case targetAmbiguous
    case targetUnsupported(String)
    case displayUnavailable(UInt32)
    case confirmationRequired
    case verificationUnavailable
    case restoreNotFound
    case restoreExpired
    case restoreAlreadyUsed

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Accessibility permission is required for native window control"
        case .targetMissing: return "The requested window could not be resolved"
        case .targetAmbiguous: return "The requested window identity matched more than one visible window"
        case .targetUnsupported(let reason): return "The requested window cannot be placed: \(reason)"
        case .displayUnavailable(let id): return "The requested display is not connected: \(id)"
        case .confirmationRequired: return "Native window mutation requires explicit confirmation"
        case .verificationUnavailable: return "The window frame could not be independently verified"
        case .restoreNotFound: return "The restore token was not found"
        case .restoreExpired: return "The restore token expired"
        case .restoreAlreadyUsed: return "The restore token was already used"
        }
    }
}

public protocol NativeWindowControlling {
    func focusedWindow(pid: pid_t, displays: [NativeWindowDisplay]) throws -> NativeWindowSnapshot
    func setFrame(
        pid: pid_t,
        identityDigest: String,
        frame: NativeWindowFrame,
        displays: [NativeWindowDisplay]
    ) throws -> NativeWindowSnapshot
}

public final class AccessibilityNativeWindowController: NativeWindowControlling,
    NativeWindowTargetInspecting, NativeWindowForegroundActivating {
    private let processActivator: (pid_t) -> Bool

    public init(
        processActivator: @escaping (pid_t) -> Bool = { pid in
            guard let application = NSRunningApplication(processIdentifier: pid),
                  !application.isTerminated else {
                return false
            }
            return application.activate(options: [.activateIgnoringOtherApps])
        }
    ) {
        self.processActivator = processActivator
    }

    public func listWindows(
        pid: pid_t,
        displays: [NativeWindowDisplay]
    ) throws -> NativeWindowTargetCatalog {
        guard PermissionDiagnostics.hasAccessibility() else { throw NativeWindowControlError.permissionDenied }
        let app = AXUIElementCreateApplication(pid)
        let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let focusedWindow = element(app, kAXFocusedWindowAttribute)
        var resolved: [(snapshot: NativeWindowSnapshot, focused: Bool, visible: Bool)] = []
        var omittedWindowCount = 0
        for window in windows {
            do {
                resolved.append((
                    snapshot: try snapshot(window, pid: pid, displays: displays),
                    focused: focusedWindow.map { CFEqual($0, window) } ?? false,
                    visible: !bool(window, kAXHiddenAttribute)
                ))
            } catch let error as NativeWindowControlError {
                if case .permissionDenied = error { throw error }
                omittedWindowCount += 1
            }
        }
        let counts = Dictionary(grouping: resolved, by: { $0.snapshot.identityDigest })
            .mapValues(\.count)
        return NativeWindowTargetCatalog(
            processID: pid,
            windows: resolved.map { item in
                NativeWindowTargetSnapshot(
                    snapshot: item.snapshot,
                    unique: counts[item.snapshot.identityDigest] == 1,
                    focused: item.focused,
                    visible: item.visible
                )
            },
            omittedWindowCount: omittedWindowCount
        )
    }

    public func inspectWindow(
        pid: pid_t,
        windowRef: String,
        displays: [NativeWindowDisplay]
    ) throws -> NativeWindowTargetSnapshot {
        guard PermissionDiagnostics.hasAccessibility() else { throw NativeWindowControlError.permissionDenied }
        let app = AXUIElementCreateApplication(pid)
        let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let matches = windows.filter { (try? digest(for: $0)) == windowRef }
        guard matches.count == 1, let window = matches.first else {
            throw matches.isEmpty ? NativeWindowControlError.targetMissing : NativeWindowControlError.targetAmbiguous
        }
        let focusedWindow = element(app, kAXFocusedWindowAttribute)
        return NativeWindowTargetSnapshot(
            snapshot: try snapshot(window, pid: pid, displays: displays),
            unique: true,
            focused: focusedWindow.map { CFEqual($0, window) } ?? false,
            visible: !bool(window, kAXHiddenAttribute)
        )
    }

    public func activateWindow(
        pid: pid_t,
        windowRef: String,
        displays: [NativeWindowDisplay]
    ) throws -> NativeWindowTargetSnapshot {
        guard PermissionDiagnostics.hasAccessibility() else { throw NativeWindowControlError.permissionDenied }
        let app = AXUIElementCreateApplication(pid)
        let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let matches = windows.filter { (try? digest(for: $0)) == windowRef }
        guard matches.count == 1, let window = matches.first else {
            throw matches.isEmpty ? NativeWindowControlError.targetMissing : NativeWindowControlError.targetAmbiguous
        }
        guard !bool(window, kAXHiddenAttribute), !bool(window, kAXMinimizedAttribute) else {
            throw NativeWindowControlError.targetUnsupported("window_not_visible")
        }

        // NSRunningApplication is used only as a PID-specific actuator; it is
        // never accepted as proof of input ownership. AX mutations remain
        // bound to objects created for the requested PID, and the independent
        // NSWorkspace PID plus AX focused-window oracles below must both pass.
        guard processActivator(pid),
              AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success,
              AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue) == .success,
              AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
            throw NativeWindowControlError.targetUnsupported("exact_activation_failed")
        }

        let deadline = Date().addingTimeInterval(2)
        repeat {
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let focusedWindow = element(app, kAXFocusedWindowAttribute)
            if frontmostPID == pid,
               let focusedWindow,
               (try? digest(for: focusedWindow)) == windowRef {
                let observed = try inspectWindow(pid: pid, windowRef: windowRef, displays: displays)
                guard observed.unique, observed.focused, observed.visible, !observed.minimized else {
                    throw NativeWindowControlError.verificationUnavailable
                }
                return observed
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        throw NativeWindowControlError.verificationUnavailable
    }

    public func focusedWindow(pid: pid_t, displays: [NativeWindowDisplay]) throws -> NativeWindowSnapshot {
        guard PermissionDiagnostics.hasAccessibility() else { throw NativeWindowControlError.permissionDenied }
        let app = AXUIElementCreateApplication(pid)
        guard let window = element(app, kAXFocusedWindowAttribute) else { throw NativeWindowControlError.targetMissing }
        return try snapshot(window, pid: pid, displays: displays)
    }

    public func setFrame(
        pid: pid_t,
        identityDigest: String,
        frame: NativeWindowFrame,
        displays: [NativeWindowDisplay]
    ) throws -> NativeWindowSnapshot {
        guard PermissionDiagnostics.hasAccessibility() else { throw NativeWindowControlError.permissionDenied }
        let app = AXUIElementCreateApplication(pid)
        let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let matches = try windows.filter { window in
            guard !bool(window, kAXHiddenAttribute), !bool(window, kAXMinimizedAttribute) else { return false }
            return try digest(for: window) == identityDigest
        }
        guard matches.count == 1, let window = matches.first else {
            throw matches.isEmpty ? NativeWindowControlError.targetMissing : NativeWindowControlError.targetAmbiguous
        }
        let before = try snapshot(window, pid: pid, displays: displays)
        guard before.movable else { throw NativeWindowControlError.targetUnsupported("not_movable") }
        guard before.resizable else { throw NativeWindowControlError.targetUnsupported("not_resizable") }
        guard !before.fullscreen else { throw NativeWindowControlError.targetUnsupported("fullscreen") }
        var position = frame.cgRect.origin
        var size = frame.cgRect.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size),
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success,
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success else {
            throw NativeWindowControlError.targetUnsupported("frame_mutation_failed")
        }
        let observed = try snapshot(window, pid: pid, displays: displays)
        guard observed.identityDigest == identityDigest,
              approximatelyEqual(observed.frame.cgRect, frame.cgRect, tolerance: 2) else {
            throw NativeWindowControlError.verificationUnavailable
        }
        return observed
    }

    private func snapshot(_ window: AXUIElement, pid: pid_t, displays: [NativeWindowDisplay]) throws -> NativeWindowSnapshot {
        guard let positionValue = attribute(window, kAXPositionAttribute),
              let sizeValue = attribute(window, kAXSizeAttribute) else {
            throw NativeWindowControlError.verificationUnavailable
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else {
            throw NativeWindowControlError.verificationUnavailable
        }
        let frame = CGRect(origin: point, size: size)
        return NativeWindowSnapshot(
            processID: pid,
            identityDigest: try digest(for: window),
            frame: NativeWindowFrame(frame),
            displayID: display(containing: frame, displays: displays)?.id,
            movable: settable(window, kAXPositionAttribute),
            resizable: settable(window, kAXSizeAttribute),
            minimized: bool(window, kAXMinimizedAttribute),
            fullscreen: bool(window, "AXFullScreen")
        )
    }

    private func digest(for window: AXUIElement) throws -> String {
        try AccessibilityWindowIdentity.digest(for: window)
    }

    private func display(containing frame: CGRect, displays: [NativeWindowDisplay]) -> NativeWindowDisplay? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let containing = displays.first(where: { $0.visibleFrame.cgRect.contains(center) }) {
            return containing
        }
        let overlapping = displays.map { ($0, $0.visibleFrame.cgRect.intersection(frame).area) }
            .filter { $0.1 > 0 }
        return overlapping.max(by: { $0.1 < $1.1 })?.0
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        attribute(element, name).map { unsafeBitCast($0, to: AXUIElement.self) }
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
    private func bool(_ element: AXUIElement, _ name: String) -> Bool { (attribute(element, name) as? Bool) ?? false }
    private func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

public struct NativeWindowPlacementReport: Codable, Equatable {
    public let schemaVersion = "macctl-window-placement/v1"
    public let application: String
    public let layout: NativeWindowLayoutName
    public let displayID: UInt32
    public let previousFrame: NativeWindowFrame
    public let observedFrame: NativeWindowFrame
    public let restoreToken: String
    public let restoreExpiresAt: Date
    public let verification: String

    public init(application: String, layout: NativeWindowLayoutName, displayID: UInt32, previousFrame: NativeWindowFrame, observedFrame: NativeWindowFrame, restoreToken: String, restoreExpiresAt: Date) {
        self.application = application
        self.layout = layout
        self.displayID = displayID
        self.previousFrame = previousFrame
        self.observedFrame = observedFrame
        self.restoreToken = restoreToken
        self.restoreExpiresAt = restoreExpiresAt
        self.verification = "passed"
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case application, layout
        case displayID = "display_id"
        case previousFrame = "previous_frame"
        case observedFrame = "observed_frame"
        case restoreToken = "restore_token"
        case restoreExpiresAt = "restore_expires_at"
        case verification
    }
}

public struct NativeWindowRestoreReport: Codable, Equatable {
    public let schemaVersion = "macctl-window-restore/v1"
    public let application: String
    public let observedFrame: NativeWindowFrame
    public let verification = "passed"

    public init(application: String, observedFrame: NativeWindowFrame) {
        self.application = application
        self.observedFrame = observedFrame
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case application
        case observedFrame = "observed_frame"
        case verification
    }
}

public final class NativeWindowRestoreStore {
    public struct Record: Equatable {
        public let token: String
        public let application: String
        public let processID: Int32
        public let identityDigest: String
        public let frame: NativeWindowFrame
        public let displayID: UInt32
        public let expiresAt: Date
        fileprivate var used: Bool
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private let now: () -> Date
    private let lifetime: TimeInterval

    public init(now: @escaping () -> Date = Date.init, lifetime: TimeInterval = 300) {
        self.now = now
        self.lifetime = min(max(lifetime, 30), 900)
    }

    public func issue(application: String, snapshot: NativeWindowSnapshot) throws -> Record {
        guard let displayID = snapshot.displayID else { throw NativeWindowControlError.verificationUnavailable }
        lock.lock()
        defer { lock.unlock() }
        let token = UUID().uuidString
        let record = Record(token: token, application: application, processID: snapshot.processID, identityDigest: snapshot.identityDigest, frame: snapshot.frame, displayID: displayID, expiresAt: now().addingTimeInterval(lifetime), used: false)
        records[token] = record
        return record
    }

    public func record(token: String) throws -> Record {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[token] else { throw NativeWindowControlError.restoreNotFound }
        guard !record.used else { throw NativeWindowControlError.restoreAlreadyUsed }
        guard record.expiresAt > now() else { throw NativeWindowControlError.restoreExpired }
        return record
    }

    public func consume(token: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var record = records[token] else { throw NativeWindowControlError.restoreNotFound }
        guard !record.used else { throw NativeWindowControlError.restoreAlreadyUsed }
        record.used = true
        records[token] = record
    }
}
