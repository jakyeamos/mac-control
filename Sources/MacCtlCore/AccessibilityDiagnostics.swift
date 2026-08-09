import ApplicationServices
import CoreGraphics
import Foundation

public struct AccessibilityTreeNodeState: Codable, Equatable {
    public let enabled: Bool
    public let focused: Bool
    public let selected: Bool
    public let expanded: Bool?
    public let visible: Bool
    public let settable: Bool
    /// Indicates that the element advertises a value attribute without
    /// reading that value.  Private text never crosses this boundary.
    public let hasValue: Bool

    public init(
        enabled: Bool,
        focused: Bool,
        selected: Bool,
        expanded: Bool?,
        visible: Bool,
        settable: Bool,
        hasValue: Bool
    ) {
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.expanded = expanded
        self.visible = visible
        self.settable = settable
        self.hasValue = hasValue
    }
}

public struct AccessibilityTreeNode: Codable, Equatable {
    public let path: String
    public let depth: Int
    public let role: String?
    public let subrole: String?
    public let identifier: String?
    public let label: String?
    public let actions: [String]
    public let state: AccessibilityTreeNodeState
    public let bounds: CGRect?
    public let childCount: Int
    public let scrollable: Bool

    public init(
        path: String,
        depth: Int,
        role: String?,
        subrole: String?,
        identifier: String?,
        label: String?,
        actions: [String],
        state: AccessibilityTreeNodeState,
        bounds: CGRect?,
        childCount: Int,
        scrollable: Bool
    ) {
        self.path = path
        self.depth = depth
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.label = label
        self.actions = actions
        self.state = state
        self.bounds = bounds
        self.childCount = childCount
        self.scrollable = scrollable
    }
}

public struct AccessibilityTreeCoveragePage: Codable, Equatable {
    /// A stable, redacted identity for one bounded window/page. This is not an
    /// AXUIElement reference and does not retain a visible title.
    public let identityDigest: String
    public let nodeCount: Int
    public let truncated: Bool

    public init(identityDigest: String, nodeCount: Int, truncated: Bool) {
        self.identityDigest = identityDigest
        self.nodeCount = max(0, nodeCount)
        self.truncated = truncated
    }
}

public struct AccessibilityTreeCoverage: Codable, Equatable {
    /// `windowed_pages` means every discovered AX window was partitioned into
    /// bounded top-level child pages. The mode is part of profile identity so
    /// a recursive and a paginated observation cannot be confused.
    public let mode: String
    public let windowCount: Int
    public let pageCount: Int
    public let omittedWindowCount: Int
    public let omittedPageCount: Int
    public let pages: [AccessibilityTreeCoveragePage]
    public let complete: Bool

    public init(
        mode: String,
        windowCount: Int,
        pageCount: Int,
        omittedWindowCount: Int = 0,
        omittedPageCount: Int = 0,
        pages: [AccessibilityTreeCoveragePage] = [],
        complete: Bool
    ) {
        self.mode = mode
        self.windowCount = max(0, windowCount)
        self.pageCount = max(0, pageCount)
        self.omittedWindowCount = max(0, omittedWindowCount)
        self.omittedPageCount = max(0, omittedPageCount)
        self.pages = pages
        self.complete = complete
    }

    public var signature: String {
        let pageSignature = pages
            .map { "\($0.identityDigest):\($0.nodeCount):\($0.truncated ? 1 : 0)" }
            .joined(separator: ",")
        return [
            mode,
            String(windowCount),
            String(pageCount),
            String(omittedWindowCount),
            String(omittedPageCount),
            complete ? "1" : "0",
            pageSignature
        ].joined(separator: "|")
    }
}

public struct AccessibilityTreeReport: Codable, Equatable {
    public let application: AppInfo
    public let maxNodes: Int
    public let maxDepth: Int
    public let nodeCount: Int
    public let truncated: Bool
    public let redacted: Bool
    public let nodes: [AccessibilityTreeNode]
    public let identifierMatchCounts: [String: Int]
    public let nameMatchCounts: [String: Int]
    public let coverage: AccessibilityTreeCoverage?

    public init(
        application: AppInfo,
        maxNodes: Int,
        maxDepth: Int,
        nodeCount: Int,
        truncated: Bool,
        redacted: Bool = true,
        nodes: [AccessibilityTreeNode],
        identifierMatchCounts: [String: Int],
        nameMatchCounts: [String: Int],
        coverage: AccessibilityTreeCoverage? = nil
    ) {
        self.application = application
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.nodeCount = nodeCount
        self.truncated = truncated
        self.redacted = redacted
        self.nodes = nodes
        self.identifierMatchCounts = identifierMatchCounts
        self.nameMatchCounts = nameMatchCounts
        self.coverage = coverage
    }
}

/// Bounded limits for the broad, read-only capability audit. The audit may
/// expand within these limits when the first traversal is truncated, but it
/// must never turn into an unbounded Accessibility walk.
public enum CapabilityAuditBounds {
    public static let defaultMaxNodes = 500
    public static let defaultMaxDepth = 8
    public static let maximumNodes = 2_000
    public static let maximumDepth = 20
    public static let maximumWindows = 8
    // Web-backed AX trees can expose more than 64 depth-frontier pages even
    // when the total redacted node count remains below the global cap. Keep
    // page count bounded, but let the existing total-node ceiling remain the
    // tighter limit for those apps.
    public static let maximumPages = 256
    public static let maximumWindowedTotalNodes = 16_000

    public static func normalizedNodes(_ value: Int) -> Int {
        min(max(value, 1), maximumNodes)
    }

    public static func normalizedDepth(_ value: Int) -> Int {
        min(max(value, 0), maximumDepth)
    }

    public static func nextNodes(after value: Int) -> Int {
        guard value < maximumNodes else { return value }
        return min(maximumNodes, value * 2)
    }

    public static func nextDepth(after value: Int) -> Int {
        guard value < maximumDepth else { return value }
        return min(maximumDepth, max(value + 1, value * 2))
    }
}

public enum AccessibilityAuditSeverity: String, Codable, Equatable {
    case error
    case warning
}

public struct AccessibilityAuditControl: Codable, Equatable {
    public let identifier: String?
    public let label: String?
    public let role: String?
    public let subrole: String?
    public let requiredActions: [String]
    public let requiresScrollSemantics: Bool

    public init(
        identifier: String? = nil,
        label: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        requiredActions: [String] = [],
        requiresScrollSemantics: Bool = false
    ) {
        self.identifier = identifier
        self.label = label
        self.role = role
        self.subrole = subrole
        self.requiredActions = requiredActions
        self.requiresScrollSemantics = requiresScrollSemantics
    }

    private enum CodingKeys: String, CodingKey {
        case identifier, label, role, subrole, requiredActions, requiredActionsSnake = "required_actions"
        case requiresScrollSemantics, requiresScrollSnake = "requires_scroll_semantics"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        subrole = try container.decodeIfPresent(String.self, forKey: .subrole)
        requiredActions = try container.decodeIfPresent([String].self, forKey: .requiredActions)
            ?? container.decodeIfPresent([String].self, forKey: .requiredActionsSnake)
            ?? []
        requiresScrollSemantics = try container.decodeIfPresent(Bool.self, forKey: .requiresScrollSemantics)
            ?? container.decodeIfPresent(Bool.self, forKey: .requiresScrollSnake)
            ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(subrole, forKey: .subrole)
        try container.encode(requiredActions, forKey: .requiredActions)
        try container.encode(requiresScrollSemantics, forKey: .requiresScrollSemantics)
    }
}

public struct AccessibilityAuditManifest: Codable, Equatable {
    public let controls: [AccessibilityAuditControl]
    public let maxNodes: Int
    public let maxDepth: Int

    public init(controls: [AccessibilityAuditControl], maxNodes: Int = 500, maxDepth: Int = 8) {
        self.controls = controls
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
    }
}

public struct AccessibilityAuditFinding: Codable, Equatable {
    public let severity: AccessibilityAuditSeverity
    public let code: String
    public let target: String?
    public let message: String

    public init(
        severity: AccessibilityAuditSeverity,
        code: String,
        target: String?,
        message: String
    ) {
        self.severity = severity
        self.code = code
        self.target = target
        self.message = message
    }
}

public struct AccessibilityAuditReport: Codable, Equatable {
    public let tree: AccessibilityTreeReport
    public let valid: Bool
    public let findings: [AccessibilityAuditFinding]

    public init(tree: AccessibilityTreeReport, valid: Bool, findings: [AccessibilityAuditFinding]) {
        self.tree = tree
        self.valid = valid
        self.findings = findings
    }
}

public enum AccessibilityScrollDirection: String, Codable, Equatable, CaseIterable {
    case up
    case down
    case left
    case right

    /// AppKit commonly exposes page-scroll actions while older providers may
    /// expose the shorter direction-only aliases. Prefer the page action so
    /// the semantic amount remains expressed in bounded pages, but accept the
    /// legacy alias when it is the only action advertised by the target.
    var actionCandidates: [String] {
        switch self {
        case .up: return ["AXScrollUpByPage", "AXScrollUp"]
        case .down: return ["AXScrollDownByPage", "AXScrollDown"]
        case .left: return ["AXScrollLeftByPage", "AXScrollLeft"]
        case .right: return ["AXScrollRightByPage", "AXScrollRight"]
        }
    }

    func actionName(matching availableActions: [String]) -> String? {
        actionCandidates.first { availableActions.contains($0) }
    }

    var pageButtonSubrole: String {
        switch self {
        case .up, .left: return "AXDecrementPage"
        case .down, .right: return "AXIncrementPage"
        }
    }

    var usesVerticalScrollBar: Bool {
        switch self {
        case .up, .down: return true
        case .left, .right: return false
        }
    }
}

/// The observable outcome of a scroll attempt. Dispatching an input event is
/// intentionally distinct from proving that the visible content changed.
public enum ScrollVerificationState: String, Codable, Equatable {
    case passed
    case dispatched
    case noObservedChange = "no_observed_change"
    case verificationUnavailable = "verification_unavailable"
}

/// Machine-readable reasons that let an agent choose a declared next provider
/// without turning every scroll failure into a blind retry.
public enum SemanticScrollFailureClass: String, Codable, Equatable {
    case targetMissing = "target_missing"
    case targetAmbiguous = "target_ambiguous"
    case actionUnavailable = "action_unavailable"
    case actionFailed = "action_failed"
    case permissionDenied = "permission_denied"
    case noObservedChange = "no_observed_change"
    case verificationUnavailable = "verification_unavailable"
}

/// Fallbacks are explicit because a low-level scroll event is app-scoped but
/// not selector-scoped, while Computer Use is an agent/provider boundary.
public enum ScrollFallbackRoute: String, Codable, Equatable, CaseIterable {
    case inputScroll = "input_scroll"
    case computerUse = "computer_use"
}

public struct InputScrollReport: Codable, Equatable {
    public let route: String
    public let direction: String
    public let amount: Int
    public let verification: ScrollVerificationState

    public init(
        route: String = "input_scroll",
        direction: String,
        amount: Int,
        verification: ScrollVerificationState = .verificationUnavailable
    ) {
        self.route = route
        self.direction = direction
        self.amount = amount
        self.verification = verification
    }
}

public protocol InputScrollPerforming {
    @discardableResult
    func scroll(amount: Int32, direction: String) throws -> InputScrollReport
}

public struct AccessibilityScrollReport: Codable, Equatable {
    public let application: AppInfo
    public let targetIdentifier: String
    public let direction: AccessibilityScrollDirection
    public let amount: Int
    public let route: ControlActionRoute
    public let verification: ScrollVerificationState

    public init(
        application: AppInfo,
        targetIdentifier: String,
        direction: AccessibilityScrollDirection,
        amount: Int,
        route: ControlActionRoute = .scroll,
        verification: ScrollVerificationState = .passed
    ) {
        self.application = application
        self.targetIdentifier = targetIdentifier
        self.direction = direction
        self.amount = amount
        self.route = route
        self.verification = verification
    }
}

public protocol AccessibilityTreeInspecting {
    func tree(
        pid: pid_t,
        application: AppInfo,
        maxNodes: Int,
        maxDepth: Int
    ) throws -> AccessibilityTreeReport

    func audit(
        pid: pid_t,
        application: AppInfo,
        manifest: AccessibilityAuditManifest
    ) throws -> AccessibilityAuditReport
}

/// Optional deep-audit capability. Keeping this separate from the core tree
/// protocol lets deterministic test inspectors and other providers opt in
/// without making a window-aware traversal a requirement on the hot path.
public protocol WindowedAccessibilityTreeInspecting {
    func windowedTree(
        pid: pid_t,
        application: AppInfo,
        maxNodesPerPage: Int,
        maxDepth: Int,
        maxWindows: Int,
        maxPages: Int
    ) throws -> AccessibilityTreeReport
}

public protocol AccessibilityScrollPerforming {
    func scroll(
        pid: pid_t,
        application: AppInfo,
        selector: Selector,
        direction: AccessibilityScrollDirection,
        amount: Int
    ) throws -> AccessibilityScrollReport
}

private struct AccessibilityTreeContinuation {
    let element: AXUIElement
    let path: String
    let depth: Int
}

private struct AccessibilityTreePageSeed {
    let element: AXUIElement
    let path: String
    let depth: Int
    let window: AccessibilityTreeNode?
}

extension AccessibilityController: AccessibilityTreeInspecting, AccessibilityScrollPerforming, WindowedAccessibilityTreeInspecting {
    public func tree(
        pid: pid_t,
        application: AppInfo,
        maxNodes: Int = 500,
        maxDepth: Int = 8
    ) throws -> AccessibilityTreeReport {
        guard PermissionDiagnostics.hasAccessibility() else {
            throw AccessibilityControllerError.permissionDenied
        }
        let boundedNodes = CapabilityAuditBounds.normalizedNodes(maxNodes)
        let boundedDepth = CapabilityAuditBounds.normalizedDepth(maxDepth)
        let root = AXUIElementCreateApplication(pid)
        var nodes: [AccessibilityTreeNode] = []
        var ignoredContinuations: [AccessibilityTreeContinuation] = []
        var ignoredContinuationOverflow = false
        let truncated = appendTreeNodes(
            from: root,
            path: "0",
            depth: 0,
            traversalDepth: 0,
            maxNodes: boundedNodes,
            maxDepth: boundedDepth,
            into: &nodes,
            continuations: &ignoredContinuations,
            continuationLimit: 0,
            continuationOverflow: &ignoredContinuationOverflow
        )
        let identifiers = Dictionary(grouping: nodes.compactMap { $0.identifier }, by: { $0 })
            .mapValues(\.count)
        let names = Dictionary(grouping: nodes.compactMap { $0.label }, by: { $0 })
            .mapValues(\.count)
        return AccessibilityTreeReport(
            application: application,
            maxNodes: boundedNodes,
            maxDepth: boundedDepth,
            nodeCount: nodes.count,
            truncated: truncated,
            nodes: nodes,
            identifierMatchCounts: identifiers,
            nameMatchCounts: names
        )
    }

    public func windowedTree(
        pid: pid_t,
        application: AppInfo,
        maxNodesPerPage: Int,
        maxDepth: Int,
        maxWindows: Int,
        maxPages: Int
    ) throws -> AccessibilityTreeReport {
        guard PermissionDiagnostics.hasAccessibility() else {
            throw AccessibilityControllerError.permissionDenied
        }
        let boundedNodes = CapabilityAuditBounds.normalizedNodes(maxNodesPerPage)
        let boundedDepth = CapabilityAuditBounds.normalizedDepth(maxDepth)
        let boundedWindows = min(max(maxWindows, 1), CapabilityAuditBounds.maximumWindows)
        let boundedPages = min(max(maxPages, 1), CapabilityAuditBounds.maximumPages)
        let root = AXUIElementCreateApplication(pid)
        let rawWindows = (attribute(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let windows = Array(rawWindows.prefix(boundedWindows))
        let omittedWindowCount = max(0, rawWindows.count - windows.count)
        var nodes: [AccessibilityTreeNode] = []
        var pages: [AccessibilityTreeCoveragePage] = []
        var omittedPageCount = 0
        var truncated = omittedWindowCount > 0
        var pageCount = 0
        var pendingPages: [AccessibilityTreePageSeed] = []

        if windows.isEmpty {
            pendingPages.append(AccessibilityTreePageSeed(
                element: root,
                path: "0",
                depth: 0,
                window: nil
            ))
        } else {
            for (windowIndex, window) in windows.enumerated() {
                let (windowNode, children) = treeNode(
                    for: window,
                    path: "w\(windowIndex)",
                    depth: 0
                )
                guard nodes.count < CapabilityAuditBounds.maximumWindowedTotalNodes else {
                    omittedPageCount += children.count
                    truncated = true
                    continue
                }
                nodes.append(windowNode)
                for (pageIndex, child) in children.enumerated() {
                    pendingPages.append(AccessibilityTreePageSeed(
                        element: child,
                        path: "w\(windowIndex)/p\(pageIndex)",
                        depth: 1,
                        window: windowNode
                    ))
                }
            }
        }

        var pendingIndex = 0
        while pendingIndex < pendingPages.count {
            guard pageCount < boundedPages else {
                omittedPageCount += pendingPages.count - pendingIndex
                truncated = true
                break
            }
            guard nodes.count < CapabilityAuditBounds.maximumWindowedTotalNodes else {
                omittedPageCount += pendingPages.count - pendingIndex
                truncated = true
                break
            }
            let seed = pendingPages[pendingIndex]
            pendingIndex += 1
            var pageNodes: [AccessibilityTreeNode] = []
            var continuations: [AccessibilityTreeContinuation] = []
            var continuationOverflow = false
            _ = appendTreeNodes(
                from: seed.element,
                path: seed.path,
                depth: seed.depth,
                traversalDepth: 0,
                maxNodes: boundedNodes,
                maxDepth: boundedDepth,
                into: &pageNodes,
                continuations: &continuations,
                continuationLimit: boundedPages,
                continuationOverflow: &continuationOverflow
            )
            let remainingNodeCapacity = max(
                0,
                CapabilityAuditBounds.maximumWindowedTotalNodes - nodes.count
            )
            if pageNodes.count > remainingNodeCapacity {
                pageNodes = Array(pageNodes.prefix(remainingNodeCapacity))
                continuations.removeAll()
                continuationOverflow = true
            }
            nodes.append(contentsOf: pageNodes)
            let pageIdentity = pageIdentityDigest(window: seed.window, child: pageNodes.first)
            pages.append(AccessibilityTreeCoveragePage(
                identityDigest: pageIdentity,
                nodeCount: pageNodes.count,
                truncated: continuationOverflow || pageNodes.isEmpty
            ))
            pageCount += 1
            for continuation in continuations {
                pendingPages.append(AccessibilityTreePageSeed(
                    element: continuation.element,
                    path: continuation.path,
                    depth: continuation.depth,
                    window: seed.window
                ))
            }
            if continuationOverflow {
                omittedPageCount += pendingPages.count - pendingIndex
                truncated = true
                break
            }
        }

        let coverage = AccessibilityTreeCoverage(
            mode: "windowed_pages",
            windowCount: windows.count,
            pageCount: pageCount,
            omittedWindowCount: omittedWindowCount,
            omittedPageCount: omittedPageCount,
            pages: pages,
            complete: !truncated && omittedWindowCount == 0 && omittedPageCount == 0
        )
        let identifiers = Dictionary(grouping: nodes.compactMap { $0.identifier }, by: { $0 })
            .mapValues(\.count)
        let names = Dictionary(grouping: nodes.compactMap { $0.label }, by: { $0 })
            .mapValues(\.count)
        return AccessibilityTreeReport(
            application: application,
            maxNodes: boundedNodes,
            maxDepth: boundedDepth,
            nodeCount: nodes.count,
            truncated: truncated,
            nodes: nodes,
            identifierMatchCounts: identifiers,
            nameMatchCounts: names,
            coverage: coverage
        )
    }

    public func audit(
        pid: pid_t,
        application: AppInfo,
        manifest: AccessibilityAuditManifest
    ) throws -> AccessibilityAuditReport {
        let treeReport = try tree(
            pid: pid,
            application: application,
            maxNodes: manifest.maxNodes,
            maxDepth: manifest.maxDepth
        )
        return AccessibilityAuditEngine.audit(tree: treeReport, manifest: manifest)
    }

    public func scroll(
        pid: pid_t,
        application: AppInfo,
        selector: Selector,
        direction: AccessibilityScrollDirection,
        amount: Int
    ) throws -> AccessibilityScrollReport {
        guard PermissionDiagnostics.hasAccessibility() else {
            throw AccessibilityControllerError.permissionDenied
        }
        guard amount > 0, amount <= 20,
              selector.role == "AXScrollArea",
              selector.identifier.map({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) ?? true else {
            throw AccessibilityControllerError.scrollTargetRequired
        }
        // Native/AppKit and SwiftUI containers are often uniquely addressable
        // by role while exposing no AXIdentifier. Keep the persisted
        // descriptor stable and redacted; uniqueness is still enforced by
        // findElements before and after the action.
        let targetIdentifier = selector.identifier ?? "role:AXScrollArea"
        let matches = try findElements(pid: pid, selector: selector, maxNodes: 2_000)
        guard let element = matches.first else {
            throw AccessibilityControllerError.elementNotFound
        }
        guard matches.count == 1 else {
            throw AccessibilityControllerError.ambiguousMatch(matches.count)
        }
        let beforeFingerprint = scrollObservationFingerprint(of: element)
        let availableActions = actionNames(of: element)
        let pageButtons = pageScrollButtonCandidates(in: element, direction: direction)
        if pageButtons.count == 1 {
            let pressAction = kAXPressAction as String
            guard AXUIElementPerformAction(pageButtons[0], pressAction as CFString) == .success else {
                throw AccessibilityControllerError.actionFailed(
                    "\(pressAction):\(direction.pageButtonSubrole)"
                )
            }
            if amount > 1 {
                for _ in 1..<amount {
                    guard AXUIElementPerformAction(pageButtons[0], pressAction as CFString) == .success else {
                        throw AccessibilityControllerError.actionFailed(
                            "\(pressAction):\(direction.pageButtonSubrole)"
                        )
                    }
                }
            }
        } else {
            guard let actionName = direction.actionName(matching: availableActions) else {
                throw AccessibilityControllerError.scrollUnavailable(direction.rawValue)
            }
            for _ in 0..<amount {
                guard AXUIElementPerformAction(element, actionName as CFString) == .success else {
                    throw AccessibilityControllerError.actionFailed(actionName)
                }
            }
        }
        // Re-resolve the target after the action. This proves that the
        // semantic container remains uniquely addressable without reading its
        // content or screenshot.
        let remaining = try findElements(pid: pid, selector: selector, maxNodes: 2_000)
        guard remaining.count == 1 else {
            throw remaining.isEmpty
                ? AccessibilityControllerError.elementNotFound
                : AccessibilityControllerError.ambiguousMatch(remaining.count)
        }
        let verification: ScrollVerificationState
        if let beforeFingerprint,
           let afterFingerprint = scrollObservationFingerprint(of: remaining[0]) {
            verification = beforeFingerprint == afterFingerprint
                ? .noObservedChange
                : .passed
        } else {
            verification = .verificationUnavailable
        }
        return AccessibilityScrollReport(
            application: application,
            targetIdentifier: targetIdentifier,
            direction: direction,
            amount: amount,
            verification: verification
        )
    }

    /// AppKit may advertise AXScroll*ByPage on a scroll area while rejecting
    /// that action at runtime. Its scrollbar's directional page button is a
    /// more concrete semantic route on those providers. Search only a bounded
    /// target subtree and require one axis-matching, enabled AXPress target;
    /// never guess when the provider exposes more than one candidate.
    private func pageScrollButtonCandidates(
        in element: AXUIElement,
        direction: AccessibilityScrollDirection
    ) -> [AXUIElement] {
        var pending: [(element: AXUIElement, axis: Bool?)] = [(element, nil)]
        var visited = Set<UInt64>()
        var candidateIdentities = Set<UInt64>()
        var candidates: [AXUIElement] = []
        let maximumVisited = 512
        let pressAction = kAXPressAction as String

        while !pending.isEmpty, visited.count < maximumVisited {
            let current = pending.removeFirst()
            let currentIdentity = UInt64(CFHash(current.element))
            guard visited.insert(currentIdentity).inserted else { continue }
            let currentRole = attribute(current.element, kAXRoleAttribute) as? String
            let children = (attribute(current.element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            for child in children {
                let childRole = attribute(child, kAXRoleAttribute) as? String
                let childSubrole = attribute(child, kAXSubroleAttribute) as? String
                if childRole == "AXButton",
                   childSubrole == direction.pageButtonSubrole,
                   actionNames(of: child).contains(pressAction),
                   (attribute(child, kAXEnabledAttribute) as? Bool) ?? true,
                   current.axis.map({ $0 == direction.usesVerticalScrollBar }) ?? true {
                    let identity = UInt64(CFHash(child))
                    if candidateIdentities.insert(identity).inserted {
                        candidates.append(child)
                    }
                }

                let nextAxis: Bool?
                if childRole == "AXScrollArea" {
                    nextAxis = nil
                } else if childRole == "AXScrollBar" {
                    nextAxis = scrollBarIsVertical(child)
                } else {
                    nextAxis = currentRole == "AXScrollBar" ? current.axis : nil
                }
                pending.append((child, nextAxis))
            }
        }
        return candidates
    }

    private func scrollBarIsVertical(_ element: AXUIElement) -> Bool? {
        guard let frame = try? bounds(of: element), frame.width > 0 || frame.height > 0 else {
            return nil
        }
        return frame.height >= frame.width
    }

    /// Capture only bounded structural metadata from visible descendants. This
    /// deliberately excludes AX values and text so a scroll can fail closed on
    /// an unchanged/unobservable viewport without persisting private content.
    private func scrollObservationFingerprint(of element: AXUIElement) -> String? {
        let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        guard !children.isEmpty else { return nil }
        let descriptors = children.prefix(256).map { child in
            let role = attribute(child, kAXRoleAttribute) as? String ?? ""
            let subrole = attribute(child, kAXSubroleAttribute) as? String ?? ""
            let identifier = attribute(child, kAXIdentifierAttribute) as? String ?? ""
            let hidden = (attribute(child, kAXHiddenAttribute) as? Bool) ?? false
            let focused = (attribute(child, kAXFocusedAttribute) as? Bool) ?? false
            let selected = (attribute(child, kAXSelectedAttribute) as? Bool) ?? false
            let childCount = (attribute(child, kAXChildrenAttribute) as? [AXUIElement])?.count ?? 0
            let frame = (try? bounds(of: child)).map {
                "\($0.origin.x),\($0.origin.y),\($0.size.width),\($0.size.height)"
            } ?? ""
            return [
                role, subrole, identifier, frame,
                hidden ? "1" : "0",
                focused ? "1" : "0",
                selected ? "1" : "0",
                String(childCount)
            ].joined(separator: "|")
        }
        return ControlTargetFingerprints.structuralDigest(descriptors.joined(separator: "||"))
    }

    private func treeNode(
        for element: AXUIElement,
        path: String,
        depth: Int
    ) -> (AccessibilityTreeNode, [AXUIElement]) {
        let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        let actions = actionNames(of: element)
        let role = attribute(element, kAXRoleAttribute) as? String
        let scrollable = role == "AXScrollArea"
            || actions.contains(where: { $0.hasPrefix("AXScroll") })
        let state = AccessibilityTreeNodeState(
            enabled: (attribute(element, kAXEnabledAttribute) as? Bool) ?? true,
            focused: (attribute(element, kAXFocusedAttribute) as? Bool) ?? false,
            selected: (attribute(element, kAXSelectedAttribute) as? Bool) ?? false,
            expanded: attribute(element, kAXExpandedAttribute) as? Bool,
            visible: !((attribute(element, kAXHiddenAttribute) as? Bool) ?? false),
            settable: isAttributeSettable(element, kAXValueAttribute),
            hasValue: attributeNames(of: element).contains(kAXValueAttribute as String)
        )
        return (AccessibilityTreeNode(
            path: path,
            depth: depth,
            role: role,
            subrole: attribute(element, kAXSubroleAttribute) as? String,
            identifier: boundedString(attribute(element, kAXIdentifierAttribute) as? String),
            label: label(of: element),
            actions: actions,
            state: state,
            bounds: try? bounds(of: element),
            childCount: children.count,
            scrollable: scrollable
        ), children)
    }

    @discardableResult
    private func appendTreeNodes(
        from element: AXUIElement,
        path: String,
        depth: Int,
        traversalDepth: Int,
        maxNodes: Int,
        maxDepth: Int,
        into nodes: inout [AccessibilityTreeNode],
        continuations: inout [AccessibilityTreeContinuation],
        continuationLimit: Int,
        continuationOverflow: inout Bool
    ) -> Bool {
        guard nodes.count < maxNodes else {
            if continuationLimit > 0 {
                if continuations.count < continuationLimit {
                    continuations.append(AccessibilityTreeContinuation(
                        element: element,
                        path: path,
                        depth: depth
                    ))
                } else {
                    continuationOverflow = true
                }
            }
            return true
        }
        let (node, children) = treeNode(for: element, path: path, depth: depth)
        nodes.append(node)
        guard traversalDepth < maxDepth else {
            for (index, child) in children.enumerated() {
                guard continuationLimit > 0 else { return true }
                if continuations.count < continuationLimit {
                    continuations.append(AccessibilityTreeContinuation(
                        element: child,
                        path: "\(path)/\(index)",
                        depth: depth + 1
                    ))
                } else {
                    continuationOverflow = true
                    return true
                }
            }
            return !children.isEmpty
        }
        var boundaryEncountered = false
        for (index, child) in children.enumerated() {
            if appendTreeNodes(
                from: child,
                path: "\(path)/\(index)",
                depth: depth + 1,
                traversalDepth: traversalDepth + 1,
                maxNodes: maxNodes,
                maxDepth: maxDepth,
                into: &nodes,
                continuations: &continuations,
                continuationLimit: continuationLimit,
                continuationOverflow: &continuationOverflow
            ) {
                boundaryEncountered = true
                if continuationOverflow {
                    return true
                }
                if continuationLimit == 0 {
                    return true
                }
            }
        }
        return boundaryEncountered
    }

    private func pageIdentityDigest(
        window: AccessibilityTreeNode?,
        child: AccessibilityTreeNode?
    ) -> String {
        let descriptor = [window, child].compactMap { $0 }.map { node in
            [
                node.role ?? "",
                node.subrole ?? "",
                node.identifier ?? "",
                node.label.map(CapabilityProfileDigest.make) ?? "",
                node.childCount.description
            ].joined(separator: "|")
        }.joined(separator: "||")
        return CapabilityProfileDigest.make(descriptor)
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        var raw: CFArray?
        guard AXUIElementCopyActionNames(element, &raw) == .success,
              let raw,
              let names = raw as? [String] else { return [] }
        return names.sorted()
    }

    private func attributeNames(of element: AXUIElement) -> [String] {
        var raw: CFArray?
        guard AXUIElementCopyAttributeNames(element, &raw) == .success,
              let raw,
              let names = raw as? [String] else { return [] }
        return names
    }

    private func isAttributeSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    private func label(of element: AXUIElement) -> String? {
        let title = attribute(element, kAXTitleAttribute) as? String
        let description = attribute(element, kAXDescriptionAttribute) as? String
        let help = attribute(element, kAXHelpAttribute) as? String
        return boundedString(title ?? description ?? help)
    }

    private func boundedString(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.prefix(240))
    }
}

public enum AccessibilityAuditEngine {
    public static func audit(
        tree: AccessibilityTreeReport,
        manifest: AccessibilityAuditManifest
    ) -> AccessibilityAuditReport {
        var findings: [AccessibilityAuditFinding] = []
        for (identifier, count) in tree.identifierMatchCounts where count > 1 {
            findings.append(AccessibilityAuditFinding(
                severity: .error,
                code: "duplicate_identifier",
                target: identifier,
                message: "Accessibility identifier appears \(count) times"
            ))
        }
        for (name, count) in tree.nameMatchCounts where count > 1 {
            findings.append(AccessibilityAuditFinding(
                severity: .warning,
                code: "duplicate_name",
                target: name,
                message: "Accessibility name appears \(count) times"
            ))
        }
        for control in manifest.controls {
            let matches = tree.nodes.filter { node in
                let idMatches = control.identifier == nil || node.identifier == control.identifier
                let nameMatches = control.label == nil || node.label == control.label
                let roleMatches = control.role == nil || node.role == control.role
                let subroleMatches = control.subrole == nil || node.subrole == control.subrole
                return idMatches && nameMatches && roleMatches && subroleMatches
                    && (control.identifier != nil || control.label != nil
                        || control.role != nil || control.subrole != nil)
            }
            let target = control.identifier ?? control.label ?? control.role ?? control.subrole
            guard matches.count == 1, let node = matches.first else {
                findings.append(AccessibilityAuditFinding(
                    severity: .error,
                    code: matches.isEmpty ? "unverifiable_control" : "ambiguous_control",
                    target: target,
                    message: matches.isEmpty
                        ? "Manifest target was not present in the bounded Accessibility tree"
                        : "Manifest target matched \(matches.count) elements"
                ))
                continue
            }
            guard node.role != nil || node.subrole != nil || node.identifier != nil || node.label != nil else {
                findings.append(AccessibilityAuditFinding(
                    severity: .error,
                    code: "unverifiable_control",
                    target: target,
                    message: "Target has no stable role, identifier, or label"
                ))
                continue
            }
            for requiredAction in control.requiredActions where !node.actions.contains(requiredAction) {
                findings.append(AccessibilityAuditFinding(
                    severity: .error,
                    code: "missing_action",
                    target: target,
                    message: "Target is missing required action \(requiredAction)"
                ))
            }
            if control.requiresScrollSemantics && !node.scrollable {
                findings.append(AccessibilityAuditFinding(
                    severity: .error,
                    code: "missing_scroll_semantics",
                    target: target,
                    message: "Target does not expose semantic scroll behavior"
                ))
            }
        }
        return AccessibilityAuditReport(
            tree: tree,
            valid: !findings.contains(where: { $0.severity == .error }) && !tree.truncated,
            findings: findings
        )
    }
}
