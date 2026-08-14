import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MacCtlCore

final class MacCtlCoreTests: XCTestCase {
    func testRequestAndResponseUseSnakeCaseEnvelopeKeys() throws {
        let request = RequestEnvelope(
            requestID: "request-1",
            method: "status",
            params: ["mode": .string("json")]
        )
        let requestData = try JSONCodec.encode(request)
        let requestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        XCTAssertEqual(requestObject["schema_version"] as? Int, 1)
        XCTAssertEqual(requestObject["request_id"] as? String, "request-1")
        XCTAssertNil(requestObject["schemaVersion"])

        let response = ResponseEnvelope(requestID: "request-1", status: .succeeded)
        let responseData = try JSONCodec.encode(response)
        let responseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        XCTAssertEqual(responseObject["operation_id"] is String, true)
        XCTAssertEqual(responseObject["status"] as? String, "succeeded")
    }

    func testNestedJSONValuesUseTheWireDateEncodingStrategy() throws {
        let value = try JSONValue.fromEncodable(
            ["created_at": Date(timeIntervalSince1970: 1_700_000_000)]
        )
        XCTAssertEqual(value["created_at"]?.stringValue, "2023-11-14T22:13:20Z")
    }

    func testSelectorAddressabilityIsDescriptiveMetadata() {
        XCTAssertEqual(
            Selector(title: "Save", normalizedX: 0.5, normalizedY: 0.5).addressability,
            .accessibility
        )
        XCTAssertEqual(
            Selector(containsText: "Save", normalizedX: 0.5, normalizedY: 0.5).addressability,
            .visual
        )
        XCTAssertEqual(
            Selector(normalizedX: 0.5, normalizedY: 0.5).addressability,
            .normalizedCoordinate
        )
        XCTAssertEqual(Selector(rawX: 100, rawY: 200).addressability, .rawCoordinate)
        XCTAssertEqual(Selector(locatorDigest: "audit-locator").addressability, .accessibility)
        XCTAssertTrue(Selector(locatorDigest: "audit-locator").hasTarget)
    }

    func testAuditLocatorDigestRoundTripsIntoActionSelectors() throws {
        let node = AccessibilityTreeNode(
            path: "0/4",
            depth: 2,
            role: "AXPopUpButton",
            subrole: nil,
            identifier: nil,
            label: "Target branch for browser-control",
            actions: ["AXPress", "AXShowMenu"],
            state: AccessibilityTreeNodeState(
                enabled: true,
                focused: false,
                selected: false,
                expanded: nil,
                visible: true,
                settable: false,
                hasValue: true
            ),
            bounds: nil,
            childCount: 0,
            scrollable: false
        )
        let auditLocator = try XCTUnwrap(CapabilityLocatorDescriptor.from(treeNode: node))
        let selector = Selector(
            role: auditLocator.role,
            locatorDigest: auditLocator.identityDigest
        )
        let actionLocator = try XCTUnwrap(
            CapabilityLocatorDescriptor.from(selector: selector, route: .accessibility)
        )

        XCTAssertEqual(actionLocator.identityDigest, auditLocator.identityDigest)
        XCTAssertEqual(
            try JSONCodec.decode(Selector.self, from: JSONCodec.encode(selector)),
            selector
        )
    }

    func testWindowScopedSelectorRoundTripsAndRemainsAccessibilityAddressable() throws {
        let selector = Selector(
            role: "AXButton",
            identifier: "tab-group",
            title: "Group tabs",
            windowTitle: "Project - Google Chrome",
            windowIdentifier: "main-window"
        )

        XCTAssertEqual(selector.addressability, .accessibility)
        XCTAssertTrue(selector.hasTarget)
        XCTAssertEqual(
            try JSONCodec.decode(Selector.self, from: JSONCodec.encode(selector)),
            selector
        )
    }

    func testWarmPathSelectionChoosesFreshMeasuredWinnerAndDeclaredFallbacks() {
        let now = Date(timeIntervalSince1970: 1_000)
        let identity = WarmPathApplicationIdentity(
            name: "Chrome",
            bundleID: "com.google.Chrome",
            path: "/Applications/Google Chrome.app",
            version: "1"
        )
        let manifest = WarmPathManifest(
            application: identity,
            taskID: "activate-save",
            targetFingerprint: "save-button-v1",
            verificationOracle: "focused-save-confirmation",
            candidates: [
                RouteCandidate(
                    route: .keyboard,
                    requiredPermissions: ["Accessibility"],
                    measuredEndToEndLatencyMs: 40,
                    measuredP95LatencyMs: 60,
                    verificationRate: 1,
                    recoveries: 1,
                    sampleCount: 5,
                    freshUntil: now.addingTimeInterval(60)
                ),
                RouteCandidate(
                    route: .accessibility,
                    requiredPermissions: ["Accessibility"],
                    measuredEndToEndLatencyMs: 12,
                    measuredP95LatencyMs: 18,
                    verificationRate: 1,
                    recoveries: 0,
                    sampleCount: 5,
                    freshUntil: now.addingTimeInterval(60),
                    declaredFallbackRoutes: [.keyboard]
                )
            ],
            updatedAt: now
        )

        let report = WarmPathSelection.select(
            manifest: manifest,
            context: WarmPathSelectionContext(
                application: identity,
                targetFingerprint: "save-button-v1",
                grantedPermissions: ["Accessibility"],
                now: now
            )
        )

        XCTAssertEqual(report.selectedRoute, .accessibility)
        XCTAssertEqual(report.fallbackChain, [.keyboard])
        XCTAssertTrue(report.assessments.allSatisfy(\.eligible))
    }

    func testWarmPathSelectionRejectsStaleVersionAmbiguousAndUnoptedVisualRoutes() {
        let now = Date(timeIntervalSince1970: 2_000)
        let manifestIdentity = WarmPathApplicationIdentity(
            name: "Preview",
            bundleID: "com.apple.Preview",
            path: "/System/Applications/Preview.app",
            version: "1"
        )
        let manifest = WarmPathManifest(
            application: manifestIdentity,
            taskID: "open-item",
            targetFingerprint: "item-v1",
            verificationOracle: "item-visible",
            candidates: [
                RouteCandidate(
                    route: .visual,
                    measuredEndToEndLatencyMs: 20,
                    measuredP95LatencyMs: 30,
                    verificationRate: 1,
                    sampleCount: 3,
                    freshUntil: now.addingTimeInterval(60)
                ),
                RouteCandidate(
                    route: .keyboard,
                    measuredEndToEndLatencyMs: 20,
                    measuredP95LatencyMs: 30,
                    verificationRate: 1,
                    sampleCount: 3,
                    freshUntil: now.addingTimeInterval(-1)
                )
            ],
            updatedAt: now
        )
        let report = WarmPathSelection.select(
            manifest: manifest,
            context: WarmPathSelectionContext(
                application: WarmPathApplicationIdentity(
                    name: "Preview",
                    bundleID: "com.apple.Preview",
                    path: "/System/Applications/Preview.app",
                    version: "2"
                ),
                targetFingerprint: "item-v1",
                targetIsUnique: false,
                now: now
            )
        )

        XCTAssertNil(report.selectedRoute)
        XCTAssertTrue(report.reason.contains("rebenchmarking"))
        XCTAssertTrue(report.assessments.allSatisfy { !$0.eligible })
        XCTAssertTrue(report.assessments[0].reasons.contains("application version changed; rebenchmark required"))
        XCTAssertTrue(report.assessments[0].reasons.contains("target is ambiguous"))
        XCTAssertTrue(report.assessments[0].reasons.contains("visual or coordinate route is not registered for this task"))
        XCTAssertTrue(report.assessments[1].reasons.contains("stale"))
    }

    func testWarmPathStoreKeepsMeasurementsScopedToAppVersionTaskAndTarget() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-warm-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSince1970: 3_000)
        let store = WarmPathStore(directory: directory, now: { now })
        let versionOne = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let versionTwo = testApp(name: "Chrome", processID: 43, bundleVersion: "2")

        _ = try store.recordBenchmark(
            application: versionOne,
            taskID: "activate-save",
            targetFingerprint: "save-v1",
            verificationOracle: "saved",
            route: .keyboard,
            latencyMs: 30,
            p95LatencyMs: 45,
            verificationRate: 1
        )
        now = now.addingTimeInterval(1)
        _ = try store.recordBenchmark(
            application: versionTwo,
            taskID: "activate-save",
            targetFingerprint: "save-v1",
            verificationOracle: "saved",
            route: .accessibility,
            latencyMs: 10,
            p95LatencyMs: 15,
            verificationRate: 1
        )

        let inspected = try XCTUnwrap(
            store.inspect(application: versionTwo, taskID: "activate-save", targetFingerprint: "save-v1")
        )
        XCTAssertEqual(inspected.application.version, "2")
        XCTAssertEqual(inspected.candidates.map(\.route), [.accessibility])
        XCTAssertEqual(store.list().count, 2)
        XCTAssertEqual(store.status().directoryOwnerOnly, true)
        XCTAssertEqual(store.status().filesOwnerOnly, true)
    }

    func testCallerSuppliedWarmPathMetadataIsInventoryOnly() {
        let now = Date(timeIntervalSince1970: 3_500)
        let identity = WarmPathApplicationIdentity(
            name: "Chrome",
            bundleID: "com.google.Chrome",
            path: "/Applications/Google Chrome.app",
            version: "1"
        )
        let manifest = WarmPathManifest(
            application: identity,
            taskID: "activate-save",
            targetFingerprint: "save-v1",
            verificationOracle: "saved",
            candidates: [RouteCandidate(
                route: .keyboard,
                measurementSource: .callerSupplied,
                measuredEndToEndLatencyMs: 1,
                measuredP95LatencyMs: 1,
                verificationRate: 1,
                sampleCount: 100,
                freshUntil: now.addingTimeInterval(60)
            )],
            updatedAt: now
        )

        let report = WarmPathSelection.select(
            manifest: manifest,
            context: WarmPathSelectionContext(
                application: identity,
                targetFingerprint: "save-v1",
                now: now
            )
        )

        XCTAssertNil(report.selectedRoute)
        XCTAssertTrue(report.assessments[0].reasons.contains {
            $0.contains("caller-supplied measurement is not eligible")
        })
        XCTAssertTrue(report.reason.contains("rebenchmarking"))
    }

    func testLegacyWarmPathManifestDecodesAsCallerSupplied() throws {
        let data = Data(#"""
        {
            "route":"keyboard",
            "requiredPermissions":[],
            "measuredEndToEndLatencyMs":1,
            "measuredP95LatencyMs":1,
            "verificationRate":1,
            "recoveries":0,
            "sampleCount":10,
            "freshUntil":"2030-01-01T00:00:00Z",
            "tabCount":0,
            "scrollCount":0,
            "coordinateUse":false,
            "userHelpCount":0,
            "declaredFallbackRoutes":[]
        }
        """#.utf8)
        let candidate = try JSONCodec.decode(RouteCandidate.self, from: data)
        XCTAssertEqual(candidate.measurementSource, .callerSupplied)
        XCTAssertFalse(candidate.isMeasured)
    }

    func testControlCapabilitiesClassifyArchetypesWithoutInventingRoutes() {
        XCTAssertEqual(
            MacAppArchetypeClassifier.classify(WarmPathApplicationIdentity(
                name: "Chrome",
                bundleID: "com.google.Chrome",
                path: "/Applications/Google Chrome.app"
            )),
            .browser
        )
        XCTAssertEqual(
            MacAppArchetypeClassifier.classify(WarmPathApplicationIdentity(
                name: "System Settings",
                bundleID: "com.apple.systemsettings",
                path: "/System/Applications/System Settings.app"
            )),
            .systemSettings
        )
        XCTAssertEqual(
            MacAppArchetypeClassifier.classify(WarmPathApplicationIdentity(
                name: "Visual Studio Code",
                bundleID: "com.microsoft.VSCode",
                path: "/Applications/Visual Studio Code.app"
            )),
            .electronChromium
        )
        XCTAssertEqual(
            MacAppArchetypeClassifier.classify(WarmPathApplicationIdentity(
                name: "SwiftUI Demo",
                bundleID: "com.example.swiftui-demo",
                path: "/Applications/SwiftUI Demo.app"
            )),
            .swiftUI
        )
        XCTAssertEqual(
            MacAppArchetypeClassifier.classify(WarmPathApplicationIdentity(
                name: "iPhone Mirroring",
                bundleID: "com.apple.ScreenContinuity",
                path: "/System/Library/CoreServices/iPhone Mirroring.app"
            )),
            .unknown
        )

        let now = Date(timeIntervalSince1970: 4_000)
        let identity = WarmPathApplicationIdentity(
            name: "Finder",
            bundleID: "com.apple.finder",
            path: "/System/Library/CoreServices/Finder.app",
            version: "1"
        )
        let profile = ControlCapabilityProfile(
            application: identity,
            taskID: "open-item",
            targetFingerprint: "item-v1",
            manifest: WarmPathManifest(
                application: identity,
                taskID: "open-item",
                targetFingerprint: "item-v1",
                verificationOracle: "item-visible",
                candidates: [
                    RouteCandidate(
                        route: .keyboard,
                        measuredEndToEndLatencyMs: 10,
                        measuredP95LatencyMs: 12,
                        verificationRate: 1,
                        sampleCount: 3,
                        freshUntil: now.addingTimeInterval(60)
                    ),
                    RouteCandidate(
                        route: .accessibility,
                        measurementSource: .callerSupplied,
                        measuredEndToEndLatencyMs: 1,
                        measuredP95LatencyMs: 1,
                        verificationRate: 1,
                        sampleCount: 20,
                        freshUntil: now.addingTimeInterval(60)
                    )
                ]
            ),
            now: now
        )
        XCTAssertEqual(profile.archetype, .nativeAppKit)
        XCTAssertEqual(profile.freshMeasuredRoutes, [.keyboard])
        XCTAssertEqual(profile.callerSuppliedRoutes, [.accessibility])
        XCTAssertEqual(profile.routeSelectionPolicy, "repeated_verified_context_bound_measurement_only")
        XCTAssertTrue(profile.handoffProviders.contains("computer_use"))
    }

    func testAccessibilityAuditFindsAmbiguousControlsMissingActionsAndRedactsValues() throws {
        let app = testApp(name: "Preview", processID: 42)
        let state = AccessibilityTreeNodeState(
            enabled: true,
            focused: false,
            selected: false,
            expanded: nil,
            visible: true,
            settable: false,
            hasValue: true
        )
        func node(path: String, identifier: String, label: String, actions: [String]) -> AccessibilityTreeNode {
            AccessibilityTreeNode(
                path: path,
                depth: 1,
                role: "AXScrollArea",
                subrole: nil,
                identifier: identifier,
                label: label,
                actions: actions,
                state: state,
                bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                childCount: 0,
                scrollable: true
            )
        }
        let tree = AccessibilityTreeReport(
            application: app,
            maxNodes: 20,
            maxDepth: 4,
            nodeCount: 3,
            truncated: false,
            nodes: [
                node(path: "0/0", identifier: "results", label: "Results", actions: ["AXScrollDown"]),
                node(path: "0/1", identifier: "results", label: "Results", actions: ["AXScrollDown"]),
                node(path: "0/2", identifier: "unique", label: "Unique", actions: [])
            ],
            identifierMatchCounts: ["results": 2, "unique": 1],
            nameMatchCounts: ["Results": 2, "Unique": 1]
        )
        let audit = AccessibilityAuditEngine.audit(
            tree: tree,
            manifest: AccessibilityAuditManifest(controls: [
                AccessibilityAuditControl(
                    identifier: "results",
                    role: "AXScrollArea",
                    requiredActions: ["AXScrollUp"],
                    requiresScrollSemantics: true
                ),
                AccessibilityAuditControl(
                    identifier: "unique",
                    requiredActions: ["AXPress"]
                )
            ])
        )

        let codes = Set(audit.findings.map(\.code))
        XCTAssertFalse(audit.valid)
        XCTAssertTrue(codes.isSuperset(of: ["duplicate_identifier", "duplicate_name", "ambiguous_control", "missing_action"]))
        XCTAssertTrue(tree.redacted)
        let encoded = String(decoding: try JSONCodec.encode(tree), as: UTF8.self)
        XCTAssertFalse(encoded.contains("\"value\""))
        XCTAssertTrue(encoded.contains("\"hasValue\":true"))
    }

    func testRiskClassificationAndSensitiveValidation() {
        let safe = ActionSpec(kind: .capture, surface: .macDesktop)
        XCTAssertEqual(ActionRiskClassifier.classify(safe), .safe)

        XCTAssertEqual(
            ActionRiskClassifier.classify(ActionSpec(kind: .click, surface: .macApp)),
            .sensitive
        )
        XCTAssertEqual(
            ActionRiskClassifier.classify(ActionSpec(kind: .key, surface: .macApp)),
            .sensitive
        )

        let sensitive = ActionSpec(
            kind: .click,
            surface: .macApp,
            selector: Selector(title: "Buy"),
            risk: .sensitive
        )
        let workflow = WorkflowSpec(
            id: "test.sensitive",
            name: "Sensitive",
            summary: "Test",
            surface: .macApp,
            actions: [sensitive]
        )
        let validation = WorkflowRegistry().validate(workflow)
        XCTAssertFalse(validation.valid)
        XCTAssertEqual(validation.risk, .sensitive)
        XCTAssertTrue(validation.errors.contains { $0.contains("approval_reason") })
    }

    func testTypeActionsRequireEphemeralInputAndSensitiveApproval() {
        let typeAction = ActionSpec(
            kind: .type,
            surface: .macApp,
            parameters: ["text_source": .string("ephemeral")]
        )
        XCTAssertEqual(ActionRiskClassifier.classify(typeAction), .sensitive)

        let workflow = WorkflowSpec(
            id: "test.type",
            name: "Type",
            summary: "Test",
            surface: .macApp,
            actions: [typeAction]
        )
        let validation = WorkflowRegistry().validate(workflow)
        XCTAssertFalse(validation.valid)
        XCTAssertEqual(validation.risk, .sensitive)
        XCTAssertTrue(validation.errors.contains { $0.contains("approval_reason") })
    }

    func testApprovalSmokeWorkflowIsSensitiveWithoutExternalInput() throws {
        let workflow = try XCTUnwrap(WorkflowRegistry().workflow(id: "approval.smoke"))
        let validation = WorkflowRegistry().validate(workflow)

        XCTAssertTrue(validation.valid)
        XCTAssertEqual(validation.risk, .sensitive)
        XCTAssertEqual(workflow.actions.count, 1)
        XCTAssertEqual(workflow.actions.first?.kind, .waitFor)
        XCTAssertEqual(workflow.recipe, "approval-smoke")
        XCTAssertNil(workflow.actions.first?.parameters["text_source"])
    }

    func testApprovalDigestBindsEphemeralInputsWithoutReturningThem() {
        let workflow = WorkflowSpec(
            id: "test.ephemeral",
            name: "Ephemeral",
            summary: "Test",
            surface: .macApp,
            actions: [ActionSpec(
                kind: .type,
                surface: .macApp,
                parameters: [
                    "text_source": .string("ephemeral"),
                    "text_key": .string("secret")
                ],
                risk: .sensitive
            )]
        )
        let first = ApprovalStore.digest(workflow, ephemeralInputs: ["secret": "one"])
        let second = ApprovalStore.digest(workflow, ephemeralInputs: ["secret": "two"])
        XCTAssertNotEqual(first, second)
        let prepared = ApprovalStore().prepare(
            workflow: workflow,
            ephemeralInputs: ["secret": "one"]
        )
        XCTAssertEqual(prepared.ephemeralInputs["secret"], "one")
        XCTAssertFalse(prepared.record.summary.contains("one"))
    }

    func testFocusPolicyDefaultsToForegroundAndBindsApprovalDigest() throws {
        let workflow = WorkflowSpec(
            id: "test.focus",
            name: "Focus",
            summary: "Test",
            surface: .macDesktop,
            actions: [ActionSpec(kind: .waitFor, surface: .macDesktop)]
        )
        XCTAssertEqual(workflow.focusPolicy, .foreground)

        let background = workflow.withFocusPolicy(.background)
        XCTAssertNotEqual(
            ApprovalStore.digest(workflow),
            ApprovalStore.digest(background)
        )
        let roundTrip = try JSONCodec.decode(
            WorkflowSpec.self,
            from: try JSONCodec.encode(background)
        )
        XCTAssertEqual(roundTrip, background)

        let legacy = try JSONCodec.decode(
            WorkflowSpec.self,
            from: Data(
                #"{"id":"legacy.focus","name":"Legacy","summary":"Legacy","surface":"mac_desktop","actions":[]}"#.utf8
            )
        )
        XCTAssertEqual(legacy.focusPolicy, .foreground)
    }

    func testAppOpenForegroundUsesVerifiedActivationPath() throws {
        let expected = testApp(name: "ChatGPT", processID: 42)
        var activatedNames: [String] = []
        let service = MacCtlService(
            permissionContext: "test",
            activateApplication: { name in
                activatedNames.append(name)
                return expected
            }
        )

        let response = service.handle(RequestEnvelope(
            method: "app.open",
            params: [
                "name": .string("ChatGPT"),
                "focus_policy": .string("foreground")
            ]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(activatedNames, ["ChatGPT"])
        XCTAssertEqual(response.result["name"]?.stringValue, "ChatGPT")
        XCTAssertEqual(
            response.evidence.first?.metadata["foreground_verified"]?.boolValue,
            true
        )
        XCTAssertEqual(
            response.evidence.first?.metadata["foreground_preserved"]?.boolValue,
            false
        )
    }

    func testKeyboardCommandsMapToTheDocumentedSequences() {
        let expected: [KeyboardCommand: [String]] = [
            .nextControl: ["tab"],
            .previousControl: ["shift+tab"],
            .activate: ["space"],
            .contextMenu: ["shift+f10"],
            .nextItem: ["ctrl+tab"],
            .previousItem: ["ctrl+shift+tab"],
            .search: ["tab", "f"],
            .windowChooser: ["tab", "w"],
            .applicationChooser: ["tab", "a"],
            .menuBar: ["fn+ctrl+f2"],
            .dock: ["fn+a"],
            .controlCenter: ["fn+c"],
            .notificationCenter: ["fn+n"],
            .pointerToFocus: ["tab", "c"],
            .commandsHelp: ["tab", "h"],
            .passThrough: ["ctrl+option+cmd+p"]
        ]

        for command in KeyboardCommand.allCases {
            XCTAssertEqual(command.keySpecifications, expected[command])
            for key in command.keySpecifications {
                XCTAssertNoThrow(try KeySpecification.parse(key))
            }
        }
    }

    func testModifiedKeySequenceEmitsBalancedModifierTransitions() throws {
        let specification = try KeySpecification.parse("ctrl+cmd+0")

        XCTAssertEqual(specification.eventSteps, [
            KeyEventStep(keyCode: 59, keyDown: true, flags: [.maskControl]),
            KeyEventStep(keyCode: 55, keyDown: true, flags: [.maskControl, .maskCommand]),
            KeyEventStep(keyCode: 29, keyDown: true, flags: [.maskControl, .maskCommand]),
            KeyEventStep(keyCode: 29, keyDown: false, flags: [.maskControl, .maskCommand]),
            KeyEventStep(keyCode: 55, keyDown: false, flags: [.maskControl]),
            KeyEventStep(keyCode: 59, keyDown: false, flags: [])
        ])
    }

    func testContextMenuUsesVerifiedPostconditionWhenFocusDoesNotChange() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let focus = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXButton",
            subrole: nil,
            identifier: "tab",
            title: "Example"
        )
        let store = KeyboardDriveStore()
        let session = ControlSession(
            keyboardDriveStore: store,
            focusedElementInspector: TestFocusedElementInspector(snapshot: focus),
            foregroundApplication: { app },
            hasPostEventAccess: { true },
            fullKeyboardAccessEnabled: { true },
            postActionTimeout: 0
        )
        let contextMenu = TestContextMenuActionPerformer(report: ContextMenuReport(
            state: .passed,
            targetResolved: true,
            menuVisible: true,
            expectedItemCount: 1,
            matchedItemCount: 1,
            visibleItemCount: 8,
            renderedMenuCount: 1
        ))
        let router = SemanticActionRouter(
            session: session,
            keyboardAccessController: KeyboardAccessController(
                eventSender: RecordingKeyboardEventSender(),
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            accessibilityActionController: TestAccessibilityActionPerformer(),
            visualActionController: TestVisualActionPerformer(),
            contextMenuActionController: contextMenu
        )
        let lease = try store.acquire(scope: .session, application: nil, seconds: 30, confirm: true)

        let report = try router.perform(
            command: .contextMenu,
            selector: Selector(
                role: "AXButton",
                identifier: "tab",
                windowTitle: "Project - Google Chrome"
            ),
            leaseToken: lease.token,
            count: 1,
            interKeyDelay: 0,
            allowRawCoordinate: false,
            expectedMenuItems: ["Add tab to new group"]
        )

        XCTAssertEqual(contextMenu.callCount, 1)
        XCTAssertEqual(contextMenu.lastExpectedMenuItems, ["Add tab to new group"])
        XCTAssertEqual(report.route, .accessibility)
        XCTAssertEqual(report.verification.state, .passed)
        XCTAssertFalse(report.verification.focusChanged)
        XCTAssertEqual(report.verification.postcondition?.kind, "context_menu")
        XCTAssertEqual(report.verification.postcondition?.verified, true)
    }

    func testContextMenuVerificationRecommendsFreshComputerUseHandoff() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-context-menu-handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let app = testApp(name: "Chrome", processID: 42)
        let focus = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXButton",
            subrole: nil,
            identifier: "tab",
            title: "Example"
        )
        var now = Date(timeIntervalSince1970: 100)
        let store = KeyboardDriveStore()
        let keyboard = KeyboardAccessController(
            eventSender: RecordingKeyboardEventSender(),
            preferenceStore: TestKeyboardPreferenceStore(enabled: true)
        )
        let session = ControlSession(
            keyboardDriveStore: store,
            focusedElementInspector: TestFocusedElementInspector(snapshot: focus),
            foregroundApplication: { app },
            hasPostEventAccess: { true },
            fullKeyboardAccessEnabled: { true },
            verifier: ControlStateVerifier(
                now: { now },
                sleep: { interval in now = now.addingTimeInterval(interval) }
            ),
            postActionTimeout: 0
        )
        let contextMenu = TestContextMenuActionPerformer(report: ContextMenuReport(
            state: .verificationUnavailable,
            targetResolved: true,
            menuVisible: false,
            expectedItemCount: 1,
            matchedItemCount: 0,
            visibleItemCount: 0,
            renderedMenuCount: 0
        ))
        let router = SemanticActionRouter(
            session: session,
            keyboardAccessController: keyboard,
            accessibilityActionController: TestAccessibilityActionPerformer(),
            visualActionController: TestVisualActionPerformer(),
            contextMenuActionController: contextMenu
        )
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            keyboardAccessController: keyboard,
            keyboardDriveStore: store,
            focusedElementInspector: TestFocusedElementInspector(snapshot: focus),
            controlSession: session,
            semanticActionRouter: router,
            foregroundApplication: { app },
            activateApplication: { _ in app },
            foregroundStabilityVerifier: ControlStateVerifier(
                now: { now },
                sleep: { interval in now = now.addingTimeInterval(interval) }
            ),
            hasPostEventAccess: { true }
        )

        let handsOffBegin = service.handle(RequestEnvelope(
            method: "control.hands_off.begin",
            params: [
                "confirm": .bool(true),
                "provider": .string("hybrid"),
                "app": .string("Chrome"),
                "task_id": .string("context-menu"),
                "seconds": .number(30)
            ]
        ))
        XCTAssertEqual(handsOffBegin.status, .succeeded)
        let handsOffSessionObject = try XCTUnwrap(handsOffBegin.result["hands_off_session"]?.objectValue)
        let handsOffSessionID = try XCTUnwrap(handsOffSessionObject["session_id"]?.stringValue)

        let response = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("context-menu"),
                "app": .string("Chrome"),
                "confirm": .bool(true),
                "hands_off_session_id": .string(handsOffSessionID),
                "selector": .object([
                    "role": .string("AXButton"),
                    "identifier": .string("tab")
                ]),
                "expected_menu_items": .array([.string("Reload")])
            ]
        ))

        XCTAssertEqual(response.status, .blocked)
        XCTAssertEqual(response.error?.code, MacCtlErrorCode.controlVerificationUnavailable.rawValue)
        XCTAssertEqual(response.error?.details["failure_class"]?.stringValue, "verification_unavailable")
        XCTAssertEqual(response.error?.details["recommended_provider"]?.stringValue, "computer_use")
        XCTAssertEqual(response.error?.details["fresh_state_required"]?.boolValue, true)
        XCTAssertEqual(response.error?.details["fallback_allowed"]?.boolValue, false)
        XCTAssertEqual(
            response.error?.details["next_action"]?.stringValue,
            "get_app_state_then_relocate_target_and_verify_with_computer_use"
        )
        XCTAssertEqual(response.outcome?.state, .verificationUnavailable)
        XCTAssertEqual(response.outcome?.recommendedProvider, "computer_use")
        XCTAssertEqual(response.outcome?.freshStateRequired, true)
        XCTAssertEqual(
            response.outcome?.nextAction,
            "get_app_state_then_relocate_target_and_verify_with_computer_use"
        )
        let handoffPlan = try XCTUnwrap(response.outcome?.handoffPlan)
        XCTAssertEqual(handoffPlan.schemaVersion, 1)
        XCTAssertEqual(handoffPlan.provider, "computer_use")
        XCTAssertEqual(handoffPlan.reason, "native_context_menu_verification_unavailable")
        XCTAssertEqual(handoffPlan.action, "context-menu")
        XCTAssertTrue(handoffPlan.freshStateRequired)
        XCTAssertFalse(handoffPlan.nativeActionReplayAllowed)
        XCTAssertEqual(handoffPlan.focusPolicy, .foreground)
        XCTAssertEqual(handoffPlan.foregroundOracle, "target_foreground_unchanged")
        XCTAssertEqual(handoffPlan.targetSource, "original_request_selector")
        XCTAssertEqual(handoffPlan.target?.application, "Chrome")
        XCTAssertEqual(handoffPlan.target?.selectorFields, ["identifier", "role"])
        XCTAssertNil(handoffPlan.target?.selectorFields.first(where: { $0 == "title" }))
        XCTAssertEqual(handoffPlan.handsOffSession?.sessionID, handsOffSessionID)
        XCTAssertGreaterThan(handoffPlan.handsOffSession?.heartbeatIntervalSeconds ?? 0, 0)
        XCTAssertEqual(handoffPlan.postconditionKind, "context_menu")
        XCTAssertEqual(handoffPlan.expectedItemCount, 1)
        XCTAssertNotNil(handoffPlan.expectedItemDigest)
        XCTAssertEqual(
            handoffPlan.steps.map(\.id),
            ["refresh_state", "relocate_target", "execute_action", "verify_postcondition"]
        )
        XCTAssertEqual(handoffPlan.steps[0].operation, "get_app_state")
        XCTAssertEqual(handoffPlan.steps[1].targetSource, "original_request_selector")
        XCTAssertEqual(handoffPlan.steps[2].parameters["mouse_button"]?.stringValue, "right")
        XCTAssertEqual(
            handoffPlan.steps[3].parameters["expected_items_source"]?.stringValue,
            "original_request"
        )
        let handoffDetails = try XCTUnwrap(response.error?.details["handoff_plan"]?.objectValue)
        XCTAssertNil(handoffDetails["expected_menu_items"])
        XCTAssertNil(handoffDetails["selector"])
        XCTAssertEqual(
            response.evidence.first(where: { $0.kind == "provider_handoff" })?.metadata["handoff_plan"],
            response.error?.details["handoff_plan"]
        )
        let encodedResponse = try JSONCodec.encode(response)
        let decodedResponse = try JSONCodec.decode(ResponseEnvelope.self, from: encodedResponse)
        XCTAssertEqual(decodedResponse.outcome?.handoffPlan, handoffPlan)
        XCTAssertTrue(response.evidence.contains { $0.kind == "provider_handoff" })
        XCTAssertNil(store.activeLease())
    }

    func testKeyboardRawSequenceValidationRejectsTypingAndBoundsRepetition() {
        XCTAssertEqual(
            try? KeyboardAccessController.validateRawSequence(["cmd+c", "escape", "shift+tab"]),
            ["cmd+c", "escape", "shift+tab"]
        )
        XCTAssertThrowsError(try KeyboardAccessController.validateRawSequence(["a"])) { error in
            XCTAssertEqual(error as? KeyboardControlError, .printableKeyRejected("a"))
        }
        XCTAssertThrowsError(try KeyboardAccessController.validateRawSequence(["space"])) { error in
            XCTAssertEqual(error as? KeyboardControlError, .printableKeyRejected("space"))
        }
        XCTAssertThrowsError(try KeyboardAccessController.validateRawSequence(["not-a-key"])) { error in
            XCTAssertEqual(error as? KeyboardControlError, .invalidSequence("not-a-key"))
        }
        XCTAssertThrowsError(try KeyboardAccessController.validateRawSequence(Array(repeating: "escape", count: 9))) { error in
            XCTAssertEqual(error as? KeyboardControlError, .repetitionLimitExceeded)
        }
        XCTAssertThrowsError(try KeyboardAccessController.validateRawSequence(Array(repeating: "escape", count: 33))) { error in
            XCTAssertEqual(error as? KeyboardControlError, .sequenceTooLong)
        }
    }

    func testKeyboardEnablementRequiresConfirmationAndAppKitVerification() throws {
        let preferenceStore = TestKeyboardPreferenceStore(enabled: false)
        let controller = KeyboardAccessController(
            eventSender: RecordingKeyboardEventSender(),
            preferenceStore: preferenceStore
        )

        XCTAssertThrowsError(try controller.enable(confirm: false)) { error in
            XCTAssertEqual(error as? KeyboardControlError, .confirmationRequired)
        }
        XCTAssertFalse(preferenceStore.enableCalled)

        preferenceStore.enableResult = .verificationFailure
        XCTAssertThrowsError(try controller.enable(confirm: true)) { error in
            XCTAssertEqual(error as? KeyboardControlError, .enableVerificationFailed)
        }
        XCTAssertTrue(preferenceStore.enableCalled)

        preferenceStore.enableResult = .success
        preferenceStore.enabled = true
        let status = try controller.enable(confirm: true, permissionContext: "test")
        XCTAssertEqual(status.fullKeyboardAccessEnabled, true)
        XCTAssertEqual(status.permissionContext, "test")
    }

    func testKeyboardLeaseStoreRequiresConfirmationIsExclusiveAndExpires() throws {
        var now = Date(timeIntervalSince1970: 100)
        let app = testApp(name: "Chrome", processID: 42)
        let store = KeyboardDriveStore(defaultLifetime: 120, now: { now })

        XCTAssertThrowsError(try store.acquire(
            scope: .app,
            application: app,
            seconds: nil,
            confirm: false
        )) { error in
            XCTAssertEqual(error as? KeyboardDriveStoreError, .confirmationRequired)
        }

        let lease = try store.acquire(scope: .app, application: app, seconds: 5, confirm: true)
        XCTAssertEqual(lease.scope, .app)
        XCTAssertEqual(lease.application, app)
        XCTAssertEqual(try store.lease(for: lease.token), lease)
        XCTAssertThrowsError(try store.acquire(scope: .session, application: nil, seconds: nil, confirm: true)) { error in
            XCTAssertEqual(error as? KeyboardDriveStoreError, .duplicateLease)
        }
        XCTAssertThrowsError(try store.lease(for: "invalid")) { error in
            XCTAssertEqual(error as? KeyboardDriveStoreError, .notFound)
        }

        now = now.addingTimeInterval(6)
        XCTAssertThrowsError(try store.lease(for: lease.token)) { error in
            XCTAssertEqual(error as? KeyboardDriveStoreError, .expired)
        }
        XCTAssertNil(store.activeLease())
        let replacement = try store.acquire(scope: .session, application: nil, seconds: nil, confirm: true)
        XCTAssertNoThrow(try store.release(token: replacement.token))
        XCTAssertThrowsError(try store.release(token: replacement.token)) { error in
            XCTAssertEqual(error as? KeyboardDriveStoreError, .notFound)
        }
    }

    func testKeyboardLeasePhysicalSuppressionIsOptInAndReleasedOnCleanup() throws {
        var now = Date()
        let suppressor = RecordingPhysicalKeyboardSuppressor()
        let store = KeyboardDriveStore(
            defaultLifetime: 120,
            now: { now },
            physicalKeyboardSuppressor: suppressor
        )

        let shared = try store.acquire(
            scope: .session,
            application: nil,
            seconds: 5,
            confirm: true
        )
        XCTAssertEqual(shared.physicalInputMode, .shared)
        XCTAssertTrue(suppressor.acquiredUntil.isEmpty)
        try store.release(token: shared.token)
        XCTAssertEqual(suppressor.releaseCount, 0)

        let suppressed = try store.acquire(
            scope: .session,
            application: nil,
            seconds: 5,
            confirm: true,
            physicalInputMode: .suppressed,
            freezeReason: "test freeze"
        )
        XCTAssertEqual(suppressed.physicalInputMode, .suppressed)
        XCTAssertEqual(suppressor.acquiredUntil.count, 1)
        try store.release(token: suppressed.token)
        XCTAssertEqual(suppressor.releaseCount, 1)

        let expiring = try store.acquire(
            scope: .session,
            application: nil,
            seconds: 5,
            confirm: true,
            physicalInputMode: .suppressed,
            freezeReason: "test freeze"
        )
        now = now.addingTimeInterval(6)
        XCTAssertNil(store.activeLease())
        XCTAssertEqual(suppressor.releaseCount, 2)
        XCTAssertThrowsError(try store.lease(for: expiring.token)) { error in
            XCTAssertEqual(error as? KeyboardDriveStoreError, .notFound)
        }

        let shutdownLease = try store.acquire(
            scope: .session,
            application: nil,
            seconds: 5,
            confirm: true,
            physicalInputMode: .suppressed,
            freezeReason: "test freeze"
        )
        store.shutdown()
        XCTAssertNil(store.activeLease())
        XCTAssertEqual(suppressor.releaseCount, 3)
        XCTAssertThrowsError(try store.lease(for: shutdownLease.token)) { error in
            XCTAssertEqual(error as? KeyboardDriveStoreError, .notFound)
        }
        store.shutdown()
        XCTAssertEqual(suppressor.releaseCount, 3)
    }

    func testKeyboardLeasePhysicalSuppressionRequiresSessionAndDoesNotLeaveLease() throws {
        let suppressor = RecordingPhysicalKeyboardSuppressor()
        let store = KeyboardDriveStore(physicalKeyboardSuppressor: suppressor)
        let app = testApp(name: "Chrome", processID: 42)

        XCTAssertThrowsError(try store.acquire(
            scope: .app,
            application: app,
            seconds: 30,
            confirm: true,
            physicalInputMode: .suppressed
        )) { error in
            XCTAssertEqual(
                error as? KeyboardDriveStoreError,
                .physicalKeyboardSuppressionRequiresSession
            )
        }
        XCTAssertNil(store.activeLease())
        XCTAssertTrue(suppressor.acquiredUntil.isEmpty)
    }

    func testKeyboardNavigationLeaseTogglesPassThroughAndRestoresOnCleanup() throws {
        var now = Date(timeIntervalSince1970: 100)
        let sender = RecordingKeyboardEventSender()
        let store = KeyboardDriveStore(
            now: { now },
            passThroughToggler: SystemKeyboardPassThroughToggler(eventSender: sender)
        )

        let lease = try store.acquire(
            scope: .session,
            application: nil,
            seconds: 5,
            confirm: true,
            navigationMode: .navigation,
            fromPassThrough: true
        )
        XCTAssertEqual(lease.navigationMode, .navigation)
        XCTAssertTrue(lease.passThroughTransitionOwned)
        XCTAssertEqual(sender.keys, ["ctrl+option+cmd+p"])

        try store.release(token: lease.token)
        XCTAssertEqual(sender.keys, ["ctrl+option+cmd+p", "ctrl+option+cmd+p"])

        let expiring = try store.acquire(
            scope: .session,
            application: nil,
            seconds: 5,
            confirm: true,
            navigationMode: .navigation,
            fromPassThrough: true
        )
        now = now.addingTimeInterval(6)
        XCTAssertNil(store.activeLease())
        XCTAssertEqual(sender.keys.count, 4)
        XCTAssertFalse(store.isNavigationRestorationPending)
        XCTAssertThrowsError(try store.lease(for: expiring.token)) { error in
            XCTAssertEqual(error as? KeyboardDriveStoreError, .notFound)
        }
    }

    func testKeyboardNavigationLeaseRequiresSessionAndExplicitPassThroughAssertion() throws {
        let sender = RecordingKeyboardEventSender()
        let store = KeyboardDriveStore(
            passThroughToggler: SystemKeyboardPassThroughToggler(eventSender: sender)
        )
        let app = testApp(name: "Chrome", processID: 42)

        XCTAssertThrowsError(try store.acquire(
            scope: .app,
            application: app,
            seconds: 30,
            confirm: true,
            navigationMode: .navigation,
            fromPassThrough: true
        )) { error in
            XCTAssertEqual(error as? KeyboardDriveStoreError, .navigationModeRequiresSession)
        }
        XCTAssertThrowsError(try store.acquire(
            scope: .session,
            application: nil,
            seconds: 30,
            confirm: true,
            navigationMode: .navigation
        )) { error in
            XCTAssertEqual(error as? KeyboardDriveStoreError, .navigationModeRequiresPassThroughAssertion)
        }
        XCTAssertNil(store.activeLease())
        XCTAssertTrue(sender.keys.isEmpty)
    }

    func testKeyboardNavigationLeaseBlocksAfterAmbiguousTransition() throws {
        let sender = RecordingKeyboardEventSender()
        sender.shouldFail = true
        let store = KeyboardDriveStore(
            passThroughToggler: SystemKeyboardPassThroughToggler(eventSender: sender)
        )

        XCTAssertThrowsError(try store.acquire(
            scope: .session,
            application: nil,
            seconds: 30,
            confirm: true,
            navigationMode: .navigation,
            fromPassThrough: true
        )) { error in
            XCTAssertEqual(error as? KeyboardDriveStoreError, .navigationModeTransitionFailed)
        }
        XCTAssertNil(store.activeLease())
        XCTAssertTrue(store.isNavigationRestorationPending)
        XCTAssertThrowsError(try store.acquire(
            scope: .session,
            application: nil,
            seconds: 30,
            confirm: true
        )) { error in
            XCTAssertEqual(error as? KeyboardDriveStoreError, .navigationModeRestorationPending)
        }
    }

    func testKeyboardDriveLeaseDecodesLegacyPayloadAsSharedInput() throws {
        let data = Data(#"{"token":"kbd_legacy","scope":"session","application":null,"acquiredAt":"1970-01-01T00:01:40Z","expiresAt":"1970-01-01T00:02:10Z"}"#.utf8)
        let lease = try JSONCodec.decode(KeyboardDriveLease.self, from: data)

        XCTAssertEqual(lease.token, "kbd_legacy")
        XCTAssertEqual(lease.scope, .session)
        XCTAssertEqual(lease.physicalInputMode, .shared)
        XCTAssertEqual(lease.navigationMode, .unchanged)
        XCTAssertFalse(lease.passThroughTransitionOwned)
        XCTAssertNil(lease.application)
        XCTAssertEqual(lease.acquiredAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(lease.expiresAt, Date(timeIntervalSince1970: 130))
    }

    func testKeyboardLeasePhysicalSuppressionFailureLeavesNoLease() throws {
        let suppressor = RecordingPhysicalKeyboardSuppressor()
        suppressor.shouldFailAcquire = true
        let store = KeyboardDriveStore(physicalKeyboardSuppressor: suppressor)

        XCTAssertThrowsError(try store.acquire(
            scope: .session,
            application: nil,
            seconds: 30,
            confirm: true,
            physicalInputMode: .suppressed,
            freezeReason: "test freeze"
        )) { error in
            XCTAssertEqual(
                error as? KeyboardDriveStoreError,
                .physicalKeyboardSuppressionUnavailable
            )
        }
        XCTAssertNil(store.activeLease())
        XCTAssertEqual(suppressor.releaseCount, 1)
    }

    func testKeyboardServiceReportsOptInPhysicalSuppression() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let suppressor = RecordingPhysicalKeyboardSuppressor()
        let store = KeyboardDriveStore(physicalKeyboardSuppressor: suppressor)
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: RecordingKeyboardEventSender(),
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            keyboardDriveStore: store,
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            hasPostEventAccess: { true }
        )

        let acquired = service.handle(RequestEnvelope(
            method: "keyboard.lease.acquire",
            params: [
                "scope": .string("session"),
                "confirm": .bool(true),
                "physical_input_mode": .string("suppressed"),
                "reason": .string("test freeze")
            ]
        ))
        XCTAssertEqual(acquired.status, .succeeded)
        XCTAssertEqual(
            acquired.result["physical_input_mode"]?.stringValue,
            "suppressed"
        )
        XCTAssertEqual(
            acquired.evidence.map(\.kind),
            ["keyboard_lease", "keyboard_physical_suppression", "keyboard_freeze"]
        )

        let token = try XCTUnwrap(acquired.result["lease"]?.objectValue?["token"]?.stringValue)
        let status = service.handle(RequestEnvelope(method: "keyboard.status"))
        XCTAssertEqual(
            status.result["activeLease"]?.objectValue?["physicalInputMode"]?.stringValue,
            "suppressed"
        )
        XCTAssertEqual(
            service.handle(RequestEnvelope(
                method: "keyboard.lease.release",
                params: ["token": .string(token)]
            )).status,
            .succeeded
        )
        XCTAssertEqual(suppressor.releaseCount, 1)
    }

    func testKeyboardServiceReportsAndRestoresNavigationModeLease() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let sender = RecordingKeyboardEventSender()
        let store = KeyboardDriveStore(
            passThroughToggler: SystemKeyboardPassThroughToggler(eventSender: sender)
        )
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: sender,
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            keyboardDriveStore: store,
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            hasPostEventAccess: { true }
        )

        let acquired = service.handle(RequestEnvelope(
            method: "keyboard.lease.acquire",
            params: [
                "scope": .string("session"),
                "confirm": .bool(true),
                "navigation_mode": .string("navigation"),
                "from_pass_through": .bool(true)
            ]
        ))
        XCTAssertEqual(acquired.status, .succeeded)
        XCTAssertEqual(acquired.result["navigation_mode"]?.stringValue, "navigation")
        XCTAssertEqual(acquired.result["pass_through_transition_owned"]?.boolValue, true)
        XCTAssertEqual(acquired.result["pass_through_state_source"]?.stringValue, "caller_asserted")
        XCTAssertEqual(acquired.evidence.map { $0.kind }, ["keyboard_navigation_mode", "keyboard_lease"])
        XCTAssertEqual(sender.keys, ["ctrl+option+cmd+p"])

        let token = try XCTUnwrap(acquired.result["lease"]?.objectValue?["token"]?.stringValue)
        let status = service.handle(RequestEnvelope(method: "keyboard.status"))
        XCTAssertEqual(
            status.result["activeLease"]?.objectValue?["navigationMode"]?.stringValue,
            "navigation"
        )
        XCTAssertEqual(
            status.result["navigationRestorationPending"]?.boolValue,
            false
        )
        XCTAssertEqual(
            service.handle(RequestEnvelope(
                method: "keyboard.lease.release",
                params: ["token": .string(token)]
            )).status,
            .succeeded
        )
        XCTAssertEqual(sender.keys, ["ctrl+option+cmd+p", "ctrl+option+cmd+p"])
    }

    func testKeyboardServiceRejectsNavigationModeWhenFullKeyboardAccessIsDisabled() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let sender = RecordingKeyboardEventSender()
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: sender,
                preferenceStore: TestKeyboardPreferenceStore(enabled: false)
            ),
            keyboardDriveStore: KeyboardDriveStore(
                passThroughToggler: SystemKeyboardPassThroughToggler(eventSender: sender)
            ),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            hasPostEventAccess: { true }
        )

        let response = service.handle(RequestEnvelope(
            method: "keyboard.lease.acquire",
            params: [
                "scope": .string("session"),
                "confirm": .bool(true),
                "navigation_mode": .string("navigation"),
                "from_pass_through": .bool(true)
            ]
        ))
        XCTAssertEqual(response.status, .blocked)
        XCTAssertEqual(response.error?.code, MacCtlErrorCode.keyboardAccessDisabled.rawValue)
        XCTAssertTrue(sender.keys.isEmpty)
    }

    func testKeyboardServiceRejectsPhysicalSuppressionForAppLease() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let suppressor = RecordingPhysicalKeyboardSuppressor()
        let service = MacCtlService(
            permissionContext: "test",
            keyboardDriveStore: KeyboardDriveStore(physicalKeyboardSuppressor: suppressor),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            hasPostEventAccess: { true }
        )

        let response = service.handle(RequestEnvelope(
            method: "keyboard.lease.acquire",
            params: [
                "scope": .string("app"),
                "app": .string("Chrome"),
                "confirm": .bool(true),
                "physical_input_mode": .string("suppressed")
            ]
        ))
        XCTAssertEqual(response.status, .blocked)
        XCTAssertEqual(
            response.error?.code,
            MacCtlErrorCode.keyboardPhysicalSuppressionRequiresSession.rawValue
        )
        XCTAssertNil(response.result["lease"])
        XCTAssertTrue(suppressor.acquiredUntil.isEmpty)
    }

    func testKeyboardFreezeServiceRequiresReasonAndReleasesSessionFreeze() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-freeze-receipts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let app = testApp(name: "Chrome", processID: 42)
        let suppressor = RecordingPhysicalKeyboardSuppressor()
        let store = KeyboardDriveStore(
            defaultLifetime: 30,
            physicalKeyboardSuppressor: suppressor
        )
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            keyboardDriveStore: store,
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            hasPostEventAccess: { true }
        )

        let missingReason = service.handle(RequestEnvelope(
            method: "keyboard.freeze.acquire",
            params: [
                "scope": .string("session"),
                "confirm": .bool(true)
            ]
        ))
        XCTAssertEqual(missingReason.status, .blocked)
        XCTAssertEqual(missingReason.error?.code, MacCtlErrorCode.keyboardFreezeReasonRequired.rawValue)

        let acquired = service.handle(RequestEnvelope(
            method: "keyboard.freeze.acquire",
            params: [
                "scope": .string("session"),
                "confirm": .bool(true),
                "reason": .string("test freeze")
            ]
        ))
        XCTAssertEqual(acquired.status, .succeeded)
        XCTAssertEqual(acquired.result["scope"]?.stringValue, "session")
        XCTAssertEqual(acquired.result["reason_present"]?.boolValue, true)
        XCTAssertEqual(acquired.evidence.map(\.kind), ["keyboard_freeze", "keyboard_freeze_permissions"])

        let token = try XCTUnwrap(acquired.result["token"]?.stringValue)
        let status = service.handle(RequestEnvelope(method: "keyboard.freeze.status"))
        XCTAssertEqual(status.status, .succeeded)
        XCTAssertEqual(status.result["active"]?.boolValue, true)
        XCTAssertEqual(status.result["reasonPresent"]?.boolValue, true)

        let released = service.handle(RequestEnvelope(
            method: "keyboard.freeze.release",
            params: ["token": .string(token)]
        ))
        XCTAssertEqual(released.status, .succeeded)
        XCTAssertEqual(released.result["released"]?.boolValue, true)
        XCTAssertEqual(
            service.handle(RequestEnvelope(method: "keyboard.freeze.status")).result["active"]?.boolValue,
            false
        )
        XCTAssertEqual(suppressor.releaseCount, 1)
    }

    func testKeyboardFreezeAuthorityIsExplicitInWorkflowAndTaskDigests() throws {
        let action = ActionSpec(
            kind: .key,
            surface: .macApp,
            parameters: [
                "key": .string("cmd+c"),
                "physical_input_mode": .string("suppressed"),
                "approval_reason": .string("freeze for controlled test")
            ],
            risk: .sensitive
        )
        let ordinaryWorkflow = WorkflowSpec(
            id: "freeze.workflow",
            name: "Freeze workflow",
            summary: "Requires explicit freeze authority",
            surface: .macApp,
            actions: [action]
        )
        let frozenWorkflow = WorkflowSpec(
            id: ordinaryWorkflow.id,
            name: ordinaryWorkflow.name,
            summary: ordinaryWorkflow.summary,
            surface: ordinaryWorkflow.surface,
            keyboardFreezeRequired: true,
            actions: ordinaryWorkflow.actions
        )
        XCTAssertFalse(WorkflowRegistry().validate(ordinaryWorkflow).valid)
        XCTAssertTrue(WorkflowRegistry().validate(frozenWorkflow).valid)
        XCTAssertNotEqual(ApprovalStore.digest(ordinaryWorkflow), ApprovalStore.digest(frozenWorkflow))

        let step = TaskStep(id: "freeze", action: action, approvalReason: "freeze for controlled test")
        let ordinaryPlan = TaskPlan(
            id: "freeze.task",
            name: "Freeze task",
            summary: "Requires explicit freeze authority",
            steps: [step]
        )
        let frozenPlan = TaskPlan(
            id: ordinaryPlan.id,
            name: ordinaryPlan.name,
            summary: ordinaryPlan.summary,
            keyboardFreezeRequired: true,
            steps: ordinaryPlan.steps
        )
        XCTAssertFalse(TaskPlanValidator.validate(ordinaryPlan).valid)
        XCTAssertTrue(TaskPlanValidator.validate(frozenPlan).valid)
        let prepared = TaskApprovalStore().prepare(plan: frozenPlan)
        XCTAssertTrue(prepared.record.keyboardFreezeRequired)
        XCTAssertNotEqual(
            TaskPlan.digest(ordinaryPlan),
            TaskPlan.digest(frozenPlan)
        )
    }

    func testAccessibilityServiceTreeAndAuditPreserveBoundsAndRedaction() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-accessibility-receipts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let app = testApp(name: "Preview", processID: 42)
        let state = AccessibilityTreeNodeState(
            enabled: true,
            focused: false,
            selected: false,
            expanded: nil,
            visible: true,
            settable: false,
            hasValue: true
        )
        let tree = AccessibilityTreeReport(
            application: app,
            maxNodes: 20,
            maxDepth: 4,
            nodeCount: 1,
            truncated: false,
            nodes: [AccessibilityTreeNode(
                path: "0",
                depth: 0,
                role: "AXWindow",
                subrole: nil,
                identifier: "window",
                label: "Preview",
                actions: [],
                state: state,
                bounds: nil,
                childCount: 0,
                scrollable: false
            )],
            identifierMatchCounts: ["window": 1],
            nameMatchCounts: ["Preview": 1]
        )
        let inspector = RecordingAccessibilityTreeInspector(tree: tree)
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            resolveApplication: { _ in app },
            accessibilityTreeInspector: inspector
        )

        let treeResponse = service.handle(RequestEnvelope(
            method: "accessibility.tree",
            params: [
                "app": .string("Preview"),
                "max_nodes": .number(25),
                "max_depth": .number(4)
            ]
        ))
        XCTAssertEqual(treeResponse.status, .succeeded)
        XCTAssertEqual(inspector.lastMaxNodes, 25)
        XCTAssertEqual(inspector.lastMaxDepth, 4)
        XCTAssertEqual(treeResponse.result["redacted"]?.boolValue, true)
        XCTAssertNil(treeResponse.result["value"])

        let auditResponse = service.handle(RequestEnvelope(
            method: "accessibility.audit",
            params: [
                "app": .string("Preview"),
                "manifest": try JSONValue.fromEncodable(
                    AccessibilityAuditManifest(controls: [
                        AccessibilityAuditControl(identifier: "window", role: "AXWindow")
                    ])
                )
            ]
        ))
        XCTAssertEqual(auditResponse.status, .succeeded)
        XCTAssertEqual(auditResponse.result["valid"]?.boolValue, true)
        XCTAssertTrue(auditResponse.evidence.contains { $0.kind == "accessibility_audit" })
    }

    func testSemanticScrollPrefersPageActionAndSupportsLegacyAlias() {
        XCTAssertEqual(
            AccessibilityScrollDirection.down.actionName(matching: ["AXScrollDownByPage", "AXScrollDown"]),
            "AXScrollDownByPage"
        )
        XCTAssertEqual(
            AccessibilityScrollDirection.down.actionName(matching: ["AXScrollDown"]),
            "AXScrollDown"
        )
        XCTAssertNil(
            AccessibilityScrollDirection.down.actionName(matching: ["AXPress"])
        )
    }

    func testSemanticScrollMapsDirectionsToDirectionalPageButtons() {
        XCTAssertEqual(AccessibilityScrollDirection.up.pageButtonSubrole, "AXDecrementPage")
        XCTAssertEqual(AccessibilityScrollDirection.down.pageButtonSubrole, "AXIncrementPage")
        XCTAssertEqual(AccessibilityScrollDirection.left.pageButtonSubrole, "AXDecrementPage")
        XCTAssertEqual(AccessibilityScrollDirection.right.pageButtonSubrole, "AXIncrementPage")
        XCTAssertTrue(AccessibilityScrollDirection.up.usesVerticalScrollBar)
        XCTAssertFalse(AccessibilityScrollDirection.right.usesVerticalScrollBar)
    }

    func testSemanticScrollServiceUsesUniqueSemanticTargetAndReportsLeaseRelease() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-scroll-receipts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let app = testApp(name: "Preview", processID: 42)
        let performer = RecordingAccessibilityScrollPerformer()
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            accessibilityScrollPerformer: performer
        )

        let response = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("scroll"),
                "app": .string("Preview"),
                "confirm": .bool(true),
                "role": .string("AXScrollArea"),
                "identifier": .string("results"),
                "direction": .string("down"),
                "amount": .number(2)
            ]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(performer.lastSelector?.role, "AXScrollArea")
        XCTAssertEqual(performer.lastSelector?.identifier, "results")
        XCTAssertEqual(performer.lastDirection, .down)
        XCTAssertEqual(performer.lastAmount, 2)
        XCTAssertEqual(response.result["route"]?.stringValue, "scroll")
        XCTAssertEqual(response.evidence.first(where: { $0.kind == "semantic_scroll" })?.metadata["lease_released"]?.boolValue, true)
    }

    func testSemanticScrollServiceAllowsUniqueRoleOnlyTarget() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-scroll-role-only-receipts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let app = testApp(name: "System Settings", processID: 42)
        let performer = RecordingAccessibilityScrollPerformer()
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            accessibilityScrollPerformer: performer
        )

        let response = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("scroll"),
                "app": .string("System Settings"),
                "confirm": .bool(true),
                "role": .string("AXScrollArea"),
                "direction": .string("down"),
                "amount": .number(1)
            ]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(performer.lastSelector?.role, "AXScrollArea")
        XCTAssertNil(performer.lastSelector?.identifier)
        XCTAssertEqual(response.result["route"]?.stringValue, "scroll")
        XCTAssertEqual(response.result["targetIdentifier"]?.stringValue, "role:AXScrollArea")
    }

    func testSemanticScrollFailureRecommendsComputerUseWithFreshState() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-scroll-fallback-receipts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let app = testApp(name: "Preview", processID: 42)
        let performer = RecordingAccessibilityScrollPerformer(
            failure: .scrollUnavailable("down")
        )
        let input = RecordingInputScrollPerformer()
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            accessibilityScrollPerformer: performer,
            inputScrollPerformer: input
        )

        let response = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("scroll"),
                "app": .string("Preview"),
                "confirm": .bool(true),
                "role": .string("AXScrollArea"),
                "identifier": .string("results"),
                "direction": .string("down"),
                "amount": .number(2)
            ]
        ))

        XCTAssertEqual(response.status, .blocked)
        XCTAssertEqual(response.error?.code, MacCtlErrorCode.scrollFallbackRequired.rawValue)
        XCTAssertEqual(response.error?.details["failure_class"]?.stringValue, "action_unavailable")
        XCTAssertEqual(response.error?.details["recommended_provider"]?.stringValue, "computer_use")
        XCTAssertEqual(response.error?.details["fresh_state_required"]?.boolValue, true)
        XCTAssertEqual(response.error?.details["fallback_allowed"]?.boolValue, true)
        XCTAssertEqual(response.outcome?.state, .actionUnavailable)
        XCTAssertEqual(response.outcome?.route, "scroll")
        XCTAssertEqual(response.outcome?.recommendedProvider, "computer_use")
        XCTAssertEqual(response.outcome?.freshStateRequired, true)
        XCTAssertEqual(
            response.outcome?.nextAction,
            "get_app_state_then_relocate_target_and_verify_with_computer_use"
        )
        XCTAssertEqual(input.callCount, 0)
        XCTAssertTrue(response.evidence.contains { $0.kind == "scroll_fallback" })
    }

    func testSemanticScrollDeclaredInputFallbackReportsUnverifiedDispatch() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-scroll-input-receipts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let app = testApp(name: "Preview", processID: 42)
        let performer = RecordingAccessibilityScrollPerformer(
            failure: .scrollUnavailable("down")
        )
        let input = RecordingInputScrollPerformer()
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            accessibilityScrollPerformer: performer,
            inputScrollPerformer: input
        )

        let response = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("scroll"),
                "app": .string("Preview"),
                "confirm": .bool(true),
                "fallback_route": .string("input_scroll"),
                "role": .string("AXScrollArea"),
                "identifier": .string("results"),
                "direction": .string("down"),
                "amount": .number(2)
            ]
        ))

        XCTAssertEqual(response.status, .blocked)
        XCTAssertEqual(response.error?.code, MacCtlErrorCode.scrollVerificationUnavailable.rawValue)
        XCTAssertEqual(response.error?.details["failure_class"]?.stringValue, "verification_unavailable")
        XCTAssertEqual(response.error?.details["requested_fallback"]?.stringValue, "input_scroll")
        XCTAssertEqual(response.error?.details["local_fallback_dispatched"]?.boolValue, true)
        XCTAssertEqual(response.error?.details["local_fallback_verification"]?.stringValue, "verification_unavailable")
        XCTAssertEqual(response.error?.details["recommended_provider"]?.stringValue, "computer_use")
        XCTAssertEqual(response.outcome?.state, .verificationUnavailable)
        XCTAssertEqual(response.outcome?.failureClass, "verification_unavailable")
        XCTAssertEqual(response.outcome?.recommendedProvider, "computer_use")
        XCTAssertEqual(input.callCount, 1)
        XCTAssertEqual(input.lastDirection, "down")
        XCTAssertEqual(input.lastAmount, 2)
    }

    func testSemanticScrollDeclaredInputFallbackSucceedsOnlyWhenVerified() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-scroll-input-verified-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let app = testApp(name: "Preview", processID: 42)
        let performer = RecordingAccessibilityScrollPerformer(
            failure: .scrollUnavailable("down")
        )
        let input = RecordingInputScrollPerformer(
            report: InputScrollReport(
                direction: "down",
                amount: 2,
                verification: .passed
            )
        )
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            accessibilityScrollPerformer: performer,
            inputScrollPerformer: input
        )

        let response = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("scroll"),
                "app": .string("Preview"),
                "confirm": .bool(true),
                "fallback_route": .string("input_scroll"),
                "role": .string("AXScrollArea"),
                "identifier": .string("results"),
                "direction": .string("down"),
                "amount": .number(2)
            ]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(response.result["route"]?.stringValue, "input_scroll")
        XCTAssertEqual(response.result["verification"]?.stringValue, "passed")
        XCTAssertEqual(response.evidence.first(where: { $0.kind == "scroll_fallback" })?.metadata["original_failure"]?.stringValue, "action_unavailable")
        XCTAssertEqual(input.callCount, 1)
    }

    func testSemanticScrollNoObservedChangeRecommendsComputerUseWithoutInputRetry() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-scroll-no-change-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let app = testApp(name: "Preview", processID: 42)
        let performer = RecordingAccessibilityScrollPerformer(
            verification: .noObservedChange
        )
        let input = RecordingInputScrollPerformer()
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            accessibilityScrollPerformer: performer,
            inputScrollPerformer: input
        )

        let response = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("scroll"),
                "app": .string("Preview"),
                "confirm": .bool(true),
                "fallback_route": .string("input_scroll"),
                "role": .string("AXScrollArea"),
                "identifier": .string("results"),
                "direction": .string("down"),
                "amount": .number(2)
            ]
        ))

        XCTAssertEqual(response.status, .blocked)
        XCTAssertEqual(response.error?.code, MacCtlErrorCode.scrollVerificationUnavailable.rawValue)
        XCTAssertEqual(response.error?.details["failure_class"]?.stringValue, "no_observed_change")
        XCTAssertEqual(response.error?.details["recommended_provider"]?.stringValue, "computer_use")
        XCTAssertEqual(response.error?.details["fallback_allowed"]?.boolValue, false)
        XCTAssertEqual(input.callCount, 0)
    }

    func testSemanticScrollAmbiguousTargetNeverFallsBack() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-scroll-ambiguous-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let app = testApp(name: "Preview", processID: 42)
        let receiptStore = OperationReceiptStore(directory: receiptDirectory)
        let performer = RecordingAccessibilityScrollPerformer(
            failure: .ambiguousMatch(2)
        )
        let input = RecordingInputScrollPerformer()
        let service = MacCtlService(
            receiptStore: receiptStore,
            permissionContext: "test",
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            accessibilityScrollPerformer: performer,
            inputScrollPerformer: input
        )

        let request = RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("scroll"),
                "app": .string("Preview"),
                "confirm": .bool(true),
                "fallback_route": .string("input_scroll"),
                "role": .string("AXScrollArea"),
                "identifier": .string("results"),
                "direction": .string("down"),
                "amount": .number(2)
            ]
        )
        let response = service.handle(request)
        let repeatedResponse = service.handle(request)

        XCTAssertEqual(response.status, .blocked)
        XCTAssertEqual(repeatedResponse.status, .blocked)
        XCTAssertEqual(response.error?.details["failure_class"]?.stringValue, "target_ambiguous")
        XCTAssertEqual(response.error?.details["fallback_allowed"]?.boolValue, false)
        XCTAssertNil(response.error?.details["recommended_provider"])
        XCTAssertEqual(input.callCount, 0)

        let receipt = try XCTUnwrap(
            receiptStore.list(limit: 10).first(where: { $0.method == "control.perform" })
        )
        XCTAssertEqual(receipt.schemaVersion, 4)
        XCTAssertEqual(receipt.actionOutcome?.state, .targetAmbiguous)
        XCTAssertEqual(receipt.actionOutcome?.failureClass, "target_ambiguous")
        XCTAssertEqual(receipt.controlTarget?.application.bundleID, app.bundleID)
        XCTAssertEqual(receipt.controlTarget?.selectorFields, ["identifier", "role"])
        XCTAssertNotNil(receipt.controlTarget?.locatorDigest)

        let encodedReceipt = String(decoding: try JSONCodec.encode(receipt), as: UTF8.self)
        XCTAssertFalse(encodedReceipt.contains("results"))
        XCTAssertFalse(encodedReceipt.contains(app.path))

        let capabilities = service.handle(RequestEnvelope(
            method: "control.capabilities",
            params: ["app": .string("Preview")]
        ))
        XCTAssertEqual(capabilities.status, .succeeded)
        let blocker = try XCTUnwrap(capabilities.result["recentBlockers"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(blocker["state"]?.stringValue, "target_ambiguous")
        XCTAssertEqual(blocker["failureClass"]?.stringValue, "target_ambiguous")
        XCTAssertEqual(blocker["count"]?.intValue, 2)
        XCTAssertEqual(blocker["isFresh"]?.boolValue, true)
        XCTAssertNotNil(blocker["freshUntil"]?.stringValue)
        XCTAssertEqual(
            blocker["target"]?.objectValue?["selectorFields"]?.arrayValue?.compactMap(\.stringValue),
            ["identifier", "role"]
        )
        XCTAssertEqual(
            capabilities.evidence.first?.metadata["recent_blocker_count"]?.intValue,
            1
        )

        let staleBlocker = try XCTUnwrap(receiptStore.recentControlBlockers(
            application: WarmPathApplicationIdentity(application: app),
            now: receipt.completedAt.addingTimeInterval(
                OperationReceiptStore.defaultBlockerFreshnessInterval + 1
            )
        ).first)
        XCTAssertFalse(staleBlocker.isFresh)
    }

    func testSemanticScrollResolutionIncompleteIsDistinctAndNeverFallsBack() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-scroll-resolution-incomplete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let app = testApp(name: "Pronto", processID: 42)
        let performer = RecordingAccessibilityScrollPerformer(
            failure: .resolutionIncomplete(1)
        )
        let input = RecordingInputScrollPerformer()
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            accessibilityScrollPerformer: performer,
            inputScrollPerformer: input
        )

        let response = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("scroll"),
                "app": .string("Pronto"),
                "confirm": .bool(true),
                "fallback_route": .string("input_scroll"),
                "role": .string("AXScrollArea"),
                "direction": .string("down"),
                "amount": .number(1)
            ]
        ))

        XCTAssertEqual(response.status, .blocked)
        XCTAssertEqual(response.error?.details["failure_class"]?.stringValue, "target_resolution_incomplete")
        XCTAssertEqual(response.error?.details["recommended_provider"]?.stringValue, "computer_use")
        XCTAssertEqual(response.error?.details["fresh_state_required"]?.boolValue, true)
        XCTAssertEqual(response.error?.details["fallback_allowed"]?.boolValue, false)
        XCTAssertEqual(response.outcome?.state, .targetResolutionIncomplete)
        XCTAssertEqual(response.outcome?.failureClass, "target_resolution_incomplete")
        XCTAssertEqual(response.outcome?.recommendedProvider, "computer_use")
        XCTAssertEqual(response.outcome?.nextAction, "get_app_state_then_relocate_target_and_verify_with_computer_use")
        XCTAssertEqual(input.callCount, 0)
    }

    func testKeyboardServiceEnforcesAppAndSessionFocusScopes() throws {
        var foreground = testApp(name: "Chrome", processID: 42)
        let otherApp = testApp(name: "Safari", processID: 43)
        let sender = RecordingKeyboardEventSender()
        let preferenceStore = TestKeyboardPreferenceStore(enabled: true)
        let controller = KeyboardAccessController(eventSender: sender, preferenceStore: preferenceStore)
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-keyboard-focus-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let appLeaseService = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            keyboardAccessController: controller,
            keyboardDriveStore: KeyboardDriveStore(),
            foregroundApplication: { foreground },
            resolveApplication: { _ in foreground },
            hasPostEventAccess: { true }
        )

        let acquired = appLeaseService.handle(RequestEnvelope(
            method: "keyboard.lease.acquire",
            params: [
                "scope": .string("app"),
                "app": .string("Chrome"),
                "confirm": .bool(true)
            ]
        ))
        XCTAssertEqual(acquired.status, .succeeded)
        let appToken = try XCTUnwrap(acquired.result["lease"]?.objectValue?["token"]?.stringValue)
        let navigated = appLeaseService.handle(RequestEnvelope(
            method: "keyboard.navigate",
            params: [
                "command": .string("next-control"),
                "lease_token": .string(appToken),
                "inter_key_ms": .number(0)
            ]
        ))
        XCTAssertEqual(navigated.status, .succeeded)
        XCTAssertEqual(sender.keys, ["tab"])

        foreground = otherApp
        let focusChanged = appLeaseService.handle(RequestEnvelope(
            method: "keyboard.navigate",
            params: [
                "command": .string("next-control"),
                "lease_token": .string(appToken),
                "inter_key_ms": .number(0)
            ]
        ))
        XCTAssertEqual(focusChanged.status, .blocked)
        XCTAssertEqual(focusChanged.error?.code, MacCtlErrorCode.keyboardFocusChanged.rawValue)

        foreground = testApp(name: "Chrome", processID: 42)
        let sessionService = MacCtlService(
            receiptStore: OperationReceiptStore(directory: URL(fileURLWithPath: "/private/tmp/macctl-keyboard-session-" + UUID().uuidString)),
            permissionContext: "test",
            keyboardAccessController: controller,
            keyboardDriveStore: KeyboardDriveStore(),
            foregroundApplication: { foreground },
            resolveApplication: { _ in foreground },
            hasPostEventAccess: { true }
        )
        let session = sessionService.handle(RequestEnvelope(
            method: "keyboard.lease.acquire",
            params: ["scope": .string("session"), "confirm": .bool(true)]
        ))
        let sessionToken = try XCTUnwrap(session.result["lease"]?.objectValue?["token"]?.stringValue)
        foreground = otherApp
        let switched = sessionService.handle(RequestEnvelope(
            method: "keyboard.navigate",
            params: [
                "command": .string("next-control"),
                "lease_token": .string(sessionToken),
                "inter_key_ms": .number(0)
            ]
        ))
        XCTAssertEqual(switched.status, .succeeded)
        XCTAssertEqual(sender.keys, ["tab", "tab"])
    }

    func testKeyboardServiceRedactsRawInputTokensAndAXValuesFromReceipts() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-keyboard-redaction-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: RecordingKeyboardEventSender(),
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            keyboardDriveStore: KeyboardDriveStore(),
            focusedElementInspector: TestFocusedElementInspector(snapshot: FocusedElementSnapshot(
                targetApplication: app,
                role: "AXTextField",
                subrole: "AXSearchField",
                identifier: "search",
                title: "Search"
            )),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            hasPostEventAccess: { true }
        )
        let acquired = service.handle(RequestEnvelope(
            method: "keyboard.lease.acquire",
            params: ["scope": .string("session"), "confirm": .bool(true)]
        ))
        let token = try XCTUnwrap(acquired.result["lease"]?.objectValue?["token"]?.stringValue)
        let sent = service.handle(RequestEnvelope(
            method: "keyboard.send",
            params: [
                "keys": .array([.string("cmd+c")]),
                "lease_token": .string(token),
                "inter_key_ms": .number(0)
            ]
        ))
        XCTAssertEqual(sent.status, .succeeded)
        let inspected = service.handle(RequestEnvelope(method: "keyboard.inspect"))
        XCTAssertEqual(inspected.status, .succeeded)
        XCTAssertEqual(inspected.result["role"]?.stringValue, "AXTextField")
        XCTAssertNil(inspected.result["value"])
        XCTAssertNil(inspected.result["children"])
        let released = service.handle(RequestEnvelope(
            method: "keyboard.lease.release",
            params: ["token": .string(token)]
        ))
        XCTAssertEqual(released.status, .succeeded)

        let receipts = try OperationReceiptStore(directory: receiptDirectory).list(limit: 20)
        let receiptText = String(decoding: try JSONCodec.encode(receipts), as: UTF8.self)
        XCTAssertFalse(receiptText.contains(token))
        XCTAssertFalse(receiptText.contains("cmd+c"))
        XCTAssertFalse(receiptText.contains("AXTextField"))
        XCTAssertTrue(receipts.contains { $0.method == "keyboard.send" && $0.evidence.contains { $0.kind == "keyboard_input" } })
    }

    func testKeyboardServiceBlocksMissingPostEventsAndAccessibility() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let service = MacCtlService(
            permissionContext: "test",
            focusedElementInspector: TestFocusedElementInspector(error: AccessibilityControllerError.permissionDenied),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            hasPostEventAccess: { false }
        )
        let lease = service.handle(RequestEnvelope(
            method: "keyboard.lease.acquire",
            params: ["scope": .string("session"), "confirm": .bool(true)]
        ))
        XCTAssertEqual(lease.status, .blocked)
        XCTAssertEqual(lease.error?.code, MacCtlErrorCode.permissionDenied.rawValue)
        let inspect = service.handle(RequestEnvelope(method: "keyboard.inspect"))
        XCTAssertEqual(inspect.status, .blocked)
        XCTAssertEqual(inspect.error?.code, MacCtlErrorCode.permissionDenied.rawValue)
    }

    func testControlStateVerifierWaitsForReadableForegroundState() throws {
        let app = testApp(name: "Chrome", processID: 42)
        var now = Date(timeIntervalSince1970: 100)
        var reads = 0
        let verifier = ControlStateVerifier(
            now: { now },
            sleep: { interval in now = now.addingTimeInterval(interval) }
        )
        let observation = try verifier.waitUntil(
            timeout: 1,
            pollInterval: 0.1,
            read: {
                reads += 1
                return ControlObservation(
                    foregroundApplication: reads >= 3 ? app : nil,
                    focusedElement: nil
                )
            },
            predicate: { $0.foregroundApplication != nil }
        )
        XCTAssertEqual(observation.foregroundApplication, app)
        XCTAssertEqual(reads, 3)
    }

    func testControlStateVerifierRequiresStableConsecutiveForegroundReads() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let other = testApp(name: "Safari", processID: 43)
        var now = Date(timeIntervalSince1970: 100)
        var reads = [other, app, other, app, app]
        let verifier = ControlStateVerifier(
            now: { now },
            sleep: { interval in now = now.addingTimeInterval(interval) }
        )

        let observation = try verifier.waitUntil(
            timeout: 1,
            pollInterval: 0.1,
            consecutiveMatches: 2,
            read: {
                ControlObservation(
                    foregroundApplication: reads.removeFirst(),
                    focusedElement: nil
                )
            },
            predicate: { $0.foregroundApplication == app }
        )

        XCTAssertEqual(observation.foregroundApplication, app)
        XCTAssertTrue(reads.isEmpty)
    }

    func testControlStateVerifierSkipsEventMonitorForImmediateVerification() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let monitor = RecordingControlEventMonitor()
        var reads = 0
        let verifier = ControlStateVerifier(eventMonitor: monitor)

        let observation = try verifier.waitUntil(
            timeout: 1,
            read: {
                reads += 1
                return ControlObservation(
                    foregroundApplication: app,
                    focusedElement: nil
                )
            },
            predicate: { $0.foregroundApplication == app }
        )

        XCTAssertEqual(observation.foregroundApplication, app)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(monitor.startCount, 0)
        XCTAssertEqual(monitor.stopCount, 0)
    }

    func testControlStateVerifierUsesEventMonitorPathAfterImmediateMiss() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let monitor = RecordingControlEventMonitor()
        var reads = 0
        var now = Date(timeIntervalSince1970: 100)
        let verifier = ControlStateVerifier(
            now: { now },
            sleep: { interval in now = now.addingTimeInterval(interval) },
            eventMonitor: monitor
        )

        let observation = try verifier.waitUntil(
            timeout: 1,
            pollInterval: 0.1,
            read: {
                reads += 1
                return ControlObservation(
                    foregroundApplication: reads >= 2 ? app : nil,
                    focusedElement: nil
                )
            },
            predicate: { $0.foregroundApplication == app }
        )

        XCTAssertEqual(observation.foregroundApplication, app)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(monitor.stopCount, 1)
    }

    func testSemanticRouterPrefersAccessibilityAndReturnsRedactedVerification() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let sender = RecordingKeyboardEventSender()
        let store = KeyboardDriveStore()
        let preferenceStore = TestKeyboardPreferenceStore(enabled: true)
        let keyboard = KeyboardAccessController(eventSender: sender, preferenceStore: preferenceStore)
        let inspector = TestFocusedElementInspector(snapshot: FocusedElementSnapshot(
            targetApplication: app,
            role: "AXButton",
            subrole: nil,
            identifier: "save",
            title: "Save"
        ))
        let session = ControlSession(
            keyboardDriveStore: store,
            focusedElementInspector: inspector,
            foregroundApplication: { app },
            hasPostEventAccess: { true },
            fullKeyboardAccessEnabled: { true }
        )
        let accessibility = TestAccessibilityActionPerformer()
        let router = SemanticActionRouter(
            session: session,
            keyboardAccessController: keyboard,
            accessibilityActionController: accessibility,
            visualActionController: TestVisualActionPerformer()
        )
        let lease = try store.acquire(scope: .session, application: nil, seconds: 30, confirm: true)

        let report = try router.perform(
            command: .activate,
            selector: Selector(role: "AXButton", title: "Save"),
            leaseToken: lease.token,
            count: 1,
            interKeyDelay: 0,
            allowRawCoordinate: false
        )

        XCTAssertEqual(report.route, .accessibility)
        XCTAssertFalse(report.fallbackUsed)
        XCTAssertEqual(report.keyCount, 0)
        XCTAssertEqual(accessibility.pressCount, 1)
        XCTAssertTrue(sender.keys.isEmpty)
        XCTAssertEqual(report.verification.state, .foregroundOnly)
        XCTAssertFalse(report.verification.focusChanged)
        XCTAssertEqual(report.verification.focusAfter?.title, "Save")
    }

    func testKeyboardNavigationPassesOnlyAfterFocusChanges() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let sender = RecordingKeyboardEventSender()
        let store = KeyboardDriveStore()
        let before = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXTextField",
            subrole: nil,
            identifier: "address",
            title: nil
        )
        let after = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXButton",
            subrole: nil,
            identifier: "reload",
            title: "Reload"
        )
        let session = ControlSession(
            keyboardDriveStore: store,
            focusedElementInspector: SequencedFocusedElementInspector([before, after]),
            foregroundApplication: { app },
            hasPostEventAccess: { true },
            fullKeyboardAccessEnabled: { true }
        )
        let router = SemanticActionRouter(
            session: session,
            keyboardAccessController: KeyboardAccessController(
                eventSender: sender,
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            accessibilityActionController: TestAccessibilityActionPerformer(),
            visualActionController: TestVisualActionPerformer()
        )
        let lease = try store.acquire(scope: .session, application: nil, seconds: 30, confirm: true)

        let report = try router.perform(
            command: .nextControl,
            selector: nil,
            leaseToken: lease.token,
            count: 1,
            interKeyDelay: 0,
            allowRawCoordinate: false
        )

        XCTAssertEqual(sender.keys, ["tab"])
        XCTAssertEqual(report.verification.state, .passed)
        XCTAssertTrue(report.verification.focusChanged)
        XCTAssertEqual(report.verification.focusAfter?.identifier, "reload")
    }

    func testKeyboardNavigationUsesRedactedIdentityForAnonymousControls() throws {
        let app = testApp(name: "ChatGPT", processID: 42)
        let sender = RecordingKeyboardEventSender()
        let store = KeyboardDriveStore()
        let before = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXButton",
            subrole: nil,
            identifier: nil,
            title: nil,
            identityFingerprint: "anonymous-button-a"
        )
        let after = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXButton",
            subrole: nil,
            identifier: nil,
            title: nil,
            identityFingerprint: "anonymous-button-b"
        )
        let session = ControlSession(
            keyboardDriveStore: store,
            focusedElementInspector: SequencedFocusedElementInspector([before, after]),
            foregroundApplication: { app },
            hasPostEventAccess: { true },
            fullKeyboardAccessEnabled: { true }
        )
        let router = SemanticActionRouter(
            session: session,
            keyboardAccessController: KeyboardAccessController(
                eventSender: sender,
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            accessibilityActionController: TestAccessibilityActionPerformer(),
            visualActionController: TestVisualActionPerformer()
        )
        let lease = try store.acquire(scope: .session, application: nil, seconds: 30, confirm: true)

        let report = try router.perform(
            command: .nextControl,
            selector: nil,
            leaseToken: lease.token,
            count: 1,
            interKeyDelay: 0,
            allowRawCoordinate: false
        )

        XCTAssertEqual(sender.keys, ["tab"])
        XCTAssertEqual(report.verification.state, .passed)
        XCTAssertTrue(report.verification.focusChanged)
        XCTAssertEqual(report.verification.focusAfter?.identityFingerprint, "anonymous-button-b")
    }

    func testSemanticRouterFallsBackFromMissingAccessibilityElementToKeyboard() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let sender = RecordingKeyboardEventSender()
        let store = KeyboardDriveStore()
        let keyboard = KeyboardAccessController(
            eventSender: sender,
            preferenceStore: TestKeyboardPreferenceStore(enabled: true)
        )
        let session = ControlSession(
            keyboardDriveStore: store,
            focusedElementInspector: TestFocusedElementInspector(snapshot: FocusedElementSnapshot(
                targetApplication: app,
                role: "AXButton",
                subrole: nil,
                identifier: nil,
                title: "Save"
            )),
            foregroundApplication: { app },
            hasPostEventAccess: { true },
            fullKeyboardAccessEnabled: { true }
        )
        let accessibility = TestAccessibilityActionPerformer(error: .elementNotFound)
        let router = SemanticActionRouter(
            session: session,
            keyboardAccessController: keyboard,
            accessibilityActionController: accessibility,
            visualActionController: TestVisualActionPerformer()
        )
        let lease = try store.acquire(scope: .session, application: nil, seconds: 30, confirm: true)

        let report = try router.perform(
            command: .activate,
            selector: Selector(role: "AXButton", title: "Save"),
            leaseToken: lease.token,
            count: 1,
            interKeyDelay: 0,
            allowRawCoordinate: false,
            fallbackChain: [.keyboard]
        )

        XCTAssertEqual(report.route, .keyboard)
        XCTAssertTrue(report.fallbackUsed)
        XCTAssertEqual(sender.keys, ["space"])
    }

    func testSemanticRouterRequiresExplicitRawCoordinateFallback() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let store = KeyboardDriveStore()
        let keyboard = KeyboardAccessController(
            eventSender: RecordingKeyboardEventSender(),
            preferenceStore: TestKeyboardPreferenceStore(enabled: true)
        )
        let session = ControlSession(
            keyboardDriveStore: store,
            focusedElementInspector: TestFocusedElementInspector(snapshot: FocusedElementSnapshot(
                targetApplication: app,
                role: nil,
                subrole: nil,
                identifier: nil,
                title: nil
            )),
            foregroundApplication: { app },
            hasPostEventAccess: { true },
            fullKeyboardAccessEnabled: { true }
        )
        let router = SemanticActionRouter(
            session: session,
            keyboardAccessController: keyboard,
            accessibilityActionController: TestAccessibilityActionPerformer(),
            visualActionController: TestVisualActionPerformer()
        )
        let lease = try store.acquire(scope: .session, application: nil, seconds: 30, confirm: true)

        XCTAssertThrowsError(try router.perform(
            command: .activate,
            selector: Selector(rawX: 10, rawY: 20),
            leaseToken: lease.token,
            count: 1,
            interKeyDelay: 0,
            allowRawCoordinate: false
        )) { error in
            XCTAssertEqual(error as? SemanticActionRouterError, .rawCoordinateRequiresExplicitOptIn)
        }
    }

    func testControlSessionFailsClosedWhenAppScopedForegroundChangesAfterInput() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let other = testApp(name: "Safari", processID: 43)
        var foreground = app
        let sender = CallbackKeyboardEventSender {
            foreground = other
        }
        let store = KeyboardDriveStore()
        let keyboard = KeyboardAccessController(
            eventSender: sender,
            preferenceStore: TestKeyboardPreferenceStore(enabled: true)
        )
        let session = ControlSession(
            keyboardDriveStore: store,
            focusedElementInspector: TestFocusedElementInspector(snapshot: FocusedElementSnapshot(
                targetApplication: app,
                role: "AXTextField",
                subrole: nil,
                identifier: "address",
                title: nil
            )),
            foregroundApplication: { foreground },
            hasPostEventAccess: { true },
            fullKeyboardAccessEnabled: { true }
        )
        let router = SemanticActionRouter(
            session: session,
            keyboardAccessController: keyboard,
            accessibilityActionController: TestAccessibilityActionPerformer(),
            visualActionController: TestVisualActionPerformer()
        )
        let lease = try store.acquire(scope: .app, application: app, seconds: 30, confirm: true)

        XCTAssertThrowsError(try router.perform(
            command: .nextControl,
            selector: nil,
            leaseToken: lease.token,
            count: 1,
            interKeyDelay: 0,
            allowRawCoordinate: false
        )) { error in
            XCTAssertEqual(
                error as? KeyboardControlError,
                .appScopeMismatch(expected: "com.example.chrome", actual: "com.example.safari")
            )
        }
    }

    func testControlServiceExposesSessionAndSemanticActionMethods() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let sender = RecordingKeyboardEventSender()
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: sender,
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            keyboardDriveStore: KeyboardDriveStore(),
            focusedElementInspector: TestFocusedElementInspector(snapshot: FocusedElementSnapshot(
                targetApplication: app,
                role: "AXTextField",
                subrole: nil,
                identifier: "address",
                title: nil
            )),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            hasPostEventAccess: { true }
        )
        let status = service.handle(RequestEnvelope(method: "control.status"))
        XCTAssertEqual(status.status, .succeeded)
        XCTAssertEqual(status.result["foregroundApplication"]?.objectValue?["name"]?.stringValue, "Chrome")

        let lease = service.handle(RequestEnvelope(
            method: "keyboard.lease.acquire",
            params: ["scope": .string("session"), "confirm": .bool(true)]
        ))
        let token = try XCTUnwrap(lease.result["lease"]?.objectValue?["token"]?.stringValue)
        let action = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("next-control"),
                "lease_token": .string(token),
                "inter_key_ms": .number(0)
            ]
        ))
        XCTAssertEqual(action.status, .succeeded)
        XCTAssertEqual(action.result["route"]?.stringValue, "keyboard")
        XCTAssertEqual(sender.keys, ["tab"])
    }

    func testAtomicControlWaitsForForegroundAndReleasesEphemeralLease() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let other = testApp(name: "Safari", processID: 43)
        let before = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXTextField",
            subrole: nil,
            identifier: "address",
            title: nil
        )
        let after = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXButton",
            subrole: nil,
            identifier: "reload",
            title: "Reload"
        )
        var foreground = other
        var now = Date(timeIntervalSince1970: 100)
        let store = KeyboardDriveStore()
        let sender = RecordingKeyboardEventSender()
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: sender,
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            keyboardDriveStore: store,
            focusedElementInspector: SequencedFocusedElementInspector([before, after]),
            foregroundApplication: { foreground },
            activateApplication: { _ in
                foreground = app
                return app
            },
            foregroundStabilityVerifier: ControlStateVerifier(
                now: { now },
                sleep: { interval in now = now.addingTimeInterval(interval) }
            ),
            hasPostEventAccess: { true }
        )

        let action = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("next-control"),
                "app": .string("Chrome"),
                "confirm": .bool(true),
                "inter_key_ms": .number(0)
            ]
        ))

        XCTAssertEqual(action.status, .succeeded)
        XCTAssertEqual(action.result["verification"]?.objectValue?["state"]?.stringValue, "passed")
        XCTAssertEqual(sender.keys, ["tab"])
        XCTAssertNil(store.activeLease())
        XCTAssertEqual(action.evidence.first?.metadata["lease_mode"]?.stringValue, "ephemeral")
        XCTAssertEqual(action.evidence.first?.metadata["lease_released"]?.boolValue, true)
    }

    func testAtomicControlUsesExactForegroundProcessFastPath() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let before = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXTextField",
            subrole: nil,
            identifier: "address",
            title: nil
        )
        let after = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXButton",
            subrole: nil,
            identifier: "reload",
            title: "Reload"
        )
        var activationCount = 0
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: RecordingKeyboardEventSender(),
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            focusedElementInspector: SequencedFocusedElementInspector([before, after]),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            activateApplication: { _ in
                activationCount += 1
                return app
            },
            hasPostEventAccess: { true }
        )

        let action = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("next-control"),
                "app": .string("Chrome"),
                "confirm": .bool(true),
                "inter_key_ms": .number(0)
            ]
        ))

        XCTAssertEqual(action.status, .succeeded)
        XCTAssertEqual(activationCount, 0)
        XCTAssertEqual(action.evidence.first?.metadata["foreground_fast_path"]?.boolValue, true)
        XCTAssertEqual(action.evidence.first?.metadata["foreground_reasserted"]?.boolValue, true)
        XCTAssertEqual(action.result["verification"]?.objectValue?["state"]?.stringValue, "passed")
    }

    func testAtomicControlReceiptCarriesExplicitForegroundOracle() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let before = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXTextField",
            subrole: nil,
            identifier: "address",
            title: nil
        )
        let after = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXButton",
            subrole: nil,
            identifier: "reload",
            title: "Reload"
        )
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: RecordingKeyboardEventSender(),
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            focusedElementInspector: SequencedFocusedElementInspector([before, after]),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            hasPostEventAccess: { true }
        )

        let action = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("next-control"),
                "app": .string("Chrome"),
                "confirm": .bool(true),
                "focus_policy": .string("foreground"),
                "inter_key_ms": .number(0)
            ]
        ))

        XCTAssertEqual(action.status, .succeeded)
        XCTAssertEqual(action.result["focusPolicy"]?.stringValue, "foreground")
        XCTAssertEqual(action.result["verification"]?.objectValue?["state"]?.stringValue, "passed")
        XCTAssertEqual(
            action.result["verification"]?.objectValue?["foregroundChanged"]?.boolValue,
            false
        )
        XCTAssertEqual(action.evidence.first?.metadata["focus_policy"]?.stringValue, "foreground")
        XCTAssertEqual(
            action.evidence.first?.metadata["foreground_oracle"]?.stringValue,
            "target_foreground_unchanged"
        )
        XCTAssertEqual(action.evidence.first?.metadata["foreground_state"]?.stringValue, "preserved")
        XCTAssertEqual(action.outcome?.state, .verifiedSuccess)
    }

    func testAtomicControlRejectsDirectBackgroundWithTaskRunHandoff() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let sender = RecordingKeyboardEventSender()
        var activationCount = 0
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: sender,
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            activateApplication: { _ in
                activationCount += 1
                return app
            },
            hasPostEventAccess: { true }
        )

        let action = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("next-control"),
                "app": .string("Chrome"),
                "confirm": .bool(true),
                "focus_policy": .string("background")
            ]
        ))

        XCTAssertEqual(action.status, .blocked)
        XCTAssertEqual(action.error?.code, MacCtlErrorCode.backgroundUnsupported.rawValue)
        XCTAssertEqual(action.error?.details["focus_policy"]?.stringValue, "background")
        XCTAssertEqual(action.error?.details["failure_class"]?.stringValue, "action_unavailable")
        XCTAssertEqual(action.error?.details["recommended_surface"]?.stringValue, "task.run")
        XCTAssertEqual(
            action.error?.details["next_action"]?.stringValue,
            "submit_named_background_task_plan"
        )
        XCTAssertEqual(action.outcome?.state, .actionUnavailable)
        XCTAssertEqual(action.outcome?.nextAction, "submit_named_background_task_plan")
        XCTAssertEqual(action.evidence.first?.kind, "focus_guard")
        XCTAssertEqual(activationCount, 0)
        XCTAssertTrue(sender.keys.isEmpty)
    }

    func testRepeatedTaskRouteSelectionIsCachedWithinHeldLease() throws {
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-route-cache-\(UUID().uuidString)")
        let warmPathStore = WarmPathStore(directory: directory)
        _ = try warmPathStore.recordBenchmark(
            application: app,
            taskID: "focus-next",
            targetFingerprint: "focus-v1",
            verificationOracle: "focus changed",
            route: .keyboard,
            requiredPermissions: [],
            latencyMs: 1,
            p95LatencyMs: 1,
            verificationRate: 1,
            samples: 3,
            contextIdentity: testWarmPathContext()
        )
        let before = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXTextField",
            subrole: nil,
            identifier: "address",
            title: nil
        )
        let after = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXButton",
            subrole: nil,
            identifier: "reload",
            title: "Reload"
        )
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: RecordingKeyboardEventSender(),
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            keyboardDriveStore: KeyboardDriveStore(),
            focusedElementInspector: SequencedFocusedElementInspector([before, after, before, after]),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            hasPostEventAccess: { true },
            warmPathStore: warmPathStore
        )

        let leaseResponse = service.handle(RequestEnvelope(
            method: "keyboard.lease.acquire",
            params: [
                "scope": .string("app"),
                "app": .string("Chrome"),
                "confirm": .bool(true),
                "seconds": .number(30)
            ]
        ))
        let token = try XCTUnwrap(leaseResponse.result["lease"]?.objectValue?["token"]?.stringValue)

        func perform() -> ResponseEnvelope {
            service.handle(RequestEnvelope(
                method: "control.perform",
                params: [
                    "action": .string("next-control"),
                    "lease_token": .string(token),
                    "task": .string("focus-next"),
                    "target_fingerprint": .string("focus-v1"),
                    "inter_key_ms": .number(0)
                ]
            ))
        }

        let first = perform()
        let second = perform()
        XCTAssertEqual(first.status, .succeeded)
        XCTAssertEqual(second.status, .succeeded)
        XCTAssertEqual(first.evidence.first?.metadata["route_selection_cache"]?.stringValue, "miss")
        XCTAssertEqual(second.evidence.first?.metadata["route_selection_cache"]?.stringValue, "hit")
        _ = service.handle(RequestEnvelope(
            method: "keyboard.lease.release",
            params: ["token": .string(token)]
        ))
    }

    func testFailedWarmActionExpiresManifestAndInvalidatesLeaseCache() throws {
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-route-demotion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let warmPathStore = WarmPathStore(directory: directory)
        _ = try warmPathStore.recordBenchmark(
            application: app,
            taskID: "focus-next",
            targetFingerprint: "focus-v1",
            verificationOracle: "focus changed",
            route: .keyboard,
            requiredPermissions: [],
            latencyMs: 1,
            p95LatencyMs: 1,
            verificationRate: 1,
            samples: 3,
            contextIdentity: testWarmPathContext()
        )
        let unchanged = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXTextField",
            subrole: nil,
            identifier: "address",
            title: nil
        )
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: RecordingKeyboardEventSender(),
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            keyboardDriveStore: KeyboardDriveStore(),
            focusedElementInspector: SequencedFocusedElementInspector([unchanged, unchanged]),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            hasPostEventAccess: { true },
            warmPathStore: warmPathStore
        )
        let lease = service.handle(RequestEnvelope(
            method: "keyboard.lease.acquire",
            params: [
                "scope": .string("app"),
                "app": .string("Chrome"),
                "confirm": .bool(true),
                "seconds": .number(30)
            ]
        ))
        let token = try XCTUnwrap(lease.result["lease"]?.objectValue?["token"]?.stringValue)
        let request = RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("next-control"),
                "lease_token": .string(token),
                "task": .string("focus-next"),
                "target_fingerprint": .string("focus-v1"),
                "inter_key_ms": .number(0)
            ]
        )

        let failed = service.handle(request)
        XCTAssertEqual(failed.status, .succeeded)
        XCTAssertEqual(failed.result["verification"]?.objectValue?["state"]?.stringValue, "foreground_only")
        let manifest = try XCTUnwrap(warmPathStore.inspect(
            application: app,
            taskID: "focus-next",
            targetFingerprint: "focus-v1"
        ))
        let candidate = try XCTUnwrap(manifest.candidates.first)
        XCTAssertFalse(candidate.isFresh(at: Date()))
        XCTAssertEqual(candidate.telemetry.verificationFailureCount, 1)

        let retried = service.handle(request)
        XCTAssertEqual(retried.status, .blocked)
        XCTAssertTrue(retried.error?.message.contains("rebenchmark") == true)
        _ = service.handle(RequestEnvelope(
            method: "keyboard.lease.release",
            params: ["token": .string(token)]
        ))
    }

    func testControlBatchSharesLeaseAndReportsPerStepRouteCacheHits() throws {
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-control-batch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let warmPathStore = WarmPathStore(directory: directory)
        _ = try warmPathStore.recordBenchmark(
            application: app,
            taskID: "focus-next",
            targetFingerprint: "focus-v1",
            verificationOracle: "focus changed",
            route: .keyboard,
            latencyMs: 1,
            p95LatencyMs: 1,
            verificationRate: 1,
            samples: 3,
            contextIdentity: testWarmPathContext()
        )
        let before = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXTextField",
            subrole: nil,
            identifier: "address",
            title: nil
        )
        let after = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXButton",
            subrole: nil,
            identifier: "reload",
            title: "Reload"
        )
        var activationCount = 0
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: RecordingKeyboardEventSender(),
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            focusedElementInspector: SequencedFocusedElementInspector([before, after, before, after]),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            activateApplication: { _ in
                activationCount += 1
                return app
            },
            hasPostEventAccess: { true },
            warmPathStore: warmPathStore
        )
        let action = JSONValue.object([
            "action": .string("next-control"),
            "inter_key_ms": .number(0)
        ])
        let response = service.handle(RequestEnvelope(
            method: "control.batch",
            params: [
                "app": .string("Chrome"),
                "confirm": .bool(true),
                "task": .string("focus-next"),
                "target_fingerprint": .string("focus-v1"),
                "actions": .array([action, action])
            ]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(response.outcome?.state, .verifiedSuccess)
        XCTAssertEqual(response.result["completedCount"]?.intValue, 2)
        XCTAssertEqual(response.result["routeSelectionCacheHits"]?.intValue, 1)
        XCTAssertEqual(response.result["leaseReleased"]?.boolValue, true)
        XCTAssertEqual(response.result["steps"]?.arrayValue?.count, 2)
        XCTAssertEqual(activationCount, 0)
        XCTAssertNil(service.handle(RequestEnvelope(method: "control.status")).result["lease"])
    }

    func testControlBatchStopsOnUnverifiedStepAndReleasesLease() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let store = KeyboardDriveStore()
        let before = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXTextField",
            subrole: nil,
            identifier: "address",
            title: nil
        )
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: RecordingKeyboardEventSender(),
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            keyboardDriveStore: store,
            focusedElementInspector: SequencedFocusedElementInspector([before, before]),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            hasPostEventAccess: { true }
        )
        let response = service.handle(RequestEnvelope(
            method: "control.batch",
            params: [
                "app": .string("Chrome"),
                "confirm": .bool(true),
                "actions": .array([.object([
                    "action": .string("next-control"),
                    "inter_key_ms": .number(0)
                ])])
            ]
        ))

        XCTAssertEqual(response.status, .blocked)
        XCTAssertEqual(response.outcome?.state, .actionFailed)
        XCTAssertEqual(response.error?.details["completed_count"]?.intValue, 0)
        XCTAssertEqual(response.error?.details["lease_released"]?.boolValue, true)
        XCTAssertNil(store.activeLease())
    }

    func testControlCapabilitiesSurfaceMeasuredRoutesAndAgentHandoffContract() throws {
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-control-capabilities-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let warmPathStore = WarmPathStore(directory: directory)
        _ = try warmPathStore.recordBenchmark(
            application: app,
            taskID: "focus-next",
            targetFingerprint: "focus-v1",
            verificationOracle: "focus changed",
            route: .keyboard,
            latencyMs: 1,
            p95LatencyMs: 1,
            verificationRate: 1,
            samples: 3,
            contextIdentity: testWarmPathContext()
        )
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            warmPathStore: warmPathStore
        )
        let response = service.handle(RequestEnvelope(
            method: "control.capabilities",
            params: [
                "app": .string("Chrome"),
                "task": .string("focus-next"),
                "target_fingerprint": .string("focus-v1")
            ]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(response.result["archetype"]?.stringValue, "browser")
        XCTAssertEqual(response.result["manifestFound"]?.boolValue, true)
        XCTAssertEqual(response.result["freshMeasuredRoutes"]?.arrayValue?.first?.stringValue, "keyboard")
        XCTAssertEqual(response.result["routeSelectionPolicy"]?.stringValue, "repeated_verified_context_bound_measurement_only")
        XCTAssertEqual(response.result["handoffProviders"]?.arrayValue?.first?.stringValue, "computer_use")
    }

    func testWebContentCapabilitiesAndExecutionReturnBrowserHandoffWithoutActivation() {
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        var activationCount = 0
        var resolvedApplicationSelectors: [String] = []
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            resolveApplication: {
                resolvedApplicationSelectors.append($0)
                return app
            },
            activateApplication: { _ in
                activationCount += 1
                return app
            }
        )

        let capabilities = service.handle(RequestEnvelope(
            method: "control.capabilities",
            params: [
                "app": .string("Chrome"),
                "target_surface": .string("web_content")
            ]
        ))

        XCTAssertEqual(capabilities.status, .succeeded)
        XCTAssertEqual(capabilities.result["targetSurface"]?.stringValue, "web_content")
        XCTAssertEqual(capabilities.result["localExecution"]?.stringValue, "provider_handoff_required")
        XCTAssertEqual(capabilities.result["foregroundRequirement"]?.stringValue, "not_required_by_surface")
        XCTAssertEqual(capabilities.result["providerHandoffRequired"]?.boolValue, true)
        XCTAssertEqual(capabilities.result["recommendedProvider"]?.stringValue, "browser_dom")
        XCTAssertTrue(
            capabilities.result["handoffProviders"]?.arrayValue?.contains(.string("browser_dom")) == true
        )
        XCTAssertEqual(resolvedApplicationSelectors.first, "Google Chrome")

        let execution = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("next-control"),
                "app": .string("Chrome"),
                "confirm": .bool(true),
                "target_surface": .string("web_content")
            ]
        ))

        XCTAssertEqual(execution.status, .blocked)
        XCTAssertEqual(execution.error?.code, MacCtlErrorCode.providerHandoffRequired.rawValue)
        XCTAssertEqual(execution.error?.details["recommended_surface"]?.stringValue, "browser_connector")
        XCTAssertEqual(execution.outcome?.state, .actionUnavailable)
        XCTAssertEqual(execution.outcome?.recommendedProvider, "browser_dom")
        XCTAssertEqual(execution.outcome?.nextAction, "submit_browser_target_plan")
        XCTAssertEqual(activationCount, 0)
    }

    func testRouteBenchmarkExecutesAndVerifiesDaemonSamplesBeforePersistence() throws {
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-route-benchmark-\(UUID().uuidString)")
        let warmPathStore = WarmPathStore(directory: directory)
        let before = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXTextField",
            subrole: nil,
            identifier: "address",
            title: nil
        )
        let after = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXButton",
            subrole: nil,
            identifier: "reload",
            title: "Reload"
        )
        var activationCount = 0
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: RecordingKeyboardEventSender(),
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            focusedElementInspector: SequencedFocusedElementInspector([before, after, before, after]),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            activateApplication: { _ in
                activationCount += 1
                return app
            },
            hasPostEventAccess: { true },
            warmPathStore: warmPathStore
        )

        let response = service.handle(RequestEnvelope(
            method: "route.benchmark",
            params: [
                "app": .string("Chrome"),
                "task": .string("focus-next"),
                "target_fingerprint": .string("focus-v1"),
                "verification_oracle": .string("focus changed"),
                "action": .string("next-control"),
                "route": .string("keyboard"),
                "samples": .number(2),
                "warmups": .number(0),
                "inter_key_ms": .number(0),
                "confirm": .bool(true)
            ]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(response.result["measurement_source"]?.stringValue, "daemon_executed")
        XCTAssertEqual(response.result["verification_rate"]?.doubleValue, 1)
        XCTAssertEqual(response.result["foreground_fast_path_samples"]?.doubleValue, 2)
        XCTAssertEqual(response.evidence.first?.metadata["measurement_source"]?.stringValue, "daemon_executed")
        XCTAssertEqual(response.evidence.first?.metadata["foreground_fast_path_samples"]?.doubleValue, 2)
        XCTAssertEqual(activationCount, 0)
        XCTAssertEqual(warmPathStore.list().first?.candidates.first?.sampleCount, 2)
        XCTAssertEqual(warmPathStore.list().first?.candidates.first?.measurementSource, .daemonExecuted)
        XCTAssertTrue(warmPathStore.list().first?.candidates.first?.isMeasured == true)
    }

    func testCapabilityProfileStoreKeysIdentityAndInvalidatesSupersededProfiles() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-capability-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 5_000)
        let store = CapabilityProfileStore(directory: directory, now: { now })
        let appV1 = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let appV2 = testApp(name: "Chrome", processID: 43, bundleVersion: "2")
        let granted = CapabilityProviderState(
            permissions: [CapabilityPermissionState(name: "Accessibility", state: "granted")],
            observedProviders: ["accessibility"]
        )
        let changedProvider = CapabilityProviderState(
            permissions: [CapabilityPermissionState(name: "Accessibility", state: "missing")],
            observedProviders: []
        )
        let tree = capabilityTree(for: appV1, identifier: "results", scrollable: true)
        let profileV1 = CapabilityProfileBuilder.build(
            application: appV1,
            osVersion: "macOS Test",
            providerState: granted,
            tree: tree,
            now: now
        )
        _ = try store.save(profileV1)

        let exact = store.lookup(application: appV1, osVersion: "macOS Test", providerState: granted)
        XCTAssertTrue(exact.cacheHit)
        XCTAssertEqual(exact.profile?.identity.application.version, "1")
        XCTAssertTrue(exact.profile?.identity.treeSignature.isEmpty == false)

        let localizedName = AppInfo(
            name: "Google Chrome",
            bundleID: appV1.bundleID,
            path: appV1.path,
            isRunning: appV1.isRunning,
            processID: appV1.processID,
            bundleVersion: appV1.bundleVersion
        )
        XCTAssertTrue(
            store.lookup(application: localizedName, osVersion: "macOS Test", providerState: granted).cacheHit,
            "cache identity must not depend on a localized display name"
        )

        let versionMismatch = store.lookup(application: appV2, osVersion: "macOS Test", providerState: granted)
        XCTAssertFalse(versionMismatch.cacheHit)
        XCTAssertTrue(versionMismatch.invalidationReasons.contains(.applicationVersionChanged))

        let changedTree = capabilityTree(for: appV1, identifier: "new-results", scrollable: false)
        let profileTreeV2 = CapabilityProfileBuilder.build(
            application: appV1,
            osVersion: "macOS Test",
            providerState: granted,
            tree: changedTree,
            now: now.addingTimeInterval(1)
        )
        _ = try store.save(profileTreeV2)
        XCTAssertTrue(store.list().contains {
            $0.identity.treeSignature == profileV1.identity.treeSignature
                && $0.state == .invalidated
                && $0.invalidationReasons.contains(.treeChanged)
        })
        XCTAssertTrue(store.lookup(application: appV1, osVersion: "macOS Test", providerState: granted).cacheHit)

        let providerMismatch = store.lookup(
            application: appV1,
            osVersion: "macOS Test",
            providerState: changedProvider
        )
        XCTAssertFalse(providerMismatch.cacheHit)
        XCTAssertTrue(providerMismatch.invalidationReasons.contains(.providerStateChanged))

        let osMismatch = store.lookup(
            application: appV1,
            osVersion: "macOS Newer Test",
            providerState: granted
        )
        XCTAssertFalse(osMismatch.cacheHit)
        XCTAssertTrue(osMismatch.invalidationReasons.contains(.osChanged))

        let profileV2 = CapabilityProfileBuilder.build(
            application: appV2,
            osVersion: "macOS Test",
            providerState: granted,
            tree: capabilityTree(for: appV2, identifier: "results-v2", scrollable: true),
            now: now.addingTimeInterval(2)
        )
        _ = try store.save(profileV2)
        let refreshedVersion = store.lookup(
            application: appV2,
            osVersion: "macOS Test",
            providerState: granted
        )
        XCTAssertTrue(refreshedVersion.cacheHit)
        XCTAssertTrue(refreshedVersion.invalidationReasons.isEmpty)
        XCTAssertFalse(refreshedVersion.summary.deepAuditRecommended)
    }

    func testCapabilityScrollLocatorsUseAncestorDigestsToDisambiguateRepeatedTargets() throws {
        let app = testApp(name: "Pronto", processID: 42, bundleVersion: "1")
        let state = AccessibilityTreeNodeState(
            enabled: true,
            focused: false,
            selected: false,
            expanded: nil,
            visible: true,
            settable: false,
            hasValue: false
        )
        let main = AccessibilityTreeNode(
            path: "0/0",
            depth: 1,
            role: "AXGroup",
            subrole: nil,
            identifier: "main-content",
            label: "Main",
            actions: [],
            state: state,
            bounds: nil,
            childCount: 1,
            scrollable: false
        )
        let sidebar = AccessibilityTreeNode(
            path: "0/1",
            depth: 1,
            role: "AXGroup",
            subrole: nil,
            identifier: "sidebar",
            label: "Sidebar",
            actions: [],
            state: state,
            bounds: nil,
            childCount: 1,
            scrollable: false
        )
        let mainScroll = AccessibilityTreeNode(
            path: "0/0/0",
            depth: 2,
            role: "AXScrollArea",
            subrole: nil,
            identifier: nil,
            label: "Content",
            actions: ["AXScrollDown"],
            state: state,
            bounds: CGRect(x: 320, y: 80, width: 960, height: 640),
            childCount: 0,
            scrollable: true
        )
        let sidebarScroll = AccessibilityTreeNode(
            path: "0/1/0",
            depth: 2,
            role: "AXScrollArea",
            subrole: nil,
            identifier: nil,
            label: "Content",
            actions: ["AXScrollDown"],
            state: state,
            bounds: CGRect(x: 0, y: 80, width: 300, height: 640),
            childCount: 0,
            scrollable: true
        )
        let tree = AccessibilityTreeReport(
            application: app,
            maxNodes: 20,
            maxDepth: 4,
            nodeCount: 4,
            truncated: false,
            nodes: [main, sidebar, mainScroll, sidebarScroll],
            identifierMatchCounts: ["main-content": 1, "sidebar": 1],
            nameMatchCounts: ["Main": 1, "Sidebar": 1, "Content": 2]
        )
        let profile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: CapabilityProviderState(observedProviders: ["accessibility"]),
            tree: tree
        )
        let scrollLocators = profile.locators.filter(\.scrollable)

        XCTAssertEqual(scrollLocators.count, 2)
        XCTAssertNotEqual(scrollLocators[0].ancestorDigest, scrollLocators[1].ancestorDigest)
        XCTAssertNotEqual(scrollLocators[0].geometryDigest, scrollLocators[1].geometryDigest)
        XCTAssertEqual(Set(scrollLocators.map(\.identityDigest)).count, 1)

        let selected = try XCTUnwrap(scrollLocators.first)
        let selector = Selector(
            role: "AXScrollArea",
            locatorDigest: selected.identityDigest,
            ancestorDigest: selected.ancestorDigest,
            geometryDigest: selected.geometryDigest
        )
        let actionLocator = try XCTUnwrap(
            CapabilityLocatorDescriptor.from(selector: selector, route: .scroll)
        )
        XCTAssertEqual(actionLocator.identityDigest, selected.identityDigest)
        XCTAssertEqual(actionLocator.ancestorDigest, selected.ancestorDigest)
        XCTAssertEqual(actionLocator.geometryDigest, selected.geometryDigest)
        XCTAssertEqual(
            try JSONCodec.decode(Selector.self, from: JSONCodec.encode(selector)),
            selector
        )
    }

    func testAccessibilitySearchDoesNotTraverseApplicationWindowAliasesTwice() {
        XCTAssertFalse(AccessibilityController.shouldTraverseApplicationChild(role: "AXWindow"))
        XCTAssertTrue(AccessibilityController.shouldTraverseApplicationChild(role: "AXMenu"))
        XCTAssertTrue(AccessibilityController.shouldTraverseApplicationChild(role: nil))
    }

    func testCapabilityProfilePromotionDemotionAndAmbiguousEvidenceAreExplicit() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-capability-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 6_000)
        let store = CapabilityProfileStore(directory: directory, now: { now })
        let app = testApp(name: "System Settings", processID: 42, bundleVersion: "1")
        let providerState = CapabilityProviderState(
            permissions: [CapabilityPermissionState(name: "Accessibility", state: "granted")],
            observedProviders: ["accessibility"]
        )
        let profile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: providerState,
            tree: capabilityTree(for: app, identifier: "settings", scrollable: true),
            now: now
        )
        _ = try store.save(profile)
        let selector = Selector(role: "AXScrollArea", identifier: "settings", title: "Settings")

        let promoted = try store.recordTaskVerification(
            application: app,
            osVersion: "macOS Test",
            providerState: providerState,
            taskID: "scroll-settings",
            targetFingerprint: "target-private-value",
            route: .scroll,
            selector: selector,
            kind: .positive,
            reason: "verified_action"
        )
        let promotedRecord = try XCTUnwrap(promoted?.capabilities.first { $0.id == "task.scroll-settings.scroll" })
        XCTAssertEqual(promotedRecord.state, .promoted)
        XCTAssertEqual(promotedRecord.positiveEvidenceCount, 1)
        XCTAssertTrue(promoted?.evidence.first?.targetFingerprintDigest != "target-private-value")
        let encoded = String(decoding: try JSONCodec.encode(promoted!), as: UTF8.self)
        XCTAssertFalse(encoded.contains("AXUIElement"))
        XCTAssertFalse(encoded.contains("target-private-value"))

        let demoted = try store.recordTaskVerification(
            application: app,
            osVersion: "macOS Test",
            providerState: providerState,
            taskID: "scroll-settings",
            targetFingerprint: "target-private-value",
            route: .scroll,
            selector: selector,
            kind: .negative,
            reason: "stale_element"
        )
        let demotedRecord = try XCTUnwrap(demoted?.capabilities.first { $0.id == "task.scroll-settings.scroll" })
        XCTAssertEqual(demotedRecord.state, .demoted)
        XCTAssertEqual(demotedRecord.negativeEvidenceCount, 1)
        XCTAssertEqual(demoted?.state, .stale)
        XCTAssertTrue(demoted?.invalidationReasons.contains(.staleElement) == true)

        let ambiguous = try store.recordTaskVerification(
            application: app,
            osVersion: "macOS Test",
            providerState: providerState,
            taskID: "scroll-settings",
            targetFingerprint: "target-private-value",
            route: .scroll,
            selector: selector,
            kind: .ambiguous,
            reason: "target_ambiguous"
        )
        let ambiguousRecord = try XCTUnwrap(ambiguous?.capabilities.first { $0.id == "task.scroll-settings.scroll" })
        XCTAssertEqual(ambiguousRecord.state, .candidate)
        XCTAssertEqual(ambiguousRecord.ambiguousEvidenceCount, 1)
        XCTAssertTrue(ambiguous?.invalidationReasons.contains(.targetAmbiguous) == true)

        let noScrollProfile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: providerState,
            tree: capabilityTree(for: app, identifier: "settings", scrollable: false),
            now: now.addingTimeInterval(1)
        )
        let noScrollRecord = try XCTUnwrap(noScrollProfile.capabilities.first { $0.id == "semantic_scroll" })
        XCTAssertEqual(noScrollRecord.state, .demoted)
        XCTAssertEqual(noScrollRecord.negativeEvidenceCount, 1)

        let truncatedProfile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: providerState,
            tree: capabilityTree(for: app, identifier: "settings", scrollable: false, truncated: true),
            now: now.addingTimeInterval(2)
        )
        let truncatedRecord = try XCTUnwrap(truncatedProfile.capabilities.first { $0.id == "semantic_scroll" })
        XCTAssertEqual(truncatedRecord.state, .candidate)
        XCTAssertEqual(truncatedRecord.ambiguousEvidenceCount, 1)

        let duplicateNode = AccessibilityTreeNode(
            path: "0/1",
            depth: 1,
            role: "AXScrollArea",
            subrole: nil,
            identifier: "settings",
            label: "Public label",
            actions: ["AXScrollDown"],
            state: AccessibilityTreeNodeState(
                enabled: true,
                focused: false,
                selected: false,
                expanded: nil,
                visible: true,
                settable: false,
                hasValue: false
            ),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            childCount: 0,
            scrollable: true
        )
        let duplicateTree = capabilityTree(for: app, identifier: "settings", scrollable: true)
        let ambiguousScrollProfile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: providerState,
            tree: AccessibilityTreeReport(
                application: app,
                maxNodes: 20,
                maxDepth: 4,
                nodeCount: 3,
                truncated: false,
                nodes: duplicateTree.nodes + [duplicateNode],
                identifierMatchCounts: ["settings": 2],
                nameMatchCounts: ["Public label": 2]
            ),
            now: now.addingTimeInterval(3)
        )
        let ambiguousScrollRecord = try XCTUnwrap(
            ambiguousScrollProfile.capabilities.first { $0.id == "semantic_scroll" }
        )
        XCTAssertEqual(ambiguousScrollRecord.state, .candidate)
        XCTAssertEqual(ambiguousScrollRecord.lastReason, "repeated_scroll_locator_ambiguous")
        XCTAssertEqual(ambiguousScrollRecord.ambiguousEvidenceCount, 1)

        let failed = try store.recordTaskVerification(
            application: app,
            osVersion: "macOS Test",
            providerState: providerState,
            taskID: "scroll-settings",
            targetFingerprint: "target-private-value",
            route: .scroll,
            selector: selector,
            kind: .negative,
            reason: "verification_failed"
        )
        XCTAssertTrue(failed?.invalidationReasons.contains(.verificationFailed) == true)
    }

    func testCapabilityProfileDoesNotPromoteIncidentalScrollActions() throws {
        let app = testApp(name: "Pronto", processID: 42, bundleVersion: "1")
        let state = AccessibilityTreeNodeState(
            enabled: true,
            focused: false,
            selected: false,
            expanded: nil,
            visible: true,
            settable: false,
            hasValue: false
        )
        let incidentalNode = AccessibilityTreeNode(
            path: "0/0",
            depth: 1,
            role: "AXStaticText",
            subrole: nil,
            identifier: "content",
            label: "Content",
            actions: ["AXScrollToVisible"],
            state: state,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            childCount: 0,
            scrollable: false
        )
        let incidentalProfile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: CapabilityProviderState(observedProviders: ["accessibility"]),
            tree: AccessibilityTreeReport(
                application: app,
                maxNodes: 20,
                maxDepth: 4,
                nodeCount: 1,
                truncated: false,
                nodes: [incidentalNode],
                identifierMatchCounts: ["content": 1],
                nameMatchCounts: ["Content": 1]
            )
        )
        let incidentalRecord = try XCTUnwrap(
            incidentalProfile.capabilities.first { $0.id == "semantic_scroll" }
        )
        XCTAssertEqual(incidentalRecord.state, .demoted)
        XCTAssertEqual(incidentalRecord.lastReason, "scrollable_element_not_present_in_complete_tree")
        XCTAssertTrue(incidentalProfile.locators.allSatisfy { !$0.scrollable })

        let roleOnlyNode = AccessibilityTreeNode(
            path: "0/0",
            depth: 1,
            role: "AXScrollArea",
            subrole: nil,
            identifier: "content",
            label: "Content",
            actions: ["AXScrollToVisible", "AXShowMenu"],
            state: state,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            childCount: 0,
            scrollable: true
        )
        let roleOnlyProfile = CapabilityProfileBuilder.build(
            application: app,
            osVersion: "macOS Test",
            providerState: CapabilityProviderState(observedProviders: ["accessibility"]),
            tree: AccessibilityTreeReport(
                application: app,
                maxNodes: 20,
                maxDepth: 4,
                nodeCount: 1,
                truncated: false,
                nodes: [roleOnlyNode],
                identifierMatchCounts: ["content": 1],
                nameMatchCounts: ["Content": 1]
            )
        )
        let roleOnlyRecord = try XCTUnwrap(
            roleOnlyProfile.capabilities.first { $0.id == "semantic_scroll" }
        )
        XCTAssertEqual(roleOnlyRecord.state, .candidate)
        XCTAssertEqual(roleOnlyRecord.lastReason, "directional_scroll_action_not_observed")
        XCTAssertEqual(roleOnlyProfile.locators.filter(\.scrollable).count, 1)
    }

    func testCapabilityProfileStorePreservesUnrelatedApplicationProfiles() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-capability-unrelated-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 7_000)
        let store = CapabilityProfileStore(directory: directory, now: { now })
        let chrome = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let notes = testApp(name: "Notes", processID: 43, bundleVersion: "1")
        let providerState = CapabilityProviderState(
            permissions: [CapabilityPermissionState(name: "Accessibility", state: "granted")],
            observedProviders: ["accessibility"]
        )

        let chromeProfile = CapabilityProfileBuilder.build(
            application: chrome,
            osVersion: "macOS Test",
            providerState: providerState,
            tree: capabilityTree(for: chrome, identifier: "chrome-results", scrollable: true),
            now: now
        )
        let notesProfile = CapabilityProfileBuilder.build(
            application: notes,
            osVersion: "macOS Test",
            providerState: providerState,
            tree: capabilityTree(for: notes, identifier: "notes-body", scrollable: false),
            now: now
        )

        _ = try store.save(chromeProfile)
        _ = try store.save(notesProfile)

        XCTAssertTrue(store.lookup(application: chrome, osVersion: "macOS Test", providerState: providerState).cacheHit)
        XCTAssertTrue(store.lookup(application: notes, osVersion: "macOS Test", providerState: providerState).cacheHit)
        XCTAssertFalse(store.list().contains {
            $0.identity.application.bundleID == chrome.bundleID && $0.state == .invalidated
        })
    }

    func testFastCapabilityProbeDoesNotWalkTreeAndDeepAuditPopulatesCache() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-capability-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let inspector = RecordingAccessibilityTreeInspector(
            tree: capabilityTree(for: app, identifier: "results", scrollable: true)
        )
        let profileStore = CapabilityProfileStore(directory: directory)
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            capabilityProfileStore: profileStore,
            accessibilityTreeInspector: inspector,
            capabilityAuditOpportunityScheduler: { _ in }
        )

        let fast = service.handle(RequestEnvelope(
            method: "control.capabilities",
            params: ["app": .string("Chrome")]
        ))
        XCTAssertEqual(fast.status, .succeeded)
        XCTAssertEqual(fast.result["probeMode"]?.stringValue, "fast_route_probe")
        XCTAssertNil(inspector.lastMaxNodes)
        XCTAssertEqual(fast.result["cachedBroadProfile"]?.objectValue?["cacheHit"]?.boolValue, false)
        XCTAssertEqual(fast.result["cachedBroadProfile"]?.objectValue?["deepAuditRecommended"]?.boolValue, true)
        XCTAssertEqual(fast.result["auditOpportunity"]?.objectValue?["state"]?.stringValue, "scheduled")

        let deep = service.handle(RequestEnvelope(
            method: "control.capability_audit",
            params: ["app": .string("Chrome")]
        ))
        XCTAssertEqual(deep.status, .succeeded)
        XCTAssertEqual(deep.result["auditDepth"]?.stringValue, "deep_read_only")
        XCTAssertEqual(inspector.lastMaxNodes, 500)
        XCTAssertEqual(profileStore.list().count, 1)

        let fastWithCache = service.handle(RequestEnvelope(
            method: "control.capabilities",
            params: ["app": .string("Chrome")]
        ))
        XCTAssertEqual(fastWithCache.status, .succeeded)
        XCTAssertEqual(fastWithCache.result["cachedBroadProfile"]?.objectValue?["cacheHit"]?.boolValue, true)
        XCTAssertEqual(inspector.lastMaxNodes, 500)
    }

    func testCapabilityProbeUsesNormalRunningAppAsReadOnlyAuditOpportunity() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-capability-opportunity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = testApp(name: "Notes", processID: 42, bundleVersion: "1")
        let inspector = RecordingAccessibilityTreeInspector(
            tree: capabilityTree(for: app, identifier: "notes-body", scrollable: true)
        )
        let profileStore = CapabilityProfileStore(directory: directory)
        var scheduledWork: (() -> Void)?
        var scheduleCount = 0
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            capabilityProfileStore: profileStore,
            accessibilityTreeInspector: inspector,
            capabilityAuditOpportunityScheduler: { work in
                scheduleCount += 1
                scheduledWork = work
            }
        )

        let first = service.handle(RequestEnvelope(
            method: "control.capabilities",
            params: ["app": .string("Notes")]
        ))
        XCTAssertEqual(first.status, .succeeded)
        XCTAssertEqual(first.result["auditOpportunity"]?.objectValue?["state"]?.stringValue, "scheduled")
        XCTAssertEqual(first.result["auditOpportunity"]?.objectValue?["launchesApplications"]?.boolValue, false)
        XCTAssertEqual(first.result["auditOpportunity"]?.objectValue?["dispatchesActions"]?.boolValue, false)
        XCTAssertEqual(scheduleCount, 1)
        XCTAssertNil(inspector.lastMaxNodes)

        let duplicate = service.handle(RequestEnvelope(
            method: "control.capabilities",
            params: ["app": .string("Notes")]
        ))
        XCTAssertEqual(duplicate.result["auditOpportunity"]?.objectValue?["state"]?.stringValue, "in_progress")
        XCTAssertEqual(scheduleCount, 1)

        try XCTUnwrap(scheduledWork)()
        XCTAssertEqual(inspector.lastMaxNodes, 500)
        XCTAssertEqual(profileStore.list().count, 1)

        let satisfied = service.handle(RequestEnvelope(
            method: "control.capabilities",
            params: ["app": .string("Notes")]
        ))
        XCTAssertEqual(satisfied.result["auditOpportunity"]?.objectValue?["state"]?.stringValue, "satisfied")
        XCTAssertEqual(scheduleCount, 1)
    }

    func testCapabilityProbeDoesNotAuditWebContentOrLaunchClosedApps() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-capability-opportunity-boundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runningBrowser = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let closedApp = AppInfo(
            name: "Notes",
            bundleID: "com.apple.Notes",
            path: "/Applications/Notes.app",
            isRunning: false,
            processID: nil,
            bundleVersion: "1"
        )
        let inspector = RecordingAccessibilityTreeInspector(
            tree: capabilityTree(for: runningBrowser, identifier: "web-area", scrollable: true)
        )
        var scheduleCount = 0
        let service = MacCtlService(
            permissionContext: "test",
            resolveApplication: { selector in selector == "Notes" ? closedApp : runningBrowser },
            capabilityProfileStore: CapabilityProfileStore(directory: directory),
            accessibilityTreeInspector: inspector,
            capabilityAuditOpportunityScheduler: { _ in scheduleCount += 1 }
        )

        let web = service.handle(RequestEnvelope(
            method: "control.capabilities",
            params: [
                "app": .string("Chrome"),
                "target_surface": .string("web_content")
            ]
        ))
        XCTAssertEqual(web.status, .succeeded)
        XCTAssertEqual(web.result["auditOpportunity"]?.objectValue?["state"]?.stringValue, "not_applicable")

        let closed = service.handle(RequestEnvelope(
            method: "control.capabilities",
            params: ["app": .string("Notes")]
        ))
        XCTAssertEqual(closed.status, .succeeded)
        XCTAssertEqual(closed.result["auditOpportunity"]?.objectValue?["state"]?.stringValue, "not_observed")
        XCTAssertEqual(scheduleCount, 0)
        XCTAssertNil(inspector.lastMaxNodes)
    }

    func testCapabilityAuditRetriesTruncatedTreesWithinBoundedCeiling() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-capability-adaptive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let inspector = AdaptiveRecordingAccessibilityTreeInspector { maxNodes, maxDepth in
            capabilityTree(
                for: app,
                identifier: "results",
                scrollable: true,
                truncated: maxNodes < 1_000 || maxDepth < 16
            )
        }
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            capabilityProfileStore: CapabilityProfileStore(directory: directory),
            accessibilityTreeInspector: inspector
        )

        let response = service.handle(RequestEnvelope(
            method: "control.capability_audit",
            params: ["app": .string("Chrome")]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(response.result["state"]?.stringValue, "valid")
        XCTAssertEqual(inspector.requests.map { "\($0.maxNodes)/\($0.maxDepth)" }, ["500/8", "1000/16"])
        let evidence = try XCTUnwrap(response.evidence.first(where: { $0.kind == "control_capability_audit" }))
        XCTAssertEqual(evidence.metadata["audit_attempts"]?.intValue, 2)
        XCTAssertEqual(evidence.metadata["adaptive_retry"]?.boolValue, true)
        XCTAssertEqual(evidence.metadata["effective_max_nodes"]?.intValue, 1_000)
        XCTAssertEqual(evidence.metadata["effective_max_depth"]?.intValue, 16)
        XCTAssertEqual(evidence.metadata["adaptive_ceiling_reached"]?.boolValue, false)
    }

    func testCapabilityAuditKeepsTruncatedProfileStaleAtBoundedCeiling() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-capability-adaptive-ceiling-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let inspector = AdaptiveRecordingAccessibilityTreeInspector { maxNodes, maxDepth in
            capabilityTree(
                for: app,
                identifier: "results",
                scrollable: true,
                truncated: true
            )
        }
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            capabilityProfileStore: CapabilityProfileStore(directory: directory),
            accessibilityTreeInspector: inspector
        )

        let response = service.handle(RequestEnvelope(
            method: "control.capability_audit",
            params: [
                "app": .string("Chrome"),
                "max_nodes": .number(500),
                "max_depth": .number(8)
            ]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(response.result["state"]?.stringValue, "stale")
        XCTAssertEqual(inspector.requests.map { "\($0.maxNodes)/\($0.maxDepth)" }, ["500/8", "1000/16", "2000/20"])
        let evidence = try XCTUnwrap(response.evidence.first(where: { $0.kind == "control_capability_audit" }))
        XCTAssertEqual(evidence.metadata["audit_attempts"]?.intValue, 3)
        XCTAssertEqual(evidence.metadata["adaptive_ceiling_reached"]?.boolValue, true)
    }

    func testCapabilityAuditUsesWindowedPagesAfterRecursiveCeiling() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-capability-windowed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let coverage = AccessibilityTreeCoverage(
            mode: "windowed_pages",
            windowCount: 1,
            pageCount: 2,
            pages: [
                AccessibilityTreeCoveragePage(identityDigest: "window-digest", nodeCount: 12, truncated: false),
                AccessibilityTreeCoveragePage(identityDigest: "page-digest", nodeCount: 18, truncated: false)
            ],
            complete: true
        )
        let inspector = WindowedRecordingAccessibilityTreeInspector(
            recursiveTree: capabilityTree(
                for: app,
                identifier: "recursive-results",
                scrollable: true,
                truncated: true
            ),
            windowedTree: capabilityTree(
                for: app,
                identifier: "windowed-results",
                scrollable: true,
                coverage: coverage
            )
        )
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            capabilityProfileStore: CapabilityProfileStore(directory: directory),
            accessibilityTreeInspector: inspector
        )

        let response = service.handle(RequestEnvelope(
            method: "control.capability_audit",
            params: ["app": .string("Chrome")]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(response.result["state"]?.stringValue, "valid")
        XCTAssertEqual(inspector.recursiveRequests.map { "\($0.maxNodes)/\($0.maxDepth)" }, ["500/8", "1000/16", "2000/20"])
        XCTAssertEqual(inspector.windowedRequests.map { "\($0.maxNodesPerPage)/\($0.maxDepth)/\($0.maxWindows)/\($0.maxPages)" }, ["2000/20/8/256"])
        let evidence = try XCTUnwrap(response.evidence.first(where: { $0.kind == "control_capability_audit" }))
        XCTAssertEqual(evidence.metadata["traversal_mode"]?.stringValue, "windowed_pages")
        XCTAssertEqual(evidence.metadata["windowed_attempted"]?.boolValue, true)
        XCTAssertEqual(evidence.metadata["coverage_complete"]?.boolValue, true)
        XCTAssertEqual(evidence.metadata["window_count"]?.intValue, 1)
        XCTAssertEqual(evidence.metadata["page_count"]?.intValue, 2)
    }

    func testCapabilityAuditKeepsIncompleteWindowedCoverageStale() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-capability-windowed-stale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let coverage = AccessibilityTreeCoverage(
            mode: "windowed_pages",
            windowCount: 2,
            pageCount: 1,
            omittedWindowCount: 1,
            omittedPageCount: 3,
            pages: [AccessibilityTreeCoveragePage(identityDigest: "window-digest", nodeCount: 12, truncated: true)],
            complete: false
        )
        let inspector = WindowedRecordingAccessibilityTreeInspector(
            recursiveTree: capabilityTree(
                for: app,
                identifier: "recursive-results",
                scrollable: true,
                truncated: true
            ),
            windowedTree: capabilityTree(
                for: app,
                identifier: "windowed-results",
                scrollable: true,
                truncated: true,
                coverage: coverage
            )
        )
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            capabilityProfileStore: CapabilityProfileStore(directory: directory),
            accessibilityTreeInspector: inspector
        )

        let response = service.handle(RequestEnvelope(
            method: "control.capability_audit",
            params: ["app": .string("Chrome")]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(response.result["state"]?.stringValue, "stale")
        let evidence = try XCTUnwrap(response.evidence.first(where: { $0.kind == "control_capability_audit" }))
        XCTAssertEqual(evidence.metadata["traversal_mode"]?.stringValue, "windowed_pages")
        XCTAssertEqual(evidence.metadata["coverage_complete"]?.boolValue, false)
        XCTAssertEqual(evidence.metadata["omitted_window_count"]?.intValue, 1)
        XCTAssertEqual(evidence.metadata["omitted_page_count"]?.intValue, 3)
    }

    func testCapabilityAuditCatalogIsBoundedAndPrioritizesUserFacingApps() {
        let helper = AppInfo(
            name: "Background Helper",
            bundleID: "com.example.helper",
            path: "/Applications/Background Helper.app",
            isRunning: false,
            processID: nil,
            bundleVersion: "1"
        )
        let synchronizer = AppInfo(
            name: "Adobe Content Synchronizer",
            bundleID: "com.adobe.accmac",
            path: "/Applications/Utilities/Adobe Sync/CoreSync/Core Sync.app",
            isRunning: true,
            processID: 902,
            bundleVersion: "1"
        )
        let finder = AppInfo(
            name: "Finder",
            bundleID: "com.apple.finder",
            path: "/System/Library/CoreServices/Finder.app",
            isRunning: false,
            processID: nil,
            bundleVersion: "1"
        )
        let applications = [helper, synchronizer, finder] + (0..<30).map { index in
            AppInfo(
                name: "App \(index)",
                bundleID: "com.example.app\(index)",
                path: "/Applications/App \(index).app",
                isRunning: false,
                processID: nil,
                bundleVersion: "1"
            )
        }

        let targets = CapabilityAuditCatalog.defaultTargets(from: applications)

        XCTAssertEqual(targets.count, CapabilityAuditCatalog.maximumTargets)
        XCTAssertEqual(targets.first?.identity?.bundleID, "com.apple.finder")
        XCTAssertFalse(targets.contains { $0.displayName == "Background Helper" })
        XCTAssertFalse(targets.contains { $0.displayName == "Adobe Content Synchronizer" })
        XCTAssertEqual(Set(targets.map(\.stableKey)).count, targets.count)
    }

    func testCapabilityAuditBatchPersistsPerAppReceiptsAndResumesUnobservedApps() throws {
        let profileDirectory = URL(fileURLWithPath: "/private/tmp/macctl-capability-batch-profiles-\(UUID().uuidString)")
        let batchDirectory = URL(fileURLWithPath: "/private/tmp/macctl-capability-batch-runs-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: profileDirectory)
            try? FileManager.default.removeItem(at: batchDirectory)
        }

        let preview = testApp(name: "Preview", processID: 42, bundleVersion: "1")
        let textEditPath = "/Applications/TextEdit.app"
        let textEditBundleID = "com.example.textedit"
        var textEdit = AppInfo(
            name: "TextEdit",
            bundleID: textEditBundleID,
            path: textEditPath,
            isRunning: false,
            processID: nil,
            bundleVersion: "1"
        )
        let inspector = RecordingAccessibilityTreeInspector(
            tree: capabilityTree(for: preview, identifier: "results", scrollable: true)
        )
        let profileStore = CapabilityProfileStore(directory: profileDirectory)
        let batchStore = CapabilityAuditBatchStore(directory: batchDirectory)
        let service = MacCtlService(
            permissionContext: "test",
            resolveApplication: { selector in
                switch selector {
                case "Preview", preview.bundleID: return preview
                case "TextEdit", textEditBundleID: return textEdit
                default: throw AppControllerError.appNotFound(selector)
                }
            },
            capabilityProfileStore: profileStore,
            accessibilityTreeInspector: inspector,
            capabilityAuditBatchStore: batchStore
        )

        let first = service.handle(RequestEnvelope(
            method: "control.capability_audit_batch",
            params: [
                "apps": .array([.string("Preview"), .string("TextEdit")]),
                "max_apps": .number(2)
            ]
        ))
        XCTAssertEqual(first.status, .succeeded)
        XCTAssertEqual(first.result["readOnly"]?.boolValue, true)
        XCTAssertEqual(first.result["launchedApplications"]?.boolValue, false)
        XCTAssertEqual(first.result["processedCount"]?.intValue, 2)
        let runID = try XCTUnwrap(first.result["run"]?.objectValue?["runID"]?.stringValue)
        let savedAfterFirst = try batchStore.load(runID: runID)
        XCTAssertEqual(savedAfterFirst.entries.map(\.state), [.audited, .notObserved])
        XCTAssertEqual(savedAfterFirst.entries[1].reason, .applicationNotRunning)
        XCTAssertEqual(inspector.treeCallCount, 1)
        XCTAssertEqual(profileStore.list().count, 1)

        textEdit = AppInfo(
            name: "TextEdit",
            bundleID: textEditBundleID,
            path: textEditPath,
            isRunning: true,
            processID: 43,
            bundleVersion: "1"
        )
        let resumed = service.handle(RequestEnvelope(
            method: "control.capability_audit_batch",
            params: ["run_id": .string(runID), "max_apps": .number(1)]
        ))
        XCTAssertEqual(resumed.status, .succeeded)
        XCTAssertEqual(resumed.result["resumed"]?.boolValue, true)
        XCTAssertEqual(resumed.result["processedCount"]?.intValue, 1)
        let savedAfterResume = try batchStore.load(runID: runID)
        XCTAssertEqual(savedAfterResume.entries.map(\.state), [.audited, .audited])
        XCTAssertEqual(savedAfterResume.entries.map(\.attempts), [1, 2])
        XCTAssertEqual(inspector.treeCallCount, 2)

        let encoded = String(decoding: try JSONCodec.encode(savedAfterResume), as: UTF8.self)
        XCTAssertFalse(encoded.contains("AXUIElement"))
        XCTAssertFalse(encoded.contains("processID"))
    }

    func testCapabilityAuditBatchRejectsUnboundedAXConcurrency() {
        let service = MacCtlService(permissionContext: "test")
        let response = service.handle(RequestEnvelope(
            method: "control.capability_audit_batch",
            params: [
                "apps": .array([.string("Preview")]),
                "max_concurrency": .number(2)
            ]
        ))

        XCTAssertEqual(response.status, .blocked)
        XCTAssertTrue(response.error?.message.contains("serialized") == true)
    }

    func testCapabilityAuditBatchPrioritizesPendingTargetsBeforeRetryingNotObservedApps() throws {
        let profileDirectory = URL(fileURLWithPath: "/private/tmp/macctl-capability-batch-priority-profiles-\(UUID().uuidString)")
        let batchDirectory = URL(fileURLWithPath: "/private/tmp/macctl-capability-batch-priority-runs-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: profileDirectory)
            try? FileManager.default.removeItem(at: batchDirectory)
        }

        let closed = AppInfo(
            name: "Closed",
            bundleID: "com.example.closed",
            path: "/Applications/Closed.app",
            isRunning: false,
            processID: nil,
            bundleVersion: "1"
        )
        let runningApp = testApp(name: "Open", processID: 42, bundleVersion: "1")
        let laterApp = testApp(name: "Later", processID: 43, bundleVersion: "1")
        let inspector = RecordingAccessibilityTreeInspector(
            tree: capabilityTree(for: runningApp, identifier: "results", scrollable: true)
        )
        let profileStore = CapabilityProfileStore(directory: profileDirectory)
        let batchStore = CapabilityAuditBatchStore(directory: batchDirectory)
        let service = MacCtlService(
            permissionContext: "test",
            resolveApplication: { selector in
                switch selector {
                case "Closed", closed.bundleID: return closed
                case "Open", runningApp.bundleID: return runningApp
                case "Later", laterApp.bundleID: return laterApp
                default: throw AppControllerError.appNotFound(selector)
                }
            },
            capabilityProfileStore: profileStore,
            accessibilityTreeInspector: inspector,
            capabilityAuditBatchStore: batchStore
        )

        let first = service.handle(RequestEnvelope(
            method: "control.capability_audit_batch",
            params: [
                "apps": .array([.string("Closed"), .string("Open"), .string("Later")]),
                "max_apps": .number(1)
            ]
        ))
        XCTAssertEqual(first.status, .succeeded)
        let runID = try XCTUnwrap(first.result["run"]?.objectValue?["runID"]?.stringValue)
        let savedAfterFirst = try batchStore.load(runID: runID)
        XCTAssertEqual(savedAfterFirst.entries.map(\.state), [.notObserved, .pending, .pending])

        let resumed = service.handle(RequestEnvelope(
            method: "control.capability_audit_batch",
            params: ["run_id": .string(runID), "max_apps": .number(1)]
        ))
        XCTAssertEqual(resumed.status, .succeeded)
        let savedAfterResume = try batchStore.load(runID: runID)
        XCTAssertEqual(savedAfterResume.entries.map(\.state), [.notObserved, .audited, .pending])
        XCTAssertEqual(savedAfterResume.entries.map(\.attempts), [1, 1, 0])
        XCTAssertEqual(inspector.treeCallCount, 1)
    }

    func testSemanticScrollRouteBenchmarkExecutesAndPersistsDaemonSamples() throws {
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-route-scroll-benchmark-\(UUID().uuidString)")
        let warmPathStore = WarmPathStore(directory: directory)
        let scroll = RecordingAccessibilityScrollPerformer()
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            foregroundStabilityVerifier: ControlStateVerifier(sleep: { _ in }),
            hasPostEventAccess: { true },
            warmPathStore: warmPathStore,
            accessibilityScrollPerformer: scroll
        )

        let response = service.handle(RequestEnvelope(
            method: "route.benchmark",
            params: [
                "app": .string("Chrome"),
                "task": .string("scroll-main"),
                "target_fingerprint": .string("scroll-v1"),
                "verification_oracle": .string("viewport changed"),
                "action": .string("scroll"),
                "route": .string("scroll"),
                "selector": .object([
                    "role": .string("AXScrollArea"),
                    "identifier": .string("main-scroll")
                ]),
                "direction": .string("down"),
                "amount": .number(1),
                "reset_direction": .string("up"),
                "reset_amount": .number(1),
                "samples": .number(2),
                "warmups": .number(1),
                "confirm": .bool(true)
            ]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(response.result["measurement_source"]?.stringValue, "daemon_executed")
        XCTAssertEqual(response.result["route"]?.stringValue, "scroll")
        XCTAssertEqual(response.result["direction"]?.stringValue, "down")
        XCTAssertEqual(response.result["amount"]?.doubleValue, 1)
        XCTAssertEqual(response.result["verification_rate"]?.doubleValue, 1)
        XCTAssertEqual(response.result["foreground_fast_path_samples"]?.doubleValue, 2)
        XCTAssertEqual(response.evidence.first?.metadata["measurement_source"]?.stringValue, "daemon_executed")
        XCTAssertEqual(response.evidence.first?.metadata["route"]?.stringValue, "scroll")
        XCTAssertEqual(warmPathStore.list().first?.candidates.first?.route, .scroll)
        XCTAssertEqual(warmPathStore.list().first?.candidates.first?.measurementSource, .daemonExecuted)
        XCTAssertTrue(warmPathStore.list().first?.candidates.first?.isMeasured == true)
        XCTAssertEqual(warmPathStore.list().first?.candidates.first?.sampleCount, 2)
        XCTAssertEqual(warmPathStore.list().first?.candidates.first?.requiredPermissions, ["Accessibility"])
        XCTAssertEqual(scroll.calls.map { $0.direction }, [.up, .down, .up, .down, .up, .down])
        XCTAssertEqual(scroll.calls.map { $0.amount }, [1, 1, 1, 1, 1, 1])
    }

    func testSemanticScrollRouteBenchmarkAllowsRoleOnlySelector() throws {
        let app = testApp(name: "System Settings", processID: 42, bundleVersion: "1")
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-route-scroll-role-only-\(UUID().uuidString)")
        let warmPathStore = WarmPathStore(directory: directory)
        let scroll = RecordingAccessibilityScrollPerformer()
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            foregroundStabilityVerifier: ControlStateVerifier(sleep: { _ in }),
            hasPostEventAccess: { true },
            warmPathStore: warmPathStore,
            accessibilityScrollPerformer: scroll
        )

        let response = service.handle(RequestEnvelope(
            method: "route.benchmark",
            params: [
                "app": .string("System Settings"),
                "task": .string("scroll-sidebar"),
                "target_fingerprint": .string("system-settings-sidebar-v1"),
                "verification_oracle": .string("viewport changed"),
                "action": .string("scroll"),
                "route": .string("scroll"),
                "selector": .object([
                    "role": .string("AXScrollArea")
                ]),
                "direction": .string("down"),
                "amount": .number(1),
                "samples": .number(1),
                "warmups": .number(0),
                "confirm": .bool(true)
            ]
        ))

        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(response.result["measurement_source"]?.stringValue, "daemon_executed")
        XCTAssertEqual(response.result["route"]?.stringValue, "scroll")
        XCTAssertNil(scroll.lastSelector?.identifier)
        XCTAssertEqual(warmPathStore.list().first?.candidates.first?.route, .scroll)
        XCTAssertEqual(warmPathStore.list().first?.candidates.first?.measurementSource, .daemonExecuted)
    }

    func testSemanticScrollRouteBenchmarkRejectsUnverifiedSampleBeforePersistence() throws {
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-route-scroll-unverified-\(UUID().uuidString)")
        let warmPathStore = WarmPathStore(directory: directory)
        let scroll = RecordingAccessibilityScrollPerformer(verification: .noObservedChange)
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            foregroundStabilityVerifier: ControlStateVerifier(sleep: { _ in }),
            hasPostEventAccess: { true },
            warmPathStore: warmPathStore,
            accessibilityScrollPerformer: scroll
        )

        let response = service.handle(RequestEnvelope(
            method: "route.benchmark",
            params: [
                "app": .string("Chrome"),
                "task": .string("scroll-main"),
                "target_fingerprint": .string("scroll-v1"),
                "verification_oracle": .string("viewport changed"),
                "action": .string("scroll"),
                "route": .string("scroll"),
                "selector": .object([
                    "role": .string("AXScrollArea"),
                    "identifier": .string("main-scroll")
                ]),
                "direction": .string("down"),
                "amount": .number(1),
                "samples": .number(1),
                "warmups": .number(0),
                "confirm": .bool(true)
            ]
        ))

        XCTAssertEqual(response.status, .blocked)
        XCTAssertTrue(response.error?.message.contains("no route manifest was written") == true)
        XCTAssertTrue(warmPathStore.list().isEmpty)
        XCTAssertEqual(scroll.calls.count, 1)
    }

    func testSemanticScrollRouteBenchmarkRecordsTaskFailureWithoutManifest() throws {
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let warmPathDirectory = URL(fileURLWithPath: "/private/tmp/macctl-route-scroll-task-failure-\(UUID().uuidString)")
        let profileDirectory = URL(fileURLWithPath: "/private/tmp/macctl-route-scroll-task-profile-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: warmPathDirectory)
            try? FileManager.default.removeItem(at: profileDirectory)
        }
        let warmPathStore = WarmPathStore(directory: warmPathDirectory)
        let providerState = CapabilityProviderState(
            permissionStatuses: PermissionDiagnostics.unknownReport()
        )
        let profileStore = CapabilityProfileStore(directory: profileDirectory)
        _ = try profileStore.save(CapabilityProfileBuilder.build(
            application: app,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            providerState: providerState,
            tree: capabilityTree(for: app, identifier: "main-scroll", scrollable: true)
        ))
        let scroll = RecordingAccessibilityScrollPerformer(verification: .noObservedChange)
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            foregroundStabilityVerifier: ControlStateVerifier(sleep: { _ in }),
            hasPostEventAccess: { true },
            warmPathStore: warmPathStore,
            capabilityProfileStore: profileStore,
            accessibilityScrollPerformer: scroll
        )

        let response = service.handle(RequestEnvelope(
            method: "route.benchmark",
            params: [
                "app": .string("Chrome"),
                "task": .string("scroll-main"),
                "target_fingerprint": .string("scroll-v1"),
                "verification_oracle": .string("viewport changed"),
                "action": .string("scroll"),
                "route": .string("scroll"),
                "selector": .object([
                    "role": .string("AXScrollArea"),
                    "identifier": .string("main-scroll")
                ]),
                "direction": .string("down"),
                "amount": .number(1),
                "samples": .number(1),
                "warmups": .number(0),
                "confirm": .bool(true)
            ]
        ))

        XCTAssertEqual(response.status, .blocked)
        XCTAssertTrue(response.error?.message.contains("no route manifest was written") == true)
        XCTAssertTrue(warmPathStore.list().isEmpty)
        let profile = try XCTUnwrap(profileStore.list().first)
        let taskCapability = try XCTUnwrap(
            profile.capabilities.first { $0.id == "task.scroll-main.scroll" }
        )
        XCTAssertEqual(taskCapability.state, .demoted)
        XCTAssertEqual(taskCapability.lastReason, "verification_failed")
        XCTAssertEqual(profile.state, .stale)
        XCTAssertTrue(profile.invalidationReasons.contains(.verificationFailed))
    }

    func testSemanticScrollRouteBenchmarkRequiresResetForRepeatedSamples() throws {
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-route-scroll-reset-\(UUID().uuidString)")
        let warmPathStore = WarmPathStore(directory: directory)
        let scroll = RecordingAccessibilityScrollPerformer()
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            foregroundStabilityVerifier: ControlStateVerifier(sleep: { _ in }),
            hasPostEventAccess: { true },
            warmPathStore: warmPathStore,
            accessibilityScrollPerformer: scroll
        )

        let response = service.handle(RequestEnvelope(
            method: "route.benchmark",
            params: [
                "app": .string("Chrome"),
                "task": .string("scroll-main"),
                "target_fingerprint": .string("scroll-v1"),
                "verification_oracle": .string("viewport changed"),
                "action": .string("scroll"),
                "route": .string("scroll"),
                "selector": .object([
                    "role": .string("AXScrollArea"),
                    "identifier": .string("main-scroll")
                ]),
                "direction": .string("down"),
                "amount": .number(1),
                "samples": .number(2),
                "warmups": .number(0),
                "confirm": .bool(true)
            ]
        ))

        XCTAssertEqual(response.status, .blocked)
        XCTAssertTrue(response.error?.message.contains("reset-direction") == true)
        XCTAssertTrue(warmPathStore.list().isEmpty)
        XCTAssertTrue(scroll.calls.isEmpty)
    }

    func testRouteBenchmarkRejectsUnverifiedWarmupBeforePersistence() throws {
        let app = testApp(name: "Chrome", processID: 42, bundleVersion: "1")
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-route-warmup-\(UUID().uuidString)")
        let profileDirectory = URL(fileURLWithPath: "/private/tmp/macctl-route-warmup-profile-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: profileDirectory)
        }
        let warmPathStore = WarmPathStore(directory: directory)
        let providerState = CapabilityProviderState(
            permissionStatuses: PermissionDiagnostics.unknownReport()
        )
        let profileStore = CapabilityProfileStore(directory: profileDirectory)
        _ = try profileStore.save(CapabilityProfileBuilder.build(
            application: app,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            providerState: providerState,
            tree: capabilityTree(for: app, identifier: "address", scrollable: false)
        ))
        let focused = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXTextField",
            subrole: nil,
            identifier: "address",
            title: nil
        )
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: RecordingKeyboardEventSender(),
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            focusedElementInspector: SequencedFocusedElementInspector([focused, focused]),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            activateApplication: { _ in app },
            hasPostEventAccess: { true },
            warmPathStore: warmPathStore,
            capabilityProfileStore: profileStore
        )

        let response = service.handle(RequestEnvelope(
            method: "route.benchmark",
            params: [
                "app": .string("Chrome"),
                "task": .string("focus-next"),
                "target_fingerprint": .string("focus-v1"),
                "verification_oracle": .string("focus changed"),
                "action": .string("next-control"),
                "route": .string("keyboard"),
                "samples": .number(1),
                "warmups": .number(1),
                "inter_key_ms": .number(0),
                "confirm": .bool(true)
            ]
        ))

        XCTAssertEqual(response.status, .blocked)
        XCTAssertTrue(warmPathStore.list().isEmpty)
        let profile = try XCTUnwrap(profileStore.list().first)
        let taskCapability = try XCTUnwrap(
            profile.capabilities.first { $0.id == "task.focus-next.keyboard" }
        )
        XCTAssertEqual(taskCapability.state, .demoted)
        XCTAssertEqual(taskCapability.lastReason, "verification_failed")
        XCTAssertEqual(profile.state, .stale)
        XCTAssertTrue(profile.invalidationReasons.contains(.verificationFailed))
    }

    func testAtomicControlRequiresOneExplicitAuthorityModeAndConfirmation() throws {
        let app = testApp(name: "Chrome", processID: 42)
        var activationCount = 0
        let service = MacCtlService(
            permissionContext: "test",
            foregroundApplication: { app },
            activateApplication: { _ in
                activationCount += 1
                return app
            },
            hasPostEventAccess: { true }
        )

        let conflicting = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("next-control"),
                "lease_token": .string("caller-owned"),
                "app": .string("Chrome"),
                "confirm": .bool(true)
            ]
        ))
        XCTAssertEqual(conflicting.status, .blocked)
        XCTAssertEqual(conflicting.error?.code, MacCtlErrorCode.unsafeInput.rawValue)

        let unconfirmed = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("next-control"),
                "app": .string("Chrome")
            ]
        ))
        XCTAssertEqual(unconfirmed.status, .blocked)
        XCTAssertEqual(
            unconfirmed.error?.code,
            MacCtlErrorCode.keyboardConfirmationRequired.rawValue
        )
        XCTAssertEqual(activationCount, 0)
    }

    func testAtomicControlFailsClosedWhenForegroundIsStolenBeforeExecution() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let other = testApp(name: "Safari", processID: 43)
        var foregroundReads = 0
        var now = Date(timeIntervalSince1970: 100)
        let store = KeyboardDriveStore()
        let sender = RecordingKeyboardEventSender()
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: sender,
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            keyboardDriveStore: store,
            focusedElementInspector: TestFocusedElementInspector(snapshot: FocusedElementSnapshot(
                targetApplication: app,
                role: "AXTextField",
                subrole: nil,
                identifier: "address",
                title: nil
            )),
            foregroundApplication: {
                foregroundReads += 1
                return foregroundReads <= 2 ? app : other
            },
            activateApplication: { _ in app },
            foregroundStabilityVerifier: ControlStateVerifier(
                now: { now },
                sleep: { interval in now = now.addingTimeInterval(interval) }
            ),
            hasPostEventAccess: { true }
        )

        let action = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("next-control"),
                "app": .string("Chrome"),
                "confirm": .bool(true),
                "inter_key_ms": .number(0)
            ]
        ))

        XCTAssertEqual(action.status, .blocked)
        XCTAssertEqual(action.error?.code, MacCtlErrorCode.keyboardFocusChanged.rawValue)
        XCTAssertTrue(sender.keys.isEmpty)
        XCTAssertNil(store.activeLease())
    }

    func testAtomicControlCanEstablishInitiallyAbsentAccessibilityFocus() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let after = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXButton",
            subrole: nil,
            identifier: "reload",
            title: "Reload"
        )
        var now = Date(timeIntervalSince1970: 100)
        let store = KeyboardDriveStore()
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: KeyboardAccessController(
                eventSender: RecordingKeyboardEventSender(),
                preferenceStore: TestKeyboardPreferenceStore(enabled: true)
            ),
            keyboardDriveStore: store,
            focusedElementInspector: OptionalSequencedFocusedElementInspector([nil, after]),
            foregroundApplication: { app },
            activateApplication: { _ in app },
            foregroundStabilityVerifier: ControlStateVerifier(
                now: { now },
                sleep: { interval in now = now.addingTimeInterval(interval) }
            ),
            hasPostEventAccess: { true }
        )

        let action = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("next-control"),
                "app": .string("Chrome"),
                "confirm": .bool(true),
                "inter_key_ms": .number(0)
            ]
        ))

        XCTAssertEqual(action.status, .succeeded)
        XCTAssertEqual(action.result["verification"]?.objectValue?["state"]?.stringValue, "passed")
        XCTAssertEqual(
            action.result["verification"]?.objectValue?["focusAfter"]?.objectValue?["identifier"]?.stringValue,
            "reload"
        )
        XCTAssertNil(store.activeLease())
    }

    func testAtomicControlBlocksUnchangedReadableFocusAsUnverified() throws {
        let app = testApp(name: "Chrome", processID: 42)
        let focus = FocusedElementSnapshot(
            targetApplication: app,
            role: "AXTextField",
            subrole: nil,
            identifier: "address",
            title: nil
        )
        var now = Date(timeIntervalSince1970: 100)
        let store = KeyboardDriveStore()
        let keyboard = KeyboardAccessController(
            eventSender: RecordingKeyboardEventSender(),
            preferenceStore: TestKeyboardPreferenceStore(enabled: true)
        )
        let session = ControlSession(
            keyboardDriveStore: store,
            focusedElementInspector: TestFocusedElementInspector(snapshot: focus),
            foregroundApplication: { app },
            hasPostEventAccess: { true },
            fullKeyboardAccessEnabled: { true },
            verifier: ControlStateVerifier(
                now: { now },
                sleep: { interval in now = now.addingTimeInterval(interval) }
            ),
            postActionTimeout: 0
        )
        let router = SemanticActionRouter(
            session: session,
            keyboardAccessController: keyboard,
            accessibilityActionController: TestAccessibilityActionPerformer(),
            visualActionController: TestVisualActionPerformer()
        )
        let service = MacCtlService(
            permissionContext: "test",
            keyboardAccessController: keyboard,
            keyboardDriveStore: store,
            focusedElementInspector: TestFocusedElementInspector(snapshot: focus),
            controlSession: session,
            semanticActionRouter: router,
            foregroundApplication: { app },
            activateApplication: { _ in app },
            foregroundStabilityVerifier: ControlStateVerifier(
                now: { now },
                sleep: { interval in now = now.addingTimeInterval(interval) }
            ),
            hasPostEventAccess: { true }
        )

        let action = service.handle(RequestEnvelope(
            method: "control.perform",
            params: [
                "action": .string("next-control"),
                "app": .string("Chrome"),
                "confirm": .bool(true),
                "inter_key_ms": .number(0)
            ]
        ))

        XCTAssertEqual(action.status, .blocked)
        XCTAssertEqual(
            action.error?.code,
            MacCtlErrorCode.controlVerificationUnavailable.rawValue
        )
        XCTAssertEqual(action.outcome?.state, .verificationUnavailable)
        XCTAssertEqual(action.error?.details["failure_class"]?.stringValue, "verification_unavailable")
        XCTAssertEqual(action.error?.details["verification"]?.stringValue, "foreground_only")
        XCTAssertEqual(action.error?.details["fresh_state_required"]?.boolValue, true)
        XCTAssertNil(store.activeLease())
    }

    func testChromeCapabilitiesDeclareProviderBoundaryForTabGroupMutation() {
        let chrome = ControlCapabilityProfile(application: WarmPathApplicationIdentity(
            name: "Google Chrome",
            bundleID: "com.google.Chrome",
            path: "/Applications/Google Chrome.app"
        ))
        let safari = ControlCapabilityProfile(application: WarmPathApplicationIdentity(
            name: "Safari",
            bundleID: "com.apple.Safari",
            path: "/Applications/Safari.app"
        ))

        XCTAssertTrue(chrome.contractCapabilities.contains("window_scoped_accessibility_selector"))
        XCTAssertEqual(chrome.schemaVersion, 6)
        XCTAssertTrue(chrome.contractCapabilities.contains("control.capability_leads"))
        XCTAssertTrue(chrome.contractCapabilities.contains("verified_context_menu"))
        XCTAssertTrue(chrome.contractCapabilities.contains("control.blocker_observations"))
        XCTAssertEqual(chrome.unsupportedCapabilities, ["chrome_tab_group_mutation"])
        XCTAssertTrue(safari.unsupportedCapabilities.isEmpty)
    }

    func testLegacyDoctorAndCapabilityReportsDecodeWithoutKeyboardFields() throws {
        let doctor = try JSONCodec.decode(
            DoctorReport.self,
            from: Data(
                #"{"processID":1,"osVersion":"test","architecture":"arm64","socketPath":"/tmp/macctld.sock","socketOwnerOnly":true,"permissions":[],"availableFrameworks":[],"warnings":[],"permissionContext":"daemon","runtimeIdentity":{"processID":1,"executablePath":"/tmp/macctld","bundlePath":null,"bundleIdentifier":null,"bundleVersion":null},"launchAgent":null}"#.utf8
            )
        )
        XCTAssertNil(doctor.keyboardAccess)

        let capabilities = try JSONCodec.decode(
            CapabilityReport.self,
            from: Data(
                #"{"capabilities":["status"],"optionalBackends":[],"permissionGates":[],"safety":[]}"#.utf8
            )
        )
        XCTAssertNil(capabilities.keyboardAccess)
    }

    func testRemovedIPhoneMirroringSurfaceAndMethodsAreUnsupported() {
        XCTAssertEqual(SurfaceKind.allCases, [.macDesktop, .macApp])
        XCTAssertNil(WorkflowRegistry().workflow(id: "iphone.open-tinder"))

        let service = MacCtlService(permissionContext: "client")
        let methods = [
            "iphone.status",
            "iphone.drive.begin",
            "iphone.drive.end",
            "iphone.open-app"
        ]
        for method in methods {
            let response = service.handle(RequestEnvelope(
                method: method,
                params: method == "iphone.open-app" ? ["name": .string("Tinder")] : [:]
            ))
            XCTAssertEqual(response.status, .failed, method)
            XCTAssertEqual(response.error?.code, MacCtlErrorCode.unsupportedMethod.rawValue, method)
        }
    }

    func testBackgroundValidationRejectsGlobalSelectorsAndAcceptsAccessibilityTargets() {
        let visual = WorkflowSpec(
            id: "test.background.visual",
            name: "Visual",
            summary: "Test",
            surface: .macApp,
            focusPolicy: .background,
            actions: [ActionSpec(
                kind: .click,
                surface: .macApp,
                selector: Selector(containsText: "Save"),
                parameters: [
                    "app": .string("TextEdit"),
                    "approval_reason": .string("test")
                ]
            )]
        )
        let visualValidation = WorkflowRegistry().validate(visual)
        XCTAssertFalse(visualValidation.valid)
        XCTAssertTrue(visualValidation.errors.contains { $0.contains("Accessibility selector") })

        let accessibility = WorkflowSpec(
            id: "test.background.accessibility",
            name: "Accessibility",
            summary: "Test",
            surface: .macApp,
            focusPolicy: .background,
            actions: [ActionSpec(
                kind: .click,
                surface: .macApp,
                selector: Selector(role: "AXButton", title: "Save"),
                parameters: [
                    "app": .string("TextEdit"),
                    "approval_reason": .string("test")
                ]
            )]
        )
        XCTAssertTrue(WorkflowRegistry().validate(accessibility).valid)
    }

    func testBackgroundApprovalExecutionPreservesPolicyInResponseAndReceipt() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-background-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "client"
        )

        let prepared = service.handle(RequestEnvelope(
            method: "workflow.prepare",
            params: [
                "workflow": .string("approval.smoke"),
                "focus_policy": .string("background")
            ]
        ))
        XCTAssertEqual(prepared.status, .prepared)
        XCTAssertEqual(prepared.result["focus_policy"]?.stringValue, "background")
        let approval = try XCTUnwrap(prepared.result["approval"]?.objectValue)
        XCTAssertEqual(approval["focusPolicy"]?.stringValue, "background")
        let token = try XCTUnwrap(approval["token"]?.stringValue)

        let approved = service.handle(RequestEnvelope(
            method: "approval.approve",
            params: [
                "token": .string(token),
                "source": .string("test")
            ]
        ))
        XCTAssertEqual(approved.status, .succeeded)
        XCTAssertEqual(approved.result["approved"]?.boolValue, true)

        let executed = service.handle(RequestEnvelope(
            method: "workflow.run",
            params: [
                "workflow": .string("approval.smoke"),
                "approval_token": .string(token),
                "focus_policy": .string("background")
            ]
        ))
        XCTAssertEqual(
            executed.status,
            .succeeded,
            executed.error.map { "\($0.code): \($0.message) \($0.details)" } ?? "no error"
        )
        XCTAssertEqual(executed.result["focus_policy"]?.stringValue, "background")
        XCTAssertTrue(executed.evidence.contains { $0.kind == "focus_guard" })

        let receipts = try OperationReceiptStore(directory: receiptDirectory).list(limit: 10)
        XCTAssertEqual(
            receipts.first(where: { $0.method == "workflow.prepare" })?.focusPolicy,
            .background
        )
        XCTAssertEqual(
            receipts.first(where: { $0.method == "approval.approve" })?.focusPolicy,
            .background
        )
        XCTAssertEqual(
            receipts.first(where: { $0.method == "workflow.run" })?.focusPolicy,
            .background
        )
    }

    func testMismatchedBackgroundRunDoesNotConsumeApprovalToken() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-policy-mismatch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "client"
        )
        let prepared = service.handle(RequestEnvelope(
            method: "workflow.prepare",
            params: ["workflow": .string("approval.smoke")]
        ))
        let approval = try XCTUnwrap(prepared.result["approval"]?.objectValue)
        let token = try XCTUnwrap(approval["token"]?.stringValue)

        let mismatched = service.handle(RequestEnvelope(
            method: "workflow.run",
            params: [
                "workflow": .string("approval.smoke"),
                "approval_token": .string(token),
                "focus_policy": .string("background")
            ]
        ))
        XCTAssertEqual(mismatched.status, .blocked)
        XCTAssertEqual(mismatched.error?.code, MacCtlErrorCode.approvalRequired.rawValue)

        let approved = service.handle(RequestEnvelope(
            method: "approval.approve",
            params: ["token": .string(token)]
        ))
        XCTAssertEqual(approved.status, .succeeded)
    }

    func testApprovalExpiresAndCannotBeReused() throws {
        let store = ApprovalStore(lifetime: 0.02)
        let workflow = WorkflowSpec(
            id: "test.safe",
            name: "Safe",
            summary: "Test",
            surface: .macDesktop,
            actions: [ActionSpec(kind: .waitFor, surface: .macDesktop, parameters: ["seconds": .number(0)])]
        )
        let prepared = store.prepare(workflow: workflow)
        let approved = try store.approve(token: prepared.record.token)
        XCTAssertEqual(approved.planDigest, ApprovalStore.digest(workflow))
        XCTAssertThrowsError(try store.approve(token: prepared.record.token)) { error in
            XCTAssertEqual(error as? ApprovalStoreError, .alreadyUsed)
        }

        let expiring = store.prepare(workflow: workflow)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertThrowsError(try store.approve(token: expiring.record.token)) { error in
            XCTAssertEqual(error as? ApprovalStoreError, .expired)
        }
    }

    func testExpiredApprovalReceiptRetainsWorkflowAndControlCenterProvenance() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-expiry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let service = MacCtlService(
            approvalStore: ApprovalStore(lifetime: 0.02),
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "client"
        )

        let prepared = service.handle(RequestEnvelope(
            method: "workflow.prepare",
            params: ["workflow": .string("approval.smoke")]
        ))
        let approval = try XCTUnwrap(prepared.result["approval"]?.objectValue)
        let token = try XCTUnwrap(approval["token"]?.stringValue)

        Thread.sleep(forTimeInterval: 0.05)
        let expired = service.handle(RequestEnvelope(
            method: "approval.approve",
            params: [
                "token": .string(token),
                "source": .string("control_center")
            ]
        ))

        XCTAssertEqual(expired.status, .blocked)
        XCTAssertEqual(expired.error?.code, MacCtlErrorCode.approvalExpired.rawValue)
        XCTAssertEqual(expired.error?.details["workflow_id"]?.stringValue, "approval.smoke")

        let receipts = try OperationReceiptStore(directory: receiptDirectory).list(limit: 10)
        let preparedReceipt = try XCTUnwrap(receipts.first { $0.method == "workflow.prepare" })
        XCTAssertEqual(preparedReceipt.workflowID, "approval.smoke")
        XCTAssertEqual(preparedReceipt.approvalState, "prepared")
        let receipt = try XCTUnwrap(receipts.first { $0.method == "approval.approve" })
        XCTAssertEqual(receipt.workflowID, "approval.smoke")
        XCTAssertEqual(receipt.source, "control_center")
        XCTAssertEqual(receipt.status, .blocked)
        XCTAssertEqual(receipt.approvalState, "required")
        XCTAssertEqual(receipt.errorCode, MacCtlErrorCode.approvalExpired.rawValue)
        XCTAssertEqual(receipt.verificationResult, "blocked")
    }

    func testDoubleTapDetectorHonorsTimingAndResetsAfterDetection() {
        var detector = DoubleTapDetector(interval: 0.35)
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(detector.register(at: start))
        XCTAssertTrue(detector.register(at: start.addingTimeInterval(0.2)))
        XCTAssertFalse(detector.register(at: start.addingTimeInterval(0.3)))
        XCTAssertFalse(detector.register(at: start.addingTimeInterval(0.7)))
        XCTAssertTrue(detector.register(at: start.addingTimeInterval(0.8)))
    }

    func testWindowRelativeCoordinateMappingAndRedaction() throws {
        let point = try CoordinateMapper.windowPoint(
            normalized: NormalizedPoint(x: 0.25, y: 0.5),
            in: CGRect(x: 100, y: 200, width: 800, height: 400)
        )
        XCTAssertEqual(point.x, 300)
        XCTAssertEqual(point.y, 400)
        XCTAssertEqual(LogRedactor.redact(value: "do-not-log", key: "password"), "[REDACTED]")
        XCTAssertEqual(LogRedactor.redact(value: "Finder", key: "app"), "Finder")
    }

    func testImageAnchorMapsRetinaPixelsToWindowPoints() throws {
        let width = 40
        let height = 40
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not create test image context")
            return
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for row in 0..<8 {
            for column in 0..<8 {
                let color = (row + column).isMultiple(of: 2)
                    ? CGColor.black
                    : CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
                context.setFillColor(color)
                context.fill(CGRect(x: 10 + column, y: 8 + row, width: 1, height: 1))
            }
        }
        let target = try XCTUnwrap(context.makeImage())
        guard let anchorContext = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 8 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not create anchor image context")
            return
        }
        for row in 0..<8 {
            for column in 0..<8 {
                let color = (row + column).isMultiple(of: 2)
                    ? CGColor.black
                    : CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
                anchorContext.setFillColor(color)
                anchorContext.fill(CGRect(x: column, y: row, width: 1, height: 1))
            }
        }
        let anchor = try XCTUnwrap(anchorContext.makeImage())
        let path = "/private/tmp/macctl-anchor-\(UUID().uuidString).png"
        defer { unlink(path) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, anchor, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let frame = CaptureFrame(
            image: target,
            bounds: CGRect(x: 100, y: 200, width: 100, height: 100),
            windowID: nil,
            source: "test"
        )
        let match = try CaptureController().findImageAnchor(in: frame, path: path)
        XCTAssertEqual(match.bounds.minX, 125, accuracy: 2.5)
        XCTAssertEqual(match.bounds.minY, 220, accuracy: 2.5)
        XCTAssertEqual(match.bounds.width, 20, accuracy: 2.5)
        XCTAssertEqual(match.bounds.height, 20, accuracy: 2.5)
        XCTAssertLessThan(match.score, 0.22)
    }

    func testOwnerOnlyUnixSocketRoundTrip() throws {
        let path = "/private/tmp/macctl-test-\(UUID().uuidString).sock"
        let server = UnixSocketServer(path: path)
        defer { server.stop() }
        try server.start { data in
            let request = try! JSONCodec.decode(RequestEnvelope.self, from: data)
            let response = ResponseEnvelope(
                requestID: request.requestID,
                status: .succeeded,
                result: .object(["echo": .string(request.method)])
            )
            return try! JSONCodec.encode(response)
        }
        let response = try UnixSocketClient().send(RequestEnvelope(method: "test.echo"), to: path)
        XCTAssertEqual(response.status, .succeeded)
        XCTAssertEqual(response.result["echo"]?.stringValue, "test.echo")
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o600)
    }

    func testSocketServerReplacesStaleSocketButNotRegularFile() throws {
        let staleSocketPath = "/private/tmp/macctl-stale-\(UUID().uuidString).sock"
        let staleDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(staleDescriptor, 0)
        defer {
            close(staleDescriptor)
            unlink(staleSocketPath)
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(staleSocketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: pathBytes)
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(staleDescriptor, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)

        let server = UnixSocketServer(path: staleSocketPath)
        XCTAssertNoThrow(try server.start { _ in Data("{}".utf8) })
        server.stop()

        let regularFilePath = "/private/tmp/macctl-regular-\(UUID().uuidString)"
        XCTAssertTrue(FileManager.default.createFile(atPath: regularFilePath, contents: Data()))
        defer { unlink(regularFilePath) }
        XCTAssertThrowsError(try UnixSocketServer(path: regularFilePath).start { _ in Data() }) { error in
            XCTAssertEqual(error as? UnixSocketError, .socketPathIsNotSocket)
        }
    }

    func testDaemonBundleHasStableIdentityAndExecutablePath() {
        XCTAssertEqual(MacCtlDaemonBundle.bundleIdentifier, "com.jakyeamos.macctl.daemon")
        XCTAssertEqual(MacCtlDaemonBundle.infoPlist["CFBundleExecutable"] as? String, "macctld")
        XCTAssertEqual(MacCtlDaemonBundle.infoPlist["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(MacCtlDaemonBundle.infoPlist["LSUIElement"] as? Bool, true)
        XCTAssertTrue(MacCtlPaths.daemonAppURL.path.hasSuffix("/.local/share/macctl/macctld.app"))
        XCTAssertTrue(MacCtlPaths.daemonAppExecutableURL.path.hasSuffix("/.local/share/macctl/macctld.app/Contents/MacOS/macctld"))
    }

    func testCodeSigningIdentityParsingAndPreference() {
        let output = """
        1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Example"
        2) 89ABCDEF0123456789ABCDEF0123456789ABCDEF "Apple Development: Example (TEAM123456)"
        """
        let identities = MacCtlCodeSigning.parseIdentities(output)
        XCTAssertEqual(identities.count, 2)
        XCTAssertEqual(identities[0].hash, "0123456789ABCDEF0123456789ABCDEF01234567")
        XCTAssertEqual(
            MacCtlCodeSigning.preferredIdentity(from: identities)?.name,
            "Apple Development: Example (TEAM123456)"
        )
    }

    func testRuntimeIdentityDecodesBeforeSigningFieldsWereAdded() throws {
        let data = Data(
            #"{"processID":7,"executablePath":"/tmp/macctld","bundlePath":"/tmp/macctld.app","bundleIdentifier":"com.jakyeamos.macctl.daemon","bundleVersion":"1"}"#.utf8
        )
        let identity = try JSONCodec.decode(RuntimeIdentity.self, from: data)
        XCTAssertNil(identity.signingIdentity)
        XCTAssertNil(identity.signingTeamIdentifier)
        XCTAssertNil(identity.signatureValid)
    }

    func testLaunchAgentStatusRejectsStaleIdentityAndSpawnFailure() {
        let expected = "/Users/test/.local/share/macctl/macctld.app/Contents/MacOS/macctld"
        let healthyOutput = """
        gui/501/com.jakyeamos.macctl.daemon = {
            program = \(expected)
            pid = 4123
            state = running
            last exit code = 0
        }
        """
        let healthy = LaunchAgentStatus.fromLaunchctlOutput(
            plistPath: "/tmp/macctl.plist",
            installed: true,
            configuredExecutablePath: expected,
            expectedExecutablePath: expected,
            launchctlStatus: 0,
            output: healthyOutput
        )
        XCTAssertTrue(healthy.launchdLoaded)
        XCTAssertTrue(healthy.loaded)
        XCTAssertTrue(healthy.identityMatches)
        XCTAssertEqual(healthy.processID, 4123)

        let staleOutput = """
        gui/501/com.jakyeamos.macctl.daemon = {
            program = /Users/test/.local/bin/macctld
            state = spawn failed
            last exit code = 78: EX_CONFIG
        }
        """
        let stale = LaunchAgentStatus.fromLaunchctlOutput(
            plistPath: "/tmp/macctl.plist",
            installed: true,
            configuredExecutablePath: "/Users/test/.local/bin/macctld",
            expectedExecutablePath: expected,
            launchctlStatus: 0,
            output: staleOutput
        )
        XCTAssertTrue(stale.launchdLoaded)
        XCTAssertFalse(stale.loaded)
        XCTAssertFalse(stale.identityMatches)
        XCTAssertEqual(stale.lastExitCode, 78)
        XCTAssertEqual(stale.spawnError, "spawn failed")

        let nonzeroExit = LaunchAgentStatus.fromLaunchctlOutput(
            plistPath: "/tmp/macctl.plist",
            installed: true,
            configuredExecutablePath: expected,
            expectedExecutablePath: expected,
            launchctlStatus: 0,
            output: """
            gui/501/com.jakyeamos.macctl.daemon = {
                program = \(expected)
                pid = 4123
                state = running
                last exit code = 78: EX_CONFIG
            }
            """
        )
        XCTAssertFalse(nonzeroExit.loaded)
        XCTAssertFalse(nonzeroExit.healthy)
    }

    func testDefaultTestServiceIsolatesReceiptsFromProductionDirectory() throws {
        let service = MacCtlService(permissionContext: "test")

        let response = service.handle(RequestEnvelope(method: "receipts.status"))

        XCTAssertEqual(response.status, .succeeded)
        let directory = try XCTUnwrap(response.result["directory"]?.stringValue)
        XCTAssertTrue(directory.contains("macctl-test-receipts-"))
        XCTAssertNotEqual(directory, MacCtlPaths.receiptsDirectory.path)
    }

    func testOperationReceiptsAreBoundedOwnerOnlyAndDoNotPersistEvidenceText() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-receipts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OperationReceiptStore(directory: directory, maximumRecords: 2)
        let identity = RuntimeIdentity(
            processID: 123,
            executablePath: "/tmp/macctld",
            bundlePath: "/tmp/macctld.app",
            bundleIdentifier: MacCtlDaemonBundle.bundleIdentifier,
            bundleVersion: "1"
        )
        for index in 0..<3 {
            try store.record(OperationReceipt(
                operationID: "operation-\(index)",
                requestID: "request-\(index)",
                method: "workflow.run",
                workflowID: "textedit.open",
                targetSurface: .macApp,
                risk: .safe,
                executionResult: "succeeded",
                verificationResult: "passed",
                planDigest: "digest-\(index)",
                runtimeIdentity: identity,
                permissionContext: "daemon",
                permissions: [],
                status: .succeeded,
                errorCode: nil,
                evidence: [ReceiptEvidence(kind: "ocr", source: "screen")],
                startedAt: Date(timeIntervalSince1970: Double(index)),
                completedAt: Date(timeIntervalSince1970: Double(index + 1))
            ))
        }
        let receipts = try store.list(limit: 10)
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts.first?.executionResult, "succeeded")
        XCTAssertEqual(receipts.first?.verificationResult, "passed")
        XCTAssertEqual(store.status().pendingPrune, 0)

        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((directoryPermissions?.intValue ?? 0) & 0o777, 0o700)
        let receiptURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "json" })
        )
        let receiptPermissions = try FileManager.default.attributesOfItem(atPath: receiptURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((receiptPermissions?.intValue ?? 0) & 0o777, 0o600)
        let receiptText = try String(contentsOf: receiptURL)
        XCTAssertFalse(receiptText.contains("secret"))
        XCTAssertTrue(receiptText.contains("ocr"))
    }

    func testOperationReceiptDecoderAcceptsOlderReceipts() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "operationID": "legacy-operation",
              "requestID": "legacy-request",
              "method": "doctor",
              "approvalState": "not_required",
              "runtimeIdentity": {
                "processID": 123,
                "executablePath": "/tmp/macctld",
                "bundlePath": "/tmp/macctld.app",
                "bundleIdentifier": "com.jakyeamos.macctl.daemon",
                "bundleVersion": "1"
              },
              "permissionContext": "daemon",
              "permissions": [],
              "status": "succeeded",
              "evidence": [],
              "startedAt": "2026-07-22T00:00:00Z",
              "completedAt": "2026-07-22T00:00:01Z"
            }
            """.utf8
        )

        let receipt = try JSONCodec.decode(OperationReceipt.self, from: data)
        XCTAssertEqual(receipt.executionResult, "not_run")
        XCTAssertEqual(receipt.verificationResult, "not_run")
        XCTAssertNil(receipt.focusPolicy)
        XCTAssertNil(receipt.actionOutcome)
        XCTAssertNil(receipt.controlTarget)
    }

    func testUnavailableDoctorDoesNotReportClientPermissionsAsDaemonPermissions() throws {
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(
                directory: URL(fileURLWithPath: "/private/tmp/macctl-doctor-\(UUID().uuidString)")
            ),
            permissionContext: "client"
        )
        let request = RequestEnvelope(requestID: "request-unavailable", method: "doctor")
        let response = service.unavailableDoctorResponse(request: request, socketError: "connection refused")
        XCTAssertEqual(response.status, OperationStatus.blocked)
        XCTAssertEqual(response.requestID, request.requestID)
        let report = try JSONCodec.decode(
            DoctorReport.self,
            from: try JSONCodec.encode(response.result)
        )
        XCTAssertEqual(report.permissionContext, "unknown")
        XCTAssertTrue(report.permissions.allSatisfy { $0.state == "unknown" || $0.state == "not_required" })
        XCTAssertEqual(response.error?.code, MacCtlErrorCode.daemonUnavailable.rawValue)
    }

    func testTaskPlanBackwardDecodingAndExactDigestMutation() throws {
        let legacy = try JSONCodec.decode(
            TaskPlan.self,
            from: Data(
                #"{"id":"legacy.task","name":"Legacy task","summary":"Legacy","steps":[{"id":"step-1","action":{"kind":"assert","surface":"mac_app"}}]}"#.utf8
            )
        )
        XCTAssertEqual(legacy.focusPolicy, .foreground)
        XCTAssertEqual(legacy.totalTimeout, 300)
        XCTAssertEqual(legacy.maxActions, TaskPlanValidator.maximumActions)
        XCTAssertEqual(legacy.steps.first?.timeout, 30)
        XCTAssertEqual(legacy.steps.first?.recovery, .adaptive)

        let target = try JSONCodec.decode(
            TaskTargetIdentity.self,
            from: Data(
                #"{"application":"TextEdit","bundle_id":"com.apple.TextEdit","process_id":42,"window_fingerprint":"window"}"#.utf8
            )
        )
        XCTAssertEqual(target.bundleID, "com.apple.TextEdit")
        XCTAssertEqual(target.processID, 42)
        XCTAssertEqual(target.windowFingerprint, "window")

        let firstDigest = TaskPlan.digest(legacy)
        let changed = TaskPlan(
            id: legacy.id,
            name: legacy.name,
            summary: "Changed",
            steps: legacy.steps
        )
        XCTAssertNotEqual(firstDigest, TaskPlan.digest(changed))
    }

    func testBackgroundTaskValidationAcceptsTaskScopedRoutesAndRejectsGlobalInput() {
        let target = TaskTargetIdentity(
            application: "TextEdit",
            selector: Selector(role: "AXTextField", identifier: "document")
        )
        let typeAction = ActionSpec(
            kind: .type,
            surface: .macApp,
            selector: target.selector,
            parameters: [
                "text_source": .string("ephemeral"),
                "input_key": .string("body")
            ]
        )
        let valid = TaskPlan(
            id: "background.type",
            name: "Background type",
            summary: "Set a named field without foreground input",
            focusPolicy: .background,
            steps: [TaskStep(
                id: "type",
                action: typeAction,
                target: target,
                approvalReason: "Set the approved field"
            )]
        )
        XCTAssertTrue(TaskPlanValidator.validate(valid).valid)

        let global = TaskPlan(
            id: "background.global",
            name: "Global type",
            summary: "Attempt an unscoped background type",
            focusPolicy: .background,
            steps: [TaskStep(
                id: "type",
                action: ActionSpec(
                    kind: .type,
                    surface: .macApp,
                    parameters: [
                        "text_source": .string("ephemeral"),
                        "input_key": .string("body")
                    ]
                ),
                approvalReason: "Test rejection"
            )]
        )
        let invalid = TaskPlanValidator.validate(global)
        XCTAssertFalse(invalid.valid)
        XCTAssertTrue(invalid.errors.contains { $0.contains("Accessibility selector") })
        XCTAssertTrue(invalid.errors.contains { $0.contains("target application") })
    }

    func testBackgroundTaskValidationAdmitsSemanticAndExplicitlySafeAdapterRoutes() {
        let target = TaskTargetIdentity(application: "Finder")
        let search = ActionSpec(
            kind: .search,
            surface: .macApp,
            selector: Selector(role: "AXTextField", subrole: "AXSearchField"),
            parameters: [
                "text_source": .string("ephemeral"),
                "input_key": .string("query"),
                "replace_existing": .bool(true)
            ]
        )
        let scroll = ActionSpec(
            kind: .scroll,
            surface: .macApp,
            selector: Selector(role: "AXScrollArea", identifier: "files"),
            parameters: ["direction": .string("down"), "amount": .number(1)]
        )
        let inspect = ActionSpec(
            kind: .adapter,
            surface: .macApp,
            parameters: [
                "adapter_id": .string("finder"),
                "operation": .string("inspect.front-window")
            ]
        )
        let plan = TaskPlan(
            id: "background.semantic",
            name: "Background semantic actions",
            summary: "Use target-addressed operations without foreground input",
            focusPolicy: .background,
            steps: [
                TaskStep(id: "search", action: search, target: target, approvalReason: "Search Finder"),
                TaskStep(id: "scroll", action: scroll, target: target),
                TaskStep(
                    id: "inspect",
                    action: inspect,
                    target: target,
                    approvalReason: "Inspect the Finder window"
                )
            ]
        )
        let registry = AppAdapterRegistry(permissionChecker: { _ in true })

        let validation = TaskPlanValidator.validate(plan, adapterRegistry: registry)

        XCTAssertTrue(validation.valid, validation.errors.joined(separator: "; "))
        XCTAssertEqual(
            try? registry.operation(adapterID: "finder", name: "inspect.front-window").focusSupport,
            .backgroundSafe
        )

        let foregroundAdapter = TaskPlan(
            id: "background.adapter.activate",
            name: "Unsafe adapter",
            summary: "Attempt a foreground-only adapter operation",
            focusPolicy: .background,
            steps: [TaskStep(
                id: "activate",
                action: ActionSpec(
                    kind: .adapter,
                    surface: .macApp,
                    parameters: [
                        "adapter_id": .string("finder"),
                        "operation": .string("activate")
                    ]
                ),
                target: target
            )]
        )
        let rejected = TaskPlanValidator.validate(foregroundAdapter, adapterRegistry: registry)
        XCTAssertFalse(rejected.valid)
        XCTAssertTrue(rejected.errors.contains { $0.contains("background-safe adapter operation") })
    }

    func testLegacyAdapterOperationDefaultsToForegroundOnly() throws {
        let data = Data(#"{"name":"legacy.inspect","mutating":false,"risk":"safe","routes":["accessibility"]}"#.utf8)

        let operation = try JSONDecoder().decode(AppAdapterOperation.self, from: data)

        XCTAssertEqual(operation.focusSupport, .foregroundOnly)
    }

    func testTaskInputChannelCannotBeReusedByAnotherTaskOrPlanDigest() throws {
        let target = AppInfo(
            name: "TextEdit",
            bundleID: "com.apple.TextEdit",
            path: "/System/Applications/TextEdit.app",
            isRunning: true,
            processID: 401
        )
        let channel = TaskInputChannel(
            channelID: "input-test",
            taskID: "task-a",
            planDigest: "digest-a",
            focusPolicy: .background,
            targetApplication: target,
            routes: [.processDirected],
            expiresAt: Date().addingTimeInterval(30)
        )
        let authority = TaskExecutionAuthority(
            leaseToken: nil,
            leaseExpiresAt: channel.expiresAt,
            inputChannel: channel,
            revalidate: { target }
        )
        let wrongTask = TaskActionContext(
            taskID: "task-b",
            stepID: "key",
            target: TaskTargetIdentity(application: "TextEdit"),
            focusPolicy: .background,
            planDigest: "digest-a",
            ephemeralInputs: [:],
            deadline: Date().addingTimeInterval(30),
            authority: authority
        )
        XCTAssertThrowsError(try wrongTask.requireAuthority()) { error in
            XCTAssertEqual(error as? TaskControlError, .leaseRequired)
        }

        let wrongDigest = TaskActionContext(
            taskID: "task-a",
            stepID: "key",
            target: TaskTargetIdentity(application: "TextEdit"),
            focusPolicy: .background,
            planDigest: "digest-b",
            ephemeralInputs: [:],
            deadline: Date().addingTimeInterval(30),
            authority: authority
        )
        XCTAssertThrowsError(try wrongDigest.requireAuthority()) { error in
            XCTAssertEqual(error as? TaskControlError, .leaseRequired)
        }
    }

    func testBackgroundTaskKeyUsesProcessDirectedChannelWithoutKeyboardLease() throws {
        let target = AppInfo(
            name: "TextEdit",
            bundleID: "com.apple.TextEdit",
            path: "/System/Applications/TextEdit.app",
            isRunning: true,
            processID: 402
        )
        let foreground = AppInfo(
            name: "Finder",
            bundleID: "com.apple.finder",
            path: "/System/Library/CoreServices/Finder.app",
            isRunning: true,
            processID: 403
        )
        let focus = FocusedElementSnapshot(
            targetApplication: foreground,
            role: "AXButton",
            subrole: nil,
            identifier: "front",
            title: "Front"
        )
        let store = KeyboardDriveStore()
        let keyboard = KeyboardAccessController(
            eventSender: RecordingKeyboardEventSender(),
            preferenceStore: TestKeyboardPreferenceStore(enabled: true)
        )
        let session = ControlSession(
            keyboardDriveStore: store,
            focusedElementInspector: TestFocusedElementInspector(snapshot: focus),
            foregroundApplication: { foreground },
            hasPostEventAccess: { true },
            fullKeyboardAccessEnabled: { true },
            postActionTimeout: 0
        )
        let router = SemanticActionRouter(
            session: session,
            keyboardAccessController: keyboard,
            accessibilityActionController: TestAccessibilityActionPerformer(),
            visualActionController: TestVisualActionPerformer()
        )
        var sent: (String, pid_t)?
        let executor = MacTaskActionExecutor(
            appController: AppController(),
            accessibilityController: AccessibilityController(),
            inputController: InputController(),
            keyboardAccessController: keyboard,
            semanticActionRouter: router,
            adapterRegistry: AppAdapterRegistry(),
            foregroundApplication: { foreground },
            backgroundSendKey: { specification, pid in
                sent = (specification, pid)
            }
        )
        let channel = TaskInputChannel(
            channelID: "input-key-test",
            taskID: "background.key",
            planDigest: "digest-key",
            focusPolicy: .background,
            targetApplication: target,
            routes: [.processDirected],
            expiresAt: Date().addingTimeInterval(30)
        )
        let context = TaskActionContext(
            taskID: channel.taskID,
            stepID: "escape",
            target: TaskTargetIdentity(application: "TextEdit", processID: target.processID),
            focusPolicy: .background,
            planDigest: channel.planDigest,
            ephemeralInputs: [:],
            deadline: channel.expiresAt,
            authority: TaskExecutionAuthority(
                leaseToken: nil,
                leaseExpiresAt: channel.expiresAt,
                inputChannel: channel,
                revalidate: { target }
            )
        )

        let report = try executor.execute(
            action: ActionSpec(
                kind: .key,
                surface: .macApp,
                parameters: ["key": .string("escape")]
            ),
            context: context
        )

        XCTAssertNil(context.authority?.leaseToken)
        XCTAssertEqual(sent?.0, "escape")
        XCTAssertEqual(sent?.1, target.processID)
        XCTAssertEqual(report.route, "task_input_process")
    }

    func testExactForegroundKeyRequiresCompleteStrictBindingAndWindowPostcondition() throws {
        let targetJSON = Data(
            #"{"application":"Code","process_id":402,"instance_ref":"instance-402","window_ref":"window-402"}"#.utf8
        )
        let decoded = try JSONCodec.decode(TaskTargetIdentity.self, from: targetJSON)
        XCTAssertEqual(decoded.instanceRef, "instance-402")
        XCTAssertEqual(decoded.windowRef, "window-402")

        let action = ActionSpec(
            kind: .key,
            surface: .macApp,
            parameters: ["key": .string("cmd+shift+m")]
        )
        let postcondition = TaskPredicate(
            kind: .elementExists,
            selector: Selector(role: "AXStaticText", containsText: "Type mismatch")
        )
        let valid = TaskPlan(
            id: "foreground.exact.key",
            name: "Exact foreground key",
            summary: "Open one exact window surface",
            focusPolicy: .foreground,
            steps: [TaskStep(
                id: "open-problems",
                action: action,
                target: decoded,
                postconditions: [postcondition],
                risk: .sensitive,
                approvalReason: "Open Problems in the disposable window",
                recovery: TaskRecoveryPolicy(mode: "strict", maxAttempts: 1)
            )]
        )
        XCTAssertTrue(TaskPlanValidator.validate(valid).valid)

        let partial = TaskPlan(
            id: "foreground.exact.partial",
            name: "Partial exact target",
            summary: "Reject a partial exact binding",
            focusPolicy: .foreground,
            steps: [TaskStep(
                id: "partial",
                action: action,
                target: TaskTargetIdentity(
                    application: "Code",
                    processID: 402,
                    instanceRef: "instance-402"
                ),
                risk: .sensitive,
                approvalReason: "Test rejection",
                recovery: .strict
            )]
        )
        let rejected = TaskPlanValidator.validate(partial)
        XCTAssertFalse(rejected.valid)
        XCTAssertTrue(rejected.errors.contains { $0.contains("process_id, instance_ref, and window_ref") })
    }

    func testExactBackgroundKeyBindsWindowBeforeDispatchAndScopesPostcondition() throws {
        let target = AppInfo(
            name: "Visual Studio Code",
            bundleID: "com.microsoft.VSCode",
            path: "/Applications/Visual Studio Code.app",
            isRunning: true,
            processID: 4402
        )
        let foreground = AppInfo(
            name: "Visual Studio Code",
            bundleID: "com.microsoft.VSCode",
            path: "/Applications/Visual Studio Code.app",
            isRunning: true,
            processID: 4403
        )
        var sent: (String, pid_t)?
        var inspectedWindow: String?
        var observedWindow: String?
        let executor = makeExactKeyExecutor(
            foreground: foreground,
            backgroundSendKey: { key, pid in sent = (key, pid) },
            exactWindowBinding: { pid, windowRef in
                inspectedWindow = windowRef
                return self.exactWindowSnapshot(pid: pid, windowRef: windowRef)
            },
            exactWindowElementExists: { _, windowRef, _ in
                observedWindow = windowRef
                return true
            }
        )
        let channel = TaskInputChannel(
            channelID: "exact-input-test",
            taskID: "background.exact",
            planDigest: "exact-digest",
            focusPolicy: .background,
            targetApplication: target,
            targetInstanceRef: "instance-4402",
            targetWindowRef: "window-4402",
            routes: [.exactProcessDirected],
            expiresAt: Date().addingTimeInterval(30)
        )
        let context = TaskActionContext(
            taskID: channel.taskID,
            stepID: "open-problems",
            target: TaskTargetIdentity(
                application: "Visual Studio Code",
                processID: 4402,
                instanceRef: "instance-4402",
                windowRef: "window-4402"
            ),
            focusPolicy: .background,
            planDigest: channel.planDigest,
            ephemeralInputs: [:],
            deadline: channel.expiresAt,
            authority: TaskExecutionAuthority(
                leaseToken: nil,
                leaseExpiresAt: channel.expiresAt,
                inputChannel: channel,
                revalidate: { target }
            )
        )

        let report = try executor.execute(
            action: ActionSpec(
                kind: .key,
                surface: .macApp,
                parameters: ["key": .string("cmd+shift+m")]
            ),
            context: context
        )
        XCTAssertEqual(report.route, "task_input_exact_process")
        XCTAssertEqual(inspectedWindow, "window-4402")
        XCTAssertEqual(sent?.0, "cmd+shift+m")
        XCTAssertEqual(sent?.1, 4402)

        XCTAssertTrue(try executor.evaluate(
            predicate: TaskPredicate(
                kind: .elementExists,
                selector: Selector(role: "AXStaticText", containsText: "Type mismatch")
            ),
            context: context
        ))
        XCTAssertEqual(observedWindow, "window-4402")
    }

    func testExactForegroundPostconditionUsesLeaseBoundPIDAndWindow() throws {
        let target = AppInfo(
            name: "Code",
            bundleID: "com.jakyeamos.macctl.fixture.vscode.qualitylensc1",
            path: "/private/tmp/MacCtl VS Code Fixture.app",
            isRunning: true,
            processID: 4404
        )
        var observedPID: pid_t?
        var observedWindow: String?
        let executor = makeExactKeyExecutor(
            foreground: target,
            backgroundSendKey: { _, _ in XCTFail("Exact foreground verification must not dispatch input") },
            exactWindowBinding: { pid, windowRef in
                self.exactWindowSnapshot(pid: pid, windowRef: windowRef)
            },
            exactWindowElementExists: { pid, windowRef, _ in
                observedPID = pid
                observedWindow = windowRef
                return true
            }
        )
        let channel = TaskInputChannel(
            taskID: "foreground.exact.verify",
            planDigest: "foreground-exact-digest",
            focusPolicy: .foreground,
            targetApplication: target,
            targetInstanceRef: "instance-4404",
            targetWindowRef: "window-4404",
            routes: [.exactForeground],
            expiresAt: Date().addingTimeInterval(30)
        )
        let context = TaskActionContext(
            taskID: channel.taskID,
            stepID: "verify-problems",
            target: TaskTargetIdentity(
                application: "Code",
                processID: 4404,
                instanceRef: "instance-4404",
                windowRef: "window-4404"
            ),
            focusPolicy: .foreground,
            planDigest: channel.planDigest,
            ephemeralInputs: [:],
            deadline: channel.expiresAt,
            authority: TaskExecutionAuthority(
                leaseToken: "lease-4404",
                leaseExpiresAt: channel.expiresAt,
                inputChannel: channel,
                revalidate: { target }
            )
        )

        XCTAssertTrue(try executor.evaluate(
            predicate: TaskPredicate(
                kind: .elementExists,
                selector: Selector(role: "AXStaticText", containsText: "Type mismatch")
            ),
            context: context
        ))
        XCTAssertEqual(observedPID, 4404)
        XCTAssertEqual(observedWindow, "window-4404")
    }

    func testExactWindowExistenceTreatsDuplicateDescendantsAsAValidProof() throws {
        XCTAssertTrue(try AccessibilityExistenceResolution.resolve(matchCount: 2, truncated: false))
        XCTAssertTrue(try AccessibilityExistenceResolution.resolve(matchCount: 1, truncated: true))
        XCTAssertFalse(try AccessibilityExistenceResolution.resolve(matchCount: 0, truncated: false))
        XCTAssertThrowsError(
            try AccessibilityExistenceResolution.resolve(matchCount: 0, truncated: true)
        ) { error in
            guard case AccessibilityControllerError.resolutionIncomplete(0) = error else {
                return XCTFail("Expected a bounded-search failure with no matches, got \(error)")
            }
        }
    }

    func testExactBackgroundKeyMarksPostDispatchTargetRaceUncertain() throws {
        let target = AppInfo(
            name: "Visual Studio Code",
            bundleID: "com.microsoft.VSCode",
            path: "/Applications/Visual Studio Code.app",
            isRunning: true,
            processID: 4502
        )
        var validationCount = 0
        var dispatched = false
        let executor = makeExactKeyExecutor(
            foreground: AppInfo(
                name: "Finder",
                bundleID: "com.apple.finder",
                path: "/System/Library/CoreServices/Finder.app",
                isRunning: true,
                processID: 4503
            ),
            backgroundSendKey: { _, _ in dispatched = true },
            exactWindowBinding: { pid, windowRef in
                self.exactWindowSnapshot(pid: pid, windowRef: windowRef)
            },
            exactWindowElementExists: { _, _, _ in true }
        )
        let channel = TaskInputChannel(
            taskID: "background.exact.race",
            planDigest: "race-digest",
            focusPolicy: .background,
            targetApplication: target,
            targetInstanceRef: "instance-4502",
            targetWindowRef: "window-4502",
            routes: [.exactProcessDirected],
            expiresAt: Date().addingTimeInterval(30)
        )
        let context = TaskActionContext(
            taskID: channel.taskID,
            stepID: "key",
            target: TaskTargetIdentity(
                application: target.name,
                processID: 4502,
                instanceRef: "instance-4502",
                windowRef: "window-4502"
            ),
            focusPolicy: .background,
            planDigest: channel.planDigest,
            ephemeralInputs: [:],
            deadline: channel.expiresAt,
            authority: TaskExecutionAuthority(
                leaseToken: nil,
                leaseExpiresAt: channel.expiresAt,
                inputChannel: channel,
                revalidate: {
                    validationCount += 1
                    if validationCount >= 4 { throw TaskControlError.blocked("target_changed") }
                    return target
                }
            )
        )

        XCTAssertThrowsError(try executor.execute(
            action: ActionSpec(
                kind: .key,
                surface: .macApp,
                parameters: ["key": .string("cmd+shift+m")]
            ),
            context: context
        )) { error in
            XCTAssertEqual(
                error as? TaskActionExecutionError,
                .uncertain("exact_process_delivery_target_changed")
            )
        }
        XCTAssertTrue(dispatched)
    }

    func testExactBackgroundKeyStopsBeforeDispatchWhenWindowLosesProcessFocus() throws {
        let target = AppInfo(
            name: "Visual Studio Code",
            bundleID: "com.microsoft.VSCode",
            path: "/Applications/Visual Studio Code.app",
            isRunning: true,
            processID: 4602
        )
        var dispatched = false
        let executor = makeExactKeyExecutor(
            foreground: AppInfo(
                name: "Finder",
                bundleID: "com.apple.finder",
                path: "/System/Library/CoreServices/Finder.app",
                isRunning: true,
                processID: 4603
            ),
            backgroundSendKey: { _, _ in dispatched = true },
            exactWindowBinding: { pid, windowRef in
                let focused = self.exactWindowSnapshot(pid: pid, windowRef: windowRef)
                return NativeWindowTargetSnapshot(
                    snapshot: NativeWindowSnapshot(
                        processID: focused.processID,
                        identityDigest: focused.windowRef,
                        frame: focused.frame,
                        displayID: focused.displayID,
                        movable: focused.movable,
                        resizable: focused.resizable,
                        minimized: focused.minimized,
                        fullscreen: focused.fullscreen
                    ),
                    unique: true,
                    focused: false,
                    visible: true
                )
            },
            exactWindowElementExists: { _, _, _ in true }
        )
        let channel = TaskInputChannel(
            taskID: "background.exact.unfocused",
            planDigest: "unfocused-digest",
            focusPolicy: .background,
            targetApplication: target,
            targetInstanceRef: "instance-4602",
            targetWindowRef: "window-4602",
            routes: [.exactProcessDirected],
            expiresAt: Date().addingTimeInterval(30)
        )
        let context = TaskActionContext(
            taskID: channel.taskID,
            stepID: "key",
            target: TaskTargetIdentity(
                application: target.name,
                processID: 4602,
                instanceRef: "instance-4602",
                windowRef: "window-4602"
            ),
            focusPolicy: .background,
            planDigest: channel.planDigest,
            ephemeralInputs: [:],
            deadline: channel.expiresAt,
            authority: TaskExecutionAuthority(
                leaseToken: nil,
                leaseExpiresAt: channel.expiresAt,
                inputChannel: channel,
                revalidate: { target }
            )
        )

        XCTAssertThrowsError(try executor.execute(
            action: ActionSpec(
                kind: .key,
                surface: .macApp,
                parameters: ["key": .string("cmd+shift+m")]
            ),
            context: context
        )) { error in
            XCTAssertEqual(
                error as? TaskActionExecutionError,
                .blocked("exact_window_not_process_focused")
            )
        }
        XCTAssertFalse(dispatched)
    }

    private func makeExactKeyExecutor(
        foreground: AppInfo,
        backgroundSendKey: @escaping (String, pid_t) throws -> Void,
        exactWindowBinding: @escaping (pid_t, String) throws -> NativeWindowTargetSnapshot,
        exactWindowElementExists: @escaping (pid_t, String, MacCtlCore.Selector) throws -> Bool
    ) -> MacTaskActionExecutor {
        let keyboard = KeyboardAccessController(
            eventSender: RecordingKeyboardEventSender(),
            preferenceStore: TestKeyboardPreferenceStore(enabled: true)
        )
        let focus = FocusedElementSnapshot(
            targetApplication: foreground,
            role: "AXButton",
            subrole: nil,
            identifier: "front",
            title: "Front"
        )
        let session = ControlSession(
            keyboardDriveStore: KeyboardDriveStore(),
            focusedElementInspector: TestFocusedElementInspector(snapshot: focus),
            foregroundApplication: { foreground },
            hasPostEventAccess: { true },
            fullKeyboardAccessEnabled: { true },
            postActionTimeout: 0
        )
        return MacTaskActionExecutor(
            appController: AppController(),
            accessibilityController: AccessibilityController(),
            inputController: InputController(),
            keyboardAccessController: keyboard,
            semanticActionRouter: SemanticActionRouter(
                session: session,
                keyboardAccessController: keyboard,
                accessibilityActionController: TestAccessibilityActionPerformer(),
                visualActionController: TestVisualActionPerformer()
            ),
            adapterRegistry: AppAdapterRegistry(),
            foregroundApplication: { foreground },
            backgroundSendKey: backgroundSendKey,
            exactWindowBinding: exactWindowBinding,
            exactWindowElementExists: exactWindowElementExists
        )
    }

    private func exactWindowSnapshot(pid: pid_t, windowRef: String) -> NativeWindowTargetSnapshot {
        NativeWindowTargetSnapshot(
            snapshot: NativeWindowSnapshot(
                processID: pid,
                identityDigest: windowRef,
                frame: NativeWindowFrame(x: 0, y: 0, width: 800, height: 600),
                displayID: 1,
                movable: true,
                resizable: true,
                minimized: false,
                fullscreen: false
            ),
            unique: true,
            focused: true,
            visible: true
        )
    }

    func testTaskPlanValidatorRejectsRawScriptsPrivateAdapterInputsAndUnknownOperations() {
        let registry = AppAdapterRegistry(permissionChecker: { _ in true })
        let rawScript = TaskStep(
            id: "raw",
            action: ActionSpec(
                kind: .adapter,
                surface: .macApp,
                parameters: [
                    "adapter_id": .string("mail"),
                    "operation": .string("draft.create"),
                    "script": .string("tell application \"Mail\" to send")
                ],
                risk: .sensitive
            ),
            approvalReason: "Test"
        )
        let privateInput = TaskStep(
            id: "private",
            action: ActionSpec(
                kind: .adapter,
                surface: .macApp,
                parameters: [
                    "adapter_id": .string("mail"),
                    "operation": .string("draft.create"),
                    "body": .string("private body")
                ],
                risk: .sensitive
            ),
            approvalReason: "Test"
        )
        let unknownOperation = TaskStep(
            id: "unknown",
            action: ActionSpec(
                kind: .adapter,
                surface: .macApp,
                parameters: [
                    "adapter_id": .string("calendar"),
                    "operation": .string("draft.create")
                ]
            )
        )
        let plan = TaskPlan(
            id: "invalid.adapters",
            name: "Invalid adapters",
            summary: "Invalid adapter inputs",
            steps: [rawScript, privateInput, unknownOperation]
        )
        let validation = TaskPlanValidator.validate(plan, adapterRegistry: registry)
        XCTAssertFalse(validation.valid)
        XCTAssertTrue(validation.errors.contains { $0.contains("arbitrary script") })
        XCTAssertTrue(validation.errors.contains { $0.contains("private input body") })
        XCTAssertTrue(validation.errors.contains { $0.contains("calendar.draft.create") })
    }

    func testTaskPlanValidatorBindsRiskFloorAndDeclaredRecoveryRoutes() throws {
        let unsafeClick = TaskStep(
            id: "unsafe-click",
            action: ActionSpec(
                kind: .click,
                surface: .macApp,
                selector: Selector(title: "Save")
            ),
            risk: .safe,
            recovery: TaskRecoveryPolicy(alternateRoutes: ["not-a-route"])
        )
        let validation = TaskPlanValidator.validate(TaskPlan(
            id: "invalid.recovery",
            name: "Invalid recovery",
            summary: "Risk and route contracts",
            steps: [unsafeClick]
        ))
        XCTAssertFalse(validation.valid)
        XCTAssertTrue(validation.errors.contains { $0.contains("risk safe") })
        XCTAssertTrue(validation.errors.contains { $0.contains("not-a-route") })

        let strict = TaskStep(
            id: "strict",
            action: ActionSpec(kind: .assert, surface: .macApp),
            recovery: TaskRecoveryPolicy(mode: "strict", alternateRoutes: ["native"])
        )
        let strictValidation = TaskPlanValidator.validate(TaskPlan(
            id: "invalid.strict",
            name: "Invalid strict recovery",
            summary: "Strict routes are explicit",
            steps: [strict]
        ))
        XCTAssertFalse(strictValidation.valid)
        XCTAssertTrue(strictValidation.errors.contains { $0.contains("strict recovery") })
    }

    func testTaskRunnerPassesOnlyDeclaredAlternateRoutesToRetries() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-task-route-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let approvals = TaskApprovalStore()
        let executor = TestTaskActionExecutor(failuresBeforeSuccess: 1)
        let runner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: directory),
            approvalStore: approvals,
            actionExecutor: executor,
            targetRevalidator: { _ in nil }
        )
        let plan = TaskPlan(
            id: "route.recovery",
            name: "Route recovery",
            summary: "Use the declared recovery route",
            steps: [TaskStep(
                id: "step",
                action: ActionSpec(kind: .assert, surface: .macApp),
                recovery: TaskRecoveryPolicy(alternateRoutes: ["native"])
            )]
        )
        let prepared = try runner.prepare(plan: plan)
        _ = try approvals.approve(token: prepared.approval.token)
        XCTAssertEqual(try runner.run(plan: plan, approvalToken: prepared.approval.token).state, .completed)
        XCTAssertEqual(executor.recoveryRoutes, [nil, "native"])
    }

    func testTaskApprovalAndCheckpointStorageAreExactAndRedacted() throws {
        var now = Date(timeIntervalSince1970: 100)
        let approvals = TaskApprovalStore(lifetime: 10, now: { now })
        let plan = TaskPlan(
            id: "approval.task",
            name: "Approval task",
            summary: "A redacted task",
            steps: [TaskStep(id: "step", action: ActionSpec(kind: .assert, surface: .macApp))]
        )
        let prepared = approvals.prepare(plan: plan, ephemeralInputs: ["body": "PRIVATE TEXT"])
        XCTAssertThrowsError(try approvals.consume(
            token: prepared.record.token,
            plan: plan,
            ephemeralInputs: ["body": "DIFFERENT"]
        )) { error in
            XCTAssertEqual(error as? TaskApprovalStoreError, .alreadyUsed)
        }
        _ = try approvals.approve(token: prepared.record.token)
        XCTAssertThrowsError(try approvals.consume(
            token: prepared.record.token,
            plan: plan,
            ephemeralInputs: ["body": "DIFFERENT"]
        )) { error in
            XCTAssertEqual(error as? TaskApprovalStoreError, .mismatch)
        }
        _ = try approvals.consume(
            token: prepared.record.token,
            plan: plan,
            ephemeralInputs: ["body": "PRIVATE TEXT"]
        )
        XCTAssertThrowsError(try approvals.consume(
            token: prepared.record.token,
            plan: plan,
            ephemeralInputs: ["body": "PRIVATE TEXT"]
        )) { error in
            XCTAssertEqual(error as? TaskApprovalStoreError, .alreadyUsed)
        }

        let directory = URL(fileURLWithPath: "/private/tmp/macctl-checkpoint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskCheckpointStore(directory: directory)
        try store.save(TaskCheckpoint(
            taskID: "approval.task",
            planDigest: TaskPlan.digest(plan, ephemeralInputs: ["body": "PRIVATE TEXT"]),
            currentStepID: "step",
            lastStepID: "step",
            stepIndex: 1,
            state: .completed,
            route: "native",
            attempts: 1,
            verificationResult: "passed",
            createdAt: now,
            updatedAt: now
        ))
        let checkpointURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        let checkpointText = try String(contentsOf: checkpointURL)
        XCTAssertFalse(checkpointText.contains("PRIVATE TEXT"))
        XCTAssertFalse(checkpointText.contains(prepared.record.token))
        XCTAssertFalse(checkpointText.contains("AXValue"))
        XCTAssertEqual(store.status().directoryOwnerOnly, true)
        XCTAssertEqual(store.status().filesOwnerOnly, true)

        let expiringToken = approvals.prepare(plan: plan).record.token
        now = now.addingTimeInterval(11)
        XCTAssertThrowsError(try approvals.approve(token: expiringToken)) { error in
            XCTAssertEqual(error as? TaskApprovalStoreError, .expired)
        }
    }

    func testTaskRunnerUsesRiskBoundedRecoveryAndCumulativeActionBudget() throws {
        let safeDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-safe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: safeDirectory) }
        let safeExecutor = TestTaskActionExecutor(failuresBeforeSuccess: 2)
        let safeApprovals = TaskApprovalStore()
        let safeRunner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: safeDirectory),
            approvalStore: safeApprovals,
            actionExecutor: safeExecutor,
            targetRevalidator: { _ in nil }
        )
        let safePlan = TaskPlan(
            id: "safe.recovery",
            name: "Safe recovery",
            summary: "Retry safe action",
            steps: [TaskStep(id: "step", action: ActionSpec(kind: .assert, surface: .macApp))]
        )
        let safeApproval = try safeRunner.prepare(plan: safePlan)
        _ = try safeApprovals.approve(token: safeApproval.approval.token)
        let safeReport = try safeRunner.run(plan: safePlan, approvalToken: safeApproval.approval.token)
        XCTAssertEqual(safeReport.state, .completed)
        XCTAssertEqual(safeExecutor.executeCount, 3)
        XCTAssertEqual(safeReport.attempts, 3)

        let reversibleDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-reversible-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: reversibleDirectory) }
        let reversibleExecutor = TestTaskActionExecutor(failuresBeforeSuccess: 3)
        let reversibleApprovals = TaskApprovalStore()
        let reversibleRunner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: reversibleDirectory),
            approvalStore: reversibleApprovals,
            actionExecutor: reversibleExecutor,
            targetRevalidator: { _ in nil }
        )
        let reversiblePlan = TaskPlan(
            id: "reversible.recovery",
            name: "Reversible recovery",
            summary: "Retry reversible action",
            steps: [TaskStep(
                id: "step",
                action: ActionSpec(kind: .assert, surface: .macApp, risk: .reversible),
                risk: .reversible
            )]
        )
        let reversibleApproval = try reversibleRunner.prepare(plan: reversiblePlan)
        _ = try reversibleApprovals.approve(token: reversibleApproval.approval.token)
        XCTAssertThrowsError(try reversibleRunner.run(
            plan: reversiblePlan,
            approvalToken: reversibleApproval.approval.token
        )) { error in
            XCTAssertEqual(error as? TaskControlError, .blocked("task_action_blocked"))
        }
        XCTAssertEqual(reversibleExecutor.executeCount, 2)
        XCTAssertEqual(try reversibleRunner.status(taskID: reversiblePlan.id).state, .blocked)

        let budgetDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: budgetDirectory) }
        let budgetExecutor = TestTaskActionExecutor(failuresBeforeSuccess: 2)
        let budgetApprovals = TaskApprovalStore()
        let budgetRunner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: budgetDirectory),
            approvalStore: budgetApprovals,
            actionExecutor: budgetExecutor,
            targetRevalidator: { _ in nil }
        )
        let budgetPlan = TaskPlan(
            id: "budget.recovery",
            name: "Budget recovery",
            summary: "Bound action attempts",
            steps: [TaskStep(id: "step", action: ActionSpec(kind: .assert, surface: .macApp))],
            maxActions: 1
        )
        let budgetApproval = try budgetRunner.prepare(plan: budgetPlan)
        _ = try budgetApprovals.approve(token: budgetApproval.approval.token)
        XCTAssertThrowsError(try budgetRunner.run(
            plan: budgetPlan,
            approvalToken: budgetApproval.approval.token
        )) { error in
            XCTAssertEqual(error as? TaskControlError, .actionBudgetExceeded)
        }
        XCTAssertEqual(budgetExecutor.executeCount, 1)
    }

    func testTaskRunnerPausesForPreconditionsRequiresFreshResumeAuthorityAndBindsRemainingPlan() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-task-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let approvals = TaskApprovalStore()
        let executor = TestTaskActionExecutor(evaluationResult: false)
        let runner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: directory),
            approvalStore: approvals,
            actionExecutor: executor,
            targetRevalidator: { _ in nil }
        )
        let plan = TaskPlan(
            id: "resume.task",
            name: "Resume task",
            summary: "Resume from a checkpoint",
            steps: [
                TaskStep(id: "step-1", action: ActionSpec(kind: .assert, surface: .macApp)),
                TaskStep(
                    id: "step-2",
                    action: ActionSpec(kind: .assert, surface: .macApp),
                    preconditions: [TaskPredicate(
                        kind: .foregroundApplication,
                        application: "TextEdit"
                    )]
                )
            ]
        )
        let prepared = try runner.prepare(plan: plan)
        _ = try approvals.approve(token: prepared.approval.token)
        XCTAssertThrowsError(try runner.run(plan: plan, approvalToken: prepared.approval.token)) { error in
            XCTAssertEqual(error as? TaskControlError, .preconditionFailed("step-2"))
        }
        let paused = try runner.status(taskID: plan.id)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.currentStepID, "step-2")
        XCTAssertEqual(paused.lastStepID, "step-1")
        XCTAssertEqual(paused.attempts, 1)

        executor.evaluationResult = true
        let resumePrepared = try runner.prepare(plan: plan)
        XCTAssertEqual(
            resumePrepared.planDigest,
            TaskPlan.digest(plan.remaining(from: 1))
        )
        _ = try approvals.approve(token: resumePrepared.approval.token)
        let staleAuthority = TaskExecutionAuthority(
            leaseToken: "lease",
            fresh: false,
            revalidate: { nil }
        )
        XCTAssertThrowsError(try runner.resume(
            plan: plan,
            approvalToken: resumePrepared.approval.token,
            authority: staleAuthority
        )) { error in
            XCTAssertEqual(error as? TaskControlError, .leaseRequired)
        }
        let freshAuthority = TaskExecutionAuthority(
            leaseToken: "lease",
            fresh: true,
            revalidate: { nil }
        )
        let completed = try runner.resume(
            plan: plan,
            approvalToken: resumePrepared.approval.token,
            authority: freshAuthority
        )
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.lastStepID, "step-2")
        XCTAssertEqual(completed.attempts, 2)
    }

    func testInterruptedRunningCheckpointRequiresExplicitResumeAndPreservesStartTime() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-task-interrupted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let approvals = TaskApprovalStore()
        let store = TaskCheckpointStore(directory: directory)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000.123)
        let currentTime = startedAt.addingTimeInterval(1)
        let runner = TaskRunner(
            checkpointStore: store,
            approvalStore: approvals,
            actionExecutor: TestTaskActionExecutor(),
            now: { currentTime },
            targetRevalidator: { _ in nil }
        )
        let plan = TaskPlan(
            id: "interrupted.task",
            name: "Interrupted task",
            summary: "Require explicit restart authority",
            steps: [TaskStep(id: "step", action: ActionSpec(kind: .assert, surface: .macApp))]
        )
        try store.save(TaskCheckpoint(
            taskID: plan.id,
            planDigest: TaskPlan.digest(plan),
            currentStepID: "step",
            stepIndex: 0,
            state: .running,
            createdAt: startedAt,
            updatedAt: startedAt,
            startedAt: startedAt
        ))

        let prepared = try runner.prepare(plan: plan)
        XCTAssertEqual(prepared.state, .indeterminate)
        XCTAssertEqual(try store.load(taskID: plan.id)?.lastErrorCode, "task_interrupted")
        XCTAssertEqual(
            try XCTUnwrap(store.load(taskID: plan.id)?.startedAt).timeIntervalSince1970,
            startedAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )

        _ = try approvals.approve(token: prepared.approval.token)
        let authority = TaskExecutionAuthority(
            leaseToken: "fresh-lease",
            fresh: true,
            revalidate: { nil }
        )
        let completed = try runner.resume(
            plan: plan,
            approvalToken: prepared.approval.token,
            authority: authority
        )
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(
            try XCTUnwrap(store.load(taskID: plan.id)?.startedAt).timeIntervalSince1970,
            startedAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
    }

    func testExpiredTaskIdentityCannotBePreparedOrResumed() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-task-expired-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let approvals = TaskApprovalStore()
        let store = TaskCheckpointStore(directory: directory)
        let runner = TaskRunner(
            checkpointStore: store,
            approvalStore: approvals,
            actionExecutor: TestTaskActionExecutor(),
            targetRevalidator: { _ in nil }
        )
        let plan = TaskPlan(
            id: "expired.identity",
            name: "Expired identity",
            summary: "Require a new identity after the plan-wide deadline",
            steps: [TaskStep(id: "step", action: ActionSpec(kind: .assert, surface: .macApp))]
        )
        try store.save(TaskCheckpoint(
            taskID: plan.id,
            planDigest: TaskPlan.digest(plan),
            currentStepID: "step",
            stepIndex: 0,
            state: .expired
        ))

        XCTAssertThrowsError(try runner.prepare(plan: plan)) { error in
            XCTAssertEqual(error as? TaskControlError, .invalidState(.expired))
        }
        let approval = approvals.prepare(plan: plan)
        _ = try approvals.approve(token: approval.record.token)
        let authority = TaskExecutionAuthority(
            leaseToken: "fresh-lease",
            fresh: true,
            revalidate: { nil }
        )
        XCTAssertThrowsError(try runner.resume(
            plan: plan,
            approvalToken: approval.record.token,
            authority: authority
        )) { error in
            XCTAssertEqual(error as? TaskControlError, .invalidState(.expired))
        }
    }

    func testSensitiveTaskNeverRetriesUncertainActionAndCancellationInvalidatesState() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-task-sensitive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let approvals = TaskApprovalStore()
        let executor = TestTaskActionExecutor(sideEffectUncertain: true)
        let runner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: directory),
            approvalStore: approvals,
            actionExecutor: executor,
            targetRevalidator: { _ in nil }
        )
        let plan = TaskPlan(
            id: "sensitive.task",
            name: "Sensitive task",
            summary: "One dispatch only",
            steps: [TaskStep(
                id: "send",
                action: ActionSpec(kind: .assert, surface: .macApp, risk: .sensitive),
                risk: .sensitive,
                approvalReason: "Test sensitive action"
            )]
        )
        let prepared = try runner.prepare(plan: plan)
        _ = try approvals.approve(token: prepared.approval.token)
        XCTAssertThrowsError(try runner.run(plan: plan, approvalToken: prepared.approval.token)) { error in
            XCTAssertEqual(error as? TaskControlError, .indeterminate("send"))
        }
        XCTAssertEqual(executor.executeCount, 1)
        XCTAssertEqual(try runner.status(taskID: plan.id).state, .indeterminate)

        let cancellationDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cancellationDirectory) }
        let cancellationApprovals = TaskApprovalStore()
        let cancellationRunner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: cancellationDirectory),
            approvalStore: cancellationApprovals,
            actionExecutor: TestTaskActionExecutor(),
            targetRevalidator: { _ in nil }
        )
        let cancellablePlan = TaskPlan(
            id: "cancel.task",
            name: "Cancel task",
            summary: "Cancel before run",
            steps: [TaskStep(id: "step", action: ActionSpec(kind: .assert, surface: .macApp))]
        )
        _ = try cancellationRunner.prepare(plan: cancellablePlan)
        let cancelled = try cancellationRunner.cancel(taskID: cancellablePlan.id)
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertThrowsError(try cancellationRunner.status(taskID: "missing-task"))

        let completedPlan = TaskPlan(
            id: "completed.cancel.task",
            name: "Completed cancellation",
            summary: "Terminal tasks cannot be cancelled",
            steps: [TaskStep(id: "step", action: ActionSpec(kind: .assert, surface: .macApp))]
        )
        let completedPrepared = try cancellationRunner.prepare(plan: completedPlan)
        _ = try cancellationApprovals.approve(token: completedPrepared.approval.token)
        _ = try cancellationRunner.run(plan: completedPlan, approvalToken: completedPrepared.approval.token)
        XCTAssertThrowsError(try cancellationRunner.cancel(taskID: completedPlan.id)) { error in
            XCTAssertEqual(error as? TaskControlError, .invalidState(.completed))
        }
    }

    func testSensitiveTaskPollsPostconditionWithoutReplayingAction() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-task-postcondition-poll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSince1970: 100)
        let approvals = TaskApprovalStore(now: { now })
        let executor = TestTaskActionExecutor(evaluationResults: [false, false, true])
        let runner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: directory),
            approvalStore: approvals,
            actionExecutor: executor,
            now: { now },
            sleep: { interval in now = now.addingTimeInterval(interval) },
            targetRevalidator: { _ in nil }
        )
        let plan = TaskPlan(
            id: "sensitive.postcondition.poll",
            name: "Sensitive postcondition polling",
            summary: "Wait for asynchronously published GUI state",
            steps: [TaskStep(
                id: "send",
                action: ActionSpec(kind: .assert, surface: .macApp, risk: .sensitive),
                postconditions: [TaskPredicate(kind: .applicationRunning, application: "Fixture")],
                risk: .sensitive,
                approvalReason: "Test one sensitive action",
                timeout: 1,
                recovery: .strict
            )]
        )

        let prepared = try runner.prepare(plan: plan)
        _ = try approvals.approve(token: prepared.approval.token)
        let report = try runner.run(plan: plan, approvalToken: prepared.approval.token)

        XCTAssertEqual(report.state, .completed)
        XCTAssertEqual(executor.executeCount, 1)
        XCTAssertEqual(executor.evaluationCount, 3)
        XCTAssertEqual(now.timeIntervalSince1970, 100.2, accuracy: 0.000_001)
    }

    func testSensitiveTaskPostconditionTimeoutDoesNotReplayAction() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-task-postcondition-timeout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSince1970: 100)
        let approvals = TaskApprovalStore(now: { now })
        let executor = TestTaskActionExecutor(evaluationResult: false)
        let runner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: directory),
            approvalStore: approvals,
            actionExecutor: executor,
            now: { now },
            sleep: { interval in now = now.addingTimeInterval(interval) },
            targetRevalidator: { _ in nil }
        )
        let plan = TaskPlan(
            id: "sensitive.postcondition.timeout",
            name: "Sensitive postcondition timeout",
            summary: "Fail closed without replay",
            steps: [TaskStep(
                id: "send",
                action: ActionSpec(kind: .assert, surface: .macApp, risk: .sensitive),
                postconditions: [TaskPredicate(kind: .applicationRunning, application: "Fixture")],
                risk: .sensitive,
                approvalReason: "Test one sensitive action",
                timeout: 0.25,
                recovery: .strict
            )]
        )

        let prepared = try runner.prepare(plan: plan)
        _ = try approvals.approve(token: prepared.approval.token)
        XCTAssertThrowsError(try runner.run(plan: plan, approvalToken: prepared.approval.token)) { error in
            XCTAssertEqual(error as? TaskControlError, .indeterminate("send"))
        }
        XCTAssertEqual(executor.executeCount, 1)
        XCTAssertGreaterThanOrEqual(executor.evaluationCount, 2)
        XCTAssertEqual(try runner.status(taskID: plan.id).state, .indeterminate)
    }

    func testAdapterRegistryReportsCapabilitiesAndKeepsAppleScriptAllowlisted() throws {
        let registry = AppAdapterRegistry(permissionChecker: { _ in true })
        let IDs = Set(registry.manifests().map(\.adapterID))
        XCTAssertTrue(IDs.isSuperset(of: ["finder", "system-settings", "terminal", "textedit", "preview", "mail", "calendar", "notes", "messages"]))
        XCTAssertEqual(registry.automationPermissions().first?.state, "granted")
        XCTAssertThrowsError(try registry.operation(adapterID: "calendar", name: "draft.create")) { error in
            XCTAssertEqual(
                error as? AppAdapterError,
                .unsupportedOperation(adapterID: "calendar", operation: "draft.create")
            )
        }
        XCTAssertThrowsError(try registry.operation(adapterID: "unknown", name: "inspect.front-window")) { error in
            XCTAssertEqual(error as? AppAdapterError, .unsupportedAdapter("unknown"))
        }
    }

    func testTaskServiceProducesCheckpointAndReceiptEvidenceWithoutPrivateInputs() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-receipts-\(UUID().uuidString)")
        let checkpointDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-service-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: receiptDirectory)
            try? FileManager.default.removeItem(at: checkpointDirectory)
        }
        let approvals = TaskApprovalStore()
        let checkpoints = TaskCheckpointStore(directory: checkpointDirectory)
        let runner = TaskRunner(
            checkpointStore: checkpoints,
            approvalStore: approvals,
            actionExecutor: TestTaskActionExecutor(),
            targetRevalidator: { _ in nil }
        )
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            taskApprovalStore: approvals,
            taskCheckpointStore: checkpoints,
            taskRunner: runner
        )
        let plan = TaskPlan(
            id: "service.task",
            name: "Service task",
            summary: "Private inputs stay ephemeral",
            steps: [TaskStep(id: "step", action: ActionSpec(kind: .assert, surface: .macApp))]
        )
        let planValue = try JSONValue.fromEncodable(plan)
        let prepared = service.handle(RequestEnvelope(
            method: "task.prepare",
            params: [
                "plan": planValue,
                "ephemeral_inputs": .object(["body": .string("PRIVATE BODY")])
            ]
        ))
        XCTAssertEqual(prepared.status, .prepared)
        let token = try XCTUnwrap(prepared.result["approval"]?.objectValue?["token"]?.stringValue)
        let approved = service.handle(RequestEnvelope(
            method: "approval.approve",
            params: ["token": .string(token)]
        ))
        XCTAssertEqual(approved.status, .succeeded)
        let run = service.handle(RequestEnvelope(
            method: "task.run",
            params: [
                "plan": planValue,
                "approval_token": .string(token),
                "ephemeral_inputs": .object(["body": .string("PRIVATE BODY")])
            ]
        ))
        XCTAssertEqual(run.status, .succeeded)
        XCTAssertEqual(run.result["lifecycle_state"]?.stringValue, "completed")
        XCTAssertEqual(run.result["last_step_id"]?.stringValue, "step")

        let receipts = try OperationReceiptStore(directory: receiptDirectory).list(limit: 20)
        let receiptText = String(decoding: try JSONCodec.encode(receipts), as: UTF8.self)
        XCTAssertFalse(receiptText.contains(token))
        XCTAssertFalse(receiptText.contains("PRIVATE BODY"))
        XCTAssertFalse(receiptText.contains("AXValue"))
        XCTAssertTrue(receipts.contains {
            $0.method == "task.run"
                && $0.lifecycleState == "completed"
                && $0.stepID == "step"
                && $0.evidence.contains { $0.kind == "task_checkpoint" }
        })
    }

    func testTaskServiceResumeValidatesApprovalAgainstOnlyTheRemainingPlan() throws {
        let checkpointDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-resume-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: checkpointDirectory) }
        let approvals = TaskApprovalStore()
        let checkpoints = TaskCheckpointStore(directory: checkpointDirectory)
        let executor = FailSecondTaskActionExecutor()
        let runner = TaskRunner(
            checkpointStore: checkpoints,
            approvalStore: approvals,
            actionExecutor: executor,
            targetRevalidator: { _ in nil }
        )
        let plan = TaskPlan(
            id: "service.resume.remaining",
            name: "Resume remaining steps",
            summary: "Bind resumed approval only to work that remains",
            steps: [
                TaskStep(
                    id: "first",
                    action: ActionSpec(kind: .assert, surface: .macApp),
                    recovery: .strict
                ),
                TaskStep(
                    id: "second",
                    action: ActionSpec(kind: .assert, surface: .macApp),
                    recovery: .strict
                )
            ]
        )
        let firstApproval = try runner.prepare(plan: plan)
        _ = try approvals.approve(token: firstApproval.approval.token)
        XCTAssertThrowsError(try runner.run(plan: plan, approvalToken: firstApproval.approval.token))
        XCTAssertEqual(try runner.status(taskID: plan.id).stepIndex, 1)

        executor.shouldFailSecond = false
        let service = MacCtlService(
            permissionContext: "test",
            keyboardDriveStore: KeyboardDriveStore(),
            taskApprovalStore: approvals,
            taskCheckpointStore: checkpoints,
            taskRunner: runner,
            hasPostEventAccess: { true }
        )
        let planValue = try JSONValue.fromEncodable(plan)
        let prepared = service.handle(RequestEnvelope(
            method: "task.prepare",
            params: ["plan": planValue]
        ))
        let token = try XCTUnwrap(prepared.result["approval"]?.objectValue?["token"]?.stringValue)
        XCTAssertEqual(
            prepared.result["planDigest"]?.stringValue,
            TaskPlan.digest(plan.remaining(from: 1))
        )
        XCTAssertEqual(
            service.handle(RequestEnvelope(
                method: "approval.approve",
                params: ["token": .string(token)]
            )).status,
            .succeeded
        )

        let resumed = service.handle(RequestEnvelope(
            method: "task.resume",
            params: [
                "plan": planValue,
                "approval_token": .string(token)
            ]
        ))

        XCTAssertEqual(resumed.status, .succeeded)
        XCTAssertEqual(resumed.result["lifecycle_state"]?.stringValue, "completed")
        XCTAssertEqual(executor.executeCount, 5)
    }

    func testTaskServiceCreatesBackgroundInputChannelWithoutKeyboardLease() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-channel-receipts-\(UUID().uuidString)")
        let checkpointDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-channel-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: receiptDirectory)
            try? FileManager.default.removeItem(at: checkpointDirectory)
        }
        let target = AppInfo(
            name: "TextEdit",
            bundleID: "com.apple.TextEdit",
            path: "/System/Applications/TextEdit.app",
            isRunning: true,
            processID: 501
        )
        let foreground = AppInfo(
            name: "Finder",
            bundleID: "com.apple.finder",
            path: "/System/Library/CoreServices/Finder.app",
            isRunning: true,
            processID: 502
        )
        let approvals = TaskApprovalStore()
        let checkpoints = TaskCheckpointStore(directory: checkpointDirectory)
        let keyboardLeases = KeyboardDriveStore()
        let runner = TaskRunner(
            checkpointStore: checkpoints,
            approvalStore: approvals,
            actionExecutor: TestTaskActionExecutor(),
            targetRevalidator: { _ in nil }
        )
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "test",
            keyboardDriveStore: keyboardLeases,
            taskApprovalStore: approvals,
            taskCheckpointStore: checkpoints,
            taskRunner: runner,
            foregroundApplication: { foreground },
            resolveApplication: { name in
                guard name == "TextEdit" || name == "com.apple.TextEdit" else {
                    throw AppControllerError.appNotFound(name)
                }
                return target
            },
            hasPostEventAccess: { true }
        )
        let plan = TaskPlan(
            id: "service.background.key",
            name: "Background key",
            summary: "Send a process-directed key without taking the shared keyboard",
            focusPolicy: .background,
            steps: [TaskStep(
                id: "escape",
                action: ActionSpec(
                    kind: .key,
                    surface: .macApp,
                    parameters: ["key": .string("escape")]
                ),
                target: TaskTargetIdentity(application: "TextEdit", processID: target.processID),
                approvalReason: "Dismiss the approved background surface"
            )]
        )
        let planValue = try JSONValue.fromEncodable(plan)
        let prepared = service.handle(RequestEnvelope(
            method: "task.prepare",
            params: ["plan": planValue]
        ))
        let token = try XCTUnwrap(prepared.result["approval"]?.objectValue?["token"]?.stringValue)
        XCTAssertEqual(
            service.handle(RequestEnvelope(
                method: "approval.approve",
                params: ["token": .string(token)]
            )).status,
            .succeeded
        )

        let run = service.handle(RequestEnvelope(
            method: "task.run",
            params: [
                "plan": planValue,
                "approval_token": .string(token)
            ]
        ))

        XCTAssertEqual(run.status, .succeeded)
        XCTAssertNil(keyboardLeases.activeLease())
        XCTAssertEqual(run.result["input_channel"]?["task_id"]?.stringValue, plan.id)
        XCTAssertEqual(run.result["input_channel"]?["focus_policy"]?.stringValue, "background")
        XCTAssertEqual(
            run.result["input_channel"]?["routes"]?.arrayValue?.compactMap(\.stringValue),
            ["process_directed"]
        )
        XCTAssertTrue(run.evidence.contains { $0.kind == "task_input_channel" })
    }

    func testTaskServiceRejectsBackgroundChannelWhenTargetOwnsForeground() throws {
        let checkpointDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-channel-foreground-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: checkpointDirectory) }
        let target = AppInfo(
            name: "TextEdit",
            bundleID: "com.apple.TextEdit",
            path: "/System/Applications/TextEdit.app",
            isRunning: true,
            processID: 503
        )
        let approvals = TaskApprovalStore()
        let checkpoints = TaskCheckpointStore(directory: checkpointDirectory)
        let keyboardLeases = KeyboardDriveStore()
        let runner = TaskRunner(
            checkpointStore: checkpoints,
            approvalStore: approvals,
            actionExecutor: TestTaskActionExecutor(),
            targetRevalidator: { _ in nil }
        )
        let service = MacCtlService(
            permissionContext: "test",
            keyboardDriveStore: keyboardLeases,
            taskApprovalStore: approvals,
            taskCheckpointStore: checkpoints,
            taskRunner: runner,
            foregroundApplication: { target },
            resolveApplication: { _ in target },
            hasPostEventAccess: { true }
        )
        let plan = TaskPlan(
            id: "service.background.foreground",
            name: "Unsafe background key",
            summary: "Reject a channel that could interleave with physical input",
            focusPolicy: .background,
            steps: [TaskStep(
                id: "escape",
                action: ActionSpec(
                    kind: .key,
                    surface: .macApp,
                    parameters: ["key": .string("escape")]
                ),
                target: TaskTargetIdentity(application: "TextEdit", processID: target.processID),
                approvalReason: "Test foreground isolation"
            )]
        )
        let planValue = try JSONValue.fromEncodable(plan)
        let prepared = service.handle(RequestEnvelope(
            method: "task.prepare",
            params: ["plan": planValue]
        ))
        let token = try XCTUnwrap(prepared.result["approval"]?.objectValue?["token"]?.stringValue)
        _ = service.handle(RequestEnvelope(
            method: "approval.approve",
            params: ["token": .string(token)]
        ))

        let run = service.handle(RequestEnvelope(
            method: "task.run",
            params: [
                "plan": planValue,
                "approval_token": .string(token)
            ]
        ))

        XCTAssertEqual(run.status, .blocked)
        XCTAssertNil(run.result["input_channel"])
        XCTAssertNil(keyboardLeases.activeLease())
        XCTAssertEqual(run.error?.code, MacCtlErrorCode.taskBlocked.rawValue)
    }

    func testTaskTargetChangesAndModalStatePauseBeforeDispatch() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-task-target-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let approvals = TaskApprovalStore()
        let executor = TestTaskActionExecutor()
        let runner = TaskRunner(
            checkpointStore: TaskCheckpointStore(directory: directory),
            approvalStore: approvals,
            actionExecutor: executor,
            targetRevalidator: { _ in throw ControlTargetInspectionError.modalDialog }
        )
        let plan = TaskPlan(
            id: "modal.task",
            name: "Modal task",
            summary: "Do not click through dialogs",
            steps: [TaskStep(
                id: "click",
            action: ActionSpec(
                kind: .key,
                surface: .macApp,
                parameters: ["key": .string("cmd+c")]
            ),
            approvalReason: "Test key dispatch"
        )]
        )
        let prepared = try runner.prepare(plan: plan)
        _ = try approvals.approve(token: prepared.approval.token)
        let authority = TaskExecutionAuthority(
            leaseToken: "lease",
            fresh: true,
            revalidate: { nil }
        )
        XCTAssertThrowsError(try runner.run(
            plan: plan,
            approvalToken: prepared.approval.token,
            authority: authority
        )) { error in
            XCTAssertEqual(error as? TaskControlError, .preconditionFailed("modal_dialog"))
        }
        XCTAssertEqual(executor.executeCount, 0)
        XCTAssertEqual(try runner.status(taskID: plan.id).state, .prepared)
        XCTAssertNotNil(try approvals.validateApproved(
            token: prepared.approval.token,
            plan: plan,
            ephemeralInputs: [:]
        ))
    }

    func testReleaseGateRequiresEveryTierOneEvidenceDimension() {
        let expectedExecutable = MacCtlPaths.daemonAppExecutableURL.path
        let identity = RuntimeIdentity(
            processID: 501,
            executablePath: expectedExecutable,
            bundlePath: MacCtlPaths.daemonAppURL.path,
            bundleIdentifier: MacCtlDaemonBundle.bundleIdentifier,
            bundleVersion: "1"
        )
        let launchAgent = LaunchAgentStatus(
            plistPath: MacCtlPaths.launchAgentURL.path,
            expectedExecutablePath: expectedExecutable,
            configuredExecutablePath: expectedExecutable,
            activeExecutablePath: expectedExecutable,
            installed: true,
            launchdLoaded: true,
            loaded: true,
            healthy: true,
            processID: 501,
            jobState: "running",
            lastExitCode: 0,
            identityMatches: true
        )
        let permissions = [
            "Accessibility",
            "Input Monitoring",
            "Post Events",
            "Screen Recording"
        ].map {
            PermissionStatus(
                name: $0,
                state: "granted",
                requiredFor: "test",
                instruction: "Screen Recording may capture screenshots, but receipt payloads must not"
            )
        }
        let keyboardStatus = KeyboardAccessStatus(
            fullKeyboardAccessEnabled: true,
            permissionContext: "daemon",
            permissions: permissions
        )
        let completedAt = Date(timeIntervalSince1970: 9_999)
        let taskCapabilities = TaskCapabilityReport()
        let capabilityReport = CapabilityReport(
            capabilities: ["app.bind", "control.outcome", "control.batch", "control.capabilities", "control.capability_audit", "control.capability_audit_batch", "control.authorization.prepare", "control.authorization.bind", "control.authorization.list", "control.authorization.resolve", "route.benchmark", "receipts.trace.begin", "receipts.trace.complete", "receipts.trace", "shortcut.audit", "shortcut.run"],
            optionalBackends: [],
            permissionGates: [],
            safety: [
                "app.bind keeps expected process identity conjunctive, independently probes the exact PID's AXApplication root, and preserves a registered app-bundle fallback for unsupported development targets",
                "route selection requires daemon-executed measurements; caller-supplied registrations are inventory-only",
                "control outcomes are provider-neutral and expose target, action, verification, and handoff state",
                "control.batch holds one bounded app lease, revalidates every step, and releases the lease on every exit path",
                "control.capability_audit performs a bounded read-only Accessibility/provider audit and persists only redacted identity descriptors; it never dispatches an action",
                "control.capability_audit_batch audits at most 24 explicit or catalog-selected apps, persists one redacted resumable receipt per app, serializes AX access, and never launches apps or dispatches actions",
                "cross-provider traces join Mac Control handoff evidence with browser observations while preserving provider-specific provenance",
                "cross-provider completion credentials are short-lived, single-use, stdin-only, stored only as digests, and never authorize provider execution",
                "browser completion remains orchestrator_declared until a browser-owned attestation channel is available",
                "authorization notices are short-lived, owner-local, redacted, and explanatory only; Mac Control never approves or denies the native macOS prompt",
                "authorization provenance is attested, declared, or unverified; missing or mismatched peer identity is never treated as safe",
                "authorization source opening is unavailable unless a registered Codex opener accepts an allowlisted codex:// reference",
                "shortcut bindings are owner-only, approval-bound by exact digest and operation, and promote to behavior_verified only after a declared postcondition passes",
                "shortcut commands dispatch at most once; indeterminate postconditions never trigger an automatic retry"
            ],
            shortcutCapabilities: ShortcutCapabilityReport(
                bindings: [ShortcutBinding(
                    id: "sc_release",
                    target: .appMenu(
                        applicationName: "Finder",
                        bundleID: "com.apple.finder",
                        menuPath: ["View", "Show Status Bar"]
                    ),
                    chord: "ctrl+option+cmd+1",
                    provider: .macOSAppShortcut,
                    postconditions: [TaskPredicate(kind: .menuItemState, expected: "toggled")],
                    status: .behaviorVerified
                )],
                ownerOnlyStorage: true
            )
        )
        let checkpointStatus = TaskCheckpointStoreStatus(
            directory: "/private/tmp/macctl-task-checkpoints",
            fileCount: 1,
            maximumCheckpoints: 100,
            pendingPrune: 0,
            invalidCheckpointCount: 0,
            writable: true,
            directoryOwnerOnly: true,
            filesOwnerOnly: true,
            oldestCheckpoint: Date(timeIntervalSince1970: 9_998),
            newestCheckpoint: completedAt
        )
        let doctor = DoctorReport(
            processID: 501,
            osVersion: "test",
            architecture: "arm64",
            socketPath: MacCtlPaths.socketURL.path,
            socketOwnerOnly: true,
            permissions: permissions,
            availableFrameworks: [],
            warnings: [],
            permissionContext: "daemon",
            runtimeIdentity: identity,
            launchAgent: launchAgent,
            keyboardAccess: keyboardStatus,
            taskCapabilities: taskCapabilities,
            checkpointStore: checkpointStatus
        )
        let daemon = DaemonStatus(
            daemonName: "macctld",
            runtimeContext: "daemon",
            processID: 501,
            socketPath: MacCtlPaths.socketURL.path,
            socketExists: true,
            approvalCount: 0,
            supportedSurfaces: SurfaceKind.allCases,
            runtimeIdentity: identity,
            launchAgent: launchAgent,
            socketOwnerOnly: true,
            receiptStore: ReceiptStoreStatus(
                directory: MacCtlPaths.receiptsDirectory.path,
                fileCount: 20,
                maximumRecords: 1_000,
                pendingPrune: 0,
                invalidReceiptCount: 0,
                writable: true,
                directoryOwnerOnly: true,
                filesOwnerOnly: true,
                oldestReceipt: Date(timeIntervalSince1970: 9_000),
                newestReceipt: Date(timeIntervalSince1970: 9_999)
            )
        )
        func receipt(
            method: String,
            workflowID: String?,
            status: OperationStatus,
            source: String? = nil,
            approvalState: String = "not_required",
            verificationResult: String = "not_required",
            errorCode: String? = nil,
            evidence: [ReceiptEvidence] = [],
            taskID: String? = nil,
            lifecycleState: String? = nil,
            route: String? = nil
        ) -> OperationReceipt {
            OperationReceipt(
                operationID: UUID().uuidString,
                requestID: UUID().uuidString,
                method: method,
                source: source,
                workflowID: workflowID,
                targetSurface: workflowID == "approval.smoke" ? .macDesktop : .macApp,
                risk: workflowID == "approval.smoke" ? .sensitive : .safe,
                approvalState: approvalState,
                executionResult: status.rawValue,
                verificationResult: verificationResult,
                planDigest: "digest",
                taskID: taskID,
                route: route,
                lifecycleState: lifecycleState,
                runtimeIdentity: identity,
                permissionContext: "daemon",
                permissions: permissions,
                status: status,
                errorCode: errorCode ?? (status == .blocked ? MacCtlErrorCode.approvalRequired.rawValue : nil),
                evidence: evidence,
                startedAt: completedAt.addingTimeInterval(-1),
                completedAt: completedAt
            )
        }
        let receipts = ReleaseGate.requiredMacWorkflows.map {
            receipt(method: "workflow.run", workflowID: $0, status: .succeeded, verificationResult: "passed")
        } + [
            receipt(method: "workflow.prepare", workflowID: "approval.smoke", status: .prepared, approvalState: "prepared"),
            receipt(method: "approval.approve", workflowID: "approval.smoke", status: .succeeded, source: "control_center", approvalState: "approved"),
            receipt(method: "approval.deny", workflowID: "approval.smoke", status: .succeeded, source: "control_center", approvalState: "denied"),
            receipt(
                method: "approval.approve",
                workflowID: "approval.smoke",
                status: .blocked,
                approvalState: "required",
                verificationResult: "blocked",
                errorCode: MacCtlErrorCode.approvalExpired.rawValue
            ),
            receipt(method: "workflow.run", workflowID: "approval.smoke", status: .blocked, approvalState: "required", verificationResult: "blocked"),
            receipt(method: "keyboard.lease.acquire", workflowID: nil, status: .succeeded, evidence: [
                ReceiptEvidence(kind: "keyboard_lease", source: "macctld")
            ]),
            receipt(method: "keyboard.navigate", workflowID: nil, status: .succeeded, verificationResult: "passed", evidence: [
                ReceiptEvidence(kind: "keyboard_input", source: "macctld")
            ]),
            receipt(method: "keyboard.inspect", workflowID: nil, status: .succeeded, evidence: [
                ReceiptEvidence(kind: "keyboard_focus", source: "macctld")
            ]),
            receipt(method: "keyboard.lease.release", workflowID: nil, status: .succeeded, evidence: [
                ReceiptEvidence(kind: "keyboard_lease", source: "macctld")
            ]),
            receipt(method: "adapter.capabilities", workflowID: nil, status: .succeeded, evidence: [
                ReceiptEvidence(kind: "adapter_capabilities", source: "macctld")
            ]),
            receipt(method: "task.prepare", workflowID: nil, status: .prepared, evidence: [
                ReceiptEvidence(kind: "task_checkpoint", source: "macctld")
            ], taskID: "release-task", lifecycleState: "prepared"),
            receipt(method: "task.run", workflowID: nil, status: .succeeded, verificationResult: "passed", evidence: [
                ReceiptEvidence(kind: "task_checkpoint", source: "macctld")
            ], taskID: "release-task", lifecycleState: "completed"),
            receipt(method: "task.status", workflowID: nil, status: .succeeded, verificationResult: "passed", evidence: [
                ReceiptEvidence(kind: "task_checkpoint", source: "macctld")
            ], taskID: "release-task", lifecycleState: "completed"),
            receipt(method: "task.cancel", workflowID: nil, status: .succeeded, evidence: [
                ReceiptEvidence(kind: "task_checkpoint", source: "macctld")
            ], taskID: "release-task", lifecycleState: "cancelled"),
            receipt(method: "shortcut.run", workflowID: nil, status: .succeeded, verificationResult: "passed", evidence: [
                ReceiptEvidence(kind: "shortcut_behavior", source: "macctld")
            ], route: ShortcutRunRoute.accessibility.rawValue),
            receipt(method: "shortcut.run", workflowID: nil, status: .succeeded, verificationResult: "passed", evidence: [
                ReceiptEvidence(kind: "shortcut_behavior", source: "macctld")
            ], route: ShortcutRunRoute.keyboard.rawValue)
        ]
        let snapshot = ReleaseGateSnapshot(
            launchAgent: launchAgent,
            daemonStatus: daemon,
            doctorReport: doctor,
            capabilityReport: capabilityReport,
            receiptStoreStatus: daemon.receiptStore,
            receipts: receipts,
            socketExists: true,
            socketOwnerOnly: true,
            daemonError: nil,
            keyboardAccessStatus: keyboardStatus,
            taskCapabilities: taskCapabilities,
            checkpointStoreStatus: checkpointStatus
        )
        let report = ReleaseGate(maximumEvidenceAge: 100, now: { Date(timeIntervalSince1970: 10_000) })
            .evaluate(snapshot: snapshot)
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.blockerCount, 0)
        XCTAssertTrue(report.checks.allSatisfy { $0.state == .passed })
        XCTAssertEqual(
            report.checks.first(where: { $0.id == "agent.contract" })?.state,
            .passed
        )
        XCTAssertEqual(
            report.checks.first(where: { $0.id == "authorization.notice" })?.state,
            .passed
        )

        let unverifiedKeyboardReceipts = receipts.map { existing in
            guard existing.method == "keyboard.navigate" else { return existing }
            return receipt(
                method: "keyboard.navigate",
                workflowID: nil,
                status: .succeeded,
                verificationResult: "foreground_only",
                evidence: [ReceiptEvidence(kind: "keyboard_input", source: "macctld")]
            )
        }
        let unverifiedKeyboardReport = ReleaseGate(
            maximumEvidenceAge: 100,
            now: { Date(timeIntervalSince1970: 10_000) }
        ).evaluate(snapshot: ReleaseGateSnapshot(
            launchAgent: launchAgent,
            daemonStatus: daemon,
            doctorReport: doctor,
            capabilityReport: capabilityReport,
            receiptStoreStatus: daemon.receiptStore,
            receipts: unverifiedKeyboardReceipts,
            socketExists: true,
            socketOwnerOnly: true,
            daemonError: nil,
            keyboardAccessStatus: keyboardStatus,
            taskCapabilities: taskCapabilities,
            checkpointStoreStatus: checkpointStatus
        ))
        XCTAssertEqual(
            unverifiedKeyboardReport.checks.first(where: { $0.id == "live.keyboard-control" })?.state,
            .blocked
        )

        let networkReport = ReleaseGate(maximumEvidenceAge: 100, now: { Date(timeIntervalSince1970: 10_000) })
            .evaluate(snapshot: ReleaseGateSnapshot(
                launchAgent: launchAgent,
                daemonStatus: daemon,
                doctorReport: doctor,
                capabilityReport: capabilityReport,
                receiptStoreStatus: daemon.receiptStore,
                receipts: receipts,
                socketExists: true,
                socketOwnerOnly: true,
                networkListenerConfigured: true,
                daemonError: nil,
                keyboardAccessStatus: keyboardStatus,
                taskCapabilities: taskCapabilities,
                checkpointStoreStatus: checkpointStatus
            ))
        XCTAssertEqual(
            networkReport.checks.first(where: { $0.id == "transport.local_only" })?.state,
            .failed
        )

        let blockedReport = ReleaseGate(maximumEvidenceAge: 100, now: { Date(timeIntervalSince1970: 10_000) })
            .evaluate(snapshot: ReleaseGateSnapshot(
                launchAgent: launchAgent,
                daemonStatus: nil,
                doctorReport: nil,
                receiptStoreStatus: nil,
                receipts: [],
                socketExists: false,
                socketOwnerOnly: false,
                daemonError: "not running"
            ))
        XCTAssertFalse(blockedReport.passed)
        XCTAssertGreaterThan(blockedReport.blockerCount, 0)
        XCTAssertEqual(
            blockedReport.checks.first(where: { $0.id == "agent.contract" })?.state,
            .blocked
        )
        XCTAssertNil(blockedReport.checks.first { $0.id == "live.iphone-mirroring" })
    }
}

private func capabilityTree(
    for application: AppInfo,
    identifier: String,
    scrollable: Bool,
    truncated: Bool = false,
    coverage: AccessibilityTreeCoverage? = nil
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
    let node = AccessibilityTreeNode(
        path: "0/0",
        depth: 1,
        role: scrollable ? "AXScrollArea" : "AXButton",
        subrole: nil,
        identifier: identifier,
        label: "Public label",
        actions: scrollable ? ["AXScrollDown"] : ["AXPress"],
        state: state,
        bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
        childCount: 0,
        scrollable: scrollable
    )
    return AccessibilityTreeReport(
        application: application,
        maxNodes: 20,
        maxDepth: 4,
        nodeCount: 2,
        truncated: truncated,
        nodes: [node],
        identifierMatchCounts: [identifier: 1],
        nameMatchCounts: ["Public label": 1],
        coverage: coverage
    )
}

private func testApp(name: String, processID: Int32, bundleVersion: String? = nil) -> AppInfo {
    AppInfo(
        name: name,
        bundleID: "com.example.\(name.lowercased())",
        path: "/Applications/\(name).app",
        isRunning: true,
        processID: processID,
        bundleVersion: bundleVersion
    )
}

private func testWarmPathContext() -> WarmPathContextIdentity {
    WarmPathContextIdentity(
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        providerStateSignature: CapabilityProviderState(
            permissionStatuses: PermissionDiagnostics.unknownReport()
        ).signature
    )
}

private final class RecordingKeyboardEventSender: KeyboardEventSending {
    private(set) var keys: [String] = []
    var shouldFail = false

    func send(keySpecification: String) throws {
        if shouldFail {
            throw KeyboardControlError.invalidSequence("test")
        }
        keys.append(keySpecification)
    }
}

private final class RecordingPhysicalKeyboardSuppressor: PhysicalKeyboardSuppressing {
    private(set) var acquiredUntil: [Date] = []
    private(set) var releaseCount = 0
    var shouldFailAcquire = false

    func acquire(until: Date) throws {
        if shouldFailAcquire {
            throw PhysicalKeyboardSuppressionError.eventTapUnavailable
        }
        acquiredUntil.append(until)
    }

    func release() {
        releaseCount += 1
    }
}

private final class CallbackKeyboardEventSender: KeyboardEventSending {
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func send(keySpecification: String) throws {
        callback()
    }
}

private final class TestAccessibilityActionPerformer: AccessibilityActionPerforming {
    private let failure: AccessibilityControllerError?
    private(set) var pressCount = 0

    init(error: AccessibilityControllerError? = nil) {
        failure = error
    }

    @discardableResult
    func press(pid: pid_t, selector: MacCtlCore.Selector) throws -> CGRect {
        pressCount += 1
        if let failure {
            throw failure
        }
        return CGRect(x: 10, y: 20, width: 40, height: 20)
    }
}

private final class TestContextMenuActionPerformer: AccessibilityContextMenuPerforming {
    let report: ContextMenuReport
    private(set) var callCount = 0
    private(set) var lastExpectedMenuItems: [String] = []

    init(report: ContextMenuReport) {
        self.report = report
    }

    func showContextMenu(
        pid: pid_t,
        selector: MacCtlCore.Selector,
        expectedMenuItems: [String]
    ) throws -> ContextMenuReport {
        callCount += 1
        lastExpectedMenuItems = expectedMenuItems
        return report
    }
}

private final class RecordingAccessibilityTreeInspector: AccessibilityTreeInspecting {
    let treeReport: AccessibilityTreeReport
    private(set) var lastMaxNodes: Int?
    private(set) var lastMaxDepth: Int?
    private(set) var treeCallCount = 0

    init(tree: AccessibilityTreeReport) {
        treeReport = tree
    }

    func tree(
        pid: pid_t,
        application: AppInfo,
        maxNodes: Int,
        maxDepth: Int
    ) throws -> AccessibilityTreeReport {
        treeCallCount += 1
        lastMaxNodes = maxNodes
        lastMaxDepth = maxDepth
        return treeReport
    }

    func audit(
        pid: pid_t,
        application: AppInfo,
        manifest: AccessibilityAuditManifest
    ) throws -> AccessibilityAuditReport {
        AccessibilityAuditEngine.audit(tree: treeReport, manifest: manifest)
    }
}

private final class AdaptiveRecordingAccessibilityTreeInspector: AccessibilityTreeInspecting {
    struct Request {
        let maxNodes: Int
        let maxDepth: Int
    }

    private let makeTree: (Int, Int) -> AccessibilityTreeReport
    private(set) var requests: [Request] = []

    init(makeTree: @escaping (Int, Int) -> AccessibilityTreeReport) {
        self.makeTree = makeTree
    }

    func tree(
        pid: pid_t,
        application: AppInfo,
        maxNodes: Int,
        maxDepth: Int
    ) throws -> AccessibilityTreeReport {
        requests.append(Request(maxNodes: maxNodes, maxDepth: maxDepth))
        return makeTree(maxNodes, maxDepth)
    }

    func audit(
        pid: pid_t,
        application: AppInfo,
        manifest: AccessibilityAuditManifest
    ) throws -> AccessibilityAuditReport {
        AccessibilityAuditEngine.audit(
            tree: makeTree(manifest.maxNodes, manifest.maxDepth),
            manifest: manifest
        )
    }
}

private final class WindowedRecordingAccessibilityTreeInspector: AccessibilityTreeInspecting, WindowedAccessibilityTreeInspecting {
    struct RecursiveRequest {
        let maxNodes: Int
        let maxDepth: Int
    }

    struct WindowedRequest {
        let maxNodesPerPage: Int
        let maxDepth: Int
        let maxWindows: Int
        let maxPages: Int
    }

    private let recursiveTree: AccessibilityTreeReport
    private let windowedTreeReport: AccessibilityTreeReport
    private(set) var recursiveRequests: [RecursiveRequest] = []
    private(set) var windowedRequests: [WindowedRequest] = []

    init(recursiveTree: AccessibilityTreeReport, windowedTree: AccessibilityTreeReport) {
        self.recursiveTree = recursiveTree
        self.windowedTreeReport = windowedTree
    }

    func tree(
        pid: pid_t,
        application: AppInfo,
        maxNodes: Int,
        maxDepth: Int
    ) throws -> AccessibilityTreeReport {
        recursiveRequests.append(RecursiveRequest(maxNodes: maxNodes, maxDepth: maxDepth))
        return recursiveTree
    }

    func windowedTree(
        pid: pid_t,
        application: AppInfo,
        maxNodesPerPage: Int,
        maxDepth: Int,
        maxWindows: Int,
        maxPages: Int
    ) throws -> AccessibilityTreeReport {
        windowedRequests.append(WindowedRequest(
            maxNodesPerPage: maxNodesPerPage,
            maxDepth: maxDepth,
            maxWindows: maxWindows,
            maxPages: maxPages
        ))
        return windowedTreeReport
    }

    func audit(
        pid: pid_t,
        application: AppInfo,
        manifest: AccessibilityAuditManifest
    ) throws -> AccessibilityAuditReport {
        AccessibilityAuditEngine.audit(tree: recursiveTree, manifest: manifest)
    }
}

private final class RecordingAccessibilityScrollPerformer: AccessibilityScrollPerforming {
    private(set) var lastSelector: MacCtlCore.Selector?
    private(set) var lastDirection: AccessibilityScrollDirection?
    private(set) var lastAmount: Int?
    private(set) var calls: [(direction: AccessibilityScrollDirection, amount: Int)] = []
    private let failure: AccessibilityControllerError?
    private let verification: ScrollVerificationState

    init(
        failure: AccessibilityControllerError? = nil,
        verification: ScrollVerificationState = .passed
    ) {
        self.failure = failure
        self.verification = verification
    }

    func scroll(
        pid: pid_t,
        application: AppInfo,
        selector: MacCtlCore.Selector,
        direction: AccessibilityScrollDirection,
        amount: Int
    ) throws -> AccessibilityScrollReport {
        lastSelector = selector
        lastDirection = direction
        lastAmount = amount
        calls.append((direction: direction, amount: amount))
        if let failure {
            throw failure
        }
        return AccessibilityScrollReport(
            application: application,
            targetIdentifier: selector.identifier ?? "role:AXScrollArea",
            direction: direction,
            amount: amount,
            verification: verification
        )
    }
}

private final class RecordingControlEventMonitor: ControlEventMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(handler: @escaping () -> Void) {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

private final class RecordingInputScrollPerformer: InputScrollPerforming {
    private let report: InputScrollReport
    private let failure: Error?
    private(set) var callCount = 0
    private(set) var lastDirection: String?
    private(set) var lastAmount: Int32?

    init(
        report: InputScrollReport? = nil,
        failure: Error? = nil
    ) {
        self.report = report ?? InputScrollReport(direction: "down", amount: 2)
        self.failure = failure
    }

    @discardableResult
    func scroll(amount: Int32, direction: String) throws -> InputScrollReport {
        callCount += 1
        lastDirection = direction
        lastAmount = amount
        if let failure {
            throw failure
        }
        return report
    }
}

private final class TestVisualActionPerformer: VisualActionPerforming {
    private(set) var activationCount = 0

    @discardableResult
    func activate(selector: MacCtlCore.Selector, application: AppInfo) throws -> CGRect {
        activationCount += 1
        return CGRect(x: 10, y: 20, width: 40, height: 20)
    }
}

private final class TestKeyboardPreferenceStore: KeyboardPreferenceStore {
    enum EnableResult {
        case success
        case verificationFailure
    }

    var enabled: Bool
    var enableResult: EnableResult = .success
    private(set) var enableCalled = false

    init(enabled: Bool) {
        self.enabled = enabled
    }

    var fullKeyboardAccessEnabled: Bool {
        enabled
    }

    func enableFullKeyboardAccess() throws {
        enableCalled = true
        switch enableResult {
        case .success:
            enabled = true
        case .verificationFailure:
            throw KeyboardControlError.enableVerificationFailed
        }
    }
}

private final class TestFocusedElementInspector: FocusedElementInspecting {
    private let value: FocusedElementSnapshot?
    private let failure: Error?

    init(snapshot: FocusedElementSnapshot) {
        value = snapshot
        failure = nil
    }

    init(error: Error) {
        value = nil
        failure = error
    }

    func focusedElementSnapshot(pid: pid_t, application: AppInfo) throws -> FocusedElementSnapshot {
        if let failure {
            throw failure
        }
        return try XCTUnwrap(value)
    }
}

private final class SequencedFocusedElementInspector: FocusedElementInspecting {
    private let snapshots: [FocusedElementSnapshot]
    private var index = 0

    init(_ snapshots: [FocusedElementSnapshot]) {
        self.snapshots = snapshots
    }

    func focusedElementSnapshot(pid: pid_t, application: AppInfo) throws -> FocusedElementSnapshot {
        let fallback = try XCTUnwrap(snapshots.last)
        let snapshot = index < snapshots.count ? snapshots[index] : fallback
        index += 1
        return snapshot
    }
}

private final class OptionalSequencedFocusedElementInspector: FocusedElementInspecting {
    private let snapshots: [FocusedElementSnapshot?]
    private var index = 0

    init(_ snapshots: [FocusedElementSnapshot?]) {
        self.snapshots = snapshots
    }

    func focusedElementSnapshot(pid: pid_t, application: AppInfo) throws -> FocusedElementSnapshot {
        guard !snapshots.isEmpty else { throw AccessibilityControllerError.unreadableFocus }
        let snapshot = index < snapshots.count ? snapshots[index] : snapshots[snapshots.count - 1]
        index += 1
        guard let snapshot else { throw AccessibilityControllerError.unreadableFocus }
        return snapshot
    }
}

private final class TestTaskActionExecutor: TaskActionExecuting {
    private(set) var executeCount = 0
    private(set) var recoveryRoutes: [String?] = []
    private(set) var evaluationCount = 0
    private var failuresBeforeSuccess: Int
    private let sideEffectUncertain: Bool
    var evaluationResult: Bool
    private var evaluationResults: [Bool]
    let route: String

    init(
        failuresBeforeSuccess: Int = 0,
        sideEffectUncertain: Bool = false,
        evaluationResult: Bool = true,
        evaluationResults: [Bool] = [],
        route: String = "test"
    ) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.sideEffectUncertain = sideEffectUncertain
        self.evaluationResult = evaluationResult
        self.evaluationResults = evaluationResults
        self.route = route
    }

    func execute(
        action: ActionSpec,
        context: TaskActionContext
    ) throws -> TaskActionExecutionReport {
        executeCount += 1
        recoveryRoutes.append(context.recoveryRoute)
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw TaskActionExecutionError.blocked("transient")
        }
        return TaskActionExecutionReport(
            route: route,
            sideEffectUncertain: sideEffectUncertain
        )
    }

    func evaluate(
        predicate: TaskPredicate,
        context: TaskActionContext
    ) throws -> Bool {
        evaluationCount += 1
        if !evaluationResults.isEmpty {
            return evaluationResults.removeFirst()
        }
        return evaluationResult
    }
}

private final class FailSecondTaskActionExecutor: TaskActionExecuting {
    private(set) var executeCount = 0
    var shouldFailSecond = true

    func execute(action: ActionSpec, context: TaskActionContext) throws -> TaskActionExecutionReport {
        executeCount += 1
        if shouldFailSecond && executeCount >= 2 {
            throw TaskActionExecutionError.blocked("second_step")
        }
        return TaskActionExecutionReport(route: "test")
    }

    func evaluate(predicate: TaskPredicate, context: TaskActionContext) throws -> Bool {
        true
    }
}
