import CoreGraphics
import Foundation
import XCTest
@testable import MacCtlCore

final class SearchActionTests: XCTestCase {
    func testSearchContractIsCodableStructuralReversibleAndInputBound() throws {
        let action = searchAction()
        let decoded = try JSONCodec.decode(ActionSpec.self, from: JSONCodec.encode(action))

        XCTAssertEqual(decoded, action)
        XCTAssertEqual(action.kind, .search)
        XCTAssertEqual(ActionRiskClassifier.classify(action), .reversible)
        XCTAssertTrue(
            TaskPlan(
                id: "search-contract",
                name: "Search",
                summary: "Enter a query in a verified search field",
                steps: [TaskStep(
                    id: "search",
                    action: action,
                    approvalReason: "Search the visible list"
                )]
            ).requiresInputAuthority
        )
    }

    func testAccessibilitySelectorsUseTheRedactedAccessibleNameProjection() {
        XCTAssertEqual(
            AccessibilitySelectorLabel.preferred(
                title: nil,
                description: "Keyboard",
                help: "Settings"
            ),
            "Keyboard"
        )
        XCTAssertTrue(
            AccessibilitySelectorLabel.matchesExact(
                "Keyboard",
                title: nil,
                description: "Keyboard",
                help: nil
            )
        )
        XCTAssertTrue(
            AccessibilitySelectorLabel.contains(
                "board",
                title: nil,
                description: "Keyboard",
                help: nil,
                value: nil
            )
        )
    }

    func testSearchContractRejectsNonMacSurfaceVisualCoordinatesAndAmbiguousSelectors() {
        let validSelector = Selector(role: "AXTextField", subrole: "AXSearchField")
        let parameters: [String: JSONValue] = [
            "text_source": .string("ephemeral"),
            "input_key": .string("query")
        ]

        XCTAssertThrowsError(try SearchActionContract.parameters(for: ActionSpec(
            kind: .search,
            surface: .macDesktop,
            selector: validSelector,
            parameters: parameters
        ))) { error in
            XCTAssertEqual(error as? SearchActionContractError, .invalidSurface)
        }
        XCTAssertThrowsError(try SearchActionContract.validate(selector: Selector(containsText: "Repository")))
        XCTAssertThrowsError(try SearchActionContract.validate(selector: Selector(
            role: "AXTextField",
            subrole: "AXSearchField",
            normalizedX: 0.5,
            normalizedY: 0.5
        )))
        XCTAssertThrowsError(try SearchActionContract.validate(selector: Selector(
            role: "AXTextField",
            subrole: "AXSearchField",
            containsText: "Repository"
        )))
        XCTAssertThrowsError(try SearchActionContract.parameters(for: ActionSpec(
            kind: .search,
            surface: .macApp,
            selector: validSelector,
            parameters: ["text_source": .string("persistent"), "input_key": .string("query")]
        )))
        XCTAssertThrowsError(try SearchActionContract.parameters(for: ActionSpec(
            kind: .search,
            surface: .macApp,
            selector: validSelector,
            parameters: ["text_source": .string("ephemeral"), "input_key": .string("query"), "replace_existing": .string("yes")]
        )))
    }

    func testMacTaskSearchUsesNamedShortcutThenReplacesAndTypesEphemeralQueryOnce() throws {
        let app = searchApp()
        let search = searchFocus(for: app)
        let distant = focusedElement(for: app, role: "AXButton", subrole: "AXPushButton", identifier: "row-41")
        let inspector = SearchFocusInspector([distant, distant, search])
        let harness = try SearchExecutorHarness(
            app: app,
            focusInspector: inspector,
            resolver: SearchFieldResolver()
        )

        let report = try harness.executor.execute(
            action: searchAction(),
            context: searchContext(app: app, lease: harness.lease, query: "sensitive-query")
        )

        XCTAssertEqual(report.route, "keyboard")
        XCTAssertEqual(harness.eventSender.keys, ["tab", "f", "cmd+a", "delete"])
        XCTAssertEqual(harness.textTyper.values, ["sensitive-query"])
        XCTAssertFalse(String(data: try JSONCodec.encode(report), encoding: .utf8)?.contains("sensitive-query") == true)
    }

    func testMacTaskSearchSkipsShortcutWhenFieldAlreadyFocused() throws {
        let app = searchApp()
        let harness = try SearchExecutorHarness(
            app: app,
            focusInspector: SearchFocusInspector([searchFocus(for: app)]),
            resolver: SearchFieldResolver()
        )

        _ = try harness.executor.execute(
            action: searchAction(),
            context: searchContext(app: app, lease: harness.lease, query: "already-focused")
        )

        XCTAssertEqual(harness.eventSender.keys, ["cmd+a", "delete"])
        XCTAssertEqual(harness.textTyper.values, ["already-focused"])
    }

    func testMacTaskSearchCanPreserveExistingTextWhenRequested() throws {
        let app = searchApp()
        let distant = focusedElement(for: app, role: "AXButton", subrole: "AXPushButton", identifier: "row-41")
        let harness = try SearchExecutorHarness(
            app: app,
            focusInspector: SearchFocusInspector([distant, distant, searchFocus(for: app)]),
            resolver: SearchFieldResolver()
        )

        _ = try harness.executor.execute(
            action: searchAction(replaceExisting: false),
            context: searchContext(app: app, lease: harness.lease, query: "append-query")
        )

        XCTAssertEqual(harness.eventSender.keys, ["tab", "f"])
        XCTAssertEqual(harness.textTyper.values, ["append-query"])
    }

    func testMacTaskSearchBlocksMissingOrAmbiguousFieldBeforeAnyDispatch() throws {
        let app = searchApp()
        for failure in [
            AccessibilityControllerError.elementNotFound,
            AccessibilityControllerError.ambiguousMatch(2)
        ] {
            let harness = try SearchExecutorHarness(
                app: app,
                focusInspector: SearchFocusInspector([searchFocus(for: app)]),
                resolver: SearchFieldResolver(failure: failure)
            )

            XCTAssertThrowsError(try harness.executor.execute(
                action: searchAction(),
                context: searchContext(app: app, lease: harness.lease, query: "blocked-query")
            )) { error in
                guard case .blocked(let reason) = error as? TaskActionExecutionError else {
                    return XCTFail("Expected a blocked search action, got \(error)")
                }
                XCTAssertTrue(reason == "search_field_unavailable" || reason == "ambiguous_search_field")
            }
            XCTAssertTrue(harness.eventSender.keys.isEmpty)
            XCTAssertTrue(harness.textTyper.values.isEmpty)
        }
    }

    func testMacTaskSearchStopsOnPermissionFocusOrForegroundFailureWithoutQueryDispatch() throws {
        let app = searchApp()
        let distant = focusedElement(for: app, role: "AXButton", subrole: "AXPushButton", identifier: "row-41")
        let wrong = focusedElement(for: app, role: "AXButton", subrole: "AXPushButton", identifier: "other-field")

        let permissionHarness = try SearchExecutorHarness(
            app: app,
            focusInspector: SearchFocusInspector([distant]),
            resolver: SearchFieldResolver(),
            hasPostEventAccess: false
        )
        XCTAssertThrowsError(try permissionHarness.executor.execute(
            action: searchAction(),
            context: searchContext(app: app, lease: permissionHarness.lease, query: "permission-query")
        )) { error in
            XCTAssertEqual(error as? TaskActionExecutionError, .permissionMissing("Post Events"))
        }
        XCTAssertTrue(permissionHarness.eventSender.keys.isEmpty)
        XCTAssertTrue(permissionHarness.textTyper.values.isEmpty)

        let focusHarness = try SearchExecutorHarness(
            app: app,
            focusInspector: SearchFocusInspector([distant, distant, wrong]),
            resolver: SearchFieldResolver()
        )
        XCTAssertThrowsError(try focusHarness.executor.execute(
            action: searchAction(),
            context: searchContext(app: app, lease: focusHarness.lease, query: "focus-race")
        )) { error in
            guard case .uncertain(let reason) = error as? TaskActionExecutionError else {
                return XCTFail("Expected an indeterminate focus result, got \(error)")
            }
            XCTAssertEqual(reason, "search_focus_not_verified")
        }
        XCTAssertEqual(focusHarness.eventSender.keys, ["tab", "f"])
        XCTAssertTrue(focusHarness.textTyper.values.isEmpty)

        let otherApp = AppInfo(
            name: "Other App",
            bundleID: "com.example.other",
            path: "/Applications/Other App.app",
            isRunning: true,
            processID: 78,
            bundleVersion: nil
        )
        let foregroundHarness = try SearchExecutorHarness(
            app: app,
            focusInspector: SearchFocusInspector([distant]),
            resolver: SearchFieldResolver(),
            foregroundApplication: { otherApp }
        )
        XCTAssertThrowsError(try foregroundHarness.executor.execute(
            action: searchAction(),
            context: searchContext(app: app, lease: foregroundHarness.lease, query: "foreground-race")
        )) { error in
            guard case .uncertain(let reason) = error as? TaskActionExecutionError else {
                return XCTFail("Expected an indeterminate foreground result, got \(error)")
            }
            XCTAssertEqual(reason, "search_shortcut_dispatch")
        }
        XCTAssertTrue(foregroundHarness.eventSender.keys.isEmpty)
        XCTAssertTrue(foregroundHarness.textTyper.values.isEmpty)
    }

    func testTaskRunnerCompletesSearchOnlyAndKeepsEphemeralQueryOutOfCheckpoint() throws {
        let app = searchApp()
        let action = searchAction()
        let plan = TaskPlan(
            id: "search-only",
            name: "Search only",
            summary: "Enter a query without choosing a result",
            steps: [TaskStep(
                id: "search",
                action: action,
                approvalReason: "Search the visible list"
            )]
        )
        XCTAssertTrue(TaskPlanValidator.validate(plan).valid)

        let executor = SearchRecordingTaskActionExecutor()
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-search-task-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpointStore = TaskCheckpointStore(directory: directory)
        let approvals = TaskApprovalStore()
        let runner = TaskRunner(
            checkpointStore: checkpointStore,
            approvalStore: approvals,
            actionExecutor: executor
        )
        let inputs = ["query": "checkpoint-secret"]
        _ = try runner.prepare(plan: plan, ephemeralInputs: inputs)
        let status = try runner.run(
            plan: plan,
            ephemeralInputs: inputs,
            authority: TaskExecutionAuthority(
                leaseToken: "task-lease",
                leaseExpiresAt: Date().addingTimeInterval(30),
                revalidate: { app }
            )
        )

        XCTAssertEqual(status.state, .completed)
        XCTAssertEqual(executor.actions, [.search])
        let checkpoint = try XCTUnwrap(checkpointStore.load(taskID: plan.id))
        let encoded = String(data: try JSONCodec.encode(checkpoint), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("checkpoint-secret"))
    }

    func testTaskRunnerRequiresExplicitFollowUpActionForResultSelection() throws {
        let search = searchAction()
        let resultSelection = ActionSpec(
            kind: .click,
            surface: .macApp,
            selector: Selector(role: "AXButton", title: "Result"),
            parameters: ["approval_reason": .string("Open the selected result")]
        )
        let plan = TaskPlan(
            id: "search-and-select",
            name: "Search and select",
            summary: "Search, then explicitly select a result",
            steps: [
                TaskStep(id: "search", action: search, approvalReason: "Search the visible list"),
                TaskStep(id: "select", action: resultSelection, approvalReason: "Open the selected result")
            ]
        )
        let executor = SearchRecordingTaskActionExecutor()
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-search-follow-up-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let approvals = TaskApprovalStore()
        let runner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: directory),
            approvalStore: approvals,
            actionExecutor: executor
        )
        let inputs = ["query": "result-query"]
        _ = try runner.prepare(plan: plan, ephemeralInputs: inputs)
        let status = try runner.run(
            plan: plan,
            ephemeralInputs: inputs,
            authority: TaskExecutionAuthority(
                leaseToken: "task-lease",
                leaseExpiresAt: Date().addingTimeInterval(30),
                revalidate: { nil }
            )
        )

        XCTAssertEqual(status.state, .completed)
        XCTAssertEqual(executor.actions, [.search, .click])
    }

    func testWorkflowValidatesAndExecutesSearchUnderKeyboardLeaseWithoutPersistingQuery() throws {
        let app = searchApp()
        let distant = focusedElement(for: app, role: "AXButton", subrole: "AXPushButton", identifier: "row-41")
        let harness = try SearchExecutorHarness(
            app: app,
            focusInspector: SearchFocusInspector([distant, distant, distant, searchFocus(for: app)]),
            resolver: SearchFieldResolver()
        )
        let workflow = WorkflowSpec(
            id: "generic-search",
            name: "Generic search",
            summary: "Search a visible native list",
            surface: .macApp,
            actions: [searchAction()]
        )

        let validation = WorkflowRegistry().validate(workflow)
        XCTAssertTrue(validation.valid, validation.errors.joined(separator: "; "))
        XCTAssertEqual(validation.risk, .reversible)

        let report = try harness.workflowExecutor.execute(
            workflow,
            ephemeralInputs: ["query": "workflow-secret"],
            keyboardLeaseToken: harness.lease.token
        )

        XCTAssertEqual(report.completedActions, 1)
        XCTAssertEqual(report.result["searched"]?.boolValue, true)
        XCTAssertEqual(harness.eventSender.keys, ["tab", "f", "cmd+a", "delete"])
        XCTAssertEqual(harness.textTyper.values, ["workflow-secret"])
        XCTAssertFalse(String(data: try JSONCodec.encode(report), encoding: .utf8)?.contains("workflow-secret") == true)
    }

    func testBackgroundTaskSearchUsesAccessibilityWithoutKeyboardFocus() throws {
        let app = searchApp()
        var setValue: (pid_t, String)?
        let resolver = SearchFieldResolver()
        let harness = try SearchExecutorHarness(
            app: app,
            focusInspector: SearchFocusInspector([searchFocus(for: app)]),
            resolver: resolver,
            backgroundSetValue: { pid, _, value in setValue = (pid, value) }
        )

        let report = try harness.executor.execute(
            action: searchAction(),
            context: searchBackgroundContext(app: app, query: "background-query")
        )

        XCTAssertEqual(report.route, "task_input_accessibility_search")
        XCTAssertEqual(setValue?.0, app.processID)
        XCTAssertEqual(setValue?.1, "background-query")
        XCTAssertEqual(resolver.callCount, 1)
        XCTAssertTrue(harness.eventSender.keys.isEmpty)
        XCTAssertTrue(harness.textTyper.values.isEmpty)
    }

    func testBackgroundTaskScrollRequiresAObservedAccessibilityChange() throws {
        let app = searchApp()
        var observedDirection: AccessibilityScrollDirection?
        let harness = try SearchExecutorHarness(
            app: app,
            focusInspector: SearchFocusInspector([searchFocus(for: app)]),
            resolver: SearchFieldResolver(),
            backgroundScroll: { _, application, _, direction, amount in
                observedDirection = direction
                return AccessibilityScrollReport(
                    application: application,
                    targetIdentifier: "results",
                    direction: direction,
                    amount: amount,
                    verification: .passed
                )
            }
        )
        let action = ActionSpec(
            kind: .scroll,
            surface: .macApp,
            selector: Selector(role: "AXScrollArea", identifier: "results"),
            parameters: ["direction": .string("down"), "amount": .number(2)]
        )

        let report = try harness.executor.execute(
            action: action,
            context: searchBackgroundContext(app: app, query: "")
        )

        XCTAssertEqual(report.route, "task_input_accessibility_scroll")
        XCTAssertEqual(observedDirection, .down)
    }
}

private func searchAction(replaceExisting: Bool = true) -> ActionSpec {
    ActionSpec(
        kind: .search,
        surface: .macApp,
        selector: Selector(role: "AXTextField", subrole: "AXSearchField"),
        parameters: [
            "text_source": .string("ephemeral"),
            "input_key": .string("query"),
            "replace_existing": .bool(replaceExisting),
            "approval_reason": .string("Search the visible list")
        ]
    )
}

private func searchApp() -> AppInfo {
    AppInfo(
        name: "Searchable List",
        bundleID: "com.example.searchable-list",
        path: "/Applications/Searchable List.app",
        isRunning: true,
        processID: 77,
        bundleVersion: "1"
    )
}

private func focusedElement(
    for app: AppInfo,
    role: String,
    subrole: String?,
    identifier: String?
) -> FocusedElementSnapshot {
    FocusedElementSnapshot(
        targetApplication: app,
        role: role,
        subrole: subrole,
        identifier: identifier,
        title: nil
    )
}

private func searchFocus(for app: AppInfo) -> FocusedElementSnapshot {
    focusedElement(for: app, role: "AXTextField", subrole: "AXSearchField", identifier: nil)
}

private func searchContext(
    app: AppInfo,
    lease: KeyboardDriveLease,
    query: String
) -> TaskActionContext {
    TaskActionContext(
        taskID: "search-test",
        stepID: "search",
        target: nil,
        focusPolicy: .foreground,
        ephemeralInputs: ["query": query],
        deadline: Date().addingTimeInterval(30),
        authority: TaskExecutionAuthority(
            leaseToken: lease.token,
            leaseExpiresAt: lease.expiresAt,
            revalidate: { app }
        )
    )
}

private func searchBackgroundContext(app: AppInfo, query: String) -> TaskActionContext {
    let expiresAt = Date().addingTimeInterval(30)
    let channel = TaskInputChannel(
        taskID: "background-search-test",
        planDigest: "background-search-digest",
        focusPolicy: .background,
        targetApplication: app,
        routes: [.accessibility],
        expiresAt: expiresAt
    )
    return TaskActionContext(
        taskID: channel.taskID,
        stepID: "semantic-action",
        target: TaskTargetIdentity(application: app.name, processID: app.processID),
        focusPolicy: .background,
        planDigest: channel.planDigest,
        ephemeralInputs: ["query": query],
        deadline: expiresAt,
        authority: TaskExecutionAuthority(
            leaseToken: nil,
            leaseExpiresAt: expiresAt,
            inputChannel: channel,
            revalidate: { app }
        )
    )
}

private final class SearchRecordingKeyboardEventSender: KeyboardEventSending {
    private(set) var keys: [String] = []

    func send(keySpecification: String) throws {
        keys.append(keySpecification)
    }
}

private struct SearchKeyboardPreferenceStore: KeyboardPreferenceStore {
    let enabled: Bool

    var fullKeyboardAccessEnabled: Bool { enabled }

    func enableFullKeyboardAccess() throws {}
}

private final class SearchFocusInspector: FocusedElementInspecting {
    private let snapshots: [FocusedElementSnapshot]
    private let failure: Error?
    private var index = 0

    init(_ snapshots: [FocusedElementSnapshot], failure: Error? = nil) {
        self.snapshots = snapshots
        self.failure = failure
    }

    func focusedElementSnapshot(pid: pid_t, application: AppInfo) throws -> FocusedElementSnapshot {
        if let failure { throw failure }
        guard let last = snapshots.last else { throw AccessibilityControllerError.unreadableFocus }
        let result = index < snapshots.count ? snapshots[index] : last
        index += 1
        return result
    }
}

private final class SearchFieldResolver: SearchFieldResolving {
    private let failure: AccessibilityControllerError?
    private(set) var callCount = 0

    init(failure: AccessibilityControllerError? = nil) {
        self.failure = failure
    }

    func requireUniqueSearchField(pid: pid_t, selector: MacCtlCore.Selector) throws {
        callCount += 1
        if let failure { throw failure }
    }
}

private final class SearchTextTyper: SearchTextTyping {
    private(set) var values: [String] = []

    func type(_ text: String) throws {
        values.append(text)
    }
}

private final class SearchAccessibilityActionPerformer: AccessibilityActionPerforming {
    @discardableResult
    func press(pid: pid_t, selector: MacCtlCore.Selector) throws -> CGRect { .zero }
}

private final class SearchVisualActionPerformer: VisualActionPerforming {
    @discardableResult
    func activate(selector: MacCtlCore.Selector, application: AppInfo) throws -> CGRect { .zero }
}

private final class SearchExecutorHarness {
    let app: AppInfo
    let eventSender: SearchRecordingKeyboardEventSender
    let textTyper: SearchTextTyper
    let lease: KeyboardDriveLease
    let executor: MacTaskActionExecutor
    let workflowExecutor: WorkflowExecutor

    init(
        app: AppInfo,
        focusInspector: SearchFocusInspector,
        resolver: SearchFieldResolver,
        foregroundApplication: @escaping () -> AppInfo? = { nil },
        hasPostEventAccess: Bool = true,
        fullKeyboardAccess: Bool = true,
        backgroundSetValue: ((pid_t, MacCtlCore.Selector, String) throws -> Void)? = nil,
        backgroundScroll: ((
            pid_t,
            AppInfo,
            MacCtlCore.Selector,
            AccessibilityScrollDirection,
            Int
        ) throws -> AccessibilityScrollReport)? = nil
    ) throws {
        self.app = app
        eventSender = SearchRecordingKeyboardEventSender()
        textTyper = SearchTextTyper()
        let preferences = SearchKeyboardPreferenceStore(enabled: fullKeyboardAccess)
        let keyboardDriveStore = KeyboardDriveStore()
        let keyboardAccessController = KeyboardAccessController(
            eventSender: eventSender,
            preferenceStore: preferences
        )
        let foreground = foregroundApplication() == nil ? { app } : foregroundApplication
        let controlSession = ControlSession(
            keyboardDriveStore: keyboardDriveStore,
            focusedElementInspector: focusInspector,
            foregroundApplication: foreground,
            hasPostEventAccess: { hasPostEventAccess },
            fullKeyboardAccessEnabled: { fullKeyboardAccess },
            verifier: ControlStateVerifier(sleep: { _ in }, eventMonitor: nil),
            postActionTimeout: 0.001
        )
        let semanticActionRouter = SemanticActionRouter(
            session: controlSession,
            keyboardAccessController: keyboardAccessController,
            accessibilityActionController: SearchAccessibilityActionPerformer(),
            visualActionController: SearchVisualActionPerformer()
        )
        lease = try keyboardDriveStore.acquire(
            scope: .app,
            application: app,
            seconds: 30,
            confirm: true
        )
        let accessibilityController = AccessibilityController()
        executor = MacTaskActionExecutor(
            appController: AppController(),
            accessibilityController: accessibilityController,
            inputController: InputController(),
            keyboardAccessController: keyboardAccessController,
            semanticActionRouter: semanticActionRouter,
            adapterRegistry: AppAdapterRegistry(),
            foregroundApplication: foreground,
            searchFieldResolver: resolver,
            focusedElementInspector: focusInspector,
            searchTextTyper: textTyper,
            backgroundSetValue: backgroundSetValue,
            backgroundScroll: backgroundScroll
        )
        workflowExecutor = WorkflowExecutor(
            appController: AppController(),
            accessibilityController: accessibilityController,
            inputController: InputController(),
            keyboardAccessController: keyboardAccessController,
            keyboardDriveStore: keyboardDriveStore,
            controlSession: controlSession,
            semanticActionRouter: semanticActionRouter,
            searchFieldResolver: resolver,
            focusedElementInspector: focusInspector,
            searchTextTyper: textTyper,
            foregroundApplication: foreground,
            hasPostEventAccess: { hasPostEventAccess },
            fullKeyboardAccessEnabled: { fullKeyboardAccess }
        )
    }
}

private final class SearchRecordingTaskActionExecutor: TaskActionExecuting {
    private(set) var actions: [ActionKind] = []

    func execute(action: ActionSpec, context: TaskActionContext) throws -> TaskActionExecutionReport {
        actions.append(action.kind)
        return TaskActionExecutionReport(route: action.kind.rawValue)
    }

    func evaluate(predicate: TaskPredicate, context: TaskActionContext) throws -> Bool {
        true
    }
}
