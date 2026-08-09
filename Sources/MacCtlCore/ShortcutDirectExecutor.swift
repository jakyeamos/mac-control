import Foundation

public protocol ShortcutDirectMenuExecuting {
    func execute(
        application: AppInfo,
        path: [String]
    ) throws -> (before: MenuCommandSnapshot, after: MenuCommandSnapshot)
}

public final class BasicShortcutDirectMenuExecutor: ShortcutDirectMenuExecuting {
    private let menus: MenuCommandControlling

    public init(menus: MenuCommandControlling) {
        self.menus = menus
    }

    public func execute(
        application: AppInfo,
        path: [String]
    ) throws -> (before: MenuCommandSnapshot, after: MenuCommandSnapshot) {
        let before = try menus.inspect(application: application, path: path)
        let after = try menus.activate(application: application, path: path)
        return (before, after)
    }
}

public final class ControlSessionShortcutDirectMenuExecutor: ShortcutDirectMenuExecuting {
    private let menus: MenuCommandControlling
    private let session: ControlSession
    private let leases: KeyboardDriveStore

    public init(
        menus: MenuCommandControlling,
        session: ControlSession,
        leases: KeyboardDriveStore
    ) {
        self.menus = menus
        self.session = session
        self.leases = leases
    }

    public func execute(
        application: AppInfo,
        path: [String]
    ) throws -> (before: MenuCommandSnapshot, after: MenuCommandSnapshot) {
        let lease = try leases.acquire(
            scope: .app,
            application: application,
            seconds: 10,
            confirm: true
        )
        defer { _ = leases.invalidate(token: lease.token) }
        let context = try session.beginAction(
            leaseToken: lease.token,
            requireFullKeyboardAccess: false,
            requirePostEventAccess: false
        )
        _ = try session.revalidate(context)
        let before = try menus.inspect(application: application, path: path)
        let after = try menus.activate(application: application, path: path)
        let changed = before.checked != after.checked || before.enabled != after.enabled
        _ = try session.completeAction(
            context,
            action: "shortcut.command",
            route: .accessibility,
            postcondition: ControlActionPostcondition(
                kind: "menu_item_state",
                verified: changed,
                details: ["path_digest": .string(ShortcutDigests.digest(path))]
            )
        )
        return (before, after)
    }
}
