import AppKit
import Foundation

public struct ShortcutProvisioningResult: Equatable {
    public let configured: Bool
    public let observedChord: String?
    public let priorChord: String?
    public let checkpoint: String
    public let handoffInstruction: String?

    public init(
        configured: Bool,
        observedChord: String? = nil,
        priorChord: String? = nil,
        checkpoint: String,
        handoffInstruction: String? = nil
    ) {
        self.configured = configured
        self.observedChord = observedChord
        self.priorChord = priorChord
        self.checkpoint = checkpoint
        self.handoffInstruction = handoffInstruction
    }
}

public protocol ShortcutProvisioning {
    func setup(binding: ShortcutBinding, application: AppInfo?) throws -> ShortcutProvisioningResult
    func remove(binding: ShortcutBinding, application: AppInfo?) throws -> ShortcutProvisioningResult
}

/// Opens only the supported configuration surfaces and verifies their
/// readback. If a unique semantic field is not available, it returns a human
/// handoff instead of traversing controls by tab order.
public final class GuidedShortcutProvisioner: ShortcutProvisioning {
    private let menuController: MenuCommandControlling
    private let chromeController: ChromeExtensionShortcutControlling
    private let chromeDiscovery: ChromeExtensionCommandDiscovering
    private let workspace: NSWorkspace

    public init(
        menuController: MenuCommandControlling = AccessibilityMenuCommandController(),
        chromeController: ChromeExtensionShortcutControlling,
        chromeDiscovery: ChromeExtensionCommandDiscovering = ChromeExtensionManifestDiscovery(),
        workspace: NSWorkspace = .shared
    ) {
        self.menuController = menuController
        self.chromeController = chromeController
        self.chromeDiscovery = chromeDiscovery
        self.workspace = workspace
    }

    public func setup(
        binding: ShortcutBinding,
        application: AppInfo?
    ) throws -> ShortcutProvisioningResult {
        guard let chord = binding.chord else { throw ShortcutError.invalidChord("missing") }
        switch binding.target.kind {
        case .appMenu:
            guard let application, let path = binding.target.menuPath else {
                throw ShortcutError.invalidTarget("app shortcut is missing its application or menu path")
            }
            let current = try menuController.inspect(application: application, path: path)
            if normalized(current.keyEquivalent) == normalized(chord) {
                return ShortcutProvisioningResult(
                    configured: true,
                    observedChord: current.keyEquivalent,
                    priorChord: binding.priorChord ?? current.keyEquivalent,
                    checkpoint: "menu_key_equivalent_readback"
                )
            }
            openKeyboardShortcutsSettings()
            let syntax = path.joined(separator: "->")
            return ShortcutProvisioningResult(
                configured: false,
                observedChord: current.keyEquivalent,
                priorChord: binding.priorChord ?? current.keyEquivalent,
                checkpoint: "system_settings_opened",
                handoffInstruction: "In App Shortcuts, choose \(application.name), enter exactly \(syntax), assign \(chord), then rerun setup for readback."
            )
        case .chromeExtension:
            openChromeExtensionShortcuts()
            guard let application,
                  let extensionID = binding.target.extensionID,
                  let commandID = binding.target.commandID else {
                throw ShortcutError.invalidTarget("Chrome command target is incomplete")
            }
            let descriptor = try chromeDiscovery.command(extensionID: extensionID, commandID: commandID)
            do {
                let current = try chromeController.inspect(descriptor: descriptor, application: application)
                if normalized(current.chord) == normalized(chord) {
                    return ShortcutProvisioningResult(
                        configured: true,
                        observedChord: current.chord,
                        priorChord: binding.priorChord ?? current.chord,
                        checkpoint: "chrome_command_readback"
                    )
                }
                let assigned = try chromeController.assign(
                    descriptor: descriptor,
                    chord: chord,
                    application: application
                )
                return ShortcutProvisioningResult(
                    configured: normalized(assigned.chord) == normalized(chord),
                    observedChord: assigned.chord,
                    priorChord: binding.priorChord ?? current.chord,
                    checkpoint: "chrome_command_assigned"
                )
            } catch ShortcutError.handoffRequired(let reason) {
                return ShortcutProvisioningResult(
                    configured: false,
                    observedChord: nil,
                    priorChord: binding.priorChord,
                    checkpoint: "chrome_extension_shortcuts_opened",
                    handoffInstruction: "\(reason). Assign \(chord) to \(descriptor.extensionName) command \(descriptor.commandDescription), then rerun setup for readback."
                )
            }
        }
    }

    public func remove(
        binding: ShortcutBinding,
        application: AppInfo?
    ) throws -> ShortcutProvisioningResult {
        switch binding.target.kind {
        case .appMenu:
            guard let application, let path = binding.target.menuPath else {
                throw ShortcutError.invalidTarget("app shortcut is missing its application or menu path")
            }
            let current = try menuController.inspect(application: application, path: path)
            if normalized(current.keyEquivalent) == normalized(binding.priorChord) {
                return ShortcutProvisioningResult(
                    configured: true,
                    observedChord: current.keyEquivalent,
                    priorChord: binding.priorChord,
                    checkpoint: "prior_menu_key_equivalent_restored"
                )
            }
            openKeyboardShortcutsSettings()
            return ShortcutProvisioningResult(
                configured: false,
                observedChord: current.keyEquivalent,
                priorChord: binding.priorChord,
                checkpoint: "system_settings_rollback_opened",
                handoffInstruction: "Remove this App Shortcut and restore the prior chord \(binding.priorChord ?? "unbound"), then rerun remove for exact readback."
            )
        case .chromeExtension:
            openChromeExtensionShortcuts()
            guard let application,
                  let extensionID = binding.target.extensionID,
                  let commandID = binding.target.commandID else {
                throw ShortcutError.invalidTarget("Chrome command target is incomplete")
            }
            let descriptor = try chromeDiscovery.command(extensionID: extensionID, commandID: commandID)
            do {
                let restored: ChromeExtensionCommandSnapshot
                if let priorChord = binding.priorChord {
                    restored = try chromeController.assign(
                        descriptor: descriptor,
                        chord: priorChord,
                        application: application
                    )
                } else {
                    restored = try chromeController.clear(descriptor: descriptor, application: application)
                }
                return ShortcutProvisioningResult(
                    configured: normalized(restored.chord) == normalized(binding.priorChord),
                    observedChord: restored.chord,
                    priorChord: binding.priorChord,
                    checkpoint: "chrome_command_prior_chord_restored"
                )
            } catch ShortcutError.handoffRequired(let reason) {
                return ShortcutProvisioningResult(
                    configured: false,
                    observedChord: nil,
                    priorChord: binding.priorChord,
                    checkpoint: "chrome_extension_rollback_opened",
                    handoffInstruction: "\(reason). Restore the prior Chrome command chord \(binding.priorChord ?? "unbound"), then rerun remove for semantic readback."
                )
            }
        }
    }

    private func normalized(_ chord: String?) -> String? {
        guard let chord else { return nil }
        return try? ShortcutChord(chord).canonical
    }

    private func openKeyboardShortcutsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?KeyboardShortcuts") {
            workspace.open(url)
        }
    }

    private func openChromeExtensionShortcuts() {
        guard let chrome = workspace.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let page = URL(string: "chrome://extensions/shortcuts") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open([page], withApplicationAt: chrome, configuration: configuration) { _, _ in }
    }
}

public protocol ShortcutKeyboardDispatching {
    func dispatch(chord: String, application: AppInfo) throws
    func clear(application: AppInfo) throws
}

public final class AppScopedShortcutKeyboardDispatcher: ShortcutKeyboardDispatching {
    private let keyboard: KeyboardAccessController
    private let leases: KeyboardDriveStore
    private let foregroundApplication: () -> AppInfo?

    public init(
        keyboard: KeyboardAccessController,
        leases: KeyboardDriveStore,
        foregroundApplication: @escaping () -> AppInfo?
    ) {
        self.keyboard = keyboard
        self.leases = leases
        self.foregroundApplication = foregroundApplication
    }

    public func dispatch(chord: String, application: AppInfo) throws {
        try dispatch(keys: [chord], application: application)
    }

    public func clear(application: AppInfo) throws {
        try dispatch(keys: ["delete"], application: application)
    }

    private func dispatch(keys: [String], application: AppInfo) throws {
        let lease = try leases.acquire(
            scope: .app,
            application: application,
            seconds: 10,
            confirm: true
        )
        defer { _ = leases.invalidate(token: lease.token) }
        _ = try keyboard.sendRaw(
            keys: keys,
            targetApplication: application,
            leaseExpiresAt: lease.expiresAt,
            interKeyDelay: 0,
            beforeEach: { [foregroundApplication] _ in
                guard let foreground = foregroundApplication(),
                      Self.sameApplication(application, foreground) else {
                    throw KeyboardControlError.appScopeMismatch(
                        expected: application.bundleID ?? application.name,
                        actual: foregroundApplication()?.bundleID ?? foregroundApplication()?.name ?? "none"
                    )
                }
            }
        )
    }

    private static func sameApplication(_ lhs: AppInfo, _ rhs: AppInfo) -> Bool {
        if let lhsID = lhs.bundleID, let rhsID = rhs.bundleID { return lhsID == rhsID }
        return lhs.path == rhs.path
    }
}
