import XCTest
@testable import MacCtlCore

final class AutomaticFocusPolicyTests: XCTestCase {
    func testAutomaticSelectsVerifiedBackgroundRoute() throws {
        let resolution = FocusPolicyResolution.resolve(
            requestedPolicy: .automatic,
            backgroundEligible: true
        )

        XCTAssertEqual(resolution.requestedPolicy, .automatic)
        XCTAssertEqual(resolution.effectivePolicy, .background)
        XCTAssertEqual(resolution.selectionReason, "verified_background_route")
        XCTAssertNil(resolution.backgroundUnavailableReason)

        let object = try XCTUnwrap(
            try JSONValue.fromEncodable(resolution).objectValue
        )
        XCTAssertEqual(object["requested_focus_policy"]?.stringValue, "automatic")
        XCTAssertEqual(object["effective_focus_policy"]?.stringValue, "background")
        XCTAssertEqual(object["selection_reason"]?.stringValue, "verified_background_route")
    }

    func testAutomaticFallsBackImmediatelyToForegroundWithReason() {
        let resolution = FocusPolicyResolution.resolve(
            requestedPolicy: .automatic,
            backgroundEligible: false,
            backgroundUnavailableReason: "task_plan_not_background_safe"
        )

        XCTAssertEqual(resolution.requestedPolicy, .automatic)
        XCTAssertEqual(resolution.effectivePolicy, .foreground)
        XCTAssertEqual(resolution.selectionReason, "foreground_fallback")
        XCTAssertEqual(resolution.backgroundUnavailableReason, "task_plan_not_background_safe")
    }

    func testExplicitPoliciesNeverChange() {
        let foreground = FocusPolicyResolution.resolve(
            requestedPolicy: .foreground,
            backgroundEligible: true
        )
        let background = FocusPolicyResolution.resolve(
            requestedPolicy: .background,
            backgroundEligible: false
        )

        XCTAssertEqual(foreground.effectivePolicy, .foreground)
        XCTAssertEqual(foreground.selectionReason, "explicit_foreground")
        XCTAssertEqual(background.effectivePolicy, .background)
        XCTAssertEqual(background.selectionReason, "explicit_background")
    }

    func testTaskPlanKeepsRequestedAutomaticPolicyWhileExecutionUsesBackground() throws {
        let directory = URL(
            fileURLWithPath: "/private/tmp/macctl-automatic-task-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let approvals = TaskApprovalStore()
        let executor = FocusRecordingTaskExecutor()
        let runner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: directory),
            approvalStore: approvals,
            actionExecutor: executor
        )
        let plan = TaskPlan(
            id: "automatic.background.execution",
            name: "Automatic background execution",
            summary: "Keep requested policy separate from route selection",
            focusPolicy: .automatic,
            steps: [TaskStep(
                id: "wait",
                action: ActionSpec(
                    kind: .waitFor,
                    surface: .macApp,
                    parameters: ["seconds": .number(0)]
                )
            )]
        )

        let prepared = try runner.prepare(plan: plan)
        XCTAssertEqual(prepared.planDigest, TaskPlan.digest(plan))

        let completed = try runner.run(
            plan: plan,
            effectiveFocusPolicy: .background
        )

        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(executor.focusPolicies, [.background])
        XCTAssertEqual(executor.planDigests, [TaskPlan.digest(plan)])
    }

    func testReceiptPersistsRequestedAndEffectiveFocusEvidence() throws {
        let receipt = OperationReceipt(
            operationID: "operation",
            requestID: "request",
            method: "task.run",
            workflowID: nil,
            targetSurface: .macApp,
            requestedFocusPolicy: .automatic,
            focusPolicy: .foreground,
            focusSelectionReason: "foreground_fallback",
            backgroundUnavailableReason: "task_plan_not_background_safe",
            risk: .safe,
            planDigest: "digest",
            runtimeIdentity: RuntimeIdentity(
                processID: 1,
                executablePath: nil,
                bundlePath: nil,
                bundleIdentifier: nil,
                bundleVersion: nil
            ),
            permissionContext: "test",
            permissions: [],
            status: .succeeded,
            errorCode: nil,
            evidence: [],
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2)
        )

        let decoded = try JSONCodec.decode(
            OperationReceipt.self,
            from: JSONCodec.encode(receipt)
        )

        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertEqual(decoded.requestedFocusPolicy, .automatic)
        XCTAssertEqual(decoded.focusPolicy, .foreground)
        XCTAssertEqual(decoded.focusSelectionReason, "foreground_fallback")
        XCTAssertEqual(decoded.backgroundUnavailableReason, "task_plan_not_background_safe")
    }

    func testWorkflowDefaultsToAutomaticAndReportsEffectiveBackgroundRoute() throws {
        let directory = URL(
            fileURLWithPath: "/private/tmp/macctl-automatic-workflow-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiptStore = OperationReceiptStore(directory: directory)
        let service = MacCtlService(
            receiptStore: receiptStore,
            permissionContext: "test"
        )

        let prepared = service.handle(RequestEnvelope(
            method: "workflow.prepare",
            params: ["workflow": .string("execution.smoke")]
        ))
        XCTAssertEqual(prepared.status, .prepared)
        XCTAssertEqual(prepared.result["focus_policy"]?.stringValue, "automatic")
        XCTAssertEqual(prepared.result["risk"]?.stringValue, RiskLevel.sensitive.rawValue)
        XCTAssertNil(prepared.result["approval"])

        let executed = service.handle(RequestEnvelope(
            method: "workflow.run",
            params: ["workflow": .string("execution.smoke")]
        ))

        XCTAssertEqual(executed.status, .succeeded)
        XCTAssertEqual(executed.result["requested_focus_policy"]?.stringValue, "automatic")
        XCTAssertEqual(executed.result["focus_policy"]?.stringValue, "background")
        XCTAssertEqual(executed.result["focus_selection_reason"]?.stringValue, "verified_background_route")

        let receipt = try XCTUnwrap(
            receiptStore.list(limit: 10).first(where: { $0.method == "workflow.run" })
        )
        XCTAssertEqual(receipt.requestedFocusPolicy, .automatic)
        XCTAssertEqual(receipt.focusPolicy, .background)
        XCTAssertEqual(receipt.focusSelectionReason, "verified_background_route")
    }
}

private final class FocusRecordingTaskExecutor: TaskActionExecuting {
    private(set) var focusPolicies: [FocusPolicy] = []
    private(set) var planDigests: [String] = []

    func execute(
        action: ActionSpec,
        context: TaskActionContext
    ) throws -> TaskActionExecutionReport {
        focusPolicies.append(context.focusPolicy)
        planDigests.append(context.planDigest)
        return TaskActionExecutionReport(route: "test")
    }

    func evaluate(
        predicate: TaskPredicate,
        context: TaskActionContext
    ) throws -> Bool {
        true
    }
}
