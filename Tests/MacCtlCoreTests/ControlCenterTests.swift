import Foundation
import AppKit
import XCTest
@testable import MacCtlCore

final class ControlCenterTests: XCTestCase {
    func testTaskProgressProjectionPreservesVerifiedStepsWhenCurrentStepStops() {
        let plan = TaskPlan(
            id: "focus-session",
            name: "Focus session",
            summary: "Prepare a focus session",
            steps: [
                TaskStep(id: "open-brief", action: ActionSpec(kind: .assert, surface: .macApp)),
                TaskStep(id: "open-scratchpad", action: ActionSpec(kind: .assert, surface: .macApp)),
                TaskStep(id: "arrange-workspace", action: ActionSpec(kind: .assert, surface: .macApp))
            ]
        )
        let status = TaskStatusReport(
            taskID: plan.id,
            planDigest: "digest",
            state: .blocked,
            stepIndex: 1,
            currentStepID: "open-scratchpad",
            lastStepID: "open-brief",
            attempts: 2,
            lastRoute: "accessibility",
            lastErrorCode: "task_postcondition_failed",
            checkpointUpdatedAt: Date()
        )

        let progress = ControlCenterTaskProgress.make(plan: plan, status: status)

        XCTAssertEqual(progress.completedStepCount, 1)
        XCTAssertEqual(progress.steps.map(\.state), [.verified, .stopped, .pending])
        XCTAssertEqual(progress.steps.map(\.label), ["Open Brief", "Open Scratchpad", "Arrange Workspace"])
        XCTAssertEqual(progress.lastErrorCode, "task_postcondition_failed")
    }

    func testTaskProgressProjectionShowsRunningAndImmediateStopStates() {
        let plan = TaskPlan(
            id: "focus-session",
            name: "Focus session",
            summary: "Prepare a focus session",
            steps: [
                TaskStep(id: "open-brief", action: ActionSpec(kind: .assert, surface: .macApp)),
                TaskStep(id: "arrange-windows", action: ActionSpec(kind: .assert, surface: .macApp))
            ]
        )
        let status = TaskStatusReport(
            taskID: plan.id,
            planDigest: "digest",
            state: .running,
            stepIndex: 0,
            currentStepID: "open-brief",
            attempts: 0,
            lastRoute: nil,
            lastErrorCode: nil,
            checkpointUpdatedAt: Date()
        )

        XCTAssertEqual(
            ControlCenterTaskProgress.make(plan: plan, status: status).steps.map(\.state),
            [.running, .pending]
        )
        XCTAssertEqual(
            ControlCenterTaskProgress.make(plan: plan, status: status, stopping: true).steps.map(\.state),
            [.stopped, .pending]
        )
    }

    func testControlCenterRendersTaskProgressWithoutPlanTargetsOrInputs() throws {
        let progress = ControlCenterTaskProgress(
            state: .blocked,
            completedStepCount: 1,
            totalStepCount: 3,
            currentStepID: "open-scratchpad",
            lastErrorCode: "task_postcondition_failed",
            steps: [
                ControlCenterTaskStepProgress(stepID: "open-brief", label: "Open Brief", state: .verified),
                ControlCenterTaskStepProgress(stepID: "open-scratchpad", label: "Open Scratchpad", state: .stopped),
                ControlCenterTaskStepProgress(stepID: "arrange-workspace", label: "Arrange Workspace", state: .pending)
            ]
        )
        let hud = ApprovalHUD(capsLockMonitor: CapsLockMonitor())
        hud.pendingApprovalsHandler = { [] }
        hud.snapshotHandler = {
            ControlCenterSnapshot(
                approvals: [],
                execution: ControlCenterExecution(
                    executionID: "execution",
                    taskID: "focus-session",
                    summary: "Prepare a focus session",
                    applicationName: "Preview",
                    physicalInputMode: .shared,
                    acquiredAt: Date(),
                    expiresAt: Date().addingTimeInterval(60),
                    taskProgress: progress
                ),
                permissions: []
            )
        }

        hud.refreshOnMain(populatePopover: true)
        guard let view = hud.popover.contentViewController?.view else {
            return XCTFail("Control Center popover content was not built")
        }
        let labels = allSubviews(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains("PROGRESS · 1 OF 3 VERIFIED"))
        XCTAssertTrue(labels.contains("✓ Open Brief · Verified"))
        XCTAssertTrue(labels.contains("■ Open Scratchpad · Stopped"))
        XCTAssertTrue(labels.contains("○ Arrange Workspace · Pending"))
        XCTAssertTrue(labels.contains("Stopped safely · task postcondition failed"))
        XCTAssertFalse(labels.joined().contains("private"))
        let captureURL = URL(fileURLWithPath: "/private/tmp/macctl-control-center-progress.png")
        try? FileManager.default.removeItem(at: captureURL)
        try renderPNG(view, to: captureURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureURL.path))
    }

    func testHiddenControlCenterBuildsPopoverContentBeforeFirstPresentation() {
        let now = Date()
        let approval = ApprovalRecord(
            token: "private-token",
            operationID: "approval-1",
            workflowID: "execution.smoke",
            summary: "Approval smoke",
            risk: .sensitive,
            focusPolicy: .foreground,
            keyboardFreezeRequired: false,
            handoffTarget: nil,
            expiresAt: now.addingTimeInterval(300)
        )
        let hud = ApprovalHUD(capsLockMonitor: CapsLockMonitor())
        hud.pendingApprovalsHandler = { [approval] }
        hud.snapshotHandler = {
            ControlCenterSnapshot(
                approvals: [ControlCenterApproval(record: approval)],
                execution: nil,
                permissions: []
            )
        }

        XCTAssertNil(hud.popover.contentViewController)
        hud.refreshOnMain(populatePopover: true)
        guard let view = hud.popover.contentViewController?.view else {
            return XCTFail("Control Center popover content was not built")
        }
        XCTAssertEqual(view.accessibilityIdentifier(), "macctl.approval.window")
        let buttons = allSubviews(of: view).compactMap { $0 as? NSButton }
        XCTAssertFalse(buttons.isEmpty)
        XCTAssertEqual(
            buttons.first(where: { $0.title == "Approve" })?.accessibilityIdentifier(),
            "macctl.approval.approve.approval-1"
        )
        for button in buttons {
            XCTAssertEqual(button.focusRingType, .none, "Unexpected focus ring on \(button.title)")
        }
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    private func renderPNG(_ view: NSView, to url: URL) throws {
        let fittingSize = view.fittingSize
        let size = NSSize(width: max(fittingSize.width, 392), height: fittingSize.height + 16)
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: fittingSize.height))
        view.layoutSubtreeIfNeeded()
        let canvas = NSView(frame: NSRect(origin: .zero, size: size))
        canvas.appearance = view.appearance
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.white.cgColor
        canvas.addSubview(view)
        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            throw NSError(domain: "ControlCenterTests", code: 1)
        }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ControlCenterTests", code: 2)
        }
        try data.write(to: url, options: .atomic)
    }

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

        let focusedExecution = ControlCenterExecution(
            executionID: "focused-execution",
            taskID: "focus-task",
            summary: "Focus test",
            applicationName: "Calculator",
            physicalInputMode: .shared,
            acquiredAt: now,
            expiresAt: now.addingTimeInterval(100),
            focusPolicy: .foreground
        )
        let focusedPresentation = ControlCenterPresentation.make(
            snapshot: ControlCenterSnapshot(
                approvals: [],
                execution: focusedExecution,
                permissions: [granted]
            ),
            now: now.addingTimeInterval(10)
        )
        XCTAssertEqual(focusedPresentation.state, .focused)
        XCTAssertEqual(focusedPresentation.label, "Focused")
        XCTAssertTrue(focusedPresentation.tooltip.contains("Focused to Calculator"))
        XCTAssertTrue(focusedPresentation.accessibilityLabel.contains("Focused to Calculator"))

        let activity = ControlCenterFocusActivity(
            applicationName: "Google Chrome",
            phase: .focusing,
            startedAt: now,
            expiresAt: now.addingTimeInterval(3)
        )
        let focusingPresentation = ControlCenterPresentation.make(
            snapshot: ControlCenterSnapshot(
                approvals: [],
                execution: nil,
                permissions: [granted],
                focusActivity: activity
            ),
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(focusingPresentation.state, .focusing)
        XCTAssertEqual(focusingPresentation.label, "Focusing")

        let completedActivity = ControlCenterFocusActivity(
            applicationName: activity.applicationName,
            phase: .focused,
            startedAt: activity.startedAt,
            expiresAt: activity.expiresAt
        )
        let focusedActivityPresentation = ControlCenterPresentation.make(
            snapshot: ControlCenterSnapshot(
                approvals: [],
                execution: nil,
                permissions: [granted],
                focusActivity: completedActivity
            ),
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(focusedActivityPresentation.state, .focused)
        XCTAssertEqual(focusedActivityPresentation.label, "Focused")

        let expiredActivityPresentation = ControlCenterPresentation.make(
            snapshot: ControlCenterSnapshot(
                approvals: [],
                execution: nil,
                permissions: [granted],
                focusActivity: completedActivity
            ),
            now: now.addingTimeInterval(4)
        )
        XCTAssertEqual(expiredActivityPresentation.state, .idle)

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

    func testHandsOffPresentationCoversTheWholeRunAndOutranksTransientFocusNotices() {
        let now = Date(timeIntervalSince1970: 20_000)
        let granted = permission("Accessibility", "granted")
        let session = ControlCenterHandsOffSession(
            sessionID: "run-1",
            provider: "computer_use",
            taskID: "context-menu",
            applicationName: "Google Chrome",
            startedAt: now,
            lastHeartbeatAt: now,
            expiresAt: now.addingTimeInterval(80)
        )
        let execution = ControlCenterExecution(
            executionID: "execution",
            taskID: "context-menu",
            summary: "Computer Use handoff",
            applicationName: "Google Chrome",
            physicalInputMode: .shared,
            acquiredAt: now,
            expiresAt: now.addingTimeInterval(100),
            focusPolicy: .foreground
        )
        let transientFocus = ControlCenterFocusActivity(
            applicationName: "Google Chrome",
            phase: .focused,
            startedAt: now,
            expiresAt: now.addingTimeInterval(3)
        )

        let active = ControlCenterPresentation.make(
            snapshot: ControlCenterSnapshot(
                approvals: [],
                execution: execution,
                permissions: [granted],
                focusActivity: transientFocus,
                handsOffSession: session
            ),
            now: now.addingTimeInterval(10)
        )
        XCTAssertEqual(active.state, .handsOff)
        XCTAssertEqual(active.label, "Hands Off")
        XCTAssertTrue(active.tooltip.contains("Hands off"))
        XCTAssertTrue(active.accessibilityLabel.contains("Hands off to Google Chrome"))
        XCTAssertEqual(active.ringFraction ?? 0, 0.875, accuracy: 0.001)

        let standalone = ControlCenterPresentation.make(
            snapshot: ControlCenterSnapshot(
                approvals: [],
                execution: nil,
                permissions: [granted],
                focusActivity: transientFocus,
                handsOffSession: session
            ),
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(standalone.state, .handsOff)
        XCTAssertEqual(standalone.label, "Hands Off")
        XCTAssertTrue(standalone.tooltip.contains("Google Chrome"))
        XCTAssertTrue(standalone.tooltip.contains("computer use active"))

        let frozen = ControlCenterPresentation.make(
            snapshot: ControlCenterSnapshot(
                approvals: [],
                execution: ControlCenterExecution(
                    executionID: execution.executionID,
                    taskID: execution.taskID,
                    summary: execution.summary,
                    applicationName: execution.applicationName,
                    physicalInputMode: .suppressed,
                    acquiredAt: execution.acquiredAt,
                    expiresAt: execution.expiresAt,
                    focusPolicy: execution.focusPolicy
                ),
                permissions: [granted],
                handsOffSession: session
            ),
            now: now.addingTimeInterval(10)
        )
        XCTAssertEqual(frozen.state, .frozen)

        let expired = ControlCenterPresentation.make(
            snapshot: ControlCenterSnapshot(
                approvals: [],
                execution: nil,
                permissions: [granted],
                focusActivity: transientFocus,
                handsOffSession: session
            ),
            now: now.addingTimeInterval(81)
        )
        XCTAssertEqual(expired.state, .idle)
    }

    func testHandsOffSessionStartsDirectlyAndStopsLifecycle() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-hands-off-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        var now = Date(timeIntervalSince1970: 30_000)
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            lifecycleNow: { now },
            lifecycleDrainDuration: 2
        )

        let begin = service.handle(RequestEnvelope(
            method: "control.hands_off.begin",
            params: [
                "provider": .string("computer_use"),
                "app": .string("Google Chrome"),
                "task_id": .string("context-menu"),
                "seconds": .number(600)
            ]
        ))
        XCTAssertEqual(begin.status, .succeeded)
        let sessionValue = try XCTUnwrap(begin.result["hands_off_session"])
        let session = try JSONCodec.decode(
            ControlCenterHandsOffSession.self,
            from: try JSONCodec.encode(sessionValue)
        )
        XCTAssertEqual(session.provider, "computer_use")
        XCTAssertEqual(session.applicationName, "Google Chrome")
        XCTAssertEqual(session.taskID, "context-menu")
        XCTAssertEqual(service.controlCenterSnapshot().handsOffSession, session)

        let activeStatus = service.handle(RequestEnvelope(method: "control.hands_off.status"))
        XCTAssertEqual(activeStatus.status, .succeeded)
        XCTAssertEqual(activeStatus.result["active"]?.boolValue, true)

        let lifecycleBlocked = service.handle(RequestEnvelope(
            method: "daemon.lifecycle.prepare",
            params: ["operation": .string(DaemonLifecycleOperation.restart.rawValue)]
        ))
        XCTAssertEqual(lifecycleBlocked.status, .blocked)
        XCTAssertEqual(lifecycleBlocked.error?.code, MacCtlErrorCode.daemonLifecycleBlocked.rawValue)
        XCTAssertEqual(lifecycleBlocked.error?.details["hands_off_session_active"]?.boolValue, true)

        now = now.addingTimeInterval(5)
        let heartbeat = service.handle(RequestEnvelope(
            method: "control.hands_off.heartbeat",
            params: [
                "session_id": .string(session.sessionID),
                "seconds": .number(900)
            ]
        ))
        XCTAssertEqual(heartbeat.status, .succeeded)
        XCTAssertEqual(service.controlCenterSnapshot().handsOffSession?.lastHeartbeatAt, now)
        XCTAssertEqual(service.controlCenterSnapshot().handsOffSession?.expiresAt, now.addingTimeInterval(900))

        let duplicate = service.handle(RequestEnvelope(
            method: "control.hands_off.begin",
            params: [:]
        ))
        XCTAssertEqual(duplicate.status, .blocked)
        XCTAssertEqual(duplicate.error?.code, MacCtlErrorCode.handsOffSessionActive.rawValue)

        let ended = service.handle(RequestEnvelope(
            method: "control.hands_off.end",
            params: ["session_id": .string(session.sessionID)]
        ))
        XCTAssertEqual(ended.status, .succeeded)
        XCTAssertEqual(ended.result["released"]?.boolValue, true)
        XCTAssertNil(service.controlCenterSnapshot().handsOffSession)

        let expiring = service.handle(RequestEnvelope(
            method: "control.hands_off.begin",
            params: [
                "provider": .string("mac_control"),
                "seconds": .number(0.5)
            ]
        ))
        let expiringSessionObject = try XCTUnwrap(expiring.result["hands_off_session"]?.objectValue)
        let expiringID = try XCTUnwrap(expiringSessionObject["session_id"]?.stringValue)
        now = now.addingTimeInterval(1)
        let expiredHeartbeat = service.handle(RequestEnvelope(
            method: "control.hands_off.heartbeat",
            params: ["session_id": .string(expiringID)]
        ))
        XCTAssertEqual(expiredHeartbeat.status, .blocked)
        XCTAssertEqual(expiredHeartbeat.error?.code, MacCtlErrorCode.handsOffSessionExpired.rawValue)
        XCTAssertNil(service.controlCenterSnapshot().handsOffSession)

        let stoppedRun = service.handle(RequestEnvelope(
            method: "control.hands_off.begin",
            params: ["seconds": .number(20)]
        ))
        XCTAssertEqual(stoppedRun.status, .succeeded)
        let stopped = service.handle(RequestEnvelope(method: "control.stop_active"))
        XCTAssertEqual(stopped.status, .succeeded)
        XCTAssertEqual(stopped.result["hands_off_session_ended"]?.boolValue, true)
        XCTAssertNil(service.controlCenterSnapshot().handsOffSession)
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
            _ = try runner.prepare(plan: plan)
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
                params: ["plan": try JSONValue.fromEncodable(plan)]
            ))
            XCTAssertEqual(response.status, .succeeded)
            XCTAssertNil(leases.activeLease())
            XCTAssertNil(service.controlCenterSnapshot().execution)
            XCTAssertFalse(suppressor.active)
            if freezeRequired { XCTAssertEqual(suppressor.releaseCount, 1) }
        }
    }

    func testDifferentPlanAndWrongCallerLeaseCannotEscalateKeyboardMode() throws {
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
        let preparedPlan = frozenPlan(id: "exact-plan", summary: "Prepared summary")
        _ = try runner.prepare(plan: preparedPlan)
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
                "lease_token": .string(sharedLease.token)
            ]
        ))
        XCTAssertEqual(mismatchResponse.status, .blocked)
        XCTAssertFalse(suppressor.active)
        XCTAssertEqual(try runner.status(taskID: preparedPlan.id).state, .prepared)

        let wrongModeResponse = service.handle(RequestEnvelope(
            method: "task.run",
            params: [
                "plan": try JSONValue.fromEncodable(preparedPlan),
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
        _ = try runner.prepare(plan: plan)
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
                params: ["plan": (try? JSONValue.fromEncodable(plan)) ?? .null]
            ))
            responseLock.lock()
            runResponse = response
            responseLock.unlock()
            finished.signal()
        }

        XCTAssertEqual(executor.started.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(suppressor.active)
        XCTAssertEqual(service.controlCenterSnapshot().execution?.physicalInputMode, .suppressed)
        let lifecycleBlocked = service.handle(RequestEnvelope(
            method: "daemon.lifecycle.prepare",
            params: ["operation": .string(DaemonLifecycleOperation.restart.rawValue)]
        ))
        XCTAssertEqual(lifecycleBlocked.status, .blocked)
        XCTAssertEqual(
            lifecycleBlocked.error?.code,
            MacCtlErrorCode.daemonLifecycleBlocked.rawValue
        )
        XCTAssertEqual(lifecycleBlocked.error?.details["active_request_count"]?.intValue, 1)
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
        let stoppedSnapshot = service.controlCenterSnapshot()
        XCTAssertNil(stoppedSnapshot.execution)
        XCTAssertEqual(stoppedSnapshot.taskOutcome?.progress.state, .cancelled)
        XCTAssertEqual(stoppedSnapshot.taskOutcome?.progress.steps.map(\.state), [.verified, .stopped])
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

    func testPostconditionFailureRetainsCompletedActionsInStoppedOutcome() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macctl-control-center-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let approvals = TaskApprovalStore()
        let leases = KeyboardDriveStore()
        let executor = RecordingTaskExecutor()
        executor.evaluationResults = [true, false, false, false]
        let runner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: directory),
            approvalStore: approvals,
            actionExecutor: executor,
            targetRevalidator: { _ in nil }
        )
        let predicate = TaskPredicate(kind: .applicationRunning, application: "Calculator")
        let plan = TaskPlan(
            id: "seeded-postcondition-failure",
            name: "Seeded failure",
            summary: "Show completed work before a safe stop",
            steps: [
                TaskStep(
                    id: "completed-action",
                    action: ActionSpec(kind: .assert, surface: .macApp),
                    target: TaskTargetIdentity(application: "Calculator"),
                    postconditions: [predicate]
                ),
                TaskStep(
                    id: "failed-verification",
                    action: ActionSpec(kind: .assert, surface: .macApp),
                    target: TaskTargetIdentity(application: "Calculator"),
                    postconditions: [predicate]
                )
            ]
        )
        _ = try runner.prepare(plan: plan)
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

        let response = service.handle(RequestEnvelope(
            method: "task.run",
            params: ["plan": try JSONValue.fromEncodable(plan)]
        ))

        XCTAssertEqual(response.status, .blocked)
        let snapshot = service.controlCenterSnapshot()
        XCTAssertNil(snapshot.execution)
        XCTAssertEqual(snapshot.taskOutcome?.progress.state, .blocked)
        XCTAssertEqual(snapshot.taskOutcome?.progress.steps.map(\.state), [.verified, .stopped])
        XCTAssertEqual(snapshot.taskOutcome?.progress.lastErrorCode, "task_postcondition_failed")
        XCTAssertNil(leases.activeLease())
    }

    func testLifecycleDrainAtomicallyRejectsMutationsAndAutoExpires() {
        var now = Date(timeIntervalSince1970: 10_000)
        let service = MacCtlService(
            permissionContext: "test",
            lifecycleNow: { now },
            lifecycleDrainDuration: 2
        )
        let prepared = service.handle(RequestEnvelope(
            method: "daemon.lifecycle.prepare",
            params: ["operation": .string(DaemonLifecycleOperation.restart.rawValue)]
        ))
        XCTAssertEqual(prepared.status, .succeeded)
        XCTAssertEqual(service.controlCenterSnapshot().lifecycleDrain?.operation, .restart)

        let rejected = service.handle(RequestEnvelope(
            method: "app.open",
            params: ["name": .string("Calculator")]
        ))
        XCTAssertEqual(rejected.status, .blocked)
        XCTAssertEqual(rejected.error?.code, MacCtlErrorCode.daemonLifecycleBlocked.rawValue)
        XCTAssertEqual(rejected.error?.details["retryable"]?.boolValue, true)

        XCTAssertEqual(
            service.handle(RequestEnvelope(method: "control.center.snapshot")).status,
            .succeeded
        )
        now = now.addingTimeInterval(3)
        let afterExpiry = service.handle(RequestEnvelope(method: "not.a.real.method"))
        XCTAssertEqual(afterExpiry.error?.code, MacCtlErrorCode.unsupportedMethod.rawValue)
        XCTAssertNil(service.controlCenterSnapshot().lifecycleDrain)
    }

    func testLifecycleDrainBlocksPendingAndApprovedAuthorityWithoutExposingTokens() throws {
        let approvals = TaskApprovalStore()
        let service = MacCtlService(permissionContext: "test", taskApprovalStore: approvals)
        let plan = TaskPlan(
            id: "restart-blocker",
            name: "Restart blocker",
            summary: "Hold authority across the lifecycle check",
            steps: [TaskStep(
                id: "assert",
                action: ActionSpec(kind: .assert, surface: .macApp)
            )]
        )
        let pending = approvals.prepare(plan: plan)
        let pendingResponse = service.handle(RequestEnvelope(
            method: "daemon.lifecycle.prepare",
            params: ["operation": .string(DaemonLifecycleOperation.upgrade.rawValue)]
        ))
        XCTAssertEqual(pendingResponse.status, .blocked)
        XCTAssertEqual(pendingResponse.error?.details["approval_count"]?.intValue, 1)
        XCTAssertFalse(String(data: try JSONCodec.encode(pendingResponse), encoding: .utf8)!.contains(pending.record.token))

        _ = try approvals.approve(token: pending.record.token)
        XCTAssertTrue(service.pendingApprovalRecords().isEmpty)
        XCTAssertEqual(service.activeApprovalRecords().count, 1)
        let approvedResponse = service.handle(RequestEnvelope(
            method: "daemon.lifecycle.prepare",
            params: ["operation": .string(DaemonLifecycleOperation.restart.rawValue)]
        ))
        XCTAssertEqual(approvedResponse.status, .blocked)
        XCTAssertEqual(approvedResponse.error?.details["approval_count"]?.intValue, 1)
        XCTAssertFalse(String(data: try JSONCodec.encode(approvedResponse), encoding: .utf8)!.contains(pending.record.token))
    }

    func testPreDispatchFailureLeavesPreparedPlanRetryableUntilFirstActionDispatch() throws {
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
        _ = try runner.prepare(plan: plan)

        XCTAssertThrowsError(try runner.run(plan: plan))
        XCTAssertEqual(try runner.status(taskID: plan.id).state, .prepared)
        XCTAssertEqual(executor.executeCount, 0)

        executor.evaluationResult = true
        XCTAssertEqual(
            try runner.run(plan: plan).state,
            .completed
        )
        XCTAssertEqual(executor.executeCount, 1)
        try? FileManager.default.removeItem(at: directory)
    }

    func testDaemonWaitUsesElapsedTimeAndPollsCancellation() throws {
        var elapsed: TimeInterval = 0
        try CancellableMonotonicWait.run(
            seconds: 0.2,
            monotonicNow: { elapsed },
            sleep: { elapsed += $0 },
            checkpoint: {}
        )
        XCTAssertEqual(elapsed, 0.2, accuracy: 0.000_001)

        elapsed = 0
        XCTAssertThrowsError(try CancellableMonotonicWait.run(
            seconds: 20,
            monotonicNow: { elapsed },
            sleep: { elapsed += $0 },
            checkpoint: {
                if elapsed >= 0.15 { throw TaskControlError.cancelled }
            }
        )) { error in
            XCTAssertEqual(error as? TaskControlError, .cancelled)
        }
        XCTAssertEqual(elapsed, 0.15, accuracy: 0.000_001)
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
    var evaluationResults: [Bool] = []
    private(set) var executeCount = 0

    func execute(action: ActionSpec, context: TaskActionContext) throws -> TaskActionExecutionReport {
        executeCount += 1
        onExecute?()
        return TaskActionExecutionReport(route: "test")
    }

    func evaluate(predicate: TaskPredicate, context: TaskActionContext) throws -> Bool {
        if !evaluationResults.isEmpty { return evaluationResults.removeFirst() }
        return evaluationResult
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
