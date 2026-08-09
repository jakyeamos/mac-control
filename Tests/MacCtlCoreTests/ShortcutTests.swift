import Foundation
import XCTest
@testable import MacCtlCore

final class ShortcutTests: XCTestCase {
    func testChordCanonicalizationRestrictionsAndCollisions() throws {
        XCTAssertEqual(
            try ShortcutChord("⌃+Option+Command+K").canonical,
            "ctrl+option+cmd+k"
        )
        XCTAssertThrowsError(try ShortcutChord("fn+cmd+k", provider: .chromeExtensionCommand))
        XCTAssertThrowsError(try ShortcutChord("shift+k"))

        let reserved = try ShortcutChord("cmd+space")
        XCTAssertEqual(
            ShortcutCollisionValidator.validate(
                chord: reserved,
                appMenuChords: [],
                bindings: []
            ).conflictingSources,
            ["system_reserved"]
        )
        let appConflict = try ShortcutChord("ctrl+option+cmd+1")
        XCTAssertEqual(
            ShortcutCollisionValidator.validate(
                chord: appConflict,
                appMenuChords: ["control+option+command+1"],
                bindings: []
            ).conflictingSources,
            ["target_app_menu"]
        )
    }

    func testEnabledSystemShortcutRegistrationsParticipateInCollisionChecks() throws {
        let directory = temporaryDirectory("system-shortcuts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("com.apple.symbolichotkeys.plist")
        let plist: [String: Any] = [
            "AppleSymbolicHotKeys": [
                "999": [
                    "enabled": true,
                    "value": ["parameters": [Int(Character("k").asciiValue!), 40, 0x1C0000]]
                ],
                "1000": [
                    "enabled": false,
                    "value": ["parameters": [Int(Character("j").asciiValue!), 38, 0x1C0000]]
                ]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: file)
        let registrations = SystemShortcutRegistrations(preferencesURL: file).enabledChords()
        XCTAssertEqual(registrations, ["ctrl+option+cmd+k"])
        let collision = ShortcutCollisionValidator.validate(
            chord: try ShortcutChord("ctrl+option+cmd+k"),
            appMenuChords: [],
            bindings: [],
            registeredSystemChords: registrations
        )
        XCTAssertEqual(collision.conflictingSources, ["system_reserved"])
    }

    func testMenuDynamicRulesKeepStaticToggleAndRejectRecentOrWindowDocument() {
        XCTAssertFalse(AccessibilityMenuCommandController.isDynamic(path: ["View", "Show Sidebar…"]))
        XCTAssertTrue(AccessibilityMenuCommandController.isDynamic(path: ["File", "Open Recent"] ))
        XCTAssertTrue(AccessibilityMenuCommandController.isDynamic(path: ["File", "Open Recent", "Document"] ))
        XCTAssertTrue(AccessibilityMenuCommandController.isDynamic(path: ["Window", "Project.swift"] ))
        XCTAssertFalse(AccessibilityMenuCommandController.isDynamic(path: ["Window", "Minimize"] ))
    }

    func testBindingStoreIsAtomicOwnerOnlyAndPreservesRollbackChord() throws {
        let directory = temporaryDirectory("shortcut-store")
        let store = ShortcutBindingStore(directory: directory)
        let binding = makeBinding(priorChord: "cmd+b")
        try store.save(binding)

        XCTAssertTrue(store.ownerOnly())
        XCTAssertEqual(store.binding(id: binding.id)?.priorChord, "cmd+b")
        let file = directory.appendingPathComponent("bindings.json")
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(mode.intValue & 0o777, 0o600)

        let replacement = binding.updating(status: .configured, setupCheckpoint: .some("readback"))
        try store.save(replacement)
        XCTAssertEqual(store.list().count, 1)
        XCTAssertEqual(store.binding(id: binding.id)?.setupCheckpoint, "readback")
    }

    func testDirectAndKeyboardRoutesRequireObservedToggleAndNeverRetry() throws {
        let directory = temporaryDirectory("shortcut-engine")
        let menu = FakeMenuController(path: ["View", "Show Sidebar…"], checked: false)
        let keyboard = FakeShortcutKeyboardDispatcher { menu.checked.toggle() }
        let provisioner = FakeShortcutProvisioner(configured: true)
        let app = runningApp()
        let engine = ShortcutEngine(
            store: ShortcutBindingStore(directory: directory.appendingPathComponent("bindings")),
            menus: menu,
            provisioner: provisioner,
            keyboard: keyboard,
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            foregroundApplication: { app },
            warmPaths: WarmPathStore(directory: directory.appendingPathComponent("warm"))
        )
        let binding = try engine.propose(
            target: .appMenu(
                applicationName: app.name,
                bundleID: app.bundleID,
                menuPath: menu.path
            ),
            requestedChord: "ctrl+option+cmd+1"
        )

        let direct = try engine.run(id: binding.id, requestedRoute: .accessibility)
        XCTAssertEqual(direct.verification, "passed")
        XCTAssertEqual(direct.beforeMenuState?.checked, false)
        XCTAssertEqual(direct.afterMenuState?.checked, true)
        XCTAssertEqual(try engine.inspect(id: binding.id).status, .behaviorVerified)

        let inspection = try engine.inspection(id: binding.id)
        XCTAssertEqual(inspection.menuState?.checked, true)
        XCTAssertEqual(inspection.observation, "live menu state read without activating or dispatching the command")
        XCTAssertEqual(menu.activationCount, 1, "inspection must not dispatch the command")

        _ = try engine.setup(id: binding.id)
        let keyboardReport = try engine.run(id: binding.id, requestedRoute: .keyboard)
        XCTAssertEqual(keyboardReport.verification, "passed")
        XCTAssertEqual(keyboard.dispatchCount, 1)

        keyboard.onDispatch = {}
        let failed = try engine.run(id: binding.id, requestedRoute: .keyboard)
        XCTAssertEqual(failed.verification, "verification_unavailable")
        XCTAssertEqual(failed.status, .configured)
        XCTAssertEqual(failed.beforeMenuState?.checked, false)
        XCTAssertEqual(failed.afterMenuState?.checked, false)
        XCTAssertEqual(keyboard.dispatchCount, 2, "indeterminate commands must not retry")
        XCTAssertEqual(try engine.inspect(id: binding.id).status, .configured)
    }

    func testMarkedToMissingValueAndBackVerifiesAsReversibleToggle() throws {
        let directory = temporaryDirectory("shortcut-unchecked-mark")
        let menu = FakeMenuController(path: ["View", "Use Groups"], checked: true)
        menu.reportUncheckedAsMissingMark = true
        let app = runningApp()
        let engine = ShortcutEngine(
            store: ShortcutBindingStore(directory: directory.appendingPathComponent("bindings")),
            menus: menu,
            provisioner: FakeShortcutProvisioner(configured: true),
            keyboard: FakeShortcutKeyboardDispatcher(),
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            foregroundApplication: { app },
            warmPaths: WarmPathStore(directory: directory.appendingPathComponent("warm"))
        )
        let binding = try engine.propose(
            target: .appMenu(applicationName: app.name, bundleID: app.bundleID, menuPath: menu.path),
            requestedChord: "ctrl+option+cmd+1"
        )

        let unchecked = try engine.run(id: binding.id, requestedRoute: .accessibility)
        XCTAssertEqual(unchecked.verification, "passed")
        XCTAssertEqual(unchecked.beforeMenuState?.checked, true)
        XCTAssertNil(unchecked.afterMenuState?.checked)

        let restored = try engine.run(id: binding.id, requestedRoute: .accessibility)
        XCTAssertEqual(restored.verification, "passed")
        XCTAssertNil(restored.beforeMenuState?.checked)
        XCTAssertEqual(restored.afterMenuState?.checked, true)
        XCTAssertEqual(menu.activationCount, 2)
    }

    func testApplicationVersionChangeMarksBindingStale() throws {
        let directory = temporaryDirectory("shortcut-stale")
        let menu = FakeMenuController(path: ["View", "Sidebar"], checked: false)
        var app = runningApp(version: "1")
        let engine = ShortcutEngine(
            store: ShortcutBindingStore(directory: directory.appendingPathComponent("bindings")),
            menus: menu,
            provisioner: FakeShortcutProvisioner(configured: false),
            keyboard: FakeShortcutKeyboardDispatcher(),
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            foregroundApplication: { app },
            warmPaths: WarmPathStore(directory: directory.appendingPathComponent("warm"))
        )
        let binding = try engine.propose(
            target: .appMenu(applicationName: app.name, bundleID: app.bundleID, menuPath: menu.path),
            requestedChord: nil
        )
        app = runningApp(version: "2")
        let stale = try engine.inspect(id: binding.id)
        XCTAssertEqual(stale.status, .stale)
        XCTAssertEqual(stale.lastBlocker, "application identity or version changed")
    }

    func testSetupHandoffPersistsCheckpointWithoutPromotingConfigured() throws {
        let directory = temporaryDirectory("shortcut-handoff")
        let menu = FakeMenuController(path: ["View", "Sidebar"], checked: false)
        let app = runningApp()
        let provisioner = FakeShortcutProvisioner(
            configured: false,
            checkpoint: "system_settings_opened",
            instruction: "Complete semantic setup"
        )
        let engine = ShortcutEngine(
            store: ShortcutBindingStore(directory: directory.appendingPathComponent("bindings")),
            menus: menu,
            provisioner: provisioner,
            keyboard: FakeShortcutKeyboardDispatcher(),
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            foregroundApplication: { app },
            warmPaths: WarmPathStore(directory: directory.appendingPathComponent("warm"))
        )
        let binding = try engine.propose(
            target: .appMenu(applicationName: app.name, bundleID: app.bundleID, menuPath: menu.path),
            requestedChord: nil
        )
        let report = try engine.setup(id: binding.id)
        let persisted = try engine.inspect(id: binding.id)
        XCTAssertTrue(report.handoffRequired)
        XCTAssertEqual(persisted.status, .setupRequired)
        XCTAssertEqual(persisted.setupCheckpoint, "system_settings_opened")
        XCTAssertNil(persisted.evidence.behaviorVerifiedAt)
    }

    func testExistingMenuChordIsAdoptedWithoutConflictAndPreservedOnRemoval() throws {
        let directory = temporaryDirectory("shortcut-existing-chord")
        let menu = FakeMenuController(
            path: ["View", "Show Sidebar…"],
            checked: false,
            keyEquivalent: "control+option+command+7"
        )
        let app = runningApp()
        let provisioner = FakeShortcutProvisioner(configured: true)
        let engine = ShortcutEngine(
            store: ShortcutBindingStore(directory: directory.appendingPathComponent("bindings")),
            menus: menu,
            provisioner: provisioner,
            keyboard: FakeShortcutKeyboardDispatcher(),
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            foregroundApplication: { app },
            warmPaths: WarmPathStore(directory: directory.appendingPathComponent("warm"))
        )

        let binding = try engine.propose(
            target: .appMenu(applicationName: app.name, bundleID: app.bundleID, menuPath: menu.path),
            requestedChord: nil
        )
        XCTAssertEqual(binding.chord, "ctrl+option+cmd+7")
        XCTAssertEqual(binding.priorChord, "control+option+command+7")
        XCTAssertEqual(binding.status, .configured)

        let removed = try engine.remove(id: binding.id)
        XCTAssertFalse(removed.handoffRequired)
        XCTAssertEqual(removed.configuredChord, "control+option+command+7")
        XCTAssertEqual(provisioner.removeCount, 1)
        XCTAssertThrowsError(try engine.inspect(id: binding.id))
    }

    func testAuditClassifiesAmbiguousDisabledDynamicAndMissingPostconditions() throws {
        let directory = temporaryDirectory("shortcut-audit")
        let app = runningApp()
        let menu = FakeMenuController(path: ["View", "Sidebar"], checked: false)
        menu.auditSnapshots = [
            MenuCommandSnapshot(path: ["File", "Export…"], enabled: false),
            MenuCommandSnapshot(path: ["File", "Open Recent", "Document"], enabled: true, dynamic: true),
            MenuCommandSnapshot(path: ["View", "Sidebar"], enabled: true, checked: nil),
            MenuCommandSnapshot(path: ["View", "First", "Duplicate"], enabled: true, checked: false),
            MenuCommandSnapshot(path: ["View", "Second", "Duplicate"], enabled: true, checked: false),
            MenuCommandSnapshot(path: ["View", "Show Sidebar…"], enabled: true, checked: true)
        ]
        let engine = ShortcutEngine(
            store: ShortcutBindingStore(directory: directory.appendingPathComponent("bindings")),
            menus: menu,
            provisioner: FakeShortcutProvisioner(configured: false),
            keyboard: FakeShortcutKeyboardDispatcher(),
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            foregroundApplication: { app },
            warmPaths: WarmPathStore(directory: directory.appendingPathComponent("warm"))
        )

        let entries = try engine.audit(app: app.name).entries
        func disposition(_ path: [String]) -> ShortcutAuditDisposition? {
            entries.first(where: { $0.target.menuPath == path })?.disposition
        }
        XCTAssertEqual(disposition(["File", "Export…"]), .unsupported)
        XCTAssertEqual(disposition(["File", "Open Recent", "Document"]), .unsupported)
        XCTAssertEqual(disposition(["View", "Sidebar"]), .needsPostcondition)
        XCTAssertEqual(disposition(["View", "First", "Duplicate"]), .conflict)
        XCTAssertEqual(disposition(["View", "Second", "Duplicate"]), .conflict)
        XCTAssertEqual(disposition(["View", "Show Sidebar…"]), .eligible)
    }

    func testChromeManifestDiscoveryResolvesLocalizedDeclaredCommand() throws {
        let root = temporaryDirectory("chrome-manifest")
        let extensionID = String(repeating: "a", count: 32)
        let version = root
            .appendingPathComponent("Default/Extensions/\(extensionID)/1.0", isDirectory: true)
        let locale = version.appendingPathComponent("_locales/en", isDirectory: true)
        try FileManager.default.createDirectory(at: locale, withIntermediateDirectories: true)
        try Data("""
        {"name":"__MSG_name__","default_locale":"en","commands":{"toggle":{"description":"__MSG_toggle__"}}}
        """.utf8).write(to: version.appendingPathComponent("manifest.json"))
        try Data("""
        {"name":{"message":"Example Extension"},"toggle":{"message":"Toggle Example"}}
        """.utf8).write(to: locale.appendingPathComponent("messages.json"))

        let descriptor = try ChromeExtensionManifestDiscovery(chromeRoot: root)
            .command(extensionID: extensionID, commandID: "toggle")
        XCTAssertEqual(descriptor.extensionName, "Example Extension")
        XCTAssertEqual(descriptor.commandDescription, "Toggle Example")
        XCTAssertThrowsError(
            try ChromeExtensionManifestDiscovery(chromeRoot: root)
                .command(extensionID: extensionID, commandID: "missing")
        )
    }

    func testCommandActionAndMenuPredicateValidationAreSensitiveAndExact() {
        let predicate = TaskPredicate(
            kind: .menuItemState,
            expected: "toggled",
            application: "Test App",
            parameters: ["menu_path": .array([.string("View"), .string("Sidebar")])]
        )
        let step = TaskStep(
            id: "shortcut-run",
            action: ActionSpec(
                kind: .command,
                surface: .macApp,
                parameters: [
                    "binding_id": .string("sc_test"),
                    "binding_digest": .string(String(repeating: "a", count: 64)),
                    "operation": .string("run")
                ]
            ),
            postconditions: [predicate],
            risk: .sensitive,
            approvalReason: "Exact shortcut operation",
            recovery: TaskRecoveryPolicy(mode: "strict", maxAttempts: 1)
        )
        let plan = TaskPlan(
            id: "shortcut-test",
            name: "Shortcut test",
            summary: "Validate exact shortcut command authority",
            steps: [step],
            totalTimeout: 10,
            maxActions: 1
        )
        let result = TaskPlanValidator.validate(plan)
        XCTAssertTrue(result.valid, result.errors.joined(separator: ", "))
        XCTAssertEqual(result.risk, .sensitive)
    }

    func testApprovalTokenIsBoundToExactBindingOperation() throws {
        let directory = temporaryDirectory("shortcut-approval")
        let menu = FakeMenuController(path: ["View", "Sidebar"], checked: false)
        let app = runningApp()
        let engine = ShortcutEngine(
            store: ShortcutBindingStore(directory: directory.appendingPathComponent("bindings")),
            menus: menu,
            provisioner: FakeShortcutProvisioner(configured: true),
            keyboard: FakeShortcutKeyboardDispatcher(),
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            foregroundApplication: { app },
            warmPaths: WarmPathStore(directory: directory.appendingPathComponent("warm"))
        )
        let binding = try engine.propose(
            target: .appMenu(applicationName: app.name, bundleID: app.bundleID, menuPath: menu.path),
            requestedChord: nil
        )
        let approvals = TaskApprovalStore()
        let receiptStore = OperationReceiptStore(directory: directory.appendingPathComponent("receipts"))
        let service = MacCtlService(
            receiptStore: receiptStore,
            permissionContext: "test",
            taskApprovalStore: approvals,
            taskCheckpointStore: TaskCheckpointStore(directory: directory.appendingPathComponent("checkpoints")),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            shortcutEngine: engine
        )
        let prepared = service.localReadOnlyHandle(RequestEnvelope(
            method: "shortcut.setup",
            params: ["id": .string(binding.id)]
        ))
        XCTAssertEqual(prepared.status, .prepared)
        let token = try XCTUnwrap(
            prepared.result.objectValue?["approval"]?.objectValue?["token"]?.stringValue
        )
        let approved = service.localReadOnlyHandle(RequestEnvelope(
            method: "approval.approve",
            params: ["token": .string(token)]
        ))
        XCTAssertEqual(approved.status, .succeeded)

        let mismatch = service.localReadOnlyHandle(RequestEnvelope(
            method: "shortcut.run",
            params: ["id": .string(binding.id), "approval_token": .string(token)]
        ))
        XCTAssertEqual(mismatch.status, .blocked)
        XCTAssertEqual(mismatch.error?.code, MacCtlErrorCode.taskApprovalMismatch.rawValue)
        XCTAssertEqual(menu.activationCount, 0)

        let preparedRun = service.localReadOnlyHandle(RequestEnvelope(
            method: "shortcut.run",
            params: [
                "id": .string(binding.id),
                "route": .string(ShortcutRunRoute.accessibility.rawValue)
            ]
        ))
        let runToken = try XCTUnwrap(
            preparedRun.result.objectValue?["approval"]?.objectValue?["token"]?.stringValue
        )
        XCTAssertEqual(service.localReadOnlyHandle(RequestEnvelope(
            method: "approval.approve",
            params: ["token": .string(runToken)]
        )).status, .succeeded)
        let run = service.localReadOnlyHandle(RequestEnvelope(
            method: "shortcut.run",
            params: [
                "id": .string(binding.id),
                "route": .string(ShortcutRunRoute.accessibility.rawValue),
                "approval_token": .string(runToken)
            ]
        ))
        XCTAssertEqual(run.status, .succeeded)
        let receipt = try XCTUnwrap(try receiptStore.list().first {
            $0.method == "shortcut.run" && $0.status == .succeeded
        })
        XCTAssertEqual(receipt.verificationResult, "passed")
        XCTAssertEqual(receipt.route, ShortcutRunRoute.accessibility.rawValue)
        XCTAssertTrue(receipt.evidence.contains { $0.kind == "shortcut_behavior" })
    }

    private func temporaryDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macctl-\(name)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func runningApp(version: String = "1") -> AppInfo {
        AppInfo(
            name: "Test App",
            bundleID: "com.example.TestApp",
            path: "/Applications/Test App.app",
            isRunning: true,
            processID: 42,
            bundleVersion: version
        )
    }

    private func makeBinding(priorChord: String? = nil) -> ShortcutBinding {
        let target = CommandTarget.appMenu(
            applicationName: "Test App",
            bundleID: "com.example.TestApp",
            menuPath: ["View", "Sidebar"]
        )
        return ShortcutBinding(
            id: ShortcutDigests.bindingID(for: target),
            target: target,
            chord: "ctrl+option+cmd+1",
            provider: .macOSAppShortcut,
            priorChord: priorChord,
            postconditions: [TaskPredicate(kind: .menuItemState, expected: "toggled")]
        )
    }
}

private final class FakeMenuController: MenuCommandControlling {
    let path: [String]
    var checked: Bool
    var enabled = true
    var dynamic = false
    var keyEquivalent: String?
    var activationCount = 0
    var auditSnapshots: [MenuCommandSnapshot]?
    var reportUncheckedAsMissingMark = false

    init(path: [String], checked: Bool, keyEquivalent: String? = nil) {
        self.path = path
        self.checked = checked
        self.keyEquivalent = keyEquivalent
    }

    func audit(application: AppInfo, maxItems: Int) throws -> ([MenuCommandSnapshot], Bool) {
        (auditSnapshots ?? [snapshot()], false)
    }

    func inspect(application: AppInfo, path: [String]) throws -> MenuCommandSnapshot {
        guard path == self.path else { throw ShortcutError.menuPathNotFound(path) }
        return snapshot()
    }

    func activate(application: AppInfo, path: [String]) throws -> MenuCommandSnapshot {
        guard path == self.path else { throw ShortcutError.menuPathNotFound(path) }
        guard enabled else { throw ShortcutError.menuItemDisabled(path) }
        guard !dynamic else { throw ShortcutError.dynamicMenuItem(path) }
        activationCount += 1
        checked.toggle()
        return snapshot()
    }

    private func snapshot() -> MenuCommandSnapshot {
        MenuCommandSnapshot(
            path: path,
            enabled: enabled,
            dynamic: dynamic,
            keyEquivalent: keyEquivalent,
            checked: reportUncheckedAsMissingMark && !checked ? nil : checked
        )
    }
}

private final class FakeShortcutProvisioner: ShortcutProvisioning {
    let configured: Bool
    let checkpoint: String
    let instruction: String?
    private(set) var setupCount = 0
    private(set) var removeCount = 0

    init(configured: Bool, checkpoint: String = "readback", instruction: String? = nil) {
        self.configured = configured
        self.checkpoint = checkpoint
        self.instruction = instruction
    }

    func setup(binding: ShortcutBinding, application: AppInfo?) throws -> ShortcutProvisioningResult {
        setupCount += 1
        return ShortcutProvisioningResult(
            configured: configured,
            observedChord: configured ? binding.chord : nil,
            priorChord: binding.priorChord,
            checkpoint: checkpoint,
            handoffInstruction: instruction
        )
    }

    func remove(binding: ShortcutBinding, application: AppInfo?) throws -> ShortcutProvisioningResult {
        removeCount += 1
        return ShortcutProvisioningResult(
            configured: configured,
            observedChord: binding.priorChord,
            priorChord: binding.priorChord,
            checkpoint: checkpoint,
            handoffInstruction: instruction
        )
    }
}

private final class FakeShortcutKeyboardDispatcher: ShortcutKeyboardDispatching {
    var dispatchCount = 0
    var clearCount = 0
    var onDispatch: () -> Void

    init(onDispatch: @escaping () -> Void = {}) {
        self.onDispatch = onDispatch
    }

    func dispatch(chord: String, application: AppInfo) throws {
        dispatchCount += 1
        onDispatch()
    }

    func clear(application: AppInfo) throws {
        clearCount += 1
    }
}
