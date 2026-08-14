import XCTest
@testable import MacCtlCore

final class ExactTargetingTests: XCTestCase {
    func testAppControllerListsDistinctInstancesAndFailsClosedOnAmbiguousApp() throws {
        let controller = AppController(runningApplicationProvider: {
            [
                self.descriptor(pid: 101, launchedAt: 1_000),
                self.descriptor(pid: 202, launchedAt: 2_000)
            ]
        })

        let instances = controller.listRunningInstances(matching: "Code")
        XCTAssertEqual(instances.map(\.processID), [101, 202])
        XCTAssertNotEqual(instances[0].instanceRef, instances[1].instanceRef)

        XCTAssertThrowsError(try controller.resolveRunningTarget(
            ApplicationTargetSelector(application: "Code")
        )) { error in
            XCTAssertEqual(error as? ApplicationTargetResolutionError, .targetAmbiguous(2))
        }
    }

    func testAppControllerUsesConjunctivePIDAndInstanceReference() throws {
        let controller = AppController(runningApplicationProvider: {
            [
                self.descriptor(pid: 101, launchedAt: 1_000),
                self.descriptor(pid: 202, launchedAt: 2_000)
            ]
        })
        let expected = try XCTUnwrap(
            controller.listRunningInstances(matching: "com.microsoft.VSCode")
                .first(where: { $0.processID == 202 })
        )

        XCTAssertEqual(
            try controller.resolveRunningTarget(ApplicationTargetSelector(
                application: "Visual Studio Code",
                processID: 202,
                instanceRef: expected.instanceRef
            )),
            expected
        )

        XCTAssertThrowsError(try controller.resolveRunningTarget(ApplicationTargetSelector(
            application: "Visual Studio Code",
            processID: 202,
            instanceRef: "stale-instance"
        ))) { error in
            XCTAssertEqual(error as? ApplicationTargetResolutionError, .targetChanged)
        }
    }

    func testInstanceReferenceIsUnavailableWithoutLaunchIdentity() {
        let controller = AppController(runningApplicationProvider: {
            [self.descriptor(pid: 303, launchedAt: nil)]
        })
        XCTAssertNil(controller.listRunningInstances(matching: "Code").first?.instanceRef)
    }

    func testForegroundApplicationPreservesExactPIDAmongSameBundleProcesses() throws {
        let first = descriptor(pid: 101, launchedAt: 1_000)
        let frontmost = descriptor(pid: 202, launchedAt: 2_000)
        let controller = AppController(
            runningApplicationProvider: { [first, frontmost] },
            foregroundApplicationProvider: { frontmost }
        )

        let observed = try XCTUnwrap(controller.foregroundApplication())
        XCTAssertEqual(observed.bundleID, first.bundleID)
        XCTAssertEqual(observed.path, first.path)
        XCTAssertEqual(observed.processID, frontmost.processID)
    }

    func testAccessibilityTreeUsesExactProcessAndWindowReference() throws {
        let instance = ApplicationInstanceInfo(descriptor: descriptor(pid: 404, launchedAt: 4_000))
        let inspector = RecordingExactTreeInspector(report: treeReport(application: instance.application))
        let service = MacCtlService(
            permissionContext: "test",
            resolveApplicationTarget: { selector in
                XCTAssertEqual(selector.processID, 404)
                XCTAssertEqual(selector.instanceRef, instance.instanceRef)
                XCTAssertEqual(selector.windowRef, "window-ref")
                return instance
            },
            accessibilityTreeInspector: inspector
        )

        let response = service.handle(RequestEnvelope(method: "accessibility.tree", params: [
            "app": .string("Code"),
            "process_id": .number(404),
            "instance_ref": .string(try XCTUnwrap(instance.instanceRef)),
            "window_ref": .string("window-ref")
        ]))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(inspector.targetedTreeCount, 1)
        XCTAssertEqual(inspector.regularTreeCount, 0)
        XCTAssertEqual(inspector.lastPID, 404)
        XCTAssertEqual(inspector.lastWindowRef, "window-ref")
    }

    func testServicePublishesAllMatchingApplicationInstances() throws {
        let instances = [
            ApplicationInstanceInfo(descriptor: descriptor(pid: 401, launchedAt: 4_001)),
            ApplicationInstanceInfo(descriptor: descriptor(pid: 402, launchedAt: 4_002))
        ]
        let service = MacCtlService(
            permissionContext: "test",
            listApplicationInstances: { application in
                XCTAssertEqual(application, "Code")
                return instances
            }
        )

        let response = service.handle(RequestEnvelope(
            method: "app.instances",
            params: ["app": .string("Code")]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(response.result["instances"]?.arrayValue?.count, 2)
        XCTAssertEqual(
            response.result["instances"]?.arrayValue?.compactMap {
                $0.objectValue?["process_id"]?.doubleValue
            },
            [401, 402]
        )
    }

    func testChangedInstanceStopsBeforeAccessibilityInspection() {
        let inspector = RecordingExactTreeInspector(report: treeReport(application: fixtureApplication(pid: 505)))
        let service = MacCtlService(
            permissionContext: "test",
            resolveApplicationTarget: { _ in throw ApplicationTargetResolutionError.targetChanged },
            accessibilityTreeInspector: inspector
        )

        let response = service.handle(RequestEnvelope(method: "accessibility.tree", params: [
            "app": .string("Code"),
            "process_id": .number(505),
            "instance_ref": .string("stale"),
            "window_ref": .string("window-ref")
        ]))

        XCTAssertEqual(response.status, .blocked)
        XCTAssertEqual(response.outcome?.state, .targetChanged)
        XCTAssertEqual(response.error?.details["failure_class"]?.stringValue, "target_changed")
        XCTAssertEqual(inspector.targetedTreeCount, 0)
        XCTAssertEqual(inspector.regularTreeCount, 0)
    }

    func testWindowTargetFailuresRemainTypedAndDoNotWidenScope() {
        let application = fixtureApplication(pid: 515)
        let instance = ApplicationInstanceInfo(application: application, processID: 515)

        let missingInspector = RecordingExactTreeInspector(
            report: treeReport(application: application),
            targetedError: AccessibilityControllerError.windowNotFound
        )
        let missingService = MacCtlService(
            permissionContext: "test",
            resolveApplicationTarget: { _ in instance },
            accessibilityTreeInspector: missingInspector
        )
        let missing = missingService.handle(RequestEnvelope(method: "accessibility.tree", params: [
            "app": .string("Code"),
            "process_id": .number(515),
            "window_ref": .string("gone")
        ]))
        XCTAssertEqual(missing.outcome?.state, .targetMissing)
        XCTAssertEqual(missing.error?.details["failure_class"]?.stringValue, "target_missing")
        XCTAssertEqual(missingInspector.regularTreeCount, 0)

        let ambiguousInspector = RecordingExactTreeInspector(
            report: treeReport(application: application),
            targetedError: AccessibilityControllerError.ambiguousWindowMatch(2)
        )
        let ambiguousService = MacCtlService(
            permissionContext: "test",
            resolveApplicationTarget: { _ in instance },
            accessibilityTreeInspector: ambiguousInspector
        )
        let ambiguous = ambiguousService.handle(RequestEnvelope(method: "accessibility.tree", params: [
            "app": .string("Code"),
            "process_id": .number(515),
            "window_ref": .string("duplicate")
        ]))
        XCTAssertEqual(ambiguous.outcome?.state, .targetAmbiguous)
        XCTAssertEqual(ambiguous.error?.details["candidate_count"]?.doubleValue, 2)
        XCTAssertEqual(ambiguousInspector.regularTreeCount, 0)
    }

    func testWindowListAndInspectStayBoundToResolvedProcess() throws {
        let instance = ApplicationInstanceInfo(descriptor: descriptor(pid: 606, launchedAt: 6_000))
        let controller = RecordingNativeWindowTargetController(pid: 606, windowRef: "window-606")
        let service = MacCtlService(
            permissionContext: "test",
            nativeWindowController: controller,
            resolveApplicationTarget: { _ in instance }
        )

        let listed = service.handle(RequestEnvelope(method: "window.list", params: [
            "app": .string("Code"),
            "process_id": .number(606)
        ]))
        XCTAssertEqual(listed.status, .succeeded)
        XCTAssertEqual(controller.listPIDs, [606])

        let inspected = service.handle(RequestEnvelope(method: "window.inspect", params: [
            "app": .string("Code"),
            "process_id": .number(606),
            "window_ref": .string("window-606")
        ]))
        XCTAssertEqual(inspected.status, .succeeded)
        XCTAssertEqual(controller.inspectedTargets.count, 1)
        XCTAssertEqual(controller.inspectedTargets.first?.pid, 606)
        XCTAssertEqual(controller.inspectedTargets.first?.windowRef, "window-606")
        XCTAssertEqual(controller.focusedWindowCount, 0)
    }

    func testExactBackgroundTaskIsRejectedWithoutMutatingEitherSameBundleProcess() throws {
        let checkpointDirectory = URL(
            fileURLWithPath: "/private/tmp/macctl-exact-task-checkpoints-\(UUID().uuidString)"
        )
        let receiptDirectory = URL(
            fileURLWithPath: "/private/tmp/macctl-exact-task-receipts-\(UUID().uuidString)"
        )
        defer {
            try? FileManager.default.removeItem(at: checkpointDirectory)
            try? FileManager.default.removeItem(at: receiptDirectory)
        }
        let targetInstance = ApplicationInstanceInfo(descriptor: descriptor(pid: 706, launchedAt: 7_000))
        let instanceRef = try XCTUnwrap(targetInstance.instanceRef)
        let unrelatedForeground = fixtureApplication(pid: 707)
        let controller = RecordingNativeWindowTargetController(pid: 706, windowRef: "window-706")
        let approvals = TaskApprovalStore()
        let checkpoints = TaskCheckpointStore(directory: checkpointDirectory)
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            taskApprovalStore: approvals,
            taskCheckpointStore: checkpoints,
            taskActionExecutor: PassingExactTaskExecutor(),
            nativeWindowController: controller,
            foregroundApplication: { unrelatedForeground },
            resolveApplication: { _ in throw ApplicationTargetResolutionError.targetAmbiguous(2) },
            resolveApplicationTarget: { selector in
                XCTAssertEqual(selector.processID, 706)
                XCTAssertEqual(selector.instanceRef, instanceRef)
                XCTAssertEqual(selector.windowRef, "window-706")
                return targetInstance
            },
            hasPostEventAccess: { true }
        )
        let plan = TaskPlan(
            id: "exact.same-bundle",
            name: "Exact same-bundle input",
            summary: "Target only the disposable Code window",
            focusPolicy: .background,
            steps: [TaskStep(
                id: "open-problems",
                action: ActionSpec(
                    kind: .key,
                    surface: .macApp,
                    parameters: ["key": .string("cmd+shift+m")]
                ),
                target: TaskTargetIdentity(
                    application: "Code",
                    processID: 706,
                    instanceRef: instanceRef,
                    windowRef: "window-706"
                ),
                postconditions: [TaskPredicate(
                    kind: .elementExists,
                    selector: Selector(role: "AXStaticText", containsText: "Type mismatch")
                )],
                risk: .sensitive,
                approvalReason: "Open Problems only in the disposable Code window",
                recovery: TaskRecoveryPolicy(mode: "strict", maxAttempts: 1)
            )]
        )
        let planValue = try JSONValue.fromEncodable(plan)
        let prepared = service.handle(RequestEnvelope(
            method: "task.prepare",
            params: ["plan": planValue]
        ))
        XCTAssertEqual(prepared.status, .failed)
        XCTAssertEqual(prepared.error?.code, MacCtlErrorCode.taskInvalidPlan.rawValue)
        XCTAssertEqual(controller.activationCount, 0)
        XCTAssertTrue(controller.inspectedTargets.isEmpty)
    }

    func testExactForegroundTaskActivatesAndBindsPIDAndWindowUnderLease() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-exact-foreground-receipts-\(UUID().uuidString)")
        let checkpointDirectory = URL(fileURLWithPath: "/private/tmp/macctl-exact-foreground-checkpoints-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: receiptDirectory)
            try? FileManager.default.removeItem(at: checkpointDirectory)
        }
        let targetPID: pid_t = 709
        let targetInstance = ApplicationInstanceInfo(descriptor: descriptor(pid: targetPID, launchedAt: 709))
        let instanceRef = try XCTUnwrap(targetInstance.instanceRef)
        let target = targetInstance.application
        let controller = RecordingNativeWindowTargetController(pid: targetPID, windowRef: "window-709")
        let keyboardStore = KeyboardDriveStore()
        let keyboard = KeyboardAccessController(preferenceStore: EnabledExactKeyboardPreferences())
        let controlSession = ControlSession(
            keyboardDriveStore: keyboardStore,
            focusedElementInspector: EmptyExactFocusInspector(),
            foregroundApplication: { target },
            hasPostEventAccess: { true },
            fullKeyboardAccessEnabled: { true },
            postActionTimeout: 0
        )
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            keyboardAccessController: keyboard,
            keyboardDriveStore: keyboardStore,
            taskCheckpointStore: TaskCheckpointStore(directory: checkpointDirectory),
            taskActionExecutor: PassingExactTaskExecutor(),
            controlSession: controlSession,
            nativeWindowController: controller,
            foregroundApplication: { target },
            resolveApplication: { _ in throw ApplicationTargetResolutionError.targetAmbiguous(2) },
            resolveApplicationTarget: { selector in
                XCTAssertEqual(selector.processID, targetPID)
                XCTAssertEqual(selector.instanceRef, instanceRef)
                XCTAssertEqual(selector.windowRef, "window-709")
                return targetInstance
            },
            hasPostEventAccess: { true }
        )
        let plan = TaskPlan(
            id: "exact.foreground",
            name: "Exact foreground input",
            summary: "Activate only the bound Code window and send one verified key",
            focusPolicy: .foreground,
            steps: [TaskStep(
                id: "open-problems",
                action: ActionSpec(
                    kind: .key,
                    surface: .macApp,
                    parameters: ["key": .string("cmd+shift+m")]
                ),
                target: TaskTargetIdentity(
                    application: "Code",
                    processID: targetPID,
                    instanceRef: instanceRef,
                    windowRef: "window-709"
                ),
                postconditions: [TaskPredicate(
                    kind: .elementExists,
                    selector: Selector(containsText: "Type mismatch")
                )],
                risk: .sensitive,
                approvalReason: "Open Problems only in the disposable Code window",
                recovery: TaskRecoveryPolicy(mode: "strict", maxAttempts: 1)
            )]
        )
        let planValue = try JSONValue.fromEncodable(plan)
        let prepared = service.handle(RequestEnvelope(method: "task.prepare", params: ["plan": planValue]))
        let token = try XCTUnwrap(prepared.result["approval"]?["token"]?.stringValue)
        XCTAssertEqual(service.handle(RequestEnvelope(
            method: "approval.approve",
            params: ["token": .string(token)]
        )).status, .succeeded)

        let run = service.handle(RequestEnvelope(
            method: "task.run",
            params: ["plan": planValue, "approval_token": .string(token)]
        ))

        XCTAssertEqual(run.status, .succeeded, String(describing: run.error))
        XCTAssertEqual(controller.activationCount, 1)
        XCTAssertEqual(
            run.result["input_channel"]?["routes"]?.arrayValue?.compactMap(\.stringValue),
            ["exact_foreground"]
        )
        XCTAssertEqual(run.result["input_channel"]?["target"]?["process_id"]?.doubleValue, 709)
        XCTAssertEqual(run.result["input_channel"]?["target"]?["window_ref"]?.stringValue, "window-709")
        XCTAssertNil(keyboardStore.activeLease())
    }

    private func descriptor(pid: Int32, launchedAt: TimeInterval?) -> RunningApplicationDescriptor {
        RunningApplicationDescriptor(
            name: "Code",
            bundleID: "com.microsoft.VSCode",
            path: "/Applications/Visual Studio Code.app",
            processID: pid,
            launchDate: launchedAt.map(Date.init(timeIntervalSince1970:)),
            bundleVersion: "1.0"
        )
    }

    private func fixtureApplication(pid: Int32) -> AppInfo {
        AppInfo(
            name: "Visual Studio Code",
            bundleID: "com.microsoft.VSCode",
            path: "/Applications/Visual Studio Code.app",
            isRunning: true,
            processID: pid,
            bundleVersion: "1.0"
        )
    }

    private func treeReport(application: AppInfo) -> AccessibilityTreeReport {
        AccessibilityTreeReport(
            application: application,
            maxNodes: 10,
            maxDepth: 2,
            nodeCount: 0,
            truncated: false,
            nodes: [],
            identifierMatchCounts: [:],
            nameMatchCounts: [:]
        )
    }
}

private final class PassingExactTaskExecutor: TaskActionExecuting {
    func execute(action: ActionSpec, context: TaskActionContext) throws -> TaskActionExecutionReport {
        TaskActionExecutionReport(route: "fixture_exact_process")
    }

    func evaluate(predicate: TaskPredicate, context: TaskActionContext) throws -> Bool {
        true
    }
}

private final class RecordingExactTreeInspector: AccessibilityTreeInspecting,
    WindowTargetedAccessibilityTreeInspecting {
    let report: AccessibilityTreeReport
    let targetedError: Error?
    var regularTreeCount = 0
    var targetedTreeCount = 0
    var lastPID: pid_t?
    var lastWindowRef: String?

    init(report: AccessibilityTreeReport, targetedError: Error? = nil) {
        self.report = report
        self.targetedError = targetedError
    }

    func tree(
        pid: pid_t,
        application: AppInfo,
        maxNodes: Int,
        maxDepth: Int
    ) throws -> AccessibilityTreeReport {
        regularTreeCount += 1
        lastPID = pid
        return report
    }

    func tree(
        pid: pid_t,
        application: AppInfo,
        windowRef: String,
        maxNodes: Int,
        maxDepth: Int
    ) throws -> AccessibilityTreeReport {
        targetedTreeCount += 1
        lastPID = pid
        lastWindowRef = windowRef
        if let targetedError { throw targetedError }
        return report
    }

    func audit(
        pid: pid_t,
        application: AppInfo,
        manifest: AccessibilityAuditManifest
    ) throws -> AccessibilityAuditReport {
        AccessibilityAuditEngine.audit(tree: report, manifest: manifest)
    }
}

private final class RecordingNativeWindowTargetController: NativeWindowControlling,
    NativeWindowTargetInspecting, NativeWindowForegroundActivating {
    let pid: pid_t
    let windowRef: String
    var listPIDs: [pid_t] = []
    var inspectedTargets: [(pid: pid_t, windowRef: String)] = []
    var focusedWindowCount = 0
    var activationCount = 0

    init(pid: pid_t, windowRef: String) {
        self.pid = pid
        self.windowRef = windowRef
    }

    func listWindows(pid: pid_t, displays: [NativeWindowDisplay]) throws -> NativeWindowTargetCatalog {
        listPIDs.append(pid)
        return NativeWindowTargetCatalog(
            processID: pid,
            windows: [targetSnapshot(pid: pid)],
            omittedWindowCount: 0
        )
    }

    func inspectWindow(
        pid: pid_t,
        windowRef: String,
        displays: [NativeWindowDisplay]
    ) throws -> NativeWindowTargetSnapshot {
        inspectedTargets.append((pid, windowRef))
        guard pid == self.pid, windowRef == self.windowRef else {
            throw NativeWindowControlError.targetMissing
        }
        return targetSnapshot(pid: pid)
    }

    func focusedWindow(pid: pid_t, displays: [NativeWindowDisplay]) throws -> NativeWindowSnapshot {
        focusedWindowCount += 1
        return snapshot(pid: pid)
    }

    func activateWindow(
        pid: pid_t,
        windowRef: String,
        displays: [NativeWindowDisplay]
    ) throws -> NativeWindowTargetSnapshot {
        activationCount += 1
        return try inspectWindow(pid: pid, windowRef: windowRef, displays: displays)
    }

    func setFrame(
        pid: pid_t,
        identityDigest: String,
        frame: NativeWindowFrame,
        displays: [NativeWindowDisplay]
    ) throws -> NativeWindowSnapshot {
        throw NativeWindowControlError.targetUnsupported("test_read_only")
    }

    private func targetSnapshot(pid: pid_t) -> NativeWindowTargetSnapshot {
        NativeWindowTargetSnapshot(
            snapshot: snapshot(pid: pid),
            unique: true,
            focused: true,
            visible: true
        )
    }

    private func snapshot(pid: pid_t) -> NativeWindowSnapshot {
        NativeWindowSnapshot(
            processID: pid,
            identityDigest: windowRef,
            frame: NativeWindowFrame(x: 0, y: 0, width: 800, height: 600),
            displayID: 1,
            movable: true,
            resizable: true,
            minimized: false,
            fullscreen: false
        )
    }
}

private struct EnabledExactKeyboardPreferences: KeyboardPreferenceStore {
    var fullKeyboardAccessEnabled: Bool { true }
    func enableFullKeyboardAccess() throws {}
}

private struct EmptyExactFocusInspector: FocusedElementInspecting {
    func focusedElementSnapshot(pid: pid_t, application: AppInfo) throws -> FocusedElementSnapshot {
        FocusedElementSnapshot(
            targetApplication: application,
            role: nil,
            subrole: nil,
            identifier: nil,
            title: nil
        )
    }
}
