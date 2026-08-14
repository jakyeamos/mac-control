import XCTest
@testable import MacCtlCore

final class ActionIntentTests: XCTestCase {
    func testResolveAndRunOneExactBackgroundPressWithDesiredStateReadback() throws {
        let fixture = Fixture()
        let controller = fixture.controller()

        let resolved = try controller.resolve(fixture.intent(), requestID: "resolve-1")
        XCTAssertEqual(resolved.route, ExactActionIntentController.route)
        XCTAssertEqual(resolved.foregroundBudget, 0)
        XCTAssertTrue(resolved.oneShot)

        let executed = try controller.run(resolutionID: resolved.resolutionID)
        XCTAssertEqual(executed.verification, "desired_state_observed")
        XCTAssertTrue(executed.foregroundPreserved)
        XCTAssertEqual(fixture.accessibility.pressCount, 1)
        XCTAssertEqual(fixture.windowInspector.inspectedWindowRefs, ["window-42", "window-42", "window-42"])

        XCTAssertThrowsError(try controller.run(resolutionID: resolved.resolutionID)) { error in
            XCTAssertEqual(error as? ExactActionIntentError, .resolutionAlreadyUsed)
        }
    }

    func testGraphInvalidationStopsBeforeMutation() throws {
        let fixture = Fixture()
        let controller = fixture.controller()
        let resolved = try controller.resolve(fixture.intent(), requestID: "resolve-2")
        fixture.graph.invalidate(processID: 42)

        XCTAssertThrowsError(try controller.run(resolutionID: resolved.resolutionID)) { error in
            XCTAssertEqual(error as? ExactActionIntentError, .targetChanged)
        }
        XCTAssertEqual(fixture.accessibility.pressCount, 0)
    }

    func testPIDReplacementFailsClosed() throws {
        let fixture = Fixture()
        let controller = fixture.controller()
        let resolved = try controller.resolve(fixture.intent(), requestID: "resolve-3")
        fixture.resolvedInstance = fixture.instance(pid: 43, instanceRef: "replacement")

        XCTAssertThrowsError(try controller.run(resolutionID: resolved.resolutionID)) { error in
            XCTAssertEqual(error as? ExactActionIntentError, .targetChanged)
        }
        XCTAssertEqual(fixture.accessibility.pressCount, 0)
    }

    func testDisappearingWindowFailsClosed() throws {
        let fixture = Fixture()
        let controller = fixture.controller()
        let resolved = try controller.resolve(fixture.intent(), requestID: "resolve-4")
        fixture.windowInspector.error = .targetMissing

        XCTAssertThrowsError(try controller.run(resolutionID: resolved.resolutionID)) { error in
            XCTAssertEqual(error as? ExactActionIntentError, .targetMissing)
        }
        XCTAssertEqual(fixture.accessibility.pressCount, 0)
    }

    func testDuplicateSemanticTargetFailsDuringResolve() {
        let fixture = Fixture()
        fixture.accessibility.inspectError = .ambiguousMatch(2)

        XCTAssertThrowsError(try fixture.controller().resolve(fixture.intent(), requestID: "resolve-5")) { error in
            XCTAssertEqual(error as? ExactActionIntentError, .targetAmbiguous(2))
        }
        XCTAssertEqual(fixture.accessibility.pressCount, 0)
    }

    func testForegroundTheftStopsBeforeMutation() throws {
        let fixture = Fixture()
        let controller = fixture.controller()
        let resolved = try controller.resolve(fixture.intent(), requestID: "resolve-6")
        fixture.foregroundPID = 100

        XCTAssertThrowsError(try controller.run(resolutionID: resolved.resolutionID)) { error in
            XCTAssertEqual(error as? ExactActionIntentError, .foregroundRace)
        }
        XCTAssertEqual(fixture.accessibility.pressCount, 0)
    }

    func testResolveRejectsTargetThatAlreadyOwnsForeground() {
        let fixture = Fixture()
        fixture.foregroundPID = 42

        XCTAssertThrowsError(try fixture.controller().resolve(fixture.intent(), requestID: "resolve-frontmost")) { error in
            XCTAssertEqual(
                error as? ExactActionIntentError,
                .unsupported("the zero-focus target must not own the foreground")
            )
        }
        XCTAssertEqual(fixture.accessibility.pressCount, 0)
    }

    func testDelayedPostconditionIsPolledWithoutReplayingMutation() throws {
        let fixture = Fixture()
        fixture.accessibility.existsResults = [false, false, false, true]
        let controller = fixture.controller()
        let resolved = try controller.resolve(fixture.intent(timeout: 1), requestID: "resolve-7")
        let executed = try controller.run(resolutionID: resolved.resolutionID)

        XCTAssertEqual(executed.verification, "desired_state_observed")
        XCTAssertEqual(fixture.accessibility.pressCount, 1)
        XCTAssertEqual(fixture.accessibility.existsCount, 4)
    }

    func testIndeterminateNativeDispatchCanCompleteOnlyThroughDesiredStateReadback() throws {
        let fixture = Fixture()
        fixture.accessibility.dispatchResult = .indeterminate(-25204)
        let controller = fixture.controller()
        let resolved = try controller.resolve(fixture.intent(), requestID: "resolve-indeterminate-verified")

        let executed = try controller.run(resolutionID: resolved.resolutionID)
        XCTAssertEqual(executed.dispatchStatus, "indeterminate_but_verified")
        XCTAssertEqual(executed.nativeDispatchCode, -25204)
        XCTAssertEqual(executed.verification, "desired_state_observed_after_indeterminate_dispatch")
        XCTAssertEqual(fixture.accessibility.pressCount, 1)
    }

    func testIndeterminateNativeDispatchWithoutDesiredStateIsTerminalAndNeverReplayed() throws {
        let fixture = Fixture()
        fixture.accessibility.dispatchResult = .indeterminate(-25204)
        fixture.accessibility.existsResults = [false, false, false]
        let controller = fixture.controller()
        let resolved = try controller.resolve(fixture.intent(timeout: 0.05), requestID: "resolve-indeterminate-unverified")

        XCTAssertThrowsError(try controller.run(resolutionID: resolved.resolutionID)) { error in
            XCTAssertEqual(error as? ExactActionIntentError, .dispatchIndeterminate(-25204))
        }
        XCTAssertEqual(fixture.accessibility.pressCount, 1)
        XCTAssertThrowsError(try controller.run(resolutionID: resolved.resolutionID)) { error in
            XCTAssertEqual(error as? ExactActionIntentError, .resolutionAlreadyUsed)
        }
    }

    func testIntentRejectsNonzeroFocusBudgetAndUnstableSelector() {
        let fixture = Fixture()
        let unsupported = fixture.intent(foregroundBudget: 1)
        XCTAssertThrowsError(try fixture.controller().resolve(unsupported, requestID: "resolve-8")) { error in
            XCTAssertEqual(
                error as? ExactActionIntentError,
                .unsupported("the vertical slice requires focus_policy=background and foreground_budget=0")
            )
        }

        let unstable = fixture.intent(selector: ExactActionSelector(role: "AXButton", title: "Run"))
        XCTAssertThrowsError(try fixture.controller().resolve(unstable, requestID: "resolve-9")) { error in
            XCTAssertEqual(
                error as? ExactActionIntentError,
                .invalid("the mutation selector requires identifier or locator_digest")
            )
        }
    }
}

private final class Fixture {
    let graph = EphemeralTargetGraph(observeSystemEvents: false)
    let accessibility = RecordingExactAccessibility()
    let windowInspector = RecordingActionWindowInspector()
    var resolvedInstance: ApplicationInstanceInfo
    var foregroundPID: Int32 = 99

    init() {
        resolvedInstance = ApplicationInstanceInfo(
            application: AppInfo(
                name: "Mac Control Background Fixture",
                bundleID: "com.jakyeamos.macctl.background-fixture",
                path: "/private/tmp/MacControlBackgroundFixture.app",
                isRunning: true,
                processID: 42,
                bundleVersion: "1"
            ),
            processID: 42,
            instanceRef: "instance-42"
        )
    }

    func instance(pid: Int32, instanceRef: String) -> ApplicationInstanceInfo {
        ApplicationInstanceInfo(
            application: AppInfo(
                name: "Mac Control Background Fixture",
                bundleID: "com.jakyeamos.macctl.background-fixture",
                path: "/private/tmp/MacControlBackgroundFixture.app",
                isRunning: true,
                processID: pid,
                bundleVersion: "1"
            ),
            processID: pid,
            instanceRef: instanceRef
        )
    }

    func intent(
        foregroundBudget: Int = 0,
        selector: ExactActionSelector = ExactActionSelector(
            role: "AXButton",
            identifier: "macctl-fixture-run"
        ),
        timeout: TimeInterval = 1
    ) -> ExactActionIntent {
        ExactActionIntent(
            action: .press,
            target: ExactActionTarget(
                application: "com.jakyeamos.macctl.background-fixture",
                processID: 42,
                instanceRef: "instance-42",
                windowRef: "window-42",
                selector: selector
            ),
            desiredState: ExactActionDesiredState(
                selector: ExactActionSelector(
                    role: "AXStaticText",
                    identifier: "macctl-fixture-status",
                    containsText: "Completed"
                )
            ),
            foregroundBudget: foregroundBudget,
            verificationTimeout: timeout
        )
    }

    func controller() -> ExactActionIntentController {
        ExactActionIntentController(
            graph: graph,
            resolveApplicationTarget: { [weak self] _ in
                guard let self else { throw ExactActionIntentError.targetMissing }
                return self.resolvedInstance
            },
            windowInspector: windowInspector,
            displayProvider: EmptyActionDisplayProvider(),
            accessibility: accessibility,
            foregroundApplication: { [weak self] in
                guard let self else { return nil }
                return AppInfo(
                    name: "Foreground Fixture",
                    bundleID: "com.jakyeamos.foreground-fixture",
                    path: "/private/tmp/ForegroundFixture.app",
                    isRunning: true,
                    processID: self.foregroundPID,
                    bundleVersion: "1"
                )
            },
            poll: { _ in }
        )
    }
}

private final class RecordingExactAccessibility: ExactAccessibilityActionPerforming {
    var inspectError: AccessibilityControllerError?
    var existsResults = [false, true]
    var pressCount = 0
    var dispatchResult: ExactAccessibilityDispatchResult = .accepted
    var existsCount = 0

    func inspectPressTarget(
        pid: pid_t,
        windowRef: String,
        selector: MacCtlCore.Selector
    ) throws -> ExactAccessibilityPressTarget {
        if let inspectError { throw inspectError }
        return ExactAccessibilityPressTarget(
            role: "AXButton",
            subrole: nil,
            action: "AXPress",
            locatorDigest: "locator-42"
        )
    }

    func press(
        pid: pid_t,
        windowRef: String,
        selector: MacCtlCore.Selector
    ) throws -> ExactAccessibilityDispatchResult {
        pressCount += 1
        return dispatchResult
    }

    func elementExists(
        pid: pid_t,
        windowRef: String,
        selector: MacCtlCore.Selector,
        maxNodes: Int
    ) throws -> Bool {
        defer { existsCount += 1 }
        let index = min(existsCount, existsResults.count - 1)
        return existsResults[index]
    }
}

private final class RecordingActionWindowInspector: NativeWindowTargetInspecting {
    var error: NativeWindowControlError?
    var inspectedWindowRefs: [String] = []

    func listWindows(pid: pid_t, displays: [NativeWindowDisplay]) throws -> NativeWindowTargetCatalog {
        NativeWindowTargetCatalog(processID: pid, windows: [], omittedWindowCount: 0)
    }

    func inspectWindow(
        pid: pid_t,
        windowRef: String,
        displays: [NativeWindowDisplay]
    ) throws -> NativeWindowTargetSnapshot {
        if let error { throw error }
        inspectedWindowRefs.append(windowRef)
        return NativeWindowTargetSnapshot(
            snapshot: NativeWindowSnapshot(
                processID: pid,
                identityDigest: windowRef,
                frame: NativeWindowFrame(x: 0, y: 0, width: 400, height: 300),
                displayID: nil,
                movable: true,
                resizable: true,
                minimized: false,
                fullscreen: false
            ),
            unique: true,
            focused: false,
            visible: true
        )
    }
}

private struct EmptyActionDisplayProvider: NativeWindowDisplayProviding {
    func connectedDisplays() -> [NativeWindowDisplay] { [] }
}
