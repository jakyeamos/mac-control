import Foundation

enum ReleaseEvidenceCatalog {
    static let requiredMacWorkflows = [
        "finder.open",
        "textedit.open",
        "system-settings.open",
        "chrome.open",
        "notes.open"
    ]

    static func keys(for receipt: OperationReceipt) -> [String] {
        var keys: [String] = []

        if let workflowID = receipt.workflowID,
           requiredMacWorkflows.contains(workflowID),
           receipt.status == .succeeded,
           receipt.verificationResult == "passed" {
            keys.append("workflow.\(workflowID)")
        }

        let evidenceKinds = Set(receipt.evidence.map(\.kind))
        switch receipt.method {
        case "keyboard.lease.acquire"
            where receipt.status == .succeeded && evidenceKinds.contains("keyboard_lease"):
            keys.append("keyboard.lease.acquire")
        case "keyboard.navigate"
            where receipt.status == .succeeded
                && receipt.verificationResult == ControlVerificationState.passed.rawValue
                && evidenceKinds.contains("keyboard_input"):
            keys.append("keyboard.navigate.passed")
        case "keyboard.inspect"
            where receipt.status == .succeeded && evidenceKinds.contains("keyboard_focus"):
            keys.append("keyboard.inspect")
        case "keyboard.lease.release"
            where receipt.status == .succeeded && evidenceKinds.contains("keyboard_lease"):
            keys.append("keyboard.lease.release")
        case "keyboard.navigate"
            where receipt.errorCode == MacCtlErrorCode.keyboardLeaseExpired.rawValue:
            keys.append("keyboard.navigate.expired")
        case "adapter.capabilities":
            keys.append("adapter.capabilities")
        case "task.prepare"
            where receipt.status == .prepared
                && receipt.lifecycleState == "prepared"
                && evidenceKinds.contains("task_checkpoint"):
            keys.append("task.prepare")
        case "task.run", "task.resume":
            if receipt.status == .succeeded,
               receipt.lifecycleState == "completed",
               evidenceKinds.contains("task_checkpoint") {
                keys.append("task.completion")
            }
        case "task.status"
            where receipt.status == .succeeded && evidenceKinds.contains("task_checkpoint"):
            keys.append("task.status")
        case "task.cancel"
            where receipt.status == .succeeded && evidenceKinds.contains("task_checkpoint"):
            keys.append("task.cancel")
        case "shortcut.run"
            where receipt.status == .succeeded
                && receipt.verificationResult == "passed"
                && evidenceKinds.contains("shortcut_behavior"):
            if let route = receipt.route, ShortcutRunRoute.allCases.map(\.rawValue).contains(route) {
                keys.append("shortcut.run.\(route)")
            }
        default:
            break
        }

        if receipt.workflowID == "approval.smoke" {
            switch receipt.method {
            case "workflow.prepare"
                where receipt.status == .prepared && receipt.approvalState == "prepared":
                keys.append("approval.prepared")
            case "approval.approve"
                where receipt.source == "control_center"
                    && receipt.status == .succeeded
                    && receipt.approvalState == "approved":
                keys.append("approval.approved")
            case "approval.deny"
                where receipt.source == "control_center"
                    && receipt.status == .succeeded
                    && receipt.approvalState == "denied":
                keys.append("approval.denied")
            case "approval.approve"
                where (receipt.source == "control_center" || receipt.source == "cli" || receipt.source == nil)
                    && receipt.status == .blocked
                    && receipt.approvalState == "required"
                    && receipt.verificationResult == "blocked"
                    && receipt.errorCode == MacCtlErrorCode.approvalExpired.rawValue:
                keys.append("approval.expired")
            case "workflow.run"
                where receipt.status == .blocked
                    && receipt.approvalState == "required"
                    && receipt.verificationResult == "blocked"
                    && receipt.errorCode == MacCtlErrorCode.approvalRequired.rawValue:
                keys.append("approval.fail_closed")
            default:
                break
            }
        }

        return Array(Set(keys)).sorted()
    }
}

struct ReleaseEvidenceArchiveStatus {
    let fileCount: Int
    let invalidReceiptCount: Int
    let writable: Bool
    let directoryOwnerOnly: Bool
    let filesOwnerOnly: Bool
}

final class ReleaseEvidenceArchive {
    static let maximumRecords = 24

    let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    func record(_ receipt: OperationReceipt) throws {
        for key in ReleaseEvidenceCatalog.keys(for: receipt) {
            let path = directory.appendingPathComponent("evidence-\(CapabilityProfileDigest.make(key)).json")
            if let data = try? Data(contentsOf: path),
               let existing = try? JSONCodec.decode(OperationReceipt.self, from: data),
               existing.completedAt > receipt.completedAt {
                continue
            }
            try OwnerOnlyFileStore.write(try JSONCodec.encode(receipt), to: path, fileManager: fileManager)
        }
    }

    func list() -> [OperationReceipt] {
        entries().compactMap { entry in
            guard let data = try? Data(contentsOf: entry.url) else { return nil }
            return try? JSONCodec.decode(OperationReceipt.self, from: data)
        }
        .sorted { $0.completedAt > $1.completedAt }
    }

    func status() -> ReleaseEvidenceArchiveStatus {
        guard fileManager.fileExists(atPath: directory.path) else {
            return ReleaseEvidenceArchiveStatus(
                fileCount: 0,
                invalidReceiptCount: 0,
                writable: true,
                directoryOwnerOnly: true,
                filesOwnerOnly: true
            )
        }
        let archiveEntries = entries()
        let invalidCount = archiveEntries.reduce(into: 0) { count, entry in
            guard let data = try? Data(contentsOf: entry.url),
                  (try? JSONCodec.decode(OperationReceipt.self, from: data)) != nil else {
                count += 1
                return
            }
        }
        return ReleaseEvidenceArchiveStatus(
            fileCount: archiveEntries.count,
            invalidReceiptCount: invalidCount,
            writable: fileManager.isWritableFile(atPath: directory.path),
            directoryOwnerOnly: ownerOnly(path: directory.path, expected: 0o700),
            filesOwnerOnly: archiveEntries.allSatisfy { ownerOnly(path: $0.url.path, expected: 0o600) }
        )
    }

    private func entries() -> [ReleaseEvidenceEntry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true ? ReleaseEvidenceEntry(url: url) : nil
        }
    }

    private func ownerOnly(path: String, expected: Int) -> Bool {
        guard let permissions = try? fileManager.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.intValue & 0o777 == expected
    }
}

private struct ReleaseEvidenceEntry {
    let url: URL
}
