import Foundation
import XCTest
@testable import MacCtlCore

final class CapabilityVerificationTests: XCTestCase {
    func testMatcherRequiresPrecisePostconditionBeforeReadOnlySurfaceIsReady() throws {
        let app = testApplication()
        let tree = makeTree(application: app, actions: ["AXPress"])
        let selector = Selector(role: "AXButton", identifier: "chatgpt-control")

        let withoutPostcondition = TaskCapabilityVerificationMatcher.evaluate(
            selector: selector,
            route: .accessibility,
            tree: tree,
            postconditionKind: nil,
            postconditionDigest: nil,
            coverageComplete: true
        )
        XCTAssertEqual(withoutPostcondition.state, .needsPostcondition)
        XCTAssertEqual(withoutPostcondition.reason, "precise_postcondition_required")
        XCTAssertEqual(withoutPostcondition.targetMatchCount, 1)
        XCTAssertFalse(withoutPostcondition.requiresComputerUseHandoff)

        let withPostcondition = TaskCapabilityVerificationMatcher.evaluate(
            selector: selector,
            route: .accessibility,
            tree: tree,
            postconditionKind: "selected_pane_changed",
            postconditionDigest: String(repeating: "a", count: 64),
            coverageComplete: true
        )
        XCTAssertEqual(withPostcondition.state, .readyForMeasurement)
        XCTAssertFalse(withPostcondition.requiresComputerUseHandoff)
    }

    func testMatcherRetainsComputerUseForAmbiguousPresentationOnlyAndIncompleteSurfaces() throws {
        let app = testApplication()
        let ambiguousTree = makeTree(
            application: app,
            actions: ["AXPress"],
            duplicateTarget: true
        )
        let selector = Selector(role: "AXButton", identifier: "chatgpt-control")
        let ambiguous = TaskCapabilityVerificationMatcher.evaluate(
            selector: selector,
            route: .accessibility,
            tree: ambiguousTree,
            postconditionKind: "state_changed",
            postconditionDigest: String(repeating: "b", count: 64),
            coverageComplete: true
        )
        XCTAssertEqual(ambiguous.state, .ambiguous)
        XCTAssertTrue(ambiguous.requiresComputerUseHandoff)

        let presentationTree = makeTree(
            application: app,
            actions: ["AXShowDefaultUI"],
            role: "AXRow"
        )
        let presentationOnly = TaskCapabilityVerificationMatcher.evaluate(
            selector: Selector(role: "AXRow", identifier: "chatgpt-control"),
            route: .accessibility,
            tree: presentationTree,
            postconditionKind: "state_changed",
            postconditionDigest: String(repeating: "c", count: 64),
            coverageComplete: true
        )
        XCTAssertEqual(presentationOnly.state, .unsupported)
        XCTAssertEqual(presentationOnly.reason, "presentation_only_accessibility_action")
        XCTAssertTrue(presentationOnly.requiresComputerUseHandoff)

        let incomplete = TaskCapabilityVerificationMatcher.evaluate(
            selector: selector,
            route: .accessibility,
            tree: makeTree(application: app, actions: ["AXPress"], truncated: true),
            postconditionKind: "state_changed",
            postconditionDigest: String(repeating: "d", count: 64),
            coverageComplete: false
        )
        XCTAssertEqual(incomplete.state, .candidate)
        XCTAssertEqual(incomplete.reason, "bounded_surface_incomplete")
        XCTAssertTrue(incomplete.requiresComputerUseHandoff)
    }

    func testServiceRecordsCandidateObservationWithoutDispatchingAction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macctl-capability-verification-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = testApplication()
        let inspector = RecordingVerificationTreeInspector(
            report: makeTree(application: app, actions: ["AXPress"])
        )
        let profileStore = CapabilityProfileStore(
            directory: root.appendingPathComponent("profiles", isDirectory: true)
        )
        let service = MacCtlService(
            permissionContext: "test",
            resolveApplication: { name in
                guard name == app.name else {
                    throw WorkflowExecutionError.unsafeInput("unexpected app")
                }
                return app
            },
            resolveApplicationTarget: { selector in
                ApplicationInstanceInfo(
                    application: app,
                    processID: selector.processID ?? app.processID ?? 404
                )
            },
            capabilityProfileStore: profileStore,
            accessibilityTreeInspector: inspector
        )
        let response = service.handle(RequestEnvelope(
            method: "control.capability_verify",
            params: [
                "app": .string(app.name),
                "task": .string("chatgpt-focus-control"),
                "target_fingerprint": .string("chatgpt-surface-v1"),
                "route": .string("accessibility"),
                "selector": .object([
                    "role": .string("AXButton"),
                    "identifier": .string("chatgpt-control")
                ]),
                "postcondition_kind": .string("selected_pane_changed"),
                "postcondition_digest": .string(String(repeating: "e", count: 64))
            ]
        ))

        XCTAssertEqual(response.status, .succeeded)
        let report = try JSONCodec.decode(
            TaskCapabilityVerificationReport.self,
            from: JSONCodec.encode(response.result)
        )
        XCTAssertEqual(report.state, .readyForMeasurement)
        XCTAssertTrue(report.readOnly)
        XCTAssertFalse(report.actionDispatched)
        XCTAssertEqual(report.targetMatchCount, 1)
        XCTAssertNil(report.handoffPlan)
        XCTAssertEqual(response.outcome?.state, .verificationUnavailable)
        XCTAssertEqual(
            response.outcome?.nextAction,
            "submit_approval_gated_action_with_same_target_and_postcondition"
        )
        XCTAssertEqual(inspector.treeCallCount, 1)
        XCTAssertEqual(
            response.evidence.first?.kind,
            "control_capability_verification"
        )
        XCTAssertEqual(
            response.evidence.first?.metadata["action_dispatched"]?.boolValue,
            false
        )
        XCTAssertEqual(
            response.evidence.first?.metadata["reason"]?.stringValue,
            "unique_actionable_surface_observed"
        )

        let providerState = CapabilityProviderState(
            permissionStatuses: PermissionDiagnostics.unknownReport()
        )
        let saved = profileStore.lookup(
            application: app,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            providerState: providerState
        ).profile
        let record = try XCTUnwrap(saved?.capabilities.first {
            $0.id == "task.chatgpt-focus-control.accessibility"
        })
        XCTAssertEqual(record.state, .candidate)
        XCTAssertEqual(record.positiveEvidenceCount, 0)
        XCTAssertEqual(record.ambiguousEvidenceCount, 1)
    }

    func testServiceUsesBoundedWindowedTraversalBeforeMatching() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macctl-capability-verification-windowed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let app = testApplication()
        let coverage = AccessibilityTreeCoverage(
            mode: "windowed_pages",
            windowCount: 1,
            pageCount: 1,
            pages: [AccessibilityTreeCoveragePage(
                identityDigest: "window-digest",
                nodeCount: 2,
                truncated: false
            )],
            complete: true
        )
        let inspector = RecordingVerificationTreeInspector(
            report: makeTree(application: app, actions: ["AXPress"], truncated: true),
            windowedReport: makeTree(
                application: app,
                actions: ["AXPress"],
                coverage: coverage
            )
        )
        let profileStore = CapabilityProfileStore(
            directory: root.appendingPathComponent("profiles", isDirectory: true)
        )
        let service = MacCtlService(
            permissionContext: "test",
            resolveApplication: { _ in app },
            resolveApplicationTarget: { selector in
                ApplicationInstanceInfo(
                    application: app,
                    processID: selector.processID ?? app.processID ?? 404
                )
            },
            capabilityProfileStore: profileStore,
            accessibilityTreeInspector: inspector
        )

        let response = service.handle(RequestEnvelope(
            method: "control.capability_verify",
            params: [
                "app": .string(app.name),
                "task": .string("chatgpt-focus-control"),
                "target_fingerprint": .string("chatgpt-surface-v1"),
                "route": .string("accessibility"),
                "selector": .object([
                    "role": .string("AXButton"),
                    "identifier": .string("chatgpt-control")
                ]),
                "postcondition_kind": .string("selected_pane_changed"),
                "postcondition_digest": .string(String(repeating: "f", count: 64))
            ]
        ))

        XCTAssertEqual(response.status, .succeeded)
        let report = try JSONCodec.decode(
            TaskCapabilityVerificationReport.self,
            from: JSONCodec.encode(response.result)
        )
        XCTAssertEqual(report.state, .readyForMeasurement)
        XCTAssertFalse(report.treeTruncated)
        XCTAssertTrue(report.coverageComplete)
        XCTAssertEqual(inspector.treeCallCount, 3)
        XCTAssertEqual(inspector.windowedTreeCallCount, 1)
        let evidence = try XCTUnwrap(response.evidence.first)
        XCTAssertEqual(evidence.metadata["traversal_mode"]?.stringValue, "windowed_pages")
        XCTAssertEqual(evidence.metadata["windowed_attempted"]?.boolValue, true)
        XCTAssertEqual(evidence.metadata["coverage_complete"]?.boolValue, true)
        XCTAssertEqual(evidence.metadata["audit_attempts"]?.intValue, 3)
    }

    private func testApplication() -> AppInfo {
        AppInfo(
            name: "ChatGPT",
            bundleID: "com.openai.codex",
            path: "/Applications/ChatGPT.app",
            isRunning: true,
            processID: 404,
            bundleVersion: "26.803.61601"
        )
    }

    private func makeTree(
        application: AppInfo,
        actions: [String],
        duplicateTarget: Bool = false,
        truncated: Bool = false,
        role: String = "AXButton",
        coverage: AccessibilityTreeCoverage? = nil
    ) -> AccessibilityTreeReport {
        let state = AccessibilityTreeNodeState(
            enabled: true,
            focused: false,
            selected: false,
            expanded: nil,
            visible: true,
            settable: false,
            hasValue: false
        )
        let root = AccessibilityTreeNode(
            path: "0",
            depth: 0,
            role: "AXApplication",
            subrole: nil,
            identifier: nil,
            label: nil,
            actions: [],
            state: state,
            bounds: nil,
            childCount: duplicateTarget ? 2 : 1,
            scrollable: false
        )
        let target = AccessibilityTreeNode(
            path: "0/0",
            depth: 1,
            role: role,
            subrole: nil,
            identifier: "chatgpt-control",
            label: "Continue",
            actions: actions,
            state: state,
            bounds: CGRect(x: 10, y: 10, width: 80, height: 24),
            childCount: 0,
            scrollable: false
        )
        var nodes = [root, target]
        if duplicateTarget {
            nodes.append(AccessibilityTreeNode(
                path: "0/1",
                depth: 1,
                role: role,
                subrole: nil,
                identifier: "chatgpt-control",
                label: "Continue",
                actions: actions,
                state: state,
                bounds: CGRect(x: 100, y: 10, width: 80, height: 24),
                childCount: 0,
                scrollable: false
            ))
        }
        return AccessibilityTreeReport(
            application: application,
            maxNodes: 20,
            maxDepth: 4,
            nodeCount: nodes.count,
            truncated: truncated,
            nodes: nodes,
            identifierMatchCounts: ["chatgpt-control": duplicateTarget ? 2 : 1],
            nameMatchCounts: ["Continue": duplicateTarget ? 2 : 1],
            coverage: coverage
        )
    }
}

private final class RecordingVerificationTreeInspector: AccessibilityTreeInspecting, WindowedAccessibilityTreeInspecting {
    let report: AccessibilityTreeReport
    private let windowedReport: AccessibilityTreeReport?
    private(set) var treeCallCount = 0
    private(set) var windowedTreeCallCount = 0

    init(report: AccessibilityTreeReport, windowedReport: AccessibilityTreeReport? = nil) {
        self.report = report
        self.windowedReport = windowedReport
    }

    func tree(
        pid: pid_t,
        application: AppInfo,
        maxNodes: Int,
        maxDepth: Int
    ) throws -> AccessibilityTreeReport {
        treeCallCount += 1
        return report
    }

    func audit(
        pid: pid_t,
        application: AppInfo,
        manifest: AccessibilityAuditManifest
    ) throws -> AccessibilityAuditReport {
        AccessibilityAuditEngine.audit(tree: report, manifest: manifest)
    }

    func windowedTree(
        pid: pid_t,
        application: AppInfo,
        maxNodesPerPage: Int,
        maxDepth: Int,
        maxWindows: Int,
        maxPages: Int
    ) throws -> AccessibilityTreeReport {
        windowedTreeCallCount += 1
        return windowedReport ?? report
    }
}
