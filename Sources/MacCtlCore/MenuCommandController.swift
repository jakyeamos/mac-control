import ApplicationServices
import Foundation

public protocol MenuCommandControlling {
    func audit(application: AppInfo, maxItems: Int) throws -> ([MenuCommandSnapshot], Bool)
    func inspect(application: AppInfo, path: [String]) throws -> MenuCommandSnapshot
    func activate(application: AppInfo, path: [String]) throws -> MenuCommandSnapshot
}

public final class AccessibilityMenuCommandController: MenuCommandControlling {
    private static let maximumItems = 1_024
    private static let maximumDepth = 8

    public init() {}

    public func audit(
        application: AppInfo,
        maxItems: Int = 512
    ) throws -> ([MenuCommandSnapshot], Bool) {
        let root = try menuBar(for: application)
        let limit = min(max(1, maxItems), Self.maximumItems)
        var snapshots: [MenuCommandSnapshot] = []
        var visited = Set<UInt64>()
        var truncated = false

        for topLevel in children(of: root) {
            guard snapshots.count < limit else {
                truncated = true
                break
            }
            guard let title = title(of: topLevel), !title.isEmpty else { continue }
            collect(
                from: topLevel,
                path: [title],
                depth: 0,
                limit: limit,
                snapshots: &snapshots,
                visited: &visited,
                truncated: &truncated
            )
        }
        return (snapshots, truncated)
    }

    public func inspect(application: AppInfo, path: [String]) throws -> MenuCommandSnapshot {
        let element = try resolve(application: application, path: path)
        return snapshot(element: element, path: path)
    }

    public func activate(application: AppInfo, path: [String]) throws -> MenuCommandSnapshot {
        let element = try resolve(application: application, path: path)
        let before = snapshot(element: element, path: path)
        guard before.enabled else { throw ShortcutError.menuItemDisabled(path) }
        guard !before.hidden else { throw ShortcutError.menuPathNotFound(path) }
        guard !before.dynamic else { throw ShortcutError.dynamicMenuItem(path) }
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw AccessibilityControllerError.actionFailed(kAXPressAction as String)
        }
        let deadline = Date().addingTimeInterval(1)
        var latest = before
        repeat {
            if let observed = try? inspect(application: application, path: path) {
                latest = observed
                if observed.checked != before.checked || observed.enabled != before.enabled {
                    return observed
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        } while Date() < deadline
        return latest
    }

    private func menuBar(for application: AppInfo) throws -> AXUIElement {
        guard PermissionDiagnostics.hasAccessibility() else {
            throw AccessibilityControllerError.permissionDenied
        }
        guard application.isRunning, let pid = application.processID else {
            throw ShortcutError.appNotRunning(application.name)
        }
        let app = AXUIElementCreateApplication(pid)
        guard let raw = attribute(app, kAXMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw ShortcutError.unsupported("application does not expose an Accessibility menu bar")
        }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private func resolve(application: AppInfo, path: [String]) throws -> AXUIElement {
        guard path.count >= 2 else { throw ShortcutError.invalidTarget("menu path is too short") }
        let menuBar = try menuBar(for: application)
        let topMatches = children(of: menuBar).filter { title(of: $0) == path[0] }
        guard !topMatches.isEmpty else { throw ShortcutError.menuPathNotFound(path) }
        guard topMatches.count == 1 else { throw ShortcutError.ambiguousMenuPath(path, topMatches.count) }
        var current = topMatches[0]

        for component in path.dropFirst() {
            let candidates = directMenuItems(below: current).filter { title(of: $0) == component }
            guard !candidates.isEmpty else { throw ShortcutError.menuPathNotFound(path) }
            guard candidates.count == 1 else { throw ShortcutError.ambiguousMenuPath(path, candidates.count) }
            current = candidates[0]
        }
        guard role(of: current) == "AXMenuItem" else {
            throw ShortcutError.menuPathNotFound(path)
        }
        return current
    }

    private func collect(
        from element: AXUIElement,
        path: [String],
        depth: Int,
        limit: Int,
        snapshots: inout [MenuCommandSnapshot],
        visited: inout Set<UInt64>,
        truncated: inout Bool
    ) {
        guard depth < Self.maximumDepth else {
            truncated = true
            return
        }
        guard visited.insert(UInt64(CFHash(element))).inserted else { return }
        let items = directMenuItems(below: element)
        for item in items {
            guard snapshots.count < limit else {
                truncated = true
                return
            }
            guard let itemTitle = title(of: item), !itemTitle.isEmpty else { continue }
            let itemPath = path + [itemTitle]
            if Self.isDynamic(path: itemPath) {
                snapshots.append(snapshot(element: item, path: itemPath))
                continue
            }
            let descendants = directMenuItems(below: item)
            if descendants.isEmpty {
                snapshots.append(snapshot(element: item, path: itemPath))
            } else {
                collect(
                    from: item,
                    path: itemPath,
                    depth: depth + 1,
                    limit: limit,
                    snapshots: &snapshots,
                    visited: &visited,
                    truncated: &truncated
                )
            }
        }
    }

    private func directMenuItems(below element: AXUIElement) -> [AXUIElement] {
        var results: [AXUIElement] = []
        for child in children(of: element) {
            if role(of: child) == "AXMenuItem" {
                results.append(child)
            } else if role(of: child) == "AXMenu" {
                results.append(contentsOf: children(of: child).filter { role(of: $0) == "AXMenuItem" })
            }
        }
        return results
    }

    private func snapshot(element: AXUIElement, path: [String]) -> MenuCommandSnapshot {
        let enabled = (attribute(element, kAXEnabledAttribute) as? Bool) ?? false
        let hidden = (attribute(element, kAXHiddenAttribute) as? Bool) ?? false
        return MenuCommandSnapshot(
            path: path,
            enabled: enabled,
            hidden: hidden,
            dynamic: Self.isDynamic(path: path),
            keyEquivalent: keyEquivalent(of: element),
            checked: checkedState(of: element)
        )
    }

    private func checkedState(of element: AXUIElement) -> Bool? {
        if let mark = attribute(element, kAXMenuItemMarkCharAttribute) as? String {
            return !mark.isEmpty
        }
        if let value = attribute(element, kAXValueAttribute) as? Bool {
            return value
        }
        return nil
    }

    private func keyEquivalent(of element: AXUIElement) -> String? {
        guard let key = attribute(element, kAXMenuItemCmdCharAttribute) as? String,
              !key.isEmpty else { return nil }
        let modifiers = (attribute(element, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
        var parts: [String] = []
        if modifiers & 4 != 0 { parts.append("ctrl") }
        if modifiers & 2 != 0 { parts.append("option") }
        if modifiers & 1 != 0 { parts.append("shift") }
        if modifiers & 8 == 0 { parts.append("cmd") }
        parts.append(key.lowercased())
        return parts.joined(separator: "+")
    }

    static func isDynamic(path: [String]) -> Bool {
        let normalized = path.map { $0.lowercased() }
        if normalized.contains(where: { $0.contains("recent") || $0.contains("recently closed") }) {
            return true
        }
        guard let root = normalized.first else { return false }
        if root == "window" {
            let stableWindowCommands = [
                "minimize", "zoom", "move window to left side of screen",
                "move window to right side of screen", "bring all to front",
                "enter full screen", "tile window"
            ]
            guard let leaf = normalized.last else { return false }
            return !stableWindowCommands.contains(where: { leaf.hasPrefix($0) })
        }
        return false
    }

    private func title(of element: AXUIElement) -> String? {
        attribute(element, kAXTitleAttribute) as? String
    }

    private func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute) as? String
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as AnyObject?
    }
}
