import Foundation

public struct ControlCenterApproval: Codable, Equatable {
    public let operationID: String
    public let workflowID: String
    public let summary: String
    public let risk: RiskLevel
    public let focusPolicy: FocusPolicy
    public let keyboardFreezeRequired: Bool
    public let handoffTarget: ApprovalHandoffTarget?
    public let expiresAt: Date

    public init(record: ApprovalRecord) {
        operationID = record.operationID
        workflowID = record.workflowID
        summary = record.summary
        risk = record.risk
        focusPolicy = record.focusPolicy
        keyboardFreezeRequired = record.keyboardFreezeRequired
        handoffTarget = record.handoffTarget
        expiresAt = record.expiresAt
    }
}

public struct ControlCenterExecution: Codable, Equatable {
    public let executionID: String
    public let taskID: String?
    public let summary: String
    public let applicationName: String?
    public let physicalInputMode: KeyboardPhysicalInputMode
    public let focusPolicy: FocusPolicy?
    public let acquiredAt: Date
    public let expiresAt: Date
    public let stopping: Bool

    public init(
        executionID: String,
        taskID: String?,
        summary: String,
        applicationName: String?,
        physicalInputMode: KeyboardPhysicalInputMode,
        acquiredAt: Date,
        expiresAt: Date,
        stopping: Bool = false,
        focusPolicy: FocusPolicy? = nil
    ) {
        self.executionID = executionID
        self.taskID = taskID
        self.summary = summary
        self.applicationName = applicationName
        self.physicalInputMode = physicalInputMode
        self.focusPolicy = focusPolicy
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
        self.stopping = stopping
    }
}

public enum ControlCenterFocusPhase: String, Codable, Equatable {
    case focusing
    case focused
}

/// Short-lived, user-visible notice for foreground actions that do not hold a
/// task lease long enough to appear as an active execution.
public struct ControlCenterFocusActivity: Codable, Equatable {
    public let applicationName: String
    public let phase: ControlCenterFocusPhase
    public let startedAt: Date
    public let expiresAt: Date

    public init(
        applicationName: String,
        phase: ControlCenterFocusPhase,
        startedAt: Date,
        expiresAt: Date
    ) {
        self.applicationName = applicationName
        self.phase = phase
        self.startedAt = startedAt
        self.expiresAt = expiresAt
    }
}

/// A caller-owned run-level hands-off lease. Unlike `ControlCenterFocusActivity`,
/// this state intentionally survives individual actions and provider handoffs.
/// The caller must heartbeat it and explicitly end it; expiry is fail-closed.
public struct ControlCenterHandsOffSession: Codable, Equatable {
    public let sessionID: String
    public let provider: String
    public let taskID: String?
    public let applicationName: String?
    public let startedAt: Date
    public let lastHeartbeatAt: Date
    public let expiresAt: Date

    public init(
        sessionID: String,
        provider: String,
        taskID: String? = nil,
        applicationName: String? = nil,
        startedAt: Date,
        lastHeartbeatAt: Date,
        expiresAt: Date
    ) {
        self.sessionID = sessionID
        self.provider = provider
        self.taskID = taskID
        self.applicationName = applicationName
        self.startedAt = startedAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case provider
        case taskID = "task_id"
        case applicationName = "application_name"
        case startedAt = "started_at"
        case lastHeartbeatAt = "last_heartbeat_at"
        case expiresAt = "expires_at"
    }
}

public struct ControlCenterSnapshot: Codable, Equatable {
    public let approvals: [ControlCenterApproval]
    public let authorizationNotices: [AuthorizationNotice]
    public let execution: ControlCenterExecution?
    public let focusActivity: ControlCenterFocusActivity?
    public let handsOffSession: ControlCenterHandsOffSession?
    public let permissions: [PermissionStatus]
    public let lifecycleDrain: ControlCenterLifecycleDrain?

    public init(
        approvals: [ControlCenterApproval],
        execution: ControlCenterExecution?,
        permissions: [PermissionStatus],
        lifecycleDrain: ControlCenterLifecycleDrain? = nil,
        focusActivity: ControlCenterFocusActivity? = nil,
        handsOffSession: ControlCenterHandsOffSession? = nil,
        authorizationNotices: [AuthorizationNotice] = []
    ) {
        self.approvals = approvals
        self.authorizationNotices = authorizationNotices
        self.execution = execution
        self.focusActivity = focusActivity
        self.handsOffSession = handsOffSession
        self.permissions = permissions
        self.lifecycleDrain = lifecycleDrain
    }
}

public enum DaemonLifecycleOperation: String, Codable, Equatable {
    case install
    case restart
    case remove
    case upgrade
}

public struct ControlCenterLifecycleDrain: Codable, Equatable {
    public let operation: DaemonLifecycleOperation
    public let expiresAt: Date

    public init(operation: DaemonLifecycleOperation, expiresAt: Date) {
        self.operation = operation
        self.expiresAt = expiresAt
    }
}

public struct DaemonLifecycleDrainReport: Codable, Equatable {
    public let operation: DaemonLifecycleOperation
    public let ready: Bool
    public let expiresAt: Date

    public init(operation: DaemonLifecycleOperation, ready: Bool, expiresAt: Date) {
        self.operation = operation
        self.ready = ready
        self.expiresAt = expiresAt
    }
}

public enum ControlCenterVisualState: String, Codable, Equatable {
    case idle
    case authorization
    case approval
    case focusing
    case focused
    case handsOff = "hands_off"
    case leased
    case frozen
    case stopping
    case degraded
}

public struct ControlCenterPresentation: Equatable {
    public let state: ControlCenterVisualState
    public let label: String
    public let ringFraction: Double?
    public let tooltip: String
    public let accessibilityLabel: String
    public let pendingCount: Int
    public let authorizationCount: Int

    public static func make(
        snapshot: ControlCenterSnapshot,
        now: Date = Date(),
        approvalLifetime: TimeInterval = 300
    ) -> ControlCenterPresentation {
        let approvals = snapshot.approvals.filter { $0.expiresAt > now }
        let authorizationNotices = snapshot.authorizationNotices.filter {
            $0.state == .pending && $0.expiresAt > now
        }
        if let drain = snapshot.lifecycleDrain, drain.expiresAt > now {
            let remaining = max(0, drain.expiresAt.timeIntervalSince(now))
            return ControlCenterPresentation(
                state: .stopping,
                label: drain.operation == .upgrade ? "Updating" : "Restarting",
                ringFraction: nil,
                tooltip: "Daemon lifecycle drain active for \(durationLabel(remaining))",
                accessibilityLabel: "Daemon lifecycle drain active, \(durationLabel(remaining)) remaining",
                pendingCount: approvals.count,
                authorizationCount: authorizationNotices.count
            )
        }
        if let nearestAuthorization = authorizationNotices.min(by: { $0.expiresAt < $1.expiresAt }) {
            let remaining = max(0, nearestAuthorization.expiresAt.timeIntervalSince(now))
            let label = authorizationNotices.count == 1
                ? "Credential request"
                : "\(authorizationNotices.count) requests"
            let source = nearestAuthorization.provenance == .unverified ? " · unverified source" : ""
            return ControlCenterPresentation(
                state: .authorization,
                label: label,
                ringFraction: min(max(remaining / approvalLifetime, 0), 1),
                tooltip: "\(label) needs attention\(source) · expires in \(durationLabel(remaining))",
                accessibilityLabel: "\(label) needs attention\(source), expires in \(durationLabel(remaining))",
                pendingCount: approvals.count,
                authorizationCount: authorizationNotices.count
            )
        }
        let missing = snapshot.permissions.filter {
            $0.state == "missing" && ["Accessibility", "Input Monitoring", "Post Events"].contains($0.name)
        }
        let handsOffSession = snapshot.handsOffSession.flatMap { session in
            session.expiresAt > now ? session : nil
        }
        if let execution = snapshot.execution {
            let remaining = max(0, (handsOffSession?.expiresAt ?? execution.expiresAt).timeIntervalSince(now))
            let total = max(
                (handsOffSession?.expiresAt ?? execution.expiresAt)
                    .timeIntervalSince(handsOffSession?.startedAt ?? execution.acquiredAt),
                0.001
            )
            let fraction = min(max(remaining / total, 0), 1)
            let handsOff = handsOffSession != nil && !execution.stopping
            let focusTaken = execution.focusPolicy == .foreground
                && execution.applicationName != nil
                && !execution.stopping
            let mode: String
            if execution.physicalInputMode == .suppressed {
                mode = "Keyboard frozen"
            } else if handsOff {
                mode = "Hands off"
            } else if focusTaken {
                mode = "Focused"
            } else {
                mode = "Computer leased"
            }
            let target = execution.applicationName.map { " to \($0)" } ?? ""
            let countSuffix = approvals.isEmpty ? "" : " · \(approvals.count) approval\(approvals.count == 1 ? "" : "s")"
            let state: ControlCenterVisualState
            if execution.stopping {
                state = .stopping
            } else if execution.physicalInputMode == .suppressed {
                // Freeze remains the higher-salience safety state; the popover
                // still reports the target and focus policy separately.
                state = .frozen
            } else if handsOff {
                state = .handsOff
            } else if focusTaken {
                state = .focused
            } else {
                state = .leased
            }
            let label: String
            if execution.stopping {
                label = "Stopping"
            } else if handsOff {
                label = "Hands Off"
            } else if focusTaken {
                label = "Focused"
            } else {
                label = execution.applicationName ?? "Leased"
            }
            return ControlCenterPresentation(
                state: state,
                label: label,
                ringFraction: fraction,
                tooltip: "\(mode)\(target) for \(durationLabel(remaining))\(countSuffix)",
                accessibilityLabel: "\(mode)\(target), \(durationLabel(remaining)) remaining\(countSuffix)",
                pendingCount: approvals.count,
                authorizationCount: authorizationNotices.count
            )
        }
        if let handsOffSession {
            let remaining = max(0, handsOffSession.expiresAt.timeIntervalSince(now))
            let total = max(handsOffSession.expiresAt.timeIntervalSince(handsOffSession.startedAt), 0.001)
            let fraction = min(max(remaining / total, 0), 1)
            let target = handsOffSession.applicationName.map { " in \($0)" } ?? ""
            let provider = handsOffSession.provider.replacingOccurrences(of: "_", with: " ")
            let task = handsOffSession.taskID.map { " · task \($0)" } ?? ""
            return ControlCenterPresentation(
                state: .handsOff,
                label: "Hands Off",
                ringFraction: fraction,
                tooltip: "Hands off\(target) · \(provider) active · \(durationLabel(remaining))\(task)",
                accessibilityLabel: "Hands off\(target), \(provider) agent run active, \(durationLabel(remaining)) remaining",
                pendingCount: approvals.count,
                authorizationCount: authorizationNotices.count
            )
        }
        if let focusActivity = snapshot.focusActivity, focusActivity.expiresAt > now {
            let focused = focusActivity.phase == .focused
            let label = focused ? "Focused" : "Focusing"
            let target = " to \(focusActivity.applicationName)"
            let remaining = max(0, focusActivity.expiresAt.timeIntervalSince(now))
            return ControlCenterPresentation(
                state: focused ? .focused : .focusing,
                label: label,
                ringFraction: nil,
                tooltip: "Mac Control \(label.lowercased())\(target) · \(durationLabel(remaining))",
                accessibilityLabel: "Mac Control \(label.lowercased())\(target)",
                pendingCount: approvals.count,
                authorizationCount: authorizationNotices.count
            )
        }
        if let nearest = approvals.min(by: { $0.expiresAt < $1.expiresAt }) {
            let remaining = max(0, nearest.expiresAt.timeIntervalSince(now))
            let fraction = min(max(remaining / approvalLifetime, 0), 1)
            let label = approvals.count == 1 ? "Approval" : "\(approvals.count) approvals"
            return ControlCenterPresentation(
                state: .approval,
                label: label,
                ringFraction: fraction,
                tooltip: "\(label) required · expires in \(durationLabel(remaining))",
                accessibilityLabel: "\(label) required, nearest expires in \(durationLabel(remaining))",
                pendingCount: approvals.count,
                authorizationCount: authorizationNotices.count
            )
        }
        if !missing.isEmpty {
            let names = missing.map(\.name).joined(separator: ", ")
            return ControlCenterPresentation(
                state: .degraded,
                label: "Blocked",
                ringFraction: nil,
                tooltip: "macctl needs: \(names)",
                accessibilityLabel: "macctl degraded, missing \(names)",
                pendingCount: 0,
                authorizationCount: authorizationNotices.count
            )
        }
        return ControlCenterPresentation(
            state: .idle,
            label: "macctl",
            ringFraction: nil,
            tooltip: "macctl ready · computer available",
            accessibilityLabel: "macctl ready, computer available",
            pendingCount: 0,
            authorizationCount: authorizationNotices.count
        )
    }

    private static func durationLabel(_ seconds: TimeInterval) -> String {
        let rounded = max(0, Int(ceil(seconds)))
        if rounded >= 60 {
            return "\(rounded / 60)m \(rounded % 60)s"
        }
        return "\(rounded)s"
    }
}

public enum ApprovalHandoffTargetResolver {
    public static func resolve(for plan: TaskPlan) -> ApprovalHandoffTarget? {
        guard plan.focusPolicy == .foreground else { return nil }
        for step in plan.steps where stepRequiresForegroundInput(step.action) {
            if let name = step.target?.application, !name.isEmpty {
                return ApprovalHandoffTarget(applicationName: name, bundleID: step.target?.bundleID)
            }
            if let bundleID = step.target?.bundleID, !bundleID.isEmpty {
                return ApprovalHandoffTarget(applicationName: bundleID, bundleID: bundleID)
            }
            if let app = step.action.parameters["app"]?.stringValue, !app.isEmpty {
                return ApprovalHandoffTarget(applicationName: app)
            }
        }
        return nil
    }

    public static func resolve(for workflow: WorkflowSpec) -> ApprovalHandoffTarget? {
        guard workflow.focusPolicy == .foreground else { return nil }
        for action in workflow.actions where stepRequiresForegroundInput(action) {
            if let app = action.parameters["app"]?.stringValue, !app.isEmpty {
                return ApprovalHandoffTarget(applicationName: app)
            }
        }
        return nil
    }

    private static func stepRequiresForegroundInput(_ action: ActionSpec) -> Bool {
        switch action.kind {
        case .click, .type, .key, .search, .command, .scroll, .activateWindow, .adapter:
            return true
        case .launchApp, .waitFor, .capture, .ocr, .assert:
            return false
        }
    }
}
