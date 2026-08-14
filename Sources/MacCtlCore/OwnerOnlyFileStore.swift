import Darwin
import Foundation

/// Publishes small owner-only state files without ever exposing a partially
/// written or broadly readable destination. The temporary file is created in
/// the destination directory at 0600, synced, and atomically renamed.
enum OwnerOnlyFileStore {
    static func write(_ data: Data, to destination: URL, fileManager: FileManager = .default) throws {
        let directory = destination.deletingLastPathComponent()
        try ensureDirectory(directory, fileManager: fileManager)

        var template = Array(
            directory.appendingPathComponent(".macctl-write-XXXXXX").path.utf8CString
        )
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress)
        }
        guard descriptor >= 0 else {
            throw posixError("create owner-only temporary file")
        }

        let temporaryPath = String(cString: template)
        var descriptorOpen = true
        var published = false
        defer {
            if descriptorOpen { _ = Darwin.close(descriptor) }
            if !published { _ = Darwin.unlink(temporaryPath) }
        }

        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw posixError("set temporary file permissions")
        }
        try data.withUnsafeBytes { rawBuffer in
            guard var baseAddress = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, baseAddress, remaining)
                guard written >= 0 else {
                    if errno == EINTR { continue }
                    throw posixError("write owner-only temporary file")
                }
                remaining -= written
                baseAddress = baseAddress.advanced(by: written)
            }
        }
        guard fsync(descriptor) == 0 else {
            throw posixError("sync owner-only temporary file")
        }
        guard Darwin.close(descriptor) == 0 else {
            throw posixError("close owner-only temporary file")
        }
        descriptorOpen = false
        guard Darwin.rename(temporaryPath, destination.path) == 0 else {
            throw posixError("publish owner-only file")
        }
        published = true
    }

    static func withExclusiveDirectoryLock<T>(
        _ directory: URL,
        fileManager: FileManager = .default,
        _ body: () throws -> T
    ) throws -> T {
        try ensureDirectory(directory, fileManager: fileManager)
        let lockPath = directory.appendingPathComponent(".store.lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw posixError("open owner-only store lock")
        }
        defer { _ = Darwin.close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw posixError("set owner-only store lock permissions")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw posixError("lock owner-only store")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func ensureDirectory(_ directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func posixError(_ operation: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "Could not \(operation): \(String(cString: strerror(code)))"]
        )
    }
}
