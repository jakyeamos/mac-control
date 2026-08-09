import Foundation
import XCTest
@testable import MacCtlCore

final class ControlCenterTests: XCTestCase {
    func testPresentationCoversIdleApprovalLeaseFreezeStoppingAndDegradedStates() {
        let now = Date(timeIntervalSince1970: 10_000)
        let granted = permission("Accessibility", "granted")
        let approval = ControlCenterApproval(record: approvalRecord(expiresAt: now.addingTimeInterval(240)))

        XCTAssertEqual(
            ControlCenterPresentation.make(
                snapshot: ControlCenterSnapshot(approvals: [], execution: nil, permissions: [granted]),
                now: now
            ).state,
            .idle
        )

        let approvalPresentation = ControlCenterPresentation.make(
            snapshot: ControlCenterSnapshot(
                approvals: [approval, approval],
                execution: nil,
                permissions: [granted]
            ),
            now: now
        )
        XCTAssertEqual(approvalPresentation.state, .approval)
        XCTAssertEqual(approvalPresentation.pendingCount, 2)
        XCTAssertEqual(approvalPresentation.ringFraction ?? 0, 0.8, accuracy: 0.001)

        for (mode, stopping, expected) in [
            (KeyboardPhysicalInputMode.shared, false, ControlCenterVisualState.leased),
            (.suppressed, false, .frozen),
            (.suppressed, true, .stopping)
        ] {
            let execution = ControlCenterExecution(
                executionID: "execution",
                taskID: "task",
                summary: "Safe test",
                applicationName: "Calculator",
                physicalInputMode: mode,
                acquiredAt: now,
                expiresAt: now.addingTimeInterval(100),
                stopping: stopping
            )
            let presentation = ControlCenterPresentation.make(
                snapshot: ControlCenterSnapshot(
                    approvals: [approval],
                    execution: execution,
                    permissions: [granted]
                ),
                now: now.addingTimeInterval(25)
            )
            XCTAssertEqual(presentation.state, expected)
            XCTAssertEqual(presentation.pendingCount, 1)
            XCTAssertEqual(presentation.ringFraction ?? 0, 0.75, accuracy: 0.001)
            XCTAssertFalse(presentation.tooltip.contains("mca_"))
            XCTAssertFalse(presentation.accessibilityLabel.contains("mca_"))
        }

        XCTAssertEqual(
            ControlCenterPresentation.make(
                snapshot: ControlCenterSnapshot(
                    approvals: [],
                    execution: nil,
                    permissions: [permission("Accessibility", "missing")]
                ),
                now: now
            ).state,
            .degraded
        )
    }

    func testHandoffTargetUsesFirstDeclaredForegroundInputTargetOnly() {
        let first = TaskStep(
            id: "capture",
            action: ActionSpec(kind: .capture, surface: .macApp),
            target: TaskTargetIdentity(application: "Preview")
        )
        let calculator = TaskStep(
            id: "type",
            action: ActionSpec(kind: .type, surface: .macApp),
            target: TaskTargetIdentity(application: "Calculator", bundleID: "com.apple.calculator")
        )
        let notes = TaskStep(
            id: "click",
            action: ActionSpec(kind: .click, surface: .macApp),
            target: TaskTargetIdentity(application: "Notes")
        )
        let foreground = TaskPlan(
            id: "handoff",
            name: "Handoff",
            summary: "Handoff test",
            steps: [first, calculator, notes]
        )
        XCTAssertEqual(
            ApprovalHandoffTargetResolver.resolve(for: foreground),
            ApprovalHandoffTarget(applicationName: "Calculator", bundleID: "com.apple.calculator")
        )

        let background = TaskPlan(
            id: "background",
            name: "Background",
            summary: "Background test",
            focusPolicy: .background,
            steps: [calculator]
        )
        XCTAssertNil(ApprovalHandoffTargetResolver.resolve(for: background))

        let targetless = TaskPlan(
            id: "targetless",
            name: "Targetless",
            summary: "Targetless test",
            steps: [TaskStep(id: "wait", action: ActionSpec(kind: .waitFor, surface: .macApp))]
        )
        XCTAssertNil(ApprovalHandoffTargetResolver.resolve(for: targetless))
    }

    func testApprovalStoresUseFiveMinuteLifetimeAndPreserveExactDigest() throws {
        let workflow = WorkflowSpec(
            id: "workflow",
            name: "Workflow",
            summary: "Type in Calculator",
            surface: .macApp,
            actions: [ActionSpec(
                kind: .type,
                surface: .macApp,
                parameters: ["app": .string("Calculator"), "text_key": .string("value")]
            )]
        )
        let workflowStore = ApprovalStore()
        let preparedWorkflow = workflowStore.prepare(
            workflow: workflow,
            ephemeralInputs: ["value": "1"]
        )
        XCTAssertGreaterThan(preparedWorkflow.record.expiresAt.timeIntervalSinceNow, 299)
        XCTAssertEqual(preparedWorkflow.record.handoffTarget?.applicationName, "Calculator")
        _ = try workflowStore.approve(token: preparedWorkflow.record.token)
        XCTAssertThrowsError(try workflowStore.validateApproved(
            token: preparedWorkflow.record.token,
            workflow: workflow,
            ephemeralInputs: ["value": "2"]
        )) { XCTAssertEqual($0 as? ApprovalStoreError, .mismatch) }
        _ = try workflowStore.consume(
            token: preparedWorkflow.record.token,
            workflow: workflow,
            ephemeralInputs: ["value": "1"]
        )
        XCTAssertThrowsError(try workflowStore.consume(
            token: preparedWorkflow.record.token,
            workflow: workflow,
            ephemeralInputs: ["value": "1"]
        )) { XCTAssertEqual($0 as? ApprovalStoreError, .alreadyUsed) }

        let plan = TaskPlan(
            id: "task",
            name: "Task",
            summary: "Click Calculator",
            steps: [TaskStep(
                id: "click",
                action: ActionSpec(kind: .click, surface: .macApp),
                target: TaskTargetIdentity(application: "Calculator")
            )]
        )
        let taskStore = TaskApprovalStore()
        let preparedTask = taskStore.prepare(plan: plan)
        XCTAssertGreaterThan(preparedTask.record.expiresAt.timeIntervalSinceNow, 299)
        XCTAssertEqual(preparedTask.record.handoffTarget?.applicationName, "Calculator")
        _ = try taskStore.approve(token: preparedTask.record.token)
        _ = try taskStore.validateApproved(token: preparedTask.record.token, plan: plan, ephemeralInputs: [:])
    }

    func testApproveAndFocusCommitsOnlyAfterStableDeclaredTargetActivation() throws {
        let app = AppInfo(
            name: "Calculator",
            bundleID: "com.apple.calculator",
            path: "/System/Applications/Calculator.app",
            isRunning: true,
            processID: 42
        )
        let store = TaskApprovalStore()
        let plan = TaskPlan(
            id: "focus-task",
            name: "Focus task",
            summary: "Focus Calculator",
            steps: [TaskStep(
                id: "click",
                action: ActionSpec(kind: .click, surface: .macApp),
                target: TaskTargetIdentity(
                    application: "Calculator",
                    bundleID: "com.apple.calculator"
                )
            )]
        )
        let prepared = store.prepare(plan: plan)
        var activatedName: String?
        var foreground: AppInfo?
        let service = MacCtlService(
            permissionContext: "test",
            taskApprovalStore: store,
            foregroundApplication: { foreground },
            resolveApplication: { _ in app },
            activateApplication: { name in
                activatedName = name
                foreground = app
                return app
            },
            foregroundStabilityVerifier: ControlStateVerifier(sleep: { _ in })
        )
        let response = service.handle(RequestEnvelope(
            method: "approval.approve",
            params: [
                "token": .string(prepared.record.token),
                "source": .string("control_center")
            ]
        ))
        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(activatedName, "com.apple.calculator")
        XCTAssertFalse(service.isApprovalPending(token: prepared.record.token))
        _ = try store.validateApproved(token: prepared.record.token, plan: plan, ephemeralInputs: [:])
    }

    func testFailedFocusPreservesApprovalAndBackgroundApprovalDoesNotActivate() {
        let foregroundPlan = TaskPlan(
            id: "failed-focus",
            name: "Failed focus",
            summary: "Focus Calculator",
            steps: [TaskStep(
                id: "click",
                action: ActionSpec(kind: .click, surface: .macApp),
                target: TaskTargetIdentity(application: "Calculator")
            )]
        )
        let foregroundStore = TaskApprovalStore()
        let foregroundApproval = foregroundStore.prepare(plan: foregroundPlan)
        let app = AppInfo(
            name: "Calculator",
            bundleID: "com.apple.calculator",
            path: "/System/Applications/Calculator.app",
            isRunning: true,
            processID: 42
        )
        var clock = Date(timeIntervalSince1970: 1_000)
        let failedService = MacCtlService(
            permissionContext: "test",
            taskApprovalStore: foregroundStore,
            foregroundApplication: { nil },
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            foregroundStabilityVerifier: ControlStateVerifier(
                now: { defer { clock = clock.addingTimeInterval(3) }; return clock },
                sleep: { _ in }
            )
        )
        let failed = failedService.handle(RequestEnvelope(
            method: "approval.approve",
            params: [
                "token": .string(foregroundApproval.record.token),
                "source": .string("control_center")
            ]
        ))
        XCTAssertEqual(failed.status, .blocked)
        XCTAssertTrue(failedService.isApprovalPending(token: foregroundApproval.record.token))

        let backgroundStore = TaskApprovalStore()
        let backgroundPlan = TaskPlan(
            id: "background",
            name: "Background",
            summary: "Background task",
            focusPolicy: .background,
            steps: [TaskStep(
                id: "click",
                action: ActionSpec(kind: .click, surface: .macApp),
                target: TaskTargetIdentity(application: "Calculator")
            )]
        )
        let backgroundApproval = backgroundStore.prepare(plan: backgroundPlan)
        var activationCount = 0
        let backgroundService = MacCtlService(
            permissionContext: "test",
            taskApprovalStore: backgroundStore,
            activateApplication: { _ in activationCount += 1; return app }
        )
        let approved = backgroundService.handle(RequestEnvelope(
            method: "approval.approve",
            params: [
                "token": .string(backgroundApproval.record.token),
                "source": .string("control_center")
            ]
        ))
        XCTAssertEqual(approved.status, .succeeded)
        XCTAssertEqual(activationCount, 0)
    }

    func testForegroundTasksAutomaticallyAcquireExactSharedOrFrozenLeaseAndCleanUp() throws {
        for freezeRequired in [false, true] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("macctl-control-center-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let approvals = TaskApprovalStore()
            let suppressor = RecordingSuppressor()
            let leases = KeyboardDriveStore(physicalKeyboardSuppressor: suppressor)
            let app = calculatorApp()
            let executor = RecordingTaskExecutor()
            executor.onExecute = {
                XCTAssertEqual(
                    leases.activeLease()?.physicalInputMode,
                    freezeRequired ? .suppressed : .shared
                )
                XCTAssertEqual(suppressor.active, freezeRequired)
            }
            let runner = TaskRunner(
                checkpointStore: TaskCheckpointStore(directory: directory),
                approvalStore: approvals,
                actionExecutor: executor,
                targetRevalidator: { _ in nil }
            )
            let plan = TaskPlan(
                id: "automatic-lease-\(freezeRequired)",
                name: "Automatic lease",
                summary: "Automatic lease test",
                keyboardFreezeRequired: freezeRequired,
                steps: [TaskStep(
                    id: "assert",
                    action: ActionSpec(kind: .assert, surface: .macApp),
                    target: TaskTargetIdentity(application: "Calculator")
                )],
                totalTimeout: 30
            )
            let prepared = try runner.prepare(plan: plan)
            _ = try approvals.approve(token: prepared.approval.token)
            let service = MacCtlService(
                permissionContext: "test",
                keyboardDriveStore: leases,
                taskApprovalStore: approvals,
                taskRunner: runner,
                focusedElementInspector: EmptyFocusInspector(),
                foregroundApplication: { app },
                resolveApplication: { _ in app },
                activateApplication: { _ in app },
                foregroundStabilityVerifier: ControlStateVerifier(sleep: { _ in }),
                hasPostEventAccess: { true }
            )
            let response = service.handle(RequestEnvelope(
                method: "task.run",
                params: [
                    "plan": try JSONValue.fromEncodable(plan),
                    "approval_token": .string(prepared.approval.token)
                ]
            ))
            XCTAssertEqual(response.status, .succeeded)
            XCTAssertNil(leases.activeLease())
            XCTAssertNil(service.controlCenterSnapshot().execution)
            XCTAssertFalse(suppressor.active)
            if freezeRequired { XCTAssertEqual(suppressor.releaseCount, 1) }
        }
    }

    func testDigestMismatchAndWrongCallerLeaseCannotEscalateKeyboardMode() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-control-center-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let approvals = TaskApprovalStore()
        let suppressor = RecordingSuppressor()
        let leases = KeyboardDriveStore(physicalKeyboardSuppressor: suppressor)
        let runner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: directory),
            approvalStore: approvals,
            actionExecutor: RecordingTaskExecutor(),
            targetRevalidator: { _ in nil }
        )
        let approvedPlan = frozenPlan(id: "exact-plan", summary: "Approved summary")
        let prepared = try runner.prepare(plan: approvedPlan)
        _ = try approvals.approve(token: prepared.approval.token)
        let sharedLease = try leases.acquire(
            scope: .session,
            application: nil,
            seconds: 30,
            confirm: true,
            physicalInputMode: .shared
        )
        let app = calculatorApp()
        let service = MacCtlService(
            permissionContext: "test",
            keyboardDriveStore: leases,
            taskApprovalStore: approvals,
            taskRunner: runner,
            focusedElementInspector: EmptyFocusInspector(),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            foregroundStabilityVerifier: ControlStateVerifier(sleep: { _ in }),
            hasPostEventAccess: { true }
        )
        let mismatched = frozenPlan(id: "exact-plan", summary: "Changed summary")
        let mismatchResponse = service.handle(RequestEnvelope(
            method: "task.run",
            params: [
                "plan": try JSONValue.fromEncodable(mismatched),
                "approval_token": .string(prepared.approval.token),
                "lease_token": .string(sharedLease.token)
            ]
        ))
        XCTAssertEqual(mismatchResponse.status, .blocked)
        XCTAssertFalse(suppressor.active)
        XCTAssertNotNil(try approvals.validateApproved(
            token: prepared.approval.token,
            plan: approvedPlan,
            ephemeralInputs: [:]
        ))

        let wrongModeResponse = service.handle(RequestEnvelope(
            method: "task.run",
            params: [
                "plan": try JSONValue.fromEncodable(approvedPlan),
                "approval_token": .string(prepared.approval.token),
                "lease_token": .string(sharedLease.token)
            ]
        ))
        XCTAssertEqual(wrongModeResponse.status, .blocked)
        XCTAssertFalse(suppressor.active)
        XCTAssertEqual(leases.activeLease()?.physicalInputMode, .shared)
        _ = leases.invalidate(token: sharedLease.token)
    }

    func testStopAndReleaseImmediatelyLiftsSuppressionAndCancelsNextCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macctl-control-center-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let approvals = TaskApprovalStore()
        let suppressor = RecordingSuppressor()
        let leases = KeyboardDriveStore(physicalKeyboardSuppressor: suppressor)
        let executor = BlockingRecordingTaskExecutor()
        let runner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: directory),
            approvalStore: approvals,
            actionExecutor: executor,
            targetRevalidator: { _ in nil }
        )
        let plan = TaskPlan(
            id: "emergency-stop",
            name: "Emergency stop",
            summary: "Emergency stop test",
            keyboardFreezeRequired: true,
            steps: [
                TaskStep(
                    id: "first",
                    action: ActionSpec(kind: .assert, surface: .macApp),
                    target: TaskTargetIdentity(application: "Calculator")
                ),
                TaskStep(
                    id: "second",
                    action: ActionSpec(kind: .assert, surface: .macApp),
                    target: TaskTargetIdentity(application: "Calculator")
                )
            ],
            totalTimeout: 30
        )
        let prepared = try runner.prepare(plan: plan)
        _ = try approvals.approve(token: prepared.approval.token)
        let app = calculatorApp()
        let service = MacCtlService(
            permissionContext: "test",
            keyboardDriveStore: leases,
            taskApprovalStore: approvals,
            taskRunner: runner,
            focusedElementInspector: EmptyFocusInspector(),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            foregroundStabilityVerifier: ControlStateVerifier(sleep: { _ in }),
            hasPostEventAccess: { true }
        )

        let finished = DispatchSemaphore(value: 0)
        let responseLock = NSLock()
        var runResponse: ResponseEnvelope?
        DispatchQueue.global().async {
            let response = service.handle(RequestEnvelope(
                method: "task.run",
                params: [
                    "plan": (try? JSONValue.fromEncodable(plan)) ?? .null,
                    "approval_token": .string(prepared.approval.token)
                ]
            ))
            responseLock.lock()
            runResponse = response
            responseLock.unlock()
            finished.signal()
        }

        XCTAssertEqual(executor.started.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(suppressor.active)
        XCTAssertEqual(service.controlCenterSnapshot().execution?.physicalInputMode, .suppressed)
        let stopped = service.handle(RequestEnvelope(method: "control.stop_active"))
        XCTAssertEqual(stopped.status, .succeeded)
        XCTAssertFalse(suppressor.active)
        XCTAssertNil(leases.activeLease())
        XCTAssertEqual(service.controlCenterSnapshot().execution?.stopping, true)

        executor.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        responseLock.lock()
        let completedResponse = runResponse
        responseLock.unlock()
        XCTAssertNotEqual(completedResponse?.status, .succeeded)
        XCTAssertNil(service.controlCenterSnapshot().execution)
        XCTAssertEqual(try runner.status(taskID: plan.id).state, .cancelled)

        let recoveryLease = try leases.acquire(
            scope: .session,
            application: nil,
            seconds: 1,
            confirm: true
        )
        XCTAssertTrue(leases.invalidate(token: recoveryLease.token))
        XCTAssertNil(leases.activeLease())
    }

    func testPreDispatchFailureLeavesApprovalRetryableUntilFirstActionDispatch() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-control-center-\(UUID().uuidString)")
        let approvals = TaskApprovalStore()
        let executor = RecordingTaskExecutor()
        executor.evaluationResult = false
        let runner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: directory),
            approvalStore: approvals,
            actionExecutor: executor,
            targetRevalidator: { _ in nil }
        )
        let plan = TaskPlan(
            id: "retryable-predispatch",
            name: "Retryable predispatch",
            summary: "Retry after a precondition blocker",
            steps: [TaskStep(
                id: "assert",
                action: ActionSpec(kind: .assert, surface: .macApp),
                preconditions: [TaskPredicate(kind: .applicationRunning, application: "Calculator")]
            )]
        )
        let prepared = try runner.prepare(plan: plan)
        _ = try approvals.approve(token: prepared.approval.token)

        XCTAssertThrowsError(try runner.run(plan: plan, approvalToken: prepared.approval.token))
        XCTAssertEqual(try runner.status(taskID: plan.id).state, .prepared)
        XCTAssertNotNil(try approvals.validateApproved(
            token: prepared.approval.token,
            plan: plan,
            ephemeralInputs: [:]
        ))
        XCTAssertEqual(executor.executeCount, 0)

        executor.evaluationResult = true
        XCTAssertEqual(
            try runner.run(plan: plan, approvalToken: prepared.approval.token).state,
            .completed
        )
        XCTAssertEqual(executor.executeCount, 1)
        try? FileManager.default.removeItem(at: directory)
    }

    private func approvalRecord(expiresAt: Date) -> ApprovalRecord {
        ApprovalRecord(
            token: "mca_secret",
            operationID: "operation",
            workflowID: "workflow",
            summary: "Approval summary",
            risk: .sensitive,
            expiresAt: expiresAt
        )
    }

    private func permission(_ name: String, _ state: String) -> PermissionStatus {
        PermissionStatus(name: name, state: state, requiredFor: "test", instruction: "test")
    }

    private func calculatorApp() -> AppInfo {
        AppInfo(
            name: "Calculator",
            bundleID: "com.apple.calculator",
            path: "/System/Applications/Calculator.app",
            isRunning: true,
            processID: 42
        )
    }

    private func frozenPlan(id: String, summary: String) -> TaskPlan {
        TaskPlan(
            id: id,
            name: "Frozen task",
            summary: summary,
            keyboardFreezeRequired: true,
            steps: [TaskStep(
                id: "assert",
                action: ActionSpec(kind: .assert, surface: .macApp),
                target: TaskTargetIdentity(application: "Calculator")
            )],
            totalTimeout: 30
        )
    }
}

private final class RecordingSuppressor: PhysicalKeyboardSuppressing {
    private(set) var active = false
    private(set) var releaseCount = 0

    func acquire(until: Date) throws { active = true }
    func release() {
        if active { releaseCount += 1 }
        active = false
    }
}

private final class EmptyFocusInspector: FocusedElementInspecting {
    func focusedElementSnapshot(pid: pid_t, application: AppInfo) throws -> FocusedElementSnapshot {
        throw AccessibilityControllerError.unreadableFocus
    }
}

private final class RecordingTaskExecutor: TaskActionExecuting {
    var onExecute: (() -> Void)?
    var evaluationResult = true
    private(set) var executeCount = 0

    func execute(action: ActionSpec, context: TaskActionContext) throws -> TaskActionExecutionReport {
        executeCount += 1
        onExecute?()
        return TaskActionExecutionReport(route: "test")
    }

    func evaluate(predicate: TaskPredicate, context: TaskActionContext) throws -> Bool {
        evaluationResult
    }
}

private final class BlockingRecordingTaskExecutor: TaskActionExecuting {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private var executeCount = 0
    private let lock = NSLock()

    func execute(action: ActionSpec, context: TaskActionContext) throws -> TaskActionExecutionReport {
        lock.lock()
        executeCount += 1
        let shouldBlock = executeCount == 1
        lock.unlock()
        if shouldBlock {
            started.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        return TaskActionExecutionReport(route: "test")
    }

    func evaluate(predicate: TaskPredicate, context: TaskActionContext) throws -> Bool { true }
}
