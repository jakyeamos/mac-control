import Foundation

public enum ReleaseCheckState: String, Codable, Equatable {
    case passed
    case failed
    case blocked
}

public struct ReleaseGateCheck: Codable, Equatable {
    public let id: String
    public let state: ReleaseCheckState
    public let message: String
    public let details: [String: JSONValue]

    public init(
        id: String,
        state: ReleaseCheckState,
        message: String,
        details: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.state = state
        self.message = message
        self.details = details
    }
}

public struct ReleaseGateReport: Codable, Equatable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let passed: Bool
    public let checks: [ReleaseGateCheck]
    public let blockerCount: Int

    public init(
        generatedAt: Date,
        passed: Bool,
        checks: [ReleaseGateCheck],
        blockerCount: Int,
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.passed = passed
        self.checks = checks
        self.blockerCount = blockerCount
    }
}

public struct ReleaseGateSnapshot {
    public let launchAgent: LaunchAgentStatus
    public let daemonStatus: DaemonStatus?
    public let doctorReport: DoctorReport?
    public let capabilityReport: CapabilityReport?
    public let keyboardAccessStatus: KeyboardAccessStatus?
    public let taskCapabilities: TaskCapabilityReport?
    public let checkpointStoreStatus: TaskCheckpointStoreStatus?
    public let receiptStoreStatus: ReceiptStoreStatus?
    public let receipts: [OperationReceipt]
    public let socketExists: Bool
    public let socketOwnerOnly: Bool
    public let networkListenerConfigured: Bool
    public let daemonError: String?

    public init(
        launchAgent: LaunchAgentStatus,
        daemonStatus: DaemonStatus?,
        doctorReport: DoctorReport?,
        capabilityReport: CapabilityReport? = nil,
        receiptStoreStatus: ReceiptStoreStatus?,
        receipts: [OperationReceipt],
        socketExists: Bool,
        socketOwnerOnly: Bool,
        networkListenerConfigured: Bool = false,
        daemonError: String?,
        keyboardAccessStatus: KeyboardAccessStatus? = nil,
        taskCapabilities: TaskCapabilityReport? = nil,
        checkpointStoreStatus: TaskCheckpointStoreStatus? = nil
    ) {
        self.launchAgent = launchAgent
        self.daemonStatus = daemonStatus
        self.doctorReport = doctorReport
        self.capabilityReport = capabilityReport
        self.keyboardAccessStatus = keyboardAccessStatus
        self.taskCapabilities = taskCapabilities ?? doctorReport?.taskCapabilities
        self.checkpointStoreStatus = checkpointStoreStatus ?? doctorReport?.checkpointStore
        self.receiptStoreStatus = receiptStoreStatus
        self.receipts = receipts
        self.socketExists = socketExists
        self.socketOwnerOnly = socketOwnerOnly
        self.networkListenerConfigured = networkListenerConfigured
        self.daemonError = daemonError
    }
}

public final class ReleaseGate {
    public static let requiredMacWorkflows = [
        "finder.open",
        "textedit.open",
        "system-settings.open",
        "chrome.open",
        "notes.open"
    ]

    private let maximumEvidenceAge: TimeInterval
    private let now: () -> Date

    public init(
        maximumEvidenceAge: TimeInterval = 86_400,
        now: @escaping () -> Date = Date.init
    ) {
        self.maximumEvidenceAge = max(0, maximumEvidenceAge)
        self.now = now
    }

    public func evaluate() -> ReleaseGateReport {
        evaluate(snapshot: collectSnapshot())
    }

    public func evaluate(snapshot: ReleaseGateSnapshot) -> ReleaseGateReport {
        let checks = [
            launchAgentCheck(snapshot.launchAgent),
            socketCheck(snapshot),
            localTransportCheck(snapshot),
            daemonIdentityCheck(snapshot),
            permissionCheck(snapshot),
            receiptStoreCheck(snapshot),
            macWorkflowCheck(snapshot),
            keyboardAccessCheck(snapshot),
            taskControlCheck(snapshot),
            shortcutCapabilityCheck(snapshot),
            agentContractCheck(snapshot),
            approvalSafetyCheck(snapshot)
        ]
        let passed = checks.allSatisfy { $0.state == .passed }
        let blockerCount = checks.reduce(into: 0) { count, check in
            if check.state != .passed { count += 1 }
        }
        return ReleaseGateReport(
            generatedAt: now(),
            passed: passed,
            checks: checks,
            blockerCount: blockerCount
        )
    }

    private func collectSnapshot() -> ReleaseGateSnapshot {
        let launchAgent = LaunchAgentManager().status()
        let socketExists = FileManager.default.fileExists(atPath: MacCtlPaths.socketURL.path)
        let socketOwnerOnly = MacCtlPaths.ownerOnlySocketPath()
        var doctorReport: DoctorReport?
        var keyboardAccessStatus: KeyboardAccessStatus?
        var daemonStatus: DaemonStatus?
        var capabilityReport: CapabilityReport?
        var daemonError: String?

        if socketExists && socketOwnerOnly {
            do {
                let client = UnixSocketClient()
                let doctorResponse = try client.send(RequestEnvelope(method: "doctor"))
                if doctorResponse.status == .succeeded {
                    do {
                        doctorReport = try decodeResult(DoctorReport.self, from: doctorResponse)
                    } catch {
                        daemonError = "doctor response decode failed: \(error.localizedDescription)"
                    }
                } else {
                    daemonError = doctorResponse.error?.message ?? "daemon doctor request was not successful"
                }
                let capabilitiesResponse = try client.send(RequestEnvelope(method: "capabilities"))
                if capabilitiesResponse.status == .succeeded {
                    do {
                        capabilityReport = try decodeResult(CapabilityReport.self, from: capabilitiesResponse)
                    } catch {
                        if daemonError == nil {
                            daemonError = "capabilities response decode failed: \(error.localizedDescription)"
                        }
                    }
                } else if daemonError == nil {
                    daemonError = capabilitiesResponse.error?.message ?? "daemon capabilities request was not successful"
                }
                let statusResponse = try client.send(RequestEnvelope(method: "status"))
                if statusResponse.status == .succeeded {
                    do {
                        daemonStatus = try decodeResult(DaemonStatus.self, from: statusResponse)
                    } catch {
                        if daemonError == nil {
                            daemonError = "status response decode failed: \(error.localizedDescription)"
                        }
                    }
                } else if daemonError == nil {
                    daemonError = statusResponse.error?.message ?? "daemon status request was not successful"
                }
                let keyboardResponse = try client.send(RequestEnvelope(method: "keyboard.status"))
                if keyboardResponse.status == .succeeded {
                    do {
                        keyboardAccessStatus = try decodeResult(
                            KeyboardAccessStatus.self,
                            from: keyboardResponse
                        )
                    } catch {
                        if daemonError == nil {
                            daemonError = "keyboard status response decode failed: \(error.localizedDescription)"
                        }
                    }
                } else if daemonError == nil {
                    daemonError = keyboardResponse.error?.message ?? "daemon keyboard status request was not successful"
                }
            } catch {
                daemonError = error.localizedDescription
            }
        } else if !socketExists {
            daemonError = "owner-only daemon socket is not present"
        } else {
            daemonError = "daemon socket is not owner-only"
        }

        let receiptStore = OperationReceiptStore()
        let receiptStoreStatus = receiptStore.status()
        let receipts = (try? receiptStore.list(limit: OperationReceiptStore.defaultMaximumRecords)) ?? []
        return ReleaseGateSnapshot(
            launchAgent: launchAgent,
            daemonStatus: daemonStatus,
            doctorReport: doctorReport,
            capabilityReport: capabilityReport,
            receiptStoreStatus: receiptStoreStatus,
            receipts: receipts,
            socketExists: socketExists,
            socketOwnerOnly: socketOwnerOnly,
            networkListenerConfigured: false,
            daemonError: daemonError,
            keyboardAccessStatus: keyboardAccessStatus,
            taskCapabilities: doctorReport?.taskCapabilities,
            checkpointStoreStatus: doctorReport?.checkpointStore
        )
    }

    private func launchAgentCheck(_ status: LaunchAgentStatus) -> ReleaseGateCheck {
        let configuredMatches = status.configuredExecutablePath == status.expectedExecutablePath
        let activeMatches = status.activeExecutablePath == status.expectedExecutablePath
        let identityMatches = status.identityMatches && configuredMatches && activeMatches
        let healthy = status.installed && status.launchdLoaded && status.loaded && status.healthy
            && identityMatches && status.spawnError == nil
            && (status.lastExitCode == nil || status.lastExitCode == 0)
        let state: ReleaseCheckState = healthy ? .passed : (status.launchdLoaded ? .failed : .blocked)
        return ReleaseGateCheck(
            id: "launchd.identity",
            state: state,
            message: healthy
                ? "LaunchAgent is running the packaged macctld.app executable"
                : status.summary,
            details: [
                "installed": .bool(status.installed),
                "launchd_loaded": .bool(status.launchdLoaded),
                "healthy": .bool(status.healthy),
                "configured_matches": .bool(configuredMatches),
                "active_matches": .bool(activeMatches),
                "identity_matches": .bool(identityMatches)
            ]
        )
    }

    private func socketCheck(_ snapshot: ReleaseGateSnapshot) -> ReleaseGateCheck {
        if !snapshot.socketExists {
            return ReleaseGateCheck(
                id: "daemon.socket",
                state: .blocked,
                message: "Daemon socket is not present",
                details: ["owner_only": .bool(false)]
            )
        }
        if !snapshot.socketOwnerOnly {
            return ReleaseGateCheck(
                id: "daemon.socket",
                state: .failed,
                message: "Daemon socket permissions are not 0600",
                details: ["owner_only": .bool(false)]
            )
        }
        if let daemonError = snapshot.daemonError {
            return ReleaseGateCheck(
                id: "daemon.socket",
                state: .blocked,
                message: "Owner-only socket exists but the daemon did not answer",
                details: ["owner_only": .bool(true), "error": .string(daemonError)]
            )
        }
        return ReleaseGateCheck(
            id: "daemon.socket",
            state: .passed,
            message: "Daemon answered through an owner-only Unix socket",
            details: ["owner_only": .bool(true)]
        )
    }

    private func daemonIdentityCheck(_ snapshot: ReleaseGateSnapshot) -> ReleaseGateCheck {
        guard let status = snapshot.daemonStatus else {
            return ReleaseGateCheck(
                id: "daemon.identity",
                state: .blocked,
                message: "Daemon runtime identity could not be read",
                details: [:]
            )
        }
        let identity = status.runtimeIdentity
        let executableMatches = identity.executablePath == MacCtlPaths.daemonAppExecutableURL.path
        let bundleMatches = identity.bundleIdentifier == MacCtlDaemonBundle.bundleIdentifier
        let contextMatches = status.runtimeContext == "daemon"
        let passed = executableMatches && bundleMatches && contextMatches
        return ReleaseGateCheck(
            id: "daemon.identity",
            state: passed ? .passed : .failed,
            message: passed
                ? "Daemon reports the packaged bundle identity"
                : "Daemon runtime identity does not match the packaged bundle",
            details: [
                "runtime_context_matches": .bool(contextMatches),
                "executable_matches": .bool(executableMatches),
                "bundle_matches": .bool(bundleMatches)
            ]
        )
    }

    private func localTransportCheck(_ snapshot: ReleaseGateSnapshot) -> ReleaseGateCheck {
        if snapshot.networkListenerConfigured {
            return ReleaseGateCheck(
                id: "transport.local_only",
                state: .failed,
                message: "A network listener is configured; macctl requires a local Unix socket",
                details: [
                    "network_listener_configured": .bool(true),
                    "socket_path": .string(MacCtlPaths.socketURL.path)
                ]
            )
        }
        return ReleaseGateCheck(
            id: "transport.local_only",
            state: .passed,
            message: "macctl uses an owner-only AF_UNIX socket and no network listener",
            details: [
                "network_listener_configured": .bool(false),
                "socket_path": .string(MacCtlPaths.socketURL.path)
            ]
        )
    }

    private func permissionCheck(_ snapshot: ReleaseGateSnapshot) -> ReleaseGateCheck {
        guard let report = snapshot.doctorReport else {
            return ReleaseGateCheck(
                id: "permissions.daemon",
                state: .blocked,
                message: "Daemon-authoritative permissions could not be evaluated",
                details: ["permission_context": .string("unknown")]
            )
        }
        guard report.permissionContext == "daemon" else {
            return ReleaseGateCheck(
                id: "permissions.daemon",
                state: .blocked,
                message: "Permission report is not daemon-authoritative",
                details: ["permission_context": .string(report.permissionContext)]
            )
        }
        let requiredNames = ["Accessibility", "Input Monitoring", "Post Events", "Screen Recording"]
        let states = Dictionary(uniqueKeysWithValues: report.permissions.map { ($0.name, $0.state) })
        let missing = requiredNames.filter { states[$0] == "missing" }
        let unknown = requiredNames.filter { states[$0] == nil || states[$0] == "unknown" }
        let unexpected = requiredNames.filter {
            guard let state = states[$0] else { return false }
            return state != "granted" && state != "missing" && state != "unknown"
        }
        if !missing.isEmpty {
            return ReleaseGateCheck(
                id: "permissions.daemon",
                state: .failed,
                message: "Required daemon permissions are missing",
                details: ["missing": .array(missing.map(JSONValue.string))]
            )
        }
        if !unknown.isEmpty {
            return ReleaseGateCheck(
                id: "permissions.daemon",
                state: .blocked,
                message: "Required daemon permissions are unknown",
                details: ["unknown": .array(unknown.map(JSONValue.string))]
            )
        }
        if !unexpected.isEmpty {
            return ReleaseGateCheck(
                id: "permissions.daemon",
                state: .failed,
                message: "Required daemon permissions have unsupported states",
                details: ["unsupported": .array(unexpected.map(JSONValue.string))]
            )
        }
        return ReleaseGateCheck(
            id: "permissions.daemon",
            state: .passed,
            message: "Required daemon permissions are confirmed",
            details: ["permission_context": .string("daemon")]
        )
    }

    private func receiptStoreCheck(_ snapshot: ReleaseGateSnapshot) -> ReleaseGateCheck {
        guard let status = snapshot.receiptStoreStatus else {
            return ReleaseGateCheck(
                id: "receipts.storage",
                state: .blocked,
                message: "Receipt store status is unavailable"
            )
        }
        let passed = status.writable
            && status.directoryOwnerOnly
            && status.filesOwnerOnly
            && status.pendingPrune == 0
            && status.invalidReceiptCount == 0
        return ReleaseGateCheck(
            id: "receipts.storage",
            state: passed ? .passed : .failed,
            message: passed
                ? "Receipts are writable, redacted, owner-only, and retention-compliant"
                : "Receipt storage is not release compliant",
            details: [
                "writable": .bool(status.writable),
                "directory_owner_only": .bool(status.directoryOwnerOnly),
                "files_owner_only": .bool(status.filesOwnerOnly),
                "pending_prune": .number(Double(status.pendingPrune)),
                "invalid_receipts": .number(Double(status.invalidReceiptCount))
            ]
        )
    }

    private func macWorkflowCheck(_ snapshot: ReleaseGateSnapshot) -> ReleaseGateCheck {
        let missing = Self.requiredMacWorkflows.filter { workflowID in
            !hasFreshSuccessfulReceipt(for: workflowID, in: snapshot.receipts)
        }
        return ReleaseGateCheck(
            id: "live.mac-workflows",
            state: missing.isEmpty ? .passed : .blocked,
            message: missing.isEmpty
                ? "Fresh Mac GUI workflow evidence is present"
                : "Fresh Mac GUI smoke evidence is missing",
            details: ["missing_workflows": .array(missing.map(JSONValue.string))]
        )
    }

    private func keyboardAccessCheck(_ snapshot: ReleaseGateSnapshot) -> ReleaseGateCheck {
        guard let status = snapshot.keyboardAccessStatus else {
            return ReleaseGateCheck(
                id: "live.keyboard-control",
                state: .blocked,
                message: "Full Keyboard Access status could not be read",
                details: ["missing": .array([.string("status")])]
            )
        }
        var missing: [String] = []
        if status.fullKeyboardAccessEnabled != true {
            missing.append("full_keyboard_access")
        }
        if !hasFreshReceipt(method: "keyboard.lease.acquire", evidenceKind: "keyboard_lease", in: snapshot.receipts) {
            missing.append("lease_acquisition")
        }
        if !hasFreshReceipt(
            method: "keyboard.navigate",
            evidenceKind: "keyboard_input",
            verificationResult: ControlVerificationState.passed.rawValue,
            in: snapshot.receipts
        ) {
            missing.append("named_navigation")
        }
        if !hasFreshReceipt(method: "keyboard.inspect", evidenceKind: "keyboard_focus", in: snapshot.receipts) {
            missing.append("focus_inspection")
        }
        let leaseEnded = hasFreshReceipt(
            method: "keyboard.lease.release",
            evidenceKind: "keyboard_lease",
            in: snapshot.receipts
        ) || snapshot.receipts.contains {
            $0.method == "keyboard.navigate"
                && $0.errorCode == MacCtlErrorCode.keyboardLeaseExpired.rawValue
                && isFresh($0)
        }
        if !leaseEnded {
            missing.append("lease_release_or_expiry")
        }
        let keyboardReceipts = snapshot.receipts.filter { $0.method.hasPrefix("keyboard.") }
        let receiptData = (try? JSONCodec.encode(keyboardReceipts)) ?? Data()
        let receiptText = String(decoding: receiptData, as: UTF8.self)
        let privateMarkers = ["raw_keys", "AXValue", "document_text", "private_text", "ocr_text", "lease_token"]
        if privateMarkers.contains(where: { receiptText.localizedCaseInsensitiveContains($0) }) {
            missing.append("redacted_receipts")
        }
        return ReleaseGateCheck(
            id: "live.keyboard-control",
            state: missing.isEmpty ? .passed : .blocked,
            message: missing.isEmpty
                ? "Full Keyboard Access, lease, navigation, focus, and release evidence is fresh"
                : "Keyboard-first GUI smoke evidence is missing",
            details: [
                "full_keyboard_access": .bool(status.fullKeyboardAccessEnabled == true),
                "missing": .array(missing.map(JSONValue.string)),
                "permission_context": .string(status.permissionContext)
            ]
        )
    }

    private func taskControlCheck(_ snapshot: ReleaseGateSnapshot) -> ReleaseGateCheck {
        var missing: [String] = []
        let requiredMethods = ["task.prepare", "task.run", "task.status", "task.resume", "task.cancel"]
        guard let capabilities = snapshot.taskCapabilities else {
            return ReleaseGateCheck(
                id: "task.control",
                state: .blocked,
                message: "Task-controller capabilities were not reported by the daemon",
                details: ["missing": .array([.string("capabilities")])]
            )
        }
        let methods = Set(capabilities.methods)
        missing.append(contentsOf: requiredMethods.filter { !methods.contains($0) })
        if capabilities.automaticResume {
            missing.append("automatic_resume_disabled")
        }
        if (snapshot.receipts.filter { $0.method == "adapter.capabilities" && isFresh($0) }).isEmpty {
            missing.append("adapter_capabilities")
        }
        guard let checkpoint = snapshot.checkpointStoreStatus else {
            missing.append("checkpoint_storage")
            return ReleaseGateCheck(
                id: "task.control",
                state: .blocked,
                message: "Task-controller release evidence is missing",
                details: ["missing": .array(missing.map(JSONValue.string))]
            )
        }
        if !checkpoint.writable || !checkpoint.directoryOwnerOnly || !checkpoint.filesOwnerOnly {
            missing.append("checkpoint_storage_permissions")
        }
        if checkpoint.pendingPrune != 0 || checkpoint.invalidCheckpointCount != 0 {
            missing.append("checkpoint_storage_health")
        }
        if !hasFreshTaskReceipt(
            method: "task.prepare",
            status: .prepared,
            state: "prepared",
            in: snapshot.receipts
        ) {
            missing.append("task_prepare")
        }
        if !hasFreshTaskReceipt(method: "task.run", state: "completed", in: snapshot.receipts)
            && !hasFreshTaskReceipt(method: "task.resume", state: "completed", in: snapshot.receipts) {
            missing.append("task_completion")
        }
        if !hasFreshReceipt(method: "task.status", evidenceKind: "task_checkpoint", in: snapshot.receipts) {
            missing.append("task_status")
        }
        if !hasFreshReceipt(method: "task.cancel", evidenceKind: "task_checkpoint", in: snapshot.receipts) {
            missing.append("task_cancel")
        }
        let taskReceipts = snapshot.receipts.filter { $0.method.hasPrefix("task.") }
        let receiptText = String(decoding: (try? JSONCodec.encode(taskReceipts)) ?? Data(), as: UTF8.self)
        let privateMarkers = [
            "raw_keys", "lease_token", "approval_token", "AXValue", "document_text", "private_text", "ocr_text"
        ]
        if privateMarkers.contains(where: { receiptText.localizedCaseInsensitiveContains($0) }) {
            missing.append("redacted_task_receipts")
        }
        return ReleaseGateCheck(
            id: "task.control",
            state: missing.isEmpty ? .passed : .blocked,
            message: missing.isEmpty
                ? "Task capabilities, checkpoint health, adapter diagnostics, and task smoke evidence are fresh"
                : "Task-controller release evidence is missing",
            details: [
                "missing": .array(missing.map(JSONValue.string)),
                "automatic_resume": .bool(capabilities.automaticResume),
                "checkpoint_writable": .bool(checkpoint.writable)
            ]
        )
    }

    private func shortcutCapabilityCheck(_ snapshot: ReleaseGateSnapshot) -> ReleaseGateCheck {
        guard let capabilities = snapshot.capabilityReport?.shortcutCapabilities else {
            return ReleaseGateCheck(
                id: "live.shortcut-control",
                state: .blocked,
                message: "Shortcut capability and binding-state evidence is unavailable",
                details: ["missing": .array([.string("capability_report")])]
            )
        }
        let requiredMethods = [
            "shortcut.audit", "shortcut.propose", "shortcut.inspect",
            "shortcut.setup", "shortcut.run", "shortcut.remove"
        ]
        var missing = requiredMethods.filter { !capabilities.methods.contains($0) }
        if !capabilities.ownerOnlyStorage { missing.append("owner_only_storage") }
        if capabilities.statusCounts[ShortcutStatus.behaviorVerified.rawValue, default: 0] == 0 {
            missing.append("behavior_verified_binding")
        }
        for route in ShortcutRunRoute.allCases {
            let hasEvidence = snapshot.receipts.contains {
                $0.method == "shortcut.run"
                    && $0.status == .succeeded
                    && $0.verificationResult == "passed"
                    && $0.route == route.rawValue
                    && $0.evidence.contains { $0.kind == "shortcut_behavior" }
                    && isFresh($0)
            }
            if !hasEvidence { missing.append("fresh_\(route.rawValue)_run") }
        }
        let counts = capabilities.statusCounts.mapValues { JSONValue.number(Double($0)) }
        return ReleaseGateCheck(
            id: "live.shortcut-control",
            state: missing.isEmpty ? .passed : .blocked,
            message: missing.isEmpty
                ? "Owner-only shortcut bindings and fresh verified Accessibility and keyboard routes are present"
                : "Shortcut capability or live route evidence is missing",
            details: [
                "missing": .array(missing.map(JSONValue.string)),
                "owner_only_storage": .bool(capabilities.ownerOnlyStorage),
                "status_counts": .object(counts)
            ]
        )
    }

    private func agentContractCheck(_ snapshot: ReleaseGateSnapshot) -> ReleaseGateCheck {
        guard let capabilities = snapshot.capabilityReport else {
            return ReleaseGateCheck(
                id: "agent.contract",
                state: .blocked,
                message: "The daemon did not report the provider-neutral agent contract",
                details: ["missing": .array([.string("capabilities")])]
            )
        }
        let requiredCapabilities = [
            "control.outcome",
            "control.batch",
            "control.capabilities",
            "control.capability_audit",
            "control.capability_audit_batch",
            "route.benchmark",
            "shortcut.audit",
            "shortcut.run"
        ]
        let requiredSafetyMarkers = [
            "route selection requires daemon-executed measurements; caller-supplied registrations are inventory-only",
            "control outcomes are provider-neutral and expose target, action, verification, and handoff state",
            "control.batch holds one bounded app lease, revalidates every step, and releases the lease on every exit path",
            "control.capability_audit performs a bounded read-only Accessibility/provider audit and persists only redacted identity descriptors; it never dispatches an action",
            "control.capability_audit_batch audits at most 24 explicit or catalog-selected apps, persists one redacted resumable receipt per app, serializes AX access, and never launches apps or dispatches actions",
            "shortcut bindings are owner-only, approval-bound by exact digest and operation, and promote to behavior_verified only after a declared postcondition passes",
            "shortcut commands dispatch at most once; indeterminate postconditions never trigger an automatic retry"
        ]
        let missingCapabilities = requiredCapabilities.filter { !capabilities.capabilities.contains($0) }
        let missingSafetyMarkers = requiredSafetyMarkers.filter { !capabilities.safety.contains($0) }
        let missing = missingCapabilities + missingSafetyMarkers
        return ReleaseGateCheck(
            id: "agent.contract",
            state: missing.isEmpty ? .passed : .blocked,
            message: missing.isEmpty
                ? "Agent-facing outcomes, provider handoff, bounded batching, and measured route provenance are exposed"
                : "Agent-facing control contract is incomplete",
            details: [
                "missing": .array(missing.map(JSONValue.string)),
                "capability_count": .number(Double(capabilities.capabilities.count)),
                "safety_marker_count": .number(Double(capabilities.safety.count))
            ]
        )
    }

    private func hasFreshTaskReceipt(
        method: String,
        status: OperationStatus = .succeeded,
        state: String,
        in receipts: [OperationReceipt]
    ) -> Bool {
        receipts.contains {
            $0.method == method
                && $0.status == status
                && $0.lifecycleState == state
                && $0.evidence.contains { $0.kind == "task_checkpoint" }
                && isFresh($0)
        }
    }

    private func approvalSafetyCheck(_ snapshot: ReleaseGateSnapshot) -> ReleaseGateCheck {
        let approvalWorkflow = "approval.smoke"
        let required: [(String, (OperationReceipt) -> Bool)] = [
            ("prepared", { receipt in
                receipt.method == "workflow.prepare"
                    && receipt.workflowID == approvalWorkflow
                    && receipt.status == .prepared
                    && receipt.approvalState == "prepared"
            }),
            ("approved_by_hud", { receipt in
                receipt.method == "approval.approve"
                    && receipt.workflowID == approvalWorkflow
                    && receipt.source == "hud"
                    && receipt.status == .succeeded
                    && receipt.approvalState == "approved"
            }),
            ("denied_by_hud", { receipt in
                receipt.method == "approval.deny"
                    && receipt.workflowID == approvalWorkflow
                    && receipt.source == "hud"
                    && receipt.status == .succeeded
                    && receipt.approvalState == "denied"
            }),
            ("expired", { receipt in
                receipt.method == "approval.approve"
                    && receipt.workflowID == approvalWorkflow
                    && (receipt.source == "hud" || receipt.source == "cli" || receipt.source == nil)
                    && receipt.status == .blocked
                    && receipt.approvalState == "required"
                    && receipt.verificationResult == "blocked"
                    && receipt.errorCode == MacCtlErrorCode.approvalExpired.rawValue
            }),
            ("fail_closed", { receipt in
                receipt.method == "workflow.run"
                    && receipt.workflowID == approvalWorkflow
                    && receipt.status == .blocked
                    && receipt.approvalState == "required"
                    && receipt.verificationResult == "blocked"
                    && receipt.errorCode == MacCtlErrorCode.approvalRequired.rawValue
            })
        ]
        let missing = required.compactMap { label, predicate in
            let found = snapshot.receipts.contains { predicate($0) && isFresh($0) }
            return found ? nil : label
        }
        return ReleaseGateCheck(
            id: "approval.safety",
            state: missing.isEmpty ? .passed : .blocked,
            message: missing.isEmpty
                ? "Approval HUD, denial, expiry, and fail-closed evidence is fresh"
                : "Approval safety evidence is missing",
            details: [
                "workflow": .string(approvalWorkflow),
                "missing": .array(missing.map(JSONValue.string))
            ]
        )
    }

    private func hasFreshSuccessfulReceipt(for workflowID: String, in receipts: [OperationReceipt]) -> Bool {
        receipts.contains {
            $0.workflowID == workflowID
                && $0.status == .succeeded
                && $0.verificationResult == "passed"
                && isFresh($0)
        }
    }

    private func hasFreshReceipt(
        method: String,
        evidenceKind: String,
        verificationResult: String? = nil,
        in receipts: [OperationReceipt]
    ) -> Bool {
        receipts.contains {
            $0.method == method
                && $0.status == .succeeded
                && (verificationResult == nil || $0.verificationResult == verificationResult)
                && $0.evidence.contains { $0.kind == evidenceKind }
                && isFresh($0)
        }
    }

    private func isFresh(_ receipt: OperationReceipt) -> Bool {
        receipt.completedAt >= now().addingTimeInterval(-maximumEvidenceAge)
    }

    private func decodeResult<T: Decodable>(_ type: T.Type, from response: ResponseEnvelope) throws -> T {
        try JSONCodec.decode(type, from: JSONCodec.encode(response.result))
    }
}
