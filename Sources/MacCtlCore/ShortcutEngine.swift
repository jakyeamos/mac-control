import Foundation

public final class ShortcutEngine {
    private let store: ShortcutBindingStore
    private let menus: MenuCommandControlling
    private let directExecutor: ShortcutDirectMenuExecuting
    private let provisioner: ShortcutProvisioning
    private let keyboard: ShortcutKeyboardDispatching
    private let resolveApplication: (String) throws -> AppInfo
    private let activateApplication: (String) throws -> AppInfo
    private let foregroundApplication: () -> AppInfo?
    private let warmPaths: WarmPathStore
    private let predicateObserver: ShortcutPredicateObserving
    private let now: () -> Date

    public init(
        store: ShortcutBindingStore = ShortcutBindingStore(),
        menus: MenuCommandControlling = AccessibilityMenuCommandController(),
        directExecutor: ShortcutDirectMenuExecuting? = nil,
        provisioner: ShortcutProvisioning,
        keyboard: ShortcutKeyboardDispatching,
        resolveApplication: @escaping (String) throws -> AppInfo,
        activateApplication: @escaping (String) throws -> AppInfo,
        foregroundApplication: @escaping () -> AppInfo?,
        warmPaths: WarmPathStore = WarmPathStore(),
        predicateObserver: ShortcutPredicateObserving = AccessibilityShortcutPredicateObserver(),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.menus = menus
        self.directExecutor = directExecutor ?? BasicShortcutDirectMenuExecutor(menus: menus)
        self.provisioner = provisioner
        self.keyboard = keyboard
        self.resolveApplication = resolveApplication
        self.activateApplication = activateApplication
        self.foregroundApplication = foregroundApplication
        self.warmPaths = warmPaths
        self.predicateObserver = predicateObserver
        self.now = now
    }

    public func list() -> [ShortcutBinding] { store.list() }

    public func capabilityReport() -> ShortcutCapabilityReport {
        ShortcutCapabilityReport(bindings: store.list(), ownerOnlyStorage: store.ownerOnly())
    }

    public func inspect(id: String) throws -> ShortcutBinding {
        guard let binding = store.binding(id: id) else { throw ShortcutError.bindingNotFound(id) }
        return try refreshed(binding)
    }

    public func inspection(id: String) throws -> ShortcutInspectionReport {
        let binding = try inspect(id: id)
        guard let application = try application(for: binding, activate: false) else {
            return ShortcutInspectionReport(
                binding: binding,
                application: nil,
                menuState: nil,
                observation: "target application is unavailable"
            )
        }
        guard application.isRunning else {
            return ShortcutInspectionReport(
                binding: binding,
                application: application,
                menuState: nil,
                observation: "target application is not running; inspection did not launch it"
            )
        }
        guard binding.target.kind == .appMenu, let path = binding.target.menuPath else {
            return ShortcutInspectionReport(
                binding: binding,
                application: application,
                menuState: nil,
                observation: "target does not expose an app-menu state"
            )
        }
        do {
            return ShortcutInspectionReport(
                binding: binding,
                application: application,
                menuState: try menus.inspect(application: application, path: path),
                observation: "live menu state read without activating or dispatching the command"
            )
        } catch {
            return ShortcutInspectionReport(
                binding: binding,
                application: application,
                menuState: nil,
                observation: "live menu state unavailable: \(error.localizedDescription)"
            )
        }
    }

    public func audit(app name: String?) throws -> ShortcutAuditReport {
        guard let name else {
            let entries = store.list().map { binding in
                ShortcutAuditEntry(
                    target: binding.target,
                    disposition: binding.status == .blocked ? .unsupported : .eligible,
                    reason: binding.lastBlocker ?? binding.status.rawValue,
                    currentChord: binding.chord,
                    suggestedChord: binding.chord,
                    postconditionAvailable: !binding.postconditions.isEmpty,
                    blockerRank: binding.status == .blocked ? 0 : 1
                )
            }
            return ShortcutAuditReport(application: nil, entries: entries, inspectedAt: now(), truncated: false)
        }
        let application = try resolveApplication(name)
        guard application.isRunning, application.processID != nil else {
            let target = CommandTarget.appMenu(
                applicationName: application.name,
                bundleID: application.bundleID,
                menuPath: ["not_running", "not_running"]
            )
            return ShortcutAuditReport(
                application: application,
                entries: [ShortcutAuditEntry(
                    target: target,
                    disposition: .notRunning,
                    reason: "detailed audits inspect running apps only",
                    currentChord: nil,
                    suggestedChord: nil,
                    postconditionAvailable: false,
                    blockerRank: 0
                )],
                inspectedAt: now(),
                truncated: false
            )
        }
        let (items, truncated) = try menus.audit(application: application, maxItems: 512)
        let appChords = items.compactMap(\.keyEquivalent)
        let leafCounts = Dictionary(grouping: items, by: { $0.path.last ?? "" }).mapValues(\.count)
        let bindings = store.list()
        let entries = items.map { item -> ShortcutAuditEntry in
            let target = CommandTarget.appMenu(
                applicationName: application.name,
                bundleID: application.bundleID,
                menuPath: item.path
            )
            let associated = bindings.first { $0.target == target }
            let disposition: ShortcutAuditDisposition
            let reason: String
            if item.hidden || item.dynamic {
                disposition = .unsupported
                reason = item.dynamic ? "dynamic menu item" : "disabled or hidden menu item"
            } else if !item.enabled {
                disposition = .needsPostcondition
                reason = "contextual menu item is currently disabled; explicit proposal requires a declared postcondition and execution-time enablement"
            } else if leafCounts[item.path.last ?? "", default: 0] > 1 {
                disposition = .conflict
                reason = "ambiguous leaf title"
            } else if item.checked == nil {
                disposition = .needsPostcondition
                reason = "no reversible menu state is exposed"
            } else {
                disposition = .eligible
                reason = "stable exact path with a reversible menu state"
            }
            let suggestion = ShortcutCollisionValidator.suggestion(
                provider: .macOSAppShortcut,
                appMenuChords: appChords,
                bindings: bindings
            )
            return ShortcutAuditEntry(
                target: target,
                disposition: disposition,
                reason: associated?.lastBlocker ?? reason,
                currentChord: item.keyEquivalent,
                suggestedChord: suggestion,
                postconditionAvailable: item.checked != nil,
                blockerRank: associated?.status == .blocked ? 0 : (item.keyEquivalent == nil ? 2 : 3)
            )
        }.sorted {
            if $0.blockerRank != $1.blockerRank { return $0.blockerRank < $1.blockerRank }
            return ($0.target.menuPath ?? []).joined(separator: "\u{0}")
                < ($1.target.menuPath ?? []).joined(separator: "\u{0}")
        }
        return ShortcutAuditReport(application: application, entries: entries, inspectedAt: now(), truncated: truncated)
    }

    @discardableResult
    public func propose(
        target: CommandTarget,
        requestedChord: String?,
        postconditions declaredPostconditions: [TaskPredicate] = []
    ) throws -> ShortcutBinding {
        try target.validate()
        let provider: ShortcutProvider = target.kind == .appMenu
            ? .macOSAppShortcut
            : .chromeExtensionCommand
        var applicationFingerprint: ShortcutApplicationFingerprint?
        var postconditions: [TaskPredicate] = declaredPostconditions
        var appChords: [String] = []
        var priorChord: String?

        if target.kind == .appMenu {
            let application = try resolveApplication(target.applicationIdentity)
            guard application.isRunning else { throw ShortcutError.appNotRunning(application.name) }
            guard let path = target.menuPath else { throw ShortcutError.invalidTarget("menu path missing") }
            let item = try menus.inspect(application: application, path: path)
            guard !item.hidden else { throw ShortcutError.menuItemDisabled(path) }
            guard !item.dynamic else { throw ShortcutError.dynamicMenuItem(path) }
            if !item.enabled, declaredPostconditions.isEmpty {
                throw ShortcutError.verificationUnavailable(
                    "contextual menu item is currently disabled; declare a behavior postcondition before provisioning it"
                )
            }
            let audited = try menus.audit(application: application, maxItems: 512).0
            appChords = audited.compactMap(\.keyEquivalent)
            priorChord = item.keyEquivalent
            if let priorChord,
               let index = appChords.firstIndex(where: {
                   (try? ShortcutChord($0).canonical) == (try? ShortcutChord(priorChord).canonical)
               }) {
                appChords.remove(at: index)
            }
            applicationFingerprint = ShortcutApplicationFingerprint(application: application)
            if item.checked != nil, postconditions.isEmpty {
                postconditions = [TaskPredicate(
                    kind: .menuItemState,
                    expected: "toggled",
                    application: application.name,
                    bundleID: application.bundleID,
                    parameters: ["menu_path": .array(path.map(JSONValue.string))]
                )]
            }
        }
        let id = ShortcutDigests.bindingID(for: target)
        try validate(postconditions: postconditions, bindingID: id)
        let chordRaw = requestedChord ?? priorChord ?? ShortcutCollisionValidator.suggestion(
            provider: provider,
            appMenuChords: appChords,
            bindings: store.list()
        )
        let chord = try chordRaw.map { try ShortcutChord($0, provider: provider) }
        if let chord {
            let collision = ShortcutCollisionValidator.validate(
                chord: chord,
                targetBindingID: id,
                appMenuChords: appChords,
                bindings: store.list()
            )
            guard !collision.hasConflict else { throw ShortcutError.conflict(chord.canonical) }
        }
        return try store.save(ShortcutBinding(
            id: id,
            target: target,
            chord: chord?.canonical,
            provider: provider,
            priorChord: priorChord,
            postconditions: postconditions,
            applicationFingerprint: applicationFingerprint,
            status: priorChord != nil && requestedChord == nil ? .configured : .proposed,
            evidence: ShortcutEvidenceTimestamps(
                configuredAt: priorChord != nil && requestedChord == nil ? now() : nil,
                lastInspectedAt: now()
            )
        ))
    }

    @discardableResult
    public func setup(id: String) throws -> ShortcutSetupReport {
        let binding = try inspect(id: id)
        let application = try application(for: binding, activate: true)
        let result = try provisioner.setup(binding: binding, application: application)
        let status: ShortcutStatus = result.configured ? .configured : .setupRequired
        let updated = binding.updating(
            priorChord: .some(result.priorChord),
            status: status,
            configuredAt: result.configured ? .some(now()) : nil,
            inspectedAt: .some(now()),
            setupCheckpoint: .some(result.checkpoint),
            blocker: .some(result.handoffInstruction)
        )
        _ = try store.save(updated)
        return ShortcutSetupReport(
            bindingID: id,
            status: status,
            configuredChord: result.observedChord,
            handoffRequired: !result.configured,
            checkpoint: result.checkpoint,
            instruction: result.handoffInstruction
        )
    }

    public func run(id: String, requestedRoute: ShortcutRunRoute? = nil) throws -> ShortcutRunReport {
        var binding = try inspect(id: id)
        let application = try application(for: binding, activate: true)
        guard let application else { throw ShortcutError.unsupported("target application is unavailable") }
        let route = requestedRoute ?? (binding.target.kind == .appMenu ? .accessibility : .keyboard)
        if binding.target.kind == .chromeExtension && route != .keyboard {
            throw ShortcutError.unsupported("Chrome extension commands are keyboard-only")
        }
        let started = Date()
        var beforeMenu: MenuCommandSnapshot?
        var afterMenu: MenuCommandSnapshot?
        switch route {
        case .accessibility:
            guard binding.target.kind == .appMenu, let path = binding.target.menuPath else {
                throw ShortcutError.unsupported("Accessibility route requires an app menu target")
            }
            let result = try directExecutor.execute(application: application, path: path)
            beforeMenu = result.before
            afterMenu = result.after
        case .keyboard:
            guard [.configured, .behaviorVerified].contains(binding.status), let chord = binding.chord else {
                throw ShortcutError.setupRequired
            }
            if binding.target.kind == .appMenu, let path = binding.target.menuPath {
                beforeMenu = try? menus.inspect(application: application, path: path)
            }
            try keyboard.dispatch(chord: chord, application: application)
            if binding.target.kind == .appMenu, let path = binding.target.menuPath {
                afterMenu = waitForMenuChange(application: application, path: path, before: beforeMenu)
            }
        }
        let verified = (try? evaluate(
            binding.postconditions,
            application: application,
            beforeMenu: beforeMenu,
            afterMenu: afterMenu
        )) ?? false
        let latency = max(0, Date().timeIntervalSince(started) * 1_000)
        guard verified else {
            binding = binding.updating(
                status: binding.status == .behaviorVerified ? .configured : nil,
                inspectedAt: .some(now()),
                blocker: .some("postcondition did not pass; command was not retried")
            )
            _ = try store.save(binding)
            return ShortcutRunReport(
                bindingID: id,
                route: route,
                verification: "verification_unavailable",
                latencyMs: latency,
                status: binding.status,
                noRetry: true,
                beforeMenuState: beforeMenu,
                afterMenuState: afterMenu
            )
        }
        binding = binding.updating(
            status: .behaviorVerified,
            behaviorVerifiedAt: .some(now()),
            inspectedAt: .some(now()),
            blocker: .some(nil)
        )
        _ = try store.save(binding)
        let targetFingerprint = ShortcutDigests.digest(ShortcutTargetFingerprint(
            target: binding.target,
            chord: binding.chord,
            postconditionFingerprint: binding.postconditionFingerprint
        ))
        _ = try? warmPaths.recordBenchmark(
            application: application,
            taskID: "shortcut.\(binding.id)",
            targetFingerprint: targetFingerprint,
            verificationOracle: binding.postconditionFingerprint,
            route: route == .accessibility ? .accessibility : .keyboard,
            requiredPermissions: route == .accessibility ? ["Accessibility"] : ["Accessibility", "Post Events"],
            latencyMs: latency,
            p95LatencyMs: latency,
            verificationRate: 1,
            samples: 1
        )
        return ShortcutRunReport(
            bindingID: id,
            route: route,
            verification: "passed",
            latencyMs: latency,
            status: .behaviorVerified,
            noRetry: true,
            beforeMenuState: beforeMenu,
            afterMenuState: afterMenu
        )
    }

    public func remove(id: String) throws -> ShortcutSetupReport {
        let binding = try inspect(id: id)
        if [.proposed, .setupRequired].contains(binding.status), binding.evidence.configuredAt == nil {
            _ = try store.remove(id: id)
            return ShortcutSetupReport(
                bindingID: id,
                status: .proposed,
                configuredChord: nil,
                handoffRequired: false,
                checkpoint: "unconfigured_binding_removed",
                instruction: nil
            )
        }
        let application = try application(for: binding, activate: true)
        let result = try provisioner.remove(binding: binding, application: application)
        guard result.configured else {
            let blocked = binding.updating(
                status: .blocked,
                inspectedAt: .some(now()),
                setupCheckpoint: .some(result.checkpoint),
                blocker: .some(result.handoffInstruction)
            )
            _ = try store.save(blocked)
            return ShortcutSetupReport(
                bindingID: id,
                status: .blocked,
                configuredChord: result.observedChord,
                handoffRequired: true,
                checkpoint: result.checkpoint,
                instruction: result.handoffInstruction
            )
        }
        _ = try store.remove(id: id)
        return ShortcutSetupReport(
            bindingID: id,
            status: .proposed,
            configuredChord: result.observedChord,
            handoffRequired: false,
            checkpoint: result.checkpoint,
            instruction: nil
        )
    }

    private func refreshed(_ binding: ShortcutBinding) throws -> ShortcutBinding {
        guard let application = try application(for: binding, activate: false) else { return binding }
        if let fingerprint = binding.applicationFingerprint, !fingerprint.matches(application) {
            let stale = binding.updating(
                status: .stale,
                inspectedAt: .some(now()),
                blocker: .some("application identity or version changed")
            )
            return try store.save(stale)
        }
        if binding.target.kind == .appMenu, let path = binding.target.menuPath, application.isRunning {
            do {
                _ = try menus.inspect(application: application, path: path)
            } catch {
                let stale = binding.updating(
                    status: .stale,
                    inspectedAt: .some(now()),
                    blocker: .some("menu path drifted")
                )
                return try store.save(stale)
            }
        }
        return binding
    }

    private func application(for binding: ShortcutBinding, activate: Bool) throws -> AppInfo? {
        let identity = binding.target.applicationIdentity
        if activate { return try activateApplication(identity) }
        return try resolveApplication(identity)
    }

    private func validate(postconditions: [TaskPredicate], bindingID: String) throws {
        guard !postconditions.isEmpty else { return }
        let action = ActionSpec(
            kind: .command,
            surface: .macApp,
            parameters: [
                "binding_id": .string(bindingID),
                "binding_digest": .string(String(repeating: "0", count: 64)),
                "operation": .string("run")
            ]
        )
        let validation = TaskPlanValidator.validate(TaskPlan(
            id: "shortcut-predicate-validation",
            name: "Shortcut predicate validation",
            summary: "Validate declared shortcut postconditions",
            steps: [TaskStep(
                id: "command",
                action: action,
                postconditions: postconditions,
                risk: .sensitive,
                approvalReason: "Validate shortcut command authority",
                recovery: TaskRecoveryPolicy(mode: "strict", maxAttempts: 1)
            )],
            totalTimeout: 30
        ))
        guard validation.valid else {
            throw ShortcutError.invalidTarget(validation.errors.joined(separator: "; "))
        }
    }

    private func waitForMenuChange(
        application: AppInfo,
        path: [String],
        before: MenuCommandSnapshot?
    ) -> MenuCommandSnapshot? {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            if let observed = try? menus.inspect(application: application, path: path),
               observed.checked != before?.checked {
                return observed
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        } while Date() < deadline
        return try? menus.inspect(application: application, path: path)
    }

    private func evaluate(
        _ predicates: [TaskPredicate],
        application: AppInfo,
        beforeMenu: MenuCommandSnapshot?,
        afterMenu: MenuCommandSnapshot?
    ) throws -> Bool {
        guard !predicates.isEmpty else { return false }
        for predicate in predicates {
            let passed: Bool
            switch predicate.kind {
            case .menuItemState:
                switch predicate.expected {
                case "toggled":
                    // AppKit commonly exposes a mark character only while a menu item is checked.
                    // Treat a missing mark as the unchecked side only when the paired observation
                    // contains a mark; two missing values remain indeterminate and cannot verify.
                    if let beforeMenu, let afterMenu,
                       beforeMenu.checked != nil || afterMenu.checked != nil {
                        passed = (beforeMenu.checked ?? false) != (afterMenu.checked ?? false)
                    } else { passed = false }
                case "checked": passed = afterMenu?.checked == true
                case "unchecked": passed = afterMenu?.checked == false
                case "enabled": passed = afterMenu?.enabled == true
                case "disabled": passed = afterMenu?.enabled == false
                default: passed = false
                }
            case .foregroundApplication:
                if let foreground = foregroundApplication() {
                    passed = foreground.bundleID == (predicate.bundleID ?? application.bundleID)
                        || foreground.name == (predicate.application ?? predicate.expected ?? application.name)
                } else {
                    passed = false
                }
            case .applicationRunning:
                passed = application.isRunning
            case .focusedElement, .elementExists, .windowVisible, .adapterState, .modalAbsent, .focusReadable:
                passed = try predicateObserver.evaluate(predicate: predicate, application: application)
            }
            if !passed { return false }
        }
        return true
    }
}

private struct ShortcutTargetFingerprint: Codable {
    let target: CommandTarget
    let chord: String?
    let postconditionFingerprint: String
}
