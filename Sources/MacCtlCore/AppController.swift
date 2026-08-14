import AppKit
import ApplicationServices
import Darwin
import Foundation

public enum AppControllerError: Error, LocalizedError {
    case appNotFound(String)
    case openFailed(String)
    case activationFailed(String)
    case focusChanged(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let name):
            return "Application not found: \(name)"
        case .openFailed(let name):
            return "Could not open application: \(name)"
        case .activationFailed(let name):
            return "Could not activate application: \(name)"
        case .focusChanged(let expected, let actual):
            return "Background application open changed foreground focus from \(expected) to \(actual)"
        }
    }
}

public final class AppController {
    private let workspace = NSWorkspace.shared
    private let fileManager = FileManager.default
    private let runningApplicationProvider: () -> [RunningApplicationDescriptor]
    private let foregroundApplicationProvider: () -> RunningApplicationDescriptor?
    private let processDescriptorProvider: (Int32) -> RunningApplicationDescriptor?
    private let accessibilityApplicationProbe: (Int32) -> AccessibilityApplicationProbeResult

    public init(
        runningApplicationProvider: (() -> [RunningApplicationDescriptor])? = nil,
        processDescriptorProvider: ((Int32) -> RunningApplicationDescriptor?)? = nil,
        accessibilityApplicationProbe: ((Int32) -> AccessibilityApplicationProbeResult)? = nil
    ) {
        self.runningApplicationProvider = runningApplicationProvider ?? Self.systemRunningApplications
        self.foregroundApplicationProvider = Self.systemForegroundApplication
        self.processDescriptorProvider = processDescriptorProvider ?? Self.systemProcessDescriptor
        self.accessibilityApplicationProbe = accessibilityApplicationProbe ?? Self.systemAccessibilityApplicationProbe
    }

    public init(
        runningApplicationProvider: @escaping () -> [RunningApplicationDescriptor],
        foregroundApplicationProvider: @escaping () -> RunningApplicationDescriptor?,
        processDescriptorProvider: ((Int32) -> RunningApplicationDescriptor?)? = nil,
        accessibilityApplicationProbe: ((Int32) -> AccessibilityApplicationProbeResult)? = nil
    ) {
        self.runningApplicationProvider = runningApplicationProvider
        self.foregroundApplicationProvider = foregroundApplicationProvider
        self.processDescriptorProvider = processDescriptorProvider ?? Self.systemProcessDescriptor
        self.accessibilityApplicationProbe = accessibilityApplicationProbe ?? Self.systemAccessibilityApplicationProbe
    }

    /// Lists every matching regular GUI process instead of collapsing bundle
    /// identity to the first NSWorkspace result.
    public func listRunningInstances(matching nameOrBundleID: String) -> [ApplicationInstanceInfo] {
        runningApplicationProvider()
            .filter { Self.matches($0, nameOrBundleID: nameOrBundleID) }
            .map(ApplicationInstanceInfo.init(descriptor:))
            .sorted { $0.processID < $1.processID }
    }

    /// Resolves an exact live process. Every supplied identity field must
    /// agree; stale instance references fail closed and never fall back.
    public func resolveRunningTarget(_ selector: ApplicationTargetSelector) throws -> ApplicationInstanceInfo {
        var applicationMatches = listRunningInstances(matching: selector.application)
        if let processID = selector.processID,
           !applicationMatches.contains(where: { $0.processID == processID }),
           let descriptor = processDescriptorProvider(processID),
           Self.matches(descriptor, nameOrBundleID: selector.application) {
            applicationMatches.append(ApplicationInstanceInfo(descriptor: descriptor))
        }
        guard !applicationMatches.isEmpty else {
            throw ApplicationTargetResolutionError.targetMissing
        }

        let processMatches: [ApplicationInstanceInfo]
        if let processID = selector.processID {
            processMatches = applicationMatches.filter { $0.processID == processID }
            guard !processMatches.isEmpty else {
                throw ApplicationTargetResolutionError.targetMissing
            }
        } else {
            processMatches = applicationMatches
        }

        let instanceMatches: [ApplicationInstanceInfo]
        if let instanceRef = selector.instanceRef {
            instanceMatches = processMatches.filter { $0.instanceRef == instanceRef }
            guard !instanceMatches.isEmpty else {
                throw ApplicationTargetResolutionError.targetChanged
            }
        } else {
            instanceMatches = processMatches
        }

        guard instanceMatches.count == 1, let instance = instanceMatches.first else {
            throw ApplicationTargetResolutionError.targetAmbiguous(instanceMatches.count)
        }
        return instance
    }

    /// Resolves a PID-bound target and independently proves that macOS exposes
    /// an addressable AXApplication root for that exact process. Process
    /// discovery alone is never treated as Accessibility addressability.
    public func bindAccessibilityTarget(
        _ selector: ApplicationTargetSelector
    ) throws -> ApplicationInstanceInfo {
        let instance = try resolveRunningTarget(selector)
        switch accessibilityApplicationProbe(instance.processID) {
        case .addressable:
            return instance
        case .permissionDenied:
            throw ApplicationTargetResolutionError.accessibilityPermissionDenied
        case .unavailable(let nativeError):
            let registeredAppBundle = instance.bundleID != nil
                && instance.path.localizedCaseInsensitiveContains(".app")
            throw ApplicationTargetResolutionError.accessibilityApplicationUnavailable(
                processID: instance.processID,
                unregisteredDevelopmentTarget: !registeredAppBundle,
                nativeError: nativeError
            )
        }
    }

    public func listApplications() -> [AppInfo] {
        var applications: [String: AppInfo] = [:]
        for url in applicationURLs() {
            guard let info = appInfo(for: url) else { continue }
            let key = info.bundleID ?? info.path
            applications[key] = info
        }
        return applications.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func resolve(_ nameOrBundleID: String) throws -> AppInfo {
        let explicitURL = URL(fileURLWithPath: nameOrBundleID).standardizedFileURL
        if explicitURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
           fileManager.fileExists(atPath: explicitURL.path),
           let info = appInfo(for: explicitURL) {
            return info
        }
        if let running = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == nameOrBundleID || $0.localizedName == nameOrBundleID
        }), let url = running.bundleURL, let info = appInfo(for: url) {
            return info
        }
        if let app = listApplications().first(where: {
            $0.bundleID == nameOrBundleID
                || $0.name.caseInsensitiveCompare(nameOrBundleID) == .orderedSame
                || URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent
                    .caseInsensitiveCompare(nameOrBundleID) == .orderedSame
        }) {
            return app
        }
        throw AppControllerError.appNotFound(nameOrBundleID)
    }

    /// Resolves one exact running process instead of the first process for a
    /// bundle. This is intentionally narrower than `resolve` and is used by
    /// same-bundle disposable fixtures and other identity-bound adapters.
    public func runningApplication(bundleID: String, processID: pid_t) -> AppInfo? {
        guard let running = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID && $0.processIdentifier == processID
        }), let url = running.bundleURL else {
            return nil
        }
        return appInfo(for: url, runningApplication: running)
    }

    @discardableResult
    public func open(
        _ nameOrBundleID: String,
        focusPolicy: FocusPolicy = .foreground
    ) throws -> AppInfo {
        let app = try resolve(nameOrBundleID)
        let initialForeground = focusPolicy == .background ? foregroundApplication() : nil
        let opened: AppInfo
        if focusPolicy == .background {
            if let running = runningInfo(for: app) {
                opened = running
            } else {
                opened = try openInBackground(app)
            }
        } else {
            opened = try openForeground(app, requestedName: nameOrBundleID)
        }
        if focusPolicy == .background {
            let actualForeground = foregroundApplication()
            guard sameApplication(initialForeground, actualForeground) else {
                throw AppControllerError.focusChanged(
                    expected: applicationLabel(initialForeground),
                    actual: applicationLabel(actualForeground)
                )
            }
        }
        return opened
    }

    @discardableResult
    public func activate(_ nameOrBundleID: String) throws -> AppInfo {
        let app = try resolve(nameOrBundleID)
        return try openForeground(app, requestedName: nameOrBundleID)
    }

    private func openForeground(_ app: AppInfo, requestedName: String) throws -> AppInfo {
        let didOpen = workspace.open(URL(fileURLWithPath: app.path))
        guard didOpen else { throw AppControllerError.openFailed(requestedName) }
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if let running = workspace.runningApplications.first(where: {
                $0.bundleIdentifier == app.bundleID || $0.bundleURL?.path == app.path
            }) {
                guard running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) else {
                    throw AppControllerError.activationFailed(requestedName)
                }
                if let frontmost = workspace.frontmostApplication,
                   frontmost.processIdentifier == running.processIdentifier {
                    return runningInfo(for: app) ?? app
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw AppControllerError.activationFailed(requestedName)
    }

    public func foregroundApplication() -> AppInfo? {
        foregroundApplicationProvider().map(ApplicationInstanceInfo.init(descriptor:))?.application
    }

    private func openInBackground(_ app: AppInfo) throws -> AppInfo {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false

        var launchError: Error?
        let completion = DispatchSemaphore(value: 0)
        workspace.openApplication(at: URL(fileURLWithPath: app.path), configuration: configuration) { _, error in
            launchError = error
            completion.signal()
        }
        guard completion.wait(timeout: .now() + 5) == .success else {
            throw AppControllerError.openFailed(app.name)
        }
        if let launchError {
            throw AppControllerError.openFailed("\(app.name): \(launchError.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let running = runningInfo(for: app) {
                return running
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw AppControllerError.openFailed(app.name)
    }

    private func runningInfo(for app: AppInfo) -> AppInfo? {
        guard let running = workspace.runningApplications.first(where: {
            (app.bundleID != nil && $0.bundleIdentifier == app.bundleID)
                || $0.bundleURL?.path == app.path
        }) else {
            return nil
        }
        return AppInfo(
            name: app.name,
            bundleID: app.bundleID,
            path: app.path,
            isRunning: true,
            processID: running.processIdentifier,
            bundleVersion: app.bundleVersion
        )
    }

    private func sameApplication(_ lhs: AppInfo?, _ rhs: AppInfo?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let lhs?, let rhs?):
            if let lhsBundleID = lhs.bundleID, let rhsBundleID = rhs.bundleID {
                return lhsBundleID == rhsBundleID
            }
            return lhs.path == rhs.path || lhs.name == rhs.name
        default:
            return false
        }
    }

    private func applicationLabel(_ app: AppInfo?) -> String {
        app?.bundleID ?? app?.path ?? app?.name ?? "none"
    }

    private func applicationURLs() -> [URL] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        var results: [URL] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                    results.append(url)
                    enumerator.skipDescendants()
                }
            }
        }
        return results
    }

    private func appInfo(for url: URL) -> AppInfo? {
        guard let bundle = Bundle(url: url) else { return nil }
        let bundleID = bundle.bundleIdentifier
        let running = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID || $0.bundleURL?.path == url.path
        })
        return appInfo(for: url, runningApplication: running)
    }

    private func appInfo(
        for url: URL,
        runningApplication: NSRunningApplication?
    ) -> AppInfo? {
        guard let bundle = Bundle(url: url) else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let bundleID = bundle.bundleIdentifier
        return AppInfo(
            name: name,
            bundleID: bundleID,
            path: url.path,
            isRunning: runningApplication != nil,
            processID: runningApplication?.processIdentifier,
            bundleVersion: (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        )
    }

    private static func matches(
        _ application: RunningApplicationDescriptor,
        nameOrBundleID: String
    ) -> Bool {
        application.bundleID == nameOrBundleID
            || URL(fileURLWithPath: application.path).standardizedFileURL.path
                == URL(fileURLWithPath: nameOrBundleID).standardizedFileURL.path
            || application.name.caseInsensitiveCompare(nameOrBundleID) == .orderedSame
            || URL(fileURLWithPath: application.path)
                .deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare(nameOrBundleID) == .orderedSame
    }

    private static func systemRunningApplications() -> [RunningApplicationDescriptor] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(systemDescriptor(for:))
    }

    /// Preserves the PID reported by the system foreground oracle. Re-resolving
    /// through bundle or path identity would collapse same-bundle processes to
    /// whichever instance NSWorkspace happens to enumerate first.
    private static func systemForegroundApplication() -> RunningApplicationDescriptor? {
        guard let running = NSWorkspace.shared.frontmostApplication else { return nil }
        return systemDescriptor(for: running)
    }

    private static func systemDescriptor(for running: NSRunningApplication) -> RunningApplicationDescriptor? {
        guard running.processIdentifier > 0 else {
            return nil
        }
        let url = running.bundleURL ?? running.executableURL
        guard let url else { return rawSystemProcessDescriptor(running.processIdentifier, name: running.localizedName) }
        let bundle = running.bundleURL.flatMap(Bundle.init(url:))
        let name = running.localizedName
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? running.executableURL?.lastPathComponent
            ?? url.deletingPathExtension().lastPathComponent
        return RunningApplicationDescriptor(
            name: name,
            bundleID: running.bundleIdentifier,
            path: url.path,
            processID: running.processIdentifier,
            launchDate: running.launchDate,
            bundleVersion: (bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        )
    }

    private static func systemProcessDescriptor(_ processID: Int32) -> RunningApplicationDescriptor? {
        if let running = NSRunningApplication(processIdentifier: processID),
           let descriptor = systemDescriptor(for: running) {
            return descriptor
        }
        return rawSystemProcessDescriptor(processID, name: nil)
    }

    private static func rawSystemProcessDescriptor(
        _ processID: Int32,
        name: String?
    ) -> RunningApplicationDescriptor? {
        guard processID > 0 else { return nil }
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let copied = proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, infoSize)
        guard copied == infoSize, info.pbi_uid == geteuid() else { return nil }

        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(processID, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        let path = String(cString: pathBuffer)
        let launchDate: Date? = if info.pbi_start_tvsec > 0 {
            Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        } else {
            nil
        }
        return RunningApplicationDescriptor(
            name: name ?? URL(fileURLWithPath: path).lastPathComponent,
            bundleID: nil,
            path: path,
            processID: processID,
            launchDate: launchDate,
            bundleVersion: nil
        )
    }

    private static func systemAccessibilityApplicationProbe(
        _ processID: Int32
    ) -> AccessibilityApplicationProbeResult {
        guard PermissionDiagnostics.hasAccessibility() else { return .permissionDenied }
        let application = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            application,
            kAXRoleAttribute as CFString,
            &value
        )
        guard error == .success, (value as? String) == kAXApplicationRole else {
            return .unavailable(nativeError: error.rawValue)
        }
        return .addressable
    }
}
