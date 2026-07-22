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

public enum MacCtlDaemonBundle {
    public static let bundleIdentifier = "com.jakyeamos.macctl.daemon"
    public static let executableName = "macctld"

    public static var infoPlist: [String: Any] {
        [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": "macctld",
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "macctld",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "13.0",
            "LSUIElement": true,
            "NSHighResolutionCapable": true
        ]
    }
}

public enum LaunchAgentError: Error, LocalizedError {
    case daemonExecutableMissing
    case launchctlFailed(String)
    case installFailed(String)
    case signingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .daemonExecutableMissing:
            return "The macctld executable could not be located beside macctl or in the installed daemon bundle"
        case .launchctlFailed(let message):
            return "launchctl failed: \(message)"
        case .installFailed(let message):
            return "Could not install macctl: \(message)"
        case .signingFailed(let message):
            return "Could not sign the macctld app bundle: \(message)"
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
        let destinationDirectory = MacCtlPaths.userLocalBinDirectory
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let commandDestination = destinationDirectory.appendingPathComponent("macctl")
        if fileManager.fileExists(atPath: commandDestination.path) {
            try fileManager.removeItem(at: commandDestination)
        }
        try fileManager.copyItem(at: source, to: commandDestination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandDestination.path)

        let daemonBundleURL = try installDaemonBundle(from: daemonSource)
        if fileManager.fileExists(atPath: MacCtlPaths.legacyDaemonExecutableURL.path) {
            try fileManager.removeItem(at: MacCtlPaths.legacyDaemonExecutableURL)
        }
        return [commandDestination.path, daemonBundleURL.path, MacCtlPaths.daemonAppExecutableURL.path]
    }

    public static func installedDaemonExecutablePath() -> String? {
        let path = MacCtlPaths.daemonAppExecutableURL.path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    public static func siblingDaemonPath(for commandPath: String) -> String? {
        let sibling = URL(fileURLWithPath: commandPath)
            .standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("macctld")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling.path : nil
    }

    private func installDaemonBundle(from source: URL) throws -> URL {
        let fileManager = self.fileManager
        let parent = MacCtlPaths.daemonDataDirectory
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)

        let stagingURL = parent.appendingPathComponent(".macctld.app.\(UUID().uuidString)", isDirectory: true)
        defer {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
        }
        let contentsURL = stagingURL.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectoryURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try fileManager.createDirectory(
            at: executableDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let executableURL = executableDirectoryURL.appendingPathComponent(MacCtlDaemonBundle.executableName)
        try fileManager.copyItem(at: source, to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let infoData: Data
        do {
            infoData = try PropertyListSerialization.data(
                fromPropertyList: MacCtlDaemonBundle.infoPlist,
                format: .xml,
                options: 0
            )
        } catch {
            throw LaunchAgentError.installFailed("could not create the daemon Info.plist: \(error.localizedDescription)")
        }
        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        do {
            try infoData.write(to: infoURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: infoURL.path)
        } catch {
            throw LaunchAgentError.installFailed("could not write the daemon Info.plist: \(error.localizedDescription)")
        }

        do {
            let signingResult = try ProcessRunner.run(
                executable: "/usr/bin/codesign",
                arguments: ["--force", "--deep", "--sign", "-", stagingURL.path],
                timeout: 30
            )
            guard signingResult.status == 0 else {
                let message = signingResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw LaunchAgentError.signingFailed(message.isEmpty ? "codesign exited with status \(signingResult.status)" : message)
            }
        } catch let error as LaunchAgentError {
            throw error
        } catch {
            throw LaunchAgentError.signingFailed(error.localizedDescription)
        }

        if fileManager.fileExists(atPath: MacCtlPaths.daemonAppURL.path) {
            try fileManager.removeItem(at: MacCtlPaths.daemonAppURL)
        }
        try fileManager.moveItem(at: stagingURL, to: MacCtlPaths.daemonAppURL)
        return MacCtlPaths.daemonAppURL
    }
}
