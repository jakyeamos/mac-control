import CoreGraphics
import Foundation
import XCTest
@testable import MacCtlCore

final class AdvertisedCapabilityTests: XCTestCase {
    func testFastProbeProjectsDiscordAdvertisementsWithoutWalkingAX() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-discord-advertisements-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = discordApp()
        let inspector = AdvertisedCapabilityTreeInspector(
            report: discordTree(app: app, labels: ["This tree must not be read by the fast probe"])
        )
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            capabilityProfileStore: CapabilityProfileStore(directory: directory),
            accessibilityTreeInspector: inspector
        )

        let response = service.handle(RequestEnvelope(
            method: "control.capabilities",
            params: ["app": .string("Discord")]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(inspector.treeCallCount, 0)
        let advertisements = try XCTUnwrap(response.result["advertisedCapabilities"]?.arrayValue)
        XCTAssertEqual(advertisements.count, 3)
        XCTAssertTrue(advertisements.allSatisfy {
            $0.objectValue?["authority"]?.stringValue == "candidate_only"
        })
        XCTAssertEqual(response.result["freshMeasuredRoutes"]?.arrayValue, [])
    }

    func testDiscordOverlayDeclaresCapabilitiesWithoutGrantingRouteAuthority() throws {
        let identity = discordIdentity()
        let profile = ControlCapabilityProfile(application: identity)

        XCTAssertEqual(profile.schemaVersion, 5)
        XCTAssertEqual(profile.archetype, .electronChromium)
        XCTAssertTrue(profile.profileLayers.contains("app:discord"))
        XCTAssertEqual(
            Set(profile.advertisedCapabilities.map(\.id)),
            Set([
                "discord.keyboard_navigation",
                "discord.shortcut_catalog",
                "discord.quick_switcher"
            ])
        )
        XCTAssertTrue(profile.advertisedCapabilities.allSatisfy { $0.authority == .candidateOnly })
        XCTAssertEqual(
            profile.advertisedCapabilities.first { $0.id == "discord.quick_switcher" }?.keyboardShortcut,
            "cmd+k"
        )
        XCTAssertTrue(profile.freshMeasuredRoutes.isEmpty)

        let taskProfile = ControlCapabilityProfile(
            application: identity,
            taskID: "discord.quick_switcher"
        )
        XCTAssertEqual(taskProfile.preferredProviders.first, .keyboard)
        XCTAssertTrue(taskProfile.freshMeasuredRoutes.isEmpty)
    }

    func testDeepAuditDiscoversDiscordAdvertisementsAsRedactedCandidates() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let app = discordApp()
        let profile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: CapabilityProviderState(observedProviders: ["accessibility", "keyboard"]),
            tree: discordTree(
                app: app,
                labels: [
                    "You can navigate Discord with your tab and arrow keys just fine.",
                    "List of keyboard shortcuts",
                    "Open the Quick Switcher - it is the fastest way to move around!"
                ]
            ),
            now: now
        )

        let observations = try XCTUnwrap(profile.advertisedCapabilities)
        XCTAssertEqual(observations.count, 3)
        XCTAssertTrue(observations.allSatisfy { $0.discoveryState == .observed })
        XCTAssertTrue(observations.allSatisfy { $0.disposition == .candidate })
        XCTAssertTrue(observations.allSatisfy { !$0.locatorDigests.isEmpty })
        XCTAssertFalse(profile.capabilities.contains {
            $0.id.hasPrefix("discord.") && $0.state == .promoted
        })

        let summary = CapabilityProfileCacheSummary(profile: profile, cacheHit: true)
        XCTAssertEqual(summary.advertisedCapabilities.count, 3)
        XCTAssertFalse(summary.promotedCapabilities.contains { $0.hasPrefix("discord.") })

        let encoded = String(decoding: try JSONCodec.encode(profile), as: UTF8.self)
        XCTAssertFalse(encoded.lowercased().contains("navigate discord"))
        XCTAssertFalse(encoded.lowercased().contains("fastest way to move around"))
        XCTAssertTrue(encoded.contains("discord.quick_switcher"))
    }

    func testDeepAuditRecordsSystemSettingsPresentationOnlyRowForProviderHandoff() throws {
        let app = AppInfo(
            name: "System Settings",
            bundleID: "com.apple.systemsettings",
            path: "/System/Applications/System Settings.app",
            isRunning: true,
            processID: 44,
            bundleVersion: "15.0"
        )
        let state = AccessibilityTreeNodeState(
            enabled: true,
            focused: false,
            selected: false,
            expanded: nil,
            visible: true,
            settable: false,
            hasValue: false
        )
        let row = AccessibilityTreeNode(
            path: "0/1/3",
            depth: 3,
            role: "AXRow",
            subrole: "AXOutlineRow",
            identifier: nil,
            label: nil,
            actions: [
                AccessibilityController.showAlternateUIAction,
                AccessibilityController.showDefaultUIAction
            ],
            state: state,
            bounds: CGRect(x: 0, y: 100, width: 250, height: 32),
            childCount: 1,
            scrollable: false
        )
        let tree = AccessibilityTreeReport(
            application: app,
            maxNodes: 500,
            maxDepth: 12,
            nodeCount: 1,
            truncated: false,
            nodes: [row],
            identifierMatchCounts: [:],
            nameMatchCounts: [:]
        )

        let profile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS 15.0",
            providerState: CapabilityProviderState(observedProviders: ["accessibility"]),
            tree: tree
        )
        let activation = try XCTUnwrap(profile.capabilities.first { $0.id == "ax_activation" })
        let presentation = try XCTUnwrap(profile.capabilities.first { $0.id == "ax_presentation" })

        XCTAssertEqual(activation.state, .demoted)
        XCTAssertEqual(activation.positiveEvidenceCount, 0)
        XCTAssertTrue(activation.locatorDigests.isEmpty)
        XCTAssertEqual(presentation.state, .promoted)
        XCTAssertEqual(presentation.positiveEvidenceCount, 1)
        XCTAssertEqual(presentation.locatorDigests.count, 1)
        XCTAssertTrue(profile.locators.contains {
            $0.actions.contains(AccessibilityController.showDefaultUIAction)
        })
        XCTAssertEqual(
            profile.capabilities.first { $0.id == "ax_press" }?.state,
            .demoted
        )
    }

    func testPartialDiscordAdvertisementRemainsAmbiguousCandidate() throws {
        let app = discordApp()
        let profile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: CapabilityProviderState(observedProviders: ["accessibility"]),
            tree: discordTree(app: app, labels: ["Open the Quick Switcher"])
        )

        let observation = try XCTUnwrap(
            profile.advertisedCapabilities?.first { $0.capabilityID == "discord.quick_switcher" }
        )
        XCTAssertEqual(observation.discoveryState, .partial)
        XCTAssertEqual(observation.matchedSignalCount, 1)
        XCTAssertEqual(observation.requiredSignalCount, 2)
        XCTAssertEqual(observation.disposition, .candidate)
    }

    func testAbsentDiscordDisclosureIsNotNegativeCapabilityEvidence() {
        let app = discordApp()
        let profile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: CapabilityProviderState(observedProviders: ["accessibility"]),
            tree: discordTree(app: app, labels: ["Friends", "Direct Messages"])
        )

        XCTAssertEqual(profile.advertisedCapabilities, [])
        XCTAssertFalse(profile.capabilities.contains { $0.id.hasPrefix("discord.") })
    }

    func testUnknownAppDiscoversGenericCapabilityLeadsWithoutOverlay() throws {
        XCTAssertEqual(
            CapabilityProfileBuilder.extractKeyboardShortcuts(from: "Open the Quick Switcher ⌘ K"),
            ["cmd+k"]
        )
        let app = genericApp()
        let profile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: CapabilityProviderState(observedProviders: ["accessibility", "keyboard"]),
            tree: capabilityTree(
                app: app,
                nodes: [
                    ("AXStaticText", "onboarding-quick-switcher", "Open the Quick Switcher"),
                    ("AXStaticText", "keycap-command", "⌘"),
                    ("AXStaticText", "keycap-k", "K"),
                    ("AXStaticText", "help-shortcuts", "Press Command-/ to view keyboard shortcuts"),
                    ("AXStaticText", "accessibility-guide", "Navigate with Tab and arrow keys")
                ]
            )
        )

        let leads = try XCTUnwrap(profile.capabilityLeads)
        XCTAssertEqual(Set(leads.map(\.kind)), Set([
            .quickSwitcher,
            .shortcutCatalog,
            .keyboardNavigation
        ]))
        let quickSwitcher = try XCTUnwrap(leads.first { $0.kind == .quickSwitcher })
        XCTAssertEqual(quickSwitcher.keyboardShortcut, "cmd+k")
        XCTAssertEqual(quickSwitcher.confidence, .high)
        XCTAssertEqual(quickSwitcher.disposition, .candidate)
        XCTAssertTrue(quickSwitcher.matchedAdvertisedCapabilityIDs.isEmpty)
        XCTAssertTrue(quickSwitcher.taskIDs.contains("open-quick-switcher"))
        XCTAssertFalse(profile.capabilities.contains {
            $0.id == quickSwitcher.leadID && $0.state == .promoted
        })

        let encoded = String(decoding: try JSONCodec.encode(profile), as: UTF8.self).lowercased()
        XCTAssertFalse(encoded.contains("open the quick switcher"))
        XCTAssertFalse(encoded.contains("navigate with tab"))
        XCTAssertFalse(encoded.contains("view keyboard shortcuts"))
    }

    func testGenericDiscoveryIgnoresCapabilityWordsInUntrustedContent() {
        let app = genericApp()
        let profile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: CapabilityProviderState(observedProviders: ["accessibility"]),
            tree: capabilityTree(
                app: app,
                nodes: [
                    ("AXStaticText", "message-content", "Press Command-K to open the Quick Switcher")
                ]
            )
        )

        XCTAssertEqual(profile.capabilityLeads, [])
    }

    func testGenericDiscoveryKeepsConflictingShortcutsAmbiguous() throws {
        let app = genericApp()
        let profile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: CapabilityProviderState(observedProviders: ["accessibility"]),
            tree: capabilityTree(
                app: app,
                nodes: [
                    ("AXStaticText", "help-quick-switcher", "Open Quick Switcher with Command-K or Command-P")
                ]
            )
        )

        let lead = try XCTUnwrap(profile.capabilityLeads?.first)
        XCTAssertEqual(lead.kind, .quickSwitcher)
        XCTAssertEqual(lead.confidence, .ambiguous)
        XCTAssertNil(lead.keyboardShortcut)
        XCTAssertEqual(lead.disposition, .candidate)
    }

    func testTaskVerificationPromotesAndDemotesMatchingGenericLead() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-generic-lead-verification-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 20_000)
        let store = CapabilityProfileStore(directory: directory, now: { now })
        let app = genericApp()
        let providerState = CapabilityProviderState(observedProviders: ["accessibility", "keyboard"])
        let profile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: providerState,
            tree: capabilityTree(
                app: app,
                nodes: [
                    ("AXButton", "quick-switcher", "Open Quick Switcher Command-K")
                ]
            ),
            now: now
        )
        _ = try store.save(profile)

        let promoted = try store.recordTaskVerification(
            application: app,
            osVersion: "macOS Test",
            providerState: providerState,
            taskID: "open-quick-switcher",
            targetFingerprint: "quick-switcher-target",
            route: .keyboard,
            selector: nil,
            kind: .positive,
            reason: "verified_action"
        )
        let promotedLead = try XCTUnwrap(promoted?.capabilityLeads?.first)
        XCTAssertEqual(promotedLead.disposition, .promoted)
        XCTAssertEqual(promotedLead.positiveEvidenceCount, 1)

        let demoted = try store.recordTaskVerification(
            application: app,
            osVersion: "macOS Test",
            providerState: providerState,
            taskID: "open-quick-switcher",
            targetFingerprint: "quick-switcher-target",
            route: .keyboard,
            selector: nil,
            kind: .negative,
            reason: "verification_failed"
        )
        let demotedLead = try XCTUnwrap(demoted?.capabilityLeads?.first)
        XCTAssertEqual(demotedLead.disposition, .demoted)
        XCTAssertEqual(demotedLead.negativeEvidenceCount, 1)
        XCTAssertEqual(demoted?.state, .stale)
        XCTAssertTrue(demoted?.invalidationReasons.contains(.verificationFailed) == true)
    }

    func testTreeChangeInvalidatesGenericLeadProfile() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-generic-lead-invalidation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CapabilityProfileStore(directory: directory)
        let app = genericApp()
        let providerState = CapabilityProviderState(observedProviders: ["accessibility"])
        let first = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: providerState,
            tree: capabilityTree(
                app: app,
                nodes: [("AXButton", "quick-switcher", "Open Quick Switcher Command-K")]
            )
        )
        _ = try store.save(first)
        let second = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: providerState,
            tree: capabilityTree(
                app: app,
                nodes: [
                    ("AXButton", "quick-switcher", "Open Quick Switcher Command-K"),
                    ("AXButton", "settings", "Settings")
                ]
            )
        )
        _ = try store.save(second)

        let invalidated = try XCTUnwrap(store.list().first {
            $0.identity.treeSignature == first.identity.treeSignature
        })
        XCTAssertEqual(invalidated.state, .invalidated)
        XCTAssertTrue(invalidated.invalidationReasons.contains(.treeChanged))
        XCTAssertEqual(invalidated.capabilityLeads?.first?.kind, .quickSwitcher)
    }

    func testFastProbeReadsCachedGenericLeadsWithoutWalkingAX() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-generic-lead-fast-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CapabilityProfileStore(directory: directory)
        let app = genericApp()
        let tree = capabilityTree(
            app: app,
            nodes: [("AXButton", "command-palette", "Open Command Palette Command-P")]
        )
        _ = try store.save(CapabilityProfileBuilder.build(
            application: app,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            providerState: CapabilityProviderState(
                permissionStatuses: PermissionDiagnostics.unknownReport()
            ),
            tree: tree
        ))
        let inspector = AdvertisedCapabilityTreeInspector(report: tree)
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            capabilityProfileStore: store,
            accessibilityTreeInspector: inspector
        )

        let response = service.handle(RequestEnvelope(
            method: "control.capabilities",
            params: ["app": .string("Example")]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(inspector.treeCallCount, 0)
        let cached = try XCTUnwrap(response.result["cachedBroadProfile"]?.objectValue)
        XCTAssertEqual(cached["capabilityLeads"]?.arrayValue?.count, 1)
    }

    func testLegacyCapabilityProfileWithoutAdvertisementFieldStillDecodes() throws {
        let app = discordApp()
        let profile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: CapabilityProviderState(observedProviders: ["accessibility"]),
            tree: discordTree(app: app, labels: ["Friends"])
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONCodec.encode(profile)) as? [String: Any]
        )
        object.removeValue(forKey: "advertisedCapabilities")
        object.removeValue(forKey: "capabilityLeads")

        let decoded = try JSONCodec.decode(
            CapabilityAuditProfile.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.advertisedCapabilities)
        XCTAssertNil(decoded.capabilityLeads)
    }

    private func discordIdentity() -> WarmPathApplicationIdentity {
        WarmPathApplicationIdentity(
            name: "Discord",
            bundleID: "com.hnc.Discord",
            path: "/Applications/Discord.app",
            version: "1"
        )
    }

    private func discordApp() -> AppInfo {
        AppInfo(
            name: "Discord",
            bundleID: "com.hnc.Discord",
            path: "/Applications/Discord.app",
            isRunning: true,
            processID: 42,
            bundleVersion: "1"
        )
    }

    private func genericApp() -> AppInfo {
        AppInfo(
            name: "Example",
            bundleID: "com.example.productivity",
            path: "/Applications/Example.app",
            isRunning: true,
            processID: 43,
            bundleVersion: "1"
        )
    }

    private func capabilityTree(
        app: AppInfo,
        nodes descriptors: [(role: String, identifier: String, label: String)]
    ) -> AccessibilityTreeReport {
        let state = AccessibilityTreeNodeState(
            enabled: true,
            focused: false,
            selected: false,
            expanded: nil,
            visible: true,
            settable: false,
            hasValue: false
        )
        let nodes = descriptors.enumerated().map { index, descriptor in
            AccessibilityTreeNode(
                path: "0/\(index)",
                depth: 1,
                role: descriptor.role,
                subrole: nil,
                identifier: descriptor.identifier,
                label: descriptor.label,
                actions: descriptor.role == "AXButton" ? ["AXPress"] : [],
                state: state,
                bounds: CGRect(x: 0, y: CGFloat(index * 30), width: 600, height: 24),
                childCount: 0,
                scrollable: false
            )
        }
        return AccessibilityTreeReport(
            application: app,
            maxNodes: 500,
            maxDepth: 8,
            nodeCount: nodes.count,
            truncated: false,
            nodes: nodes,
            identifierMatchCounts: Dictionary(uniqueKeysWithValues: nodes.compactMap {
                $0.identifier.map { ($0, 1) }
            }),
            nameMatchCounts: Dictionary(uniqueKeysWithValues: nodes.compactMap {
                $0.label.map { ($0, 1) }
            })
        )
    }

    private func discordTree(app: AppInfo, labels: [String]) -> AccessibilityTreeReport {
        let state = AccessibilityTreeNodeState(
            enabled: true,
            focused: false,
            selected: false,
            expanded: nil,
            visible: true,
            settable: false,
            hasValue: false
        )
        let nodes = labels.enumerated().map { index, label in
            AccessibilityTreeNode(
                path: "0/\(index)",
                depth: 1,
                role: "AXStaticText",
                subrole: nil,
                identifier: "discord-disclosure-\(index)",
                label: label,
                actions: [],
                state: state,
                bounds: CGRect(x: 0, y: CGFloat(index * 30), width: 600, height: 24),
                childCount: 0,
                scrollable: false
            )
        }
        return AccessibilityTreeReport(
            application: app,
            maxNodes: 500,
            maxDepth: 8,
            nodeCount: nodes.count,
            truncated: false,
            nodes: nodes,
            identifierMatchCounts: Dictionary(
                uniqueKeysWithValues: nodes.compactMap { node in
                    node.identifier.map { ($0, 1) }
                }
            ),
            nameMatchCounts: Dictionary(uniqueKeysWithValues: labels.map { ($0, 1) })
        )
    }
}

private final class AdvertisedCapabilityTreeInspector: AccessibilityTreeInspecting {
    let report: AccessibilityTreeReport
    private(set) var treeCallCount = 0

    init(report: AccessibilityTreeReport) {
        self.report = report
    }

    func tree(
        pid: pid_t,
        application: AppInfo,
        maxNodes: Int,
        maxDepth: Int
    ) throws -> AccessibilityTreeReport {
        treeCallCount += 1
        return report
    }

    func audit(
        pid: pid_t,
        application: AppInfo,
        manifest: AccessibilityAuditManifest
    ) throws -> AccessibilityAuditReport {
        AccessibilityAuditEngine.audit(tree: report, manifest: manifest)
    }
}
