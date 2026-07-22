import Foundation

public struct ProcessResult: Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessRunner {
    public static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 10
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            process.terminate()
            throw NSError(
                domain: "MacCtlProcess",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Process timed out: \(executable)"]
            )
        }
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

public enum LaunchAgentError: Error, LocalizedError {
    case daemonExecutableMissing
    case launchctlFailed(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .daemonExecutableMissing:
            return "The macctld executable could not be located beside macctl"
        case .launchctlFailed(let message):
            return "launchctl failed: \(message)"
        case .installFailed(let message):
            return "Could not install macctl: \(message)"
        }
    }
}

public struct LaunchAgentStatus: Codable, Equatable {
    public let plistPath: String
    public let installed: Bool
    public let loaded: Bool

    public init(plistPath: String, installed: Bool, loaded: Bool) {
        self.plistPath = plistPath
        self.installed = installed
        self.loaded = loaded
    }
}

public final class LaunchAgentManager {
    private let fileManager = FileManager.default

    public init() {}

    public func install(daemonExecutable: String) throws -> LaunchAgentStatus {
        guard fileManager.isExecutableFile(atPath: daemonExecutable) else {
            throw LaunchAgentError.daemonExecutableMissing
        }
        try MacCtlPaths.ensureDirectories()
        try fileManager.createDirectory(
            at: MacCtlPaths.launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let dictionary: [String: Any] = [
            "Label": MacCtlPaths.launchAgentLabel,
            "ProgramArguments": [daemonExecutable],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": MacCtlPaths.logURL.path,
            "StandardErrorPath": MacCtlPaths.logURL.path
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
        do {
            try data.write(to: MacCtlPaths.launchAgentURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: MacCtlPaths.launchAgentURL.path
            )
        } catch {
            throw LaunchAgentError.installFailed(error.localizedDescription)
        }
        let domain = "gui/\(getuid())"
        _ = try? ProcessRunner.run(
            executable: "/bin/launchctl",
            arguments: ["bootout", domain, MacCtlPaths.launchAgentLabel]
        )
        let result = try ProcessRunner.run(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", domain, MacCtlPaths.launchAgentURL.path]
        )
        if result.status != 0 {
            let currentStatus = status()
            guard currentStatus.loaded else {
                throw LaunchAgentError.launchctlFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return currentStatus
        }
        return status()
    }

    public func remove() throws -> LaunchAgentStatus {
        let domain = "gui/\(getuid())"
        _ = try? ProcessRunner.run(
            executable: "/bin/launchctl",
            arguments: ["bootout", domain, MacCtlPaths.launchAgentLabel]
        )
        if fileManager.fileExists(atPath: MacCtlPaths.launchAgentURL.path) {
            try fileManager.removeItem(at: MacCtlPaths.launchAgentURL)
        }
        return status()
    }

    public func restart() throws -> LaunchAgentStatus {
        let domain = "gui/\(getuid())"
        let result = try ProcessRunner.run(
            executable: "/bin/launchctl",
            arguments: ["kickstart", "-k", "\(domain)/\(MacCtlPaths.launchAgentLabel)"]
        )
        guard result.status == 0 else {
            throw LaunchAgentError.launchctlFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return status()
    }

    public func status() -> LaunchAgentStatus {
        let domain = "gui/\(getuid())"
        let loaded = (try? ProcessRunner.run(
            executable: "/bin/launchctl",
            arguments: ["print", "\(domain)/\(MacCtlPaths.launchAgentLabel)"]
        ).status == 0) ?? false
        return LaunchAgentStatus(
            plistPath: MacCtlPaths.launchAgentURL.path,
            installed: fileManager.fileExists(atPath: MacCtlPaths.launchAgentURL.path),
            loaded: loaded
        )
    }

    public func installUserBinaries(from commandPath: String) throws -> [String] {
        let source = URL(fileURLWithPath: commandPath).standardizedFileURL
        let sourceDirectory = source.deletingLastPathComponent()
        let daemonSource = sourceDirectory.appendingPathComponent("macctld")
        guard fileManager.isExecutableFile(atPath: source.path),
              fileManager.isExecutableFile(atPath: daemonSource.path) else {
            throw LaunchAgentError.daemonExecutableMissing
        }
        let destinationDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destinations = [
            (source, destinationDirectory.appendingPathComponent("macctl")),
            (daemonSource, destinationDirectory.appendingPathComponent("macctld"))
        ]
        for (sourceURL, destinationURL) in destinations {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
        }
        return destinations.map { $0.1.path }
    }

    public static func siblingDaemonPath(for commandPath: String) -> String? {
        let sibling = URL(fileURLWithPath: commandPath)
            .standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("macctld")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling.path : nil
    }
}
