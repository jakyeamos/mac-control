import Foundation

public struct ReceiptEvidence: Codable, Equatable {
    public let kind: String
    public let source: String?

    public init(kind: String, source: String?) {
        self.kind = kind
        self.source = source
    }
}

public struct OperationReceipt: Codable, Equatable {
    public let schemaVersion: Int
    public let operationID: String
    public let requestID: String
    public let method: String
    public let source: String?
    public let workflowID: String?
    public let targetSurface: SurfaceKind?
    public let focusPolicy: FocusPolicy?
    public let risk: RiskLevel?
    public let approvalState: String
    public let executionResult: String
    public let verificationResult: String
    public let planDigest: String?
    public let runtimeIdentity: RuntimeIdentity
    public let permissionContext: String
    public let permissions: [PermissionStatus]
    public let status: OperationStatus
    public let errorCode: String?
    public let evidence: [ReceiptEvidence]
    public let startedAt: Date
    public let completedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case operationID
        case requestID
        case method
        case source
        case workflowID
        case targetSurface
        case focusPolicy
        case risk
        case approvalState
        case executionResult
        case verificationResult
        case planDigest
        case runtimeIdentity
        case permissionContext
        case permissions
        case status
        case errorCode
        case evidence
        case startedAt
        case completedAt
    }

    public init(
        operationID: String,
        requestID: String,
        method: String,
        source: String? = nil,
        workflowID: String?,
        targetSurface: SurfaceKind?,
        focusPolicy: FocusPolicy? = nil,
        risk: RiskLevel?,
        approvalState: String = "not_required",
        executionResult: String = "not_run",
        verificationResult: String = "not_run",
        planDigest: String?,
        runtimeIdentity: RuntimeIdentity,
        permissionContext: String,
        permissions: [PermissionStatus],
        status: OperationStatus,
        errorCode: String?,
        evidence: [ReceiptEvidence],
        startedAt: Date,
        completedAt: Date,
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.requestID = requestID
        self.method = method
        self.source = source
        self.workflowID = workflowID
        self.targetSurface = targetSurface
        self.focusPolicy = focusPolicy
        self.risk = risk
        self.approvalState = approvalState
        self.executionResult = executionResult
        self.verificationResult = verificationResult
        self.planDigest = planDigest
        self.runtimeIdentity = runtimeIdentity
        self.permissionContext = permissionContext
        self.permissions = permissions
        self.status = status
        self.errorCode = errorCode
        self.evidence = evidence
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.operationID = try container.decode(String.self, forKey: .operationID)
        self.requestID = try container.decode(String.self, forKey: .requestID)
        self.method = try container.decode(String.self, forKey: .method)
        self.source = try container.decodeIfPresent(String.self, forKey: .source)
        self.workflowID = try container.decodeIfPresent(String.self, forKey: .workflowID)
        self.targetSurface = try container.decodeIfPresent(SurfaceKind.self, forKey: .targetSurface)
        self.focusPolicy = try container.decodeIfPresent(FocusPolicy.self, forKey: .focusPolicy)
        self.risk = try container.decodeIfPresent(RiskLevel.self, forKey: .risk)
        self.approvalState = try container.decodeIfPresent(String.self, forKey: .approvalState) ?? "not_required"
        self.executionResult = try container.decodeIfPresent(String.self, forKey: .executionResult) ?? "not_run"
        self.verificationResult = try container.decodeIfPresent(String.self, forKey: .verificationResult) ?? "not_run"
        self.planDigest = try container.decodeIfPresent(String.self, forKey: .planDigest)
        self.runtimeIdentity = try container.decode(RuntimeIdentity.self, forKey: .runtimeIdentity)
        self.permissionContext = try container.decodeIfPresent(String.self, forKey: .permissionContext) ?? "unknown"
        self.permissions = try container.decodeIfPresent([PermissionStatus].self, forKey: .permissions) ?? []
        self.status = try container.decode(OperationStatus.self, forKey: .status)
        self.errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        self.evidence = try container.decodeIfPresent([ReceiptEvidence].self, forKey: .evidence) ?? []
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.completedAt = try container.decode(Date.self, forKey: .completedAt)
    }
}

public struct ReceiptPruneResult: Codable, Equatable {
    public let prunedCount: Int
    public let remainingCount: Int
    public let maximumRecords: Int

    public init(prunedCount: Int, remainingCount: Int, maximumRecords: Int) {
        self.prunedCount = prunedCount
        self.remainingCount = remainingCount
        self.maximumRecords = maximumRecords
    }
}

public struct ReceiptStoreStatus: Codable, Equatable {
    public let directory: String
    public let fileCount: Int
    public let maximumRecords: Int
    public let pendingPrune: Int
    public let invalidReceiptCount: Int
    public let writable: Bool
    public let directoryOwnerOnly: Bool
    public let filesOwnerOnly: Bool
    public let oldestReceipt: Date?
    public let newestReceipt: Date?

    public init(
        directory: String,
        fileCount: Int,
        maximumRecords: Int,
        pendingPrune: Int,
        invalidReceiptCount: Int,
        writable: Bool,
        directoryOwnerOnly: Bool,
        filesOwnerOnly: Bool,
        oldestReceipt: Date?,
        newestReceipt: Date?
    ) {
        self.directory = directory
        self.fileCount = fileCount
        self.maximumRecords = maximumRecords
        self.pendingPrune = pendingPrune
        self.invalidReceiptCount = invalidReceiptCount
        self.writable = writable
        self.directoryOwnerOnly = directoryOwnerOnly
        self.filesOwnerOnly = filesOwnerOnly
        self.oldestReceipt = oldestReceipt
        self.newestReceipt = newestReceipt
    }

    public static func unavailable() -> ReceiptStoreStatus {
        ReceiptStoreStatus(
            directory: MacCtlPaths.receiptsDirectory.path,
            fileCount: 0,
            maximumRecords: OperationReceiptStore.defaultMaximumRecords,
            pendingPrune: 0,
            invalidReceiptCount: 0,
            writable: false,
            directoryOwnerOnly: false,
            filesOwnerOnly: false,
            oldestReceipt: nil,
            newestReceipt: nil
        )
    }
}

public enum ReceiptStoreError: Error, LocalizedError, Equatable {
    case invalidOperationID
    case directoryUnavailable(String)
    case writeFailed(String)
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOperationID:
            return "Operation receipt requires a non-empty operation ID"
        case .directoryUnavailable(let message):
            return "Receipt directory is unavailable: \(message)"
        case .writeFailed(let message):
            return "Operation receipt could not be written: \(message)"
        case .readFailed(let message):
            return "Operation receipts could not be read: \(message)"
        }
    }
}

public final class OperationReceiptStore {
    public static let defaultMaximumRecords = 1_000

    private let directory: URL
    private let maximumRecords: Int
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        directory: URL = MacCtlPaths.receiptsDirectory,
        maximumRecords: Int = OperationReceiptStore.defaultMaximumRecords,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.maximumRecords = max(1, maximumRecords)
        self.fileManager = fileManager
    }

    public func record(_ receipt: OperationReceipt) throws {
        guard !receipt.operationID.isEmpty else {
            throw ReceiptStoreError.invalidOperationID
        }
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory()
        let path = directory.appendingPathComponent(
            fileName(for: receipt.operationID, requestID: receipt.requestID)
        )
        do {
            let data = try JSONCodec.encode(receipt)
            try data.write(to: path, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            _ = try pruneLocked()
        } catch let error as ReceiptStoreError {
            throw error
        } catch {
            throw ReceiptStoreError.writeFailed(error.localizedDescription)
        }
    }

    public func list(limit: Int = 80) throws -> [OperationReceipt] {
        lock.lock()
        defer { lock.unlock() }
        let entries = try receiptEntries()
        return entries.compactMap { entry in
            guard let data = try? Data(contentsOf: entry.url),
                  let receipt = try? JSONCodec.decode(OperationReceipt.self, from: data) else {
                return nil
            }
            return receipt
        }
        .sorted { $0.completedAt > $1.completedAt }
        .prefix(max(0, limit))
        .map { $0 }
    }

    public func prune() throws -> ReceiptPruneResult {
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory()
        let result = try pruneLocked()
        let remaining = try receiptEntries().count
        return ReceiptPruneResult(
            prunedCount: result,
            remainingCount: remaining,
            maximumRecords: maximumRecords
        )
    }

    public func status() -> ReceiptStoreStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let entries = try? receiptEntries() else {
            return ReceiptStoreStatus(
                directory: directory.path,
                fileCount: 0,
                maximumRecords: maximumRecords,
                pendingPrune: 0,
                invalidReceiptCount: 0,
                writable: false,
                directoryOwnerOnly: false,
                filesOwnerOnly: false,
                oldestReceipt: nil,
                newestReceipt: nil
            )
        }
        let dates = entries.compactMap(\.modificationDate).sorted()
        let invalidCount = entries.reduce(into: 0) { count, entry in
            guard let data = try? Data(contentsOf: entry.url),
                  (try? JSONCodec.decode(OperationReceipt.self, from: data)) != nil else {
                count += 1
                return
            }
        }
        let directoryOwnerOnly = (try? fileManager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
            .map { ($0.intValue & 0o777) == 0o700 } ?? false
        let filesOwnerOnly = entries.allSatisfy { entry in
            guard let permissions = try? fileManager.attributesOfItem(atPath: entry.url.path)[.posixPermissions] as? NSNumber else {
                return false
            }
            return (permissions.intValue & 0o777) == 0o600
        }
        return ReceiptStoreStatus(
            directory: directory.path,
            fileCount: entries.count,
            maximumRecords: maximumRecords,
            pendingPrune: max(0, entries.count - maximumRecords),
            invalidReceiptCount: invalidCount,
            writable: fileManager.isWritableFile(atPath: directory.path),
            directoryOwnerOnly: directoryOwnerOnly,
            filesOwnerOnly: filesOwnerOnly,
            oldestReceipt: dates.first,
            newestReceipt: dates.last
        )
    }

    private func ensureDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw ReceiptStoreError.directoryUnavailable(error.localizedDescription)
        }
    }

    private func receiptEntries() throws -> [ReceiptEntry] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        do {
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { return nil }
                return ReceiptEntry(url: url, modificationDate: values?.contentModificationDate)
            }
            .sorted { $0.modificationDate ?? .distantPast > $1.modificationDate ?? .distantPast }
        } catch {
            throw ReceiptStoreError.readFailed(error.localizedDescription)
        }
    }

    private func pruneLocked() throws -> Int {
        let entries = try receiptEntries()
        guard entries.count > maximumRecords else { return 0 }
        var removed = 0
        for entry in entries.dropFirst(maximumRecords) {
            do {
                try fileManager.removeItem(at: entry.url)
                removed += 1
            } catch {
                throw ReceiptStoreError.writeFailed(error.localizedDescription)
            }
        }
        return removed
    }

    private func fileName(for operationID: String, requestID: String) -> String {
        let normalized = operationID.unicodeScalars.reduce(into: "") { value, scalar in
            let code = scalar.value
            let isAlphanumeric = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122)
            if isAlphanumeric || code == 45 || code == 95 {
                value.append(String(scalar))
            }
        }
        let normalizedRequest = requestID.unicodeScalars.reduce(into: "") { value, scalar in
            let code = scalar.value
            let isAlphanumeric = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122)
            if isAlphanumeric || code == 45 || code == 95 {
                value.append(String(scalar))
            }
        }
        let operationPart = normalized.isEmpty ? UUID().uuidString : normalized
        let requestPart = normalizedRequest.isEmpty ? UUID().uuidString : normalizedRequest
        return "receipt-\(operationPart)-\(requestPart).json"
    }
}

private struct ReceiptEntry {
    let url: URL
    let modificationDate: Date?
}
