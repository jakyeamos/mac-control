import Foundation

/// The result of a task-specific, read-only observation. None of these states
/// authorizes an action; `readyForMeasurement` only means that a later,
/// approval-gated action may reuse the same structural target and declared
/// postcondition.
public enum TaskCapabilityVerificationState: String, Codable, Equatable {
    case readyForMeasurement = "ready_for_measurement"
    case needsPostcondition = "needs_postcondition"
    case candidate
    case ambiguous
    case unsupported
}

public struct TaskCapabilityVerificationEvaluation: Equatable {
    public let state: TaskCapabilityVerificationState
    public let reason: String
    public let targetMatchCount: Int
    public let targetLocatorDigests: [String]
    public let observedActions: [String]
    public let coverageComplete: Bool

    public init(
        state: TaskCapabilityVerificationState,
        reason: String,
        targetMatchCount: Int = 0,
        targetLocatorDigests: [String] = [],
        observedActions: [String] = [],
        coverageComplete: Bool = false
    ) {
        self.state = state
        self.reason = reason
        self.targetMatchCount = max(0, targetMatchCount)
        self.targetLocatorDigests = Array(Set(targetLocatorDigests)).sorted()
        self.observedActions = Array(Set(observedActions)).sorted()
        self.coverageComplete = coverageComplete
    }

    public var requiresComputerUseHandoff: Bool {
        switch state {
        case .candidate, .ambiguous, .unsupported:
            return true
        case .readyForMeasurement, .needsPostcondition:
            return false
        }
    }
}

/// A redacted report for one bounded task-surface observation. It contains
/// hashes and structural counts only; raw labels, AX values, screenshots, and
/// element references are intentionally absent.
public struct TaskCapabilityVerificationReport: Codable, Equatable {
    public let schemaVersion: Int
    public let application: WarmPathApplicationIdentity
    public let taskID: String
    public let targetFingerprintDigest: String
    public let route: ControlActionRoute
    public let state: TaskCapabilityVerificationState
    public let readOnly: Bool
    public let actionDispatched: Bool
    public let postconditionKind: String?
    public let postconditionDigest: String?
    public let treeSignature: String?
    public let treeNodeCount: Int
    public let treeTruncated: Bool
    public let coverageComplete: Bool
    public let profileState: CapabilityProfileState?
    public let targetMatchCount: Int
    public let targetLocatorDigests: [String]
    public let observedActions: [String]
    public let reason: String
    public let recommendedProvider: String?
    public let freshStateRequired: Bool
    public let nativeActionReplayAllowed: Bool
    public let nextAction: String?
    public let handoffPlan: AgentProviderHandoffPlan?

    public init(
        application: WarmPathApplicationIdentity,
        taskID: String,
        targetFingerprintDigest: String,
        route: ControlActionRoute,
        state: TaskCapabilityVerificationState,
        postconditionKind: String?,
        postconditionDigest: String?,
        treeSignature: String?,
        treeNodeCount: Int,
        treeTruncated: Bool,
        coverageComplete: Bool,
        profileState: CapabilityProfileState?,
        targetMatchCount: Int,
        targetLocatorDigests: [String],
        observedActions: [String],
        reason: String,
        recommendedProvider: String? = nil,
        freshStateRequired: Bool = false,
        nativeActionReplayAllowed: Bool = false,
        nextAction: String? = nil,
        handoffPlan: AgentProviderHandoffPlan? = nil,
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.application = application
        self.taskID = taskID
        self.targetFingerprintDigest = targetFingerprintDigest
        self.route = route
        self.state = state
        self.readOnly = true
        self.actionDispatched = false
        self.postconditionKind = postconditionKind
        self.postconditionDigest = postconditionDigest
        self.treeSignature = treeSignature
        self.treeNodeCount = max(0, treeNodeCount)
        self.treeTruncated = treeTruncated
        self.coverageComplete = coverageComplete
        self.profileState = profileState
        self.targetMatchCount = max(0, targetMatchCount)
        self.targetLocatorDigests = Array(Set(targetLocatorDigests)).sorted()
        self.observedActions = Array(Set(observedActions)).sorted()
        self.reason = reason
        self.recommendedProvider = recommendedProvider
        self.freshStateRequired = freshStateRequired
        self.nativeActionReplayAllowed = nativeActionReplayAllowed
        self.nextAction = nextAction
        self.handoffPlan = handoffPlan
    }
}

public enum TaskCapabilityVerificationMatcher {
    /// Matches a selector against one already-captured, redacted AX tree.
    /// Structural uniqueness and action availability are evaluated before a
    /// caller-supplied postcondition can make the surface ready for a later
    /// measured route.
    public static func evaluate(
        selector: Selector,
        route: ControlActionRoute,
        tree: AccessibilityTreeReport,
        postconditionKind: String?,
        postconditionDigest: String?,
        coverageComplete: Bool
    ) -> TaskCapabilityVerificationEvaluation {
        guard route == .accessibility || route == .scroll else {
            return TaskCapabilityVerificationEvaluation(
                state: .unsupported,
                reason: "route_requires_external_provider",
                coverageComplete: coverageComplete && !tree.truncated
            )
        }
        if selector.containsText != nil
            || selector.imageAnchor != nil
            || selector.normalizedX != nil
            || selector.normalizedY != nil
            || selector.rawX != nil
            || selector.rawY != nil
            || selector.windowTitle != nil
            || selector.windowIdentifier != nil {
            return TaskCapabilityVerificationEvaluation(
                state: .unsupported,
                reason: "non_structural_selector",
                coverageComplete: coverageComplete && !tree.truncated
            )
        }
        guard selector.hasTarget else {
            return TaskCapabilityVerificationEvaluation(
                state: .unsupported,
                reason: "selector_missing_structural_identity",
                coverageComplete: coverageComplete && !tree.truncated
            )
        }

        let nodesByPath = tree.nodes.reduce(into: [String: AccessibilityTreeNode]()) {
            $0[$1.path] = $1
        }
        let matchedNodes = tree.nodes.compactMap { node -> (AccessibilityTreeNode, CapabilityLocatorDescriptor)? in
            guard let locator = CapabilityProfileBuilder.locatorDescriptor(
                for: node,
                nodesByPath: nodesByPath
            ), matches(selector: selector, node: node, locator: locator) else {
                return nil
            }
            return (node, locator)
        }
        let complete = coverageComplete && !tree.truncated
        let locatorDigests = matchedNodes.map { $0.1.identityDigest }
        let actions = matchedNodes.flatMap { $0.0.actions }
        guard !matchedNodes.isEmpty else {
            return TaskCapabilityVerificationEvaluation(
                state: .candidate,
                reason: complete ? "target_not_observed" : "bounded_surface_incomplete",
                coverageComplete: complete
            )
        }
        guard matchedNodes.count == 1 else {
            return TaskCapabilityVerificationEvaluation(
                state: .ambiguous,
                reason: "target_ambiguous",
                targetMatchCount: matchedNodes.count,
                targetLocatorDigests: locatorDigests,
                observedActions: actions,
                coverageComplete: complete
            )
        }
        let (node, locator) = matchedNodes[0]
        guard complete else {
            return TaskCapabilityVerificationEvaluation(
                state: .candidate,
                reason: "bounded_surface_incomplete",
                targetMatchCount: 1,
                targetLocatorDigests: [locator.identityDigest],
                observedActions: node.actions,
                coverageComplete: false
            )
        }
        guard node.state.visible && node.state.enabled else {
            return TaskCapabilityVerificationEvaluation(
                state: .unsupported,
                reason: "target_not_actionable",
                targetMatchCount: 1,
                targetLocatorDigests: [locator.identityDigest],
                observedActions: node.actions,
                coverageComplete: true
            )
        }

        switch route {
        case .accessibility:
            guard AccessibilityController.semanticActivationAction(
                role: node.role,
                subrole: node.subrole,
                actions: node.actions
            ) != nil else {
                let presentationOnly = AccessibilityController.semanticPresentationAction(
                    role: node.role,
                    subrole: node.subrole,
                    actions: node.actions
                ) != nil
                return TaskCapabilityVerificationEvaluation(
                    state: .unsupported,
                    reason: presentationOnly
                        ? "presentation_only_accessibility_action"
                        : "accessibility_activation_action_unavailable",
                    targetMatchCount: 1,
                    targetLocatorDigests: [locator.identityDigest],
                    observedActions: node.actions,
                    coverageComplete: true
                )
            }
        case .scroll:
            guard node.role == "AXScrollArea" else {
                return TaskCapabilityVerificationEvaluation(
                    state: .unsupported,
                    reason: "scroll_target_role_unavailable",
                    targetMatchCount: 1,
                    targetLocatorDigests: [locator.identityDigest],
                    observedActions: node.actions,
                    coverageComplete: true
                )
            }
            guard AccessibilityScrollDirection.allCases.contains(where: {
                $0.actionName(matching: node.actions) != nil
            }) else {
                return TaskCapabilityVerificationEvaluation(
                    state: .unsupported,
                    reason: "scroll_action_unavailable",
                    targetMatchCount: 1,
                    targetLocatorDigests: [locator.identityDigest],
                    observedActions: node.actions,
                    coverageComplete: true
                )
            }
        case .keyboard, .visual, .normalizedCoordinate, .rawCoordinate:
            break
        }

        guard let postconditionKind, !postconditionKind.isEmpty,
              let postconditionDigest, !postconditionDigest.isEmpty else {
            return TaskCapabilityVerificationEvaluation(
                state: .needsPostcondition,
                reason: "precise_postcondition_required",
                targetMatchCount: 1,
                targetLocatorDigests: [locator.identityDigest],
                observedActions: node.actions,
                coverageComplete: true
            )
        }
        return TaskCapabilityVerificationEvaluation(
            state: .readyForMeasurement,
            reason: "unique_actionable_surface_observed",
            targetMatchCount: 1,
            targetLocatorDigests: [locator.identityDigest],
            observedActions: node.actions,
            coverageComplete: true
        )
    }

    private static func matches(
        selector: Selector,
        node: AccessibilityTreeNode,
        locator: CapabilityLocatorDescriptor
    ) -> Bool {
        if let role = selector.role, node.role != role { return false }
        if let identifier = selector.identifier, node.identifier != identifier { return false }
        if let subrole = selector.subrole, node.subrole != subrole { return false }
        if let title = selector.title, node.label != title { return false }
        if let locatorDigest = selector.locatorDigest, locator.identityDigest != locatorDigest {
            return false
        }
        if let ancestorDigest = selector.ancestorDigest,
           locator.ancestorDigest != ancestorDigest {
            return false
        }
        if let geometryDigest = selector.geometryDigest,
           locator.geometryDigest != geometryDigest {
            return false
        }
        return true
    }
}
