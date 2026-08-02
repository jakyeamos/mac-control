import CryptoKit
import Foundation

public enum TaskCheckpointStoreError: Error, LocalizedError, Equatable {
    case invalidTaskID
    case directoryUnavailable(String)
    case writeFailed(String)
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTaskID: return "Task checkpoint requires a non-empty task ID"
        case .directoryUnavailable(let message): return "Task checkpoint directory is unavailable: \(message)"
        case .writeFailed(let message): return "Task checkpoint could not be written: \(message)"
        case .readFailed(let message): return "Task checkpoint could not be read: \(message)"
        }
    }
}

public struct TaskCheckpointStoreStatus: Codable, Equatable {
    public let directory: String
    public let fileCount: Int
    public let maximumCheckpoints: Int
    public let pendingPrune: Int
    public let invalidCheckpointCount: Int
    public let writable: Bool
    public let directoryOwnerOnly: Bool
    public let filesOwnerOnly: Bool
    public let oldestCheckpoint: Date?
    public let newestCheckpoint: Date?

    public init(
        directory: String,
        fileCount: Int,
        maximumCheckpoints: Int,
        pendingPrune: Int,
        invalidCheckpointCount: Int,
        writable: Bool,
        directoryOwnerOnly: Bool,
        filesOwnerOnly: Bool,
        oldestCheckpoint: Date?,
        newestCheckpoint: Date?
    ) {
        self.directory = directory
        self.fileCount = fileCount
        self.maximumCheckpoints = maximumCheckpoints
        self.pendingPrune = pendingPrune
        self.invalidCheckpointCount = invalidCheckpointCount
        self.writable = writable
        self.directoryOwnerOnly = directoryOwnerOnly
        self.filesOwnerOnly = filesOwnerOnly
        self.oldestCheckpoint = oldestCheckpoint
        self.newestCheckpoint = newestCheckpoint
    }

    public static func unavailable(directory: URL = MacCtlPaths.taskCheckpointsDirectory) -> TaskCheckpointStoreStatus {
        TaskCheckpointStoreStatus(
            directory: directory.path,
            fileCount: 0,
            maximumCheckpoints: TaskCheckpointStore.defaultMaximumCheckpoints,
            pendingPrune: 0,
            invalidCheckpointCount: 0,
            writable: false,
            directoryOwnerOnly: false,
            filesOwnerOnly: false,
            oldestCheckpoint: nil,
            newestCheckpoint: nil
        )
    }
}

/// Atomic, owner-only, retention-bounded storage for task state.  The file
/// name is a digest of the task ID so the directory does not become a task
/// inventory; the checkpoint body itself contains no selectors or private
/// output.
public final class TaskCheckpointStore {
    public static let defaultMaximumCheckpoints = 100

    private let directory: URL
    private let maximumCheckpoints: Int
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        directory: URL = MacCtlPaths.taskCheckpointsDirectory,
        maximumCheckpoints: Int = TaskCheckpointStore.defaultMaximumCheckpoints,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.maximumCheckpoints = max(1, maximumCheckpoints)
        self.fileManager = fileManager
    }

    public func save(_ checkpoint: TaskCheckpoint) throws {
        guard !checkpoint.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskCheckpointStoreError.invalidTaskID
        }
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectoryLocked()
        try requireOwnerOnlyReadLocked()
        let path = directory.appendingPathComponent(fileName(for: checkpoint.taskID))
        do {
            let data = try JSONCodec.encode(checkpoint)
            try data.write(to: path, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            try pruneLocked()
        } catch let error as TaskCheckpointStoreError {
            throw error
        } catch {
            throw TaskCheckpointStoreError.writeFailed(error.localizedDescription)
        }
    }

    public func load(taskID: String) throws -> TaskCheckpoint? {
        guard !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskCheckpointStoreError.invalidTaskID
        }
        lock.lock()
        defer { lock.unlock() }
        try requireOwnerOnlyReadLocked()
        let path = directory.appendingPathComponent(fileName(for: taskID))
        guard fileManager.fileExists(atPath: path.path) else { return nil }
        do {
            let data = try Data(contentsOf: path)
            return try JSONCodec.decode(TaskCheckpoint.self, from: data)
        } catch {
            throw TaskCheckpointStoreError.readFailed(error.localizedDescription)
        }
    }

    public func list() throws -> [TaskCheckpoint] {
        lock.lock()
        defer { lock.unlock() }
        try requireOwnerOnlyReadLocked()
        return try checkpointEntriesLocked().compactMap { entry in
            guard let data = try? Data(contentsOf: entry.url) else { return nil }
            return try? JSONCodec.decode(TaskCheckpoint.self, from: data)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(taskID: String) throws {
        guard !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskCheckpointStoreError.invalidTaskID
        }
        lock.lock()
        defer { lock.unlock() }
        try requireOwnerOnlyReadLocked()
        let path = directory.appendingPathComponent(fileName(for: taskID))
        guard fileManager.fileExists(atPath: path.path) else { return }
        do {
            try fileManager.removeItem(at: path)
        } catch {
            throw TaskCheckpointStoreError.writeFailed(error.localizedDescription)
        }
    }

    public func status() -> TaskCheckpointStoreStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let entries = try? checkpointEntriesLocked() else {
            return .unavailable(directory: directory)
        }
        let dates = entries.compactMap(\.modificationDate).sorted()
        let invalidCount = entries.reduce(into: 0) { count, entry in
            guard let data = try? Data(contentsOf: entry.url),
                  (try? JSONCodec.decode(TaskCheckpoint.self, from: data)) != nil else {
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
            return permissions.intValue & 0o777 == 0o600
        }
        let writable = fileManager.isWritableFile(atPath: directory.path)
        return TaskCheckpointStoreStatus(
            directory: directory.path,
            fileCount: entries.count,
            maximumCheckpoints: maximumCheckpoints,
            pendingPrune: max(0, entries.count - maximumCheckpoints),
            invalidCheckpointCount: invalidCount,
            writable: writable,
            directoryOwnerOnly: directoryOwnerOnly,
            filesOwnerOnly: filesOwnerOnly,
            oldestCheckpoint: dates.first,
            newestCheckpoint: dates.last
        )
    }

    private struct Entry {
        let url: URL
        let modificationDate: Date?
    }

    private func ensureDirectoryLocked() throws {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw TaskCheckpointStoreError.directoryUnavailable(error.localizedDescription)
        }
    }

    private func checkpointEntriesLocked() throws -> [Entry] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        do {
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).compactMap { url in
                guard url.pathExtension == "json" else { return nil }
                let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return Entry(url: url, modificationDate: date ?? nil)
            }
        } catch {
            throw TaskCheckpointStoreError.readFailed(error.localizedDescription)
        }
    }

    private func requireOwnerOnlyReadLocked() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        guard let directoryPermissions = permissions(for: directory), directoryPermissions == 0o700 else {
            throw TaskCheckpointStoreError.readFailed("insecure_directory_permissions")
        }
        for entry in try checkpointEntriesLocked() {
            guard let filePermissions = permissions(for: entry.url), filePermissions == 0o600 else {
                throw TaskCheckpointStoreError.readFailed("insecure_checkpoint_permissions")
            }
        }
    }

    private func permissions(for url: URL) -> Int? {
        guard let value = try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber else {
            return nil
        }
        return value.intValue & 0o777
    }

    private func pruneLocked() throws {
        let entries = try checkpointEntriesLocked().sorted {
            ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast)
        }
        guard entries.count > maximumCheckpoints else { return }
        for entry in entries.prefix(entries.count - maximumCheckpoints) {
            try fileManager.removeItem(at: entry.url)
        }
    }

    private func fileName(for taskID: String) -> String {
        let digest = SHA256.hash(data: Data(taskID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "task-\(digest).json"
    }
}
