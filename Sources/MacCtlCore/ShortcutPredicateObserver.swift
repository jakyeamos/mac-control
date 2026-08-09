import Foundation

public protocol ShortcutPredicateObserving {
    func evaluate(predicate: TaskPredicate, application: AppInfo) throws -> Bool
}

public final class AccessibilityShortcutPredicateObserver: ShortcutPredicateObserving {
    private let accessibility: AccessibilityController
    private let adapters: AppAdapterRegistry

    public init(
        accessibility: AccessibilityController = AccessibilityController(),
        adapters: AppAdapterRegistry = AppAdapterRegistry()
    ) {
        self.accessibility = accessibility
        self.adapters = adapters
    }

    public func evaluate(predicate: TaskPredicate, application: AppInfo) throws -> Bool {
        guard let pid = application.processID else { return false }
        switch predicate.kind {
        case .focusedElement:
            guard let selector = predicate.selector else { return false }
            let focus = try accessibility.focusedElementSnapshot(pid: pid, application: application)
            return matches(selector: selector, focus: focus)
        case .elementExists:
            guard let selector = predicate.selector else { return false }
            do {
                _ = try accessibility.findElement(pid: pid, selector: selector)
                return true
            } catch AccessibilityControllerError.elementNotFound {
                return false
            }
        case .windowVisible:
            return try accessibility.windowState(pid: pid).visible
        case .modalAbsent:
            return try !accessibility.windowState(pid: pid).modal
        case .focusReadable:
            _ = try accessibility.focusedElementSnapshot(pid: pid, application: application)
            return true
        case .adapterState:
            guard let adapterID = predicate.parameters["adapter_id"]?.stringValue,
                  let expected = predicate.parameters["state"]?.stringValue else { return false }
            if expected == "supported" { return adapters.manifest(adapterID: adapterID) != nil }
            return adapters.adapterID(for: application) == adapterID
        case .menuItemState, .foregroundApplication, .applicationRunning:
            return false
        }
    }

    private func matches(selector: Selector, focus: FocusedElementSnapshot) -> Bool {
        if let role = selector.role, focus.role != role { return false }
        if let subrole = selector.subrole, focus.subrole != subrole { return false }
        if let identifier = selector.identifier, focus.identifier != identifier { return false }
        if let title = selector.title, focus.title != title { return false }
        if selector.containsText != nil || selector.imageAnchor != nil
            || selector.normalizedX != nil || selector.normalizedY != nil
            || selector.rawX != nil || selector.rawY != nil { return false }
        if selector.windowTitle != nil || selector.windowIdentifier != nil { return false }
        return selector.role != nil || selector.subrole != nil || selector.identifier != nil || selector.title != nil
    }
}
