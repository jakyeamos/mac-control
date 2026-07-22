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
}
