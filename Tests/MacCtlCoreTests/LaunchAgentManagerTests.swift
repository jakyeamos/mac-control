import Darwin
import Foundation
import XCTest
@testable import MacCtlCore

final class LaunchAgentManagerTests: XCTestCase {
    func testEnsureBootstrapsExistingPlistWhenLaunchdReportsMissing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var launchctlCalls: [[String]] = []
        var printCount = 0
        let interlock = DaemonLifecycleInterlock(send: { request in
            XCTAssertEqual(request.method, "daemon.lifecycle.prepare")
            return ResponseEnvelope(requestID: request.requestID, status: .succeeded)
        })
        let manager = LaunchAgentManager(
            lifecycleInterlock: interlock,
            processRunner: { executable, arguments, _ in
                XCTAssertEqual(executable, "/bin/launchctl")
                launchctlCalls.append(arguments)
                switch arguments.first {
                case "print":
                    printCount += 1
                    if printCount == 1 {
                        return ProcessResult(
                            status: 113,
                            stdout: "",
                            stderr: "Bad request.\nCould not find service \"\(fixture.paths.label)\" in domain for user gui: \(getuid())"
                        )
                    }
                    return ProcessResult(
                        status: 0,
                        stdout: runningLaunchctlOutput(path: fixture.paths.expectedExecutableURL.path),
                        stderr: ""
                    )
                case "bootstrap":
                    return ProcessResult(status: 0, stdout: "", stderr: "")
                default:
                    XCTFail("unexpected launchctl command: \(arguments)")
                    return ProcessResult(status: 1, stdout: "", stderr: "unexpected")
                }
            },
            runtimeVerifier: { expectedProcessID, _ in
                XCTAssertEqual(expectedProcessID, 42)
                return verifiedRuntime(processID: 42)
            },
            paths: fixture.paths,
            verificationTimeout: 0,
            pollInterval: 0
        )

        let report = try manager.ensure()

        XCTAssertEqual(report.action, .bootstrapped)
        XCTAssertTrue(report.repairAttempted)
        XCTAssertTrue(report.verification.verified)
        XCTAssertEqual(launchctlCalls.filter { $0.first == "bootstrap" }.count, 1)
        XCTAssertFalse(launchctlCalls.contains { $0.first == "bootout" })
    }

    func testEnsureDoesNotBootstrapRegisteredJob() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var launchctlCalls: [[String]] = []
        let manager = LaunchAgentManager(
            lifecycleInterlock: DaemonLifecycleInterlock(send: { request in
                XCTFail("registered ensure must not negotiate a lifecycle drain: \(request.method)")
                return ResponseEnvelope(requestID: request.requestID, status: .succeeded)
            }),
            processRunner: { executable, arguments, _ in
                XCTAssertEqual(executable, "/bin/launchctl")
                launchctlCalls.append(arguments)
                return ProcessResult(
                    status: 0,
                    stdout: runningLaunchctlOutput(path: fixture.paths.expectedExecutableURL.path),
                    stderr: ""
                )
            },
            runtimeVerifier: { expectedProcessID, _ in
                XCTAssertEqual(expectedProcessID, 42)
                return verifiedRuntime(processID: 42)
            },
            paths: fixture.paths,
            verificationTimeout: 0,
            pollInterval: 0
        )

        let report = try manager.ensure()

        XCTAssertEqual(report.action, .alreadyRegistered)
        XCTAssertFalse(report.repairAttempted)
        XCTAssertEqual(launchctlCalls.count, 1)
        XCTAssertEqual(launchctlCalls.first?.first, "print")
    }

    func testEnsureDoesNotRepairRegisteredButUnhealthyJob() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var launchctlCalls: [[String]] = []
        let manager = LaunchAgentManager(
            lifecycleInterlock: DaemonLifecycleInterlock(send: { request in
                XCTFail("unhealthy registered ensure must not negotiate a lifecycle drain: \(request.method)")
                return ResponseEnvelope(requestID: request.requestID, status: .succeeded)
            }),
            processRunner: { executable, arguments, _ in
                XCTAssertEqual(executable, "/bin/launchctl")
                launchctlCalls.append(arguments)
                return ProcessResult(
                    status: 0,
                    stdout: """
                    gui/\(getuid())/\(fixture.paths.label) = {
                        program = \(fixture.paths.expectedExecutableURL.path)
                        state = spawn failed
                        last exit code = 78: EX_CONFIG
                    }
                    """,
                    stderr: ""
                )
            },
            runtimeVerifier: { _, _ in
                DaemonRegistrationVerification(
                    installedRuntimeParity: InstalledRuntimeParityStatus(
                        state: "current",
                        message: "test"
                    ),
                    socketExists: true,
                    socketOwnerOnly: true,
                    daemonIdentityMatches: false,
                    verified: false,
                    failureReasons: ["test_failure"]
                )
            },
            paths: fixture.paths,
            verificationTimeout: 0,
            pollInterval: 0
        )

        XCTAssertThrowsError(try manager.ensure()) { error in
            guard case LaunchAgentError.registrationFailed(let message, let details) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("registered"))
            XCTAssertEqual(details["repair_attempted"]?.boolValue, false)
        }
        XCTAssertEqual(launchctlCalls.count, 1)
        XCTAssertFalse(launchctlCalls.contains { $0.first == "bootstrap" })
        XCTAssertFalse(launchctlCalls.contains { $0.first == "bootout" })
    }

    func testEnsureRefusesUnclassifiedLaunchctlFailure() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var launchctlCalls: [[String]] = []
        let manager = LaunchAgentManager(
            lifecycleInterlock: DaemonLifecycleInterlock(send: { request in
                XCTFail("unclassified launchctl failure must not negotiate a lifecycle drain: \(request.method)")
                return ResponseEnvelope(requestID: request.requestID, status: .succeeded)
            }),
            processRunner: { executable, arguments, _ in
                XCTAssertEqual(executable, "/bin/launchctl")
                launchctlCalls.append(arguments)
                return ProcessResult(status: 1, stdout: "", stderr: "launchctl is unavailable")
            },
            runtimeVerifier: { _, _ in
                XCTFail("runtime verification must not run before a safe repair decision")
                return verifiedRuntime(processID: 42)
            },
            paths: fixture.paths,
            verificationTimeout: 0,
            pollInterval: 0
        )

        XCTAssertThrowsError(try manager.ensure()) { error in
            guard case LaunchAgentError.registrationFailed(_, let details) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(details["before_registration_state"]?.stringValue, "unavailable")
        }
        XCTAssertEqual(launchctlCalls.count, 1)
        XCTAssertFalse(launchctlCalls.contains { $0.first == "bootstrap" })
    }

    private func makeFixture() throws -> (root: URL, paths: LaunchAgentPaths) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macctl-launch-agent-\(UUID().uuidString)", isDirectory: true)
        let expectedExecutableURL = root
            .appendingPathComponent("macctld.app/Contents/MacOS/macctld")
        try FileManager.default.createDirectory(
            at: expectedExecutableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: expectedExecutableURL.path, contents: Data("daemon".utf8)))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: expectedExecutableURL.path
        )

        let launchAgentURL = root.appendingPathComponent("LaunchAgent.plist")
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["ProgramArguments": [expectedExecutableURL.path]],
            format: .xml,
            options: 0
        )
        try plistData.write(to: launchAgentURL)
        return (
            root,
            LaunchAgentPaths(
                label: MacCtlPaths.launchAgentLabel,
                launchAgentURL: launchAgentURL,
                expectedExecutableURL: expectedExecutableURL,
                logURL: root.appendingPathComponent("macctld.log")
            )
        )
    }
}

private func runningLaunchctlOutput(path: String) -> String {
    """
    gui/\(getuid())/\(MacCtlPaths.launchAgentLabel) = {
        program = \(path)
        pid = 42
        state = running
        last exit code = 0
    }
    """
}

private func verifiedRuntime(processID: Int32) -> DaemonRegistrationVerification {
    DaemonRegistrationVerification(
        installedRuntimeParity: InstalledRuntimeParityStatus(
            state: "current",
            message: "test",
            sourceRevision: "0123456",
            processID: processID
        ),
        socketExists: true,
        socketOwnerOnly: true,
        daemonProcessID: processID,
        daemonRuntimeContext: "daemon",
        daemonIdentityMatches: true,
        verified: true
    )
}
