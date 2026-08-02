import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

public enum AccessibilityControllerError: Error, LocalizedError {
    case permissionDenied
    case elementNotFound
    case ambiguousMatch(Int)
    case unreadableFocus
    case actionFailed(String)
    case boundsUnavailable

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Accessibility permission is missing for the macctl host"
        case .elementNotFound:
            return "No Accessibility element matched the selector"
        case .ambiguousMatch(let count):
            return "Accessibility selector matched \(count) elements; the target was not unique"
        case .unreadableFocus:
            return "The focused Accessibility element could not be read"
        case .actionFailed(let action):
            return "Accessibility action failed: \(action)"
        case .boundsUnavailable:
            return "Accessibility element has no usable screen bounds"
        }
    }
}

public final class AccessibilityController: FocusedElementInspecting {
    public init() {}

    public func findElement(pid: pid_t, selector: Selector) throws -> AXUIElement {
        let matches = try findElements(pid: pid, selector: selector)
        guard let element = matches.first else {
            throw AccessibilityControllerError.elementNotFound
        }
        guard matches.count == 1 else {
            throw AccessibilityControllerError.ambiguousMatch(matches.count)
        }
        return element
    }

    /// Resolves all matches so callers can fail closed on ambiguous targets.
    /// The returned AX objects are short-lived runtime handles and must not be
    /// serialized or retained in checkpoints.
    public func findElements(
        pid: pid_t,
        selector: Selector,
        maxNodes: Int = 8_000
    ) throws -> [AXUIElement] {
        guard PermissionDiagnostics.hasAccessibility() else {
            throw AccessibilityControllerError.permissionDenied
        }
        let nodeLimit = min(max(1, maxNodes), 8_000)
        let application = AXUIElementCreateApplication(pid)
        var found: [AXUIElement] = []
        var identities = Set<UInt64>()
        func append(_ element: AXUIElement) {
            let identity = UInt64(CFHash(element))
            guard identities.insert(identity).inserted else { return }
            found.append(element)
        }
        if let focused = elementAttribute(application, kAXFocusedUIElementAttribute),
           self.matches(focused, selector: selector) {
            append(focused)
        }
        var visited = 0
        var truncated = false
        let windows = (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for window in windows {
            search(
                window,
                selector: selector,
                maxNodes: nodeLimit,
                found: &found,
                identities: &identities,
                visited: &visited,
                truncated: &truncated
            )
        }
        if self.matches(application, selector: selector) {
            append(application)
        }
        guard !truncated else {
            throw AccessibilityControllerError.ambiguousMatch(max(found.count + 1, 2))
        }
        return found
    }

    @discardableResult
    public func press(pid: pid_t, selector: Selector) throws -> CGRect {
        let element = try findElement(pid: pid, selector: selector)
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return try bounds(of: element)
        }
        throw AccessibilityControllerError.actionFailed(kAXPressAction as String)
    }

    @discardableResult
    public func setValue(pid: pid_t, selector: Selector, value: String) throws -> CGRect? {
        let element = try findElement(pid: pid, selector: selector)
        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFTypeRef
        ) == .success else {
            throw AccessibilityControllerError.actionFailed(kAXValueAttribute as String)
        }
        return try? bounds(of: element)
    }

    @discardableResult
    public func raiseFocusedWindow(pid: pid_t) throws -> CGRect? {
        guard PermissionDiagnostics.hasAccessibility() else {
            throw AccessibilityControllerError.permissionDenied
        }
        let application = AXUIElementCreateApplication(pid)
        let window = elementAttribute(application, kAXFocusedWindowAttribute)
            ?? (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first
        guard let window else { throw AccessibilityControllerError.elementNotFound }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return try? bounds(of: window)
    }

    public func bounds(of element: AXUIElement) throws -> CGRect {
        guard let value = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute) else {
            throw AccessibilityControllerError.boundsUnavailable
        }
        var position = CGPoint.zero
        var dimensions = CGSize.zero
        let positionValue = unsafeBitCast(value, to: AXValue.self)
        let sizeValue = unsafeBitCast(size, to: AXValue.self)
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &dimensions) else {
            throw AccessibilityControllerError.boundsUnavailable
        }
        return CGRect(origin: position, size: dimensions)
    }

    public func windowBounds(pid: pid_t) -> CGRect? {
        guard PermissionDiagnostics.hasAccessibility() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        let window = elementAttribute(application, kAXFocusedWindowAttribute)
            ?? (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first
        guard let window else { return nil }
        return try? bounds(of: window)
    }

    /// Returns only structural window state.  No AX value, document text, or
    /// child tree is exposed to callers.
    public func windowState(pid: pid_t) throws -> AccessibilityWindowState {
        guard PermissionDiagnostics.hasAccessibility() else {
            throw AccessibilityControllerError.permissionDenied
        }
        let application = AXUIElementCreateApplication(pid)
        guard let window = elementAttribute(application, kAXFocusedWindowAttribute)
            ?? (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first else {
            throw AccessibilityControllerError.elementNotFound
        }
        let role = attribute(window, kAXRoleAttribute) as? String
        let subrole = attribute(window, kAXSubroleAttribute) as? String
        let hidden = (attribute(window, kAXHiddenAttribute) as? Bool) ?? false
        let modal = ["AXSheet", "AXDialog", "AXSystemDialog"].contains(role)
            || ["AXDialog", "AXSystemDialog"].contains(subrole)
        let identity = [role, subrole, attribute(window, kAXIdentifierAttribute) as? String,
                        attribute(window, kAXTitleAttribute) as? String]
            .compactMap { $0 }
            .joined(separator: "|")
        return AccessibilityWindowState(
            visible: !hidden,
            modal: modal,
            identityFingerprint: ControlTargetFingerprints.structuralDigest(identity)
        )
    }

    public func title(of element: AXUIElement) -> String? {
        attribute(element, kAXTitleAttribute) as? String
    }

    public func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute) as? String
    }

    public func focusedElementSnapshot(
        pid: pid_t,
        application: AppInfo
    ) throws -> FocusedElementSnapshot {
        guard PermissionDiagnostics.hasAccessibility() else {
            throw AccessibilityControllerError.permissionDenied
        }
        let applicationElement = AXUIElementCreateApplication(pid)
        guard let focused = elementAttribute(applicationElement, kAXFocusedUIElementAttribute) else {
            throw AccessibilityControllerError.unreadableFocus
        }
        return FocusedElementSnapshot(
            targetApplication: application,
            role: attribute(focused, kAXRoleAttribute) as? String,
            subrole: attribute(focused, kAXSubroleAttribute) as? String,
            identifier: attribute(focused, kAXIdentifierAttribute) as? String,
            title: attribute(focused, kAXTitleAttribute) as? String
        )
    }

    private func search(
        _ element: AXUIElement,
        selector: Selector,
        maxNodes: Int,
        found: inout [AXUIElement],
        identities: inout Set<UInt64>,
        visited: inout Int,
        truncated: inout Bool
    ) {
        guard visited < maxNodes else {
            truncated = true
            return
        }
        visited += 1
        if self.matches(element, selector: selector) {
            let identity = UInt64(CFHash(element))
            if identities.insert(identity).inserted {
                found.append(element)
            }
        }
        let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for child in children {
            search(
                child,
                selector: selector,
                maxNodes: maxNodes,
                found: &found,
                identities: &identities,
                visited: &visited,
                truncated: &truncated
            )
        }
    }

    private func matches(_ element: AXUIElement, selector: Selector) -> Bool {
        if let role = selector.role, role != (attribute(element, kAXRoleAttribute) as? String) {
            return false
        }
        if let identifier = selector.identifier,
           identifier != (attribute(element, kAXIdentifierAttribute) as? String) {
            return false
        }
        if let title = selector.title, title != (attribute(element, kAXTitleAttribute) as? String) {
            return false
        }
        if let subrole = selector.subrole,
           subrole != (attribute(element, kAXSubroleAttribute) as? String) {
            return false
        }
        if let text = selector.containsText {
            let title = (attribute(element, kAXTitleAttribute) as? String) ?? ""
            let value = (attribute(element, kAXValueAttribute) as? String) ?? ""
            guard title.localizedCaseInsensitiveContains(text)
                || value.localizedCaseInsensitiveContains(text) else {
                return false
            }
        }
        return selector.role != nil || selector.identifier != nil || selector.title != nil
            || selector.subrole != nil || selector.containsText != nil
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success else { return nil }
        return value as AnyObject?
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name) else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
