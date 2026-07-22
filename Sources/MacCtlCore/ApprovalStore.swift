import CryptoKit
import Foundation

public enum ApprovalStoreError: Error, LocalizedError, Equatable {
    case notFound
    case expired
    case alreadyUsed

    public var errorDescription: String? {
        switch self {
        case .notFound: return "Approval token was not found"
        case .expired: return "Approval token has expired"
        case .alreadyUsed: return "Approval token was already used"
        }
    }
}

public struct PreparedApproval {
    public let record: ApprovalRecord
    public let workflow: WorkflowSpec
    public let ephemeralInputs: [String: String]
    public let planDigest: String

    public init(
        record: ApprovalRecord,
        workflow: WorkflowSpec,
        ephemeralInputs: [String: String] = [:],
        planDigest: String
    ) {
        self.record = record
        self.workflow = workflow
        self.ephemeralInputs = ephemeralInputs
        self.planDigest = planDigest
    }
}

public final class ApprovalStore {
    private struct Entry {
        let prepared: PreparedApproval
        var state: State
    }

    private enum State {
        case pending
        case approved
        case denied
        case expired
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let lifetime: TimeInterval

    public init(lifetime: TimeInterval = 120) {
        self.lifetime = lifetime
    }

    public func prepare(
        workflow: WorkflowSpec,
        ephemeralInputs: [String: String] = [:],
        operationID: String = UUID().uuidString
    ) -> PreparedApproval {
        let token = "mca_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let expiresAt = Date().addingTimeInterval(lifetime)
        let record = ApprovalRecord(
            token: token,
            operationID: operationID,
            workflowID: workflow.id,
            summary: workflow.summary,
            risk: ActionRiskClassifier.classify(workflow),
            focusPolicy: workflow.focusPolicy,
            expiresAt: expiresAt
        )
        let prepared = PreparedApproval(
            record: record,
            workflow: workflow,
            ephemeralInputs: ephemeralInputs,
            planDigest: Self.digest(workflow, ephemeralInputs: ephemeralInputs)
        )
        lock.lock()
        entries[token] = Entry(prepared: prepared, state: .pending)
        lock.unlock()
        return prepared
    }

    public func list() -> [ApprovalRecord] {
        lock.lock()
        defer { lock.unlock() }
        expireEntries(now: Date())
        return entries.values
            .filter { $0.state == .pending }
            .map { $0.prepared.record }
            .sorted { $0.expiresAt < $1.expiresAt }
    }

    public func record(for token: String) -> ApprovalRecord? {
        lock.lock()
        defer { lock.unlock() }
        return entries[token]?.prepared.record
    }

    public func approve(token: String) throws -> PreparedApproval {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[token] else { throw ApprovalStoreError.notFound }
        guard entry.state == .pending else {
            if entry.state == .expired { throw ApprovalStoreError.expired }
            throw ApprovalStoreError.alreadyUsed
        }
        guard entry.prepared.record.expiresAt > Date() else {
            entry.state = .expired
            entries[token] = entry
            throw ApprovalStoreError.expired
        }
        entry.state = .approved
        entries[token] = entry
        return entry.prepared
    }

    public func deny(token: String) throws -> ApprovalRecord {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[token] else { throw ApprovalStoreError.notFound }
        guard entry.state == .pending else {
            if entry.state == .expired { throw ApprovalStoreError.expired }
            throw ApprovalStoreError.alreadyUsed
        }
        guard entry.prepared.record.expiresAt > Date() else {
            entry.state = .expired
            entries[token] = entry
            throw ApprovalStoreError.expired
        }
        entry.state = .denied
        entries[token] = entry
        return entry.prepared.record
    }

    public static func digest(_ workflow: WorkflowSpec) -> String {
        digest(workflow, ephemeralInputs: [:])
    }

    public static func digest(
        _ workflow: WorkflowSpec,
        ephemeralInputs: [String: String]
    ) -> String {
        let payload = ApprovalDigestPayload(workflow: workflow, ephemeralInputs: ephemeralInputs)
        guard let data = try? JSONCodec.encode(payload) else { return "unavailable" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func expireEntries(now: Date) {
        for token in entries.keys {
            guard let entry = entries[token], entry.state == .pending else { continue }
            if entry.prepared.record.expiresAt <= now {
                entries[token] = Entry(prepared: entry.prepared, state: .expired)
            }
        }
    }
}
