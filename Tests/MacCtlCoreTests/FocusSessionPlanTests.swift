import XCTest
@testable import MacCtlCore

final class FocusSessionPlanTests: XCTestCase {
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

    func testLayoutConvertsAppKitScreenCoordinatesToAccessibilityCoordinates() {
        let frames = FocusSessionLayout.targetFrames(
            visibleFrame: CGRect(x: 0, y: 75, width: 1512, height: 882),
            primaryScreenMaxY: 982
        )

        XCTAssertEqual(frames.brief, CGRect(x: 0, y: 25, width: 750, height: 882))
        XCTAssertEqual(frames.scratchpad, CGRect(x: 762, y: 25, width: 750, height: 882))
    }

    func testCanonicalRequestComposesTheSamePreviewAndDigestTwice() throws {
        let first = try FocusSessionPlanComposer.compose()
        let second = try FocusSessionPlanComposer.compose()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.effects.map(\.id), ["open-brief", "open-scratchpad", "arrange-workspace"])
        XCTAssertEqual(first.effects.map(\.risk), [.reversible, .reversible, .reversible])
        XCTAssertEqual(first.planDigest.count, 64)
        XCTAssertTrue(first.executable)
        XCTAssertEqual(first.status, "ready")
        XCTAssertTrue(first.blockedBy.isEmpty)
    }

    func testRequestNormalizationDoesNotChangeThePlanDigest() throws {
        let canonical = try FocusSessionPlanComposer.compose()
        let normalized = try FocusSessionPlanComposer.compose(
            request: "  prepare   MY research SESSION  "
        )

        XCTAssertEqual(normalized, canonical)
    }

    func testUnsupportedRequestFailsClosed() {
        XCTAssertThrowsError(try FocusSessionPlanComposer.compose(request: "Organize everything")) { error in
            XCTAssertEqual(error as? FocusSessionPlanError, .unsupportedRequest)
        }
    }

    func testExecutableCandidateUsesOnlyTypedBoundedOperationsAndIndependentPostconditions() throws {
        let registry = AppAdapterRegistry(permissionChecker: { _ in true })
        let plan = try FocusSessionPlanComposer.taskPlan()

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
        XCTAssertTrue(plan.steps.allSatisfy { step in
            step.postconditions.count == 1
                && step.postconditions[0].parameters["state"]?.stringValue == "focus_session_verified"
        })
        let validation = TaskPlanValidator.validate(plan, adapterRegistry: registry)
        XCTAssertTrue(validation.valid, validation.errors.joined(separator: "\n"))
    }

    func testIndependentVerificationProducesThreePlanBoundRedactedRecords() throws {
        let preview = try FocusSessionPlanComposer.compose()
        let briefFrame = FocusSessionWindowFrame(x: 0, y: 40, width: 720, height: 860)
        let scratchpadFrame = FocusSessionWindowFrame(x: 720, y: 40, width: 720, height: 860)
        let snapshot = FocusSessionVerificationSnapshot(
            planDigest: preview.planDigest,
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
        XCTAssertTrue(records.allSatisfy { $0.planDigest == preview.planDigest })
        let encoded = String(decoding: try JSONCodec.encode(records), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Synthetic Research Brief"))
        XCTAssertFalse(encoded.contains("Synthetic Research Scratchpad"))
    }

    func testVerificationFailsClosedForStalePlanAndMismatchedObservation() throws {
        let preview = try FocusSessionPlanComposer.compose()
        let expectedBrief = FocusSessionWindowFrame(x: 0, y: 40, width: 720, height: 860)
        let expectedScratchpad = FocusSessionWindowFrame(x: 720, y: 40, width: 720, height: 860)
        let snapshot = FocusSessionVerificationSnapshot(
            planDigest: "stale-plan",
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

    func testChangedTargetRefusesBeforeMutationAndPreparedPlanRunsOnlyOnce() throws {
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

        _ = try runner.prepare(plan: plan)
        let authority = TaskExecutionAuthority(
            leaseToken: "focus-session-test-lease",
            fresh: true,
            revalidate: { nil }
        )
        XCTAssertThrowsError(
            try runner.run(
                plan: plan,
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
                authority: authority
            ).state,
            .completed
        )
        XCTAssertEqual(executor.executeCount, 1)
        XCTAssertThrowsError(
            try runner.run(
                plan: plan,
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
