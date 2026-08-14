import XCTest
@testable import MacCtlCore

final class FocusSessionPlanTests: XCTestCase {
    private let studioDisplay = FocusSessionDisplay(
        id: 42,
        name: "Studio Display",
        visibleFrame: FocusSessionWindowFrame(x: 0, y: 40, width: 1440, height: 860)
    )

    func testFixtureWindowIdentityPrefersDocumentURLAndUsesExactTitleDigestFallback() {
        let expected = URL(fileURLWithPath: "/private/tmp/Synthetic Research Scratchpad.txt")

        XCTAssertTrue(FocusSessionFixtureWindowIdentity.matches(
            expectedURL: expected,
            observedDocumentURL: expected,
            observedWindowTitle: nil
        ))
        XCTAssertTrue(FocusSessionFixtureWindowIdentity.matches(
            expectedURL: expected,
            observedDocumentURL: nil,
            observedWindowTitle: "Synthetic Research Scratchpad.txt"
        ))
        XCTAssertFalse(FocusSessionFixtureWindowIdentity.matches(
            expectedURL: expected,
            observedDocumentURL: nil,
            observedWindowTitle: "Unrelated Notes.txt"
        ))
        XCTAssertFalse(FocusSessionFixtureWindowIdentity.matches(
            expectedURL: expected,
            observedDocumentURL: nil,
            observedWindowTitle: nil
        ))
    }

    func testVerificationPollStopsOnSuccessAndRemainsBounded() {
        var observations = 0
        var sleeps = 0
        XCTAssertTrue(FocusSessionVerificationPoll.untilVerified(
            maximumAttempts: 4,
            interval: 0,
            sleep: { _ in sleeps += 1 },
            observe: {
                observations += 1
                return observations == 3
            }
        ))
        XCTAssertEqual(observations, 3)
        XCTAssertEqual(sleeps, 2)

        observations = 0
        sleeps = 0
        XCTAssertFalse(FocusSessionVerificationPoll.untilVerified(
            maximumAttempts: 3,
            interval: 0,
            sleep: { _ in sleeps += 1 },
            observe: {
                observations += 1
                return false
            }
        ))
        XCTAssertEqual(observations, 3)
        XCTAssertEqual(sleeps, 2)
    }

    func testCanonicalRequestComposesTheSamePreviewAndDigestTwice() throws {
        let first = try FocusSessionPlanComposer.compose(display: studioDisplay, layout: .balanced)
        let second = try FocusSessionPlanComposer.compose(display: studioDisplay, layout: .balanced)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.effects.map(\.id), ["open-brief", "open-scratchpad", "arrange-workspace"])
        XCTAssertEqual(first.effects.map(\.risk), [.reversible, .reversible, .reversible])
        XCTAssertEqual(first.approvalDigest.count, 64)
        XCTAssertFalse(first.executable)
        XCTAssertEqual(first.blockedBy, ["MC-2", "MC-3"])
        XCTAssertEqual(first.display.id, 42)
        XCTAssertEqual(first.layoutName, .balanced)
    }

    func testRequestNormalizationDoesNotChangeTheApprovalDigest() throws {
        let canonical = try FocusSessionPlanComposer.compose(display: studioDisplay, layout: .balanced)
        let normalized = try FocusSessionPlanComposer.compose(
            request: "  prepare   MY research SESSION  ",
            display: studioDisplay,
            layout: .balanced
        )

        XCTAssertEqual(normalized, canonical)
    }

    func testUnsupportedRequestFailsClosed() {
        XCTAssertThrowsError(try FocusSessionPlanComposer.compose(
            request: "Organize everything",
            display: studioDisplay,
            layout: .balanced
        )) { error in
            XCTAssertEqual(error as? FocusSessionPlanError, .unsupportedRequest)
        }
    }

    func testDisplayResolutionUsesIdentityWhenConnectedDisplayOrderChanges() throws {
        let laptop = FocusSessionDisplay(
            id: 7,
            name: "Built-in Display",
            visibleFrame: FocusSessionWindowFrame(x: -1512, y: 0, width: 1512, height: 945)
        )

        XCTAssertEqual(
            try FocusSessionDisplayResolver.resolve(id: studioDisplay.id, from: [laptop, studioDisplay]),
            studioDisplay
        )
        XCTAssertEqual(
            try FocusSessionDisplayResolver.resolve(id: studioDisplay.id, from: [studioDisplay, laptop]),
            studioDisplay
        )
    }

    func testMissingDisplayFailsClosedInsteadOfFallingBackToAnotherScreen() {
        let laptop = FocusSessionDisplay(
            id: 7,
            name: "Built-in Display",
            visibleFrame: FocusSessionWindowFrame(x: 0, y: 0, width: 1512, height: 945)
        )

        XCTAssertThrowsError(
            try FocusSessionDisplayResolver.resolve(id: studioDisplay.id, from: [laptop])
        ) { error in
            XCTAssertEqual(error as? FocusSessionDisplayError, .displayUnavailable(studioDisplay.id))
        }
    }

    func testNamedLayoutsAreIndependentForTheSameDisplay() {
        let balanced = FocusSessionLayoutResolver.targetFrames(
            layout: .balanced,
            visibleFrame: studioDisplay.visibleFrame
        )
        let briefPrimary = FocusSessionLayoutResolver.targetFrames(
            layout: .briefPrimary,
            visibleFrame: studioDisplay.visibleFrame
        )

        XCTAssertNotEqual(balanced.brief.width, briefPrimary.brief.width)
        XCTAssertEqual(
            balanced.brief.width + balanced.scratchpad.width,
            briefPrimary.brief.width + briefPrimary.scratchpad.width,
            accuracy: 0.001
        )
        XCTAssertEqual(balanced.scratchpad.x - balanced.brief.width, 12, accuracy: 0.001)
        XCTAssertEqual(briefPrimary.scratchpad.x - briefPrimary.brief.width, 12, accuracy: 0.001)
    }

    func testDisplayAndLayoutAreBoundIntoIndependentApprovalDigests() throws {
        let balanced = try FocusSessionPlanComposer.compose(display: studioDisplay, layout: .balanced)
        let briefPrimary = try FocusSessionPlanComposer.compose(display: studioDisplay, layout: .briefPrimary)
        let otherDisplay = FocusSessionDisplay(
            id: 99,
            name: "Projector",
            visibleFrame: studioDisplay.visibleFrame
        )
        let projector = try FocusSessionPlanComposer.compose(display: otherDisplay, layout: .balanced)

        XCTAssertNotEqual(balanced.approvalDigest, briefPrimary.approvalDigest)
        XCTAssertNotEqual(balanced.approvalDigest, projector.approvalDigest)
    }

    func testExecutableCandidateUsesOnlyTypedBoundedOperationsAndIndependentPostconditions() throws {
        let registry = AppAdapterRegistry(permissionChecker: { _ in true })
        let plan = try FocusSessionPlanComposer.taskPlan(display: studioDisplay, layout: .briefPrimary)

        XCTAssertEqual(plan.steps.map(\.id), ["open-brief", "open-scratchpad", "arrange-workspace"])
        XCTAssertEqual(
            plan.steps.compactMap { $0.action.parameters["operation"]?.stringValue },
            [
                FocusSessionExecutionOperation.openBrief.rawValue,
                FocusSessionExecutionOperation.openScratchpad.rawValue,
                FocusSessionExecutionOperation.arrangeWorkspace.rawValue
            ]
        )
        XCTAssertTrue(plan.steps.allSatisfy { $0.action.parameters["path"] == nil })
        XCTAssertTrue(plan.steps.allSatisfy { $0.action.parameters["content"] == nil })
        XCTAssertTrue(plan.steps.allSatisfy { $0.action.parameters["script"] == nil })
        let layoutStep = try XCTUnwrap(plan.steps.last)
        XCTAssertEqual(layoutStep.action.parameters["display_id"]?.intValue, Int(studioDisplay.id))
        XCTAssertEqual(layoutStep.action.parameters["layout_name"]?.stringValue, "brief-primary")
        XCTAssertEqual(layoutStep.postconditions.first?.parameters["display_id"]?.intValue, Int(studioDisplay.id))
        XCTAssertEqual(layoutStep.postconditions.first?.parameters["layout_name"]?.stringValue, "brief-primary")
        XCTAssertTrue(plan.steps.allSatisfy { step in
            step.postconditions.count == 1
                && step.postconditions[0].parameters["state"]?.stringValue == "focus_session_verified"
        })
        let validation = TaskPlanValidator.validate(plan, adapterRegistry: registry)
        XCTAssertTrue(validation.valid, validation.errors.joined(separator: "\n"))
    }

    func testIndependentVerificationProducesThreePlanBoundRedactedRecords() throws {
        let preview = try FocusSessionPlanComposer.compose(display: studioDisplay, layout: .balanced)
        let briefFrame = FocusSessionWindowFrame(x: 0, y: 40, width: 720, height: 860)
        let scratchpadFrame = FocusSessionWindowFrame(x: 720, y: 40, width: 720, height: 860)
        let snapshot = FocusSessionVerificationSnapshot(
            planDigest: preview.approvalDigest,
            displayID: studioDisplay.id,
            layoutName: .balanced,
            brief: FocusSessionWindowObservation(
                applicationBundleID: FocusSessionVerifier.previewBundleID,
                visible: true,
                fixtureDigest: "brief-digest",
                windowIdentityDigest: "brief-window-digest",
                frame: briefFrame
            ),
            scratchpad: FocusSessionWindowObservation(
                applicationBundleID: FocusSessionVerifier.textEditBundleID,
                visible: true,
                fixtureDigest: "scratchpad-digest",
                windowIdentityDigest: "scratchpad-window-digest",
                frame: scratchpadFrame
            )
        )

        let records = FocusSessionVerifier.verify(
            preview: preview,
            snapshot: snapshot,
            expectedBriefFixtureDigest: "brief-digest",
            expectedScratchpadFixtureDigest: "scratchpad-digest",
            expectedBriefFrame: briefFrame,
            expectedScratchpadFrame: scratchpadFrame
        )

        XCTAssertEqual(records.map(\.effectID), ["open-brief", "open-scratchpad", "arrange-workspace"])
        XCTAssertEqual(records.map(\.state), [.verified, .verified, .verified])
        XCTAssertTrue(records.allSatisfy { $0.planDigest == preview.approvalDigest })
        let encoded = String(decoding: try JSONCodec.encode(records), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Synthetic Research Brief"))
        XCTAssertFalse(encoded.contains("Synthetic Research Scratchpad"))
    }

    func testVerificationFailsClosedForStalePlanAndMismatchedObservation() throws {
        let preview = try FocusSessionPlanComposer.compose(display: studioDisplay, layout: .balanced)
        let expectedBrief = FocusSessionWindowFrame(x: 0, y: 40, width: 720, height: 860)
        let expectedScratchpad = FocusSessionWindowFrame(x: 720, y: 40, width: 720, height: 860)
        let snapshot = FocusSessionVerificationSnapshot(
            planDigest: "stale-plan",
            displayID: studioDisplay.id,
            layoutName: .balanced,
            brief: FocusSessionWindowObservation(
                applicationBundleID: FocusSessionVerifier.previewBundleID,
                visible: true,
                fixtureDigest: "wrong-brief",
                windowIdentityDigest: "brief-window-digest",
                frame: expectedBrief
            ),
            scratchpad: FocusSessionWindowObservation(
                applicationBundleID: FocusSessionVerifier.textEditBundleID,
                visible: true,
                fixtureDigest: "scratchpad-digest",
                windowIdentityDigest: "scratchpad-window-digest",
                frame: expectedScratchpad
            )
        )

        let records = FocusSessionVerifier.verify(
            preview: preview,
            snapshot: snapshot,
            expectedBriefFixtureDigest: "brief-digest",
            expectedScratchpadFixtureDigest: "scratchpad-digest",
            expectedBriefFrame: expectedBrief,
            expectedScratchpadFrame: expectedScratchpad
        )

        XCTAssertEqual(records.map(\.state), [.failed, .failed, .failed])
    }

    func testChangedTargetRefusesBeforeMutationAndApprovalRunsOnlyOnce() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-focus-session-replay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let approvals = TaskApprovalStore()
        let executor = FocusSessionCountingExecutor()
        var targetChanged = true
        let runner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: directory),
            approvalStore: approvals,
            actionExecutor: executor,
            targetRevalidator: { _ in
                if targetChanged { throw ControlTargetInspectionError.targetChanged }
                return nil
            }
        )
        let plan = TaskPlan(
            id: "showcase.focus-session",
            name: "Research focus session",
            summary: "Prepare the bounded research workspace",
            steps: [TaskStep(
                id: "open-brief",
                action: ActionSpec(
                    kind: .activateWindow,
                    surface: .macApp,
                    parameters: ["app": .string("Preview")]
                ),
                target: TaskTargetIdentity(application: "Preview", bundleID: FocusSessionVerifier.previewBundleID)
            )]
        )

        let prepared = try runner.prepare(plan: plan)
        _ = try approvals.approve(token: prepared.approval.token)
        let authority = TaskExecutionAuthority(
            leaseToken: "focus-session-test-lease",
            fresh: true,
            revalidate: { nil }
        )
        XCTAssertThrowsError(
            try runner.run(
                plan: plan,
                approvalToken: prepared.approval.token,
                authority: authority
            )
        ) { error in
            XCTAssertEqual(error as? TaskControlError, .preconditionFailed("target_changed"))
        }
        XCTAssertEqual(executor.executeCount, 0)
        XCTAssertEqual(try runner.status(taskID: plan.id).state, .prepared)

        targetChanged = false
        XCTAssertEqual(
            try runner.run(
                plan: plan,
                approvalToken: prepared.approval.token,
                authority: authority
            ).state,
            .completed
        )
        XCTAssertEqual(executor.executeCount, 1)
        XCTAssertThrowsError(
            try runner.run(
                plan: plan,
                approvalToken: prepared.approval.token,
                authority: authority
            )
        ) { error in
            XCTAssertEqual(error as? TaskControlError, .invalidState(.completed))
        }
        XCTAssertEqual(executor.executeCount, 1)
    }
}

private final class FocusSessionCountingExecutor: TaskActionExecuting {
    private(set) var executeCount = 0

    func execute(action: ActionSpec, context: TaskActionContext) throws -> TaskActionExecutionReport {
        executeCount += 1
        return TaskActionExecutionReport(route: "test")
    }

    func evaluate(predicate: TaskPredicate, context: TaskActionContext) throws -> Bool {
        true
    }
}
