import ApplicationServices
import AppKit
import CoreGraphics
import CryptoKit
import Foundation

/// Resolution may inspect a larger bounded surface than the default fast
/// selector lookup. Deep native and web-backed AX trees can exceed the audit
/// page size; the bound remains finite so an action can never become an
/// unbounded provider walk.
public enum AccessibilityResolutionBounds {
    public static let maximumNodes = 16_000
}

public enum AccessibilityControllerError: Error, LocalizedError {
    case permissionDenied
    case applicationNotRunning
    case elementNotFound
    case ambiguousMatch(Int)
    case resolutionIncomplete(Int)
    case windowNotFound
    case ambiguousWindowMatch(Int)
    case unreadableFocus
    case actionUnavailable(String)
    case semanticActivationUnavailable(
        role: String?,
        subrole: String?,
        advertisedActions: [String]
    )
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
        case .resolutionIncomplete(let count):
            return "Accessibility selector resolution reached its bounded search limit after observing \(count) candidate(s); uniqueness could not be proven"
        case .windowNotFound:
            return "No Accessibility window matched the selector's window scope"
        case .ambiguousWindowMatch(let count):
            return "Accessibility window scope matched \(count) windows; the window was not unique"
        case .unreadableFocus:
            return "The focused Accessibility element could not be read"
        case .actionUnavailable(let action):
            return "Accessibility action is not exposed by the target: \(action)"
        case let .semanticActivationUnavailable(role, subrole, advertisedActions):
            let actions = advertisedActions.sorted().joined(separator: ", ")
            return "Accessibility target \(role ?? "unknown")/\(subrole ?? "unknown") exposes presentation-only actions [\(actions)] but no activation action; hand off to Computer Use"
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
    let renderedMenuCount: Int
    let visibleItemCount: Int
    let labels: [String]
    let ambiguousMenuCandidates: Bool

    var menuVisible: Bool {
        renderedMenuCount == 1 && !ambiguousMenuCandidates
    }

    var visible: Bool {
        menuVisible && visibleItemCount > 0
    }
}

public final class AccessibilityController: FocusedElementInspecting {
    /// macOS sidebar rows can expose semantic UI actions instead of AXPress.
    /// Keep these names explicit because they are part of the provider's
    /// action contract, not guessed coordinate or keyboard fallbacks.
    public static let showDefaultUIAction = "AXShowDefaultUI"
    public static let showAlternateUIAction = "AXShowAlternateUI"

    public init() {}

    /// Select a native activation action for a target. AXPress is the only
    /// action whose Accessibility contract simulates clicking the element.
    /// AXShowDefaultUI/AXShowAlternateUI are presentation actions, even when
    /// System Settings advertises them on sidebar rows, so they must not be
    /// mistaken for row activation.
    public static func semanticActivationAction(
        role: String?,
        subrole: String?,
        actions: [String]
    ) -> String? {
        if actions.contains(kAXPressAction as String) {
            return kAXPressAction as String
        }
        return nil
    }

    /// Returns a presentation-only action exposed by a sidebar/outline row.
    /// This is recorded as capability evidence so an agent can explain the
    /// provider boundary, but it is never dispatched as an activation.
    public static func semanticPresentationAction(
        role: String?,
        subrole: String?,
        actions: [String]
    ) -> String? {
        guard role == "AXRow" || subrole == "AXOutlineRow" else {
            return nil
        }
        if actions.contains(showDefaultUIAction) {
            return showDefaultUIAction
        }
        if actions.contains(showAlternateUIAction) {
            return showAlternateUIAction
        }
        return nil
    }

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
        let nodeLimit = min(max(1, maxNodes), AccessibilityResolutionBounds.maximumNodes)
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
           self.matches(focused, selector: selector, ancestorDigest: nil) {
            append(focused)
        }
        for window in scopedWindows {
            guard found.count < 2 else { break }
            search(
                window,
                selector: selector,
                ancestorIdentityDigests: [],
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
                guard found.count < 2 else { break }
                // Ancestor-scoped locators are emitted by the windowed deep
                // audit. Do not search a second provider projection for them;
                // an app-level alias can otherwise make a unique audited
                // target appear ambiguous.
                guard selector.ancestorDigest == nil else { continue }
                // AXWindows are already traversed above. Some applications
                // expose the same window tree through both AXWindows and
                // application-level children, but return distinct runtime
                // handles for the two projections. Walking both can turn a
                // structurally unique selector into a false two-match result.
                // Keep the application-level pass for menus and other
                // non-window surfaces that are not reachable from a window.
                guard Self.shouldTraverseApplicationChild(
                    role: attribute(child, kAXRoleAttribute) as? String
                ) else { continue }
                search(
                    child,
                    selector: selector,
                    ancestorIdentityDigests: [],
                    maxNodes: nodeLimit,
                    found: &found,
                    identities: &identities,
                    visitedElements: &visitedElements,
                    visited: &visited,
                    truncated: &truncated
                )
            }
            if self.matches(application, selector: selector, ancestorDigest: nil) {
                append(application)
            }
        }
        guard !truncated else {
            throw AccessibilityControllerError.resolutionIncomplete(found.count)
        }
        return found
    }

    /// Window descendants are searched through AXWindows first. Application
    /// children with AXWindow role are aliases of that surface on some
    /// providers, not an additional target scope.
    static func shouldTraverseApplicationChild(role: String?) -> Bool {
        role != "AXWindow"
    }

    @discardableResult
    public func press(pid: pid_t, selector: Selector) throws -> CGRect {
        let element = try findElement(pid: pid, selector: selector)
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return try bounds(of: element)
        }
        throw AccessibilityControllerError.actionFailed(kAXPressAction as String)
    }

    /// Activates a uniquely resolved target using the action that the target
    /// actually advertises. Sidebar rows that expose only
    /// AXShowDefaultUI/AXShowAlternateUI are presentation-only on macOS;
    /// report an explicit provider handoff instead of dispatching a no-op.
    /// Rows that expose AXPress receive the task-specific selected-pane
    /// postcondition.
    @discardableResult
    public func activate(
        pid: pid_t,
        selector: Selector
    ) throws -> AccessibilityActivationReport {
        let element = try findElement(pid: pid, selector: selector)
        let role = attribute(element, kAXRoleAttribute) as? String
        let subrole = attribute(element, kAXSubroleAttribute) as? String
        let action = Self.semanticActivationAction(
            role: role,
            subrole: subrole,
            actions: actionNames(of: element)
        )
        guard let action else {
            let actions = actionNames(of: element)
            if Self.semanticPresentationAction(
                role: role,
                subrole: subrole,
                actions: actions
            ) != nil {
                throw AccessibilityControllerError.semanticActivationUnavailable(
                    role: role,
                    subrole: subrole,
                    advertisedActions: actions.filter {
                        $0 == Self.showDefaultUIAction || $0 == Self.showAlternateUIAction
                    }
                )
            }
            throw AccessibilityControllerError.actionUnavailable(kAXPressAction as String)
        }
        guard AXUIElementPerformAction(element, action as CFString) == .success else {
            throw AccessibilityControllerError.actionFailed(action)
        }

        let isSidebarRow = role == "AXRow" || subrole == "AXOutlineRow"
        let postcondition = isSidebarRow
            ? waitForSelectedPane(
                pid: pid,
                selector: selector,
                role: role,
                subrole: subrole,
                action: action
            )
            : nil
        return AccessibilityActivationReport(
            action: action,
            postcondition: postcondition
        )
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

    /// Writes a value to one uniquely resolved element and verifies the value
    /// through AX before returning. The value is never included in receipts or
    /// error metadata.
    @discardableResult
    public func setValueAndVerify(pid: pid_t, selector: Selector, value: String) throws -> CGRect? {
        let element = try findElement(pid: pid, selector: selector)
        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFTypeRef
        ) == .success else {
            throw AccessibilityControllerError.actionFailed(kAXValueAttribute as String)
        }
        guard attribute(element, kAXValueAttribute) as? String == value else {
            throw AccessibilityControllerError.actionFailed("AXValue verification")
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

    /// Resolves one visible product-owned fixture window across the app's
    /// complete window list. Raw document URLs and titles remain in memory.
    public func fixtureWindowBounds(
        pid: pid_t,
        expectedURL: URL,
        expectedTitleDigest: String
    ) throws -> CGRect? {
        try fixtureWindow(
            pid: pid,
            expectedURL: expectedURL,
            expectedTitleDigest: expectedTitleDigest
        ).map { try bounds(of: $0) }
    }

    public func setFixtureWindowFrame(
        pid: pid_t,
        expectedURL: URL,
        expectedTitleDigest: String,
        frame: CGRect,
        tolerance: CGFloat = 2
    ) throws {
        guard let window = try fixtureWindow(
            pid: pid,
            expectedURL: expectedURL,
            expectedTitleDigest: expectedTitleDigest
        ) else {
            throw AccessibilityControllerError.elementNotFound
        }
        try setWindowFrame(window, frame: frame, tolerance: tolerance)
    }

    private func fixtureWindow(
        pid: pid_t,
        expectedURL: URL,
        expectedTitleDigest: String
    ) throws -> AXUIElement? {
        guard PermissionDiagnostics.hasAccessibility() else {
            throw AccessibilityControllerError.permissionDenied
        }
        let application = AXUIElementCreateApplication(pid)
        let windows = (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let focusedWindow = elementAttribute(application, kAXFocusedWindowAttribute)
        var documentMatches: [AXUIElement] = []
        var titleMatches: [AXUIElement] = []
        let canonicalExpectedURL = expectedURL.standardizedFileURL.resolvingSymlinksInPath()
        for window in windows {
            let hidden = (attribute(window, kAXHiddenAttribute) as? Bool) ?? false
            guard !hidden else { continue }
            if let document = attribute(window, kAXDocumentAttribute) as? String,
               !document.isEmpty {
                let observedURL = URL(string: document)?.isFileURL == true
                    ? URL(string: document)
                    : URL(fileURLWithPath: document)
                if observedURL?.standardizedFileURL.resolvingSymlinksInPath() == canonicalExpectedURL {
                    documentMatches.append(window)
                    continue
                }
            }
            guard let title = attribute(window, kAXTitleAttribute) as? String,
                  !title.isEmpty else { continue }
            let digest = SHA256.hash(data: Data(title.utf8))
                .map { String(format: "%02x", $0) }.joined()
            if digest == expectedTitleDigest {
                titleMatches.append(window)
            }
        }
        if !documentMatches.isEmpty {
            if let focusedWindow,
               let focusedMatch = documentMatches.first(where: { CFEqual($0, focusedWindow) }) {
                return focusedMatch
            }
            return documentMatches.first
        }
        guard titleMatches.count <= 1 else {
            throw AccessibilityControllerError.ambiguousWindowMatch(titleMatches.count)
        }
        return titleMatches.first
    }

    /// Moves and resizes only the currently focused window, then reads the
    /// frame back before returning. Callers must resolve and bind the process.
    public func setFocusedWindowFrame(pid: pid_t, frame: CGRect, tolerance: CGFloat = 2) throws {
        guard PermissionDiagnostics.hasAccessibility() else {
            throw AccessibilityControllerError.permissionDenied
        }
        let application = AXUIElementCreateApplication(pid)
        guard let window = elementAttribute(application, kAXFocusedWindowAttribute)
            ?? (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first else {
            throw AccessibilityControllerError.elementNotFound
        }
        try setWindowFrame(window, frame: frame, tolerance: tolerance)
    }

    private func setWindowFrame(_ window: AXUIElement, frame: CGRect, tolerance: CGFloat) throws {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size),
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success,
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success else {
            throw AccessibilityControllerError.actionFailed("window_frame")
        }
        let observed = try bounds(of: window)
        guard abs(observed.minX - frame.minX) <= tolerance,
              abs(observed.minY - frame.minY) <= tolerance,
              abs(observed.width - frame.width) <= tolerance,
              abs(observed.height - frame.height) <= tolerance else {
            throw AccessibilityControllerError.actionFailed("window_frame_verification")
        }
    }

    /// Returns the focused window's document URL for an in-memory equality
    /// check. Callers must not retain or project the raw path.
    public func focusedWindowDocumentURL(pid: pid_t) throws -> URL? {
        guard PermissionDiagnostics.hasAccessibility() else {
            throw AccessibilityControllerError.permissionDenied
        }
        let application = AXUIElementCreateApplication(pid)
        guard let window = elementAttribute(application, kAXFocusedWindowAttribute)
            ?? (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first else {
            throw AccessibilityControllerError.elementNotFound
        }
        guard let document = attribute(window, kAXDocumentAttribute) as? String,
              !document.isEmpty else {
            return nil
        }
        return URL(string: document)?.isFileURL == true
            ? URL(string: document)
            : URL(fileURLWithPath: document)
    }

    /// Returns the focused window title for an immediate, in-memory identity
    /// comparison. Callers must not retain or project the raw title.
    public func focusedWindowTitle(pid: pid_t) throws -> String? {
        guard PermissionDiagnostics.hasAccessibility() else {
            throw AccessibilityControllerError.permissionDenied
        }
        let application = AXUIElementCreateApplication(pid)
        guard let window = elementAttribute(application, kAXFocusedWindowAttribute)
            ?? (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first else {
            throw AccessibilityControllerError.elementNotFound
        }
        guard let title = attribute(window, kAXTitleAttribute) as? String,
              !title.isEmpty else {
            return nil
        }
        return title
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
        let title = AccessibilitySelectorLabel.preferred(
            title: attribute(focused, kAXTitleAttribute) as? String,
            description: attribute(focused, kAXDescriptionAttribute) as? String,
            help: attribute(focused, kAXHelpAttribute) as? String
        )
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
        ancestorIdentityDigests: [String],
        maxNodes: Int,
        found: inout [AXUIElement],
        identities: inout Set<UInt64>,
        visitedElements: inout Set<UInt64>,
        visited: inout Int,
        truncated: inout Bool
    ) {
        // Two matches are sufficient to prove ambiguity. Stop traversing the
        // provider surface once that proof exists so a large unrelated AX
        // subtree cannot turn a known ambiguity into a bounded-search result.
        guard found.count < 2 else { return }
        guard visited < maxNodes else {
            truncated = true
            return
        }
        guard visitedElements.insert(UInt64(CFHash(element))).inserted else {
            return
        }
        visited += 1
        if self.matches(
            element,
            selector: selector,
            ancestorDigest: makeAncestorDigest(ancestorIdentityDigests)
        ) {
            let identity = UInt64(CFHash(element))
            if identities.insert(identity).inserted {
                found.append(element)
            }
        }
        let childAncestors: [String]
        if selector.ancestorDigest == nil {
            childAncestors = []
        } else {
            childAncestors = ancestorIdentityDigests + [liveLocatorDigest(for: element)]
        }
        let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for child in children {
            search(
                child,
                selector: selector,
                ancestorIdentityDigests: childAncestors,
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
        var latest = ContextMenuObservation(
            renderedMenuCount: 0,
            visibleItemCount: 0,
            labels: [],
            ambiguousMenuCandidates: false
        )
        while true {
            latest = inspectContextMenu(pid: pid)
            let matched = matchedMenuItemCount(expected: expected, labels: latest.labels)
            if Self.contextMenuEvidenceIsSufficient(
                renderedMenuCount: latest.renderedMenuCount,
                visibleItemCount: latest.visibleItemCount,
                expectedItemCount: expected.count,
                matchedItemCount: matched,
                ambiguousMenuCandidates: latest.ambiguousMenuCandidates
            ) {
                return ContextMenuReport(
                    state: .passed,
                    targetResolved: true,
                    menuVisible: true,
                    expectedItemCount: expected.count,
                    matchedItemCount: matched,
                    visibleItemCount: latest.visibleItemCount,
                    renderedMenuCount: latest.renderedMenuCount,
                    ambiguousMenuCandidates: latest.ambiguousMenuCandidates
                )
            }
            guard Date() < deadline else { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        let matched = matchedMenuItemCount(expected: expected, labels: latest.labels)
        return ContextMenuReport(
            state: .verificationUnavailable,
            targetResolved: true,
            menuVisible: latest.menuVisible,
            expectedItemCount: expected.count,
            matchedItemCount: matched,
            visibleItemCount: latest.visibleItemCount,
            renderedMenuCount: latest.renderedMenuCount,
            ambiguousMenuCandidates: latest.ambiguousMenuCandidates
        )
    }

    private func waitForSelectedPane(
        pid: pid_t,
        selector: Selector,
        role: String?,
        subrole: String?,
        action: String
    ) -> ControlActionPostcondition {
        let deadline = Date().addingTimeInterval(1.0)
        var targetResolved = false
        var selected = false
        var resolution = "not_observed"

        while true {
            do {
                let matches = try findElements(
                    pid: pid,
                    selector: selector,
                    maxNodes: AccessibilityResolutionBounds.maximumNodes
                )
                if matches.count == 1, let target = matches.first {
                    targetResolved = true
                    selected = (attribute(target, kAXSelectedAttribute) as? Bool) == true
                    resolution = "unique"
                    if selected {
                        return selectedPanePostcondition(
                            verified: true,
                            targetResolved: true,
                            selected: true,
                            resolution: resolution,
                            role: role,
                            subrole: subrole,
                            action: action
                        )
                    }
                } else {
                    resolution = matches.isEmpty ? "not_found" : "ambiguous"
                }
            } catch {
                resolution = "read_failed"
            }
            guard Date() < deadline else { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }

        return selectedPanePostcondition(
            verified: false,
            targetResolved: targetResolved,
            selected: selected,
            resolution: resolution,
            role: role,
            subrole: subrole,
            action: action
        )
    }

    private func selectedPanePostcondition(
        verified: Bool,
        targetResolved: Bool,
        selected: Bool,
        resolution: String,
        role: String?,
        subrole: String?,
        action: String
    ) -> ControlActionPostcondition {
        ControlActionPostcondition(
            kind: "selected_pane",
            verified: verified,
            details: [
                "target_resolved": .bool(targetResolved),
                "selected": .bool(selected),
                "resolution": .string(resolution),
                "role": .string(role ?? ""),
                "subrole": .string(subrole ?? ""),
                "activation_action": .string(action)
            ]
        )
    }

    private func inspectContextMenu(pid: pid_t) -> ContextMenuObservation {
        let application = AXUIElementCreateApplication(pid)
        let roots = ((attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? [])
            + ((attribute(application, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
        var visited = Set<UInt64>()
        var renderedMenuCount = 0
        var visibleItemCount = 0
        var labels: [String] = []

        func walk(_ element: AXUIElement, insideVisibleMenu: Bool, depth: Int) {
            guard depth < 32, visited.insert(UInt64(CFHash(element))).inserted else { return }
            let role = attribute(element, kAXRoleAttribute) as? String
            let hidden = (attribute(element, kAXHiddenAttribute) as? Bool) ?? false
            let isRenderedMenu = !insideVisibleMenu
                && role == "AXMenu"
                && !hidden
                && Self.hasRenderableBounds(try? bounds(of: element))
            let isVisibleMenu = insideVisibleMenu || isRenderedMenu
            if isRenderedMenu { renderedMenuCount += 1 }
            if role == "AXMenuItem" && isVisibleMenu && !hidden {
                if Self.hasRenderableBounds(try? bounds(of: element)) {
                    visibleItemCount += 1
                    if let label = AccessibilitySelectorLabel.preferred(
                        title: attribute(element, kAXTitleAttribute) as? String,
                        description: attribute(element, kAXDescriptionAttribute) as? String,
                        help: attribute(element, kAXHelpAttribute) as? String
                    ) {
                        labels.append(label.lowercased())
                    }
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
            renderedMenuCount: renderedMenuCount,
            visibleItemCount: visibleItemCount,
            labels: labels,
            ambiguousMenuCandidates: renderedMenuCount > 1
        )
    }

    static func hasRenderableBounds(_ bounds: CGRect?) -> Bool {
        guard let bounds else { return false }
        return bounds.origin.x.isFinite
            && bounds.origin.y.isFinite
            && bounds.size.width.isFinite
            && bounds.size.height.isFinite
            && bounds.size.width > 0
            && bounds.size.height > 0
    }

    static func contextMenuEvidenceIsSufficient(
        renderedMenuCount: Int,
        visibleItemCount: Int,
        expectedItemCount: Int,
        matchedItemCount: Int,
        ambiguousMenuCandidates: Bool
    ) -> Bool {
        renderedMenuCount == 1
            && visibleItemCount > 0
            && !ambiguousMenuCandidates
            && (expectedItemCount == 0 || matchedItemCount == expectedItemCount)
    }

    private func matchedMenuItemCount(expected: Set<String>, labels: [String]) -> Int {
        expected.reduce(into: 0) { count, item in
            if labels.contains(where: { $0 == item }) { count += 1 }
        }
    }

    private func matches(
        _ element: AXUIElement,
        selector: Selector,
        ancestorDigest: String?
    ) -> Bool {
        if let role = selector.role, role != (attribute(element, kAXRoleAttribute) as? String) {
            return false
        }
        if let identifier = selector.identifier,
           identifier != (attribute(element, kAXIdentifierAttribute) as? String) {
            return false
        }
        if let locatorDigest = selector.locatorDigest,
           locatorDigest != liveLocatorDigest(for: element) {
            return false
        }
        if let expectedAncestorDigest = selector.ancestorDigest,
           expectedAncestorDigest != ancestorDigest {
            return false
        }
        if let expectedGeometryDigest = selector.geometryDigest,
           expectedGeometryDigest != liveGeometryDigest(for: element) {
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
        return selector.role != nil || selector.identifier != nil || selector.locatorDigest != nil
            || selector.ancestorDigest != nil || selector.geometryDigest != nil || selector.title != nil || selector.subrole != nil
            || selector.containsText != nil
    }

    /// Rebuilds the same redacted identity descriptor emitted by capability
    /// audits. Raw labels and values never leave this process.
    private func liveLocatorDigest(for element: AXUIElement) -> String {
        let role = attribute(element, kAXRoleAttribute) as? String
        let actions = actionNames(of: element)
        // Keep live selector identity in lockstep with deep-audit locators:
        // incidental AXScrollToVisible actions do not identify a semantic
        // scroll container.
        let scrollable = role == "AXScrollArea"
        let label = AccessibilitySelectorLabel.preferred(
            title: attribute(element, kAXTitleAttribute) as? String,
            description: attribute(element, kAXDescriptionAttribute) as? String,
            help: attribute(element, kAXHelpAttribute) as? String
        ).map { String($0.prefix(240)) }
        return CapabilityLocatorDescriptor.fromAccessibilityIdentity(
            role: role,
            subrole: attribute(element, kAXSubroleAttribute) as? String,
            identifier: (attribute(element, kAXIdentifierAttribute) as? String)
                .map { String($0.prefix(240)) },
            label: label,
            actions: actions,
            scrollable: scrollable
        ).identityDigest
    }

    private func liveGeometryDigest(for element: AXUIElement) -> String? {
        guard let frame = try? bounds(of: element) else { return nil }
        return CapabilityProfileDigest.geometry(frame)
    }

    private func makeAncestorDigest(_ identities: [String]) -> String? {
        guard !identities.isEmpty else { return nil }
        return CapabilityProfileDigest.make(identities.joined(separator: "|"))
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
