import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

public enum AccessibilityControllerError: Error, LocalizedError {
    case permissionDenied
    case elementNotFound
    case actionFailed(String)
    case boundsUnavailable

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Accessibility permission is missing for the macctl host"
        case .elementNotFound:
            return "No Accessibility element matched the selector"
        case .actionFailed(let action):
            return "Accessibility action failed: \(action)"
        case .boundsUnavailable:
            return "Accessibility element has no usable screen bounds"
        }
    }
}

public final class AccessibilityController {
    public init() {}

    public func findElement(pid: pid_t, selector: Selector) throws -> AXUIElement {
        guard PermissionDiagnostics.hasAccessibility() else {
            throw AccessibilityControllerError.permissionDenied
        }
        let application = AXUIElementCreateApplication(pid)
        if let focused = elementAttribute(application, kAXFocusedUIElementAttribute),
           matches(focused, selector: selector) {
            return focused
        }
        let windows = (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for window in windows {
            if let match = search(window, selector: selector, maxNodes: 8_000) {
                return match
            }
        }
        if matches(application, selector: selector) {
            return application
        }
        throw AccessibilityControllerError.elementNotFound
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

    public func title(of element: AXUIElement) -> String? {
        attribute(element, kAXTitleAttribute) as? String
    }

    public func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute) as? String
    }

    private func search(
        _ element: AXUIElement,
        selector: Selector,
        maxNodes: Int,
        visited: inout Int
    ) -> AXUIElement? {
        guard visited < maxNodes else { return nil }
        visited += 1
        if matches(element, selector: selector) { return element }
        let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for child in children {
            if let match = search(child, selector: selector, maxNodes: maxNodes, visited: &visited) {
                return match
            }
        }
        return nil
    }

    private func search(_ element: AXUIElement, selector: Selector, maxNodes: Int) -> AXUIElement? {
        var visited = 0
        return search(element, selector: selector, maxNodes: maxNodes, visited: &visited)
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
