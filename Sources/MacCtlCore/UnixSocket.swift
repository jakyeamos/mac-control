import Foundation
import Darwin

public enum UnixSocketError: Error, LocalizedError, Equatable {
    case invalidPath
    case createFailed(String)
    case bindFailed(String)
    case listenFailed(String)
    case connectFailed(String)
    case acceptFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case socketPathIsNotSocket

    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "Unix socket path is too long or invalid"
        case .createFailed(let message):
            return "Could not create Unix socket: \(message)"
        case .bindFailed(let message):
            return "Could not bind Unix socket: \(message)"
        case .listenFailed(let message):
            return "Could not listen on Unix socket: \(message)"
        case .connectFailed(let message):
            return "Could not connect to macctld: \(message)"
        case .acceptFailed(let message):
            return "Could not accept Unix socket connection: \(message)"
        case .readFailed(let message):
            return "Could not read Unix socket request: \(message)"
        case .writeFailed(let message):
            return "Could not write Unix socket response: \(message)"
        case .socketPathIsNotSocket:
            return "Refusing to replace a non-socket at the configured socket path"
        }
    }
}

/// Identity observed from the local Unix socket. Callers cannot provide or
/// override these fields because they are collected after accept(2).
public struct UnixSocketPeerIdentity: Codable, Equatable {
    public let userID: UInt32?
    public let groupID: UInt32?
    public let processID: Int32?
    public let executablePath: String?
    public let signingIdentity: String?
    public let teamIdentifier: String?
    public let signatureValid: Bool?

    public init(
        userID: UInt32? = nil,
        groupID: UInt32? = nil,
        processID: Int32? = nil,
        executablePath: String? = nil,
        signingIdentity: String? = nil,
        teamIdentifier: String? = nil,
        signatureValid: Bool? = nil
    ) {
        self.userID = userID
        self.groupID = groupID
        self.processID = processID
        self.executablePath = executablePath
        self.signingIdentity = signingIdentity
        self.teamIdentifier = teamIdentifier
        self.signatureValid = signatureValid
    }

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case groupID = "group_id"
        case processID = "process_id"
        case executablePath = "executable_path"
        case signingIdentity = "signing_identity"
        case teamIdentifier = "team_identifier"
        case signatureValid = "signature_valid"
    }
}

private func errnoMessage() -> String {
    String(cString: strerror(errno))
}

private func makeUnixAddress(path: String) throws -> (sockaddr_un, socklen_t) {
    let pathBytes = Array(path.utf8) + [0]
    guard pathBytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
        throw UnixSocketError.invalidPath
    }
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        buffer.copyBytes(from: pathBytes)
    }
    return (address, socklen_t(MemoryLayout<sockaddr_un>.size))
}

private func withSockAddr<T>(
    _ address: inout sockaddr_un,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) rethrows -> T {
    try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            try body(rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

public final class UnixSocketClient {
    public init() {}

    public func send(_ request: RequestEnvelope, to path: String = MacCtlPaths.socketURL.path) throws -> ResponseEnvelope {
        let data = try JSONCodec.encode(request)
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw UnixSocketError.createFailed(errnoMessage())
        }
        defer { close(fileDescriptor) }

        var address = try makeUnixAddress(path: path).0
        let result = withSockAddr(&address) { pointer, length in
            connect(fileDescriptor, pointer, length)
        }
        guard result == 0 else {
            throw UnixSocketError.connectFailed(errnoMessage())
        }

        try writeAll(data, to: fileDescriptor)
        _ = shutdown(fileDescriptor, SHUT_WR)
        let responseData = try readAll(from: fileDescriptor)
        return try JSONCodec.decode(ResponseEnvelope.self, from: responseData)
    }
}

public final class UnixSocketServer {
    private let path: String
    private let queue = DispatchQueue(label: "com.jakyeamos.macctl.unix-socket", qos: .userInitiated)
    private let clientQueue = DispatchQueue(
        label: "com.jakyeamos.macctl.unix-socket.clients",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var fileDescriptor: Int32 = -1
    private var running = false

    public init(path: String = MacCtlPaths.socketURL.path) {
        self.path = path
    }

    deinit {
        stop()
    }

    public func start(handler: @escaping (Data) -> Data) throws {
        try startWithPeer { data, _ in handler(data) }
    }

    /// Starts the owner-only server while exposing daemon-observed peer
    /// identity to the request handler. The existing data-only overload stays
    /// available for compatibility with older tests and embedders.
    public func startWithPeer(handler: @escaping (Data, UnixSocketPeerIdentity) -> Data) throws {
        try MacCtlPaths.ensureDirectories()
        try removeStaleSocketIfNeeded()
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UnixSocketError.createFailed(errnoMessage())
        }
        var address = try makeUnixAddress(path: path).0
        let bindResult = withSockAddr(&address) { pointer, length in
            bind(descriptor, pointer, length)
        }
        guard bindResult == 0 else {
            close(descriptor)
            throw UnixSocketError.bindFailed(errnoMessage())
        }
        guard chmod(path, mode_t(0o600)) == 0 else {
            close(descriptor)
            unlink(path)
            throw UnixSocketError.bindFailed(errnoMessage())
        }
        guard listen(descriptor, 16) == 0 else {
            close(descriptor)
            unlink(path)
            throw UnixSocketError.listenFailed(errnoMessage())
        }
        fileDescriptor = descriptor
        running = true
        queue.async { [weak self] in
            self?.acceptLoopWithPeer(handler: handler)
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        if fileDescriptor >= 0 {
            shutdown(fileDescriptor, SHUT_RDWR)
            close(fileDescriptor)
            fileDescriptor = -1
        }
        if FileManager.default.fileExists(atPath: path) {
            unlink(path)
        }
    }

    private func acceptLoopWithPeer(handler: @escaping (Data, UnixSocketPeerIdentity) -> Data) {
        while running {
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    accept(fileDescriptor, rebound, &length)
                }
            }
            guard client >= 0 else {
                if running { SafeLog().record(event: "socket_accept_failed") }
                continue
            }
            // Keep accepting connections while a bounded task action is in
            // flight.  The service serializes ordinary mutations separately;
            // cancellation must still reach TaskRunner's cooperative flag.
            clientQueue.async { [weak self] in
                self?.handle(client: client, handler: handler)
            }
        }
    }

    private func handle(client: Int32, handler: (Data, UnixSocketPeerIdentity) -> Data) {
        defer { close(client) }
        do {
            let request = try readAll(from: client)
            let response = handler(request, peerIdentity(for: client))
            try writeAll(response, to: client)
        } catch {
            let fallback = ResponseEnvelope(
                requestID: UUID().uuidString,
                status: .failed,
                error: MacCtlError(
                    code: MacCtlErrorCode.operationFailed.rawValue,
                    message: error.localizedDescription
                )
            )
            if let data = try? JSONCodec.encode(fallback) {
                try? writeAll(data, to: client)
            }
        }
    }

    private func peerIdentity(for client: Int32) -> UnixSocketPeerIdentity {
        var userID: uid_t = 0
        var groupID: gid_t = 0
        let peerResult = getpeereid(client, &userID, &groupID)
        let observedUserID = peerResult == 0 ? UInt32(userID) : nil
        let observedGroupID = peerResult == 0 ? UInt32(groupID) : nil

        var processID: pid_t = 0
        var processLength = socklen_t(MemoryLayout<pid_t>.size)
        let processResult = withUnsafeMutablePointer(to: &processID) { pointer in
            getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, pointer, &processLength)
        }
        let observedProcessID = processResult == 0 && processID > 0 ? Int32(processID) : nil
        let executablePath = observedProcessID.flatMap(executablePath(for:))
        let signature = executablePath.map {
            MacCtlCodeSigning.inspect(bundleURL: URL(fileURLWithPath: $0))
        }
        return UnixSocketPeerIdentity(
            userID: observedUserID,
            groupID: observedGroupID,
            processID: observedProcessID,
            executablePath: executablePath,
            signingIdentity: signature?.identity,
            teamIdentifier: signature?.teamIdentifier,
            signatureValid: signature.map(\.valid)
        )
    }

    private func executablePath(for processID: Int32) -> String? {
        // The SDK exposes PROC_PIDPATHINFO_MAXSIZE as an unavailable macro to
        // Swift; this is the documented 4 * MAXPATHLEN upper bound.
        var buffer = [CChar](repeating: 0, count: 16_384)
        let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func removeStaleSocketIfNeeded() throws {
        var fileStatus = stat()
        guard lstat(path, &fileStatus) == 0 else {
            if errno == ENOENT { return }
            throw UnixSocketError.bindFailed(errnoMessage())
        }
        guard (fileStatus.st_mode & S_IFMT) == S_IFSOCK else {
            throw UnixSocketError.socketPathIsNotSocket
        }
        guard unlink(path) == 0 else {
            throw UnixSocketError.bindFailed(errnoMessage())
        }
    }
}

private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let written = write(fileDescriptor, baseAddress.advanced(by: offset), data.count - offset)
            guard written > 0 else {
                throw UnixSocketError.writeFailed(errnoMessage())
            }
            offset += written
        }
    }
}

private func readAll(from fileDescriptor: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = read(fileDescriptor, &buffer, buffer.count)
        if count == 0 { break }
        guard count > 0 else {
            throw UnixSocketError.readFailed(errnoMessage())
        }
        data.append(contentsOf: buffer.prefix(count))
        if data.count > 4 * 1024 * 1024 {
            throw UnixSocketError.readFailed("request exceeds 4 MiB limit")
        }
    }
    return data
}
