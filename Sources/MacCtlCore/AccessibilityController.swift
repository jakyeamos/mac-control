import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

public enum AccessibilityControllerError: Error, LocalizedError {
    case permissionDenied
    case applicationNotRunning
    case elementNotFound
    case ambiguousMatch(Int)
    case windowNotFound
    case ambiguousWindowMatch(Int)
    case unreadableFocus
    case actionUnavailable(String)
    case actionFailed(String)
    case boundsUnavailable
    case scrollTargetRequired
    case scrollUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Accessibility permission is missing for the macctl host"
        case .applicationNotRunning:
            return "The requested application is not running, so its Accessibility tree is unavailable"
        case .elementNotFound:
            return "No Accessibility element matched the selector"
        case .ambiguousMatch(let count):
            return "Accessibility selector matched \(count) elements; the target was not unique"
        case .windowNotFound:
            return "No Accessibility window matched the selector's window scope"
        case .ambiguousWindowMatch(let count):
            return "Accessibility window scope matched \(count) windows; the window was not unique"
        case .unreadableFocus:
            return "The focused Accessibility element could not be read"
        case .actionUnavailable(let action):
            return "Accessibility action is not exposed by the target: \(action)"
        case .actionFailed(let action):
            return "Accessibility action failed: \(action)"
        case .boundsUnavailable:
            return "Accessibility element has no usable screen bounds"
        case .scrollTargetRequired:
            return "Semantic scrolling requires an AXScrollArea selector that resolves to one unique target"
        case .scrollUnavailable(let direction):
            return "Accessibility scrolling is not available in direction: \(direction)"
        }
    }
}

/// Projects the same redacted accessible name that the tree inspector exposes.
/// Native controls do not consistently put that name in AXTitle; some use
/// AXDescription or AXHelp instead. Selectors must address the exposed name
/// without reading private text or relying on coordinates.
enum AccessibilitySelectorLabel {
    static func preferred(
        title: String?,
        description: String?,
        help: String?
    ) -> String? {
        [title, description, help]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .first
    }

    static func matchesExact(
        _ expected: String,
        title: String?,
        description: String?,
        help: String?
    ) -> Bool {
        preferred(title: title, description: description, help: help) == expected
    }

    static func contains(
        _ expected: String,
        title: String?,
        description: String?,
        help: String?,
        value: String?
    ) -> Bool {
        preferred(title: title, description: description, help: help)?
            .localizedCaseInsensitiveContains(expected) == true
            || value?.localizedCaseInsensitiveContains(expected) == true
    }
}

private struct ContextMenuObservation {
    let visible: Bool
    let visibleItemCount: Int
    let labels: [String]
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
        var visitedElements = Set<UInt64>()
        func append(_ element: AXUIElement) {
            let identity = UInt64(CFHash(element))
            guard identities.insert(identity).inserted else { return }
            found.append(element)
        }
        var visited = 0
        var truncated = false
        let windows = (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let hasWindowScope = selector.windowTitle != nil || selector.windowIdentifier != nil
        let scopedWindows = try scopedWindows(windows, selector: selector)
        if !hasWindowScope,
           let focused = elementAttribute(application, kAXFocusedUIElementAttribute),
           self.matches(focused, selector: selector) {
            append(focused)
        }
        for window in scopedWindows {
            search(
                window,
                selector: selector,
                maxNodes: nodeLimit,
                found: &found,
                identities: &identities,
                visitedElements: &visitedElements,
                visited: &visited,
                truncated: &truncated
            )
        }
        // Some native result menus are exposed as application-level children
        // rather than descendants of AXWindows. Walk both surfaces while
        // de-duplicating handles so a structurally unique result remains
        // addressable without coordinates.
        if !hasWindowScope {
            let applicationChildren = (attribute(application, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            for child in applicationChildren {
                search(
                    child,
                    selector: selector,
                    maxNodes: nodeLimit,
                    found: &found,
                    identities: &identities,
                    visitedElements: &visitedElements,
                    visited: &visited,
                    truncated: &truncated
                )
            }
            if self.matches(application, selector: selector) {
                append(application)
            }
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

    public func showContextMenu(
        pid: pid_t,
        selector: Selector,
        expectedMenuItems: [String]
    ) throws -> ContextMenuReport {
        let element = try findElement(pid: pid, selector: selector)
        let availableActions = actionNames(of: element)
        guard availableActions.contains(kAXShowMenuAction as String) else {
            throw AccessibilityControllerError.actionUnavailable(kAXShowMenuAction as String)
        }
        guard AXUIElementPerformAction(element, kAXShowMenuAction as CFString) == .success else {
            throw AccessibilityControllerError.actionFailed(kAXShowMenuAction as String)
        }
        return waitForContextMenu(pid: pid, expectedMenuItems: expectedMenuItems)
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
        let role = attribute(focused, kAXRoleAttribute) as? String
        let subrole = attribute(focused, kAXSubroleAttribute) as? String
        let identifier = attribute(focused, kAXIdentifierAttribute) as? String
        let title = attribute(focused, kAXTitleAttribute) as? String
        let frame = (try? bounds(of: focused)).map {
            "\($0.origin.x),\($0.origin.y),\($0.size.width),\($0.size.height)"
        }
        let structuralIdentity = [role, subrole, identifier, title, frame]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "|")
        return FocusedElementSnapshot(
            targetApplication: application,
            role: role,
            subrole: subrole,
            identifier: identifier,
            title: title,
            identityFingerprint: structuralIdentity.isEmpty
                ? nil
                : ControlTargetFingerprints.structuralDigest(structuralIdentity)
        )
    }

    private func search(
        _ element: AXUIElement,
        selector: Selector,
        maxNodes: Int,
        found: inout [AXUIElement],
        identities: inout Set<UInt64>,
        visitedElements: inout Set<UInt64>,
        visited: inout Int,
        truncated: inout Bool
    ) {
        guard visited < maxNodes else {
            truncated = true
            return
        }
        guard visitedElements.insert(UInt64(CFHash(element))).inserted else {
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
                visitedElements: &visitedElements,
                visited: &visited,
                truncated: &truncated
            )
        }
    }

    private func scopedWindows(
        _ windows: [AXUIElement],
        selector: Selector
    ) throws -> [AXUIElement] {
        guard selector.windowTitle != nil || selector.windowIdentifier != nil else {
            return windows
        }
        let matches = windows.filter { window in
            if let expectedTitle = selector.windowTitle,
               expectedTitle != (attribute(window, kAXTitleAttribute) as? String) {
                return false
            }
            if let expectedIdentifier = selector.windowIdentifier,
               expectedIdentifier != (attribute(window, kAXIdentifierAttribute) as? String) {
                return false
            }
            return true
        }
        guard !matches.isEmpty else { throw AccessibilityControllerError.windowNotFound }
        guard matches.count == 1 else {
            throw AccessibilityControllerError.ambiguousWindowMatch(matches.count)
        }
        return matches
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        var raw: CFArray?
        guard AXUIElementCopyActionNames(element, &raw) == .success,
              let raw,
              let names = raw as? [String] else { return [] }
        return names
    }

    private func waitForContextMenu(
        pid: pid_t,
        expectedMenuItems: [String]
    ) -> ContextMenuReport {
        let expected = Set(expectedMenuItems.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
        let deadline = Date().addingTimeInterval(1.0)
        var latest = ContextMenuObservation(visible: false, visibleItemCount: 0, labels: [])
        while true {
            latest = inspectContextMenu(pid: pid)
            let matched = matchedMenuItemCount(expected: expected, labels: latest.labels)
            if latest.visible && (expected.isEmpty || matched == expected.count) {
                return ContextMenuReport(
                    state: .passed,
                    targetResolved: true,
                    menuVisible: true,
                    expectedItemCount: expected.count,
                    matchedItemCount: matched,
                    visibleItemCount: latest.visibleItemCount
                )
            }
            guard Date() < deadline else { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        let matched = matchedMenuItemCount(expected: expected, labels: latest.labels)
        return ContextMenuReport(
            state: .verificationUnavailable,
            targetResolved: true,
            menuVisible: latest.visible,
            expectedItemCount: expected.count,
            matchedItemCount: matched,
            visibleItemCount: latest.visibleItemCount
        )
    }

    private func inspectContextMenu(pid: pid_t) -> ContextMenuObservation {
        let application = AXUIElementCreateApplication(pid)
        let roots = ((attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? [])
            + ((attribute(application, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
        var visited = Set<UInt64>()
        var visible = false
        var visibleItemCount = 0
        var labels: [String] = []

        func walk(_ element: AXUIElement, insideVisibleMenu: Bool, depth: Int) {
            guard depth < 32, visited.insert(UInt64(CFHash(element))).inserted else { return }
            let role = attribute(element, kAXRoleAttribute) as? String
            let hidden = (attribute(element, kAXHiddenAttribute) as? Bool) ?? false
            let isVisibleMenu = insideVisibleMenu || (role == "AXMenu" && !hidden)
            if role == "AXMenu" && !hidden { visible = true }
            if role == "AXMenuItem" && isVisibleMenu && !hidden {
                visibleItemCount += 1
                if let label = AccessibilitySelectorLabel.preferred(
                    title: attribute(element, kAXTitleAttribute) as? String,
                    description: attribute(element, kAXDescriptionAttribute) as? String,
                    help: attribute(element, kAXHelpAttribute) as? String
                ) {
                    labels.append(label.lowercased())
                }
            }
            let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            for child in children {
                walk(child, insideVisibleMenu: isVisibleMenu, depth: depth + 1)
            }
        }

        for root in roots {
            walk(root, insideVisibleMenu: false, depth: 0)
        }
        return ContextMenuObservation(
            visible: visible,
            visibleItemCount: visibleItemCount,
            labels: labels
        )
    }

    private func matchedMenuItemCount(expected: Set<String>, labels: [String]) -> Int {
        expected.reduce(into: 0) { count, item in
            if labels.contains(where: { $0 == item }) { count += 1 }
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
        if let title = selector.title,
           !AccessibilitySelectorLabel.matchesExact(
               title,
               title: attribute(element, kAXTitleAttribute) as? String,
               description: attribute(element, kAXDescriptionAttribute) as? String,
               help: attribute(element, kAXHelpAttribute) as? String
           ) {
            return false
        }
        if let subrole = selector.subrole,
           subrole != (attribute(element, kAXSubroleAttribute) as? String) {
            return false
        }
        if let text = selector.containsText {
            guard AccessibilitySelectorLabel.contains(
                text,
                title: attribute(element, kAXTitleAttribute) as? String,
                description: attribute(element, kAXDescriptionAttribute) as? String,
                help: attribute(element, kAXHelpAttribute) as? String,
                value: attribute(element, kAXValueAttribute) as? String
            ) else {
                return false
            }
        }
        return selector.role != nil || selector.identifier != nil || selector.title != nil
            || selector.subrole != nil || selector.containsText != nil
    }

    func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success else { return nil }
        return value as AnyObject?
    }

    func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name) else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
