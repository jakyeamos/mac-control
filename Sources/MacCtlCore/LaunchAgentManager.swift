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
    case lifecycleBlocked(String)
    case lifecycleInterlockUnavailable(String)
    case registrationFailed(String, [String: JSONValue])

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
        case .lifecycleBlocked(let message):
            return "Daemon lifecycle change blocked: \(message)"
        case .lifecycleInterlockUnavailable(let message):
            return "Could not verify the daemon lifecycle interlock: \(message)"
        case .registrationFailed(let message, _):
            return "Daemon registration repair failed: \(message)"
        }
    }
}

public enum LaunchAgentRegistrationState: String, Codable, Equatable {
    case registered
    case missing
    case unavailable
}

public enum LaunchAgentEnsureAction: String, Codable, Equatable {
    case alreadyRegistered = "already_registered"
    case bootstrapped
}

/// Read-only evidence collected after an explicit LaunchAgent registration
/// repair. The daemon identity is taken from the owner-only status response;
/// callers cannot supply it as an assertion.
public struct DaemonRegistrationVerification: Codable, Equatable {
    public let installedRuntimeParity: InstalledRuntimeParityStatus
    public let socketExists: Bool
    public let socketOwnerOnly: Bool
    public let daemonProcessID: Int32?
    public let daemonRuntimeContext: String?
    public let daemonRuntimeIdentity: RuntimeIdentity?
    public let daemonIdentityMatches: Bool
    public let verified: Bool
    public let failureReasons: [String]

    public init(
        installedRuntimeParity: InstalledRuntimeParityStatus,
        socketExists: Bool,
        socketOwnerOnly: Bool,
        daemonProcessID: Int32? = nil,
        daemonRuntimeContext: String? = nil,
        daemonRuntimeIdentity: RuntimeIdentity? = nil,
        daemonIdentityMatches: Bool,
        verified: Bool,
        failureReasons: [String] = []
    ) {
        self.installedRuntimeParity = installedRuntimeParity
        self.socketExists = socketExists
        self.socketOwnerOnly = socketOwnerOnly
        self.daemonProcessID = daemonProcessID
        self.daemonRuntimeContext = daemonRuntimeContext
        self.daemonRuntimeIdentity = daemonRuntimeIdentity
        self.daemonIdentityMatches = daemonIdentityMatches
        self.verified = verified
        self.failureReasons = failureReasons
    }
}

public struct DaemonEnsureReport: Codable, Equatable {
    public let schemaVersion: String
    public let action: LaunchAgentEnsureAction
    public let repairAttempted: Bool
    public let before: LaunchAgentStatus
    public let after: LaunchAgentStatus
    public let verification: DaemonRegistrationVerification

    public init(
        action: LaunchAgentEnsureAction,
        repairAttempted: Bool,
        before: LaunchAgentStatus,
        after: LaunchAgentStatus,
        verification: DaemonRegistrationVerification,
        schemaVersion: String = "daemon-ensure/v1"
    ) {
        self.schemaVersion = schemaVersion
        self.action = action
        self.repairAttempted = repairAttempted
        self.before = before
        self.after = after
        self.verification = verification
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

    /// Distinguishes a launchctl observation that explicitly says the job is
    /// absent from an observation that could not be trusted. Repair may only
    /// bootstrap the former.
    public var registrationState: LaunchAgentRegistrationState {
        guard launchdLoaded == false else { return .registered }
        let diagnostic = (spawnError ?? "").lowercased()
        if diagnostic.contains("could not find service")
            || diagnostic.contains("service not found")
            || diagnostic.contains("no such process") {
            return .missing
        }
        return .unavailable
    }
}

internal struct LaunchAgentPaths: Equatable {
    let label: String
    let launchAgentURL: URL
    let expectedExecutableURL: URL
    let logURL: URL

    static let production = LaunchAgentPaths(
        label: MacCtlPaths.launchAgentLabel,
        launchAgentURL: MacCtlPaths.launchAgentURL,
        expectedExecutableURL: MacCtlPaths.daemonAppExecutableURL,
        logURL: MacCtlPaths.logURL
    )
}

public final class LaunchAgentManager {
    internal typealias ProcessExecutor = (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> ProcessResult
    internal typealias RuntimeVerifier = (_ expectedProcessID: Int32?, _ expectedExecutablePath: String) -> DaemonRegistrationVerification

    private let fileManager: FileManager
    private let lifecycleInterlock: DaemonLifecycleInterlock
    private let processRunner: ProcessExecutor
    private let runtimeVerifier: RuntimeVerifier
    private let paths: LaunchAgentPaths
    private let verificationTimeout: TimeInterval
    private let pollInterval: TimeInterval

    public init(lifecycleInterlock: DaemonLifecycleInterlock = DaemonLifecycleInterlock()) {
        self.fileManager = .default
        self.lifecycleInterlock = lifecycleInterlock
        self.processRunner = { executable, arguments, timeout in
            try ProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout)
        }
        self.runtimeVerifier = { expectedProcessID, expectedExecutablePath in
            LaunchAgentManager.liveRuntimeVerification(
                expectedProcessID: expectedProcessID,
                expectedExecutablePath: expectedExecutablePath
            )
        }
        self.paths = .production
        self.verificationTimeout = 3
        self.pollInterval = 0.1
    }

    internal init(
        lifecycleInterlock: DaemonLifecycleInterlock = DaemonLifecycleInterlock(),
        fileManager: FileManager = .default,
        processRunner: @escaping ProcessExecutor,
        runtimeVerifier: @escaping RuntimeVerifier,
        paths: LaunchAgentPaths,
        verificationTimeout: TimeInterval = 3,
        pollInterval: TimeInterval = 0.1
    ) {
        self.fileManager = fileManager
        self.lifecycleInterlock = lifecycleInterlock
        self.processRunner = processRunner
        self.runtimeVerifier = runtimeVerifier
        self.paths = paths
        self.verificationTimeout = verificationTimeout
        self.pollInterval = pollInterval
    }

    public func install(daemonExecutable: String) throws -> LaunchAgentStatus {
        guard fileManager.isExecutableFile(atPath: daemonExecutable) else {
            throw LaunchAgentError.daemonExecutableMissing
        }
        let expectedPath = paths.expectedExecutableURL.standardizedFileURL.path
        let suppliedPath = URL(fileURLWithPath: daemonExecutable).standardizedFileURL.path
        guard suppliedPath == expectedPath else {
            throw LaunchAgentError.invalidDaemonIdentity(suppliedPath)
        }
        _ = try lifecycleInterlock.prepare(operation: .install, launchAgentStatus: status())
        try MacCtlPaths.ensureDirectories()
        try fileManager.createDirectory(
            at: paths.launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let dictionary: [String: Any] = [
            "Label": paths.label,
            "ProgramArguments": [daemonExecutable],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": paths.logURL.path,
            "StandardErrorPath": paths.logURL.path
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
        do {
            try data.write(to: paths.launchAgentURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: paths.launchAgentURL.path
            )
        } catch {
            throw LaunchAgentError.installFailed(error.localizedDescription)
        }
        return try reconcile()
    }

    public func remove() throws -> LaunchAgentStatus {
        _ = try lifecycleInterlock.prepare(operation: .remove, launchAgentStatus: status())
        let domain = "gui/\(getuid())"
        _ = try? processRunner(
            "/bin/launchctl",
            ["bootout", "\(domain)/\(paths.label)"],
            10
        )
        if fileManager.fileExists(atPath: paths.launchAgentURL.path) {
            try fileManager.removeItem(at: paths.launchAgentURL)
        }
        return status()
    }

    public func restart() throws -> LaunchAgentStatus {
        guard fileManager.fileExists(atPath: paths.launchAgentURL.path) else {
            throw LaunchAgentError.launchctlFailed("LaunchAgent plist is not installed")
        }
        _ = try lifecycleInterlock.prepare(operation: .restart, launchAgentStatus: status())
        return try reconcile()
    }

    public func status() -> LaunchAgentStatus {
        let configuredExecutablePath = configuredExecutablePath()
        let launchctlResult = try? processRunner(
            "/bin/launchctl",
            ["print", "gui/\(getuid())/\(paths.label)"],
            10
        )
        return LaunchAgentStatus.fromLaunchctlOutput(
            plistPath: paths.launchAgentURL.path,
            installed: fileManager.fileExists(atPath: paths.launchAgentURL.path),
            configuredExecutablePath: configuredExecutablePath,
            expectedExecutablePath: paths.expectedExecutableURL.path,
            launchctlStatus: launchctlResult?.status ?? -1,
            output: launchctlResult?.stdout ?? "",
            stderr: launchctlResult?.stderr ?? ""
        )
    }

    /// Idempotently repairs only the split state where the LaunchAgent plist
    /// exists but launchd explicitly reports that the job is missing. A
    /// registered-but-unhealthy job is observed and reported; it is never
    /// booted out or retried by this command.
    public func ensure() throws -> DaemonEnsureReport {
        let before = status()
        switch before.registrationState {
        case .registered:
            let verification = runtimeVerifier(before.processID, before.expectedExecutablePath)
            let report = DaemonEnsureReport(
                action: .alreadyRegistered,
                repairAttempted: false,
                before: before,
                after: before,
                verification: verification
            )
            guard launchAgentReady(before), verification.verified else {
                throw registrationFailure(
                    "LaunchAgent is registered but its health or runtime identity could not be verified",
                    before: before,
                    after: before,
                    verification: verification,
                    repairAttempted: false
                )
            }
            return report

        case .unavailable:
            throw registrationFailure(
                "launchd did not explicitly report the job as missing; no bootstrap was attempted",
                before: before,
                repairAttempted: false
            )

        case .missing:
            guard before.installed else {
                throw registrationFailure(
                    "LaunchAgent plist is not installed; run macctl daemon install first",
                    before: before,
                    repairAttempted: false
                )
            }
            guard let configuredPath = before.configuredExecutablePath,
                  normalizedPath(configuredPath) == normalizedPath(before.expectedExecutablePath) else {
                throw registrationFailure(
                    "LaunchAgent plist does not point to the packaged daemon executable",
                    before: before,
                    repairAttempted: false
                )
            }
            guard fileManager.isExecutableFile(atPath: before.expectedExecutablePath) else {
                throw registrationFailure(
                    "The packaged daemon executable is missing or not executable",
                    before: before,
                    repairAttempted: false
                )
            }

            _ = try lifecycleInterlock.prepare(operation: .install, launchAgentStatus: before)
            let domain = "gui/\(getuid())"
            let bootstrapResult: ProcessResult
            do {
                bootstrapResult = try processRunner(
                    "/bin/launchctl",
                    ["bootstrap", domain, paths.launchAgentURL.path],
                    10
                )
            } catch {
                throw registrationFailure(
                    "launchctl bootstrap could not be started: \(error.localizedDescription)",
                    before: before,
                    repairAttempted: true
                )
            }
            guard bootstrapResult.status == 0 else {
                let diagnostic = bootstrapResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw registrationFailure(
                    diagnostic.isEmpty
                        ? "launchctl bootstrap exited with status \(bootstrapResult.status)"
                        : diagnostic,
                    before: before,
                    repairAttempted: true
                )
            }

            let (after, verification) = waitForBootstrappedVerification()
            let report = DaemonEnsureReport(
                action: .bootstrapped,
                repairAttempted: true,
                before: before,
                after: after,
                verification: verification
            )
            guard launchAgentReady(after), verification.verified else {
                throw registrationFailure(
                    "bootstrap completed but the LaunchAgent postcondition was not verified",
                    before: before,
                    after: after,
                    verification: verification,
                    repairAttempted: true
                )
            }
            return report
        }
    }

    private func reconcile() throws -> LaunchAgentStatus {
        let domain = "gui/\(getuid())"
        _ = try? processRunner(
            "/bin/launchctl",
            ["bootout", "\(domain)/\(paths.label)"],
            10
        )
        let result = try processRunner(
            "/bin/launchctl",
            ["bootstrap", domain, paths.launchAgentURL.path],
            10
        )
        guard result.status == 0 else {
            throw LaunchAgentError.launchctlFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var current = status()
        let deadline = Date().addingTimeInterval(verificationTimeout)
        while !current.loaded && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
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
        _ = try lifecycleInterlock.prepare(operation: .upgrade, launchAgentStatus: status())
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

        let daemonInstall = try installDaemonBundle(from: daemonSource)
        _ = try InstalledRuntimeParity.recordInstallation(
            sourceRevision: InstalledRuntimeParity.discoverSourceRevision(),
            builtArtifactSHA256: daemonInstall.builtArtifactSHA256,
            installedExecutable: MacCtlPaths.daemonAppExecutableURL,
            fileManager: fileManager
        )
        if fileManager.fileExists(atPath: MacCtlPaths.legacyDaemonExecutableURL.path) {
            try fileManager.removeItem(at: MacCtlPaths.legacyDaemonExecutableURL)
        }
        return [commandDestination.path, daemonInstall.bundleURL.path, MacCtlPaths.daemonAppExecutableURL.path]
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

    private func installDaemonBundle(from source: URL) throws -> (bundleURL: URL, builtArtifactSHA256: String) {
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

        let builtArtifactSHA256: String
        do {
            builtArtifactSHA256 = try InstalledRuntimeParity.artifactSHA256(at: executableURL)
        } catch {
            throw LaunchAgentError.installFailed("could not fingerprint the packaged daemon: \(error.localizedDescription)")
        }

        do {
            let signingResult = try processRunner(
                "/usr/bin/codesign",
                ["--force", "--deep", "--sign", signingIdentity.hash, stagingURL.path],
                30
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

        // Refresh the bounded drain immediately before replacing the running
        // daemon's on-disk bundle. Staging or codesigning may have consumed the
        // first window; a newly active task must stop the replacement here.
        _ = try lifecycleInterlock.prepare(operation: .upgrade, launchAgentStatus: status())
        if fileManager.fileExists(atPath: MacCtlPaths.daemonAppURL.path) {
            try fileManager.removeItem(at: MacCtlPaths.daemonAppURL)
        }
        try fileManager.moveItem(at: stagingURL, to: MacCtlPaths.daemonAppURL)
        return (MacCtlPaths.daemonAppURL, builtArtifactSHA256)
    }

    private func configuredExecutablePath() -> String? {
        guard let data = try? Data(contentsOf: paths.launchAgentURL),
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

    private func launchAgentReady(_ status: LaunchAgentStatus) -> Bool {
        status.installed
            && status.registrationState == .registered
            && status.loaded
            && status.healthy
            && status.identityMatches
            && status.processID != nil
            && status.configuredExecutablePath.map(normalizedPath) == normalizedPath(status.expectedExecutablePath)
            && status.activeExecutablePath.map(normalizedPath) == normalizedPath(status.expectedExecutablePath)
            && status.spawnError == nil
            && (status.lastExitCode == nil || status.lastExitCode == 0)
    }

    private func waitForBootstrappedVerification() -> (LaunchAgentStatus, DaemonRegistrationVerification) {
        var current = status()
        var verification = runtimeVerifier(current.processID, current.expectedExecutablePath)
        let deadline = Date().addingTimeInterval(verificationTimeout)
        while Date() < deadline && (!launchAgentReady(current) || !verification.verified) {
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
            current = status()
            verification = runtimeVerifier(current.processID, current.expectedExecutablePath)
        }
        return (current, verification)
    }

    private func registrationFailure(
        _ message: String,
        before: LaunchAgentStatus,
        after: LaunchAgentStatus? = nil,
        verification: DaemonRegistrationVerification? = nil,
        repairAttempted: Bool
    ) -> LaunchAgentError {
        var details: [String: JSONValue] = [
            "repair_attempted": .bool(repairAttempted),
            "before_registration_state": .string(before.registrationState.rawValue)
        ]
        if let beforeValue = try? JSONValue.fromEncodable(before) {
            details["before"] = beforeValue
        }
        if let after {
            details["after_registration_state"] = .string(after.registrationState.rawValue)
            if let afterValue = try? JSONValue.fromEncodable(after) {
                details["after"] = afterValue
            }
        }
        if let verification,
           let verificationValue = try? JSONValue.fromEncodable(verification) {
            details["runtime_verification"] = verificationValue
        }
        return .registrationFailed(message, details)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func normalizedPath(_ path: String) -> String {
        Self.normalizedPath(path)
    }

    private static func liveRuntimeVerification(
        expectedProcessID: Int32?,
        expectedExecutablePath: String
    ) -> DaemonRegistrationVerification {
        let parity = InstalledRuntimeParity.evaluate(expectedProcessID: expectedProcessID)
        var failures: [String] = []
        if parity.state != "current" {
            failures.append("installed_runtime_parity_\(parity.state)")
        }

        let socketExists = FileManager.default.fileExists(atPath: MacCtlPaths.socketURL.path)
        let socketOwnerOnly = socketExists && MacCtlPaths.ownerOnlySocketPath()
        if !socketExists {
            failures.append("daemon_socket_missing")
        } else if !socketOwnerOnly {
            failures.append("daemon_socket_not_owner_only")
        }

        var daemonProcessID: Int32?
        var daemonRuntimeContext: String?
        var daemonRuntimeIdentity: RuntimeIdentity?
        var daemonStatus: DaemonStatus?
        if socketExists && socketOwnerOnly {
            do {
                let response = try UnixSocketClient().send(RequestEnvelope(method: "status"))
                guard response.status == .succeeded else {
                    failures.append("daemon_status_request_failed")
                    return DaemonRegistrationVerification(
                        installedRuntimeParity: parity,
                        socketExists: socketExists,
                        socketOwnerOnly: socketOwnerOnly,
                        daemonIdentityMatches: false,
                        verified: false,
                        failureReasons: failures
                    )
                }
                daemonStatus = try JSONCodec.decode(
                    DaemonStatus.self,
                    from: JSONCodec.encode(response.result)
                )
                daemonProcessID = daemonStatus?.processID
                daemonRuntimeContext = daemonStatus?.runtimeContext
                daemonRuntimeIdentity = daemonStatus?.runtimeIdentity
            } catch {
                failures.append("daemon_status_unavailable")
            }
        }

        let daemonIdentityMatches: Bool
        if let daemonStatus {
            let identity = daemonStatus.runtimeIdentity
            daemonIdentityMatches = daemonStatus.daemonName == "macctld"
                && daemonStatus.runtimeContext == "daemon"
                && daemonStatus.processID == expectedProcessID
                && identity.processID == daemonStatus.processID
                && identity.executablePath == expectedExecutablePath
                && identity.bundlePath == MacCtlPaths.daemonAppURL.path
                && identity.bundleIdentifier == MacCtlDaemonBundle.bundleIdentifier
                && daemonStatus.socketPath == MacCtlPaths.socketURL.path
                && daemonStatus.socketExists
                && daemonStatus.socketOwnerOnly
            if !daemonIdentityMatches {
                failures.append("daemon_identity_mismatch")
            }
        } else {
            daemonIdentityMatches = false
        }

        return DaemonRegistrationVerification(
            installedRuntimeParity: parity,
            socketExists: socketExists,
            socketOwnerOnly: socketOwnerOnly,
            daemonProcessID: daemonProcessID,
            daemonRuntimeContext: daemonRuntimeContext,
            daemonRuntimeIdentity: daemonRuntimeIdentity,
            daemonIdentityMatches: daemonIdentityMatches,
            verified: parity.state == "current"
                && socketExists
                && socketOwnerOnly
                && daemonIdentityMatches
                && failures.isEmpty,
            failureReasons: failures
        )
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
