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

    func testSelectorPrecedencePrefersAccessibilityThenVisualThenCoordinates() {
        XCTAssertEqual(Selector(title: "Save", normalizedX: 0.5, normalizedY: 0.5).tier, .accessibility)
        XCTAssertEqual(Selector(containsText: "Save", normalizedX: 0.5, normalizedY: 0.5).tier, .visual)
        XCTAssertEqual(Selector(normalizedX: 0.5, normalizedY: 0.5).tier, .normalizedCoordinate)
        XCTAssertEqual(Selector(rawX: 100, rawY: 200).tier, .rawCoordinate)
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

    func testKeyboardCommandsMapToTheDocumentedSequences() {
        let expected: [KeyboardCommand: [String]] = [
            .nextControl: ["tab"],
            .previousControl: ["shift+tab"],
            .activate: ["space"],
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
            allowRawCoordinate: false
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

    func testIPhoneMirroringDrivingLeaseIsExclusiveAndExpires() throws {
        var now = Date(timeIntervalSince1970: 100)
        let store = IPhoneMirroringDrivingLeaseStore(
            lifetime: 10,
            now: { now }
        )

        let first = try store.acquire()
        XCTAssertTrue(first.isHeld)
        XCTAssertThrowsError(try store.acquire()) { error in
            XCTAssertEqual(error as? IPhoneMirroringDrivingLeaseError, .alreadyHeld)
        }
        XCTAssertTrue(try XCTUnwrap(store.lease(for: first.token)).isHeld)

        XCTAssertTrue(store.release(token: first.token))
        XCTAssertFalse(first.isHeld)
        XCTAssertFalse(store.release(token: first.token))

        let second = try store.acquire()
        now = now.addingTimeInterval(11)
        XCTAssertFalse(second.isHeld)
        XCTAssertNil(store.lease(for: second.token))
        XCTAssertNoThrow(try store.acquire())
    }

    func testIPhoneMirroringNavigationRequiresAUserHeldDrivingLease() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-mirroring-lease-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "client"
        )

        let direct = service.handle(RequestEnvelope(
            method: "iphone.open-app",
            params: ["name": .string("Tinder")]
        ))
        XCTAssertEqual(direct.status, .blocked)
        XCTAssertEqual(direct.error?.code, MacCtlErrorCode.mirroringDrivingLeaseRequired.rawValue)

        let prepared = service.handle(RequestEnvelope(
            method: "workflow.prepare",
            params: ["workflow": .string("iphone.open-tinder")]
        ))
        XCTAssertEqual(prepared.status, .prepared)
        XCTAssertEqual(prepared.result["mirroring_driving_lease_required"]?.boolValue, true)

        let run = service.handle(RequestEnvelope(
            method: "workflow.run",
            params: ["workflow": .string("iphone.open-tinder")]
        ))
        XCTAssertEqual(run.status, .blocked)
        XCTAssertEqual(run.error?.code, MacCtlErrorCode.mirroringDrivingLeaseRequired.rawValue)
    }

    func testGenericMirroringSyntheticInputRequiresTheDrivingLease() throws {
        let workflow = WorkflowSpec(
            id: "test.mirroring-key",
            name: "Mirroring key",
            summary: "Test",
            surface: .iphoneMirroring,
            actions: [ActionSpec(
                kind: .key,
                surface: .iphoneMirroring,
                parameters: [
                    "key": .string("down"),
                    "approval_reason": .string("lease guard test")
                ]
            )]
        )

        XCTAssertThrowsError(try WorkflowExecutor().execute(workflow)) { error in
            guard let workflowError = error as? WorkflowExecutionError else {
                XCTFail("Expected a workflow execution error")
                return
            }
            if case .mirroringDrivingLeaseRequired = workflowError {
                return
            }
            XCTFail("Expected the Mirroring driving lease guard")
        }
    }

    func testIPhoneMirroringDrivingLeaseServiceHandoffDoesNotPersistToken() throws {
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-mirroring-lease-service-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let service = MacCtlService(
            receiptStore: OperationReceiptStore(directory: receiptDirectory),
            permissionContext: "client"
        )

        let begun = service.handle(RequestEnvelope(method: "iphone.drive.begin"))
        XCTAssertEqual(begun.status, .succeeded)
        let token = try XCTUnwrap(begun.result["driving_lease_token"]?.stringValue)
        XCTAssertFalse(token.isEmpty)

        let competing = service.handle(RequestEnvelope(method: "iphone.drive.begin"))
        XCTAssertEqual(competing.status, .blocked)
        XCTAssertEqual(competing.error?.code, MacCtlErrorCode.mirroringDrivingLeaseHeld.rawValue)

        let ended = service.handle(RequestEnvelope(
            method: "iphone.drive.end",
            params: ["driving_lease_token": .string(token)]
        ))
        XCTAssertEqual(ended.status, .succeeded)

        let receipts = try OperationReceiptStore(directory: receiptDirectory).list(limit: 10)
        XCTAssertTrue(receipts.filter { $0.method == "iphone.drive.begin" && $0.status == .succeeded }
            .allSatisfy { receipt in
                receipt.evidence.contains { $0.kind == "mirroring_driving_lease" }
            })
        let receiptData = try JSONCodec.encode(receipts)
        let receiptText = String(decoding: receiptData, as: UTF8.self)
        XCTAssertFalse(receiptText.contains(token))
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

        let executed = service.handle(RequestEnvelope(
            method: "approval.approve",
            params: [
                "token": .string(token),
                "source": .string("test")
            ]
        ))
        XCTAssertEqual(executed.status, .succeeded)
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

    func testExpiredApprovalReceiptRetainsWorkflowAndHUDProvenance() throws {
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
                "source": .string("hud")
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
        XCTAssertEqual(receipt.source, "hud")
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
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-task-route-(UUID().uuidString)")
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

        let directory = URL(fileURLWithPath: "/private/tmp/macctl-checkpoint-(UUID().uuidString)")
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
        let safeDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-safe-(UUID().uuidString)")
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

        let reversibleDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-reversible-(UUID().uuidString)")
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

        let budgetDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-budget-(UUID().uuidString)")
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
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-task-resume-(UUID().uuidString)")
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
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-task-interrupted-(UUID().uuidString)")
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
            id: "interrupted.task",
            name: "Interrupted task",
            summary: "Require explicit restart authority",
            steps: [TaskStep(id: "step", action: ActionSpec(kind: .assert, surface: .macApp))]
        )
        let startedAt = Date().addingTimeInterval(-1)
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
            accuracy: 1
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
            accuracy: 1
        )
    }

    func testSensitiveTaskNeverRetriesUncertainActionAndCancellationInvalidatesState() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-task-sensitive-(UUID().uuidString)")
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

        let cancellationDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-cancel-(UUID().uuidString)")
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
        let receiptDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-receipts-(UUID().uuidString)")
        let checkpointDirectory = URL(fileURLWithPath: "/private/tmp/macctl-task-service-(UUID().uuidString)")
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

    func testTaskTargetChangesAndModalStatePauseBeforeDispatch() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/macctl-task-target-(UUID().uuidString)")
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
        XCTAssertEqual(try runner.status(taskID: plan.id).state, .paused)
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
            lifecycleState: String? = nil
        ) -> OperationReceipt {
            OperationReceipt(
                operationID: UUID().uuidString,
                requestID: UUID().uuidString,
                method: method,
                source: source,
                workflowID: workflowID,
                targetSurface: workflowID == "iphone.open-tinder"
                    ? .iphoneMirroring
                    : workflowID == "approval.smoke" ? .macDesktop : .macApp,
                risk: workflowID == "approval.smoke" ? .sensitive : .safe,
                approvalState: approvalState,
                executionResult: status.rawValue,
                verificationResult: verificationResult,
                planDigest: "digest",
                taskID: taskID,
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
            receipt(method: "workflow.run", workflowID: "iphone.open-tinder", status: .succeeded, verificationResult: "passed", evidence: [
                ReceiptEvidence(kind: "mirroring_driving_lease", source: "macctld"),
                ReceiptEvidence(kind: "ocr_anchor", source: "iPhone Mirroring"),
                ReceiptEvidence(kind: "assertion", source: "iPhone Mirroring")
            ]),
            receipt(method: "workflow.prepare", workflowID: "approval.smoke", status: .prepared, approvalState: "prepared"),
            receipt(method: "approval.approve", workflowID: "approval.smoke", status: .succeeded, source: "hud", approvalState: "approved"),
            receipt(method: "approval.deny", workflowID: "approval.smoke", status: .succeeded, source: "hud", approvalState: "denied"),
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
            ], taskID: "release-task", lifecycleState: "cancelled")
        ]
        let snapshot = ReleaseGateSnapshot(
            launchAgent: launchAgent,
            daemonStatus: daemon,
            doctorReport: doctor,
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
        XCTAssertTrue(blockedReport.checks.contains { $0.id == "live.iphone-mirroring" && $0.state == .blocked })
    }
}

private func testApp(name: String, processID: Int32) -> AppInfo {
    AppInfo(
        name: name,
        bundleID: "com.example.\(name.lowercased())",
        path: "/Applications/\(name).app",
        isRunning: true,
        processID: processID
    )
}

private final class RecordingKeyboardEventSender: KeyboardEventSending {
    private(set) var keys: [String] = []

    func send(keySpecification: String) throws {
        keys.append(keySpecification)
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

private final class TestTaskActionExecutor: TaskActionExecuting {
    private(set) var executeCount = 0
    private(set) var recoveryRoutes: [String?] = []
    private(set) var evaluationCount = 0
    private var failuresBeforeSuccess: Int
    private let sideEffectUncertain: Bool
    var evaluationResult: Bool
    let route: String

    init(
        failuresBeforeSuccess: Int = 0,
        sideEffectUncertain: Bool = false,
        evaluationResult: Bool = true,
        route: String = "test"
    ) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.sideEffectUncertain = sideEffectUncertain
        self.evaluationResult = evaluationResult
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
        return evaluationResult
    }
}
