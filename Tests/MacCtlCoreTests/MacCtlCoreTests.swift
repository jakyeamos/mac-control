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
                instruction: "test"
            )
        }
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
            launchAgent: launchAgent
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
        let completedAt = Date(timeIntervalSince1970: 9_999)
        func receipt(
            method: String,
            workflowID: String?,
            status: OperationStatus,
            source: String? = nil,
            approvalState: String = "not_required",
            verificationResult: String = "not_required",
            errorCode: String? = nil,
            evidence: [ReceiptEvidence] = []
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
            receipt(method: "workflow.run", workflowID: "approval.smoke", status: .blocked, approvalState: "required", verificationResult: "blocked")
        ]
        let snapshot = ReleaseGateSnapshot(
            launchAgent: launchAgent,
            daemonStatus: daemon,
            doctorReport: doctor,
            receiptStoreStatus: daemon.receiptStore,
            receipts: receipts,
            socketExists: true,
            socketOwnerOnly: true,
            daemonError: nil
        )
        let report = ReleaseGate(maximumEvidenceAge: 100, now: { Date(timeIntervalSince1970: 10_000) })
            .evaluate(snapshot: snapshot)
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.blockerCount, 0)
        XCTAssertTrue(report.checks.allSatisfy { $0.state == .passed })

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
                daemonError: nil
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
