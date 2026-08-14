import ApplicationServices
import CryptoKit
import Foundation

enum AccessibilityWindowIdentity {
    static func digest(for window: AXUIElement) throws -> String {
        let fields = [
            string(window, kAXIdentifierAttribute),
            string(window, kAXDocumentAttribute),
            string(window, kAXTitleAttribute),
            string(window, kAXRoleAttribute),
            string(window, kAXSubroleAttribute)
        ]
        guard fields.contains(where: { $0?.isEmpty == false }) else {
            throw NativeWindowControlError.targetUnsupported("identity_unavailable")
        }
        return SHA256.hash(data: Data(fields.map { $0 ?? "" }.joined(separator: "\u{1f}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

public struct NativeWindowTargetSnapshot: Codable, Equatable {
    public let schemaVersion = "macctl-window-target/v1"
    public let processID: Int32
    public let windowRef: String
    public let identitySource: String
    public let unique: Bool
    public let focused: Bool
    public let visible: Bool
    public let frame: NativeWindowFrame
    public let displayID: UInt32?
    public let movable: Bool
    public let resizable: Bool
    public let minimized: Bool
    public let fullscreen: Bool

    public init(
        snapshot: NativeWindowSnapshot,
        unique: Bool,
        focused: Bool,
        visible: Bool
    ) {
        processID = snapshot.processID
        windowRef = snapshot.identityDigest
        identitySource = "ax_identity_digest"
        self.unique = unique
        self.focused = focused
        self.visible = visible
        frame = snapshot.frame
        displayID = snapshot.displayID
        movable = snapshot.movable
        resizable = snapshot.resizable
        minimized = snapshot.minimized
        fullscreen = snapshot.fullscreen
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case processID = "process_id"
        case windowRef = "window_ref"
        case identitySource = "identity_source"
        case unique, focused, visible, frame
        case displayID = "display_id"
        case movable, resizable, minimized, fullscreen
    }
}

public struct NativeWindowTargetCatalog: Codable, Equatable {
    public let schemaVersion = "macctl-window-target-catalog/v1"
    public let processID: Int32
    public let windows: [NativeWindowTargetSnapshot]
    public let omittedWindowCount: Int

    public init(
        processID: Int32,
        windows: [NativeWindowTargetSnapshot],
        omittedWindowCount: Int
    ) {
        self.processID = processID
        self.windows = windows
        self.omittedWindowCount = omittedWindowCount
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case processID = "process_id"
        case windows
        case omittedWindowCount = "omitted_window_count"
    }
}

public protocol NativeWindowTargetInspecting {
    func listWindows(pid: pid_t, displays: [NativeWindowDisplay]) throws -> NativeWindowTargetCatalog
    func inspectWindow(
        pid: pid_t,
        windowRef: String,
        displays: [NativeWindowDisplay]
    ) throws -> NativeWindowTargetSnapshot
}

/// Brings one PID-bound Accessibility window forward and returns only after
/// both macOS foreground ownership and the AX focused-window identity agree.
/// Implementations must fail closed if either oracle is unavailable.
public protocol NativeWindowForegroundActivating {
    func activateWindow(
        pid: pid_t,
        windowRef: String,
        displays: [NativeWindowDisplay]
    ) throws -> NativeWindowTargetSnapshot
}
