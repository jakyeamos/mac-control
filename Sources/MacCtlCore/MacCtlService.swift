import Foundation

private struct RouteSelectionResolution {
    let report: RouteSelectionReport?
    let cacheHit: Bool
}

private struct ControlActionExecution {
    let report: SemanticActionReport
    let foregroundFastPathUsed: Bool
    let routeSelectionCacheHit: Bool
}

private struct RouteSelectionCacheEntry {
    let leaseToken: String
    let application: AppInfo
    let taskID: String
    let targetFingerprint: String
    let manifest: WarmPathManifest
}

private struct ControlBatchExecutionError: Error, LocalizedError {
    let failedIndex: Int
    let completedCount: Int
    let cause: String

    var errorDescription: String? {
        "control.batch stopped at action \(failedIndex) after \(completedCount) completed action(s): \(cause)"
    }

    var details: [String: JSONValue] {
        [
            "failed_index": .number(Double(failedIndex)),
            "completed_count": .number(Double(completedCount)),
            "lease_released": .bool(true),
            "cause": .string(cause),
            "fresh_state_required": .bool(true),
            "recommended_provider": .string("mac_control")
        ]
    }
}

private enum RouteBenchmarkError: Error, LocalizedError {
    case verificationFailed(route: ControlActionRoute, sample: Int, state: ControlVerificationState)
    case scrollVerificationFailed(route: ControlActionRoute, sample: Int, state: ScrollVerificationState)
    case routeMismatch(expected: ControlActionRoute, actual: ControlActionRoute)

    var errorDescription: String? {
        switch self {
        case let .verificationFailed(route, sample, state):
            return "Daemon benchmark sample \(sample) for \(route.rawValue) did not reach verified state (observed \(state.rawValue)); no route manifest was written"
        case let .scrollVerificationFailed(route, sample, state):
            return "Daemon benchmark sample \(sample) for \(route.rawValue) did not reach verified state (observed \(state.rawValue)); no route manifest was written"
        case let .routeMismatch(expected, actual):
            return "Daemon benchmark requested \(expected.rawValue) but executed \(actual.rawValue); no route manifest was written"
        }
    }
}

private struct SemanticScrollFailure: Error, LocalizedError {
    let failureClass: SemanticScrollFailureClass
    let message: String
    let recommendedProvider: ScrollFallbackRoute?
    let freshStateRequired: Bool
    let fallbackAllowed: Bool
    let requestedFallback: ScrollFallbackRoute?
    let localFallbackDispatched: Bool
    let localFallbackVerification: ScrollVerificationState?

    var errorDescription: String? { message }

    var details: [String: JSONValue] {
        var details: [String: JSONValue] = [
            "failure_class": .string(failureClass.rawValue),
            "fallback_allowed": .bool(fallbackAllowed),
            "fresh_state_required": .bool(freshStateRequired),
            "local_fallback_dispatched": .bool(localFallbackDispatched)
        ]
        if let recommendedProvider {
            details["recommended_provider"] = .string(recommendedProvider.rawValue)
        }
        if let requestedFallback {
            details["requested_fallback"] = .string(requestedFallback.rawValue)
        }
        if let localFallbackVerification {
            details["local_fallback_verification"] = .string(localFallbackVerification.rawValue)
        }
        return details
    }
}

private enum SemanticScrollExecution {
    case accessibility(AccessibilityScrollReport)
    case input(InputScrollReport, from: SemanticScrollFailureClass)
}

private struct CapabilityAuditExecution {
    let profile: CapabilityAuditProfile
    let initialMaxNodes: Int
    let initialMaxDepth: Int
    let effectiveMaxNodes: Int
    let effectiveMaxDepth: Int
    let attempts: Int
    let traversalMode: String
    let coverage: AccessibilityTreeCoverage?
    let windowedAttempted: Bool

    var adaptiveRetry: Bool { attempts > 1 }
    var coverageComplete: Bool {
        coverage?.complete ?? !profile.treeTruncated
    }
    var exhausted: Bool {
        profile.treeTruncated
            && effectiveMaxNodes == CapabilityAuditBounds.maximumNodes
            && effectiveMaxDepth == CapabilityAuditBounds.maximumDepth
    }
}

public final class MacCtlService {
    private struct ActiveControlExecution {
        let executionID: String
        let taskID: String?
        let summary: String
        let applicationName: String?
        let leaseToken: String
        let leaseOwnedByDaemon: Bool
        let physicalInputMode: KeyboardPhysicalInputMode
        let acquiredAt: Date
        let expiresAt: Date
        var stopping: Bool

        var snapshot: ControlCenterExecution {
            ControlCenterExecution(
                executionID: executionID,
                taskID: taskID,
                summary: summary,
                applicationName: applicationName,
                physicalInputMode: physicalInputMode,
                acquiredAt: acquiredAt,
                expiresAt: expiresAt,
                stopping: stopping
            )
        }
    }

    private struct TaskAuthorityReservation {
        let authority: TaskExecutionAuthority?
        let lease: KeyboardDriveLease?
        let ownedByDaemon: Bool
    }

    private struct WorkflowLeaseReservation {
        let lease: KeyboardDriveLease?
        let ownedByDaemon: Bool
    }

    private let appController: AppController
    private let workflowRegistry: WorkflowRegistry
    private let workflowExecutor: WorkflowExecutor
    private let approvalStore: ApprovalStore
    private let keyboardAccessController: KeyboardAccessController
    private let keyboardDriveStore: KeyboardDriveStore
    private let taskApprovalStore: TaskApprovalStore
    private let externalApprovalStore: ExternalApprovalStore
    private let taskCheckpointStore: TaskCheckpointStore
    private let taskRunner: TaskRunner
    private let adapterRegistry: AppAdapterRegistry
    private let targetInspector: ControlTargetInspecting
    private let focusedElementInspector: FocusedElementInspecting
    private let accessibilityTreeInspector: AccessibilityTreeInspecting
    private let accessibilityScrollPerformer: AccessibilityScrollPerforming
    private let inputScrollPerformer: InputScrollPerforming
    private let warmPathStore: WarmPathStore
    private let capabilityProfileStore: CapabilityProfileStore
    private let capabilityAuditBatchStore: CapabilityAuditBatchStore
    private let shortcutEngine: ShortcutEngine
    private let controlSession: ControlSession
    private let semanticActionRouter: SemanticActionRouter
    private let foregroundApplication: () -> AppInfo?
    private let resolveApplication: (String) throws -> AppInfo
    private let activateApplication: (String) throws -> AppInfo
    private let foregroundStabilityVerifier: ControlStateVerifier
    private let hasPostEventAccess: () -> Bool
    private let launchAgentManager: LaunchAgentManager
    private let logger: SafeLog
    private let receiptStore: OperationReceiptStore
    private let permissionContext: String
    private let presentApproval: ((ApprovalRecord) -> Void)?
    private let executionLock = NSLock()
    private let controlCenterLock = NSLock()
    // Access is serialized by executionLock. The cache is deliberately held
    // only by a single keyboard lease and re-runs permission selection on
    // every action, so a warm manifest cannot bypass a changed permission gate.
    private var routeSelectionCache: RouteSelectionCacheEntry?
    private var activeControlExecution: ActiveControlExecution?

    public var controlCenterStateChanged: (() -> Void)?

    public init(
        appController: AppController = AppController(),
        workflowRegistry: WorkflowRegistry = WorkflowRegistry(),
        approvalStore: ApprovalStore = ApprovalStore(),
        presentApproval: ((ApprovalRecord) -> Void)? = nil,
        logger: SafeLog = SafeLog(),
        receiptStore: OperationReceiptStore = OperationReceiptStore(),
        permissionContext: String = "daemon",
        keyboardAccessController: KeyboardAccessController = KeyboardAccessController(),
        keyboardDriveStore: KeyboardDriveStore = KeyboardDriveStore(),
        taskApprovalStore: TaskApprovalStore = TaskApprovalStore(),
        externalApprovalStore: ExternalApprovalStore = ExternalApprovalStore(),
        taskCheckpointStore: TaskCheckpointStore = TaskCheckpointStore(),
        adapterRegistry: AppAdapterRegistry = AppAdapterRegistry(),
        taskActionExecutor: TaskActionExecuting? = nil,
        taskRunner: TaskRunner? = nil,
        targetInspector: ControlTargetInspecting? = nil,
        focusedElementInspector: FocusedElementInspecting? = nil,
        accessibilityActionController: AccessibilityActionPerforming? = nil,
        visualActionController: VisualActionPerforming? = nil,
        controlSession: ControlSession? = nil,
        semanticActionRouter: SemanticActionRouter? = nil,
        foregroundApplication: (() -> AppInfo?)? = nil,
        resolveApplication: ((String) throws -> AppInfo)? = nil,
        activateApplication: ((String) throws -> AppInfo)? = nil,
        foregroundStabilityVerifier: ControlStateVerifier? = nil,
        hasPostEventAccess: (() -> Bool)? = nil,
        warmPathStore: WarmPathStore = WarmPathStore(),
        capabilityProfileStore: CapabilityProfileStore = CapabilityProfileStore(),
        accessibilityTreeInspector: AccessibilityTreeInspecting? = nil,
        accessibilityScrollPerformer: AccessibilityScrollPerforming? = nil,
        inputScrollPerformer: InputScrollPerforming? = nil,
        capabilityAuditBatchStore: CapabilityAuditBatchStore = CapabilityAuditBatchStore(),
        shortcutBindingStore: ShortcutBindingStore = ShortcutBindingStore(),
        menuCommandController: MenuCommandControlling? = nil,
        shortcutProvisioner: ShortcutProvisioning? = nil,
        shortcutKeyboardDispatcher: ShortcutKeyboardDispatching? = nil,
        shortcutEngine: ShortcutEngine? = nil
    ) {
        self.appController = appController
        self.workflowRegistry = workflowRegistry
        self.approvalStore = approvalStore
        self.presentApproval = presentApproval
        self.logger = logger
        self.receiptStore = receiptStore
        self.permissionContext = permissionContext
        self.keyboardAccessController = keyboardAccessController
        self.keyboardDriveStore = keyboardDriveStore
        self.taskApprovalStore = taskApprovalStore
        self.externalApprovalStore = externalApprovalStore
        self.taskCheckpointStore = taskCheckpointStore
        self.adapterRegistry = adapterRegistry
        let defaultAccessibilityController = AccessibilityController()
        self.warmPathStore = warmPathStore
        self.capabilityProfileStore = capabilityProfileStore
        self.capabilityAuditBatchStore = capabilityAuditBatchStore
        self.accessibilityTreeInspector = accessibilityTreeInspector ?? defaultAccessibilityController
        self.accessibilityScrollPerformer = accessibilityScrollPerformer ?? defaultAccessibilityController
        let resolvedTargetInspector = targetInspector
            ?? AccessibilityTargetInspector(accessibility: defaultAccessibilityController)
        self.targetInspector = resolvedTargetInspector
        let resolvedFocusedElementInspector = focusedElementInspector ?? defaultAccessibilityController
        let resolvedAccessibilityActionController = accessibilityActionController ?? defaultAccessibilityController
        let resolvedForegroundApplication = foregroundApplication ?? { appController.foregroundApplication() }
        let resolvedPostEventAccess = hasPostEventAccess ?? PermissionDiagnostics.hasPostEventAccess
        self.focusedElementInspector = resolvedFocusedElementInspector
        self.foregroundApplication = resolvedForegroundApplication
        let resolvedApplicationResolver = resolveApplication ?? { try appController.resolve($0) }
        self.resolveApplication = resolvedApplicationResolver
        let resolvedApplicationActivator = activateApplication ?? { try appController.activate($0) }
        self.activateApplication = resolvedApplicationActivator
        self.foregroundStabilityVerifier = foregroundStabilityVerifier ?? ControlStateVerifier()
        self.hasPostEventAccess = resolvedPostEventAccess
        let inputController = InputController()
        let captureController = CaptureController(appController: appController)
        let resolvedControlSession = controlSession ?? ControlSession(
            keyboardDriveStore: keyboardDriveStore,
            focusedElementInspector: resolvedFocusedElementInspector,
            foregroundApplication: resolvedForegroundApplication,
            hasPostEventAccess: resolvedPostEventAccess,
            fullKeyboardAccessEnabled: {
                keyboardAccessController.status(permissionContext: permissionContext).fullKeyboardAccessEnabled == true
            }
        )
        self.controlSession = resolvedControlSession
        self.inputScrollPerformer = inputScrollPerformer ?? inputController
        let resolvedSemanticActionRouter = semanticActionRouter ?? SemanticActionRouter(
            session: resolvedControlSession,
            keyboardAccessController: keyboardAccessController,
            accessibilityActionController: resolvedAccessibilityActionController,
            visualActionController: visualActionController
                ?? VisualControlFallback(
                    captureController: captureController,
                    inputController: inputController
                )
        )
        self.semanticActionRouter = resolvedSemanticActionRouter
        let resolvedMenuCommandController = menuCommandController ?? AccessibilityMenuCommandController()
        let resolvedShortcutKeyboardDispatcher = shortcutKeyboardDispatcher
            ?? AppScopedShortcutKeyboardDispatcher(
                keyboard: keyboardAccessController,
                leases: keyboardDriveStore,
                foregroundApplication: resolvedForegroundApplication
            )
        self.shortcutEngine = shortcutEngine ?? ShortcutEngine(
            store: shortcutBindingStore,
            menus: resolvedMenuCommandController,
            directExecutor: ControlSessionShortcutDirectMenuExecutor(
                menus: resolvedMenuCommandController,
                session: resolvedControlSession,
                leases: keyboardDriveStore
            ),
            provisioner: shortcutProvisioner
                ?? GuidedShortcutProvisioner(
                    menuController: resolvedMenuCommandController,
                    chromeController: AccessibilityChromeExtensionShortcutController(
                        keyboard: resolvedShortcutKeyboardDispatcher
                    )
                ),
            keyboard: resolvedShortcutKeyboardDispatcher,
            resolveApplication: resolvedApplicationResolver,
            activateApplication: resolvedApplicationActivator,
            foregroundApplication: resolvedForegroundApplication,
            warmPaths: warmPathStore
        )
        self.workflowExecutor = WorkflowExecutor(
            appController: appController,
            inputController: inputController,
            captureController: captureController,
            keyboardAccessController: keyboardAccessController,
            keyboardDriveStore: keyboardDriveStore,
            controlSession: resolvedControlSession,
            semanticActionRouter: resolvedSemanticActionRouter,
            searchFieldResolver: defaultAccessibilityController,
            focusedElementInspector: resolvedFocusedElementInspector,
            foregroundApplication: resolvedForegroundApplication,
            hasPostEventAccess: resolvedPostEventAccess,
            fullKeyboardAccessEnabled: {
                keyboardAccessController.status(permissionContext: permissionContext).fullKeyboardAccessEnabled == true
            }
        )
        let resolvedTaskExecutor = taskActionExecutor ?? MacTaskActionExecutor(
            appController: appController,
            accessibilityController: defaultAccessibilityController,
            inputController: inputController,
            keyboardAccessController: keyboardAccessController,
            semanticActionRouter: resolvedSemanticActionRouter,
            adapterRegistry: adapterRegistry,
            foregroundApplication: resolvedForegroundApplication
        )
        self.taskRunner = taskRunner ?? TaskRunner(
            checkpointStore: taskCheckpointStore,
            approvalStore: taskApprovalStore,
            actionExecutor: resolvedTaskExecutor,
            targetRevalidator: { [resolvedTargetInspector, resolvedForegroundApplication, resolvedApplicationResolver, adapterRegistry] step in
                let target = step.target
                var requestedApplication = target?.application ?? target?.bundleID
                if requestedApplication == nil,
                   [.launchApp, .activateWindow].contains(step.action.kind) {
                    requestedApplication = step.action.parameters["app"]?.stringValue
                }
                if requestedApplication == nil,
                   step.action.kind == .adapter,
                   let adapterID = step.action.parameters["adapter_id"]?.stringValue,
                   let manifest = adapterRegistry.manifest(adapterID: adapterID) {
                    requestedApplication = step.action.parameters["app"]?.stringValue ?? manifest.displayName
                }
                let application: AppInfo?
                if let name = requestedApplication {
                    application = try resolvedApplicationResolver(name)
                } else {
                    application = resolvedForegroundApplication()
                }
                guard let application else {
                    throw ControlTargetInspectionError.applicationUnavailable
                }
                let isAdapterOpen = step.action.kind == .adapter
                    && step.action.parameters["operation"]?.stringValue == "open"
                if isAdapterOpen {
                    guard target?.processID == nil,
                          target?.windowFingerprint == nil,
                          target?.focusedElementFingerprint == nil,
                          target?.selector == nil else {
                        throw ControlTargetInspectionError.targetChanged
                    }
                    let snapshot = ControlTargetSnapshot(
                        application: application,
                        focusedElement: nil,
                        fingerprint: ControlTargetFingerprints.make(
                            application: application,
                            focus: nil,
                            window: AccessibilityWindowState(visible: false, modal: false)
                        ),
                        windowVisible: false,
                        modal: false,
                        focusReadable: false,
                        hung: false
                    )
                    try MacCtlService.validateTaskTarget(snapshot: snapshot, target: target)
                    return snapshot
                }
                if let selector = target?.selector,
                   selector.addressability == .accessibility,
                   let pid = application.processID {
                    do {
                        _ = try defaultAccessibilityController.findElement(pid: pid, selector: selector)
                    } catch AccessibilityControllerError.ambiguousMatch,
                            AccessibilityControllerError.ambiguousWindowMatch {
                        throw ControlTargetInspectionError.ambiguousTarget
                    } catch AccessibilityControllerError.elementNotFound,
                            AccessibilityControllerError.windowNotFound {
                        throw ControlTargetInspectionError.targetChanged
                    } catch AccessibilityControllerError.permissionDenied {
                        throw ControlTargetInspectionError.unreadableFocus
                    }
                }
                let snapshot = try resolvedTargetInspector.inspect(application: application)
                if MacCtlService.actionRequiresReadableFocus(
                    step.action,
                    adapterRegistry: adapterRegistry
                ), !snapshot.focusReadable {
                    throw ControlTargetInspectionError.unreadableFocus
                }
                try MacCtlService.validateTaskTarget(snapshot: snapshot, target: target)
                return snapshot
            },
            adapterRegistry: adapterRegistry
        )
        self.launchAgentManager = LaunchAgentManager()
    }

    public func handle(_ request: RequestEnvelope) -> ResponseEnvelope {
        let startedAt = Date()
        let response: ResponseEnvelope
        if request.schemaVersion != 1 {
            response = failure(
                request,
                status: .failed,
                code: .invalidRequest,
                message: "Unsupported schema_version; expected 1"
            )
        } else {
            do {
                response = try execute(request)
            } catch {
                response = errorResponse(request, error: error)
            }
        }
        recordReceipt(for: request, response: response, startedAt: startedAt)
        controlCenterStateChanged?()
        return response
    }

    public func shutdown() {
        routeSelectionCache = nil
        controlCenterLock.lock()
        activeControlExecution = nil
        controlCenterLock.unlock()
        keyboardDriveStore.shutdown()
        controlCenterStateChanged?()
    }

    private func execute(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        switch request.method {
            case "doctor":
                return try success(request, value: doctorReport())
            case "capabilities":
                return try success(request, value: capabilityReport())
            case "status":
                return try success(request, value: daemonStatus())
            case "keyboard.status":
                return try keyboardStatus(request)
            case "keyboard.setup":
                return try keyboardSetup(request)
            case "keyboard.enable":
                return try keyboardEnable(request)
            case "keyboard.inspect":
                return try keyboardInspect(request)
            case "keyboard.lease.acquire":
                return try acquireKeyboardLease(request)
            case "keyboard.lease.release":
                return try releaseKeyboardLease(request)
            case "keyboard.freeze.acquire":
                return try acquireKeyboardFreeze(request)
            case "keyboard.freeze.status":
                return try keyboardFreezeStatus(request)
            case "keyboard.freeze.release":
                return try releaseKeyboardFreeze(request)
            case "keyboard.navigate":
                return try navigateKeyboard(request)
            case "keyboard.send":
                return try sendKeyboard(request)
            case "task.prepare":
                return try prepareTask(request)
            case "task.run":
                return try runTask(request)
            case "task.status":
                return try statusTask(request)
            case "task.resume":
                return try resumeTask(request)
            case "task.cancel":
                return try cancelTask(request)
            case "control.stop_active":
                return try stopActiveControl(request)
            case "adapter.capabilities":
                return try success(
                    request,
                    result: [
                        "manifests": try JSONValue.fromEncodable(adapterRegistry.manifests()),
                        "automation_permissions": try JSONValue.fromEncodable(adapterRegistry.automationPermissions())
                    ],
                    evidence: [Evidence(
                        kind: "adapter_capabilities",
                        message: "Allowlisted adapter manifests and Automation diagnostics were inspected",
                        source: "macctld"
                    )]
                )
            case "control.status":
                return try controlStatus(request)
            case "control.center.snapshot":
                return try success(request, value: controlCenterSnapshot())
            case "control.perform":
                return try performControlAction(request)
            case "control.batch":
                return try performControlBatch(request)
            case "control.capabilities":
                return try controlCapabilities(request)
            case "control.capability_audit":
                return try controlCapabilityAudit(request)
            case "control.capability_audit_batch":
                return try controlCapabilityAuditBatch(request)
            case "shortcut.audit":
                return try shortcutAudit(request)
            case "shortcut.propose":
                return try shortcutPropose(request)
            case "shortcut.inspect":
                return try shortcutInspect(request)
            case "shortcut.setup", "shortcut.run", "shortcut.remove":
                return try shortcutMutatingOperation(request)
            case "route.list":
                return try routeList(request)
            case "route.inspect":
                return try routeInspect(request)
            case "route.benchmark":
                return try routeBenchmark(request)
            case "route.register":
                return try routeRegister(request)
            case "accessibility.tree":
                return try accessibilityTree(request)
            case "accessibility.audit":
                return try accessibilityAudit(request)
            case "ideal-state.audit":
                return try idealStateAudit(request)
            case "app.list":
                return try success(request, value: appController.listApplications())
            case "app.open":
                let name = try requiredString(request, key: "name")
                let focusPolicy = try requestedFocusPolicy(from: request) ?? .foreground
                let app = try withExecutionLock {
                    try appController.open(name, focusPolicy: focusPolicy)
                }
                logger.record(event: "app_opened", metadata: [
                    "app": app.name,
                    "focus_policy": focusPolicy.rawValue
                ])
                return try success(
                    request,
                    value: app,
                    evidence: [Evidence(
                        kind: "focus_policy",
                        message: "Application open used the requested focus policy",
                        metadata: ["policy": .string(focusPolicy.rawValue)]
                    )]
                )
            case "workflow.list":
                return try success(request, value: workflowRegistry.list())
            case "workflow.validate":
                let id = try requiredString(request, key: "workflow")
                guard let baseWorkflow = workflowRegistry.workflow(id: id) else {
                    return try success(request, value: workflowRegistry.validate(id: id))
                }
                let workflow = try workflowApplyingRequestedFocusPolicy(baseWorkflow, request: request)
                return try success(request, value: workflowRegistry.validate(workflow))
            case "workflow.prepare":
                return try prepareWorkflow(request)
            case "workflow.run":
                return try runWorkflow(request)
            case "approval.list":
                return try success(
                    request,
                    value: approvalStore.list() + taskApprovalStore.list() + externalApprovalStore.list()
                )
            case "approval.external.prepare":
                return try prepareExternalApproval(request)
            case "approval.external.status":
                return try externalApprovalStatus(request)
            case "approval.external.consume":
                return try consumeExternalApproval(request)
            case "approval.approve":
                return try approve(request)
            case "approval.deny":
                return try deny(request)
            case "receipts.list":
                return try success(request, value: receiptStore.list())
            case "receipts.status":
                return try success(request, value: receiptStore.status())
            case "logs":
                return try success(request, value: ["lines": logger.tail()])
            default:
                return failure(
                    request,
                    status: .failed,
                    code: .unsupportedMethod,
                    message: "Unsupported method: \(request.method)"
                )
        }
    }

    public func localReadOnlyHandle(_ request: RequestEnvelope) -> ResponseEnvelope {
        handle(request)
    }

    public func isApprovalPending(token: String) -> Bool {
        approvalStore.list().contains { $0.token == token }
            || taskApprovalStore.list().contains { $0.token == token }
            || externalApprovalStore.list().contains { $0.token == token }
    }

    public func pendingApprovalRecords() -> [ApprovalRecord] {
        (approvalStore.list() + taskApprovalStore.list() + externalApprovalStore.list()).sorted {
            if $0.expiresAt == $1.expiresAt { return $0.operationID < $1.operationID }
            return $0.expiresAt < $1.expiresAt
        }
    }

    public func controlCenterSnapshot() -> ControlCenterSnapshot {
        let approvals = pendingApprovalRecords().map(ControlCenterApproval.init)
        controlCenterLock.lock()
        let activeExecution = activeControlExecution?.snapshot
        controlCenterLock.unlock()
        let execution: ControlCenterExecution?
        if let activeExecution {
            execution = activeExecution
        } else if let lease = keyboardDriveStore.activeLease() {
            execution = ControlCenterExecution(
                executionID: "manual-lease",
                taskID: nil,
                summary: lease.physicalInputMode == .suppressed
                    ? "Physical keyboard suppression"
                    : "Keyboard control lease",
                applicationName: lease.application?.name,
                physicalInputMode: lease.physicalInputMode,
                acquiredAt: lease.acquiredAt,
                expiresAt: lease.expiresAt
            )
        } else {
            execution = nil
        }
        let permissions = permissionContext == "daemon"
            ? PermissionDiagnostics.report()
            : PermissionDiagnostics.unknownReport()
        return ControlCenterSnapshot(
            approvals: approvals,
            execution: execution,
            permissions: permissions
        )
    }

    private func shortcutAudit(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let report = try shortcutEngine.audit(app: request.params["app"]?.stringValue)
        return try success(
            request,
            value: report,
            evidence: [Evidence(
                kind: "shortcut_audit",
                message: "Running-app menus and registered shortcut blockers were inspected without launching applications",
                source: "macctld"
            )]
        )
    }

    private func shortcutPropose(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let target: CommandTarget
        if let extensionID = request.params["extension_id"]?.stringValue {
            target = .chromeExtension(
                extensionID: extensionID,
                commandID: try requiredString(request, key: "command_id")
            )
        } else {
            let appName = try requiredString(request, key: "app")
            let application = try resolveApplication(appName)
            let path = try requestedStringArray(from: request, key: "menu_path")
            target = .appMenu(
                applicationName: application.name,
                bundleID: application.bundleID,
                menuPath: path
            )
        }
        let binding = try shortcutEngine.propose(
            target: target,
            requestedChord: request.params["chord"]?.stringValue,
            postconditions: try shortcutPostconditions(request)
        )
        return try success(
            request,
            status: .prepared,
            value: binding,
            evidence: [Evidence(
                kind: "shortcut_proposal",
                message: "A deterministic chord and exact target were previewed; no system shortcut was installed",
                source: "macctld",
                metadata: ["binding_digest": .string(binding.digest)]
            )]
        )
    }

    private func shortcutInspect(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let report = try shortcutEngine.inspection(id: try requiredString(request, key: "id"))
        return try success(
            request,
            value: report,
            evidence: [Evidence(
                kind: "shortcut_binding",
                message: "The owner-only shortcut binding and available live target state were inspected without dispatch",
                source: "macctld",
                metadata: ["binding_digest": .string(report.binding.digest)]
            )]
        )
    }

    private func shortcutPostconditions(_ request: RequestEnvelope) throws -> [TaskPredicate] {
        guard let value = request.params["postconditions"] else { return [] }
        do {
            return try JSONCodec.decode([TaskPredicate].self, from: JSONCodec.encode(value))
        } catch {
            throw ShortcutError.invalidTarget("postconditions must be a JSON array of task predicates")
        }
    }

    private func shortcutMutatingOperation(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let operation = String(request.method.dropFirst("shortcut.".count))
        let id = try requiredString(request, key: "id")
        let binding = try shortcutEngine.inspect(id: id)
        let requestedRoute = try request.params["route"]?.stringValue.map { raw -> ShortcutRunRoute in
            guard let route = ShortcutRunRoute(rawValue: raw) else {
                throw ShortcutError.unsupported("unknown shortcut route: \(raw)")
            }
            return route
        }
        let plan = shortcutOperationPlan(binding: binding, operation: operation, route: requestedRoute)
        guard let token = request.params["approval_token"]?.stringValue else {
            let prepared = taskApprovalStore.prepare(plan: plan)
            presentApproval?(prepared.record)
            return try success(
                request,
                status: .prepared,
                operationID: prepared.record.operationID,
                result: [
                    "approval": try JSONValue.fromEncodable(prepared.record),
                    "plan_digest": .string(prepared.planDigest),
                    "binding_digest": .string(binding.digest),
                    "operation": .string(operation)
                ],
                evidence: [Evidence(
                    kind: "shortcut_approval",
                    message: "The exact binding, operation, route, and postconditions were prepared for approval",
                    source: "macctld",
                    metadata: ["binding_digest": .string(binding.digest)]
                )]
            )
        }
        _ = try taskApprovalStore.consume(token: token, plan: plan, ephemeralInputs: [:])
        switch operation {
        case "setup":
            let report = try withExecutionLock { try shortcutEngine.setup(id: id) }
            return try success(
                request,
                status: report.handoffRequired ? .blocked : .succeeded,
                value: report,
                evidence: [Evidence(
                    kind: "shortcut_setup",
                    message: report.handoffRequired
                        ? "Setup reached a semantic checkpoint and stopped for human handoff"
                        : "The configured shortcut was read back from the target application menu",
                    source: "macctld",
                    metadata: ["binding_digest": .string(binding.digest)]
                )]
            )
        case "run":
            let report = try withExecutionLock {
                try shortcutEngine.run(id: id, requestedRoute: requestedRoute)
            }
            guard report.verification == "passed" else {
                return failure(
                    request,
                    status: .blocked,
                    code: .controlVerificationUnavailable,
                    message: "Command was dispatched once, but its declared postcondition did not pass",
                    details: [
                        "binding_digest": .string(binding.digest),
                        "route": .string(report.route.rawValue),
                        "no_retry": .bool(true),
                        "verification": .string(report.verification)
                    ],
                    outcome: AgentActionOutcome(
                        state: .verificationUnavailable,
                        route: report.route.rawValue,
                        verification: report.verification,
                        failureClass: "verification_unavailable",
                        fallbackAllowed: false,
                        freshStateRequired: true,
                        nextAction: "inspect current menu state before any new command"
                    )
                )
            }
            return try success(
                request,
                value: report,
                evidence: [Evidence(
                    kind: "shortcut_behavior",
                    message: "The command route ran once and its declared postcondition passed",
                    source: "macctld",
                    metadata: ["binding_digest": .string(binding.digest)]
                )],
                outcome: AgentActionOutcome(
                    state: .verifiedSuccess,
                    route: report.route.rawValue,
                    verification: report.verification
                )
            )
        case "remove":
            let report = try withExecutionLock { try shortcutEngine.remove(id: id) }
            return try success(
                request,
                status: report.handoffRequired ? .blocked : .succeeded,
                value: report,
                evidence: [Evidence(
                    kind: "shortcut_rollback",
                    message: report.handoffRequired
                        ? "Rollback reached a semantic checkpoint and stopped for human handoff"
                        : "The prior shortcut state was read back before the binding was removed",
                    source: "macctld",
                    metadata: ["binding_digest": .string(binding.digest)]
                )]
            )
        default:
            throw ShortcutError.unsupported("unknown shortcut operation: \(operation)")
        }
    }

    private func shortcutOperationPlan(
        binding: ShortcutBinding,
        operation: String,
        route: ShortcutRunRoute?
    ) -> TaskPlan {
        var parameters: [String: JSONValue] = [
            "binding_id": .string(binding.id),
            "binding_digest": .string(binding.digest),
            "operation": .string(operation)
        ]
        if let route { parameters["route"] = .string(route.rawValue) }
        let alternateRoutes = binding.target.kind == .appMenu
            ? ["accessibility", "keyboard"]
            : ["keyboard"]
        let action = ActionSpec(
            kind: .command,
            surface: .macApp,
            parameters: parameters,
            risk: .sensitive
        )
        let step = TaskStep(
            id: "shortcut-\(operation)",
            action: action,
            target: TaskTargetIdentity(
                application: binding.target.applicationName,
                bundleID: binding.target.bundleID
            ),
            postconditions: operation == "run" ? binding.postconditions : [],
            risk: .sensitive,
            approvalReason: "Execute exact shortcut \(operation) for binding digest \(binding.digest)",
            timeout: 30,
            recovery: TaskRecoveryPolicy(mode: "strict", alternateRoutes: alternateRoutes, maxAttempts: 1)
        )
        return TaskPlan(
            id: "shortcut.\(operation).\(binding.id)",
            name: "Shortcut \(operation)",
            summary: "\(operation.capitalized) exact shortcut binding \(binding.id)",
            steps: [step],
            totalTimeout: 30,
            maxActions: 1,
            recipe: "shortcut-operation"
        )
    }

    private func keyboardStatus(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let status = keyboardAccessController.status(
            permissionContext: permissionContext,
            activeLease: keyboardDriveStore.activeLease()
        )
        return try success(
            request,
            value: status,
            evidence: [Evidence(
                kind: "keyboard_status",
                message: "Full Keyboard Access and keyboard permission status were inspected",
                source: "macctld"
            )]
        )
    }

    private func keyboardSetup(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        return try success(
            request,
            value: keyboardAccessController.setup(),
            evidence: [Evidence(
                kind: "keyboard_setup",
                message: "Keyboard setup guidance was returned without changing system preferences",
                source: "macctld"
            )]
        )
    }

    private func keyboardEnable(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let status = try keyboardAccessController.enable(
            confirm: request.params["confirm"]?.boolValue == true,
            permissionContext: permissionContext,
            activeLease: keyboardDriveStore.activeLease()
        )
        return try success(
            request,
            value: status,
            evidence: [Evidence(
                kind: "keyboard_setting",
                message: "Full Keyboard Access was explicitly requested and verified through AppKit",
                source: "macctld"
            )]
        )
    }

    private func keyboardInspect(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        guard let application = foregroundApplication(), let processID = application.processID else {
            throw KeyboardControlError.foregroundUnavailable
        }
        let snapshot = try focusedElementInspector.focusedElementSnapshot(
            pid: processID,
            application: application
        )
        return try success(
            request,
            value: snapshot,
            evidence: [Evidence(
                kind: "keyboard_focus",
                message: "Focused Accessibility metadata was inspected without reading values or child trees",
                source: "macctld"
            )]
        )
    }

    private func acquireKeyboardLease(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let rawScope = try requiredString(request, key: "scope").lowercased()
        guard let scope = KeyboardLeaseScope(rawValue: rawScope) else {
            throw KeyboardControlError.invalidSequence("scope")
        }
        let rawPhysicalInputMode = request.params["physical_input_mode"]?.stringValue ?? "shared"
        guard let physicalInputMode = KeyboardPhysicalInputMode(rawValue: rawPhysicalInputMode.lowercased()) else {
            throw KeyboardControlError.invalidSequence("physical_input_mode")
        }
        guard hasPostEventAccess() else {
            throw KeyboardControlError.permissionDenied("Post Events")
        }
        let freezeReason = request.params["reason"]?.stringValue
        let application: AppInfo?
        switch scope {
        case .app:
            guard let requestedName = request.params["app"]?.stringValue,
                  !requestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KeyboardDriveStoreError.applicationRequired
            }
            let requestedApplication = try resolveApplication(requestedName)
            guard let currentApplication = foregroundApplication() else {
                throw KeyboardControlError.foregroundUnavailable
            }
            guard sameKeyboardApplication(requestedApplication, currentApplication, requireProcess: true) else {
                throw KeyboardControlError.appScopeMismatch(
                    expected: keyboardApplicationLabel(requestedApplication),
                    actual: keyboardApplicationLabel(currentApplication)
                )
            }
            application = currentApplication
        case .session:
            application = nil
        }
        let lease = try keyboardDriveStore.acquire(
            scope: scope,
            application: application,
            seconds: try requestedKeyboardLifetime(from: request),
            confirm: request.params["confirm"]?.boolValue == true,
            physicalInputMode: physicalInputMode,
            freezeReason: freezeReason
        )
        let message = physicalInputMode == .suppressed
            ? "Keyboard driving lease acquired; physical keyboard events are suppressed until release or expiry; use the mouse or daemon quit action for emergency release"
            : "Keyboard driving lease acquired; keep the physical keyboard and trackpad idle while driving"
        let evidence: [Evidence] = physicalInputMode == .suppressed
            ? [
                Evidence(
                    kind: "keyboard_lease",
                    message: "A short-lived keyboard driving lease was acquired in memory",
                    source: "macctld"
                ),
                Evidence(
                    kind: "keyboard_physical_suppression",
                    message: "An opt-in session event tap is suppressing physical keyboard events while the lease is active",
                    source: "macctld"
                ),
                Evidence(
                    kind: "keyboard_freeze",
                    message: "Physical keyboard suppression was explicitly requested with a human reason and bounded expiry",
                    source: "macctld"
                )
            ]
            : [Evidence(
                kind: "keyboard_lease",
                message: "A short-lived keyboard driving lease was acquired in memory",
                source: "macctld"
            )]
        return try success(
            request,
            result: [
                "message": .string(message),
                "lease": try JSONValue.fromEncodable(lease),
                "scope": .string(scope.rawValue),
                "physical_input_mode": .string(physicalInputMode.rawValue),
                "freeze_reason_present": .bool(lease.freezeReasonProvided),
                "expires_at": try JSONValue.fromEncodable(lease.expiresAt)
            ],
            evidence: evidence
        )
    }

    private func releaseKeyboardLease(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        guard let token = request.params["token"]?.stringValue, !token.isEmpty else {
            throw KeyboardControlError.leaseRequired
        }
        let lease = try keyboardDriveStore.release(token: token)
        if routeSelectionCache?.leaseToken == token {
            routeSelectionCache = nil
        }
        return try success(
            request,
            result: [
                "released": .bool(true),
                "scope": .string(lease.scope.rawValue),
                "expires_at": try JSONValue.fromEncodable(lease.expiresAt)
            ],
            evidence: [Evidence(
                kind: "keyboard_lease",
                message: "Keyboard driving lease was released from memory",
                source: "macctld"
            )]
        )
    }

    private func acquireKeyboardFreeze(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let scope = try requiredString(request, key: "scope").lowercased()
        if scope != KeyboardLeaseScope.session.rawValue {
            throw KeyboardDriveStoreError.physicalKeyboardSuppressionRequiresSession
        }
        guard request.params["confirm"]?.boolValue == true else {
            throw KeyboardControlError.confirmationRequired
        }
        guard let reason = request.params["reason"]?.stringValue,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeyboardDriveStoreError.physicalKeyboardSuppressionReasonRequired
        }
        let lease = try keyboardDriveStore.acquire(
            scope: .session,
            application: nil,
            seconds: try requestedKeyboardLifetime(from: request),
            confirm: true,
            physicalInputMode: .suppressed,
            freezeReason: reason
        )
        return try success(
            request,
            result: [
                "message": .string("Physical keyboard freeze acquired until release or bounded expiry; mouse remains available"),
                "token": .string(lease.token),
                "expires_at": try JSONValue.fromEncodable(lease.expiresAt),
                "reason_present": .bool(lease.freezeReasonProvided),
                "scope": .string(lease.scope.rawValue)
            ],
            evidence: [
                Evidence(
                    kind: "keyboard_freeze",
                    message: "An explicit session-only physical keyboard freeze is active",
                    source: "macctld"
                ),
                Evidence(
                    kind: "keyboard_freeze_permissions",
                    message: "Accessibility and Input Monitoring are required; expiry and shutdown release the freeze",
                    source: "macctld"
                )
            ]
        )
    }

    private func keyboardFreezeStatus(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let lease = keyboardDriveStore.activeLease()
        let freeze = lease?.physicalInputMode == .suppressed ? lease : nil
        let permissions = permissionContext == "daemon"
            ? PermissionDiagnostics.report()
            : PermissionDiagnostics.unknownReport()
        return try success(
            request,
            value: KeyboardFreezeStatus(
                active: freeze != nil,
                token: freeze?.token,
                scope: freeze?.scope,
                expiresAt: freeze?.expiresAt,
                reasonPresent: freeze?.freezeReasonProvided ?? false,
                permissions: permissions
            ),
            evidence: [Evidence(
                kind: "keyboard_freeze_status",
                message: "Freeze activity and required permissions were inspected without changing input state",
                source: "macctld"
            )]
        )
    }

    private func releaseKeyboardFreeze(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let token = try requiredString(request, key: "token")
        let active = try keyboardDriveStore.lease(for: token)
        guard active.physicalInputMode == .suppressed else {
            throw KeyboardControlError.invalidSequence("freeze token")
        }
        let released = try keyboardDriveStore.release(token: token)
        return try success(
            request,
            result: [
                "released": .bool(true),
                "token": .string(released.token),
                "scope": .string(released.scope.rawValue)
            ],
            evidence: [Evidence(
                kind: "keyboard_freeze",
                message: "Physical keyboard freeze was explicitly released; mouse remains available",
                source: "macctld"
            )]
        )
    }

    private func navigateKeyboard(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        guard let token = request.params["lease_token"]?.stringValue, !token.isEmpty else {
            throw KeyboardControlError.leaseRequired
        }
        let command = try KeyboardCommand.resolve(try requiredString(request, key: "command"))
        let count = try requestedKeyboardCount(from: request)
        let interKeyDelay = try requestedInterKeyDelay(from: request)
        let expectedMenuItems = try requestedStringArray(from: request, key: "expected_menu_items")
        let report = try withExecutionLock {
            try semanticActionRouter.perform(
                command: command,
                selector: nil,
                leaseToken: token,
                count: count,
                interKeyDelay: interKeyDelay,
                allowRawCoordinate: false,
                expectedMenuItems: expectedMenuItems
            )
        }
        // Navigation commands without a declared postcondition preserve their
        // dispatch result even when focus cannot be observed. Commands with a
        // concrete postcondition must fail closed.
        guard report.verification.postcondition == nil || report.verification.state == .passed else {
            throw ControlVerificationFailure(
                route: report.route,
                state: report.verification.state,
                postcondition: report.verification.postcondition
            )
        }
        return try success(
            request,
            value: report,
            evidence: [Evidence(
                kind: "keyboard_input",
                message: "Named keyboard navigation ran under a live lease and reported post-action focus verification",
                source: "macctld"
            )]
        )
    }

    private func sendKeyboard(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        guard let values = request.params["keys"]?.arrayValue else {
            throw KeyboardControlError.invalidSequence("keys")
        }
        let keys = values.map { $0.stringValue }
        guard keys.allSatisfy({ $0 != nil }) else {
            throw KeyboardControlError.invalidSequence("keys")
        }
        guard let token = request.params["lease_token"]?.stringValue, !token.isEmpty else {
            throw KeyboardControlError.leaseRequired
        }
        let interKeyDelay = try requestedInterKeyDelay(from: request)
        let report = try withExecutionLock {
            let (lease, application) = try requireKeyboardInputLease(
                token: token,
                requireFullKeyboardAccess: false
            )
            return try keyboardAccessController.sendRaw(
                keys: keys.compactMap { $0 },
                targetApplication: application,
                leaseExpiresAt: lease.expiresAt,
                interKeyDelay: interKeyDelay,
                beforeEach: { _ in
                    _ = try self.requireKeyboardInputLease(
                        token: token,
                        requireFullKeyboardAccess: false
                    )
                }
            )
        }
        return try success(
            request,
            value: report,
            evidence: [Evidence(
                kind: "keyboard_input",
                message: "Raw non-printable keyboard shortcuts ran under a live lease and per-key focus checks",
                source: "macctld"
            )]
        )
    }

    private func controlStatus(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        try success(
            request,
            value: controlSession.snapshot(),
            evidence: [Evidence(
                kind: "control_session",
                message: "Foreground, redacted focus, lease, and last verification state were inspected",
                source: "macctld"
            )]
        )
    }

    private func controlCapabilities(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let application = try resolveApplication(try requiredString(request, key: "app"))
        let taskID = request.params["task"]?.stringValue
        let targetFingerprint = request.params["target_fingerprint"]?.stringValue
        if taskID != nil && targetFingerprint == nil {
            throw WarmPathSelectionError.targetFingerprintRequired
        }
        let manifest: WarmPathManifest? = if let taskID, let targetFingerprint {
            warmPathStore.inspect(
                application: application,
                taskID: taskID,
                targetFingerprint: targetFingerprint
            )
        } else {
            nil
        }
        let providerState = currentCapabilityProviderState()
        let cachedProfile = capabilityProfileStore.lookup(
            application: application,
            osVersion: currentOSVersion(),
            providerState: providerState
        )
        let targetFingerprintDigest = targetFingerprint.map(CapabilityProfileDigest.make)
        let recentBlockers = (try? receiptStore.recentControlBlockers(
            application: WarmPathApplicationIdentity(application: application),
            taskID: taskID,
            targetFingerprintDigest: targetFingerprintDigest
        )) ?? []
        let profile = ControlCapabilityProfile(
            application: WarmPathApplicationIdentity(application: application),
            taskID: taskID,
            targetFingerprint: targetFingerprint,
            manifest: manifest,
            deepAuditAvailable: application.isRunning && application.processID != nil,
            cachedBroadProfile: cachedProfile.summary,
            recentBlockers: recentBlockers
        )
        return try success(
            request,
            value: profile,
            evidence: [Evidence(
                kind: "control_capabilities",
                message: "Fast route, cached broad-profile metadata, and redacted recent blockers were reported without walking the Accessibility tree",
                source: "macctld",
                metadata: [
                    "archetype": .string(profile.archetype.rawValue),
                    "manifest_found": .bool(profile.manifestFound),
                    "route_selection_policy": .string(profile.routeSelectionPolicy),
                    "probe_mode": .string(profile.probeMode),
                    "broad_profile_cache_hit": .bool(cachedProfile.cacheHit),
                    "deep_audit_recommended": .bool(cachedProfile.summary.deepAuditRecommended),
                    "recent_blocker_count": .number(Double(recentBlockers.count))
                ]
            )]
        )
    }

    private func controlCapabilityAudit(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let application = try runningAccessibilityApplication(from: request)
        let execution = try auditCapabilityProfile(
            application: application,
            maxNodes: try requestedNonNegativeInt(
                from: request,
                key: "max_nodes",
                defaultValue: CapabilityAuditBounds.defaultMaxNodes
            ),
            maxDepth: try requestedNonNegativeInt(
                from: request,
                key: "max_depth",
                defaultValue: CapabilityAuditBounds.defaultMaxDepth
            )
        )
        let profile = execution.profile
        var auditMetadata: [String: JSONValue] = [
            "audit_depth": .string(CapabilityAuditDepth.deepReadOnly.rawValue),
            "tree_signature": .string(profile.identity.treeSignature),
            "tree_node_count": .number(Double(profile.treeNodeCount)),
            "tree_truncated": .bool(profile.treeTruncated),
            "profile_state": .string(profile.state.rawValue),
            "archetype": .string(profile.archetype.rawValue),
            "audit_attempts": .number(Double(execution.attempts)),
            "adaptive_retry": .bool(execution.adaptiveRetry),
            "initial_max_nodes": .number(Double(execution.initialMaxNodes)),
            "initial_max_depth": .number(Double(execution.initialMaxDepth)),
            "effective_max_nodes": .number(Double(execution.effectiveMaxNodes)),
            "effective_max_depth": .number(Double(execution.effectiveMaxDepth)),
            "adaptive_ceiling_reached": .bool(execution.exhausted),
            "traversal_mode": .string(execution.traversalMode),
            "windowed_attempted": .bool(execution.windowedAttempted),
            "coverage_complete": .bool(execution.coverageComplete)
        ]
        if let coverage = execution.coverage {
            auditMetadata["window_count"] = .number(Double(coverage.windowCount))
            auditMetadata["page_count"] = .number(Double(coverage.pageCount))
            auditMetadata["omitted_window_count"] = .number(Double(coverage.omittedWindowCount))
            auditMetadata["omitted_page_count"] = .number(Double(coverage.omittedPageCount))
        }
        return try success(
            request,
            value: profile,
            evidence: [Evidence(
                kind: "control_capability_audit",
                message: "A bounded, redacted Accessibility tree produced a persisted broad capability profile; no action was dispatched",
                source: "macctld",
                metadata: auditMetadata
            )]
        )
    }

    private func controlCapabilityAuditBatch(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let runID = request.params["run_id"]?.stringValue
        let resumed = runID != nil
        var run: CapabilityAuditBatchRun
        if let runID {
            guard request.params["apps"] == nil,
                  request.params["all_applicable"] == nil else {
                throw WorkflowExecutionError.unsafeInput(
                    "run_id cannot be combined with apps or all_applicable; resume the stored manifest unchanged"
                )
            }
            run = try capabilityAuditBatchStore.load(runID: runID)
        } else {
            let targets = try capabilityAuditBatchTargets(from: request)
            let maxNodes = try requestedPositiveInt(
                from: request,
                key: "max_nodes",
                defaultValue: CapabilityAuditCatalog.defaultMaxNodes
            )
            let maxDepth = try requestedNonNegativeInt(
                from: request,
                key: "max_depth",
                defaultValue: CapabilityAuditCatalog.defaultMaxDepth
            )
            let maxConcurrency = try requestedPositiveInt(
                from: request,
                key: "max_concurrency",
                defaultValue: 1
            )
            guard maxConcurrency == 1 else {
                throw WorkflowExecutionError.unsafeInput(
                    "Accessibility batch audits are serialized; max_concurrency must be 1"
                )
            }
            run = try capabilityAuditBatchStore.create(
                targets: targets,
                maxNodes: maxNodes,
                maxDepth: maxDepth,
                maxConcurrency: maxConcurrency
            )
        }

        let maxApps = try requestedPositiveInt(
            from: request,
            key: "max_apps",
            defaultValue: CapabilityAuditCatalog.maximumTargets
        )
        guard maxApps <= CapabilityAuditCatalog.maximumTargets else {
            throw WorkflowExecutionError.unsafeInput(
                "max_apps must be at most \(CapabilityAuditCatalog.maximumTargets)"
            )
        }

        var entries = run.entries
        var targets = run.targets
        var processedCount = 0
        for index in entries.indices where entries[index].canResume {
            guard processedCount < maxApps else { break }
            let originalEntry = entries[index]
            let startedAt = Date()
            let attempt = originalEntry.attempts + 1
            entries[index] = CapabilityAuditBatchEntryReceipt(
                target: originalEntry.target,
                state: .pending,
                reason: .pending,
                attempts: attempt,
                startedAt: startedAt
            )
            run = run.replacingTargetsAndEntries(targets, entries: entries, updatedAt: startedAt)
            try capabilityAuditBatchStore.save(run)

            do {
                let application: AppInfo
                do {
                    application = try resolveApplication(originalEntry.target.selector)
                } catch AppControllerError.appNotFound {
                    entries[index] = CapabilityAuditBatchEntryReceipt(
                        target: originalEntry.target,
                        state: .notObserved,
                        reason: .applicationNotFound,
                        attempts: attempt,
                        startedAt: startedAt,
                        completedAt: Date()
                    )
                    processedCount += 1
                    run = run.replacingTargetsAndEntries(targets, entries: entries)
                    try capabilityAuditBatchStore.save(run)
                    continue
                }

                if let expected = originalEntry.target.identity,
                   let mismatch = capabilityAuditIdentityMismatch(expected: expected, actual: application) {
                    entries[index] = CapabilityAuditBatchEntryReceipt(
                        target: originalEntry.target,
                        state: .blocked,
                        reason: mismatch,
                        attempts: attempt,
                        startedAt: startedAt,
                        completedAt: Date()
                    )
                    processedCount += 1
                    run = run.replacingTargetsAndEntries(targets, entries: entries)
                    try capabilityAuditBatchStore.save(run)
                    continue
                }

                if originalEntry.target.identity == nil {
                    let boundTarget = CapabilityAuditBatchTarget(application: application)
                    targets[index] = boundTarget
                    entries[index] = CapabilityAuditBatchEntryReceipt(
                        target: boundTarget,
                        state: .pending,
                        reason: .pending,
                        attempts: attempt,
                        startedAt: startedAt
                    )
                    run = run.replacingTargetsAndEntries(targets, entries: entries, updatedAt: startedAt)
                    try capabilityAuditBatchStore.save(run)
                }

                guard application.isRunning, application.processID != nil else {
                    entries[index] = CapabilityAuditBatchEntryReceipt(
                        target: entries[index].target,
                        state: .notObserved,
                        reason: .applicationNotRunning,
                        attempts: attempt,
                        startedAt: startedAt,
                        completedAt: Date()
                    )
                    processedCount += 1
                    run = run.replacingTargetsAndEntries(targets, entries: entries)
                    try capabilityAuditBatchStore.save(run)
                    continue
                }

                let execution = try auditCapabilityProfile(
                    application: application,
                    maxNodes: run.maxNodes,
                    maxDepth: run.maxDepth
                )
                let profile = execution.profile
                entries[index] = CapabilityAuditBatchEntryReceipt(
                    target: entries[index].target,
                    state: .audited,
                    reason: .audited,
                    attempts: attempt,
                    profileState: profile.state,
                    archetype: profile.archetype,
                    treeSignature: profile.identity.treeSignature,
                    treeNodeCount: profile.treeNodeCount,
                    treeTruncated: profile.treeTruncated,
                    auditAttempts: execution.attempts,
                    effectiveMaxNodes: execution.effectiveMaxNodes,
                    effectiveMaxDepth: execution.effectiveMaxDepth,
                    traversalMode: execution.traversalMode,
                    windowCount: execution.coverage?.windowCount,
                    pageCount: execution.coverage?.pageCount,
                    coverageComplete: execution.coverageComplete,
                    startedAt: startedAt,
                    completedAt: Date()
                )
            } catch AccessibilityControllerError.permissionDenied {
                entries[index] = CapabilityAuditBatchEntryReceipt(
                    target: entries[index].target,
                    state: .blocked,
                    reason: .permissionDenied,
                    attempts: attempt,
                    startedAt: startedAt,
                    completedAt: Date()
                )
            } catch CapabilityProfileStoreError.writeFailed {
                entries[index] = CapabilityAuditBatchEntryReceipt(
                    target: entries[index].target,
                    state: .failed,
                    reason: .profilePersistenceFailed,
                    attempts: attempt,
                    startedAt: startedAt,
                    completedAt: Date()
                )
            } catch {
                entries[index] = CapabilityAuditBatchEntryReceipt(
                    target: entries[index].target,
                    state: .failed,
                    reason: .auditFailed,
                    attempts: attempt,
                    startedAt: startedAt,
                    completedAt: Date()
                )
            }
            processedCount += 1
            run = run.replacingTargetsAndEntries(targets, entries: entries)
            try capabilityAuditBatchStore.save(run)
        }

        let report = CapabilityAuditBatchReport(
            run: run,
            resumed: resumed,
            processedCount: processedCount
        )
        return try success(
            request,
            value: report,
            evidence: [Evidence(
                kind: "control_capability_audit_batch",
                message: "A bounded, serialized, read-only audit batch persisted one resumable receipt per app; no applications were launched and no actions were dispatched",
                source: "macctld",
                metadata: [
                    "run_id": .string(run.runID),
                    "target_count": .number(Double(run.targets.count)),
                    "processed_count": .number(Double(processedCount)),
                    "remaining_count": .number(Double(run.remainingCount)),
                    "max_concurrency": .number(Double(run.maxConcurrency)),
                    "read_only": .bool(true),
                    "launched_applications": .bool(false)
                ]
            )]
        )
    }

    private func capabilityAuditBatchTargets(
        from request: RequestEnvelope
    ) throws -> [CapabilityAuditBatchTarget] {
        if let rawApps = request.params["apps"] {
            guard let values = rawApps.arrayValue, !values.isEmpty else {
                throw WorkflowExecutionError.unsafeInput("apps must be a non-empty array of app names, bundle IDs, or paths")
            }
            guard values.count <= CapabilityAuditCatalog.maximumTargets else {
                throw WorkflowExecutionError.unsafeInput(
                    "apps must contain at most \(CapabilityAuditCatalog.maximumTargets) targets"
                )
            }
            var targets: [CapabilityAuditBatchTarget] = []
            var seen = Set<String>()
            for value in values {
                guard let selector = value.stringValue,
                      !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw WorkflowExecutionError.unsafeInput("apps must contain only non-empty strings")
                }
                if let application = try? resolveApplication(selector) {
                    let target = CapabilityAuditBatchTarget(application: application)
                    guard seen.insert(target.stableKey).inserted else {
                        throw WorkflowExecutionError.unsafeInput("apps must contain unique targets")
                    }
                    targets.append(target)
                } else {
                    let target = CapabilityAuditBatchTarget(selector: selector)
                    guard seen.insert(target.stableKey).inserted else {
                        throw WorkflowExecutionError.unsafeInput("apps must contain unique targets")
                    }
                    targets.append(target)
                }
            }
            return targets
        }

        guard request.params["all_applicable"]?.boolValue == true else {
            throw WorkflowExecutionError.missingParameter("apps or all_applicable")
        }
        let targets = CapabilityAuditCatalog.defaultTargets(
            from: appController.listApplications(),
            limit: CapabilityAuditCatalog.maximumTargets
        )
        guard !targets.isEmpty else {
            throw WorkflowExecutionError.unsafeInput("no applicable user-facing applications were found")
        }
        return targets
    }

    private func auditCapabilityProfile(
        application: AppInfo,
        maxNodes: Int,
        maxDepth: Int
    ) throws -> CapabilityAuditExecution {
        guard let pid = application.processID else {
            throw AccessibilityControllerError.applicationNotRunning
        }
        let initialMaxNodes = CapabilityAuditBounds.normalizedNodes(maxNodes)
        let initialMaxDepth = CapabilityAuditBounds.normalizedDepth(maxDepth)
        var effectiveMaxNodes = initialMaxNodes
        var effectiveMaxDepth = initialMaxDepth
        var attempts = 0
        var tree: AccessibilityTreeReport
        while true {
            attempts += 1
            let candidate = try accessibilityTreeInspector.tree(
                pid: pid,
                application: application,
                maxNodes: effectiveMaxNodes,
                maxDepth: effectiveMaxDepth
            )
            if !candidate.truncated {
                tree = candidate
                break
            }

            let nextMaxNodes = CapabilityAuditBounds.nextNodes(after: effectiveMaxNodes)
            let nextMaxDepth = CapabilityAuditBounds.nextDepth(after: effectiveMaxDepth)
            guard nextMaxNodes != effectiveMaxNodes || nextMaxDepth != effectiveMaxDepth else {
                tree = candidate
                break
            }
            effectiveMaxNodes = nextMaxNodes
            effectiveMaxDepth = nextMaxDepth
        }

        var traversalMode = tree.coverage?.mode ?? "recursive"
        var coverage = tree.coverage
        var windowedAttempted = false
        if tree.truncated,
           let windowedInspector = accessibilityTreeInspector as? WindowedAccessibilityTreeInspecting {
            windowedAttempted = true
            let windowedTree = try windowedInspector.windowedTree(
                pid: pid,
                application: application,
                maxNodesPerPage: CapabilityAuditBounds.maximumNodes,
                maxDepth: CapabilityAuditBounds.maximumDepth,
                maxWindows: CapabilityAuditBounds.maximumWindows,
                maxPages: CapabilityAuditBounds.maximumPages
            )
            // A paginated report carries its own coverage proof. Prefer it
            // whenever available, including incomplete coverage, so the
            // persisted stale profile explains what was and was not observed.
            // A provider that does not return coverage cannot promote a new
            // broad profile merely because it returned more nodes.
            if windowedTree.coverage != nil {
                tree = windowedTree
                traversalMode = windowedTree.coverage?.mode ?? "windowed"
                coverage = windowedTree.coverage
            }
        }
        let profile = CapabilityProfileBuilder.build(
            application: application,
            osVersion: currentOSVersion(),
            providerState: currentCapabilityProviderState(),
            tree: tree
        )
        return CapabilityAuditExecution(
            profile: try capabilityProfileStore.save(profile),
            initialMaxNodes: initialMaxNodes,
            initialMaxDepth: initialMaxDepth,
            effectiveMaxNodes: effectiveMaxNodes,
            effectiveMaxDepth: effectiveMaxDepth,
            attempts: attempts,
            traversalMode: traversalMode,
            coverage: coverage,
            windowedAttempted: windowedAttempted
        )
    }

    private func capabilityAuditIdentityMismatch(
        expected: WarmPathApplicationIdentity,
        actual: AppInfo
    ) -> CapabilityAuditBatchReason? {
        let current = WarmPathApplicationIdentity(application: actual)
        guard expected.path == current.path,
              expected.bundleID == current.bundleID else {
            return .applicationIdentityChanged
        }
        guard expected.version == current.version else {
            return .applicationVersionChanged
        }
        return nil
    }

    private func performControlBatch(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        guard request.params["confirm"]?.boolValue == true else {
            throw KeyboardControlError.confirmationRequired
        }
        guard request.params["lease_token"]?.stringValue == nil else {
            throw WorkflowExecutionError.unsafeInput("control.batch owns one ephemeral app lease; do not provide lease_token")
        }
        let applicationName = try requiredString(request, key: "app")
        guard let actions = request.params["actions"]?.arrayValue, !actions.isEmpty else {
            throw WorkflowExecutionError.missingParameter("actions")
        }
        guard actions.count <= 32 else {
            throw WorkflowExecutionError.unsafeInput("control.batch accepts at most 32 actions")
        }
        let batchTaskID = request.params["task"]?.stringValue
        let batchTargetFingerprint = request.params["target_fingerprint"]?.stringValue
        if batchTaskID != nil && batchTargetFingerprint == nil {
            throw WarmPathSelectionError.targetFingerprintRequired
        }
        let parsedActions = try actions.enumerated().map { index, value -> (Int, [String: JSONValue]) in
            guard let object = value.objectValue else {
                throw WorkflowExecutionError.unsafeInput("control.batch action \(index) must be a JSON object")
            }
            guard let rawAction = object["action"]?.stringValue,
                  !rawAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowExecutionError.missingParameter("actions[\(index)].action")
            }
            if rawAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "scroll" {
                throw WorkflowExecutionError.unsafeInput(
                    "semantic scroll requires control.perform so target and provider handoff remain explicit"
                )
            }
            return (index, object)
        }

        let batch = try withExecutionLock { () throws -> ControlBatchReport in
            let activation = try activateAndStabilizeApplication(applicationName)
            let stableForeground = activation.application
            let lease = try keyboardDriveStore.acquire(
                scope: .app,
                application: stableForeground,
                seconds: 30,
                confirm: true
            )
            routeSelectionCache = nil
            defer {
                routeSelectionCache = nil
                keyboardDriveStore.invalidate(token: lease.token)
            }

            var steps: [ControlBatchStepReport] = []
            var routeSelectionCacheHits = 0
            for (index, object) in parsedActions {
                do {
                    var stepParams = object
                    if stepParams["task"] == nil, let batchTaskID {
                        stepParams["task"] = .string(batchTaskID)
                    }
                    if stepParams["target_fingerprint"] == nil, let batchTargetFingerprint {
                        stepParams["target_fingerprint"] = .string(batchTargetFingerprint)
                    }
                    let stepRequest = RequestEnvelope(method: "control.perform", params: stepParams)
                    let command = try KeyboardCommand.resolve(try requiredString(stepRequest, key: "action"))
                    let execution = try performControlActionWithLease(
                        command: command,
                        selector: try requestedControlSelector(from: stepRequest),
                        count: try requestedKeyboardCount(from: stepRequest),
                        interKeyDelay: try requestedInterKeyDelay(from: stepRequest),
                        allowRawCoordinate: stepRequest.params["allow_raw_coordinate"]?.boolValue == true,
                        taskID: stepRequest.params["task"]?.stringValue,
                        targetFingerprint: stepRequest.params["target_fingerprint"]?.stringValue,
                        requestedRoute: try requestedControlRoute(from: stepRequest),
                        application: foregroundApplication(),
                        leaseToken: lease.token,
                        foregroundFastPathUsed: activation.foregroundFastPathUsed,
                        expectedMenuItems: try requestedStringArray(from: stepRequest, key: "expected_menu_items")
                    )
                    guard execution.report.verification.state == .passed else {
                        throw WorkflowExecutionError.unsafeInput(
                            "batch action did not reach verified state (\(execution.report.verification.state.rawValue))"
                        )
                    }
                    if execution.routeSelectionCacheHit {
                        routeSelectionCacheHits += 1
                    }
                    steps.append(ControlBatchStepReport(
                        index: index,
                        action: execution.report.action,
                        route: execution.report.route,
                        verification: execution.report.verification.state,
                        fallbackUsed: execution.report.fallbackUsed,
                        routeSelectionCacheHit: execution.routeSelectionCacheHit
                    ))
                } catch {
                    throw ControlBatchExecutionError(
                        failedIndex: index,
                        completedCount: steps.count,
                        cause: error.localizedDescription
                    )
                }
            }
            return ControlBatchReport(
                application: WarmPathApplicationIdentity(application: stableForeground),
                actionCount: actions.count,
                completedCount: steps.count,
                routeSelectionCacheHits: routeSelectionCacheHits,
                foregroundFastPathUsed: activation.foregroundFastPathUsed,
                leaseReleased: true,
                steps: steps
            )
        }

        return try success(
            request,
            value: batch,
            evidence: [Evidence(
                kind: "control_batch",
                message: "A bounded sequence shared one app-scoped lease while revalidating every action and route selection",
                source: "macctld",
                metadata: [
                    "action_count": .number(Double(batch.actionCount)),
                    "completed_count": .number(Double(batch.completedCount)),
                    "route_selection_cache_hits": .number(Double(batch.routeSelectionCacheHits)),
                    "foreground_fast_path": .bool(batch.foregroundFastPathUsed),
                    "lease_released": .bool(batch.leaseReleased)
                ]
            )],
            outcome: AgentActionOutcome(
                state: .verifiedSuccess,
                route: "batch",
                verification: "passed"
            )
        )
    }

    private func performControlAction(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let token = request.params["lease_token"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedApplication = request.params["app"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasToken = token?.isEmpty == false
        let hasRequestedApplication = requestedApplication?.isEmpty == false
        guard !(hasToken && hasRequestedApplication) else {
            throw WorkflowExecutionError.unsafeInput(
                "control.perform accepts either lease_token or app, not both"
            )
        }
        let rawAction = try requiredString(request, key: "action")
        if rawAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "scroll" {
            return try performSemanticScroll(request)
        }
        let command = try KeyboardCommand.resolve(rawAction)
        let selector = try requestedControlSelector(from: request)
        let count = try requestedKeyboardCount(from: request)
        let interKeyDelay = try requestedInterKeyDelay(from: request)
        let expectedMenuItems = try requestedStringArray(from: request, key: "expected_menu_items")
        let allowRawCoordinate = request.params["allow_raw_coordinate"]?.boolValue == true
        let requestedRoute = try requestedControlRoute(from: request)
        let taskID = request.params["task"]?.stringValue
        let targetFingerprint = request.params["target_fingerprint"]?.stringValue
        let usesEphemeralLease = hasRequestedApplication
        let execution = try withExecutionLock {
            if let requestedApplication, !requestedApplication.isEmpty {
                guard request.params["confirm"]?.boolValue == true else {
                    throw KeyboardDriveStoreError.confirmationRequired
                }
                return try performEphemeralControlAction(
                    applicationName: requestedApplication,
                    command: command,
                    selector: selector,
                    count: count,
                    interKeyDelay: interKeyDelay,
                    allowRawCoordinate: allowRawCoordinate,
                    taskID: taskID,
                    targetFingerprint: targetFingerprint,
                    requestedRoute: requestedRoute,
                    expectedMenuItems: expectedMenuItems
                )
            }
            guard let token, !token.isEmpty else { throw KeyboardControlError.leaseRequired }
            return try performControlActionWithLease(
                command: command,
                selector: selector,
                count: count,
                interKeyDelay: interKeyDelay,
                allowRawCoordinate: allowRawCoordinate,
                taskID: taskID,
                targetFingerprint: targetFingerprint,
                requestedRoute: requestedRoute,
                application: foregroundApplication(),
                leaseToken: token,
                foregroundFastPathUsed: false,
                expectedMenuItems: expectedMenuItems
            )
        }
        // Existing-lease callers retain the lower-level dispatch report. The
        // atomic app-scoped surface and commands with concrete postconditions
        // must fail closed when the result cannot be observed.
        guard (!usesEphemeralLease && execution.report.verification.postcondition == nil)
                || execution.report.verification.state == .passed else {
            throw ControlVerificationFailure(
                route: execution.report.route,
                state: execution.report.verification.state,
                postcondition: execution.report.verification.postcondition
            )
        }
        return try success(
            request,
            value: execution.report,
            evidence: [Evidence(
                kind: "control_action",
                message: "Semantic control used the strongest available route and verified the resulting foreground state",
                source: "macctld",
                metadata: [
                    "route": .string(execution.report.route.rawValue),
                    "fallback_used": .bool(execution.report.fallbackUsed),
                    "fallback_chain": .array(execution.report.fallbackChain.map { .string($0.rawValue) }),
                    "verification": .string(execution.report.verification.state.rawValue),
                    "foreground_changed": .bool(execution.report.verification.foregroundChanged),
                    "focus_changed": .bool(execution.report.verification.focusChanged),
                    "lease_mode": .string(usesEphemeralLease ? "ephemeral" : "provided"),
                    "lease_released": .bool(usesEphemeralLease),
                    "foreground_reasserted": .bool(usesEphemeralLease),
                    "foreground_fast_path": .bool(execution.foregroundFastPathUsed),
                    "route_selection_cache": .string(
                        execution.routeSelectionCacheHit
                            ? "hit"
                            : (taskID == nil ? "not_used" : "miss")
                    )
                ]
            )],
            outcome: AgentActionOutcome(
                state: .verifiedSuccess,
                route: execution.report.route.rawValue,
                verification: execution.report.verification.state.rawValue,
                failureClass: nil,
                fallbackAllowed: false,
                recommendedProvider: nil,
                freshStateRequired: false,
                nextAction: nil
            )
        )
    }

    private func performControlActionWithLease(
        command: KeyboardCommand,
        selector: Selector?,
        count: Int,
        interKeyDelay: TimeInterval,
        allowRawCoordinate: Bool,
        taskID: String?,
        targetFingerprint: String?,
        requestedRoute: ControlActionRoute?,
        application: AppInfo?,
        leaseToken: String,
        foregroundFastPathUsed: Bool,
        expectedMenuItems: [String] = []
    ) throws -> ControlActionExecution {
        do {
            let selection = try routeSelection(
                taskID: taskID,
                targetFingerprint: targetFingerprint,
                application: application,
                leaseToken: leaseToken
            )
            let report = try semanticActionRouter.perform(
                command: command,
                selector: selector,
                leaseToken: leaseToken,
                count: count,
                interKeyDelay: interKeyDelay,
                allowRawCoordinate: allowRawCoordinate,
                requestedRoute: selection.report?.selectedRoute ?? requestedRoute,
                fallbackChain: selection.report?.fallbackChain ?? [],
                routeSelection: selection.report,
                expectedMenuItems: expectedMenuItems
            )
            let kind: CapabilityEvidenceKind = report.verification.state == .passed
                ? .positive
                : .ambiguous
            recordCapabilityVerification(
                application: application,
                taskID: taskID,
                targetFingerprint: targetFingerprint,
                route: report.route,
                selector: selector,
                kind: kind,
                reason: report.verification.state == .passed ? "verified_action" : "verification_unavailable"
            )
            return ControlActionExecution(
                report: report,
                foregroundFastPathUsed: foregroundFastPathUsed,
                routeSelectionCacheHit: selection.cacheHit
            )
        } catch {
            let (kind, reason) = capabilityEvidence(for: error)
            recordCapabilityVerification(
                application: application,
                taskID: taskID,
                targetFingerprint: targetFingerprint,
                route: requestedRoute ?? .keyboard,
                selector: selector,
                kind: kind,
                reason: reason
            )
            throw error
        }
    }

    private func activateAndStabilizeApplication(
        _ applicationName: String
    ) throws -> (application: AppInfo, foregroundFastPathUsed: Bool) {
        let currentForeground = foregroundApplication()
        let resolvedRequestedApplication = try? resolveApplication(applicationName)
        let activated: AppInfo
        let foregroundFastPathUsed: Bool
        if let currentForeground,
           let resolvedRequestedApplication,
           sameKeyboardApplication(resolvedRequestedApplication, currentForeground, requireProcess: true) {
            // The process identity is already exact. Keep the stability wait
            // below so a focus race still fails closed, but avoid reopening
            // and re-activating the already foreground app.
            activated = currentForeground
            foregroundFastPathUsed = true
        } else {
            activated = try activateApplication(applicationName)
            foregroundFastPathUsed = false
        }

        do {
            let observation = try foregroundStabilityVerifier.waitUntil(
                timeout: 2,
                pollInterval: 0.05,
                consecutiveMatches: 2,
                read: {
                    ControlObservation(
                        foregroundApplication: self.foregroundApplication(),
                        focusedElement: nil
                    )
                },
                predicate: { observation in
                    guard let current = observation.foregroundApplication else { return false }
                    return self.sameKeyboardApplication(
                        activated,
                        current,
                        requireProcess: activated.processID != nil
                    )
                }
            )
            guard let stableForeground = observation.foregroundApplication else {
                throw KeyboardControlError.foregroundUnavailable
            }
            return (stableForeground, foregroundFastPathUsed)
        } catch ControlStateVerifierError.timedOut {
            throw KeyboardControlError.appScopeMismatch(
                expected: keyboardApplicationLabel(activated),
                actual: keyboardApplicationLabel(foregroundApplication())
            )
        }
    }

    private func performEphemeralControlAction(
        applicationName: String,
        command: KeyboardCommand,
        selector: Selector?,
        count: Int,
        interKeyDelay: TimeInterval,
        allowRawCoordinate: Bool,
        taskID: String?,
        targetFingerprint: String?,
        requestedRoute: ControlActionRoute?,
        expectedMenuItems: [String] = []
    ) throws -> ControlActionExecution {
        let activation = try activateAndStabilizeApplication(applicationName)
        let stableForeground = activation.application
        let foregroundFastPathUsed = activation.foregroundFastPathUsed

        let lease = try keyboardDriveStore.acquire(
            scope: .app,
            application: stableForeground,
            seconds: 30,
            confirm: true
        )
        defer {
            routeSelectionCache = nil
            keyboardDriveStore.invalidate(token: lease.token)
        }
        return try performControlActionWithLease(
            command: command,
            selector: selector,
            count: count,
            interKeyDelay: interKeyDelay,
            allowRawCoordinate: allowRawCoordinate,
            taskID: taskID,
            targetFingerprint: targetFingerprint,
            requestedRoute: requestedRoute,
            application: stableForeground,
            leaseToken: lease.token,
            foregroundFastPathUsed: foregroundFastPathUsed,
            expectedMenuItems: expectedMenuItems
        )
    }

    private func performEphemeralSemanticScroll(
        applicationName: String,
        selector: Selector,
        direction: AccessibilityScrollDirection,
        amount: Int
    ) throws -> (report: AccessibilityScrollReport, foregroundFastPathUsed: Bool) {
        // AX scroll is selector- and process-scoped; it does not synthesize
        // global input. Preserve that direct route instead of forcing the
        // keyboard activation/stability guard onto it. The foreground probe
        // remains observable for benchmark accounting, while the AX
        // controller performs target re-resolution and viewport verification.
        let application = try resolveApplication(applicationName)
        guard application.isRunning, let processID = application.processID else {
            throw AccessibilityControllerError.applicationNotRunning
        }
        let foregroundFastPathUsed = foregroundApplication().map {
            sameKeyboardApplication(application, $0, requireProcess: true)
        } ?? false
        let report = try accessibilityScrollPerformer.scroll(
            pid: processID,
            application: application,
            selector: selector,
            direction: direction,
            amount: amount
        )
        return (report, foregroundFastPathUsed)
    }

    private func requestedControlRoute(from request: RequestEnvelope) throws -> ControlActionRoute? {
        guard let raw = request.params["route"]?.stringValue,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let normalized = raw.lowercased().replacingOccurrences(of: "-", with: "_")
        guard let route = ControlActionRoute(rawValue: normalized) else {
            throw WorkflowExecutionError.unsafeInput("unknown control route: \(raw)")
        }
        return route
    }

    private func benchmarkPermissions(for route: ControlActionRoute) -> [String] {
        switch route {
        case .accessibility:
            return ["Accessibility"]
        case .keyboard:
            return ["Accessibility", "Post Events"]
        case .scroll:
            return ["Accessibility"]
        case .visual, .normalizedCoordinate, .rawCoordinate:
            return ["Screen Recording", "Post Events"]
        }
    }

    private func routeSelection(
        taskID: String?,
        targetFingerprint: String?,
        application: AppInfo?,
        leaseToken: String?
    ) throws -> RouteSelectionResolution {
        guard let taskID else { return RouteSelectionResolution(report: nil, cacheHit: false) }
        guard let targetFingerprint, !targetFingerprint.isEmpty else {
            throw WarmPathSelectionError.targetFingerprintRequired
        }
        guard let application else { throw KeyboardControlError.foregroundUnavailable }
        let cachedManifest: WarmPathManifest?
        if let leaseToken,
           let cached = routeSelectionCache,
           cached.leaseToken == leaseToken,
           cached.application == application,
           cached.taskID == taskID,
           cached.targetFingerprint == targetFingerprint {
            cachedManifest = cached.manifest
        } else {
            cachedManifest = nil
        }
        let cacheHit = cachedManifest != nil
        guard let manifest = cachedManifest ?? warmPathStore.inspect(
            application: application,
            taskID: taskID,
            targetFingerprint: targetFingerprint
        ) else {
            throw WarmPathSelectionError.manifestNotFound
        }
        if !cacheHit, let leaseToken {
            routeSelectionCache = RouteSelectionCacheEntry(
                leaseToken: leaseToken,
                application: application,
                taskID: taskID,
                targetFingerprint: targetFingerprint,
                manifest: manifest
            )
        }
        let permissions = Set(PermissionDiagnostics.report()
            .filter { $0.state == "granted" }
            .map { $0.name.lowercased() })
        let report = WarmPathSelection.select(
            manifest: manifest,
            context: WarmPathSelectionContext(
                application: WarmPathApplicationIdentity(application: application),
                targetFingerprint: targetFingerprint,
                grantedPermissions: permissions,
                targetIsUnique: true,
                verificationAvailable: !manifest.verificationOracle.isEmpty
            )
        )
        guard report.selectedRoute != nil else {
            throw WarmPathSelectionError.noEligibleRoute
        }
        return RouteSelectionResolution(report: report, cacheHit: cacheHit)
    }

    private func routeList(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let manifests = warmPathStore.list()
        return try success(
            request,
            result: [
                "directory": .string(warmPathStore.directory.path),
                "manifests": .array(try manifests.map { try JSONValue.fromEncodable($0) }),
                "count": .number(Double(manifests.count))
            ],
            evidence: [Evidence(
                kind: "warm_path_registry",
                message: "Persisted app/task warm-path manifests were listed without launching an app",
                source: "macctld"
            )]
        )
    }

    private func routeInspect(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let application = try resolveApplication(try requiredString(request, key: "app"))
        let taskID = try requiredString(request, key: "task")
        let targetFingerprint = request.params["target_fingerprint"]?.stringValue
        let manifest = warmPathStore.inspect(
            application: application,
            taskID: taskID,
            targetFingerprint: targetFingerprint
        )
        return try success(
            request,
            result: [
                "application": try JSONValue.fromEncodable(WarmPathApplicationIdentity(application: application)),
                "task_id": .string(taskID),
                "target_fingerprint": targetFingerprint.map(JSONValue.string) ?? .null,
                "found": .bool(manifest != nil),
                "manifest": manifest.map { (try? JSONValue.fromEncodable($0)) ?? .null } ?? .null
            ],
            evidence: [Evidence(
                kind: "warm_path_inspection",
                message: "The warm-path registry was inspected for the requested app, task, and target",
                source: "macctld"
            )]
        )
    }

    private func routeBenchmark(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        guard request.params["confirm"]?.boolValue == true else {
            throw KeyboardControlError.confirmationRequired
        }
        let application = try resolveApplication(try requiredString(request, key: "app"))
        let taskID = try requiredString(request, key: "task")
        let targetFingerprint = try requiredString(request, key: "target_fingerprint")
        let verificationOracle = try requiredString(request, key: "verification_oracle")
        guard let route = try requestedControlRoute(from: request) else {
            throw WorkflowExecutionError.missingParameter("route")
        }
        let rawAction = try requiredString(request, key: "action")
        let selector = try requestedControlSelector(from: request)
        let count = try requestedKeyboardCount(from: request)
        let interKeyDelay = try requestedInterKeyDelay(from: request)
        let allowRawCoordinate = request.params["allow_raw_coordinate"]?.boolValue == true
        let warmups = try requestedNonNegativeInt(from: request, key: "warmups", defaultValue: 1)
        let samples = try requestedPositiveInt(from: request, key: "samples", defaultValue: 5)
        guard (0...20).contains(warmups), (1...50).contains(samples) else {
            throw WorkflowExecutionError.unsafeInput("warmups must be 0...20 and samples must be 1...50")
        }
        let requiredPermissions = request.params["required_permissions"] == nil
            ? benchmarkPermissions(for: route)
            : try requestedStringArray(from: request, key: "required_permissions")
        let freshness = try requestedPositiveDouble(
            from: request,
            key: "freshness_seconds",
            defaultValue: WarmPathStore.defaultFreshness
        )
        let tabCount = try requestedNonNegativeInt(from: request, key: "tab_count", defaultValue: 0)
        let scrollCount = try requestedNonNegativeInt(from: request, key: "scroll_count", defaultValue: 0)
        let coordinateUse = request.params["coordinate_use"]?.boolValue == true
        let userHelpCount = try requestedNonNegativeInt(from: request, key: "user_help_count", defaultValue: 0)
        let visualCoordinateOptIn = request.params["visual_coordinate_opt_in"]?.boolValue == true
        let declaredFallbackRoutes = try requestedRouteArray(from: request, key: "fallback_routes")

        let normalizedAction = rawAction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if normalizedAction == "scroll" || route == .scroll {
            guard normalizedAction == "scroll", route == .scroll else {
                throw WorkflowExecutionError.unsafeInput(
                    "semantic scroll benchmarks require action scroll and route scroll"
                )
            }
            return try routeSemanticScrollBenchmark(
                request,
                application: application,
                taskID: taskID,
                targetFingerprint: targetFingerprint,
                verificationOracle: verificationOracle,
                selector: selector,
                warmups: warmups,
                samples: samples,
                requiredPermissions: requiredPermissions,
                freshness: freshness,
                tabCount: tabCount,
                scrollCount: scrollCount,
                coordinateUse: coordinateUse,
                userHelpCount: userHelpCount,
                visualCoordinateOptIn: visualCoordinateOptIn,
                declaredFallbackRoutes: declaredFallbackRoutes
            )
        }

        let command = try KeyboardCommand.resolve(rawAction)
        let resetAction = request.params["reset_action"]?.stringValue
        let resetCommand = try resetAction.map(KeyboardCommand.resolve)
        let resetRoute = try request.params["reset_route"]?.stringValue.map { raw in
            guard let parsed = ControlActionRoute(
                rawValue: raw.lowercased().replacingOccurrences(of: "-", with: "_")
            ) else {
                throw WorkflowExecutionError.unsafeInput("unknown reset route: \(raw)")
            }
            return parsed
        } ?? route

        let benchmark = try withExecutionLock {
            var durations: [Double] = []
            var recoveries = 0
            var foregroundFastPathSamples = 0

            func runResetIfNeeded() throws {
                guard let resetCommand else { return }
                let reset = try performEphemeralControlAction(
                    applicationName: application.name,
                    command: resetCommand,
                    selector: selector,
                    count: count,
                    interKeyDelay: interKeyDelay,
                    allowRawCoordinate: allowRawCoordinate,
                    taskID: nil,
                    targetFingerprint: nil,
                    requestedRoute: resetRoute
                )
                guard reset.report.route == resetRoute else {
                    throw RouteBenchmarkError.routeMismatch(expected: resetRoute, actual: reset.report.route)
                }
                guard reset.report.verification.state == .passed else {
                    throw RouteBenchmarkError.verificationFailed(
                        route: resetRoute,
                        sample: 0,
                        state: reset.report.verification.state
                    )
                }
            }

            func runBenchmarkAction(sample: Int) throws -> ControlActionExecution {
                let execution = try performEphemeralControlAction(
                    applicationName: application.name,
                    command: command,
                    selector: selector,
                    count: count,
                    interKeyDelay: interKeyDelay,
                    allowRawCoordinate: allowRawCoordinate,
                    taskID: nil,
                    targetFingerprint: nil,
                    requestedRoute: route
                )
                guard execution.report.route == route else {
                    throw RouteBenchmarkError.routeMismatch(expected: route, actual: execution.report.route)
                }
                guard execution.report.verification.state == .passed else {
                    throw RouteBenchmarkError.verificationFailed(
                        route: route,
                        sample: sample,
                        state: execution.report.verification.state
                    )
                }
                return execution
            }

            for _ in 0..<warmups {
                try runResetIfNeeded()
                _ = try runBenchmarkAction(sample: 0)
            }

            for sample in 1...samples {
                try runResetIfNeeded()
                let started = DispatchTime.now().uptimeNanoseconds
                let execution = try runBenchmarkAction(sample: sample)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                durations.append(elapsed)
                if execution.foregroundFastPathUsed {
                    foregroundFastPathSamples += 1
                }
                if execution.report.fallbackUsed {
                    recoveries += 1
                }
            }

            let sorted = durations.sorted()
            let p95Index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1))
            let average = durations.reduce(0, +) / Double(durations.count)
            return (
                latencyMs: average,
                p95LatencyMs: sorted[p95Index],
                recoveries: recoveries,
                foregroundFastPathSamples: foregroundFastPathSamples
            )
        }

        let manifest = try warmPathStore.recordBenchmark(
            application: application,
            taskID: taskID,
            targetFingerprint: targetFingerprint,
            verificationOracle: verificationOracle,
            route: route,
            requiredPermissions: requiredPermissions,
            latencyMs: benchmark.latencyMs,
            p95LatencyMs: benchmark.p95LatencyMs,
            verificationRate: 1,
            recoveries: benchmark.recoveries,
            samples: samples,
            freshness: freshness,
            tabCount: tabCount,
            scrollCount: scrollCount,
            coordinateUse: coordinateUse,
            userHelpCount: userHelpCount,
            visualCoordinateOptIn: visualCoordinateOptIn,
            declaredFallbackRoutes: declaredFallbackRoutes,
            measurementSource: .daemonExecuted
        )
        return try success(
            request,
            result: [
                "manifest": try JSONValue.fromEncodable(manifest),
                "persisted": .bool(true),
                "measurement_source": .string("daemon_executed"),
                "sample_count": .number(Double(samples)),
                "warmup_count": .number(Double(warmups)),
                "latency_ms": .number(benchmark.latencyMs),
                "p95_latency_ms": .number(benchmark.p95LatencyMs),
                "verification_rate": .number(1),
                "foreground_fast_path_samples": .number(Double(benchmark.foregroundFastPathSamples))
            ],
            evidence: [Evidence(
                kind: "warm_path_benchmark",
                message: "The daemon executed and verified every bounded route sample before persisting warm-path metrics",
                source: "macctld",
                metadata: [
                    "route": .string(route.rawValue),
                    "target_fingerprint": .string(targetFingerprint),
                    "measurement_source": .string("daemon_executed"),
                    "samples": .number(Double(samples)),
                    "warmups": .number(Double(warmups)),
                    "verification_rate": .number(1),
                    "foreground_fast_path_samples": .number(Double(benchmark.foregroundFastPathSamples))
                ]
            )]
        )
    }

    private func routeSemanticScrollBenchmark(
        _ request: RequestEnvelope,
        application: AppInfo,
        taskID: String,
        targetFingerprint: String,
        verificationOracle: String,
        selector: Selector?,
        warmups: Int,
        samples: Int,
        requiredPermissions: [String],
        freshness: TimeInterval,
        tabCount: Int,
        scrollCount: Int,
        coordinateUse: Bool,
        userHelpCount: Int,
        visualCoordinateOptIn: Bool,
        declaredFallbackRoutes: [ControlActionRoute]
    ) throws -> ResponseEnvelope {
        let direction = try requestedScrollDirection(from: request, key: "direction")
        let amount = try requestedScrollAmount(from: request, key: "amount", defaultValue: nil)
        guard let selector,
              selector.role == "AXScrollArea",
              selector.identifier.map({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) ?? true else {
            throw WorkflowExecutionError.unsafeInput(
                "semantic scroll benchmarks require a selector with role AXScrollArea; identifier is optional when role-only resolution is unique"
            )
        }

        let resetDirection = try requestedOptionalScrollDirection(from: request, key: "reset_direction")
        guard resetDirection != nil || request.params["reset_amount"] == nil else {
            throw WorkflowExecutionError.unsafeInput(
                "--reset-amount requires --reset-direction for semantic scroll benchmarks"
            )
        }
        guard resetDirection == nil || request.params["reset_amount"] != nil else {
            throw WorkflowExecutionError.unsafeInput(
                "--reset-direction requires --reset-amount for semantic scroll benchmarks"
            )
        }
        let resetAmount = try requestedScrollAmount(
            from: request,
            key: "reset_amount",
            defaultValue: amount
        )
        if let resetDirection {
            guard resetDirection == oppositeScrollDirection(direction) else {
                throw WorkflowExecutionError.unsafeInput(
                    "--reset-direction must be the opposite direction of --direction"
                )
            }
        }
        if warmups + samples > 1, resetDirection == nil {
            throw WorkflowExecutionError.unsafeInput(
                "semantic scroll benchmarks with more than one execution require --reset-direction and --reset-amount"
            )
        }

        let benchmark = try withExecutionLock {
            var durations: [Double] = []
            var foregroundFastPathSamples = 0

            func execute(
                direction: AccessibilityScrollDirection,
                amount: Int,
                sample: Int
            ) throws -> (report: AccessibilityScrollReport, foregroundFastPathUsed: Bool) {
                let execution = try performEphemeralSemanticScroll(
                    applicationName: application.name,
                    selector: selector,
                    direction: direction,
                    amount: amount
                )
                guard execution.report.route == .scroll else {
                    throw RouteBenchmarkError.routeMismatch(
                        expected: .scroll,
                        actual: execution.report.route
                    )
                }
                guard execution.report.verification == .passed else {
                    throw RouteBenchmarkError.scrollVerificationFailed(
                        route: .scroll,
                        sample: sample,
                        state: execution.report.verification
                    )
                }
                return execution
            }

            func resetIfNeeded() throws {
                guard let resetDirection else { return }
                _ = try execute(
                    direction: resetDirection,
                    amount: resetAmount,
                    sample: 0
                )
            }

            for _ in 0..<warmups {
                try resetIfNeeded()
                _ = try execute(direction: direction, amount: amount, sample: 0)
            }

            for sample in 1...samples {
                try resetIfNeeded()
                let started = DispatchTime.now().uptimeNanoseconds
                let execution = try execute(
                    direction: direction,
                    amount: amount,
                    sample: sample
                )
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                durations.append(elapsed)
                if execution.foregroundFastPathUsed {
                    foregroundFastPathSamples += 1
                }
            }

            let sorted = durations.sorted()
            let p95Index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1))
            let average = durations.reduce(0, +) / Double(durations.count)
            return (
                latencyMs: average,
                p95LatencyMs: sorted[p95Index],
                foregroundFastPathSamples: foregroundFastPathSamples
            )
        }

        let manifest = try warmPathStore.recordBenchmark(
            application: application,
            taskID: taskID,
            targetFingerprint: targetFingerprint,
            verificationOracle: verificationOracle,
            route: .scroll,
            requiredPermissions: requiredPermissions,
            latencyMs: benchmark.latencyMs,
            p95LatencyMs: benchmark.p95LatencyMs,
            verificationRate: 1,
            recoveries: 0,
            samples: samples,
            freshness: freshness,
            tabCount: tabCount,
            scrollCount: scrollCount,
            coordinateUse: coordinateUse,
            userHelpCount: userHelpCount,
            visualCoordinateOptIn: visualCoordinateOptIn,
            declaredFallbackRoutes: declaredFallbackRoutes,
            measurementSource: .daemonExecuted
        )
        return try success(
            request,
            result: [
                "manifest": try JSONValue.fromEncodable(manifest),
                "persisted": .bool(true),
                "measurement_source": .string("daemon_executed"),
                "sample_count": .number(Double(samples)),
                "warmup_count": .number(Double(warmups)),
                "latency_ms": .number(benchmark.latencyMs),
                "p95_latency_ms": .number(benchmark.p95LatencyMs),
                "verification_rate": .number(1),
                "foreground_fast_path_samples": .number(Double(benchmark.foregroundFastPathSamples)),
                "route": .string(ControlActionRoute.scroll.rawValue),
                "direction": .string(direction.rawValue),
                "amount": .number(Double(amount)),
                "reset_direction": resetDirection.map { .string($0.rawValue) } ?? .null,
                "reset_amount": .number(Double(resetAmount))
            ],
            evidence: [Evidence(
                kind: "warm_path_benchmark",
                message: "The daemon executed and verified every bounded semantic scroll sample before persisting warm-path metrics",
                source: "macctld",
                metadata: [
                    "route": .string(ControlActionRoute.scroll.rawValue),
                    "target_fingerprint": .string(targetFingerprint),
                    "measurement_source": .string("daemon_executed"),
                    "samples": .number(Double(samples)),
                    "warmups": .number(Double(warmups)),
                    "verification_rate": .number(1),
                    "foreground_fast_path_samples": .number(Double(benchmark.foregroundFastPathSamples)),
                    "reset_direction": resetDirection.map { .string($0.rawValue) } ?? .null
                ]
            )]
        )
    }

    private func routeRegister(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        guard request.params["confirm"]?.boolValue == true else {
            throw KeyboardControlError.confirmationRequired
        }
        let application = try resolveApplication(try requiredString(request, key: "app"))
        let taskID = try requiredString(request, key: "task")
        let targetFingerprint = try requiredString(request, key: "target_fingerprint")
        let verificationOracle = try requiredString(request, key: "verification_oracle")
        guard let route = try requestedControlRoute(from: request) else {
            throw WorkflowExecutionError.missingParameter("route")
        }
        let manifest = try warmPathStore.recordBenchmark(
            application: application,
            taskID: taskID,
            targetFingerprint: targetFingerprint,
            verificationOracle: verificationOracle,
            route: route,
            requiredPermissions: try requestedStringArray(from: request, key: "required_permissions"),
            latencyMs: try requestedDouble(from: request, key: "latency_ms"),
            p95LatencyMs: try requestedDouble(from: request, key: "p95_latency_ms"),
            verificationRate: try requestedDouble(from: request, key: "verification_rate"),
            recoveries: try requestedNonNegativeInt(from: request, key: "recoveries", defaultValue: 0),
            samples: try requestedPositiveInt(from: request, key: "samples", defaultValue: 1),
            freshness: try requestedPositiveDouble(
                from: request,
                key: "freshness_seconds",
                defaultValue: WarmPathStore.defaultFreshness
            ),
            tabCount: try requestedNonNegativeInt(from: request, key: "tab_count", defaultValue: 0),
            scrollCount: try requestedNonNegativeInt(from: request, key: "scroll_count", defaultValue: 0),
            coordinateUse: request.params["coordinate_use"]?.boolValue == true,
            userHelpCount: try requestedNonNegativeInt(from: request, key: "user_help_count", defaultValue: 0),
            visualCoordinateOptIn: request.params["visual_coordinate_opt_in"]?.boolValue == true,
            declaredFallbackRoutes: try requestedRouteArray(from: request, key: "fallback_routes"),
            measurementSource: .callerSupplied
        )
        return try success(
            request,
            result: [
                "manifest": try JSONValue.fromEncodable(manifest),
                "persisted": .bool(true),
                "measurement_source": .string("caller_supplied")
            ],
            evidence: [Evidence(
                kind: "warm_path_registration",
                message: "Caller-supplied route metadata was explicitly registered; use route benchmark for daemon-executed measurements",
                source: "macctld",
                metadata: [
                    "route": .string(route.rawValue),
                    "target_fingerprint": .string(targetFingerprint),
                    "measurement_source": .string("caller_supplied")
                ]
            )]
        )
    }

    private func accessibilityTree(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let application = try runningAccessibilityApplication(from: request)
        let report = try accessibilityTreeInspector.tree(
            pid: application.processID!,
            application: application,
            maxNodes: try requestedNonNegativeInt(
                from: request,
                key: "max_nodes",
                defaultValue: CapabilityAuditBounds.defaultMaxNodes
            ),
            maxDepth: try requestedNonNegativeInt(
                from: request,
                key: "max_depth",
                defaultValue: CapabilityAuditBounds.defaultMaxDepth
            )
        )
        return try success(
            request,
            value: report,
            evidence: [Evidence(
                kind: "accessibility_tree",
                message: "A bounded Accessibility tree was inspected with values, private text, screenshots, and OCR excluded",
                source: "macctld",
                metadata: [
                    "redacted": .bool(report.redacted),
                    "bounded": .bool(true),
                    "truncated": .bool(report.truncated)
                ]
            )]
        )
    }

    private func accessibilityAudit(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let application = try runningAccessibilityApplication(from: request)
        guard let manifestValue = request.params["manifest"],
              let data = try? JSONCodec.encode(manifestValue) else {
            throw WorkflowExecutionError.missingParameter("manifest")
        }
        let manifest: AccessibilityAuditManifest
        do {
            manifest = try JSONCodec.decode(AccessibilityAuditManifest.self, from: data)
        } catch {
            throw WorkflowExecutionError.unsafeInput("manifest is not a valid accessibility audit manifest")
        }
        let report = try accessibilityTreeInspector.audit(
            pid: application.processID!,
            application: application,
            manifest: manifest
        )
        return try success(
            request,
            value: report,
            evidence: [Evidence(
                kind: "accessibility_audit",
                message: report.valid
                    ? "Accessibility audit passed within the bounded redacted tree"
                    : "Accessibility audit reported actionable contract findings",
                source: "macctld",
                metadata: [
                    "valid": .bool(report.valid),
                    "finding_count": .number(Double(report.findings.count)),
                    "redacted": .bool(report.tree.redacted)
                ]
            )]
        )
    }

    private func idealStateAudit(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let application = try runningAccessibilityApplication(from: request)
        guard let manifestValue = request.params["manifest"],
              let data = try? JSONCodec.encode(manifestValue) else {
            throw WorkflowExecutionError.missingParameter("manifest")
        }
        let manifest: MacControlIdealStateManifest
        do {
            manifest = try JSONCodec.decode(MacControlIdealStateManifest.self, from: data)
        } catch {
            throw WorkflowExecutionError.unsafeInput("manifest is not a valid Mac Control ideal-state manifest")
        }
        let validation = MacControlIdealStateManifestValidator.validate(manifest)
        var findings = validation.errors.map { error in
            AccessibilityAuditFinding(
                severity: .error,
                code: "invalid_manifest",
                target: manifest.repositoryID,
                message: error
            )
        }
        var structuralValid = validation.valid
        if validation.valid && MacControlIdealStateManifestValidator.token(manifest.applicability) == "applicable" {
            let accessibilityManifest = AccessibilityAuditManifest(
                controls: manifest.tasks.compactMap(\.accessibility)
            )
            let report = try accessibilityTreeInspector.audit(
                pid: application.processID!,
                application: application,
                manifest: accessibilityManifest
            )
            findings.append(contentsOf: report.findings)
            structuralValid = report.valid
        }
        let audit = MacControlIdealStateLiveAudit(
            application: application,
            manifestValid: validation.valid,
            structuralValid: structuralValid,
            findings: findings
        )
        return try success(
            request,
            value: audit,
            evidence: [Evidence(
                kind: "ideal_state_audit",
                message: structuralValid
                    ? "Mac Control validated the task manifest and bounded structural Accessibility evidence"
                    : "Mac Control found manifest or bounded structural Accessibility gaps",
                source: "macctld",
                metadata: [
                    "manifest_valid": .bool(validation.valid),
                    "structural_valid": .bool(structuralValid),
                    "finding_count": .number(Double(findings.count)),
                    "redacted": .bool(true)
                ]
            )]
        )
    }

    private func performSemanticScroll(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        guard request.params["confirm"]?.boolValue == true else {
            throw KeyboardControlError.confirmationRequired
        }
        guard request.params["lease_token"]?.stringValue == nil else {
            throw WorkflowExecutionError.unsafeInput("semantic scrolling requires an app-scoped atomic request")
        }
        let applicationName = try requiredString(request, key: "app")
        let direction = try requestedScrollDirection(from: request, key: "direction")
        let amount = try requestedScrollAmount(from: request, key: "amount", defaultValue: nil)
        let selector = try requestedControlSelector(from: request)
            ?? Selector(
                role: request.params["role"]?.stringValue,
                identifier: request.params["identifier"]?.stringValue
            )
        let requestedFallback = try requestedScrollFallback(from: request)
        let resolvedApplication = try? resolveApplication(applicationName)
        let execution: SemanticScrollExecution
        do {
            execution = try withExecutionLock { () -> SemanticScrollExecution in
                do {
                    let scrollExecution = try performEphemeralSemanticScroll(
                        applicationName: applicationName,
                        selector: selector,
                        direction: direction,
                        amount: amount
                    )
                    let report = scrollExecution.report
                    guard report.verification == .passed else {
                        let failureClass: SemanticScrollFailureClass = switch report.verification {
                        case .noObservedChange:
                            .noObservedChange
                        case .dispatched, .verificationUnavailable:
                            .verificationUnavailable
                        case .passed:
                            .actionFailed
                        }
                        throw semanticScrollFailure(
                            for: failureClass,
                            requestedFallback: requestedFallback,
                            message: "Accessibility scroll did not produce a verified visible change"
                        )
                    }
                    return .accessibility(report)
                } catch let error as SemanticScrollFailure {
                    throw error
                } catch let error as AccessibilityControllerError {
                    let failure = semanticScrollFailure(
                        for: error,
                        requestedFallback: requestedFallback
                    )
                    guard failure.fallbackAllowed,
                          requestedFallback == .inputScroll else {
                        throw failure
                    }

                    do {
                        let inputReport = try inputScrollPerformer.scroll(
                            amount: Int32(amount),
                            direction: direction.rawValue
                        )
                        switch inputReport.verification {
                        case .passed:
                            return .input(inputReport, from: failure.failureClass)
                        case .noObservedChange:
                            throw semanticScrollFailure(
                                for: .noObservedChange,
                                requestedFallback: requestedFallback,
                                message: "The declared low-level scroll fallback produced no observed change",
                                localFallbackDispatched: true,
                                localFallbackVerification: inputReport.verification
                            )
                        case .dispatched, .verificationUnavailable:
                            throw semanticScrollFailure(
                                for: .verificationUnavailable,
                                requestedFallback: requestedFallback,
                                message: "The declared low-level scroll fallback dispatched an event but could not verify the visible result",
                                localFallbackDispatched: true,
                                localFallbackVerification: inputReport.verification
                            )
                        }
                    } catch let error as SemanticScrollFailure {
                        throw error
                    } catch {
                        throw semanticScrollFailure(
                            for: .actionFailed,
                            requestedFallback: requestedFallback,
                            message: "The declared low-level scroll fallback failed: \(error.localizedDescription)",
                            localFallbackDispatched: false
                        )
                    }
                }
            }
        } catch let error as SemanticScrollFailure {
            let kind: CapabilityEvidenceKind = error.failureClass == .targetAmbiguous
                ? .ambiguous
                : .negative
            let reason: String = switch error.failureClass {
            case .targetAmbiguous: CapabilityProfileInvalidationReason.targetAmbiguous.rawValue
            case .noObservedChange, .verificationUnavailable: CapabilityProfileInvalidationReason.verificationFailed.rawValue
            default: CapabilityProfileInvalidationReason.actionFailed.rawValue
            }
            recordCapabilityVerification(
                application: resolvedApplication,
                taskID: request.params["task"]?.stringValue,
                targetFingerprint: request.params["target_fingerprint"]?.stringValue,
                route: .scroll,
                selector: selector,
                kind: kind,
                reason: reason
            )
            throw error
        } catch {
            recordCapabilityVerification(
                application: resolvedApplication,
                taskID: request.params["task"]?.stringValue,
                targetFingerprint: request.params["target_fingerprint"]?.stringValue,
                route: .scroll,
                selector: selector,
                kind: .negative,
                reason: CapabilityProfileInvalidationReason.actionFailed.rawValue
            )
            throw error
        }

        switch execution {
        case .accessibility(let report):
            recordCapabilityVerification(
                application: report.application,
                taskID: request.params["task"]?.stringValue,
                targetFingerprint: request.params["target_fingerprint"]?.stringValue,
                route: .scroll,
                selector: selector,
                kind: .positive,
                reason: "verified_action"
            )
            return try success(
                request,
                value: report,
                evidence: [Evidence(
                    kind: "semantic_scroll",
                    message: "A uniquely addressable semantic scroll container was acted on and re-resolved after scrolling",
                    source: "macctld",
                    metadata: [
                        "route": .string(ControlActionRoute.scroll.rawValue),
                        "verification": .string(report.verification.rawValue),
                        "verification_basis": .string("target_re_resolved"),
                        "lease_released": .bool(true)
                    ]
                )],
                outcome: AgentActionOutcome(
                    state: .verifiedSuccess,
                    route: ControlActionRoute.scroll.rawValue,
                    verification: report.verification.rawValue
                )
            )
        case .input(let report, let originalFailure):
            recordCapabilityVerification(
                application: resolvedApplication,
                taskID: request.params["task"]?.stringValue,
                targetFingerprint: request.params["target_fingerprint"]?.stringValue,
                route: .scroll,
                selector: selector,
                kind: .positive,
                reason: "verified_input_fallback"
            )
            return try success(
                request,
                value: report,
                evidence: [Evidence(
                    kind: "scroll_fallback",
                    message: "Accessibility scrolling was unavailable; the explicitly declared low-level input scroll fallback was dispatched and verified",
                    source: "macctld",
                    metadata: [
                        "route": .string(report.route),
                        "fallback_from": .string(ControlActionRoute.scroll.rawValue),
                        "original_failure": .string(originalFailure.rawValue),
                        "verification": .string(report.verification.rawValue),
                        "lease_released": .bool(true)
                    ]
                )],
                outcome: AgentActionOutcome(
                    state: .verifiedSuccess,
                    route: report.route,
                    verification: report.verification.rawValue,
                    failureClass: originalFailure.rawValue
                )
            )
        }
    }

    private func requestedScrollFallback(from request: RequestEnvelope) throws -> ScrollFallbackRoute? {
        guard let raw = request.params["fallback_route"]?.stringValue,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let normalized = raw.lowercased().replacingOccurrences(of: "-", with: "_")
        guard let route = ScrollFallbackRoute(rawValue: normalized) else {
            throw WorkflowExecutionError.unsafeInput(
                "unknown scroll fallback route: \(raw); expected input_scroll or computer_use"
            )
        }
        return route
    }

    private func semanticScrollFailure(
        for error: AccessibilityControllerError,
        requestedFallback: ScrollFallbackRoute?,
        localFallbackDispatched: Bool = false,
        localFallbackVerification: ScrollVerificationState? = nil
    ) -> SemanticScrollFailure {
        switch error {
        case .elementNotFound, .windowNotFound, .scrollTargetRequired:
            return semanticScrollFailure(
                for: .targetMissing,
                requestedFallback: requestedFallback,
                message: error.localizedDescription,
                localFallbackDispatched: localFallbackDispatched,
                localFallbackVerification: localFallbackVerification
            )
        case .scrollUnavailable:
            return semanticScrollFailure(
                for: .actionUnavailable,
                requestedFallback: requestedFallback,
                message: error.localizedDescription,
                localFallbackDispatched: localFallbackDispatched,
                localFallbackVerification: localFallbackVerification
            )
        case .ambiguousMatch, .ambiguousWindowMatch:
            return semanticScrollFailure(
                for: .targetAmbiguous,
                requestedFallback: requestedFallback,
                message: error.localizedDescription,
                localFallbackDispatched: localFallbackDispatched,
                localFallbackVerification: localFallbackVerification
            )
        case .actionUnavailable:
            return semanticScrollFailure(
                for: .actionUnavailable,
                requestedFallback: requestedFallback,
                message: error.localizedDescription,
                localFallbackDispatched: localFallbackDispatched,
                localFallbackVerification: localFallbackVerification
            )
        case .actionFailed:
            return semanticScrollFailure(
                for: .actionFailed,
                requestedFallback: requestedFallback,
                message: error.localizedDescription,
                localFallbackDispatched: localFallbackDispatched,
                localFallbackVerification: localFallbackVerification
            )
        case .permissionDenied:
            return semanticScrollFailure(
                for: .permissionDenied,
                requestedFallback: requestedFallback,
                message: error.localizedDescription,
                localFallbackDispatched: localFallbackDispatched,
                localFallbackVerification: localFallbackVerification
            )
        case .applicationNotRunning, .unreadableFocus, .boundsUnavailable:
            return semanticScrollFailure(
                for: .actionFailed,
                requestedFallback: requestedFallback,
                message: error.localizedDescription,
                localFallbackDispatched: localFallbackDispatched,
                localFallbackVerification: localFallbackVerification
            )
        }
    }

    private func semanticScrollFailure(
        for failureClass: SemanticScrollFailureClass,
        requestedFallback: ScrollFallbackRoute?,
        message: String,
        localFallbackDispatched: Bool = false,
        localFallbackVerification: ScrollVerificationState? = nil
    ) -> SemanticScrollFailure {
        let fallbackAllowed: Bool
        switch failureClass {
        case .targetMissing, .actionUnavailable, .permissionDenied:
            fallbackAllowed = true
        case .targetAmbiguous, .actionFailed, .noObservedChange, .verificationUnavailable:
            fallbackAllowed = false
        }
        let recommendsComputerUse = failureClass != .targetAmbiguous
        return SemanticScrollFailure(
            failureClass: failureClass,
            message: message,
            recommendedProvider: recommendsComputerUse ? .computerUse : nil,
            freshStateRequired: recommendsComputerUse,
            fallbackAllowed: fallbackAllowed,
            requestedFallback: requestedFallback,
            localFallbackDispatched: localFallbackDispatched,
            localFallbackVerification: localFallbackVerification
        )
    }

    private func runningAccessibilityApplication(from request: RequestEnvelope) throws -> AppInfo {
        let application = try resolveApplication(try requiredString(request, key: "app"))
        guard application.isRunning, application.processID != nil else {
            throw AccessibilityControllerError.applicationNotRunning
        }
        return application
    }

    private func currentOSVersion() -> String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    private func currentCapabilityProviderState() -> CapabilityProviderState {
        let permissions = permissionContext == "daemon"
            ? PermissionDiagnostics.report()
            : PermissionDiagnostics.unknownReport()
        return CapabilityProviderState(permissionStatuses: permissions)
    }

    /// Task evidence is advisory to the profile cache. A broken cache must
    /// never turn a verified control action into a failed control action.
    private func recordCapabilityVerification(
        application: AppInfo?,
        taskID: String?,
        targetFingerprint: String?,
        route: ControlActionRoute,
        selector: Selector?,
        kind: CapabilityEvidenceKind,
        reason: String
    ) {
        guard let application,
              let taskID,
              let targetFingerprint,
              !taskID.isEmpty,
              !targetFingerprint.isEmpty else {
            return
        }
        do {
            _ = try capabilityProfileStore.recordTaskVerification(
                application: application,
                osVersion: currentOSVersion(),
                providerState: currentCapabilityProviderState(),
                taskID: taskID,
                targetFingerprint: targetFingerprint,
                route: route,
                selector: selector,
                kind: kind,
                reason: reason
            )
        } catch {
            logger.record(event: "capability_profile_update_failed", metadata: [
                "task": taskID,
                "route": route.rawValue,
                "error": error.localizedDescription
            ])
        }
    }

    private func capabilityEvidence(for error: Error) -> (CapabilityEvidenceKind, String) {
        let description = error.localizedDescription.lowercased()
        if description.contains("ambiguous") {
            return (.ambiguous, CapabilityProfileInvalidationReason.targetAmbiguous.rawValue)
        }
        if description.contains("verification") || description.contains("focus") {
            return (.negative, CapabilityProfileInvalidationReason.verificationFailed.rawValue)
        }
        if description.contains("stale") || description.contains("element") {
            return (.negative, CapabilityProfileInvalidationReason.staleElement.rawValue)
        }
        return (.negative, CapabilityProfileInvalidationReason.actionFailed.rawValue)
    }

    private func requestedDouble(from request: RequestEnvelope, key: String) throws -> Double {
        guard let value = request.params[key]?.doubleValue, value.isFinite else {
            throw WorkflowExecutionError.unsafeInput("\(key) must be a finite number")
        }
        return value
    }

    private func requestedPositiveDouble(
        from request: RequestEnvelope,
        key: String,
        defaultValue: Double
    ) throws -> Double {
        guard let raw = request.params[key] else { return defaultValue }
        guard let value = raw.doubleValue, value.isFinite, value > 0 else {
            throw WorkflowExecutionError.unsafeInput("\(key) must be a positive finite number")
        }
        return value
    }

    private func requestedNonNegativeInt(
        from request: RequestEnvelope,
        key: String,
        defaultValue: Int
    ) throws -> Int {
        guard let raw = request.params[key] else { return defaultValue }
        guard let value = raw.doubleValue, value.isFinite, value.rounded() == value, value >= 0 else {
            throw WorkflowExecutionError.unsafeInput("\(key) must be a non-negative integer")
        }
        return Int(value)
    }

    private func requestedPositiveInt(
        from request: RequestEnvelope,
        key: String,
        defaultValue: Int?
    ) throws -> Int {
        guard let raw = request.params[key] else {
            if let defaultValue { return defaultValue }
            throw WorkflowExecutionError.missingParameter(key)
        }
        guard let value = raw.doubleValue, value.isFinite, value.rounded() == value, value > 0 else {
            throw WorkflowExecutionError.unsafeInput("\(key) must be a positive integer")
        }
        return Int(value)
    }

    private func requestedScrollDirection(
        from request: RequestEnvelope,
        key: String
    ) throws -> AccessibilityScrollDirection {
        guard let direction = try requestedOptionalScrollDirection(from: request, key: key) else {
            throw WorkflowExecutionError.missingParameter(key)
        }
        return direction
    }

    private func requestedOptionalScrollDirection(
        from request: RequestEnvelope,
        key: String
    ) throws -> AccessibilityScrollDirection? {
        guard let raw = request.params[key] else { return nil }
        guard let value = raw.stringValue,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowExecutionError.unsafeInput("\(key) must be up, down, left, or right")
        }
        guard let direction = AccessibilityScrollDirection(
            rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ) else {
            throw WorkflowExecutionError.unsafeInput("\(key) must be up, down, left, or right")
        }
        return direction
    }

    private func requestedScrollAmount(
        from request: RequestEnvelope,
        key: String,
        defaultValue: Int?
    ) throws -> Int {
        let amount = try requestedPositiveInt(from: request, key: key, defaultValue: defaultValue)
        guard (1...20).contains(amount) else {
            throw WorkflowExecutionError.unsafeInput("\(key) must be between 1 and 20")
        }
        return amount
    }

    private func oppositeScrollDirection(
        _ direction: AccessibilityScrollDirection
    ) -> AccessibilityScrollDirection {
        switch direction {
        case .up: return .down
        case .down: return .up
        case .left: return .right
        case .right: return .left
        }
    }

    private func requestedStringArray(from request: RequestEnvelope, key: String) throws -> [String] {
        guard let raw = request.params[key] else { return [] }
        guard let values = raw.arrayValue else {
            throw WorkflowExecutionError.unsafeInput("\(key) must be an array of strings")
        }
        var result: [String] = []
        for value in values {
            guard let string = value.stringValue,
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowExecutionError.unsafeInput("\(key) must contain only non-empty strings")
            }
            result.append(string)
        }
        return result
    }

    private func requestedRouteArray(from request: RequestEnvelope, key: String) throws -> [ControlActionRoute] {
        guard let raw = request.params[key] else { return [] }
        let values: [String]
        if let array = raw.arrayValue {
            values = try array.map { value in
                guard let string = value.stringValue else {
                    throw WorkflowExecutionError.unsafeInput("\(key) must contain route strings")
                }
                return string
            }
        } else if let string = raw.stringValue {
            values = string.split(separator: ",").map(String.init)
        } else {
            throw WorkflowExecutionError.unsafeInput("\(key) must be a route array or comma-separated string")
        }
        return try values.map { rawRoute in
            let normalized = rawRoute.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            guard let route = ControlActionRoute(rawValue: normalized) else {
                throw WorkflowExecutionError.unsafeInput("unknown control route: \(rawRoute)")
            }
            return route
        }
    }

    private func requestedControlSelector(from request: RequestEnvelope) throws -> Selector? {
        guard let raw = request.params["selector"] else { return nil }
        if raw == .null { return nil }
        guard raw.objectValue != nil,
              let data = try? JSONCodec.encode(raw),
              let selector = try? JSONCodec.decode(Selector.self, from: data) else {
            throw SemanticActionRouterError.invalidSelector
        }
        return selector
    }

    private func requireKeyboardInputLease(
        token: String,
        requireFullKeyboardAccess: Bool
    ) throws -> (KeyboardDriveLease, AppInfo) {
        let lease = try keyboardDriveStore.lease(for: token)
        guard hasPostEventAccess() else {
            throw KeyboardControlError.permissionDenied("Post Events")
        }
        guard let application = foregroundApplication(), application.processID != nil else {
            throw KeyboardControlError.foregroundUnavailable
        }
        if lease.scope == .app {
            guard let expected = lease.application,
                  sameKeyboardApplication(expected, application, requireProcess: true) else {
                throw KeyboardControlError.appScopeMismatch(
                    expected: keyboardApplicationLabel(lease.application),
                    actual: keyboardApplicationLabel(application)
                )
            }
        }
        if requireFullKeyboardAccess {
            let status = keyboardAccessController.status(
                permissionContext: permissionContext,
                activeLease: lease
            )
            guard status.fullKeyboardAccessEnabled == true else {
                throw KeyboardControlError.fullKeyboardAccessDisabled
            }
        }
        return (lease, application)
    }

    private func requestedKeyboardLifetime(from request: RequestEnvelope) throws -> TimeInterval? {
        guard let raw = request.params["seconds"] else { return nil }
        guard let seconds = raw.doubleValue else { throw KeyboardDriveStoreError.invalidLifetime }
        return seconds
    }

    private func requestedKeyboardCount(from request: RequestEnvelope) throws -> Int {
        guard let raw = request.params["count"] else { return 1 }
        guard let value = raw.doubleValue, value.rounded() == value else {
            throw KeyboardControlError.repetitionLimitExceeded
        }
        return Int(value)
    }

    private func requestedInterKeyDelay(from request: RequestEnvelope) throws -> TimeInterval {
        guard let raw = request.params["inter_key_ms"] else { return 0.05 }
        guard let milliseconds = raw.doubleValue, (0...1_000).contains(milliseconds) else {
            throw KeyboardControlError.invalidInterKeyDelay
        }
        return milliseconds / 1_000
    }

    private func sameKeyboardApplication(
        _ expected: AppInfo,
        _ actual: AppInfo,
        requireProcess: Bool
    ) -> Bool {
        if requireProcess, expected.processID != actual.processID {
            return false
        }
        if let expectedBundle = expected.bundleID, let actualBundle = actual.bundleID {
            return expectedBundle == actualBundle
        }
        return expected.path == actual.path
    }

    private func keyboardApplicationLabel(_ application: AppInfo?) -> String {
        application?.bundleID ?? application?.path ?? application?.name ?? "none"
    }

    private func prepareTask(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let plan = try taskPlan(from: request)
        let prepared = try withExecutionLock {
            try taskRunner.prepare(
                plan: plan,
                ephemeralInputs: try ephemeralInputs(from: request),
                operationID: UUID().uuidString
            )
        }
        presentApproval?(prepared.approval)
        logger.record(event: "task_prepared", metadata: [
            "task_id": prepared.taskID,
            "plan_digest": prepared.planDigest,
            "operation_id": prepared.approval.operationID
        ])
        return try success(
            request,
            status: .prepared,
            operationID: prepared.approval.operationID,
            value: prepared,
            evidence: [Evidence(
                kind: "task_approval",
                message: "Exact task plan prepared; approval is required before execution",
                source: "macctld"
            )]
        )
    }

    private func runTask(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let plan = try taskPlan(from: request)
        let token = try requiredString(request, key: "approval_token")
        let inputs = try ephemeralInputs(from: request)
        let reservation = try taskAuthority(
            for: plan,
            request: request,
            approvalToken: token,
            ephemeralInputs: inputs,
            force: false
        )
        let executionID = reservation.lease.map {
            beginControlCenterExecution(
                taskID: plan.id,
                summary: plan.summary,
                applicationName: ApprovalHandoffTargetResolver.resolve(for: plan)?.applicationName,
                lease: $0,
                leaseOwnedByDaemon: reservation.ownedByDaemon
            )
        }
        defer {
            if reservation.ownedByDaemon, let lease = reservation.lease {
                keyboardDriveStore.invalidate(token: lease.token)
            }
            if let executionID { finishControlCenterExecution(executionID: executionID) }
        }
        let report = try withExecutionLock {
            try taskRunner.run(
                plan: plan,
                approvalToken: token,
                ephemeralInputs: inputs,
                authority: reservation.authority
            )
        }
        return try taskResponse(
            request,
            report: report,
            message: "Task completed",
            inputChannel: reservation.authority?.inputChannel
        )
    }

    private func statusTask(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let taskID = try requiredString(request, key: "task_id")
        let report = try withExecutionLock { try taskRunner.status(taskID: taskID) }
        return try taskResponse(request, report: report, message: "Task status")
    }

    private func resumeTask(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let plan = try taskPlan(from: request)
        let token = try requiredString(request, key: "approval_token")
        let inputs = try ephemeralInputs(from: request)
        let reservation = try taskAuthority(
            for: plan,
            request: request,
            approvalToken: token,
            ephemeralInputs: inputs,
            force: true
        )
        guard let authority = reservation.authority else { throw TaskControlError.leaseRequired }
        let executionID = reservation.lease.map {
            beginControlCenterExecution(
                taskID: plan.id,
                summary: plan.summary,
                applicationName: ApprovalHandoffTargetResolver.resolve(for: plan)?.applicationName,
                lease: $0,
                leaseOwnedByDaemon: reservation.ownedByDaemon
            )
        }
        defer {
            if reservation.ownedByDaemon, let lease = reservation.lease {
                keyboardDriveStore.invalidate(token: lease.token)
            }
            if let executionID { finishControlCenterExecution(executionID: executionID) }
        }
        let report = try withExecutionLock {
            try taskRunner.resume(
                plan: plan,
                approvalToken: token,
                ephemeralInputs: inputs,
                authority: authority
            )
        }
        return try taskResponse(
            request,
            report: report,
            message: "Task resumed and completed",
            inputChannel: authority.inputChannel
        )
    }

    private func cancelTask(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let taskID = try requiredString(request, key: "task_id")
        // Cancellation is intentionally outside the action lock so a caller can
        // interrupt a task that is waiting on a bounded Accessibility or adapter
        // action.  TaskRunner owns its checkpoint/cancellation synchronization.
        let report = try taskRunner.cancel(taskID: taskID)
        return try taskResponse(request, report: report, message: "Task cancellation requested")
    }

    private func stopActiveControl(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        controlCenterLock.lock()
        let execution = activeControlExecution
        if var stopping = execution {
            stopping.stopping = true
            activeControlExecution = stopping
        }
        controlCenterLock.unlock()
        controlCenterStateChanged?()

        var cancellationRequested = false
        if let taskID = execution?.taskID {
            cancellationRequested = (try? taskRunner.cancel(taskID: taskID)) != nil
        }
        let leaseToken = execution?.leaseToken ?? keyboardDriveStore.activeLease()?.token
        let released = leaseToken.map { keyboardDriveStore.invalidate(token: $0) } ?? false
        if let leaseToken, routeSelectionCache?.leaseToken == leaseToken {
            routeSelectionCache = nil
        }
        if execution == nil {
            controlCenterLock.lock()
            activeControlExecution = nil
            controlCenterLock.unlock()
        }
        return try success(
            request,
            result: [
                "cancellation_requested": .bool(cancellationRequested),
                "released": .bool(released)
            ],
            evidence: [Evidence(
                kind: "control_stop",
                message: "Active execution was marked cancelled and its input authority was invalidated",
                source: "macctld"
            )]
        )
    }

    @discardableResult
    private func beginControlCenterExecution(
        taskID: String?,
        summary: String,
        applicationName: String?,
        lease: KeyboardDriveLease,
        leaseOwnedByDaemon: Bool
    ) -> String {
        let executionID = UUID().uuidString
        controlCenterLock.lock()
        activeControlExecution = ActiveControlExecution(
            executionID: executionID,
            taskID: taskID,
            summary: summary,
            applicationName: applicationName,
            leaseToken: lease.token,
            leaseOwnedByDaemon: leaseOwnedByDaemon,
            physicalInputMode: lease.physicalInputMode,
            acquiredAt: lease.acquiredAt,
            expiresAt: lease.expiresAt,
            stopping: false
        )
        controlCenterLock.unlock()
        controlCenterStateChanged?()
        return executionID
    }

    private func finishControlCenterExecution(executionID: String) {
        controlCenterLock.lock()
        if activeControlExecution?.executionID == executionID {
            activeControlExecution = nil
        }
        controlCenterLock.unlock()
        controlCenterStateChanged?()
    }

    private func taskPlan(from request: RequestEnvelope) throws -> TaskPlan {
        guard let value = request.params["plan"] else {
            throw TaskControlError.invalidPlan(["plan is required"])
        }
        guard let data = try? JSONCodec.encode(value) else {
            throw TaskControlError.invalidPlan(["plan is not valid JSON"])
        }
        do {
            return try JSONCodec.decode(TaskPlan.self, from: data)
        } catch {
            throw TaskControlError.invalidPlan(["plan could not be decoded"])
        }
    }

    private func taskAuthority(
        for plan: TaskPlan,
        request: RequestEnvelope,
        approvalToken: String,
        ephemeralInputs: [String: String],
        force: Bool
    ) throws -> TaskAuthorityReservation {
        _ = try taskApprovalStore.validateApproved(
            token: approvalToken,
            plan: plan,
            ephemeralInputs: ephemeralInputs
        )
        if plan.focusPolicy == .background {
            guard force || plan.requiresInputAuthority(using: adapterRegistry) else {
                return TaskAuthorityReservation(authority: nil, lease: nil, ownedByDaemon: false)
            }
            return TaskAuthorityReservation(
                authority: try backgroundTaskAuthority(for: plan, ephemeralInputs: ephemeralInputs),
                lease: nil,
                ownedByDaemon: false
            )
        }
        if let target = ApprovalHandoffTargetResolver.resolve(for: plan) {
            _ = try activateAndStabilizeApplication(target.bundleID ?? target.applicationName)
        }
        let requiredMode: KeyboardPhysicalInputMode = plan.keyboardFreezeRequired ? .suppressed : .shared
        let suppliedToken = request.params["lease_token"]?.stringValue
        let lease: KeyboardDriveLease
        let ownedByDaemon: Bool
        if let suppliedToken, !suppliedToken.isEmpty {
            lease = try keyboardDriveStore.lease(for: suppliedToken)
            guard lease.scope == .session, lease.physicalInputMode == requiredMode else {
                throw TaskControlError.leaseRequired
            }
            ownedByDaemon = false
        } else {
            guard hasPostEventAccess() else {
                throw KeyboardControlError.permissionDenied("Post Events")
            }
            lease = try keyboardDriveStore.acquire(
                scope: .session,
                application: nil,
                seconds: min(plan.totalTimeout, KeyboardDriveStore.maximumLifetime),
                confirm: true,
                physicalInputMode: requiredMode,
                freezeReason: requiredMode == .suppressed
                    ? "Exact approved task requires physical keyboard suppression"
                    : nil
            )
            ownedByDaemon = true
        }
        let requiresFullKeyboardAccess = plan.steps.contains {
            $0.action.kind == .key || $0.action.kind == .search
        }
        do {
            let context = try controlSession.beginAction(
                leaseToken: lease.token,
                requireFullKeyboardAccess: requiresFullKeyboardAccess
            )
            let authority = TaskExecutionAuthority(
                leaseToken: lease.token,
                leaseExpiresAt: context.lease.expiresAt,
                fresh: true,
                revalidate: { [controlSession] in
                    try controlSession.revalidate(context)
                },
                fingerprint: { [controlSession] in
                    let application = try? controlSession.revalidate(context)
                    return application.map { ControlTargetFingerprints.make(application: $0, focus: nil) }
                }
            )
            return TaskAuthorityReservation(
                authority: authority,
                lease: lease,
                ownedByDaemon: ownedByDaemon
            )
        } catch {
            if ownedByDaemon { keyboardDriveStore.invalidate(token: lease.token) }
            throw error
        }
    }

    private func backgroundTaskAuthority(
        for plan: TaskPlan,
        ephemeralInputs: [String: String]
    ) throws -> TaskExecutionAuthority {
        let inputSteps = plan.steps.filter {
            [.click, .type, .key].contains($0.action.kind)
        }
        let targetNames = Set(inputSteps.compactMap {
            $0.target?.bundleID ?? $0.target?.application
        })
        guard targetNames.count == 1, let targetName = targetNames.first else {
            throw TaskControlError.leaseRequired
        }
        let targetApplication = try resolveApplication(targetName)
        guard targetApplication.isRunning, let targetPID = targetApplication.processID else {
            throw TaskControlError.blocked("background_target_not_running")
        }
        guard inputSteps.allSatisfy({ step in
            step.target?.processID.map { $0 == targetPID } ?? true
        }) else {
            throw TaskControlError.blocked("background_target_process_changed")
        }
        guard let initialForeground = foregroundApplication() else {
            throw TaskControlError.blocked("foreground_unavailable")
        }
        guard !Self.sameTaskApplication(initialForeground, targetApplication) else {
            throw TaskControlError.blocked("background_target_is_foreground")
        }
        if inputSteps.contains(where: { $0.action.kind == .key }), !hasPostEventAccess() {
            throw KeyboardControlError.permissionDenied("Post Events")
        }

        var routes: [TaskInputChannelRoute] = []
        if inputSteps.contains(where: { [.click, .type].contains($0.action.kind) }) {
            routes.append(.accessibility)
        }
        if inputSteps.contains(where: { $0.action.kind == .key }) {
            routes.append(.processDirected)
        }
        let planDigest = TaskPlan.digest(plan, ephemeralInputs: ephemeralInputs)
        let channel = TaskInputChannel(
            taskID: plan.id,
            planDigest: planDigest,
            focusPolicy: .background,
            targetApplication: targetApplication,
            routes: routes,
            expiresAt: Date().addingTimeInterval(
                min(plan.totalTimeout, KeyboardDriveStore.maximumLifetime)
            )
        )
        return TaskExecutionAuthority(
            leaseToken: nil,
            leaseExpiresAt: channel.expiresAt,
            fresh: true,
            inputChannel: channel,
            revalidate: { [resolveApplication, foregroundApplication] in
                let currentTarget = try resolveApplication(targetName)
                guard currentTarget.processID == targetPID,
                      currentTarget.isRunning else {
                    throw TaskControlError.blocked("background_target_process_changed")
                }
                guard let currentForeground = foregroundApplication(),
                      Self.sameTaskApplication(currentForeground, initialForeground),
                      !Self.sameTaskApplication(currentForeground, currentTarget) else {
                    throw TaskControlError.blocked("background_foreground_changed")
                }
                return currentTarget
            },
            fingerprint: {
                ControlTargetFingerprints.make(application: targetApplication, focus: nil)
            }
        )
    }

    private static func sameTaskApplication(_ lhs: AppInfo, _ rhs: AppInfo) -> Bool {
        if let lhsBundleID = lhs.bundleID, let rhsBundleID = rhs.bundleID {
            return lhsBundleID == rhsBundleID
        }
        return lhs.path == rhs.path || lhs.name == rhs.name
    }

    private static func validateTaskTarget(
        snapshot: ControlTargetSnapshot,
        target: TaskTargetIdentity?
    ) throws {
        guard let target else { return }
        if let application = target.application,
           snapshot.application.name.caseInsensitiveCompare(application) != .orderedSame,
           snapshot.application.bundleID != application {
            throw ControlTargetInspectionError.targetChanged
        }
        if let bundleID = target.bundleID, snapshot.application.bundleID != bundleID {
            throw ControlTargetInspectionError.targetChanged
        }
        if let processID = target.processID,
           snapshot.application.processID != processID {
            throw ControlTargetInspectionError.targetChanged
        }
        if let windowFingerprint = target.windowFingerprint,
           snapshot.fingerprint.window != windowFingerprint {
            throw ControlTargetInspectionError.targetChanged
        }
        if let focusedElementFingerprint = target.focusedElementFingerprint,
           snapshot.fingerprint.focusedElement != focusedElementFingerprint {
            throw ControlTargetInspectionError.targetChanged
        }
    }

    private static func actionRequiresReadableFocus(
        _ action: ActionSpec,
        adapterRegistry: AppAdapterRegistry
    ) -> Bool {
        switch action.kind {
        case .click, .type, .key, .search, .scroll, .activateWindow, .capture, .ocr, .command:
            return true
        case .adapter:
            guard let adapterID = action.parameters["adapter_id"]?.stringValue,
                  let operationName = action.parameters["operation"]?.stringValue,
                  let operation = try? adapterRegistry.operation(
                      adapterID: adapterID,
                      name: operationName
                  ) else {
                return true
            }
            return operation.mutating
        case .launchApp, .waitFor, .assert:
            return false
        }
    }

    private func taskResponse(
        _ request: RequestEnvelope,
        report: TaskStatusReport,
        message: String,
        inputChannel: TaskInputChannel? = nil
    ) throws -> ResponseEnvelope {
        var result = try JSONValue.fromEncodable(report).objectValue ?? [:]
        result["task_id"] = .string(report.taskID)
        result["plan_digest"] = .string(report.planDigest)
        result["lifecycle_state"] = .string(report.state.rawValue)
        if let lastStepID = report.lastStepID {
            result["last_step_id"] = .string(lastStepID)
        }
        result["message"] = .string(message)
        var evidence = [Evidence(
            kind: "task_checkpoint",
            message: "Task status was derived from a redacted durable checkpoint",
            source: "macctld",
            metadata: ["lifecycle_state": .string(report.state.rawValue)]
        )]
        if let inputChannel {
            result["input_channel"] = .object([
                "channel_id": .string(inputChannel.channelID),
                "task_id": .string(inputChannel.taskID),
                "plan_digest": .string(inputChannel.planDigest),
                "focus_policy": .string(inputChannel.focusPolicy.rawValue),
                "target": .object([
                    "name": .string(inputChannel.targetApplication.name),
                    "bundle_id": inputChannel.targetApplication.bundleID.map(JSONValue.string) ?? .null,
                    "process_id": inputChannel.targetApplication.processID
                        .map { .number(Double($0)) } ?? .null
                ]),
                "routes": .array(inputChannel.routes.map { .string($0.rawValue) }),
                "expires_at_unix_seconds": .number(inputChannel.expiresAt.timeIntervalSince1970)
            ])
            evidence.append(Evidence(
                kind: "task_input_channel",
                message: "Background input was bound to the approved task and target process",
                source: "macctld",
                metadata: [
                    "task_id": .string(inputChannel.taskID),
                    "focus_policy": .string(inputChannel.focusPolicy.rawValue),
                    "routes": .array(inputChannel.routes.map { .string($0.rawValue) })
                ]
            ))
        }
        return try success(
            request,
            status: taskOperationStatus(report.state),
            result: result,
            evidence: evidence
        )
    }

    private func taskOperationStatus(_ state: TaskLifecycleState) -> OperationStatus {
        switch state {
        case .prepared: return .prepared
        case .completed, .cancelled: return .succeeded
        case .expired: return .expired
        case .running, .paused, .blocked, .indeterminate: return .blocked
        }
    }

    private func prepareWorkflow(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let id = try requiredString(request, key: "workflow")
        guard let baseWorkflow = workflowRegistry.workflow(id: id) else {
            return failure(request, status: .failed, code: .workflowNotFound, message: "Workflow does not exist")
        }
        let workflow = try workflowApplyingRequestedFocusPolicy(baseWorkflow, request: request)
        let validation = workflowRegistry.validate(workflow)
        guard validation.valid else {
            return failure(
                request,
                status: .failed,
                code: .workflowInvalid,
                message: "Workflow validation failed",
                details: ["errors": .array(validation.errors.map(JSONValue.string))]
            )
        }
        let prepared = approvalStore.prepare(
            workflow: workflow,
            ephemeralInputs: try ephemeralInputs(from: request),
            operationID: UUID().uuidString
        )
        presentApproval?(prepared.record)
        logger.record(event: "approval_prepared", metadata: [
            "workflow": workflow.id,
            "risk": validation.risk.rawValue,
            "operation_id": prepared.record.operationID
        ])
        var result: [String: JSONValue] = [
            "approval": try JSONValue.fromEncodable(prepared.record),
            "plan_digest": .string(prepared.planDigest),
            "risk": .string(validation.risk.rawValue),
            "focus_policy": .string(workflow.focusPolicy.rawValue),
            "expires_at": try JSONValue.fromEncodable(prepared.record.expiresAt)
        ]
        if workflow.actions.contains(where: { $0.kind == .search }) {
            result["keyboard_lease_required"] = .bool(true)
        }
        return try success(
            request,
            status: .prepared,
            operationID: prepared.record.operationID,
            result: result,
            evidence: [Evidence(
                kind: "approval",
                message: "Exact workflow plan prepared; approval is required before execution",
                metadata: ["risk": .string(validation.risk.rawValue)]
            )]
        )
    }

    private func runWorkflow(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let id = try requiredString(request, key: "workflow")
        guard let baseWorkflow = workflowRegistry.workflow(id: id) else {
            return failure(request, status: .failed, code: .workflowNotFound, message: "Workflow does not exist")
        }
        let requestedPolicy = try requestedFocusPolicy(from: request)
        let workflow = baseWorkflow.withFocusPolicy(requestedPolicy ?? baseWorkflow.focusPolicy)
        let validation = workflowRegistry.validate(workflow)
        guard validation.valid else {
            return failure(
                request,
                status: .failed,
                code: .workflowInvalid,
                message: "Workflow validation failed",
                details: ["errors": .array(validation.errors.map(JSONValue.string))]
            )
        }
        let suppliedInputs = try ephemeralInputs(from: request)
        if validation.risk == .sensitive {
            guard let token = request.params["approval_token"]?.stringValue else {
                return failure(
                    request,
                    status: .blocked,
                    code: .approvalRequired,
                    message: "Sensitive workflow requires workflow.prepare followed by approval.approve"
                )
            }
            guard let record = approvalStore.record(for: token) else {
                return approvalFailure(request, token: token, error: .notFound)
            }
            guard record.workflowID == id else {
                return failure(
                    request,
                    status: .blocked,
                    code: .approvalRequired,
                    message: "Approval token was prepared for a different workflow",
                    operationID: record.operationID,
                    details: [
                        "requested_workflow_id": .string(id),
                        "prepared_workflow_id": .string(record.workflowID)
                    ]
                )
            }
            guard requestedPolicy == nil || requestedPolicy == record.focusPolicy else {
                return failure(
                    request,
                    status: .blocked,
                    code: .approvalRequired,
                    message: "Approval token was prepared for a different focus policy",
                    operationID: record.operationID,
                    details: [
                        "requested_focus_policy": .string(requestedPolicy?.rawValue ?? "unknown"),
                        "prepared_focus_policy": .string(record.focusPolicy.rawValue)
                    ]
                )
            }
            let prepared = try approvalStore.validateApproved(
                token: token,
                workflow: workflow,
                ephemeralInputs: suppliedInputs
            )
            guard requestedPolicy == nil || requestedPolicy == prepared.workflow.focusPolicy else {
                return failure(
                    request,
                    status: .blocked,
                    code: .approvalRequired,
                    message: "Approval token was prepared for a different focus policy",
                    operationID: prepared.record.operationID,
                    details: [
                        "requested_focus_policy": .string(requestedPolicy?.rawValue ?? "unknown"),
                        "prepared_focus_policy": .string(prepared.workflow.focusPolicy.rawValue)
                    ]
                )
            }
            guard suppliedInputs.isEmpty || suppliedInputs == prepared.ephemeralInputs else {
                throw WorkflowExecutionError.unsafeInput("ephemeral inputs did not match the prepared plan")
            }
            return try executePrepared(
                request,
                prepared: prepared,
                keyboardLeaseToken: request.params["lease_token"]?.stringValue
            )
        }
        let report = try executeWorkflow(
            workflow,
            ephemeralInputs: suppliedInputs,
            keyboardLeaseToken: request.params["lease_token"]?.stringValue
        )
        logger.record(event: "workflow_succeeded", metadata: ["workflow": workflow.id])
        var result = try JSONValue.fromEncodable(report).objectValue ?? [:]
        result["workflow_id"] = .string(workflow.id)
        result["plan_digest"] = .string(ApprovalStore.digest(workflow, ephemeralInputs: suppliedInputs))
        result["run_id"] = .string(report.runID)
        result["focus_policy"] = .string(report.focusPolicy.rawValue)
        result["target_process_ids"] = .array(report.targetProcessIDs.map { .number(Double($0)) })
        return try success(
            request,
            result: result,
            evidence: report.evidence
        )
    }

    private func prepareExternalApproval(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let provider = try validatedExternalIdentifier(request, key: "provider")
        let providerInstanceID = try validatedExternalIdentifier(request, key: "provider_instance_id")
        let planID = try validatedExternalIdentifier(request, key: "plan_id")
        let planDigest = try requiredString(request, key: "plan_digest")
        guard planDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw WorkflowExecutionError.unsafeInput("plan_digest must be a lowercase SHA-256 digest")
        }
        let summary = try requiredString(request, key: "summary")
        guard summary.count <= 500 else {
            throw WorkflowExecutionError.unsafeInput("summary must contain at most 500 characters")
        }
        let riskValue = try requiredString(request, key: "risk")
        guard let risk = RiskLevel(rawValue: riskValue) else {
            throw WorkflowExecutionError.unsafeInput("risk must be safe, reversible, or sensitive")
        }
        let prepared = externalApprovalStore.prepare(
            provider: provider,
            providerInstanceID: providerInstanceID,
            planID: planID,
            planDigest: planDigest,
            summary: summary,
            risk: risk
        )
        presentApproval?(prepared.record)
        controlCenterStateChanged?()
        return try success(
            request,
            status: .prepared,
            operationID: prepared.record.operationID,
            result: externalApprovalResult(prepared),
            evidence: [Evidence(
                kind: "external_approval",
                message: "External provider plan was bound to its exact digest in the control center",
                source: "macctld",
                metadata: ["provider": .string(provider), "plan_digest": .string(planDigest)]
            )]
        )
    }

    private func externalApprovalStatus(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let operationID = try requiredString(request, key: "operation_id")
        do {
            let status = try externalApprovalStore.status(operationID: operationID)
            let operationStatus: OperationStatus = switch status.state {
            case .pending:
                .prepared
            case .approved, .consumed:
                .succeeded
            case .denied:
                .denied
            case .expired:
                .expired
            }
            return try success(
                request,
                status: operationStatus,
                operationID: operationID,
                result: externalApprovalResult(status)
            )
        } catch let error as ExternalApprovalStoreError {
            return externalApprovalFailure(request, operationID: operationID, error: error)
        }
    }

    private func consumeExternalApproval(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let operationID = try requiredString(request, key: "operation_id")
        do {
            let consumed = try externalApprovalStore.consume(
                operationID: operationID,
                provider: try validatedExternalIdentifier(request, key: "provider"),
                providerInstanceID: try validatedExternalIdentifier(request, key: "provider_instance_id"),
                planID: try validatedExternalIdentifier(request, key: "plan_id"),
                planDigest: try requiredString(request, key: "plan_digest")
            )
            controlCenterStateChanged?()
            return try success(
                request,
                operationID: operationID,
                result: externalApprovalResult(consumed),
                evidence: [Evidence(
                    kind: "external_approval",
                    message: "Single-use external approval decision was consumed by the bound provider plan",
                    source: "macctld",
                    metadata: ["provider": .string(consumed.provider), "plan_digest": .string(consumed.planDigest)]
                )]
            )
        } catch let error as ExternalApprovalStoreError {
            return externalApprovalFailure(request, operationID: operationID, error: error)
        }
    }

    private func approve(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let token = try requiredString(request, key: "token")
        if token.hasPrefix("mce_") {
            do {
                let approved = try externalApprovalStore.approve(token: token)
                logger.record(event: "external_approval_approved", metadata: [
                    "provider": approved.provider,
                    "operation_id": approved.record.operationID
                ])
                return try success(
                    request,
                    operationID: approved.record.operationID,
                    result: externalApprovalResult(approved),
                    evidence: [Evidence(
                        kind: "external_approval",
                        message: "External provider plan was approved for one exact digest",
                        source: "macctld",
                        metadata: ["provider": .string(approved.provider)]
                    )]
                )
            } catch let error as ExternalApprovalStoreError {
                return externalApprovalFailure(request, token: token, error: error)
            }
        }
        if token.hasPrefix("mct_") {
            do {
                if request.params["source"]?.stringValue == "control_center",
                   let target = taskApprovalStore.record(for: token)?.handoffTarget {
                    _ = try activateAndStabilizeApplication(target.bundleID ?? target.applicationName)
                }
                let prepared = try taskApprovalStore.approve(token: token)
                logger.record(event: "task_approval_approved", metadata: [
                    "task_id": prepared.plan.id,
                    "operation_id": prepared.record.operationID
                ])
                return try success(
                    request,
                    operationID: prepared.record.operationID,
                    result: [
                        "approved": .bool(true),
                        "task_id": .string(prepared.plan.id),
                        "plan_digest": .string(prepared.planDigest),
                        "approval": try JSONValue.fromEncodable(prepared.record)
                    ],
                    evidence: [Evidence(
                        kind: "task_approval",
                        message: "Task approval was bound to the exact serialized plan",
                        source: "macctld"
                    )]
                )
            } catch let error as TaskApprovalStoreError {
                return taskApprovalFailure(request, token: token, error: error)
            }
        }
        do {
            if request.params["source"]?.stringValue == "control_center",
               let target = approvalStore.record(for: token)?.handoffTarget {
                _ = try activateAndStabilizeApplication(target.bundleID ?? target.applicationName)
            }
            let prepared = try approvalStore.approve(token: token)
            logger.record(event: "workflow_approval_approved", metadata: [
                "workflow": prepared.workflow.id,
                "operation_id": prepared.record.operationID
            ])
            return try success(
                request,
                operationID: prepared.record.operationID,
                result: [
                    "approved": .bool(true),
                    "workflow_id": .string(prepared.workflow.id),
                    "plan_digest": .string(prepared.planDigest),
                    "approval": try JSONValue.fromEncodable(prepared.record)
                ],
                evidence: [Evidence(
                    kind: "approval",
                    message: "Workflow approval was bound to the exact serialized plan",
                    source: "macctld"
                )]
            )
        } catch let error as ApprovalStoreError {
            return approvalFailure(request, token: token, error: error)
        }
    }

    private func executePrepared(
        _ request: RequestEnvelope,
        prepared: PreparedApproval,
        keyboardLeaseToken: String? = nil
    ) throws -> ResponseEnvelope {
        let digest = ApprovalStore.digest(
            prepared.workflow,
            ephemeralInputs: prepared.ephemeralInputs
        )
        guard digest == prepared.planDigest else {
            return failure(
                request,
                status: .blocked,
                code: .approvalRequired,
                message: "Prepared plan digest did not match; refusing execution"
            )
        }
        let requestedPolicy = try requestedFocusPolicy(from: request)
        guard requestedPolicy == nil || requestedPolicy == prepared.workflow.focusPolicy else {
            return failure(
                request,
                status: .blocked,
                code: .approvalRequired,
                message: "Approval token was prepared for a different focus policy",
                operationID: prepared.record.operationID,
                details: [
                    "requested_focus_policy": .string(requestedPolicy?.rawValue ?? "unknown"),
                    "prepared_focus_policy": .string(prepared.workflow.focusPolicy.rawValue)
                ]
            )
        }
        guard prepared.record.focusPolicy == prepared.workflow.focusPolicy else {
            return failure(
                request,
                status: .blocked,
                code: .approvalRequired,
                message: "Approval record focus policy did not match the prepared workflow",
                operationID: prepared.record.operationID
            )
        }
        let reservation = try approvedWorkflowLease(
            workflow: prepared.workflow,
            suppliedToken: keyboardLeaseToken ?? request.params["lease_token"]?.stringValue
        )
        let executionID = reservation.lease.map {
            beginControlCenterExecution(
                taskID: nil,
                summary: prepared.workflow.summary,
                applicationName: prepared.record.handoffTarget?.applicationName,
                lease: $0,
                leaseOwnedByDaemon: reservation.ownedByDaemon
            )
        }
        defer {
            if reservation.ownedByDaemon, let lease = reservation.lease {
                keyboardDriveStore.invalidate(token: lease.token)
            }
            if let executionID { finishControlCenterExecution(executionID: executionID) }
        }
        _ = try approvalStore.consume(
            token: prepared.record.token,
            workflow: prepared.workflow,
            ephemeralInputs: prepared.ephemeralInputs
        )
        let report = try executeWorkflow(
            prepared.workflow,
            ephemeralInputs: prepared.ephemeralInputs,
            keyboardLeaseToken: reservation.lease?.token
        )
        let source = request.params["source"]?.stringValue ?? "cli"
        logger.record(event: "approved_workflow_succeeded", metadata: [
            "workflow": prepared.workflow.id,
            "operation_id": prepared.record.operationID,
            "source": source
        ])
        var result = try JSONValue.fromEncodable(report).objectValue ?? [:]
        result["workflow_id"] = .string(prepared.workflow.id)
        result["plan_digest"] = .string(prepared.planDigest)
        result["run_id"] = .string(report.runID)
        result["focus_policy"] = .string(report.focusPolicy.rawValue)
        result["target_process_ids"] = .array(report.targetProcessIDs.map { .number(Double($0)) })
        return try success(
            request,
            operationID: prepared.record.operationID,
            result: result,
            evidence: report.evidence
        )
    }

    private func approvedWorkflowLease(
        workflow: WorkflowSpec,
        suppliedToken: String?
    ) throws -> WorkflowLeaseReservation {
        guard workflow.focusPolicy == .foreground else {
            return WorkflowLeaseReservation(lease: nil, ownedByDaemon: false)
        }
        if let target = ApprovalHandoffTargetResolver.resolve(for: workflow) {
            _ = try activateAndStabilizeApplication(target.bundleID ?? target.applicationName)
        }
        let requiredMode: KeyboardPhysicalInputMode = workflow.keyboardFreezeRequired ? .suppressed : .shared
        if let suppliedToken, !suppliedToken.isEmpty {
            let lease = try keyboardDriveStore.lease(for: suppliedToken)
            guard lease.scope == .session, lease.physicalInputMode == requiredMode else {
                throw TaskControlError.leaseRequired
            }
            return WorkflowLeaseReservation(lease: lease, ownedByDaemon: false)
        }
        guard hasPostEventAccess() else {
            throw KeyboardControlError.permissionDenied("Post Events")
        }
        let lease = try keyboardDriveStore.acquire(
            scope: .session,
            application: nil,
            seconds: KeyboardDriveStore.maximumLifetime,
            confirm: true,
            physicalInputMode: requiredMode,
            freezeReason: requiredMode == .suppressed
                ? "Exact approved workflow requires physical keyboard suppression"
                : nil
        )
        return WorkflowLeaseReservation(lease: lease, ownedByDaemon: true)
    }

    private func deny(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let token = try requiredString(request, key: "token")
        if token.hasPrefix("mce_") {
            do {
                let denied = try externalApprovalStore.deny(token: token)
                logger.record(event: "external_approval_denied", metadata: [
                    "provider": denied.provider,
                    "operation_id": denied.record.operationID
                ])
                return try success(
                    request,
                    operationID: denied.record.operationID,
                    result: externalApprovalResult(denied),
                    evidence: [Evidence(
                        kind: "external_approval",
                        message: "External provider plan was denied",
                        source: "macctld",
                        metadata: ["provider": .string(denied.provider)]
                    )]
                )
            } catch let error as ExternalApprovalStoreError {
                return externalApprovalFailure(request, token: token, error: error)
            }
        }
        if token.hasPrefix("mct_") {
            do {
                let record = try taskApprovalStore.deny(token: token)
                return try success(
                    request,
                    operationID: record.operationID,
                    result: [
                        "denied": .bool(true),
                        "task_id": .string(record.workflowID)
                    ],
                    evidence: [Evidence(
                        kind: "task_approval",
                        message: "Task approval was denied",
                        source: "macctld"
                    )]
                )
            } catch let error as TaskApprovalStoreError {
                return taskApprovalFailure(request, token: token, error: error)
            }
        }
        let record: ApprovalRecord
        do {
            record = try approvalStore.deny(token: token)
        } catch let error as ApprovalStoreError {
            return approvalFailure(request, token: token, error: error)
        }
        logger.record(event: "approval_denied", metadata: [
            "workflow": record.workflowID,
            "source": request.params["source"]?.stringValue ?? "cli"
        ])
        return try success(
            request,
            operationID: record.operationID,
            result: ["denied": .bool(true), "workflow": .string(record.workflowID)],
            evidence: [Evidence(kind: "approval", message: "Approval token denied")]
        )
    }

    private func doctorReport() -> DoctorReport {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let permissions = PermissionDiagnostics.report()
        let runtimeIdentity = RuntimeIdentity.current()
        let keyboardAccess = keyboardAccessController.status(
            permissionContext: permissionContext,
            activeLease: keyboardDriveStore.activeLease()
        )
        var warnings = permissions
            .filter { $0.state == "missing" || $0.state == "unknown" }
            .map { "\($0.name) permission is missing" }
        if keyboardAccess.fullKeyboardAccessEnabled != true {
            warnings.append("Full Keyboard Access is disabled or could not be verified")
        }
        if runtimeIdentity.signatureValid == false {
            warnings.append("The daemon bundle code signature is missing or invalid")
        }
        return DoctorReport(
            processID: ProcessInfo.processInfo.processIdentifier,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            socketPath: MacCtlPaths.socketURL.path,
            socketOwnerOnly: !FileManager.default.fileExists(atPath: MacCtlPaths.socketURL.path)
                || MacCtlPaths.ownerOnlySocketPath(),
            permissions: permissions,
            availableFrameworks: [
                "AppKit", "ApplicationServices", "CoreGraphics", "ScreenCaptureKit", "Vision", "Foundation"
            ],
            warnings: warnings,
            permissionContext: permissionContext,
            runtimeIdentity: runtimeIdentity,
            launchAgent: launchAgentManager.status(),
            keyboardAccess: keyboardAccess,
            taskCapabilities: TaskCapabilityReport(),
            checkpointStore: taskCheckpointStore.status()
        )
    }

    private func capabilityReport() -> CapabilityReport {
        CapabilityReport(
            capabilities: [
                "app.list", "app.open", "launchApp", "activateWindow", "click", "type", "key", "search",
                "scroll", "waitFor", "capture", "ocr", "assert", "workflow.prepare", "workflow.run",
                "workflow.background", "approval.approve", "approval.deny",
                "approval.external.prepare", "approval.external.status", "approval.external.consume",
                "keyboard.status", "keyboard.setup", "keyboard.enable", "keyboard.inspect",
                "keyboard.lease.acquire", "keyboard.lease.release", "keyboard.lease.physical-suppression",
                "keyboard.freeze.acquire", "keyboard.freeze.status", "keyboard.freeze.release",
                "keyboard.navigate", "keyboard.send",
                "control.status", "control.perform", "control.batch", "control.capabilities", "control.capability_audit", "control.capability_audit_batch", "control.outcome", "control.center.snapshot", "control.stop_active",
                "route.list", "route.inspect", "route.benchmark", "route.register",
                "accessibility.tree", "accessibility.audit", "ideal-state.audit", "task.prepare", "task.run", "task.status",
                "task.resume", "task.cancel", "adapter.capabilities",
                "shortcut.audit", "shortcut.propose", "shortcut.inspect", "shortcut.setup", "shortcut.run", "shortcut.remove"
            ],
            optionalBackends: ["AppleScript/JXA", "shortcuts", "devicectl developer-device diagnostics"],
            permissionGates: ["Accessibility", "Input Monitoring", "Post Events", "Screen Recording", "Automation"],
            safety: [
                "sensitive workflows require a short-lived single-use approval token",
                "external local providers publish only bounded plan metadata and exact digests; control-center tokens never leave macctld",
                "raw coordinates require an explicit coordinate_mode=raw marker",
                "background workflows require named macOS app targets and preserve foreground focus",
                "background input is sent to target processes; global mouse, desktop, and foreground paths are rejected",
                "Full Keyboard Access is explicit, AppKit-verified, and never enabled at daemon startup",
                "direct keyboard navigation requires one short-lived, user-confirmed lease with per-key focus checks",
                "physical keyboard suppression is opt-in, session-scoped, bounded by lease expiry, and leaves mouse emergency release available",
                "bare printable keys are rejected from keyboard.send; text remains ephemeral-input plus approval gated",
                "keyboard focus inspection returns only role, subrole, identifier, title, and target application",
                "route selection uses a fresh measured app/task/version/target manifest after safety and permission gates",
                "route selection requires daemon-executed measurements; caller-supplied registrations are inventory-only",
                "control outcomes are provider-neutral and expose target, action, verification, and handoff state",
                "control.batch holds one bounded app lease, revalidates every step, and releases the lease on every exit path",
                "control.capabilities is a fast route probe that may read a cached broad profile but never walks the Accessibility tree",
                "control.capability_audit performs a bounded read-only Accessibility/provider audit and persists only redacted identity descriptors; it never dispatches an action",
                "control.capability_audit_batch audits at most 24 explicit or catalog-selected apps, persists one redacted resumable receipt per app, serializes AX access, and never launches apps or dispatches actions",
                "selector addressability identifies a requested route but never invents a universal fallback ladder",
                "only an explicit pre-action target-not-found failure may advance through a declared fallback chain",
                "visual and coordinate routes require task-manifest opt-in and report the selected route and fallback chain",
                "every semantic action revalidates the lease and foreground state and records redacted verification metadata",
                "atomic semantic control reasserts stable foreground, owns an ephemeral app lease, and releases it on every exit path",
                "semantic scroll targets a unique AXScrollArea selector (identifier optional when role-only resolution is unique), re-resolves it, and compares bounded structural viewport metadata",
                "semantic scroll failures expose fallback_allowed, failure_class, and explicit Computer Use handoff metadata",
                "accessibility trees are bounded and redacted; AX values, private text, screenshots, and OCR are excluded",
                "task plans are approved by exact digest, checkpointed atomically, and never resume automatically",
                "task recovery is capped at three safe, two reversible, and one sensitive attempt",
                "sensitive uncertainty is indeterminate and is never retried automatically",
                "adapter operations are typed and allowlisted; arbitrary AppleScript and JXA are rejected",
                "task checkpoints contain only redacted identity hashes and verification state",
                "shortcut bindings are owner-only, approval-bound by exact digest and operation, and promote to behavior_verified only after a declared postcondition passes",
                "shortcut commands dispatch at most once; indeterminate postconditions never trigger an automatic retry",
                "raw coordinate semantic fallback requires an explicit allow_raw_coordinate flag",
                "screenshots and OCR frames are discarded after an operation",
                "no TCP or network listener is created"
            ],
            keyboardAccess: keyboardAccessController.status(
                permissionContext: permissionContext,
                activeLease: keyboardDriveStore.activeLease()
            ),
            taskCapabilities: TaskCapabilityReport(),
            adapterManifests: adapterRegistry.manifests(),
            automationPermissions: adapterRegistry.automationPermissions(),
            checkpointStore: taskCheckpointStore.status(),
            shortcutCapabilities: shortcutEngine.capabilityReport()
        )
    }

    private func daemonStatus() -> DaemonStatus {
        DaemonStatus(
            daemonName: "macctld",
            runtimeContext: permissionContext,
            processID: ProcessInfo.processInfo.processIdentifier,
            socketPath: MacCtlPaths.socketURL.path,
            socketExists: FileManager.default.fileExists(atPath: MacCtlPaths.socketURL.path),
            approvalCount: approvalStore.list().count,
            supportedSurfaces: SurfaceKind.allCases,
            runtimeIdentity: .current(),
            launchAgent: launchAgentManager.status(),
            socketOwnerOnly: !FileManager.default.fileExists(atPath: MacCtlPaths.socketURL.path)
                || MacCtlPaths.ownerOnlySocketPath(),
            receiptStore: receiptStore.status()
        )
    }

    public func unavailableDoctorResponse(
        request: RequestEnvelope,
        socketError: String
    ) -> ResponseEnvelope {
        let report = DoctorReport(
            processID: ProcessInfo.processInfo.processIdentifier,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architectureName(),
            socketPath: MacCtlPaths.socketURL.path,
            socketOwnerOnly: !FileManager.default.fileExists(atPath: MacCtlPaths.socketURL.path)
                || MacCtlPaths.ownerOnlySocketPath(),
            permissions: PermissionDiagnostics.unknownReport(),
            availableFrameworks: [
                "AppKit", "ApplicationServices", "CoreGraphics", "ScreenCaptureKit", "Vision", "Foundation"
            ],
            warnings: ["Daemon-authoritative permission context is unavailable"],
            permissionContext: "unknown",
            runtimeIdentity: .current(),
            launchAgent: launchAgentManager.status(),
            keyboardAccess: .unknown()
        )
        return ResponseEnvelope(
            requestID: request.requestID,
            status: .blocked,
            result: (try? JSONValue.fromEncodable(report)) ?? .object([:]),
            evidence: [Evidence(
                kind: "daemon_unavailable",
                message: "Permission checks were not evaluated in the CLI process",
                source: "macctld"
            )],
            error: MacCtlError(
                code: MacCtlErrorCode.daemonUnavailable.rawValue,
                message: "macctld is unavailable at \(MacCtlPaths.socketURL.path): \(socketError)"
            )
        )
    }

    public func unavailableStatusResponse(
        request: RequestEnvelope,
        socketError: String
    ) -> ResponseEnvelope {
        let status = DaemonStatus(
            daemonName: "macctld",
            runtimeContext: "unknown",
            processID: 0,
            socketPath: MacCtlPaths.socketURL.path,
            socketExists: FileManager.default.fileExists(atPath: MacCtlPaths.socketURL.path),
            approvalCount: 0,
            supportedSurfaces: SurfaceKind.allCases,
            runtimeIdentity: .current(),
            launchAgent: launchAgentManager.status(),
            socketOwnerOnly: MacCtlPaths.ownerOnlySocketPath(),
            receiptStore: .unavailable()
        )
        return ResponseEnvelope(
            requestID: request.requestID,
            status: .blocked,
            result: (try? JSONValue.fromEncodable(status)) ?? .object([:]),
            evidence: [Evidence(
                kind: "daemon_unavailable",
                message: "Status reflects launchd state; daemon runtime was not reached",
                source: "launchd"
            )],
            error: MacCtlError(
                code: MacCtlErrorCode.daemonUnavailable.rawValue,
                message: "macctld is unavailable at \(MacCtlPaths.socketURL.path): \(socketError)"
            )
        )
    }

    private func requiredString(_ request: RequestEnvelope, key: String) throws -> String {
        guard let value = request.params[key]?.stringValue,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowExecutionError.missingParameter(key)
        }
        return value
    }

    private func ephemeralInputs(from request: RequestEnvelope) throws -> [String: String] {
        guard let raw = request.params["ephemeral_inputs"] else { return [:] }
        guard let object = raw.objectValue else {
            throw WorkflowExecutionError.unsafeInput("ephemeral_inputs must be an object of strings")
        }
        var inputs: [String: String] = [:]
        for (key, value) in object {
            guard !key.isEmpty, let string = value.stringValue else {
                throw WorkflowExecutionError.unsafeInput("ephemeral_inputs must contain only string values")
            }
            inputs[key] = string
        }
        return inputs
    }

    private func requestedFocusPolicy(from request: RequestEnvelope) throws -> FocusPolicy? {
        guard let raw = request.params["focus_policy"] else { return nil }
        guard let value = raw.stringValue, let policy = FocusPolicy(rawValue: value) else {
            throw WorkflowExecutionError.unsafeInput(
                "focus_policy must be either foreground or background"
            )
        }
        return policy
    }

    private func workflowApplyingRequestedFocusPolicy(
        _ workflow: WorkflowSpec,
        request: RequestEnvelope
    ) throws -> WorkflowSpec {
        guard let policy = try requestedFocusPolicy(from: request) else { return workflow }
        return workflow.withFocusPolicy(policy)
    }

    private func executeWorkflow(
        _ workflow: WorkflowSpec,
        ephemeralInputs: [String: String],
        keyboardLeaseToken: String? = nil
    ) throws -> ExecutionReport {
        try withExecutionLock {
            try workflowExecutor.execute(
                workflow,
                ephemeralInputs: ephemeralInputs,
                keyboardLeaseToken: keyboardLeaseToken
            )
        }
    }

    private func withExecutionLock<T>(_ operation: () throws -> T) rethrows -> T {
        executionLock.lock()
        defer { executionLock.unlock() }
        return try operation()
    }

    private func recordReceipt(
        for request: RequestEnvelope,
        response: ResponseEnvelope,
        startedAt: Date
    ) {
        let workflowID = request.params["workflow"]?.stringValue
            ?? response.result["workflow_id"]?.stringValue
            ?? response.result["workflow"]?.stringValue
            ?? response.result["approval"]?.objectValue?["workflowID"]?.stringValue
            ?? response.result["approval"]?.objectValue?["workflow_id"]?.stringValue
            ?? response.error?.details["workflow_id"]?.stringValue
        let workflow = workflowID.flatMap { workflowRegistry.workflow(id: $0) }
        let taskPlan = decodeTaskPlan(request.params["plan"])
        let taskID = request.params["task_id"]?.stringValue
            ?? response.result["task_id"]?.stringValue
            ?? response.result["taskID"]?.stringValue
            ?? taskPlan?.id
        let checkpoint: TaskCheckpoint?
        if let taskID {
            do {
                checkpoint = try taskCheckpointStore.load(taskID: taskID)
            } catch {
                checkpoint = nil
            }
        } else {
            checkpoint = nil
        }
        let taskLifecycleState = response.result["lifecycle_state"]?.stringValue
            ?? response.result["state"]?.stringValue
            ?? checkpoint?.state.rawValue
        let currentTaskStepID = response.result["current_step_id"]?.stringValue
            ?? response.result["currentStepID"]?.stringValue
            ?? checkpoint?.currentStepID
        let lastTaskStepID = response.result["last_step_id"]?.stringValue
            ?? response.result["lastStepID"]?.stringValue
            ?? checkpoint?.lastStepID
        let terminalTaskState = [
            TaskLifecycleState.completed.rawValue,
            TaskLifecycleState.cancelled.rawValue,
            TaskLifecycleState.expired.rawValue
        ]
        let taskStepID = terminalTaskState.contains(taskLifecycleState ?? "")
            ? (lastTaskStepID ?? currentTaskStepID)
            : (currentTaskStepID ?? lastTaskStepID)
        let taskStep = taskPlan?.steps.first { $0.id == taskStepID }
            ?? taskPlan?.steps.first
        let taskRisk = taskStep?.risk
        let taskTargetSurface = taskPlan?.surface
        let taskFocusPolicy = taskPlan?.focusPolicy
        let focusPolicy = response.result["focus_policy"]?.stringValue
            .flatMap(FocusPolicy.init(rawValue:))
            ?? response.result["focusPolicy"]?.stringValue
                .flatMap(FocusPolicy.init(rawValue:))
            ?? response.result["approval"]?.objectValue?["focusPolicy"]?.stringValue
                .flatMap(FocusPolicy.init(rawValue:))
            ?? response.result["approval"]?.objectValue?["focus_policy"]?.stringValue
                .flatMap(FocusPolicy.init(rawValue:))
            ?? response.error?.details["focus_policy"]?.stringValue
                .flatMap(FocusPolicy.init(rawValue:))
            ?? request.params["focus_policy"]?.stringValue
                .flatMap(FocusPolicy.init(rawValue:))
            ?? workflow?.focusPolicy
            ?? taskFocusPolicy
        let permissions = permissionContext == "daemon"
            ? PermissionDiagnostics.report()
            : PermissionDiagnostics.unknownReport()
        let approvalState: String
        if let workflow {
            let risk = workflowRegistry.validate(workflow).risk
            if risk != .sensitive {
                approvalState = "not_required"
            } else {
                switch request.method {
                case "workflow.prepare":
                    approvalState = response.status == .prepared ? "prepared" : "required"
                case "approval.approve":
                    approvalState = response.status == .succeeded ? "approved" : "required"
                case "approval.deny":
                    approvalState = response.status == .succeeded ? "denied" : "required"
                case "workflow.run":
                    approvalState = response.status == .succeeded ? "approved" : "required"
                default:
                    approvalState = response.status == .succeeded ? "approved" : "required"
                }
            }
        } else if taskID != nil {
            switch request.method {
            case "task.prepare": approvalState = response.status == .prepared ? "prepared" : "required"
            case "approval.approve": approvalState = response.status == .succeeded ? "approved" : "required"
            case "approval.deny": approvalState = response.status == .succeeded ? "denied" : "required"
            case "task.run", "task.resume": approvalState = response.status == .succeeded ? "approved" : "required"
            default: approvalState = "not_required"
            }
        } else {
            approvalState = "not_required"
        }
        let controlVerification = response.result["verification"]?.objectValue?["state"]?.stringValue
            ?? response.result["verification"]?.stringValue
        let verificationResult: String
        if let controlVerification {
            verificationResult = controlVerification
        } else if taskLifecycleState == TaskLifecycleState.completed.rawValue {
            verificationResult = "passed"
        } else if taskLifecycleState == TaskLifecycleState.indeterminate.rawValue {
            verificationResult = "indeterminate"
        } else if response.evidence.contains(where: { $0.kind == "assertion" }) {
            verificationResult = "passed"
        } else if response.status == .blocked || response.status == .failed {
            verificationResult = "blocked"
        } else {
            verificationResult = "not_required"
        }
        let receiptSource = request.params["source"]?.stringValue
            ?? (["approval.approve", "approval.deny"].contains(request.method) ? "cli" : nil)
        let receipt = OperationReceipt(
            operationID: response.operationID,
            requestID: response.requestID,
            method: request.method,
            source: receiptSource,
            workflowID: workflowID,
            targetSurface: workflow?.surface ?? taskTargetSurface,
            focusPolicy: focusPolicy,
            risk: workflow.map { workflowRegistry.validate($0).risk } ?? taskRisk,
            approvalState: approvalState,
            executionResult: response.status.rawValue,
            verificationResult: verificationResult,
            planDigest: response.result["plan_digest"]?.stringValue
                ?? response.result["planDigest"]?.stringValue
                ?? checkpoint?.planDigest,
            taskID: taskID,
            stepID: taskStepID,
            route: response.result["last_route"]?.stringValue
                ?? response.result["lastRoute"]?.stringValue
                ?? response.result["route"]?.stringValue
                ?? checkpoint?.route,
            adapterID: taskStep?.action.parameters["adapter_id"]?.stringValue,
            recoveryClassification: taskStep?.recovery.mode,
            preconditionResult: checkpoint?.verificationResult == "precondition_failed"
                ? "blocked"
                : taskLifecycleState == TaskLifecycleState.completed.rawValue ? "passed" : nil,
            postconditionResult: checkpoint?.verificationResult == "postcondition_failed"
                ? "failed"
                : taskLifecycleState == TaskLifecycleState.completed.rawValue ? "passed" : nil,
            lifecycleState: taskLifecycleState,
            actionOutcome: response.outcome,
            controlTarget: controlReceiptTarget(for: request),
            runtimeIdentity: .current(),
            permissionContext: permissionContext,
            permissions: permissions,
            status: response.status,
            errorCode: response.error?.code,
            evidence: receiptEvidence(
                response: response,
                taskID: taskID,
                checkpoint: checkpoint
            ),
            startedAt: startedAt,
            completedAt: Date()
        )
        do {
            try receiptStore.record(receipt)
        } catch {
            logger.record(event: "receipt_write_failed", metadata: [
                "operation_id": response.operationID,
                "error": error.localizedDescription
            ])
        }
    }

    private func controlReceiptTarget(for request: RequestEnvelope) -> ControlReceiptTarget? {
        guard request.method.hasPrefix("control.") else { return nil }
        let application: AppInfo?
        if let requestedApplication = request.params["app"]?.stringValue {
            application = try? resolveApplication(requestedApplication)
        } else {
            application = foregroundApplication()
        }
        guard let application else { return nil }

        let selectorKeys = [
            "role", "identifier", "locatorDigest", "title", "subrole", "containsText",
            "normalizedX", "normalizedY", "rawX", "rawY", "imageAnchor",
            "windowTitle", "windowIdentifier"
        ]
        let selectorObject = request.params["selector"]?.objectValue ?? [:]
        var selectorValues: [String: JSONValue] = [:]
        for key in selectorKeys {
            if let value = selectorObject[key] ?? request.params[key], value != .null {
                selectorValues[key] = value
            }
        }
        let selectorFields = selectorValues.keys.sorted()
        let locatorDigest: String? = if selectorFields.isEmpty {
            nil
        } else {
            CapabilityProfileDigest.make(selectorFields.map { key in
                let encoded = (try? JSONCodec.encode(selectorValues[key]!)) ?? Data()
                return "\(key)=\(CapabilityProfileDigest.make(String(decoding: encoded, as: UTF8.self)))"
            }.joined(separator: "|"))
        }

        return ControlReceiptTarget(
            application: ControlReceiptApplication(application: application),
            action: request.params["action"]?.stringValue ?? request.method,
            targetFingerprintDigest: request.params["target_fingerprint"]?.stringValue
                .map(CapabilityProfileDigest.make),
            locatorDigest: locatorDigest,
            selectorFields: selectorFields
        )
    }

    private func architectureName() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func decodeTaskPlan(_ value: JSONValue?) -> TaskPlan? {
        guard let value, let data = try? JSONCodec.encode(value) else { return nil }
        return try? JSONCodec.decode(TaskPlan.self, from: data)
    }

    private func receiptEvidence(
        response: ResponseEnvelope,
        taskID: String?,
        checkpoint: TaskCheckpoint?
    ) -> [ReceiptEvidence] {
        var evidence = response.evidence.map { ReceiptEvidence(kind: $0.kind, source: $0.source) }
        guard taskID != nil,
              checkpoint != nil,
              !evidence.contains(where: { $0.kind == "task_checkpoint" }) else {
            return evidence
        }
        evidence.append(ReceiptEvidence(kind: "task_checkpoint", source: "macctld"))
        return evidence
    }

    private func validatedExternalIdentifier(
        _ request: RequestEnvelope,
        key: String
    ) throws -> String {
        let value = try requiredString(request, key: key)
        guard value.count <= 128,
              value.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            throw WorkflowExecutionError.unsafeInput(
                "\(key) must contain only letters, digits, dot, underscore, or hyphen"
            )
        }
        return value
    }

    private func externalApprovalResult(
        _ approval: ExternalApprovalRequest
    ) -> [String: JSONValue] {
        [
            "operation_id": .string(approval.record.operationID),
            "provider": .string(approval.provider),
            "provider_instance_id": .string(approval.providerInstanceID),
            "plan_id": .string(approval.planID),
            "plan_digest": .string(approval.planDigest),
            "state": .string(approval.state.rawValue),
            "expires_at": (try? JSONValue.fromEncodable(approval.record.expiresAt)) ?? .null
        ]
    }

    private func externalApprovalFailure(
        _ request: RequestEnvelope,
        operationID: String? = nil,
        token: String? = nil,
        error: ExternalApprovalStoreError
    ) -> ResponseEnvelope {
        let resolvedOperationID = operationID
            ?? token.flatMap { externalApprovalStore.record(for: $0)?.operationID }
        let code: MacCtlErrorCode
        let status: OperationStatus
        switch error {
        case .notFound:
            code = .approvalNotFound
            status = .blocked
        case .expired:
            code = .approvalExpired
            status = .expired
        case .alreadyUsed:
            code = .approvalAlreadyUsed
            status = .blocked
        case .mismatch:
            code = .approvalMismatch
            status = .blocked
        case .pending:
            code = .approvalRequired
            status = .blocked
        case .denied:
            code = .approvalRequired
            status = .denied
        }
        return failure(
            request,
            status: status,
            code: code,
            message: error.localizedDescription,
            operationID: resolvedOperationID
        )
    }

    private func success<T: Encodable>(
        _ request: RequestEnvelope,
        status: OperationStatus = .succeeded,
        operationID: String? = nil,
        value: T,
        evidence: [Evidence] = [],
        outcome: AgentActionOutcome? = nil
    ) throws -> ResponseEnvelope {
        ResponseEnvelope(
            requestID: request.requestID,
            operationID: operationID ?? UUID().uuidString,
            status: status,
            result: try JSONValue.fromEncodable(value),
            evidence: evidence,
            outcome: outcome
        )
    }

    private func success(
        _ request: RequestEnvelope,
        status: OperationStatus = .succeeded,
        operationID: String? = nil,
        result: [String: JSONValue],
        evidence: [Evidence] = [],
        outcome: AgentActionOutcome? = nil
    ) throws -> ResponseEnvelope {
        ResponseEnvelope(
            requestID: request.requestID,
            operationID: operationID ?? UUID().uuidString,
            status: status,
            result: .object(result),
            evidence: evidence,
            outcome: outcome
        )
    }

    private func failure(
        _ request: RequestEnvelope,
        status: OperationStatus,
        code: MacCtlErrorCode,
        message: String,
        operationID: String? = nil,
        evidence: [Evidence] = [],
        details: [String: JSONValue] = [:],
        outcome: AgentActionOutcome? = nil
    ) -> ResponseEnvelope {
        ResponseEnvelope(
            requestID: request.requestID,
            operationID: operationID ?? UUID().uuidString,
            status: status,
            evidence: evidence,
            error: MacCtlError(code: code.rawValue, message: message, details: details),
            outcome: outcome
        )
    }

    private func approvalFailure(
        _ request: RequestEnvelope,
        token: String,
        error: ApprovalStoreError
    ) -> ResponseEnvelope {
        let record = approvalStore.record(for: token)
        var details: [String: JSONValue] = [:]
        if let record {
            details["workflow_id"] = .string(record.workflowID)
            details["focus_policy"] = .string(record.focusPolicy.rawValue)
        }
        let code: MacCtlErrorCode
        switch error {
        case .notFound: code = .approvalNotFound
        case .expired: code = .approvalExpired
        case .alreadyUsed: code = .approvalAlreadyUsed
        case .mismatch: code = .approvalMismatch
        }
        return failure(
            request,
            status: .blocked,
            code: code,
            message: error.localizedDescription,
            operationID: record?.operationID,
            details: details
        )
    }

    private func taskApprovalFailure(
        _ request: RequestEnvelope,
        token: String,
        error: TaskApprovalStoreError
    ) -> ResponseEnvelope {
        let code: MacCtlErrorCode
        switch error {
        case .notFound: code = .taskApprovalRequired
        case .expired: code = .taskExpired
        case .alreadyUsed: code = .taskApprovalRequired
        case .mismatch: code = .taskApprovalMismatch
        }
        return failure(
            request,
            status: .blocked,
            code: code,
            message: error.localizedDescription,
            details: ["token_present": .bool(!token.isEmpty)]
        )
    }

    private func errorResponse(_ request: RequestEnvelope, error: Error) -> ResponseEnvelope {
        var status: OperationStatus
        let code: MacCtlErrorCode
        var details: [String: JSONValue] = [:]
        var evidence: [Evidence] = []
        switch error {
        case let error as SemanticScrollFailure:
            status = .blocked
            switch error.failureClass {
            case .noObservedChange, .verificationUnavailable:
                code = .scrollVerificationUnavailable
            default:
                code = .scrollFallbackRequired
            }
            details = error.details
            evidence = [Evidence(
                kind: "scroll_fallback",
                message: "Semantic Accessibility scrolling did not complete a verified action; follow the provider recommendation or refine the target",
                source: "macctld",
                metadata: error.details
            )]
        case let error as ControlVerificationFailure:
            status = .blocked
            code = .controlVerificationUnavailable
            details = error.details
            evidence = [Evidence(
                kind: "control_verification",
                message: "The control action may have been dispatched, but its declared postcondition was not verified; no completion was reported",
                source: "macctld",
                metadata: error.details
            )]
        case let error as ControlBatchExecutionError:
            status = .blocked
            code = .operationFailed
            details = error.details
            evidence = [Evidence(
                kind: "control_batch",
                message: "A bounded control batch stopped fail-closed; the app lease was released and the remaining steps were not attempted",
                source: "macctld",
                metadata: error.details
            )]
        case let error as ShortcutError:
            status = .blocked
            switch error {
            case .bindingNotFound:
                code = .shortcutNotFound
            case .conflict:
                code = .shortcutConflict
            case .setupRequired:
                code = .shortcutSetupRequired
            case .handoffRequired:
                code = .shortcutHandoffRequired
            case .staleBinding, .menuPathDrift:
                code = .shortcutStale
            case .verificationUnavailable:
                code = .controlVerificationUnavailable
            case .invalidTarget, .invalidChord, .duplicateBinding, .persistence:
                status = .failed
                code = .invalidRequest
            case .appNotRunning, .menuPathNotFound, .ambiguousMenuPath,
                    .menuItemDisabled, .dynamicMenuItem, .unsupported:
                code = .taskBlocked
            }
            details["failure_class"] = .string(code.rawValue)
        case let error as TaskControlError:
            switch error {
            case .invalidPlan(let errors):
                status = .failed
                code = .taskInvalidPlan
                details["errors"] = .array(errors.map(JSONValue.string))
            case .notFound:
                status = .blocked
                code = .taskNotFound
            case .approvalRequired:
                status = .blocked
                code = .taskApprovalRequired
            case .approvalMismatch:
                status = .blocked
                code = .taskApprovalMismatch
            case .invalidState(let state):
                status = .blocked
                code = .taskStateInvalid
                details["state"] = .string(state.rawValue)
            case .leaseRequired:
                status = .blocked
                code = .taskLeaseRequired
            case .leaseExpired:
                status = .expired
                code = .taskExpired
            case .cancelled:
                status = .blocked
                code = .taskCancelled
            case .timedOut:
                status = .expired
                code = .taskTimeout
            case .actionBudgetExceeded:
                status = .blocked
                code = .taskActionBudgetExceeded
            case .preconditionFailed:
                status = .blocked
                code = .taskPreconditionFailed
            case .postconditionFailed:
                status = .blocked
                code = .taskPostconditionFailed
            case .indeterminate:
                status = .blocked
                code = .taskIndeterminate
            case .checkpointUnavailable:
                status = .blocked
                code = .taskCheckpointUnavailable
            case .blocked:
                status = .blocked
                code = .taskBlocked
            }
        case let error as TaskActionExecutionError:
            switch error {
            case .permissionMissing(let permission):
                status = .blocked
                code = .adapterPermissionMissing
                details["permission"] = .string(permission)
            case .unsupported:
                status = .blocked
                code = .adapterUnsupported
            case .uncertain:
                status = .blocked
                code = .taskIndeterminate
            case .blocked:
                status = .blocked
                code = .taskBlocked
            }
        case let error as AppAdapterError:
            status = .blocked
            switch error {
            case .permissionMissing(let permission):
                code = .adapterPermissionMissing
                details["permission"] = .string(permission)
            case .unsupportedAdapter, .unsupportedOperation, .arbitraryScriptRejected:
                code = .adapterUnsupported
            case .ambiguousTarget, .targetUnavailable, .operationFailed:
                code = .taskBlocked
            }
        case let error as InputControllerError:
            switch error {
            case .permissionDenied:
                status = .blocked
                code = .permissionDenied
            default:
                status = .failed
                code = .operationFailed
            }
        case let error as AccessibilityControllerError:
            switch error {
            case .permissionDenied:
                status = .blocked
                code = .permissionDenied
            case .applicationNotRunning:
                status = .blocked
                code = .accessibilityTreeUnavailable
            case .ambiguousMatch, .windowNotFound, .ambiguousWindowMatch,
                 .unreadableFocus, .elementNotFound, .scrollTargetRequired, .scrollUnavailable,
                 .actionUnavailable:
                status = .blocked
                code = .taskBlocked
            default:
                status = .failed
                code = .operationFailed
            }
        case let error as AppControllerError:
            switch error {
            case let .focusChanged(expected, actual):
                status = .blocked
                code = .focusChanged
                details["focus_policy"] = .string(FocusPolicy.background.rawValue)
                details["expected_foreground"] = .string(expected)
                details["actual_foreground"] = .string(actual)
                evidence = [Evidence(
                    kind: "focus_guard",
                    message: "Application open changed foreground focus; execution was blocked",
                    source: "macctld",
                    metadata: [
                        "policy": .string(FocusPolicy.background.rawValue),
                        "expected": .string(expected),
                        "actual": .string(actual)
                    ]
                )]
            default:
                status = .failed
                code = .operationFailed
            }
        case let error as CaptureControllerError:
            switch error {
            case .permissionDenied:
                status = .blocked
                code = .permissionDenied
            default:
                status = .failed
                code = .operationFailed
            }
        case let error as KeyboardControlError:
            switch error {
            case .confirmationRequired:
                status = .blocked
                code = .keyboardConfirmationRequired
            case .leaseRequired:
                status = .blocked
                code = .keyboardLeaseRequired
            case .fullKeyboardAccessDisabled:
                status = .blocked
                code = .keyboardAccessDisabled
            case .enableVerificationFailed:
                status = .blocked
                code = .keyboardEnableVerificationFailed
            case .permissionDenied(let permission):
                status = .blocked
                code = .permissionDenied
                details["permission"] = .string(permission)
            case .foregroundUnavailable:
                status = .blocked
                code = .keyboardFocusUnavailable
                evidence = [Evidence(
                    kind: "keyboard_focus_guard",
                    message: "Foreground state could not be read; keyboard input was blocked",
                    source: "macctld"
                )]
            case .appScopeMismatch(let expected, let actual):
                status = .blocked
                code = .keyboardFocusChanged
                details["expected_foreground"] = .string(expected)
                details["actual_foreground"] = .string(actual)
                evidence = [Evidence(
                    kind: "keyboard_focus_guard",
                    message: "App-scoped keyboard lease did not match the foreground process",
                    source: "macctld"
                )]
            case .invalidCommand:
                status = .failed
                code = .keyboardCommandInvalid
            case .invalidSequence, .sequenceTooLong, .repetitionLimitExceeded, .invalidInterKeyDelay:
                status = .failed
                code = .keyboardSequenceInvalid
            case .printableKeyRejected:
                status = .blocked
                code = .keyboardPrintableKeyRejected
            }
        case let error as KeyboardDriveStoreError:
            status = .blocked
            switch error {
            case .confirmationRequired:
                code = .keyboardConfirmationRequired
            case .duplicateLease:
                code = .keyboardLeaseConflict
            case .invalidLifetime, .applicationRequired:
                code = .keyboardLeaseInvalid
            case .physicalKeyboardSuppressionRequiresSession:
                code = .keyboardPhysicalSuppressionRequiresSession
            case .physicalKeyboardSuppressionUnavailable:
                code = .keyboardPhysicalSuppressionUnavailable
            case .physicalKeyboardSuppressionReasonRequired:
                code = .keyboardFreezeReasonRequired
            case .notFound:
                code = .keyboardLeaseNotFound
            case .expired:
                code = .keyboardLeaseExpired
            }
        case let error as SemanticActionRouterError:
            switch error {
            case .invalidSelector:
                status = .failed
                code = .invalidSelector
            case .selectorRequiresActivate:
                status = .failed
                code = .invalidSelector
            case .rawCoordinateRequiresExplicitOptIn:
                status = .blocked
                code = .unsafeInput
            }
        case let error as WarmPathSelectionError:
            status = .blocked
            code = .routeSelectionBlocked
            details["selection_reason"] = .string(error.localizedDescription)
        case let error as WarmPathStoreError:
            status = .failed
            code = .routeSelectionBlocked
            details["registry_error"] = .string(error.localizedDescription)
        case is RouteBenchmarkError:
            status = .blocked
            code = .routeBenchmarkBlocked
        case is ControlStateVerifierError:
            status = .blocked
            code = .operationFailed
        case let error as ApprovalStoreError:
            status = .blocked
            switch error {
            case .notFound: code = .approvalNotFound
            case .expired: code = .approvalExpired
            case .alreadyUsed: code = .approvalAlreadyUsed
            case .mismatch: code = .approvalMismatch
            }
        case let error as TaskApprovalStoreError:
            status = .blocked
            switch error {
            case .notFound, .alreadyUsed: code = .taskApprovalRequired
            case .expired: code = .taskExpired
            case .mismatch: code = .taskApprovalMismatch
            }
        case is TaskCheckpointStoreError:
            status = .blocked
            code = .taskCheckpointUnavailable
        case is ControlTargetInspectionError:
            status = .blocked
            code = .taskBlocked
            evidence = [Evidence(
                kind: "task_target_guard",
                message: "Task target observation was unreadable or unsafe; execution paused",
                source: "macctld"
            )]
        case let error as WorkflowExecutionError:
            status = .blocked
            switch error {
            case .invalidWorkflow:
                code = .workflowInvalid
            case .unsafeInput:
                code = .unsafeInput
            case .backgroundUnsupported:
                code = .backgroundUnsupported
                details["focus_policy"] = .string(FocusPolicy.background.rawValue)
                evidence = [Evidence(
                    kind: "focus_guard",
                    message: "Background policy rejected an operation that could not be isolated from foreground focus",
                    source: "macctld",
                    metadata: ["policy": .string(FocusPolicy.background.rawValue)]
                )]
            case .indeterminate:
                code = .taskIndeterminate
                evidence = [Evidence(
                    kind: "search_focus_guard",
                    message: "Search input may have been dispatched, but the declared Accessibility focus could not be reverified",
                    source: "macctld"
                )]
            case let .focusChanged(expected, actual):
                code = .focusChanged
                details["focus_policy"] = .string(FocusPolicy.background.rawValue)
                details["expected_foreground"] = .string(expected)
                details["actual_foreground"] = .string(actual)
                evidence = [Evidence(
                    kind: "focus_guard",
                    message: "Background workflow changed foreground focus; execution was blocked",
                    source: "macctld",
                    metadata: [
                        "policy": .string(FocusPolicy.background.rawValue),
                        "expected": .string(expected),
                        "actual": .string(actual)
                    ]
                )]
            default:
                code = .operationFailed
            }
        default:
            status = .failed
            code = .operationFailed
        }
        return failure(
            request,
            status: status,
            code: code,
            message: error.localizedDescription,
            evidence: evidence,
            details: details,
            outcome: agentActionOutcome(for: error, code: code, details: details)
        )
    }

    private func agentActionOutcome(
        for error: Error,
        code: MacCtlErrorCode,
        details: [String: JSONValue]
    ) -> AgentActionOutcome {
        if let scrollFailure = error as? SemanticScrollFailure {
            let state: AgentActionOutcomeState = switch scrollFailure.failureClass {
            case .targetMissing: .targetMissing
            case .targetAmbiguous: .targetAmbiguous
            case .actionUnavailable: .actionUnavailable
            case .actionFailed: .actionFailed
            case .permissionDenied: .permissionBlocked
            case .noObservedChange: .noObservedChange
            case .verificationUnavailable: .verificationUnavailable
            }
            let recommended = scrollFailure.recommendedProvider?.rawValue
            return AgentActionOutcome(
                state: state,
                route: ControlActionRoute.scroll.rawValue,
                verification: scrollFailure.localFallbackVerification?.rawValue,
                failureClass: scrollFailure.failureClass.rawValue,
                fallbackAllowed: scrollFailure.fallbackAllowed,
                recommendedProvider: recommended,
                freshStateRequired: scrollFailure.freshStateRequired,
                nextAction: recommended == ScrollFallbackRoute.computerUse.rawValue
                    ? "get_app_state_then_relocate_target_and_verify_with_computer_use"
                    : nil
            )
        }

        let failureClass = details["failure_class"]?.stringValue
        let state: AgentActionOutcomeState
        switch failureClass {
        case "target_missing": state = .targetMissing
        case "target_ambiguous": state = .targetAmbiguous
        case "action_unavailable": state = .actionUnavailable
        case "no_observed_change": state = .noObservedChange
        case "verification_unavailable": state = .verificationUnavailable
        case "permission_denied": state = .permissionBlocked
        case "foreground_race": state = .foregroundRace
        default:
            switch code {
            case .permissionDenied, .adapterPermissionMissing:
                state = .permissionBlocked
            case .focusChanged, .keyboardFocusChanged, .keyboardFocusUnavailable:
                state = .foregroundRace
            case .routeSelectionBlocked, .routeBenchmarkBlocked:
                state = .actionUnavailable
            default:
                state = .actionFailed
            }
        }
        let recommended = details["recommended_provider"]?.stringValue
        let freshStateRequired = details["fresh_state_required"]?.boolValue ?? false
        let fallbackAllowed = details["fallback_allowed"]?.boolValue ?? false
        let nextAction: String? = if recommended == ScrollFallbackRoute.computerUse.rawValue {
            "get_app_state_then_relocate_target_and_verify_with_computer_use"
        } else if freshStateRequired {
            "refresh_state_before_retrying"
        } else {
            nil
        }
        return AgentActionOutcome(
            state: state,
            route: details["route"]?.stringValue,
            verification: details["local_fallback_verification"]?.stringValue,
            failureClass: failureClass,
            fallbackAllowed: fallbackAllowed,
            recommendedProvider: recommended,
            freshStateRequired: freshStateRequired,
            nextAction: nextAction
        )
    }
}
