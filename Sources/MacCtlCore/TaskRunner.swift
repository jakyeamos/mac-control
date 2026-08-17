import AppKit
import CryptoKit
import Foundation

public struct TaskExecutionAuthority {
    public let leaseToken: String?
    public let leaseExpiresAt: Date?
    public let fresh: Bool
    public let inputChannel: TaskInputChannel?

    private let revalidateHandler: () throws -> AppInfo?
    private let fingerprintHandler: () -> String?

    public init(
        leaseToken: String?,
        leaseExpiresAt: Date? = nil,
        fresh: Bool = true,
        inputChannel: TaskInputChannel? = nil,
        revalidate: @escaping () throws -> AppInfo?,
        fingerprint: @escaping () -> String? = { nil }
    ) {
        self.leaseToken = leaseToken
        self.leaseExpiresAt = leaseExpiresAt
        self.fresh = fresh
        self.inputChannel = inputChannel
        self.revalidateHandler = revalidate
        self.fingerprintHandler = fingerprint
    }

    @discardableResult
    public func revalidate() throws -> AppInfo? {
        try revalidateHandler()
    }

    public func fingerprint() -> String? {
        fingerprintHandler()
    }

    public func validateBinding(
        taskID: String,
        planDigest: String,
        focusPolicy: FocusPolicy
    ) throws {
        guard let inputChannel else { return }
        guard inputChannel.taskID == taskID,
              inputChannel.planDigest == planDigest,
              inputChannel.focusPolicy == focusPolicy else {
            throw TaskControlError.leaseRequired
        }
    }
}

public struct TaskActionContext {
    public let taskID: String
    public let stepID: String
    public let target: TaskTargetIdentity?
    public let focusPolicy: FocusPolicy
    public let planDigest: String
    public let ephemeralInputs: [String: String]
    public let deadline: Date
    public let authority: TaskExecutionAuthority?
    public let recoveryRoute: String?
    public let isCancelled: () -> Bool
    public let now: () -> Date
    private let targetRevalidation: () throws -> ControlTargetSnapshot?

    public init(
        taskID: String,
        stepID: String,
        target: TaskTargetIdentity?,
        focusPolicy: FocusPolicy,
        planDigest: String = "unavailable",
        ephemeralInputs: [String: String],
        deadline: Date,
        authority: TaskExecutionAuthority?,
        recoveryRoute: String? = nil,
        isCancelled: @escaping () -> Bool = { false },
        now: @escaping () -> Date = Date.init,
        targetRevalidation: @escaping () throws -> ControlTargetSnapshot? = { nil }
    ) {
        self.taskID = taskID
        self.stepID = stepID
        self.target = target
        self.focusPolicy = focusPolicy
        self.planDigest = planDigest
        self.ephemeralInputs = ephemeralInputs
        self.deadline = deadline
        self.authority = authority
        self.recoveryRoute = recoveryRoute
        self.isCancelled = isCancelled
        self.now = now
        self.targetRevalidation = targetRevalidation
    }

    public func withRecoveryRoute(_ route: String?) -> TaskActionContext {
        TaskActionContext(
            taskID: taskID,
            stepID: stepID,
            target: target,
            focusPolicy: focusPolicy,
            planDigest: planDigest,
            ephemeralInputs: ephemeralInputs,
            deadline: deadline,
            authority: authority,
            recoveryRoute: route,
            isCancelled: isCancelled,
            now: now,
            targetRevalidation: targetRevalidation
        )
    }

    @discardableResult
    public func requireAuthority() throws -> AppInfo? {
        guard let authority else { throw TaskControlError.leaseRequired }
        guard !isCancelled() else { throw TaskControlError.cancelled }
        guard now() < deadline else { throw TaskControlError.timedOut }
        guard authority.fresh else { throw TaskControlError.leaseRequired }
        try authority.validateBinding(taskID: taskID, planDigest: planDigest, focusPolicy: focusPolicy)
        if let expiresAt = authority.leaseExpiresAt, now() >= expiresAt {
            throw TaskControlError.leaseExpired
        }
        return try authority.revalidate()
    }

    @discardableResult
    public func revalidateBeforeAction(includeTarget: Bool = true) throws -> ControlTargetSnapshot? {
        guard !isCancelled() else { throw TaskControlError.cancelled }
        guard now() < deadline else { throw TaskControlError.timedOut }
        if let authority {
            guard authority.fresh else { throw TaskControlError.leaseRequired }
            try authority.validateBinding(taskID: taskID, planDigest: planDigest, focusPolicy: focusPolicy)
            if let expiresAt = authority.leaseExpiresAt, now() >= expiresAt {
                throw TaskControlError.leaseExpired
            }
            _ = try authority.revalidate()
        }
        return includeTarget ? try targetRevalidation() : nil
    }
}

public struct TaskActionExecutionReport: Codable, Equatable {
    public let route: String
    public let adapterID: String?
    public let targetFingerprint: String?
    public let sideEffectUncertain: Bool

    public init(
        route: String,
        adapterID: String? = nil,
        targetFingerprint: String? = nil,
        sideEffectUncertain: Bool = false
    ) {
        self.route = route
        self.adapterID = adapterID
        self.targetFingerprint = targetFingerprint
        self.sideEffectUncertain = sideEffectUncertain
    }
}

public enum TaskActionExecutionError: Error, LocalizedError, Equatable {
    case blocked(String)
    case uncertain(String)
    case unsupported(String)
    case permissionMissing(String)

    public var errorDescription: String? {
        switch self {
        case .blocked(let message): return "Task action blocked: \(message)"
        case .uncertain(let message): return "Task action outcome is uncertain: \(message)"
        case .unsupported(let message): return "Task action is unsupported: \(message)"
        case .permissionMissing(let permission): return "Task action requires permission: \(permission)"
        }
    }
}

public protocol TaskActionExecuting {
    func execute(
        action: ActionSpec,
        context: TaskActionContext
    ) throws -> TaskActionExecutionReport

    func evaluate(
        predicate: TaskPredicate,
        context: TaskActionContext
    ) throws -> Bool
}

/// A deterministic action seam used by unit tests and by the daemon runner.
/// It never invents a route or performs live input.
public final class BlockingTaskActionExecutor: TaskActionExecuting {
    public init() {}

    public func execute(
        action: ActionSpec,
        context: TaskActionContext
    ) throws -> TaskActionExecutionReport {
        throw TaskActionExecutionError.unsupported(action.kind.rawValue)
    }

    public func evaluate(
        predicate: TaskPredicate,
        context: TaskActionContext
    ) throws -> Bool {
        throw TaskActionExecutionError.blocked("No task observation executor is installed")
    }
}

public final class TaskRunner {
    private let checkpointStore: TaskCheckpointStore
    private let approvalStore: TaskApprovalStore
    private let actionExecutor: TaskActionExecuting
    private let now: () -> Date
    private let targetRevalidator: (TaskStep) throws -> ControlTargetSnapshot?
    private let adapterRegistry: AppAdapterRegistry?
    private let lock = NSLock()
    private var cancellationFlags: Set<String> = []

    public init(
        checkpointStore: TaskCheckpointStore = TaskCheckpointStore(),
        approvalStore: TaskApprovalStore = TaskApprovalStore(),
        actionExecutor: TaskActionExecuting = BlockingTaskActionExecutor(),
        now: @escaping () -> Date = Date.init,
        targetRevalidator: @escaping (TaskStep) throws -> ControlTargetSnapshot? = { _ in nil },
        adapterRegistry: AppAdapterRegistry? = nil
    ) {
        self.checkpointStore = checkpointStore
        self.approvalStore = approvalStore
        self.actionExecutor = actionExecutor
        self.now = now
        self.targetRevalidator = targetRevalidator
        self.adapterRegistry = adapterRegistry
    }

    public func prepare(
        plan: TaskPlan,
        ephemeralInputs: [String: String] = [:]
    ) throws -> TaskPreparedReport {
        try validate(plan)
        let digest = TaskPlan.digest(plan, ephemeralInputs: ephemeralInputs)
        var existing = try loadCheckpoint(plan.id)
        if let running = existing, running.state == .running {
            guard running.planDigest == digest else {
                throw TaskControlError.approvalMismatch
            }
            // An interruption cannot prove whether the current action was
            // dispatched. Preserve the indeterminate checkpoint and require
            // fresh execution authority before a caller can resume.
            let interrupted = checkpointCopy(
                running,
                state: .indeterminate,
                verificationResult: "indeterminate",
                lastErrorCode: "task_interrupted",
                updatedAt: now()
            )
            try saveCheckpoint(interrupted)
            existing = interrupted
        }
        if existing?.state == .expired {
            throw TaskControlError.invalidState(.expired)
        }
        if existing == nil || ![.paused, .blocked, .indeterminate].contains(existing!.state) {
            let timestamp = now()
            let checkpoint = TaskCheckpoint(
                taskID: plan.id,
                planDigest: digest,
                currentStepID: plan.steps.first?.id,
                stepIndex: 0,
                state: .prepared,
                preconditionHash: hash(plan.steps.first?.preconditions ?? []),
                createdAt: timestamp,
                updatedAt: timestamp
            )
            try saveCheckpoint(checkpoint)
        }
        return TaskPreparedReport(
            taskID: plan.id,
            planDigest: digest,
            state: existing.map { [.paused, .blocked, .indeterminate].contains($0.state) ? $0.state : .prepared } ?? .prepared,
            risk: TaskPlanValidator.validate(plan, adapterRegistry: adapterRegistry).risk
        )
    }

    public func status(taskID: String) throws -> TaskStatusReport {
        guard let checkpoint = try loadCheckpoint(taskID) else {
            throw TaskControlError.notFound(taskID)
        }
        return report(for: checkpoint)
    }

    public func run(
        plan: TaskPlan,
        ephemeralInputs: [String: String] = [:],
        authority: TaskExecutionAuthority? = nil,
        effectiveFocusPolicy: FocusPolicy? = nil
    ) throws -> TaskStatusReport {
        try execute(
            plan: plan,
            ephemeralInputs: ephemeralInputs,
            authority: authority,
            effectiveFocusPolicy: effectiveFocusPolicy,
            resuming: false
        )
    }

    public func resume(
        plan: TaskPlan,
        ephemeralInputs: [String: String] = [:],
        authority: TaskExecutionAuthority,
        effectiveFocusPolicy: FocusPolicy? = nil
    ) throws -> TaskStatusReport {
        try execute(
            plan: plan,
            ephemeralInputs: ephemeralInputs,
            authority: authority,
            effectiveFocusPolicy: effectiveFocusPolicy,
            resuming: true
        )
    }

    public func cancel(taskID: String) throws -> TaskStatusReport {
        guard let checkpoint = try loadCheckpoint(taskID) else {
            throw TaskControlError.notFound(taskID)
        }
        guard checkpoint.state != .completed, checkpoint.state != .cancelled else {
            throw TaskControlError.invalidState(checkpoint.state)
        }
        lock.lock()
        if checkpoint.state == .running {
            cancellationFlags.insert(taskID)
        } else {
            cancellationFlags.remove(taskID)
        }
        lock.unlock()
        guard checkpoint.state != .running else {
            return report(for: checkpoint)
        }
        let cancelled = checkpointCopy(
            checkpoint,
            state: .cancelled,
            lastErrorCode: "task_cancelled",
            updatedAt: now()
        )
        try saveCheckpoint(cancelled)
        return report(for: cancelled)
    }

    private func execute(
        plan: TaskPlan,
        ephemeralInputs: [String: String],
        authority: TaskExecutionAuthority?,
        effectiveFocusPolicy: FocusPolicy?,
        resuming: Bool
    ) throws -> TaskStatusReport {
        try validate(plan)
        let executionFocusPolicy = effectiveFocusPolicy
            ?? FocusPolicyResolution.resolve(
                requestedPolicy: plan.focusPolicy,
                backgroundEligible: false,
                backgroundUnavailableReason: "execution_policy_not_resolved"
            ).effectivePolicy
        try validate(plan.withFocusPolicy(executionFocusPolicy))
        guard let checkpoint = try loadCheckpoint(plan.id) else {
            throw TaskControlError.notFound(plan.id)
        }
        let expectedDigest = TaskPlan.digest(plan, ephemeralInputs: ephemeralInputs)
        guard checkpoint.planDigest == expectedDigest else {
            throw TaskControlError.approvalMismatch
        }
        if resuming {
            guard [.paused, .blocked, .indeterminate].contains(checkpoint.state) else {
                throw TaskControlError.invalidState(checkpoint.state)
            }
            guard authority?.fresh == true else { throw TaskControlError.leaseRequired }
        } else if checkpoint.state != .prepared {
            throw TaskControlError.invalidState(checkpoint.state)
        }
        if plan.requiresInputAuthority(using: adapterRegistry) {
            guard let authority, authority.fresh else { throw TaskControlError.leaseRequired }
        }
        var actionDispatched = false
        let markDispatch = {
            actionDispatched = true
        }

        let startedAt = now()
        let taskStartedAt = checkpoint.startedAt ?? startedAt
        let deadline = taskStartedAt.addingTimeInterval(plan.totalTimeout)
        var current = checkpointCopy(
            checkpoint,
            state: .running,
            lastErrorCode: nil,
            startedAt: taskStartedAt,
            updatedAt: now()
        )
        try saveCheckpoint(current)
        defer {
            lock.lock()
            cancellationFlags.remove(plan.id)
            lock.unlock()
        }

        while current.stepIndex < plan.steps.count {
            let step = plan.steps[current.stepIndex]
            var stepAttempts = 0
            var stepRoute: String?
            do {
                try checkTaskLiveness(
                    taskID: plan.id,
                    deadline: deadline
                )
                let context = TaskActionContext(
                    taskID: plan.id,
                    stepID: step.id,
                    target: step.target,
                    focusPolicy: executionFocusPolicy,
                    planDigest: expectedDigest,
                    ephemeralInputs: ephemeralInputs,
                    deadline: minDate(deadline, now().addingTimeInterval(step.timeout)),
                    authority: authority,
                    isCancelled: { [weak self] in self?.isCancelled(plan.id) ?? false },
                    now: now,
                    targetRevalidation: { [targetRevalidator, step] in
                        try targetRevalidator(step)
                    }
                )
                let stepResult = try executeStep(
                    step,
                    context: context,
                    current: current,
                    deadline: deadline,
                    attempts: &stepAttempts,
                    route: &stepRoute,
                    consumeApprovalAtDispatch: markDispatch
                )
                current = checkpointCopy(
                    current,
                    state: .running,
                    currentStepID: plan.steps[safe: current.stepIndex + 1]?.id,
                    lastStepID: step.id,
                    stepIndex: current.stepIndex + 1,
                    route: stepResult.route,
                    attempts: current.attempts + stepResult.attempts,
                    targetFingerprint: stepResult.targetFingerprint,
                    preconditionHash: hash(step.preconditions),
                    postconditionHash: hash(step.postconditions),
                    verificationResult: "passed",
                    lastErrorCode: nil,
                    updatedAt: now()
                )
                try saveCheckpoint(current)
            } catch let error as TaskControlError {
                if actionDispatched {
                    current = try persistFailure(
                        checkpoint: current,
                        step: step,
                        error: error,
                        attempts: stepAttempts,
                        route: stepRoute
                    )
                } else {
                    current = checkpointCopy(
                        current,
                        state: .prepared,
                        currentStepID: step.id,
                        route: stepRoute,
                        attempts: current.attempts + stepAttempts,
                        verificationResult: "pre_dispatch_failed",
                        lastErrorCode: errorCode(for: error),
                        updatedAt: now()
                    )
                    try saveCheckpoint(current)
                }
                throw error
            } catch {
                let taskError = TaskControlError.blocked(errorCode(for: error))
                if actionDispatched {
                    current = try persistFailure(
                        checkpoint: current,
                        step: step,
                        error: taskError,
                        attempts: stepAttempts,
                        route: stepRoute
                    )
                } else {
                    current = checkpointCopy(
                        current,
                        state: .prepared,
                        currentStepID: step.id,
                        route: stepRoute,
                        attempts: current.attempts + stepAttempts,
                        verificationResult: "pre_dispatch_failed",
                        lastErrorCode: errorCode(for: taskError),
                        updatedAt: now()
                    )
                    try saveCheckpoint(current)
                }
                throw taskError
            }
        }

        current = checkpointCopy(
            current,
            state: .completed,
            currentStepID: nil,
            clearCurrentStepID: true,
            verificationResult: "passed",
            updatedAt: now()
        )
        try saveCheckpoint(current)
        return report(for: current)
    }

    private struct StepResult {
        let route: String
        let attempts: Int
        let targetFingerprint: String?
    }

    private func executeStep(
        _ step: TaskStep,
        context: TaskActionContext,
        current: TaskCheckpoint,
        deadline: Date,
        attempts: inout Int,
        route: inout String?,
        consumeApprovalAtDispatch: () throws -> Void
    ) throws -> StepResult {
        let maximumAttempts = TaskPlanValidator.attemptLimit(for: step.risk, recovery: step.recovery)
        var lastReport: TaskActionExecutionReport?
        attempts = 0
        route = nil
        while attempts < maximumAttempts {
            try checkTaskLiveness(
                taskID: context.taskID,
                deadline: minDate(deadline, context.deadline)
            )
            let nextAttempt = attempts + 1
            let recoveryRoute = nextAttempt > 1 && step.recovery.permitsAlternateRoute
                ? step.recovery.alternateRoutes[safe: nextAttempt - 2]
                : nil
            let attemptContext = context.withRecoveryRoute(recoveryRoute)
            route = recoveryRoute
            do {
                try evaluate(
                    step.preconditions,
                    context: attemptContext,
                    failure: { TaskControlError.preconditionFailed(step.id) }
                )
                attempts = nextAttempt
                try checkTaskLiveness(
                    taskID: context.taskID,
                    deadline: minDate(deadline, context.deadline)
                )
                _ = try attemptContext.revalidateBeforeAction(
                    includeTarget: requiresTargetRevalidation(for: step.action)
                )
                try consumeApprovalAtDispatch()
                try saveCheckpoint(checkpointCopy(
                    current,
                    state: .running,
                    currentStepID: step.id,
                    route: recoveryRoute,
                    attempts: current.attempts + attempts,
                    preconditionHash: hash(step.preconditions),
                    postconditionHash: hash(step.postconditions),
                    verificationResult: "dispatching",
                    lastErrorCode: nil,
                    updatedAt: now()
                ))
                let report = try actionExecutor.execute(action: step.action, context: attemptContext)
                lastReport = report
                route = report.route
                if report.sideEffectUncertain {
                    throw TaskControlError.indeterminate(step.id)
                }
                if try evaluateAll(step.postconditions, context: attemptContext) {
                    return StepResult(
                        route: report.route,
                        attempts: attempts,
                        targetFingerprint: report.targetFingerprint
                    )
                }
                if step.risk == .sensitive {
                    throw TaskControlError.indeterminate(step.id)
                }
                if step.risk == .reversible && !step.recovery.permitsAlternateRoute {
                    throw TaskControlError.postconditionFailed(step.id)
                }
                if attempts == maximumAttempts {
                    throw TaskControlError.postconditionFailed(step.id)
                }
            } catch let error as TaskControlError {
                if case .indeterminate = error { throw error }
                if case .cancelled = error { throw error }
                if case .leaseExpired = error { throw error }
                if case .timedOut = error { throw error }
                if case .preconditionFailed = error { throw error }
                if attempts == maximumAttempts || step.risk == .sensitive {
                    throw error
                }
            } catch let error as TaskActionExecutionError {
                switch error {
                case .uncertain(let message):
                    throw TaskControlError.indeterminate(message)
                case .permissionMissing(let permission):
                    throw TaskControlError.blocked("permission_\(permission.lowercased().replacingOccurrences(of: " ", with: "_"))")
                case .unsupported:
                    throw TaskControlError.blocked(errorCode(for: error))
                case .blocked:
                    if attempts == maximumAttempts || step.risk == .sensitive {
                        throw TaskControlError.blocked(errorCode(for: error))
                    }
                }
            } catch let error as AppAdapterError {
                switch error {
                case .operationFailed:
                    throw TaskControlError.indeterminate(step.id)
                case .permissionMissing, .unsupportedAdapter, .unsupportedOperation,
                     .targetUnavailable, .ambiguousTarget, .arbitraryScriptRejected:
                    throw TaskControlError.blocked(errorCode(for: error))
                }
            } catch let error as ControlTargetInspectionError {
                throw TaskControlError.preconditionFailed(errorCode(for: error))
            } catch {
                if attempts == maximumAttempts || step.risk == .sensitive {
                    if step.risk == .sensitive {
                        throw TaskControlError.indeterminate(step.id)
                    }
                    throw TaskControlError.blocked(errorCode(for: error))
                }
            }
        }
        throw TaskControlError.blocked(lastReport?.route ?? "task_step_failed")
    }

    private func evaluate(
        _ predicates: [TaskPredicate],
        context: TaskActionContext,
        failure: () -> TaskControlError
    ) throws {
        do {
            guard try evaluateAll(predicates, context: context) else { throw failure() }
        } catch let error as TaskControlError {
            throw error
        } catch let error as ControlTargetInspectionError {
            throw TaskControlError.preconditionFailed(errorCode(for: error))
        } catch let error as TaskActionExecutionError {
            switch error {
            case .uncertain(let message):
                throw TaskControlError.indeterminate(message)
            case .permissionMissing(let permission):
                throw TaskControlError.preconditionFailed(
                    "permission_\(permission.lowercased().replacingOccurrences(of: " ", with: "_"))"
                )
            case .blocked(let message), .unsupported(let message):
                throw TaskControlError.preconditionFailed(message)
            }
        } catch {
            throw TaskControlError.preconditionFailed(errorCode(for: error))
        }
    }

    private func evaluateAll(
        _ predicates: [TaskPredicate],
        context: TaskActionContext
    ) throws -> Bool {
        for predicate in predicates {
            _ = try context.revalidateBeforeAction(
                includeTarget: requiresTargetRevalidation(for: predicate)
            )
            if try !actionExecutor.evaluate(predicate: predicate, context: context) {
                return false
            }
        }
        return true
    }

    private func requiresTargetRevalidation(for action: ActionSpec) -> Bool {
        switch action.kind {
        case .click, .type, .key, .search, .command, .scroll, .activateWindow, .capture, .ocr, .adapter:
            return true
        case .launchApp, .waitFor, .assert:
            return false
        }
    }

    private func requiresTargetRevalidation(for predicate: TaskPredicate) -> Bool {
        switch predicate.kind {
        case .focusedElement, .elementExists, .windowVisible, .adapterState, .modalAbsent, .focusReadable, .menuItemState:
            return true
        case .foregroundApplication, .applicationRunning:
            return false
        }
    }

    private func checkTaskLiveness(
        taskID: String,
        deadline: Date
    ) throws {
        guard !isCancelled(taskID) else { throw TaskControlError.cancelled }
        guard now() < deadline else { throw TaskControlError.timedOut }
    }

    private func persistFailure(
        checkpoint: TaskCheckpoint,
        step: TaskStep?,
        error: TaskControlError,
        attempts: Int,
        route: String?
    ) throws -> TaskCheckpoint {
        let state: TaskLifecycleState
        switch error {
        case .cancelled: state = .cancelled
        case .timedOut, .leaseExpired: state = .expired
        case .indeterminate: state = .indeterminate
        case .preconditionFailed: state = .paused
        default: state = .blocked
        }
        let verificationResult: String
        switch error {
        case .preconditionFailed: verificationResult = "precondition_failed"
        case .postconditionFailed: verificationResult = "postcondition_failed"
        case .indeterminate: verificationResult = "indeterminate"
        case .cancelled: verificationResult = "cancelled"
        case .timedOut, .leaseExpired: verificationResult = "expired"
        default: verificationResult = "blocked"
        }
        let persisted = checkpointCopy(
            checkpoint,
            state: state,
            currentStepID: step?.id ?? checkpoint.currentStepID,
            route: route ?? checkpoint.route,
            attempts: checkpoint.attempts + attempts,
            preconditionHash: step.map { hash($0.preconditions) } ?? checkpoint.preconditionHash,
            postconditionHash: step.map { hash($0.postconditions) } ?? checkpoint.postconditionHash,
            verificationResult: verificationResult,
            lastErrorCode: errorCode(for: error),
            updatedAt: now()
        )
        try saveCheckpoint(persisted)
        return persisted
    }

    private func report(for checkpoint: TaskCheckpoint) -> TaskStatusReport {
        TaskStatusReport(
            taskID: checkpoint.taskID,
            planDigest: checkpoint.planDigest,
            state: checkpoint.state,
            stepIndex: checkpoint.stepIndex,
            currentStepID: checkpoint.currentStepID,
            lastStepID: checkpoint.lastStepID,
            attempts: checkpoint.attempts,
            lastRoute: checkpoint.route,
            lastErrorCode: checkpoint.lastErrorCode,
            checkpointUpdatedAt: checkpoint.updatedAt,
            completedAt: checkpoint.state == .completed ? checkpoint.updatedAt : nil
        )
    }

    private func checkpointCopy(
        _ checkpoint: TaskCheckpoint,
        state: TaskLifecycleState,
        currentStepID: String? = nil,
        lastStepID: String? = nil,
        clearCurrentStepID: Bool = false,
        stepIndex: Int? = nil,
        route: String? = nil,
        attempts: Int? = nil,
        targetFingerprint: String? = nil,
        preconditionHash: String? = nil,
        postconditionHash: String? = nil,
        verificationResult: String? = nil,
        lastErrorCode: String? = nil,
        startedAt: Date? = nil,
        updatedAt: Date
    ) -> TaskCheckpoint {
        TaskCheckpoint(
            taskID: checkpoint.taskID,
            planDigest: checkpoint.planDigest,
            currentStepID: clearCurrentStepID ? nil : (currentStepID ?? checkpoint.currentStepID),
            lastStepID: lastStepID ?? checkpoint.lastStepID,
            stepIndex: stepIndex ?? checkpoint.stepIndex,
            state: state,
            route: route ?? checkpoint.route,
            attempts: attempts ?? checkpoint.attempts,
            targetFingerprint: targetFingerprint ?? checkpoint.targetFingerprint,
            preconditionHash: preconditionHash ?? checkpoint.preconditionHash,
            postconditionHash: postconditionHash ?? checkpoint.postconditionHash,
            verificationResult: verificationResult ?? checkpoint.verificationResult,
            lastErrorCode: lastErrorCode,
            createdAt: checkpoint.createdAt,
            updatedAt: updatedAt,
            startedAt: startedAt ?? checkpoint.startedAt
        )
    }

    private func validate(_ plan: TaskPlan) throws {
        let validation = TaskPlanValidator.validate(plan, adapterRegistry: adapterRegistry)
        guard validation.valid else { throw TaskControlError.invalidPlan(validation.errors) }
    }

    private func loadCheckpoint(_ taskID: String) throws -> TaskCheckpoint? {
        do { return try checkpointStore.load(taskID: taskID) }
        catch { throw TaskControlError.checkpointUnavailable(errorCode(for: error)) }
    }

    private func saveCheckpoint(_ checkpoint: TaskCheckpoint) throws {
        do { try checkpointStore.save(checkpoint) }
        catch { throw TaskControlError.checkpointUnavailable(errorCode(for: error)) }
    }

    private func isCancelled(_ taskID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationFlags.contains(taskID)
    }

    private func hash<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONCodec.encode(value) else { return nil }
        return TaskPlanDigest.hash(data: data)
    }

    private func errorCode(for error: Error) -> String {
        switch error {
        case let error as TaskControlError:
            switch error {
            case .cancelled: return "task_cancelled"
            case .timedOut: return "task_timeout"
            case .leaseExpired, .leaseRequired: return "task_lease_expired"
            case .preconditionFailed: return "task_precondition_failed"
            case .postconditionFailed: return "task_postcondition_failed"
            case .indeterminate: return "task_indeterminate"
            case .blocked: return "task_blocked"
            case .invalidPlan: return "task_invalid_plan"
            case .approvalRequired: return "task_approval_required"
            case .approvalMismatch: return "task_approval_mismatch"
            case .invalidState: return "task_invalid_state"
            case .notFound: return "task_not_found"
            case .checkpointUnavailable: return "task_checkpoint_unavailable"
            }
        case let error as TaskActionExecutionError:
            switch error {
            case .uncertain: return "task_indeterminate"
            case .permissionMissing: return "adapter_permission_missing"
            case .unsupported: return "adapter_unsupported"
            case .blocked: return "task_action_blocked"
            }
        case let error as AppAdapterError:
            switch error {
            case .permissionMissing: return "adapter_permission_missing"
            case .unsupportedAdapter, .unsupportedOperation, .arbitraryScriptRejected: return "adapter_unsupported"
            case .ambiguousTarget: return "ambiguous_target"
            case .targetUnavailable: return "target_unavailable"
            case .operationFailed: return "adapter_operation_failed"
            }
        case let error as ControlTargetInspectionError:
            switch error {
            case .applicationUnavailable: return "target_unavailable"
            case .unreadableFocus: return "focus_unreadable"
            case .modalDialog: return "modal_dialog"
            case .hungApplication: return "hung_application"
            case .ambiguousTarget: return "ambiguous_target"
            case .targetChanged: return "target_changed"
            }
        case is TaskCheckpointStoreError: return "task_checkpoint_unavailable"
        default: return "task_action_failed"
        }
    }

    private func minDate(_ lhs: Date, _ rhs: Date) -> Date {
        min(lhs, rhs)
    }
}

private enum TaskPlanDigest {
    static func hash(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum CancellableMonotonicWait {
    static func run(
        seconds: TimeInterval,
        monotonicNow: () -> TimeInterval,
        sleep: (TimeInterval) -> Void,
        checkpoint: () throws -> Void
    ) throws {
        let end = monotonicNow() + seconds
        repeat {
            try checkpoint()
            let remaining = end - monotonicNow()
            guard remaining > 0 else { break }
            sleep(min(remaining, 0.05))
        } while monotonicNow() < end
        try checkpoint()
    }
}

/// Native/Accessibility/keyboard execution for the allowlisted task action
/// set.  Adapter mutations are dispatched only by typed operation name.
public final class MacTaskActionExecutor: TaskActionExecuting {
    private let appController: AppController
    private let accessibilityController: AccessibilityController
    private let inputController: InputController
    private let keyboardAccessController: KeyboardAccessController
    private let semanticActionRouter: SemanticActionRouter
    private let adapterRegistry: AppAdapterRegistry
    private let typedAppleScriptExecutor: TypedAppleScriptExecuting
    private let focusSessionExecutor: FocusSessionActionExecuting
    private let foregroundApplication: () -> AppInfo?
    private let searchFieldResolver: SearchFieldResolving
    private let focusedElementInspector: FocusedElementInspecting
    private let searchTextTyper: SearchTextTyping
    private let backgroundPress: (pid_t, Selector) throws -> Void
    private let backgroundSetValue: (pid_t, Selector, String) throws -> Void
    private let backgroundSendKey: (String, pid_t) throws -> Void
    private let backgroundScroll: (
        pid_t,
        AppInfo,
        Selector,
        AccessibilityScrollDirection,
        Int
    ) throws -> AccessibilityScrollReport
    private let monotonicNow: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void

    public init(
        appController: AppController,
        accessibilityController: AccessibilityController,
        inputController: InputController,
        keyboardAccessController: KeyboardAccessController,
        semanticActionRouter: SemanticActionRouter,
        adapterRegistry: AppAdapterRegistry,
        foregroundApplication: @escaping () -> AppInfo?,
        typedAppleScriptExecutor: TypedAppleScriptExecuting = SystemTypedAppleScriptExecutor(),
        focusSessionExecutor: FocusSessionActionExecuting? = nil,
        searchFieldResolver: SearchFieldResolving? = nil,
        focusedElementInspector: FocusedElementInspecting? = nil,
        searchTextTyper: SearchTextTyping? = nil,
        backgroundPress: ((pid_t, Selector) throws -> Void)? = nil,
        backgroundSetValue: ((pid_t, Selector, String) throws -> Void)? = nil,
        backgroundSendKey: ((String, pid_t) throws -> Void)? = nil,
        backgroundScroll: ((
            pid_t,
            AppInfo,
            Selector,
            AccessibilityScrollDirection,
            Int
        ) throws -> AccessibilityScrollReport)? = nil,
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
    ) {
        self.appController = appController
        self.accessibilityController = accessibilityController
        self.inputController = inputController
        self.keyboardAccessController = keyboardAccessController
        self.semanticActionRouter = semanticActionRouter
        self.adapterRegistry = adapterRegistry
        self.typedAppleScriptExecutor = typedAppleScriptExecutor
        self.focusSessionExecutor = focusSessionExecutor
            ?? SystemFocusSessionActionExecutor(accessibilityController: accessibilityController)
        self.foregroundApplication = foregroundApplication
        self.searchFieldResolver = searchFieldResolver ?? accessibilityController
        self.focusedElementInspector = focusedElementInspector ?? accessibilityController
        self.searchTextTyper = searchTextTyper ?? inputController
        self.backgroundPress = backgroundPress ?? { pid, selector in
            _ = try accessibilityController.press(pid: pid, selector: selector)
        }
        self.backgroundSetValue = backgroundSetValue ?? { pid, selector, value in
            _ = try accessibilityController.setValueAndVerify(pid: pid, selector: selector, value: value)
        }
        self.backgroundSendKey = backgroundSendKey ?? { specification, pid in
            try inputController.key(specification, toProcess: pid)
        }
        self.backgroundScroll = backgroundScroll ?? { pid, application, selector, direction, amount in
            try accessibilityController.scroll(
                pid: pid,
                application: application,
                selector: selector,
                direction: direction,
                amount: amount
            )
        }
        self.monotonicNow = monotonicNow
        self.sleep = sleep
    }

    public func execute(
        action: ActionSpec,
        context: TaskActionContext
    ) throws -> TaskActionExecutionReport {
        switch action.kind {
        case .launchApp:
            try requireRecoveryRoute(context, allowed: ["native"])
            let name = try requiredParameter(action, key: "app")
            let app = try appController.open(name, focusPolicy: context.focusPolicy)
            return report(route: "native", application: app)
        case .activateWindow:
            try requireRecoveryRoute(context, allowed: ["native"])
            let appName = try requiredParameter(action, key: "app")
            let _ = try context.requireAuthority()
            _ = try context.revalidateBeforeAction(includeTarget: true)
            let app = try appController.activate(appName)
            return report(route: "native", application: app)
        case .click:
            guard let selector = action.selector else {
                throw TaskActionExecutionError.blocked("missing_selector")
            }
            if context.focusPolicy == .background {
                try requireRecoveryRoute(context, allowed: ["accessibility"])
                guard selector.addressability == .accessibility,
                      context.authority?.inputChannel?.permits(.accessibility) == true else {
                    throw TaskActionExecutionError.unsupported("background_click_requires_task_accessibility_channel")
                }
                guard let application = try context.requireAuthority(), let pid = application.processID else {
                    throw TaskControlError.leaseRequired
                }
                _ = try context.revalidateBeforeAction(includeTarget: true)
                do {
                    try backgroundPress(pid, selector)
                } catch AccessibilityControllerError.ambiguousMatch {
                    throw TaskActionExecutionError.blocked("ambiguous_target")
                } catch AccessibilityControllerError.elementNotFound {
                    throw TaskActionExecutionError.blocked("target_unavailable")
                } catch AccessibilityControllerError.permissionDenied {
                    throw TaskActionExecutionError.permissionMissing("Accessibility")
                }
                _ = try context.revalidateBeforeAction(includeTarget: true)
                return report(route: "task_input_accessibility", application: application)
            }
            guard let leaseToken = context.authority?.leaseToken else {
                throw TaskControlError.leaseRequired
            }
            _ = try context.requireAuthority()
            _ = try context.revalidateBeforeAction(includeTarget: true)
            let semantic: SemanticActionReport
            switch try recoveryRoute(context) {
            case .none:
                semantic = try semanticActionRouter.perform(
                    command: .activate,
                    selector: selector,
                    leaseToken: leaseToken,
                    count: 1,
                    interKeyDelay: action.parameters["inter_key_ms"]?.doubleValue ?? 0,
                    allowRawCoordinate: action.parameters["allow_raw_coordinate"]?.boolValue == true
                )
            case .some("keyboard"):
                semantic = try semanticActionRouter.perform(
                    command: .activate,
                    selector: nil,
                    leaseToken: leaseToken,
                    count: 1,
                    interKeyDelay: action.parameters["inter_key_ms"]?.doubleValue ?? 0,
                    allowRawCoordinate: false
                )
            case .some("visual"):
                guard selector.addressability != .accessibility else {
                    throw TaskActionExecutionError.unsupported("visual_route_requires_visual_selector")
                }
                semantic = try semanticActionRouter.perform(
                    command: .activate,
                    selector: selector,
                    leaseToken: leaseToken,
                    count: 1,
                    interKeyDelay: action.parameters["inter_key_ms"]?.doubleValue ?? 0,
                    allowRawCoordinate: action.parameters["allow_raw_coordinate"]?.boolValue == true
                )
            case .some("accessibility"):
                guard selector.addressability == .accessibility else {
                    throw TaskActionExecutionError.unsupported("accessibility_route_requires_accessibility_selector")
                }
                guard let application = try context.requireAuthority(), let pid = application.processID else {
                    throw TaskControlError.leaseRequired
                }
                _ = try context.revalidateBeforeAction(includeTarget: true)
                do {
                    _ = try accessibilityController.press(pid: pid, selector: selector)
                } catch AccessibilityControllerError.ambiguousMatch {
                    throw TaskActionExecutionError.blocked("ambiguous_target")
                } catch AccessibilityControllerError.elementNotFound {
                    throw TaskActionExecutionError.blocked("target_unavailable")
                } catch AccessibilityControllerError.permissionDenied {
                    throw TaskActionExecutionError.permissionMissing("Accessibility")
                }
                return report(route: "accessibility", application: application)
            default:
                throw TaskActionExecutionError.unsupported("unsupported_click_recovery_route")
            }
            return TaskActionExecutionReport(
                route: semantic.route.rawValue,
                targetFingerprint: ControlTargetFingerprints.make(
                    application: semantic.targetApplication,
                    focus: semantic.verification.focusAfter
                )
            )
        case .type:
            let inputKey = try requiredParameter(action, key: "input_key")
            guard let text = context.ephemeralInputs[inputKey] else {
                throw TaskActionExecutionError.blocked("missing_ephemeral_input")
            }
            if context.focusPolicy == .background {
                try requireRecoveryRoute(context, allowed: ["accessibility"])
                guard let selector = action.selector,
                      selector.addressability == .accessibility,
                      context.authority?.inputChannel?.permits(.accessibility) == true else {
                    throw TaskActionExecutionError.unsupported("background_type_requires_task_accessibility_channel")
                }
                guard let application = try context.requireAuthority(), let pid = application.processID else {
                    throw TaskControlError.leaseRequired
                }
                _ = try context.revalidateBeforeAction(includeTarget: true)
                do {
                    try backgroundSetValue(pid, selector, text)
                } catch AccessibilityControllerError.ambiguousMatch {
                    throw TaskActionExecutionError.blocked("ambiguous_target")
                } catch AccessibilityControllerError.elementNotFound {
                    throw TaskActionExecutionError.blocked("target_unavailable")
                } catch AccessibilityControllerError.permissionDenied {
                    throw TaskActionExecutionError.permissionMissing("Accessibility")
                }
                _ = try context.revalidateBeforeAction(includeTarget: true)
                return report(route: "task_input_accessibility", application: application)
            }
            let application = try context.requireAuthority()
            guard let application, let pid = application.processID else {
                throw TaskControlError.leaseRequired
            }
            switch try recoveryRoute(context) {
            case .some("accessibility"):
                guard let selector = action.selector, selector.addressability == .accessibility else {
                    throw TaskActionExecutionError.unsupported("accessibility_route_requires_accessibility_selector")
                }
                _ = try context.revalidateBeforeAction(includeTarget: true)
                do {
                    _ = try accessibilityController.setValue(pid: pid, selector: selector, value: text)
                    return report(route: "accessibility", application: application)
                } catch AccessibilityControllerError.ambiguousMatch {
                    throw TaskActionExecutionError.blocked("ambiguous_target")
                } catch AccessibilityControllerError.elementNotFound {
                    throw TaskActionExecutionError.blocked("target_unavailable")
                } catch AccessibilityControllerError.permissionDenied {
                    throw TaskActionExecutionError.permissionMissing("Accessibility")
                }
            case .none, .some("keyboard"):
                break
            default:
                throw TaskActionExecutionError.unsupported("unsupported_type_recovery_route")
            }
            _ = try context.revalidateBeforeAction(includeTarget: true)
            try inputController.type(text)
            return report(route: "keyboard", application: application)
        case .search:
            return try executeSearch(action, context: context)
        case .command:
            throw TaskActionExecutionError.unsupported("shortcut commands execute through the digest-bound shortcut service")
        case .key:
            try requireRecoveryRoute(context, allowed: ["keyboard"])
            let key = try requiredParameter(action, key: "key")
            if context.focusPolicy == .background {
                guard context.authority?.inputChannel?.permits(.processDirected) == true else {
                    throw TaskActionExecutionError.unsupported("background_key_requires_task_process_channel")
                }
                guard let application = try context.requireAuthority(), let pid = application.processID else {
                    throw TaskControlError.leaseRequired
                }
                _ = try context.revalidateBeforeAction(includeTarget: true)
                try backgroundSendKey(key, pid)
                _ = try context.revalidateBeforeAction(includeTarget: true)
                return report(route: "task_input_process", application: application)
            }
            guard let authority = context.authority else { throw TaskControlError.leaseRequired }
            guard let application = try context.requireAuthority(), let leaseToken = authority.leaseToken else {
                throw TaskControlError.leaseRequired
            }
            _ = leaseToken
            let result = try keyboardAccessController.sendRaw(
                keys: [key],
                targetApplication: application,
                leaseExpiresAt: authority.leaseExpiresAt ?? Date().addingTimeInterval(1),
                interKeyDelay: action.parameters["inter_key_ms"]?.doubleValue ?? 0,
                beforeEach: { [context] _ in
                    _ = try context.revalidateBeforeAction(includeTarget: true)
                }
            )
            return TaskActionExecutionReport(
                route: "keyboard",
                targetFingerprint: ControlTargetFingerprints.make(application: result.targetApplication, focus: nil)
            )
        case .scroll:
            let application = try context.requireAuthority()
            let direction = try requiredParameter(action, key: "direction")
            let amount = action.parameters["amount"]?.intValue ?? 3
            if context.focusPolicy == .background {
                try requireRecoveryRoute(context, allowed: ["accessibility"])
                guard let application,
                      let pid = application.processID,
                      let selector = action.selector,
                      selector.addressability == .accessibility,
                      let semanticDirection = AccessibilityScrollDirection(rawValue: direction),
                      context.authority?.inputChannel?.permits(.accessibility) == true else {
                    throw TaskActionExecutionError.unsupported("background_scroll_requires_task_accessibility_channel")
                }
                _ = try context.revalidateBeforeAction(includeTarget: true)
                let scroll: AccessibilityScrollReport
                do {
                    scroll = try backgroundScroll(pid, application, selector, semanticDirection, amount)
                } catch AccessibilityControllerError.ambiguousMatch {
                    throw TaskActionExecutionError.blocked("ambiguous_target")
                } catch AccessibilityControllerError.elementNotFound {
                    throw TaskActionExecutionError.blocked("target_unavailable")
                } catch AccessibilityControllerError.permissionDenied {
                    throw TaskActionExecutionError.permissionMissing("Accessibility")
                }
                guard scroll.verification == .passed else {
                    throw TaskActionExecutionError.uncertain("background_scroll_not_verified")
                }
                _ = try context.revalidateBeforeAction(includeTarget: true)
                return report(route: "task_input_accessibility_scroll", application: application)
            }
            try requireRecoveryRoute(context, allowed: ["input_scroll", "keyboard"])
            guard application != nil else { throw TaskControlError.leaseRequired }
            _ = try context.revalidateBeforeAction(includeTarget: true)
            let inputReport = try inputController.scroll(amount: Int32(amount), direction: direction)
            return report(route: inputReport.route, application: application)
        case .waitFor:
            try requireRecoveryRoute(context, allowed: ["native"])
            let seconds = min(max(action.parameters["seconds"]?.doubleValue ?? 0.2, 0), 30)
            guard context.now().addingTimeInterval(seconds) <= context.deadline else {
                throw TaskControlError.timedOut
            }
            // A daemon request executes on a worker thread whose RunLoop may
            // have no sources, so RunLoop.run(until:) can return immediately.
            // Use monotonic time and short slices so Stop & Release is observed
            // promptly even while a wait action is in progress.
            try CancellableMonotonicWait.run(
                seconds: seconds,
                monotonicNow: monotonicNow,
                sleep: sleep,
                checkpoint: {
                    _ = try context.revalidateBeforeAction(includeTarget: false)
                }
            )
            return TaskActionExecutionReport(route: "native")
        case .capture, .ocr:
            try requireRecoveryRoute(context, allowed: ["visual"])
            throw TaskActionExecutionError.unsupported("visual capture actions require a declared visual adapter route")
        case .assert:
            try requireRecoveryRoute(context, allowed: ["native"])
            return TaskActionExecutionReport(route: "native")
        case .adapter:
            return try executeAdapter(action, context: context)
        }
    }

    private func executeSearch(
        _ action: ActionSpec,
        context: TaskActionContext
    ) throws -> TaskActionExecutionReport {
        let parameters: SearchActionParameters
        do {
            parameters = try SearchActionContract.parameters(for: action)
        } catch {
            throw TaskActionExecutionError.blocked("search_contract_invalid")
        }
        guard let selector = action.selector else {
            throw TaskActionExecutionError.blocked("missing_search_selector")
        }
        guard let query = context.ephemeralInputs[parameters.inputKey] else {
            throw TaskActionExecutionError.blocked("missing_ephemeral_input")
        }
        if context.focusPolicy == .background {
            try requireRecoveryRoute(context, allowed: ["accessibility"])
            guard parameters.replaceExisting else {
                throw TaskActionExecutionError.unsupported("background_search_requires_replace_existing")
            }
            guard context.authority?.inputChannel?.permits(.accessibility) == true,
                  let application = try context.requireAuthority(),
                  let pid = application.processID else {
                throw TaskControlError.leaseRequired
            }
            _ = try context.revalidateBeforeAction(includeTarget: true)
            do {
                try searchFieldResolver.requireUniqueSearchField(pid: pid, selector: selector)
                try backgroundSetValue(pid, selector, query)
            } catch AccessibilityControllerError.ambiguousMatch {
                throw TaskActionExecutionError.blocked("ambiguous_search_field")
            } catch AccessibilityControllerError.elementNotFound {
                throw TaskActionExecutionError.blocked("search_field_unavailable")
            } catch AccessibilityControllerError.permissionDenied {
                throw TaskActionExecutionError.permissionMissing("Accessibility")
            }
            _ = try context.revalidateBeforeAction(includeTarget: true)
            return report(route: "task_input_accessibility_search", application: application)
        }
        try requireRecoveryRoute(context, allowed: ["keyboard"])
        guard let authority = context.authority,
              let leaseToken = authority.leaseToken else {
            throw TaskControlError.leaseRequired
        }
        guard let application = try context.requireAuthority(),
              let pid = application.processID else {
            throw TaskControlError.leaseRequired
        }
        _ = try context.revalidateBeforeAction(includeTarget: true)

        do {
            try searchFieldResolver.requireUniqueSearchField(pid: pid, selector: selector)
        } catch AccessibilityControllerError.ambiguousMatch {
            throw TaskActionExecutionError.blocked("ambiguous_search_field")
        } catch AccessibilityControllerError.elementNotFound {
            throw TaskActionExecutionError.blocked("search_field_unavailable")
        } catch AccessibilityControllerError.permissionDenied {
            throw TaskActionExecutionError.permissionMissing("Accessibility")
        }

        let focus = try readSearchFocus(application: application)
        if !SearchActionContract.matches(selector: selector, focus: focus) {
            let semantic: SemanticActionReport
            do {
                semantic = try semanticActionRouter.perform(
                    command: .search,
                    selector: nil,
                    leaseToken: leaseToken,
                    count: 1,
                    interKeyDelay: action.parameters["inter_key_ms"]?.doubleValue ?? 0,
                    allowRawCoordinate: false,
                    requestedRoute: .keyboard
                )
            } catch let error as TaskControlError {
                throw error
            } catch KeyboardControlError.permissionDenied(let permission) {
                throw TaskActionExecutionError.permissionMissing(permission)
            } catch KeyboardControlError.fullKeyboardAccessDisabled {
                throw TaskActionExecutionError.permissionMissing("Full Keyboard Access")
            } catch {
                throw TaskActionExecutionError.uncertain("search_shortcut_dispatch")
            }
            guard semantic.verification.state == .passed,
                  let verifiedFocus = semantic.verification.focusAfter,
                  SearchActionContract.matches(selector: selector, focus: verifiedFocus) else {
                throw TaskActionExecutionError.uncertain("search_focus_not_verified")
            }
        }

        _ = try context.revalidateBeforeAction(includeTarget: true)
        let focusedBeforeTyping: FocusedElementSnapshot
        do {
            try searchFieldResolver.requireUniqueSearchField(pid: pid, selector: selector)
            focusedBeforeTyping = try readSearchFocus(application: application)
        } catch is TaskActionExecutionError {
            throw TaskActionExecutionError.uncertain("search_focus_not_verified")
        } catch {
            throw TaskActionExecutionError.uncertain("search_target_revalidation")
        }
        guard SearchActionContract.matches(selector: selector, focus: focusedBeforeTyping) else {
            throw TaskActionExecutionError.uncertain("search_focus_not_verified")
        }

        if parameters.replaceExisting {
            do {
                _ = try keyboardAccessController.sendRaw(
                    keys: ["cmd+a", "delete"],
                    targetApplication: application,
                    leaseExpiresAt: authority.leaseExpiresAt ?? context.deadline,
                    interKeyDelay: action.parameters["inter_key_ms"]?.doubleValue ?? 0,
                    beforeEach: { [context, application] _ in
                        _ = try context.revalidateBeforeAction(includeTarget: true)
                        let currentFocus = try self.readSearchFocus(application: application)
                        guard SearchActionContract.matches(selector: selector, focus: currentFocus) else {
                            throw TaskActionExecutionError.uncertain("search_focus_changed_before_clear")
                        }
                    }
                )
            } catch let error as TaskControlError {
                throw error
            } catch let error as TaskActionExecutionError {
                throw error
            } catch {
                throw TaskActionExecutionError.uncertain("search_clear_not_verified")
            }
        }

        _ = try context.revalidateBeforeAction(includeTarget: true)
        let currentFocus = try readSearchFocus(application: application)
        guard SearchActionContract.matches(selector: selector, focus: currentFocus) else {
            throw TaskActionExecutionError.uncertain("search_focus_changed_before_type")
        }
        do {
            try searchTextTyper.type(query)
        } catch {
            throw TaskActionExecutionError.uncertain("search_query_dispatch")
        }
        _ = try context.revalidateBeforeAction(includeTarget: true)
        let finalFocus: FocusedElementSnapshot
        do {
            finalFocus = try readSearchFocus(application: application)
        } catch {
            throw TaskActionExecutionError.uncertain("search_focus_not_verified_after_type")
        }
        guard SearchActionContract.matches(selector: selector, focus: finalFocus) else {
            throw TaskActionExecutionError.uncertain("search_focus_not_verified_after_type")
        }
        return report(route: "keyboard", application: application)
    }

    private func readSearchFocus(application: AppInfo) throws -> FocusedElementSnapshot {
        guard let pid = application.processID else {
            throw TaskActionExecutionError.blocked("foreground_unavailable")
        }
        do {
            return try focusedElementInspector.focusedElementSnapshot(pid: pid, application: application)
        } catch AccessibilityControllerError.permissionDenied {
            throw TaskActionExecutionError.permissionMissing("Accessibility")
        } catch AccessibilityControllerError.unreadableFocus {
            throw TaskActionExecutionError.blocked("focus_unreadable")
        } catch {
            throw TaskActionExecutionError.blocked("focus_observation_failed")
        }
    }

    public func evaluate(
        predicate: TaskPredicate,
        context: TaskActionContext
    ) throws -> Bool {
        switch predicate.kind {
        case .foregroundApplication:
            guard let application = foregroundApplication() else { return false }
            return matchesApplication(
                application,
                name: predicate.application ?? predicate.expected,
                bundleID: predicate.bundleID
            )
        case .applicationRunning:
            guard let name = predicate.application ?? predicate.expected ?? predicate.bundleID else { return false }
            return (try? appController.resolve(name))?.isRunning == true
        case .focusedElement:
            guard let application = foregroundApplication(), let pid = application.processID else { return false }
            _ = try context.revalidateBeforeAction(includeTarget: true)
            let focus: FocusedElementSnapshot
            do {
                focus = try accessibilityController.focusedElementSnapshot(pid: pid, application: application)
            } catch let error as AccessibilityControllerError {
                throw mappedAccessibilityObservationError(error)
            }
            return selectorMatchesFocus(predicate.selector, focus: focus)
        case .elementExists:
            guard let selector = predicate.selector,
                  let application = try targetApplication(predicate: predicate, context: context),
                  let pid = application.processID else { return false }
            _ = try context.revalidateBeforeAction(includeTarget: true)
            do {
                _ = try accessibilityController.findElement(pid: pid, selector: selector)
                return true
            } catch AccessibilityControllerError.elementNotFound {
                return false
            } catch AccessibilityControllerError.ambiguousMatch {
                throw TaskActionExecutionError.blocked("ambiguous_target")
            } catch let error as AccessibilityControllerError {
                throw mappedAccessibilityObservationError(error)
            }
        case .windowVisible:
            guard let application = try targetApplication(predicate: predicate, context: context),
                  let pid = application.processID else { return false }
            _ = try context.revalidateBeforeAction(includeTarget: true)
            do {
                return try accessibilityController.windowState(pid: pid).visible
            } catch let error as AccessibilityControllerError {
                throw mappedAccessibilityObservationError(error)
            }
        case .modalAbsent:
            guard let application = try targetApplication(predicate: predicate, context: context),
                  let pid = application.processID else { return false }
            _ = try context.revalidateBeforeAction(includeTarget: true)
            do {
                return !(try accessibilityController.windowState(pid: pid).modal)
            } catch let error as AccessibilityControllerError {
                throw mappedAccessibilityObservationError(error)
            }
        case .focusReadable:
            guard let application = try targetApplication(predicate: predicate, context: context),
                  let pid = application.processID else { return false }
            _ = try context.revalidateBeforeAction(includeTarget: true)
            do {
                _ = try accessibilityController.focusedElementSnapshot(pid: pid, application: application)
            } catch let error as AccessibilityControllerError {
                throw mappedAccessibilityObservationError(error)
            }
            return true
        case .adapterState:
            guard let adapterID = predicate.parameters["adapter_id"]?.stringValue,
                  let expected = predicate.parameters["state"]?.stringValue else { return false }
            guard adapterRegistry.manifest(adapterID: adapterID) != nil else {
                throw AppAdapterError.unsupportedAdapter(adapterID)
            }
            if expected == "focus_session_verified",
               let rawOperation = predicate.parameters["focus_session_effect"]?.stringValue,
               let operation = FocusSessionExecutionOperation(rawValue: rawOperation) {
                _ = try context.revalidateBeforeAction(includeTarget: true)
                return try focusSessionExecutor.verify(operation)
            }
            if expected == "supported" { return true }
            guard let application = foregroundApplication() else { return false }
            return adapterRegistry.adapterID(for: application) == adapterID
        case .menuItemState:
            throw TaskActionExecutionError.unsupported("menu_item_state is evaluated by the shortcut service")
        }
    }

    private func executeAdapter(
        _ action: ActionSpec,
        context: TaskActionContext
    ) throws -> TaskActionExecutionReport {
        guard let adapterID = action.parameters["adapter_id"]?.stringValue,
              let operationName = action.parameters["operation"]?.stringValue else {
            throw AppAdapterError.unsupportedOperation(adapterID: "unknown", operation: "unknown")
        }
        if action.parameters["script"] != nil || action.parameters["jxa"] != nil {
            throw AppAdapterError.arbitraryScriptRejected
        }
        let operation = try adapterRegistry.operation(adapterID: adapterID, name: operationName)
        if context.focusPolicy == .background, operation.focusSupport != .backgroundSafe {
            throw TaskActionExecutionError.unsupported("adapter_operation_requires_foreground")
        }
        let requestedRoute = try adapterRecoveryRoute(context, operation: operation)
        guard let manifest = adapterRegistry.manifest(adapterID: adapterID) else {
            throw AppAdapterError.unsupportedAdapter(adapterID)
        }
        let applicationName = action.parameters["app"]?.stringValue
            ?? context.target?.application
            ?? manifest.displayName
        let application = try appController.resolve(applicationName)
        guard let bundleID = application.bundleID,
              manifest.supportedBundleIdentifiers.contains(bundleID) else {
            throw AppAdapterError.targetUnavailable(application.name)
        }
        if let missingPermission = adapterRegistry.missingPermission(for: operation) {
            throw AppAdapterError.permissionMissing(missingPermission)
        }
        if operation.mutating {
            _ = try context.requireAuthority()
        }
        switch operationName {
        case FocusSessionExecutionOperation.openBrief.rawValue,
             FocusSessionExecutionOperation.openScratchpad.rawValue,
             FocusSessionExecutionOperation.arrangeWorkspace.rawValue:
            guard let focusOperation = FocusSessionExecutionOperation(rawValue: operationName) else {
                throw AppAdapterError.unsupportedOperation(adapterID: adapterID, operation: operationName)
            }
            guard requestedRoute == nil || requestedRoute == focusOperation.expectedRoute else {
                throw TaskActionExecutionError.unsupported("adapter_route_not_implemented")
            }
            _ = try context.revalidateBeforeAction(includeTarget: true)
            let result = try focusSessionExecutor.execute(focusOperation)
            return AppAdapterActionResult(
                adapterID: adapterID,
                operation: operationName,
                route: result.route,
                mutating: operation.mutating,
                targetFingerprint: ControlTargetFingerprints.make(application: application, focus: nil),
                observation: AppAdapterObservation(
                    adapterID: adapterID,
                    operation: operationName,
                    application: application.name,
                    state: "applied",
                    fields: [
                        "opened": .bool(focusOperation != .arrangeWorkspace),
                        "layout_applied": .bool(focusOperation == .arrangeWorkspace)
                    ]
                )
            ).asTaskReport()
        case "open":
            guard requestedRoute == nil || requestedRoute == .native else {
                throw TaskActionExecutionError.unsupported("adapter_route_not_implemented")
            }
            _ = try context.revalidateBeforeAction(includeTarget: true)
            let opened = try appController.open(application.name, focusPolicy: context.focusPolicy)
            return AppAdapterActionResult(
                adapterID: adapterID,
                operation: operationName,
                route: .native,
                mutating: operation.mutating,
                targetFingerprint: ControlTargetFingerprints.make(application: opened, focus: nil)
            ).asTaskReport()
        case "activate":
            guard requestedRoute == nil || requestedRoute == .native else {
                throw TaskActionExecutionError.unsupported("adapter_route_not_implemented")
            }
            _ = try context.revalidateBeforeAction(includeTarget: true)
            let activated = try appController.activate(application.name)
            return AppAdapterActionResult(
                adapterID: adapterID,
                operation: operationName,
                route: .native,
                mutating: operation.mutating,
                targetFingerprint: ControlTargetFingerprints.make(application: activated, focus: nil)
            ).asTaskReport()
        case "inspect.front-window":
            guard requestedRoute == nil || requestedRoute == .accessibility else {
                throw TaskActionExecutionError.unsupported("adapter_route_not_implemented")
            }
            guard let pid = application.processID else {
                throw AppAdapterError.targetUnavailable(application.name)
            }
            _ = try context.revalidateBeforeAction(includeTarget: true)
            let state: AccessibilityWindowState
            do {
                state = try accessibilityController.windowState(pid: pid)
            } catch AccessibilityControllerError.permissionDenied {
                throw AppAdapterError.permissionMissing("Accessibility")
            } catch AccessibilityControllerError.elementNotFound {
                throw AppAdapterError.targetUnavailable(application.name)
            }
            let observation = AppAdapterObservation(
                adapterID: adapterID,
                operation: operationName,
                application: application.name,
                state: state.visible ? "visible" : "hidden",
                fields: ["window_visible": .bool(state.visible)]
            )
            _ = try context.revalidateBeforeAction(includeTarget: true)
            return AppAdapterActionResult(
                adapterID: adapterID,
                operation: operationName,
                route: .accessibility,
                mutating: false,
                targetFingerprint: ControlTargetFingerprints.make(application: application, focus: nil),
                observation: observation
            ).asTaskReport()
        case "locate.named-object":
            guard requestedRoute == nil || requestedRoute == .accessibility else {
                throw TaskActionExecutionError.unsupported("adapter_route_not_implemented")
            }
            guard let pid = application.processID,
                  let selectorValue = action.parameters["selector"] else {
                throw AppAdapterError.targetUnavailable(application.name)
            }
            let selector = try decodeSelector(selectorValue)
            _ = try context.revalidateBeforeAction(includeTarget: true)
            do {
                _ = try accessibilityController.findElement(pid: pid, selector: selector)
            } catch AccessibilityControllerError.ambiguousMatch {
                throw AppAdapterError.ambiguousTarget
            } catch AccessibilityControllerError.permissionDenied {
                throw AppAdapterError.permissionMissing("Accessibility")
            } catch AccessibilityControllerError.elementNotFound {
                throw AppAdapterError.targetUnavailable(application.name)
            }
            let observation = AppAdapterObservation(
                adapterID: adapterID,
                operation: operationName,
                application: application.name,
                state: "matched",
                fields: ["matched": .bool(true)]
            )
            _ = try context.revalidateBeforeAction(includeTarget: true)
            return AppAdapterActionResult(
                adapterID: adapterID,
                operation: operationName,
                route: .accessibility,
                mutating: false,
                targetFingerprint: ControlTargetFingerprints.make(application: application, focus: nil),
                observation: observation
            ).asTaskReport()
        case "document.save", "draft.create":
            guard requestedRoute == nil || requestedRoute == .appleScript else {
                throw TaskActionExecutionError.unsupported("adapter_route_not_implemented")
            }
            return try executeTypedAppleScript(
                adapterID: adapterID,
                operation: operation,
                operationName: operationName,
                bundleID: bundleID,
                application: application,
                action: action,
                context: context
            )
        default:
            throw AppAdapterError.unsupportedOperation(adapterID: adapterID, operation: operationName)
        }
    }

    private func executeTypedAppleScript(
        adapterID: String,
        operation: AppAdapterOperation,
        operationName: String,
        bundleID: String,
        application: AppInfo,
        action: ActionSpec,
        context: TaskActionContext
    ) throws -> TaskActionExecutionReport {
        let source: String
        switch operationName {
        case "document.save":
            guard ["textedit", "preview"].contains(adapterID) else {
                throw AppAdapterError.unsupportedOperation(adapterID: adapterID, operation: operationName)
            }
            source = """
            tell application id "\(appleScriptString(bundleID))"
                save front document
            end tell
            """
        case "draft.create":
            guard let bodyKey = action.parameters["body_key"]?.stringValue,
                  let body = context.ephemeralInputs[bodyKey] else {
                throw TaskActionExecutionError.blocked("missing_ephemeral_body")
            }
            let subject = ephemeralValue(
                action: action,
                context: context,
                keys: ["subject_key", "title_key"]
            ) ?? ""
            let scriptSubject = appleScriptString(subject)
            let scriptBody = appleScriptString(body)
            switch adapterID {
            case "mail":
                source = """
                tell application id "\(appleScriptString(bundleID))"
                    make new outgoing message with properties {subject:"\(scriptSubject)", content:"\(scriptBody)"}
                end tell
                """
            case "messages":
                source = """
                tell application id "\(appleScriptString(bundleID))"
                    make new outgoing message with properties {content:"\(scriptBody)"}
                end tell
                """
            case "notes":
                source = """
                tell application id "\(appleScriptString(bundleID))"
                    make new note with properties {name:"\(scriptSubject)", body:"\(scriptBody)"}
                end tell
                """
            default:
                throw AppAdapterError.unsupportedOperation(adapterID: adapterID, operation: operationName)
            }
        default:
            throw AppAdapterError.unsupportedOperation(adapterID: adapterID, operation: operationName)
        }
        _ = try context.revalidateBeforeAction(includeTarget: true)
        do {
            try typedAppleScriptExecutor.execute(source: source)
        } catch let error as AppAdapterError {
            throw error
        } catch {
            throw AppAdapterError.operationFailed("typed_apple_script_failed")
        }
        return AppAdapterActionResult(
            adapterID: adapterID,
            operation: operationName,
            route: .appleScript,
            mutating: operation.mutating,
            targetFingerprint: ControlTargetFingerprints.make(application: application, focus: nil)
        ).asTaskReport()
    }

    private func ephemeralValue(
        action: ActionSpec,
        context: TaskActionContext,
        keys: [String]
    ) -> String? {
        for key in keys {
            if let inputKey = action.parameters[key]?.stringValue,
               let value = context.ephemeralInputs[inputKey] {
                return value
            }
        }
        return nil
    }

    private func recoveryRoute(_ context: TaskActionContext) throws -> String? {
        guard let route = context.recoveryRoute else { return nil }
        guard ["native", "accessibility", "keyboard", "input_scroll", "visual", "apple_script"].contains(route) else {
            throw TaskActionExecutionError.unsupported("unsupported_recovery_route")
        }
        return route
    }

    private func requireRecoveryRoute(
        _ context: TaskActionContext,
        allowed: [String]
    ) throws {
        guard let route = try recoveryRoute(context) else { return }
        guard allowed.contains(route) else {
            throw TaskActionExecutionError.unsupported("recovery_route_not_supported_for_action")
        }
    }

    private func adapterRecoveryRoute(
        _ context: TaskActionContext,
        operation: AppAdapterOperation
    ) throws -> AppAdapterRoute? {
        guard let route = try recoveryRoute(context) else { return nil }
        guard let adapterRoute = AppAdapterRoute(rawValue: route), operation.routes.contains(adapterRoute) else {
            throw TaskActionExecutionError.unsupported("adapter_recovery_route_not_declared")
        }
        return adapterRoute
    }

    private func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func targetApplication(
        predicate: TaskPredicate,
        context: TaskActionContext
    ) throws -> AppInfo? {
        let name = predicate.application
            ?? predicate.expected
            ?? context.target?.application
        if let name { return try appController.resolve(name) }
        return foregroundApplication()
    }

    private func requiredParameter(_ action: ActionSpec, key: String) throws -> String {
        guard let value = action.parameters[key]?.stringValue,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskActionExecutionError.blocked("missing_\(key)")
        }
        return value
    }

    private func report(route: String, application: AppInfo? = nil) -> TaskActionExecutionReport {
        TaskActionExecutionReport(
            route: route,
            targetFingerprint: application.map { ControlTargetFingerprints.make(application: $0, focus: nil) }
        )
    }

    private func matchesApplication(_ application: AppInfo, name: String?, bundleID: String?) -> Bool {
        if let bundleID { return application.bundleID == bundleID }
        guard let name else { return false }
        return application.name.caseInsensitiveCompare(name) == .orderedSame
            || application.bundleID == name
    }

    private func selectorMatchesFocus(_ selector: Selector?, focus: FocusedElementSnapshot) -> Bool {
        guard let selector else { return true }
        if let role = selector.role, role != focus.role { return false }
        if let subrole = selector.subrole, subrole != focus.subrole { return false }
        if let identifier = selector.identifier, identifier != focus.identifier { return false }
        if let title = selector.title, title != focus.title { return false }
        if let containsText = selector.containsText {
            return focus.title?.localizedCaseInsensitiveContains(containsText) == true
        }
        return selector.hasTarget
    }

    private func mappedAccessibilityObservationError(
        _ error: AccessibilityControllerError
    ) -> TaskActionExecutionError {
        switch error {
        case .permissionDenied:
            return .permissionMissing("Accessibility")
        case .applicationNotRunning:
            return .blocked("application_not_running")
        case .ambiguousMatch, .ambiguousWindowMatch:
            return .blocked("ambiguous_target")
        case .resolutionIncomplete:
            return .blocked("target_resolution_incomplete")
        case .elementNotFound, .windowNotFound, .unreadableFocus:
            return .blocked("focus_unreadable")
        case .actionUnavailable, .semanticActivationUnavailable, .actionFailed, .boundsUnavailable, .scrollTargetRequired, .scrollUnavailable:
            return .blocked("accessibility_observation_failed")
        }
    }

    private func decodeSelector(_ value: JSONValue) throws -> Selector {
        guard let data = try? JSONCodec.encode(value) else {
            throw TaskActionExecutionError.blocked("invalid_selector")
        }
        do { return try JSONCodec.decode(Selector.self, from: data) }
        catch { throw TaskActionExecutionError.blocked("invalid_selector") }
    }
}

private extension AppAdapterActionResult {
    func asTaskReport() -> TaskActionExecutionReport {
        TaskActionExecutionReport(
            route: route.rawValue,
            adapterID: adapterID,
            targetFingerprint: targetFingerprint
        )
    }
}
