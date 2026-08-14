import XCTest
@testable import MacCtlCore

final class NativeWindowManagementTests: XCTestCase {
    func testNamedLayoutsCoverUsableFrameWithDeterministicRounding() {
        let bounds = NativeWindowFrame(x: -1920, y: 24, width: 1919, height: 1055)

        XCTAssertEqual(
            NativeWindowLayoutResolver.frame(for: .leftHalf, in: bounds),
            NativeWindowFrame(x: -1920, y: 24, width: 959, height: 1055)
        )
        XCTAssertEqual(
            NativeWindowLayoutResolver.frame(for: .rightThird, in: bounds),
            NativeWindowFrame(x: -641, y: 24, width: 640, height: 1055)
        )
        XCTAssertEqual(
            NativeWindowLayoutResolver.frame(for: .bottomRightQuarter, in: bounds),
            NativeWindowFrame(x: -961, y: 552, width: 960, height: 527)
        )
    }

    func testCenteredLayoutStaysInsidePortraitDisplay() {
        let bounds = NativeWindowFrame(x: 1440, y: -900, width: 900, height: 1440)
        XCTAssertEqual(
            NativeWindowLayoutResolver.frame(for: .center, in: bounds),
            NativeWindowFrame(x: 1530, y: -756, width: 720, height: 1152)
        )
    }

    func testRestoreStoreIsBoundedAndSingleUse() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let store = NativeWindowRestoreStore(now: { now }, lifetime: 30)
        let snapshot = NativeWindowSnapshot(
            processID: 42,
            identityDigest: "digest",
            frame: NativeWindowFrame(x: 10, y: 20, width: 300, height: 400),
            displayID: 7,
            movable: true,
            resizable: true,
            minimized: false,
            fullscreen: false
        )
        let record = try store.issue(application: "TextEdit", snapshot: snapshot)
        XCTAssertEqual(try store.record(token: record.token).processID, 42)
        try store.consume(token: record.token)
        XCTAssertThrowsError(try store.record(token: record.token)) {
            XCTAssertEqual($0 as? NativeWindowControlError, .restoreAlreadyUsed)
        }

        let expiring = try store.issue(application: "TextEdit", snapshot: snapshot)
        now = now.addingTimeInterval(31)
        XCTAssertThrowsError(try store.record(token: expiring.token)) {
            XCTAssertEqual($0 as? NativeWindowControlError, .restoreExpired)
        }
    }

    func testServicePlacesAndRestoresExactWindow() throws {
        let app = AppInfo(
            name: "Fixture",
            bundleID: "example.fixture",
            path: "/Applications/Fixture.app",
            isRunning: true,
            processID: 99
        )
        let display = NativeWindowDisplay(
            id: 55,
            name: "External",
            visibleFrame: NativeWindowFrame(x: 1000, y: 0, width: 1200, height: 800)
        )
        let controller = FixtureNativeWindowController(
            snapshot: NativeWindowSnapshot(
                processID: 99,
                identityDigest: "window-a",
                frame: NativeWindowFrame(x: 20, y: 30, width: 600, height: 500),
                displayID: 55,
                movable: true,
                resizable: true,
                minimized: false,
                fullscreen: false
            )
        )
        let service = MacCtlService(
            permissionContext: "test",
            nativeWindowController: controller,
            nativeWindowDisplayProvider: FixtureNativeWindowDisplayProvider(displays: [display]),
            foregroundApplication: { app },
            resolveApplication: { _ in app },
            activateApplication: { _ in app }
        )

        let placed = service.handle(RequestEnvelope(method: "window.place", params: [
            "app": .string("Fixture"),
            "display_id": .number(55),
            "layout": .string("right-half"),
            "confirm": .bool(true)
        ]))
        XCTAssertEqual(placed.status, .succeeded)
        XCTAssertEqual(placed.outcome?.state, .verifiedSuccess)
        XCTAssertEqual(controller.setCount, 1)
        XCTAssertEqual(controller.snapshot.frame, NativeWindowFrame(x: 1600, y: 0, width: 600, height: 800))
        let token = try XCTUnwrap(placed.result["restore_token"]?.stringValue)

        let restored = service.handle(RequestEnvelope(method: "window.restore", params: [
            "restore_token": .string(token),
            "confirm": .bool(true)
        ]))
        XCTAssertEqual(restored.status, .succeeded)
        XCTAssertEqual(controller.setCount, 2)
        XCTAssertEqual(controller.snapshot.frame, NativeWindowFrame(x: 20, y: 30, width: 600, height: 500))

        let replay = service.handle(RequestEnvelope(method: "window.restore", params: [
            "restore_token": .string(token),
            "confirm": .bool(true)
        ]))
        XCTAssertEqual(replay.status, .blocked)
        XCTAssertEqual(controller.setCount, 2)
    }

    func testServiceRejectsMutationWithoutConfirmation() {
        let service = MacCtlService(permissionContext: "test")
        let response = service.handle(RequestEnvelope(method: "window.place", params: [
            "app": .string("Fixture"),
            "display_id": .number(1),
            "layout": .string("maximize")
        ]))
        XCTAssertEqual(response.status, .blocked)
        XCTAssertEqual(response.error?.code, MacCtlErrorCode.approvalRequired.rawValue)
    }
}

private struct FixtureNativeWindowDisplayProvider: NativeWindowDisplayProviding {
    let displays: [NativeWindowDisplay]
    func connectedDisplays() -> [NativeWindowDisplay] { displays }
}

private final class FixtureNativeWindowController: NativeWindowControlling {
    var snapshot: NativeWindowSnapshot
    var setCount = 0

    init(snapshot: NativeWindowSnapshot) { self.snapshot = snapshot }

    func focusedWindow(pid: pid_t, displays: [NativeWindowDisplay]) throws -> NativeWindowSnapshot {
        snapshot
    }

    func setFrame(pid: pid_t, identityDigest: String, frame: NativeWindowFrame, displays: [NativeWindowDisplay]) throws -> NativeWindowSnapshot {
        guard identityDigest == snapshot.identityDigest else { throw NativeWindowControlError.targetMissing }
        setCount += 1
        snapshot = NativeWindowSnapshot(
            processID: snapshot.processID,
            identityDigest: snapshot.identityDigest,
            frame: frame,
            displayID: displays.first(where: { $0.visibleFrame.cgRect.contains(CGPoint(x: frame.cgRect.midX, y: frame.cgRect.midY)) })?.id,
            movable: snapshot.movable,
            resizable: snapshot.resizable,
            minimized: snapshot.minimized,
            fullscreen: snapshot.fullscreen
        )
        return snapshot
    }
}
