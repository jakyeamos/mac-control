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
    case invalidDaemonIdentity(String)
    case launchctlFailed(String)
    case installFailed(String)
    case signingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .daemonExecutableMissing:
            return "The macctld executable could not be located beside macctl or in the installed daemon bundle"
        case .invalidDaemonIdentity(let path):
            return "The daemon must run from the packaged macctld.app identity: \(path)"
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
    public let expectedExecutablePath: String
    public let configuredExecutablePath: String?
    public let activeExecutablePath: String?
    public let installed: Bool
    public let launchdLoaded: Bool
    public let loaded: Bool
    public let healthy: Bool
    public let processID: Int32?
    public let jobState: String?
    public let lastExitCode: Int32?
    public let spawnError: String?
    public let identityMatches: Bool

    public init(
        plistPath: String,
        expectedExecutablePath: String = MacCtlPaths.daemonAppExecutableURL.path,
        configuredExecutablePath: String? = nil,
        activeExecutablePath: String? = nil,
        installed: Bool,
        launchdLoaded: Bool = false,
        loaded: Bool = false,
        healthy: Bool = false,
        processID: Int32? = nil,
        jobState: String? = nil,
        lastExitCode: Int32? = nil,
        spawnError: String? = nil,
        identityMatches: Bool = false
    ) {
        self.plistPath = plistPath
        self.expectedExecutablePath = expectedExecutablePath
        self.configuredExecutablePath = configuredExecutablePath
        self.activeExecutablePath = activeExecutablePath
        self.installed = installed
        self.launchdLoaded = launchdLoaded
        self.loaded = loaded
        self.healthy = healthy
        self.processID = processID
        self.jobState = jobState
        self.lastExitCode = lastExitCode
        self.spawnError = spawnError
        self.identityMatches = identityMatches
    }

    public static func unavailable() -> LaunchAgentStatus {
        LaunchAgentStatus(
            plistPath: MacCtlPaths.launchAgentURL.path,
            installed: FileManager.default.fileExists(atPath: MacCtlPaths.launchAgentURL.path)
        )
    }

    public var summary: String {
        var parts = ["launchd_loaded=\(launchdLoaded)", "healthy=\(healthy)"]
        if let configuredExecutablePath {
            parts.append("configured=\(configuredExecutablePath)")
        }
        if let activeExecutablePath {
            parts.append("active=\(activeExecutablePath)")
        }
        if let jobState {
            parts.append("state=\(jobState)")
        }
        if let lastExitCode {
            parts.append("last_exit_code=\(lastExitCode)")
        }
        if let spawnError {
            parts.append("spawn_error=\(spawnError)")
        }
        return parts.joined(separator: ", ")
    }
}

public final class LaunchAgentManager {
    private let fileManager = FileManager.default

    public init() {}

    public func install(daemonExecutable: String) throws -> LaunchAgentStatus {
        guard fileManager.isExecutableFile(atPath: daemonExecutable) else {
            throw LaunchAgentError.daemonExecutableMissing
        }
        let expectedPath = URL(fileURLWithPath: MacCtlPaths.daemonAppExecutableURL.path).standardizedFileURL.path
        let suppliedPath = URL(fileURLWithPath: daemonExecutable).standardizedFileURL.path
        guard suppliedPath == expectedPath else {
            throw LaunchAgentError.invalidDaemonIdentity(suppliedPath)
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
        return try reconcile()
    }

    public func remove() throws -> LaunchAgentStatus {
        let domain = "gui/\(getuid())"
        _ = try? ProcessRunner.run(
            executable: "/bin/launchctl",
            arguments: ["bootout", "\(domain)/\(MacCtlPaths.launchAgentLabel)"]
        )
        if fileManager.fileExists(atPath: MacCtlPaths.launchAgentURL.path) {
            try fileManager.removeItem(at: MacCtlPaths.launchAgentURL)
        }
        return status()
    }

    public func restart() throws -> LaunchAgentStatus {
        guard fileManager.fileExists(atPath: MacCtlPaths.launchAgentURL.path) else {
            throw LaunchAgentError.launchctlFailed("LaunchAgent plist is not installed")
        }
        return try reconcile()
    }

    public func status() -> LaunchAgentStatus {
        let configuredExecutablePath = configuredExecutablePath()
        let launchctlResult = try? ProcessRunner.run(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/\(getuid())/\(MacCtlPaths.launchAgentLabel)"]
        )
        return LaunchAgentStatus.fromLaunchctlOutput(
            plistPath: MacCtlPaths.launchAgentURL.path,
            installed: fileManager.fileExists(atPath: MacCtlPaths.launchAgentURL.path),
            configuredExecutablePath: configuredExecutablePath,
            expectedExecutablePath: MacCtlPaths.daemonAppExecutableURL.path,
            launchctlStatus: launchctlResult?.status ?? -1,
            output: launchctlResult?.stdout ?? "",
            stderr: launchctlResult?.stderr ?? ""
        )
    }

    private func reconcile() throws -> LaunchAgentStatus {
        let domain = "gui/\(getuid())"
        _ = try? ProcessRunner.run(
            executable: "/bin/launchctl",
            arguments: ["bootout", "\(domain)/\(MacCtlPaths.launchAgentLabel)"]
        )
        let result = try ProcessRunner.run(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", domain, MacCtlPaths.launchAgentURL.path]
        )
        guard result.status == 0 else {
            throw LaunchAgentError.launchctlFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var current = status()
        let deadline = Date().addingTimeInterval(3)
        while !current.loaded && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            current = status()
        }
        guard current.loaded else {
            throw LaunchAgentError.launchctlFailed(current.summary)
        }
        return current
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

        let signingIdentity: MacCtlCodeSigningIdentity
        do {
            signingIdentity = try MacCtlCodeSigning.resolve()
        } catch {
            throw LaunchAgentError.signingFailed(error.localizedDescription)
        }

        do {
            let signingResult = try ProcessRunner.run(
                executable: "/usr/bin/codesign",
                arguments: ["--force", "--deep", "--sign", signingIdentity.hash, stagingURL.path],
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

    private func configuredExecutablePath() -> String? {
        guard let data = try? Data(contentsOf: MacCtlPaths.launchAgentURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let dictionary = propertyList as? [String: Any],
              let arguments = dictionary["ProgramArguments"] as? [String] else {
            return nil
        }
        return arguments.first
    }
}

extension LaunchAgentStatus {
    public static func fromLaunchctlOutput(
        plistPath: String,
        installed: Bool,
        configuredExecutablePath: String?,
        expectedExecutablePath: String,
        launchctlStatus: Int32,
        output: String,
        stderr: String = ""
    ) -> LaunchAgentStatus {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let activeExecutablePath = value(for: "program", in: lines)
        let jobState = value(for: "state", in: lines)
        let processID = value(for: "pid", in: lines).flatMap(Int32.init)
        let lastExitRaw = value(for: "last exit code", in: lines)
        let lastExitCode = lastExitRaw.flatMap { raw in
            let code = raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? raw
            return Int32(code.trimmingCharacters(in: .whitespaces))
        }
        let normalizedExpected = URL(fileURLWithPath: expectedExecutablePath).standardizedFileURL.path
        let normalizedConfigured = configuredExecutablePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let normalizedActive = activeExecutablePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let identityMatches = normalizedConfigured == normalizedExpected && normalizedActive == normalizedExpected
        let lowerState = jobState?.lowercased() ?? ""
        let spawnError: String?
        if lowerState.contains("spawn failed") {
            spawnError = jobState
        } else if launchctlStatus != 0 && !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            spawnError = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            spawnError = nil
        }
        let launchdLoaded = launchctlStatus == 0
        let healthy = launchdLoaded
            && identityMatches
            && spawnError == nil
            && (lastExitCode == nil || lastExitCode == 0)
            && (processID != nil || lowerState == "running")
        return LaunchAgentStatus(
            plistPath: plistPath,
            expectedExecutablePath: expectedExecutablePath,
            configuredExecutablePath: configuredExecutablePath,
            activeExecutablePath: activeExecutablePath,
            installed: installed,
            launchdLoaded: launchdLoaded,
            loaded: healthy,
            healthy: healthy,
            processID: processID,
            jobState: jobState,
            lastExitCode: lastExitCode,
            spawnError: spawnError,
            identityMatches: identityMatches
        )
    }

    private static func value(for key: String, in lines: [String]) -> String? {
        let prefix = "\(key) = "
        return lines.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count).description
    }
}
