import AppKit
import Foundation

public enum AppControllerError: Error, LocalizedError {
    case appNotFound(String)
    case openFailed(String)
    case activationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let name):
            return "Application not found: \(name)"
        case .openFailed(let name):
            return "Could not open application: \(name)"
        case .activationFailed(let name):
            return "Could not activate application: \(name)"
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
    public func open(_ nameOrBundleID: String) throws -> AppInfo {
        let app = try resolve(nameOrBundleID)
        let opened = workspace.open(URL(fileURLWithPath: app.path))
        guard opened else { throw AppControllerError.openFailed(nameOrBundleID) }
        return app
    }

    @discardableResult
    public func activate(_ nameOrBundleID: String) throws -> AppInfo {
        let app = try open(nameOrBundleID)
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
