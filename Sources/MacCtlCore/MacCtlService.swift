import Foundation

public final class MacCtlService {
    private let appController: AppController
    private let workflowRegistry: WorkflowRegistry
    private let workflowExecutor: WorkflowExecutor
    private let approvalStore: ApprovalStore
    private let iphoneController: IPhoneMirroringController
    private let iphoneDrivingLeaseStore: IPhoneMirroringDrivingLeaseStore
    private let keyboardAccessController: KeyboardAccessController
    private let keyboardDriveStore: KeyboardDriveStore
    private let taskApprovalStore: TaskApprovalStore
    private let taskCheckpointStore: TaskCheckpointStore
    private let taskRunner: TaskRunner
    private let adapterRegistry: AppAdapterRegistry
    private let targetInspector: ControlTargetInspecting
    private let focusedElementInspector: FocusedElementInspecting
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

    public init(
        appController: AppController = AppController(),
        workflowRegistry: WorkflowRegistry = WorkflowRegistry(),
        approvalStore: ApprovalStore = ApprovalStore(),
        presentApproval: ((ApprovalRecord) -> Void)? = nil,
        logger: SafeLog = SafeLog(),
        receiptStore: OperationReceiptStore = OperationReceiptStore(),
        permissionContext: String = "daemon",
        iphoneDrivingLeaseStore: IPhoneMirroringDrivingLeaseStore = IPhoneMirroringDrivingLeaseStore(),
        keyboardAccessController: KeyboardAccessController = KeyboardAccessController(),
        keyboardDriveStore: KeyboardDriveStore = KeyboardDriveStore(),
        taskApprovalStore: TaskApprovalStore = TaskApprovalStore(),
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
        hasPostEventAccess: (() -> Bool)? = nil
    ) {
        self.appController = appController
        self.workflowRegistry = workflowRegistry
        self.approvalStore = approvalStore
        self.presentApproval = presentApproval
        self.logger = logger
        self.receiptStore = receiptStore
        self.permissionContext = permissionContext
        self.iphoneDrivingLeaseStore = iphoneDrivingLeaseStore
        self.keyboardAccessController = keyboardAccessController
        self.keyboardDriveStore = keyboardDriveStore
        self.taskApprovalStore = taskApprovalStore
        self.taskCheckpointStore = taskCheckpointStore
        self.adapterRegistry = adapterRegistry
        let defaultAccessibilityController = AccessibilityController()
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
        self.activateApplication = activateApplication ?? { try appController.activate($0) }
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
        let resolvedIPhoneController = IPhoneMirroringController(
            appController: appController,
            captureController: captureController,
            inputController: inputController
        )
        self.iphoneController = resolvedIPhoneController
        self.workflowExecutor = WorkflowExecutor(
            appController: appController,
            inputController: inputController,
            captureController: captureController,
            iphoneController: resolvedIPhoneController
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
                   selector.tier == .accessibility,
                   let pid = application.processID {
                    do {
                        _ = try defaultAccessibilityController.findElement(pid: pid, selector: selector)
                    } catch AccessibilityControllerError.ambiguousMatch {
                        throw ControlTargetInspectionError.ambiguousTarget
                    } catch AccessibilityControllerError.elementNotFound {
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
        return response
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
            case "control.perform":
                return try performControlAction(request)
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
                return try success(request, value: approvalStore.list() + taskApprovalStore.list())
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
            case "iphone.status":
                return try success(request, value: iphoneController.state())
            case "iphone.drive.begin":
                return try beginIPhoneDrivingLease(request)
            case "iphone.drive.end":
                return try endIPhoneDrivingLease(request)
            case "iphone.open-app":
                let appName = try requiredString(request, key: "name")
                let drivingLease = try requiredIPhoneDrivingLease(from: request)
                let match = try withExecutionLock {
                    try iphoneController.openMirroredApp(appName, drivingLease: drivingLease)
                }
                return try success(
                    request,
                    result: [
                        "app": .string(appName),
                        "anchor_x": .number(Double(match.bounds.midX)),
                        "anchor_y": .number(Double(match.bounds.midY))
                    ],
                    evidence: [
                        Evidence(
                            kind: "mirroring_driving_lease",
                            message: "Synthetic Mirroring navigation ran under an active user-held exclusive driving lease",
                            source: "macctld"
                        ),
                        Evidence(
                            kind: "ocr_anchor",
                            message: "Mirrored app located and clicked by OCR",
                            source: "iPhone Mirroring"
                        )
                    ]
                )
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
        guard hasPostEventAccess() else {
            throw KeyboardControlError.permissionDenied("Post Events")
        }
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
            confirm: request.params["confirm"]?.boolValue == true
        )
        return try success(
            request,
            result: [
                "message": .string("Keyboard driving lease acquired; keep the physical keyboard and trackpad idle while driving"),
                "lease": try JSONValue.fromEncodable(lease),
                "scope": .string(scope.rawValue),
                "expires_at": try JSONValue.fromEncodable(lease.expiresAt)
            ],
            evidence: [Evidence(
                kind: "keyboard_lease",
                message: "A short-lived keyboard driving lease was acquired in memory",
                source: "macctld"
            )]
        )
    }

    private func releaseKeyboardLease(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        guard let token = request.params["token"]?.stringValue, !token.isEmpty else {
            throw KeyboardControlError.leaseRequired
        }
        let lease = try keyboardDriveStore.release(token: token)
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

    private func navigateKeyboard(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        guard let token = request.params["lease_token"]?.stringValue, !token.isEmpty else {
            throw KeyboardControlError.leaseRequired
        }
        let command = try KeyboardCommand.resolve(try requiredString(request, key: "command"))
        let count = try requestedKeyboardCount(from: request)
        let interKeyDelay = try requestedInterKeyDelay(from: request)
        let report = try withExecutionLock {
            try semanticActionRouter.perform(
                command: command,
                selector: nil,
                leaseToken: token,
                count: count,
                interKeyDelay: interKeyDelay,
                allowRawCoordinate: false
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
        let command = try KeyboardCommand.resolve(try requiredString(request, key: "action"))
        let selector = try requestedControlSelector(from: request)
        let count = try requestedKeyboardCount(from: request)
        let interKeyDelay = try requestedInterKeyDelay(from: request)
        let allowRawCoordinate = request.params["allow_raw_coordinate"]?.boolValue == true
        let usesEphemeralLease = hasRequestedApplication
        let report = try withExecutionLock {
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
                    allowRawCoordinate: allowRawCoordinate
                )
            }
            guard let token, !token.isEmpty else { throw KeyboardControlError.leaseRequired }
            return try semanticActionRouter.perform(
                command: command,
                selector: selector,
                leaseToken: token,
                count: count,
                interKeyDelay: interKeyDelay,
                allowRawCoordinate: allowRawCoordinate
            )
        }
        return try success(
            request,
            value: report,
            evidence: [Evidence(
                kind: "control_action",
                message: "Semantic control used the strongest available route and verified the resulting foreground state",
                source: "macctld",
                metadata: [
                    "route": .string(report.route.rawValue),
                    "fallback_used": .bool(report.fallbackUsed),
                    "verification": .string(report.verification.state.rawValue),
                    "foreground_changed": .bool(report.verification.foregroundChanged),
                    "focus_changed": .bool(report.verification.focusChanged),
                    "lease_mode": .string(usesEphemeralLease ? "ephemeral" : "provided"),
                    "lease_released": .bool(usesEphemeralLease),
                    "foreground_reasserted": .bool(usesEphemeralLease)
                ]
            )]
        )
    }

    private func performEphemeralControlAction(
        applicationName: String,
        command: KeyboardCommand,
        selector: Selector?,
        count: Int,
        interKeyDelay: TimeInterval,
        allowRawCoordinate: Bool
    ) throws -> SemanticActionReport {
        let activated = try activateApplication(applicationName)
        let stableForeground: AppInfo
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
            guard let current = observation.foregroundApplication else {
                throw KeyboardControlError.foregroundUnavailable
            }
            stableForeground = current
        } catch ControlStateVerifierError.timedOut {
            throw KeyboardControlError.appScopeMismatch(
                expected: keyboardApplicationLabel(activated),
                actual: keyboardApplicationLabel(foregroundApplication())
            )
        }

        let lease = try keyboardDriveStore.acquire(
            scope: .app,
            application: stableForeground,
            seconds: 30,
            confirm: true
        )
        defer { keyboardDriveStore.invalidate(token: lease.token) }
        return try semanticActionRouter.perform(
            command: command,
            selector: selector,
            leaseToken: lease.token,
            count: count,
            interKeyDelay: interKeyDelay,
            allowRawCoordinate: allowRawCoordinate
        )
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

    private func beginIPhoneDrivingLease(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let lease = try iphoneDrivingLeaseStore.acquire()
        return try success(
            request,
            result: [
                "message": .string(
                    "Exclusive iPhone Mirroring driving lease acquired; keep hands off the trackpad until the operation completes"
                ),
                "driving_lease_token": .string(lease.token),
                "expires_at": try JSONValue.fromEncodable(lease.expiresAt),
                "duration_seconds": .number(iphoneDrivingLeaseStore.lifetimeSeconds)
            ],
            evidence: [Evidence(
                kind: "mirroring_driving_lease",
                message: "User-held exclusive Mirroring driving lease acquired in memory",
                source: "macctld"
            )]
        )
    }

    private func endIPhoneDrivingLease(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let token = try requiredString(request, key: "driving_lease_token")
        guard iphoneDrivingLeaseStore.release(token: token) else {
            throw IPhoneMirroringDrivingLeaseError.invalidOrExpired
        }
        return try success(
            request,
            result: [
                "message": .string("Exclusive iPhone Mirroring driving lease released"),
                "released": .bool(true)
            ],
            evidence: [Evidence(
                kind: "mirroring_driving_lease",
                message: "User-held exclusive Mirroring driving lease released",
                source: "macctld"
            )]
        )
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
        let authority = try taskAuthority(for: plan, request: request, force: false)
        let report = try withExecutionLock {
            try taskRunner.run(
                plan: plan,
                approvalToken: token,
                ephemeralInputs: inputs,
                authority: authority
            )
        }
        return try taskResponse(request, report: report, message: "Task completed")
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
        let authority = try taskAuthority(for: plan, request: request, force: true)
        guard let authority else { throw TaskControlError.leaseRequired }
        let report = try withExecutionLock {
            try taskRunner.resume(
                plan: plan,
                approvalToken: token,
                ephemeralInputs: inputs,
                authority: authority
            )
        }
        return try taskResponse(request, report: report, message: "Task resumed and completed")
    }

    private func cancelTask(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let taskID = try requiredString(request, key: "task_id")
        // Cancellation is intentionally outside the action lock so a caller can
        // interrupt a task that is waiting on a bounded Accessibility or adapter
        // action.  TaskRunner owns its checkpoint/cancellation synchronization.
        let report = try taskRunner.cancel(taskID: taskID)
        return try taskResponse(request, report: report, message: "Task cancellation requested")
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
        force: Bool
    ) throws -> TaskExecutionAuthority? {
        guard force || plan.requiresInputAuthority(using: adapterRegistry) else { return nil }
        guard let token = request.params["lease_token"]?.stringValue, !token.isEmpty else {
            throw TaskControlError.leaseRequired
        }
        let requiresFullKeyboardAccess = plan.steps.contains { $0.action.kind == .key }
        let context = try controlSession.beginAction(
            leaseToken: token,
            requireFullKeyboardAccess: requiresFullKeyboardAccess
        )
        return TaskExecutionAuthority(
            leaseToken: token,
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
        case .click, .type, .key, .scroll, .activateWindow, .capture, .ocr:
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
        message: String
    ) throws -> ResponseEnvelope {
        var result = try JSONValue.fromEncodable(report).objectValue ?? [:]
        result["task_id"] = .string(report.taskID)
        result["plan_digest"] = .string(report.planDigest)
        result["lifecycle_state"] = .string(report.state.rawValue)
        if let lastStepID = report.lastStepID {
            result["last_step_id"] = .string(lastStepID)
        }
        result["message"] = .string(message)
        return try success(
            request,
            status: taskOperationStatus(report.state),
            result: result,
            evidence: [Evidence(
                kind: "task_checkpoint",
                message: "Task status was derived from a redacted durable checkpoint",
                source: "macctld",
                metadata: ["lifecycle_state": .string(report.state.rawValue)]
            )]
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
        if requiresIPhoneMirroringDrivingLease(workflow) {
            result["mirroring_driving_lease_required"] = .bool(true)
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
        let drivingLease = try requestedIPhoneMirroringDrivingLease(for: workflow, request: request)
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
            let prepared = try approvalStore.approve(token: token)
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
            return try executePrepared(request, prepared: prepared, drivingLease: drivingLease)
        }
        let report = try executeWorkflow(
            workflow,
            ephemeralInputs: suppliedInputs,
            drivingLease: drivingLease
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

    private func approve(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let token = try requiredString(request, key: "token")
        if token.hasPrefix("mct_") {
            do {
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
            let drivingLease: IPhoneMirroringDrivingLease?
            if let record = approvalStore.record(for: token),
               let workflow = workflowRegistry.workflow(id: record.workflowID) {
                drivingLease = try requestedIPhoneMirroringDrivingLease(for: workflow, request: request)
            } else {
                drivingLease = nil
            }
            let prepared = try approvalStore.approve(token: token)
            return try executePrepared(request, prepared: prepared, drivingLease: drivingLease)
        } catch let error as ApprovalStoreError {
            return approvalFailure(request, token: token, error: error)
        }
    }

    private func executePrepared(
        _ request: RequestEnvelope,
        prepared: PreparedApproval,
        drivingLease: IPhoneMirroringDrivingLease? = nil
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
        let resolvedDrivingLease = try drivingLease
            ?? requestedIPhoneMirroringDrivingLease(for: prepared.workflow, request: request)
        let report = try executeWorkflow(
            prepared.workflow,
            ephemeralInputs: prepared.ephemeralInputs,
            drivingLease: resolvedDrivingLease
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

    private func deny(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let token = try requiredString(request, key: "token")
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
                "app.list", "app.open", "launchApp", "activateWindow", "click", "type", "key",
                "scroll", "waitFor", "capture", "ocr", "assert", "workflow.prepare", "workflow.run",
                "workflow.background", "approval.approve", "approval.deny", "iphoneMirroring",
                "keyboard.status", "keyboard.setup", "keyboard.enable", "keyboard.inspect",
                "keyboard.lease.acquire", "keyboard.lease.release", "keyboard.navigate", "keyboard.send",
                "control.status", "control.perform", "task.prepare", "task.run", "task.status",
                "task.resume", "task.cancel", "adapter.capabilities"
            ],
            optionalBackends: ["AppleScript/JXA", "shortcuts", "devicectl developer-device diagnostics"],
            permissionGates: ["Accessibility", "Input Monitoring", "Post Events", "Screen Recording", "Automation"],
            safety: [
                "sensitive workflows require a short-lived single-use approval token",
                "raw coordinates require an explicit coordinate_mode=raw marker",
                "background workflows require named macOS app targets and preserve foreground focus",
                "background input is sent to target processes; global mouse, desktop, and foreground paths are rejected",
                "Full Keyboard Access is explicit, AppKit-verified, and never enabled at daemon startup",
                "direct keyboard navigation requires one short-lived, user-confirmed lease with per-key focus checks",
                "bare printable keys are rejected from keyboard.send; text remains ephemeral-input plus approval gated",
                "keyboard focus inspection returns only role, subrole, identifier, title, and target application",
                "semantic control prefers Accessibility actions, then keyboard navigation, then explicit visual fallback",
                "every semantic action revalidates the lease and foreground state and records redacted verification metadata",
                "atomic semantic control reasserts stable foreground, owns an ephemeral app lease, and releases it on every exit path",
                "task plans are approved by exact digest, checkpointed atomically, and never resume automatically",
                "task recovery is capped at three safe, two reversible, and one sensitive attempt",
                "sensitive uncertainty is indeterminate and is never retried automatically",
                "adapter operations are typed and allowlisted; arbitrary AppleScript and JXA are rejected",
                "task checkpoints contain only redacted identity hashes and verification state",
                "raw coordinate semantic fallback requires an explicit allow_raw_coordinate flag",
                "browser DOM automation and iPhone Mirroring remain separate surfaces",
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
            checkpointStore: taskCheckpointStore.status()
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
        drivingLease: IPhoneMirroringDrivingLease? = nil
    ) throws -> ExecutionReport {
        try withExecutionLock {
            try workflowExecutor.execute(
                workflow,
                ephemeralInputs: ephemeralInputs,
                mirroringDrivingLease: drivingLease
            )
        }
    }

    private func requestedIPhoneMirroringDrivingLease(
        for workflow: WorkflowSpec,
        request: RequestEnvelope
    ) throws -> IPhoneMirroringDrivingLease? {
        guard requiresIPhoneMirroringDrivingLease(workflow) else { return nil }
        return try requiredIPhoneDrivingLease(from: request)
    }

    private func requiredIPhoneDrivingLease(
        from request: RequestEnvelope
    ) throws -> IPhoneMirroringDrivingLease {
        guard let rawToken = request.params["driving_lease_token"] else {
            throw IPhoneMirroringDrivingLeaseError.required
        }
        guard let token = rawToken.stringValue, !token.isEmpty,
              let lease = iphoneDrivingLeaseStore.lease(for: token) else {
            throw IPhoneMirroringDrivingLeaseError.invalidOrExpired
        }
        try lease.requireHeld()
        return lease
    }

    private func requiresIPhoneMirroringDrivingLease(_ workflow: WorkflowSpec) -> Bool {
        workflow.recipe == "iphone-open-tinder"
            || workflow.actions.contains { action in
                guard action.surface == .iphoneMirroring else { return false }
                switch action.kind {
                case .click, .type, .key, .scroll:
                    return true
                default:
                    return false
                }
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

    private func success<T: Encodable>(
        _ request: RequestEnvelope,
        status: OperationStatus = .succeeded,
        operationID: String? = nil,
        value: T,
        evidence: [Evidence] = []
    ) throws -> ResponseEnvelope {
        ResponseEnvelope(
            requestID: request.requestID,
            operationID: operationID ?? UUID().uuidString,
            status: status,
            result: try JSONValue.fromEncodable(value),
            evidence: evidence
        )
    }

    private func success(
        _ request: RequestEnvelope,
        status: OperationStatus = .succeeded,
        operationID: String? = nil,
        result: [String: JSONValue],
        evidence: [Evidence] = []
    ) throws -> ResponseEnvelope {
        ResponseEnvelope(
            requestID: request.requestID,
            operationID: operationID ?? UUID().uuidString,
            status: status,
            result: .object(result),
            evidence: evidence
        )
    }

    private func failure(
        _ request: RequestEnvelope,
        status: OperationStatus,
        code: MacCtlErrorCode,
        message: String,
        operationID: String? = nil,
        evidence: [Evidence] = [],
        details: [String: JSONValue] = [:]
    ) -> ResponseEnvelope {
        ResponseEnvelope(
            requestID: request.requestID,
            operationID: operationID ?? UUID().uuidString,
            status: status,
            evidence: evidence,
            error: MacCtlError(code: code.rawValue, message: message, details: details)
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
        let status: OperationStatus
        let code: MacCtlErrorCode
        var details: [String: JSONValue] = [:]
        var evidence: [Evidence] = []
        switch error {
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
            case .ambiguousMatch, .unreadableFocus:
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
        case is ControlStateVerifierError:
            status = .blocked
            code = .operationFailed
        case let error as IPhoneMirroringError:
            status = .blocked
            switch error {
            case .drivingLeaseRequired:
                code = .mirroringDrivingLeaseRequired
            default:
                code = .operationFailed
            }
        case let error as IPhoneMirroringDrivingLeaseError:
            status = .blocked
            switch error {
            case .alreadyHeld:
                code = .mirroringDrivingLeaseHeld
            case .required:
                code = .mirroringDrivingLeaseRequired
            case .invalidOrExpired:
                code = .mirroringDrivingLeaseInvalid
            }
        case let error as ApprovalStoreError:
            status = .blocked
            switch error {
            case .notFound: code = .approvalNotFound
            case .expired: code = .approvalExpired
            case .alreadyUsed: code = .approvalAlreadyUsed
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
            case .mirroringDrivingLeaseRequired:
                code = .mirroringDrivingLeaseRequired
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
            details: details
        )
    }
}
