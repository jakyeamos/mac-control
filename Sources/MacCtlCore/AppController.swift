import AppKit
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

    public init() {}

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
            let didOpen = workspace.open(URL(fileURLWithPath: app.path))
            guard didOpen else { throw AppControllerError.openFailed(nameOrBundleID) }
            opened = runningInfo(for: app) ?? app
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
        let app = try open(nameOrBundleID, focusPolicy: .foreground)
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if let running = workspace.runningApplications.first(where: {
                $0.bundleIdentifier == app.bundleID || $0.bundleURL?.path == app.path
            }) {
                let activated = running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                guard activated else { throw AppControllerError.activationFailed(nameOrBundleID) }
                if running.isActive { return app }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw AppControllerError.activationFailed(nameOrBundleID)
    }

    public func foregroundApplication() -> AppInfo? {
        guard let running = workspace.runningApplications.first(where: { $0.isActive }),
              let url = running.bundleURL else {
            return nil
        }
        return appInfo(for: url)
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
            processID: running.processIdentifier
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
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let bundleID = bundle.bundleIdentifier
        let running = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID || $0.bundleURL?.path == url.path
        })
        return AppInfo(
            name: name,
            bundleID: bundleID,
            path: url.path,
            isRunning: running != nil,
            processID: running?.processIdentifier
        )
    }
}
