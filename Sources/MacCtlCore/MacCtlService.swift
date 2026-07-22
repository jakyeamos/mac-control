import Foundation

public final class MacCtlService {
    private let appController: AppController
    private let workflowRegistry: WorkflowRegistry
    private let workflowExecutor: WorkflowExecutor
    private let approvalStore: ApprovalStore
    private let iphoneController: IPhoneMirroringController
    private let launchAgentManager: LaunchAgentManager
    private let logger: SafeLog
    private let receiptStore: OperationReceiptStore
    private let permissionContext: String
    private let presentApproval: ((ApprovalRecord) -> Void)?

    public init(
        appController: AppController = AppController(),
        workflowRegistry: WorkflowRegistry = WorkflowRegistry(),
        approvalStore: ApprovalStore = ApprovalStore(),
        presentApproval: ((ApprovalRecord) -> Void)? = nil,
        logger: SafeLog = SafeLog(),
        receiptStore: OperationReceiptStore = OperationReceiptStore(),
        permissionContext: String = "daemon"
    ) {
        self.appController = appController
        self.workflowRegistry = workflowRegistry
        self.approvalStore = approvalStore
        self.presentApproval = presentApproval
        self.logger = logger
        self.receiptStore = receiptStore
        self.permissionContext = permissionContext
        let inputController = InputController()
        let captureController = CaptureController(appController: appController)
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
            case "app.list":
                return try success(request, value: appController.listApplications())
            case "app.open":
                let name = try requiredString(request, key: "name")
                let app = try appController.open(name)
                logger.record(event: "app_opened", metadata: ["app": app.name])
                return try success(request, value: app)
            case "workflow.list":
                return try success(request, value: workflowRegistry.list())
            case "workflow.validate":
                let id = try requiredString(request, key: "workflow")
                return try success(request, value: workflowRegistry.validate(id: id))
            case "workflow.prepare":
                return try prepareWorkflow(request)
            case "workflow.run":
                return try runWorkflow(request)
            case "approval.list":
                return try success(request, value: approvalStore.list())
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
            case "iphone.open-app":
                let appName = try requiredString(request, key: "name")
                let match = try iphoneController.openMirroredApp(appName)
                return try success(
                    request,
                    result: [
                        "app": .string(appName),
                        "anchor_x": .number(Double(match.bounds.midX)),
                        "anchor_y": .number(Double(match.bounds.midY))
                    ],
                    evidence: [Evidence(
                        kind: "ocr_anchor",
                        message: "Mirrored app located and clicked by OCR",
                        source: "iPhone Mirroring"
                    )]
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

    private func prepareWorkflow(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let id = try requiredString(request, key: "workflow")
        guard let workflow = workflowRegistry.workflow(id: id) else {
            return failure(request, status: .failed, code: .workflowNotFound, message: "Workflow does not exist")
        }
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
        return try success(
            request,
            status: .prepared,
            operationID: prepared.record.operationID,
            result: [
                "approval": try JSONValue.fromEncodable(prepared.record),
                "plan_digest": .string(prepared.planDigest),
                "risk": .string(validation.risk.rawValue),
                "expires_at": try JSONValue.fromEncodable(prepared.record.expiresAt)
            ],
            evidence: [Evidence(
                kind: "approval",
                message: "Exact workflow plan prepared; approval is required before execution",
                metadata: ["risk": .string(validation.risk.rawValue)]
            )]
        )
    }

    private func runWorkflow(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let id = try requiredString(request, key: "workflow")
        guard let workflow = workflowRegistry.workflow(id: id) else {
            return failure(request, status: .failed, code: .workflowNotFound, message: "Workflow does not exist")
        }
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
            let prepared = try approvalStore.approve(token: token)
            guard suppliedInputs.isEmpty || suppliedInputs == prepared.ephemeralInputs else {
                throw WorkflowExecutionError.unsafeInput("ephemeral inputs did not match the prepared plan")
            }
            return try executePrepared(request, prepared: prepared)
        }
        let report = try workflowExecutor.execute(
            workflow,
            ephemeralInputs: suppliedInputs
        )
        logger.record(event: "workflow_succeeded", metadata: ["workflow": workflow.id])
        var result = try JSONValue.fromEncodable(report).objectValue ?? [:]
        result["workflow_id"] = .string(workflow.id)
        result["plan_digest"] = .string(ApprovalStore.digest(workflow, ephemeralInputs: suppliedInputs))
        return try success(
            request,
            result: result,
            evidence: report.evidence
        )
    }

    private func approve(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let token = try requiredString(request, key: "token")
        let prepared = try approvalStore.approve(token: token)
        return try executePrepared(request, prepared: prepared)
    }

    private func executePrepared(_ request: RequestEnvelope, prepared: PreparedApproval) throws -> ResponseEnvelope {
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
        let report = try workflowExecutor.execute(
            prepared.workflow,
            ephemeralInputs: prepared.ephemeralInputs
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
        return try success(
            request,
            operationID: prepared.record.operationID,
            result: result,
            evidence: report.evidence
        )
    }

    private func deny(_ request: RequestEnvelope) throws -> ResponseEnvelope {
        let token = try requiredString(request, key: "token")
        let record = try approvalStore.deny(token: token)
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
        var warnings = permissions
            .filter { $0.state == "missing" || $0.state == "unknown" }
            .map { "\($0.name) permission is missing" }
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
            launchAgent: launchAgentManager.status()
        )
    }

    private func capabilityReport() -> CapabilityReport {
        CapabilityReport(
            capabilities: [
                "app.list", "app.open", "launchApp", "activateWindow", "click", "type", "key",
                "scroll", "waitFor", "capture", "ocr", "assert", "workflow.prepare", "workflow.run",
                "approval.approve", "approval.deny", "iphoneMirroring"
            ],
            optionalBackends: ["AppleScript/JXA", "shortcuts", "devicectl developer-device diagnostics"],
            permissionGates: ["Accessibility", "Input Monitoring", "Post Events", "Screen Recording", "Automation"],
            safety: [
                "sensitive workflows require a short-lived single-use approval token",
                "raw coordinates require an explicit coordinate_mode=raw marker",
                "screenshots and OCR frames are discarded after an operation",
                "no TCP or network listener is created"
            ]
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
            launchAgent: launchAgentManager.status()
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

    private func recordReceipt(
        for request: RequestEnvelope,
        response: ResponseEnvelope,
        startedAt: Date
    ) {
        let workflowID = request.params["workflow"]?.stringValue
            ?? response.result["workflow_id"]?.stringValue
            ?? response.result["workflow"]?.stringValue
        let workflow = workflowID.flatMap { workflowRegistry.workflow(id: $0) }
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
        } else {
            approvalState = "not_required"
        }
        let verificationResult: String
        if response.evidence.contains(where: { $0.kind == "assertion" }) {
            verificationResult = "passed"
        } else if response.status == .blocked || response.status == .failed {
            verificationResult = "blocked"
        } else {
            verificationResult = "not_required"
        }
        let receipt = OperationReceipt(
            operationID: response.operationID,
            requestID: response.requestID,
            method: request.method,
            source: request.params["source"]?.stringValue,
            workflowID: workflowID,
            targetSurface: workflow?.surface,
            risk: workflow.map { workflowRegistry.validate($0).risk },
            approvalState: approvalState,
            executionResult: response.status.rawValue,
            verificationResult: verificationResult,
            planDigest: response.result["plan_digest"]?.stringValue,
            runtimeIdentity: .current(),
            permissionContext: permissionContext,
            permissions: permissions,
            status: response.status,
            errorCode: response.error?.code,
            evidence: response.evidence.map { ReceiptEvidence(kind: $0.kind, source: $0.source) },
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
        details: [String: JSONValue] = [:]
    ) -> ResponseEnvelope {
        ResponseEnvelope(
            requestID: request.requestID,
            status: status,
            error: MacCtlError(code: code.rawValue, message: message, details: details)
        )
    }

    private func errorResponse(_ request: RequestEnvelope, error: Error) -> ResponseEnvelope {
        let status: OperationStatus
        let code: MacCtlErrorCode
        switch error {
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
        case is IPhoneMirroringError:
            status = .blocked
            code = .operationFailed
        case let error as ApprovalStoreError:
            status = .blocked
            switch error {
            case .notFound: code = .approvalNotFound
            case .expired: code = .approvalExpired
            case .alreadyUsed: code = .approvalAlreadyUsed
            }
        case let error as WorkflowExecutionError:
            status = .blocked
            if case .unsafeInput = error {
                code = .unsafeInput
            } else {
                code = .operationFailed
            }
        default:
            status = .failed
            code = .operationFailed
        }
        return failure(request, status: status, code: code, message: error.localizedDescription)
    }
}
