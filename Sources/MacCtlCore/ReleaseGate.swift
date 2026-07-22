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
        receiptStoreStatus: ReceiptStoreStatus?,
        receipts: [OperationReceipt],
        socketExists: Bool,
        socketOwnerOnly: Bool,
        networkListenerConfigured: Bool = false,
        daemonError: String?
    ) {
        self.launchAgent = launchAgent
        self.daemonStatus = daemonStatus
        self.doctorReport = doctorReport
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
            iPhoneMirroringCheck(snapshot),
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
        var daemonStatus: DaemonStatus?
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
            receiptStoreStatus: receiptStoreStatus,
            receipts: receipts,
            socketExists: socketExists,
            socketOwnerOnly: socketOwnerOnly,
            networkListenerConfigured: false,
            daemonError: daemonError
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

    private func iPhoneMirroringCheck(_ snapshot: ReleaseGateSnapshot) -> ReleaseGateCheck {
        let candidates = snapshot.receipts.filter {
            $0.workflowID == "iphone.open-tinder"
                && $0.status == .succeeded
                && $0.verificationResult == "passed"
                && isFresh($0)
        }
        guard let receipt = candidates.first else {
            return ReleaseGateCheck(
                id: "live.iphone-mirroring",
                state: .blocked,
                message: "Fresh iPhone Mirroring Tinder evidence is missing",
                details: ["workflow": .string("iphone.open-tinder")]
            )
        }
        let evidenceKinds = Set(receipt.evidence.map(\.kind))
        let requiredKinds = Set(["ocr_anchor", "assertion"])
        let missingKinds = requiredKinds.subtracting(evidenceKinds).sorted()
        return ReleaseGateCheck(
            id: "live.iphone-mirroring",
            state: missingKinds.isEmpty ? .passed : .failed,
            message: missingKinds.isEmpty
                ? "Fresh Tinder foreground/visibility evidence is present"
                : "Tinder receipt is missing required verification evidence",
            details: ["missing_evidence": .array(missingKinds.map(JSONValue.string))]
        )
    }

    private func approvalSafetyCheck(_ snapshot: ReleaseGateSnapshot) -> ReleaseGateCheck {
        let required: [(String, String, OperationStatus, String)] = [
            ("workflow.prepare", "prepared", .prepared, "prepared"),
            ("approval.approve", "approved", .succeeded, "approved"),
            ("approval.deny", "denied", .succeeded, "denied"),
            ("workflow.run", "fail_closed", .blocked, "required")
        ]
        let missing = required.compactMap { method, label, status, approvalState in
            let found = snapshot.receipts.contains {
                $0.method == method
                    && $0.status == status
                    && $0.approvalState == approvalState
                    && isFresh($0)
            }
            return found ? nil : label
        }
        return ReleaseGateCheck(
            id: "approval.safety",
            state: missing.isEmpty ? .passed : .blocked,
            message: missing.isEmpty
                ? "Approval, denial, expiry/fail-closed evidence is fresh"
                : "Approval safety evidence is missing",
            details: ["missing": .array(missing.map(JSONValue.string))]
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

    private func isFresh(_ receipt: OperationReceipt) -> Bool {
        receipt.completedAt >= now().addingTimeInterval(-maximumEvidenceAge)
    }

    private func decodeResult<T: Decodable>(_ type: T.Type, from response: ResponseEnvelope) throws -> T {
        try JSONCodec.decode(type, from: JSONCodec.encode(response.result))
    }
}
