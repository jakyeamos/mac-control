import CoreGraphics
import Foundation
import XCTest
@testable import MacCtlCore

final class AccessibilityActivationTests: XCTestCase {
    func testContextMenuEvidenceAcceptsOneRenderedMenuWithRenderedItems() {
        XCTAssertTrue(
            AccessibilityController.contextMenuEvidenceIsSufficient(
                renderedMenuCount: 1,
                visibleItemCount: 8,
                expectedItemCount: 1,
                matchedItemCount: 1,
                ambiguousMenuCandidates: false
            )
        )
        XCTAssertTrue(
            AccessibilityController.hasRenderableBounds(
                CGRect(x: 12, y: 24, width: 240, height: 32)
            )
        )
    }

    func testContextMenuEvidenceRejectsAXMenuTemplatesWithoutRenderedItems() {
        XCTAssertFalse(
            AccessibilityController.hasRenderableBounds(.zero)
        )
        XCTAssertFalse(
            AccessibilityController.contextMenuEvidenceIsSufficient(
                renderedMenuCount: 1,
                visibleItemCount: 0,
                expectedItemCount: 1,
                matchedItemCount: 1,
                ambiguousMenuCandidates: false
            )
        )
    }

    func testContextMenuEvidenceRejectsAmbiguousRenderedMenuCandidates() {
        XCTAssertFalse(
            AccessibilityController.contextMenuEvidenceIsSufficient(
                renderedMenuCount: 2,
                visibleItemCount: 12,
                expectedItemCount: 1,
                matchedItemCount: 1,
                ambiguousMenuCandidates: true
            )
        )
    }

    func testContextMenuReportDecodesReceiptsWrittenBeforeGeometryEvidence() throws {
        let legacy = """
        {
          "state": "passed",
          "targetResolved": true,
          "menuVisible": true,
          "expectedItemCount": 1,
          "matchedItemCount": 1,
          "visibleItemCount": 8
        }
        """.data(using: .utf8)!

        let report = try JSONDecoder().decode(ContextMenuReport.self, from: legacy)

        XCTAssertEqual(report.renderedMenuCount, 1)
        XCTAssertFalse(report.ambiguousMenuCandidates)
        XCTAssertTrue(report.actionPostcondition.details["menu_geometry_verified"] == .bool(true))
    }

    func testSemanticActivationPrefersAXPressForOrdinaryControls() {
        XCTAssertEqual(
            AccessibilityController.semanticActivationAction(
                role: "AXButton",
                subrole: nil,
                actions: ["AXPress", AccessibilityController.showDefaultUIAction]
            ),
            "AXPress"
        )
    }

    func testSystemSettingsRowsExposePresentationOnlyShowDefaultUI() {
        XCTAssertNil(
            AccessibilityController.semanticActivationAction(
                role: "AXRow",
                subrole: "AXOutlineRow",
                actions: [
                    AccessibilityController.showAlternateUIAction,
                    AccessibilityController.showDefaultUIAction
                ]
            )
        )
        XCTAssertEqual(
            AccessibilityController.semanticPresentationAction(
                role: "AXRow",
                subrole: "AXOutlineRow",
                actions: [
                    AccessibilityController.showAlternateUIAction,
                    AccessibilityController.showDefaultUIAction
                ]
            ),
            AccessibilityController.showDefaultUIAction
        )
    }

    func testSystemSettingsRowsExposeAlternatePresentationOnlyWhenDefaultIsAbsent() {
        XCTAssertEqual(
            AccessibilityController.semanticPresentationAction(
                role: "AXRow",
                subrole: "AXOutlineRow",
                actions: [AccessibilityController.showAlternateUIAction]
            ),
            AccessibilityController.showAlternateUIAction
        )
    }

    func testShowDefaultUIIsNotAcceptedForAnUnrelatedElement() {
        XCTAssertNil(
            AccessibilityController.semanticPresentationAction(
                role: "AXGroup",
                subrole: nil,
                actions: [AccessibilityController.showDefaultUIAction]
            )
        )
    }

    func testVerifiedSelectedPanePostconditionPromotesActivationWithoutFocusChange() throws {
        let app = testApp()
        let store = KeyboardDriveStore()
        let focused = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXRow",
            subrole: "AXOutlineRow",
            identifier: nil,
            title: nil
        )
        let session = ControlSession(
            keyboardDriveStore: store,
            focusedElementInspector: FixedFocusInspector(snapshot: focused),
            foregroundApplication: { app },
            hasPostEventAccess: { true },
            fullKeyboardAccessEnabled: { true },
            verifier: ControlStateVerifier(sleep: { _ in }, eventMonitor: nil),
            postActionTimeout: 0
        )
        let activation = FakeActivationPerformer(verified: true)
        let router = SemanticActionRouter(
            session: session,
            keyboardAccessController: KeyboardAccessController(
                eventSender: NoopKeyboardEvents(),
                preferenceStore: EnabledKeyboardPreferences()
            ),
            accessibilityActionController: activation,
            visualActionController: NoopVisualActivation()
        )
        let lease = try store.acquire(
            scope: .app,
            application: app,
            seconds: 30,
            confirm: true
        )

        let report = try router.perform(
            command: .activate,
            selector: Selector(role: "AXRow", subrole: "AXOutlineRow"),
            leaseToken: lease.token,
            count: 1,
            interKeyDelay: 0,
            allowRawCoordinate: false
        )

        XCTAssertEqual(activation.activationCount, 1)
        XCTAssertEqual(report.verification.state, .passed)
        XCTAssertFalse(report.verification.focusChanged)
        XCTAssertEqual(report.verification.postcondition?.kind, "selected_pane")
        XCTAssertTrue(report.verification.postcondition?.verified == true)
    }

    func testUnverifiedSelectedPanePostconditionRemainsForegroundOnly() throws {
        let app = testApp()
        let store = KeyboardDriveStore()
        let focused = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXRow",
            subrole: "AXOutlineRow",
            identifier: nil,
            title: nil
        )
        let session = ControlSession(
            keyboardDriveStore: store,
            focusedElementInspector: FixedFocusInspector(snapshot: focused),
            foregroundApplication: { app },
            hasPostEventAccess: { true },
            fullKeyboardAccessEnabled: { true },
            verifier: ControlStateVerifier(sleep: { _ in }, eventMonitor: nil),
            postActionTimeout: 0
        )
        let router = SemanticActionRouter(
            session: session,
            keyboardAccessController: KeyboardAccessController(
                eventSender: NoopKeyboardEvents(),
                preferenceStore: EnabledKeyboardPreferences()
            ),
            accessibilityActionController: FakeActivationPerformer(verified: false),
            visualActionController: NoopVisualActivation()
        )
        let lease = try store.acquire(
            scope: .app,
            application: app,
            seconds: 30,
            confirm: true
        )

        let report = try router.perform(
            command: .activate,
            selector: Selector(role: "AXRow", subrole: "AXOutlineRow"),
            leaseToken: lease.token,
            count: 1,
            interKeyDelay: 0,
            allowRawCoordinate: false
        )

        XCTAssertEqual(report.verification.state, .foregroundOnly)
        XCTAssertEqual(report.verification.postcondition?.kind, "selected_pane")
        XCTAssertFalse(report.verification.postcondition?.verified == true)
    }

    private func testApp() -> AppInfo {
        AppInfo(
            name: "System Settings",
            bundleID: "com.apple.systemsettings",
            path: "/System/Applications/System Settings.app",
            isRunning: true,
            processID: 404,
            bundleVersion: "15.0"
        )
    }
}

private final class FixedFocusInspector: FocusedElementInspecting {
    private let snapshot: FocusedElementSnapshot

    init(snapshot: FocusedElementSnapshot) {
        self.snapshot = snapshot
    }

    func focusedElementSnapshot(pid: pid_t, application: AppInfo) throws -> FocusedElementSnapshot {
        snapshot
    }
}

private final class FakeActivationPerformer: AccessibilityActionPerforming {
    private let verified: Bool
    private(set) var activationCount = 0

    init(verified: Bool) {
        self.verified = verified
    }

    @discardableResult
    func press(pid: pid_t, selector: MacCtlCore.Selector) throws -> CGRect {
        .zero
    }

    func activate(
        pid: pid_t,
        selector: MacCtlCore.Selector
    ) throws -> AccessibilityActivationReport {
        activationCount += 1
        return AccessibilityActivationReport(
            action: "AXPress",
            postcondition: ControlActionPostcondition(
                kind: "selected_pane",
                verified: verified,
                details: ["selected": .bool(verified)]
            )
        )
    }
}

private final class NoopVisualActivation: VisualActionPerforming {
    @discardableResult
    func activate(selector: MacCtlCore.Selector, application: AppInfo) throws -> CGRect {
        .zero
    }
}

private struct NoopKeyboardEvents: KeyboardEventSending {
    func send(keySpecification: String) throws {}
}

private struct EnabledKeyboardPreferences: KeyboardPreferenceStore {
    var fullKeyboardAccessEnabled: Bool { true }

    func enableFullKeyboardAccess() throws {}
}
