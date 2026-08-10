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
        stopping: Bool = false
    ) {
        self.executionID = executionID
        self.taskID = taskID
        self.summary = summary
        self.applicationName = applicationName
        self.physicalInputMode = physicalInputMode
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
        self.stopping = stopping
    }
}

public struct ControlCenterSnapshot: Codable, Equatable {
    public let approvals: [ControlCenterApproval]
    public let execution: ControlCenterExecution?
    public let permissions: [PermissionStatus]
    public let lifecycleDrain: ControlCenterLifecycleDrain?

    public init(
        approvals: [ControlCenterApproval],
        execution: ControlCenterExecution?,
        permissions: [PermissionStatus],
        lifecycleDrain: ControlCenterLifecycleDrain? = nil
    ) {
        self.approvals = approvals
        self.execution = execution
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
    case approval
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

    public static func make(
        snapshot: ControlCenterSnapshot,
        now: Date = Date(),
        approvalLifetime: TimeInterval = 300
    ) -> ControlCenterPresentation {
        let approvals = snapshot.approvals.filter { $0.expiresAt > now }
        if let drain = snapshot.lifecycleDrain, drain.expiresAt > now {
            let remaining = max(0, drain.expiresAt.timeIntervalSince(now))
            return ControlCenterPresentation(
                state: .stopping,
                label: drain.operation == .upgrade ? "Updating" : "Restarting",
                ringFraction: nil,
                tooltip: "Daemon lifecycle drain active for \(durationLabel(remaining))",
                accessibilityLabel: "Daemon lifecycle drain active, \(durationLabel(remaining)) remaining",
                pendingCount: approvals.count
            )
        }
        let missing = snapshot.permissions.filter {
            $0.state == "missing" && ["Accessibility", "Input Monitoring", "Post Events"].contains($0.name)
        }
        if let execution = snapshot.execution {
            let remaining = max(0, execution.expiresAt.timeIntervalSince(now))
            let total = max(execution.expiresAt.timeIntervalSince(execution.acquiredAt), 0.001)
            let fraction = min(max(remaining / total, 0), 1)
            let mode = execution.physicalInputMode == .suppressed ? "Keyboard frozen" : "Computer leased"
            let target = execution.applicationName.map { " to \($0)" } ?? ""
            let countSuffix = approvals.isEmpty ? "" : " · \(approvals.count) approval\(approvals.count == 1 ? "" : "s")"
            let state: ControlCenterVisualState = execution.stopping
                ? .stopping
                : (execution.physicalInputMode == .suppressed ? .frozen : .leased)
            return ControlCenterPresentation(
                state: state,
                label: execution.stopping ? "Stopping" : (execution.applicationName ?? "Leased"),
                ringFraction: fraction,
                tooltip: "\(mode)\(target) for \(durationLabel(remaining))\(countSuffix)",
                accessibilityLabel: "\(mode)\(target), \(durationLabel(remaining)) remaining\(countSuffix)",
                pendingCount: approvals.count
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
                pendingCount: approvals.count
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
                pendingCount: 0
            )
        }
        return ControlCenterPresentation(
            state: .idle,
            label: "macctl",
            ringFraction: nil,
            tooltip: "macctl ready · computer available",
            accessibilityLabel: "macctl ready, computer available",
            pendingCount: 0
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
