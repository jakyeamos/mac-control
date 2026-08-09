import Foundation

private struct ShortcutBindingRegistry: Codable {
    let schemaVersion: Int
    let bindings: [ShortcutBinding]
}

public final class ShortcutBindingStore {
    private let directory: URL
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        directory: URL = MacCtlPaths.shortcutBindingsDirectory,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("bindings.json")
        self.fileManager = fileManager
    }

    public func list() -> [ShortcutBinding] {
        lock.lock()
        defer { lock.unlock() }
        return (try? loadLocked())?.sorted { $0.id < $1.id } ?? []
    }

    public func binding(id: String) -> ShortcutBinding? {
        list().first { $0.id == id }
    }

    @discardableResult
    public func save(_ binding: ShortcutBinding) throws -> ShortcutBinding {
        try binding.target.validate()
        guard binding.schemaVersion == 1, !binding.id.isEmpty else {
            throw ShortcutError.persistence("unsupported schema or empty binding id")
        }
        lock.lock()
        defer { lock.unlock() }
        var bindings = try loadLocked()
        bindings.removeAll { $0.id == binding.id }
        bindings.append(binding)
        try persistLocked(bindings)
        return binding
    }

    @discardableResult
    public func remove(id: String) throws -> ShortcutBinding {
        lock.lock()
        defer { lock.unlock() }
        var bindings = try loadLocked()
        guard let index = bindings.firstIndex(where: { $0.id == id }) else {
            throw ShortcutError.bindingNotFound(id)
        }
        let removed = bindings.remove(at: index)
        try persistLocked(bindings)
        return removed
    }

    public func ownerOnly() -> Bool {
        guard let directoryAttributes = try? fileManager.attributesOfItem(atPath: directory.path),
              let directoryMode = directoryAttributes[.posixPermissions] as? NSNumber,
              directoryMode.intValue & 0o077 == 0 else { return false }
        guard fileManager.fileExists(atPath: fileURL.path) else { return true }
        guard let fileAttributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let fileMode = fileAttributes[.posixPermissions] as? NSNumber else { return false }
        return fileMode.intValue & 0o077 == 0
    }

    private func loadLocked() throws -> [ShortcutBinding] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let registry = try JSONCodec.decode(ShortcutBindingRegistry.self, from: data)
            guard registry.schemaVersion == 1 else {
                throw ShortcutError.persistence("unsupported registry schema")
            }
            return registry.bindings
        } catch let error as ShortcutError {
            throw error
        } catch {
            throw ShortcutError.persistence(error.localizedDescription)
        }
    }

    private func persistLocked(_ bindings: [ShortcutBinding]) throws {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONCodec.encode(ShortcutBindingRegistry(
                schemaVersion: 1,
                bindings: bindings.sorted { $0.id < $1.id }
            ))
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw ShortcutError.persistence(error.localizedDescription)
        }
    }
}
