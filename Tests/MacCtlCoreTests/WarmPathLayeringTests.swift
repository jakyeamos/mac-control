import Foundation
import XCTest
@testable import MacCtlCore

final class WarmPathLayeringTests: XCTestCase {
    func testRegistryLayersArchetypeAndAppOverlayDeclaratively() {
        let registry = AppControlProfileRegistry.standard
        let chrome = WarmPathApplicationIdentity(
            name: "Google Chrome",
            bundleID: "com.google.Chrome",
            path: "/Applications/Google Chrome.app"
        )
        let mail = WarmPathApplicationIdentity(
            name: "Mail",
            bundleID: "com.apple.mail",
            path: "/System/Applications/Mail.app"
        )
        let mirroring = WarmPathApplicationIdentity(
            name: "iPhone Mirroring",
            bundleID: "com.apple.ScreenContinuity",
            path: "/System/Library/CoreServices/iPhone Mirroring.app"
        )

        let chromeProfile = registry.profile(for: chrome)
        XCTAssertEqual(chromeProfile.archetype, .browser)
        XCTAssertEqual(chromeProfile.layers, ["archetype:browser", "app:google_chrome"])
        XCTAssertEqual(chromeProfile.preferredProviders(for: "scroll").first, .browserDOM)
        XCTAssertEqual(chromeProfile.unsupportedCapabilities, ["chrome_tab_group_mutation"])

        let mailProfile = registry.profile(for: mail)
        XCTAssertEqual(mailProfile.archetype, .nativeAppKit)
        XCTAssertTrue(mailProfile.anchors.contains("AXTable"))
        XCTAssertTrue(mailProfile.verification.contains("row_count_change"))

        let removedMirroringProfile = registry.profile(for: mirroring)
        XCTAssertEqual(removedMirroringProfile.archetype, .unknown)
        XCTAssertEqual(removedMirroringProfile.preferredProviders, [.accessibility, .computerUse])
        XCTAssertEqual(removedMirroringProfile.verification, ["focused_window"])
        XCTAssertFalse(removedMirroringProfile.layers.contains { $0.contains("mirroring") })
    }

    func testWarmSelectionRequiresRepeatedEvidenceAndMatchingContext() {
        let now = Date(timeIntervalSince1970: 10_000)
        let application = identity(version: "1")
        let context = WarmPathContextIdentity(
            osVersion: "macOS 26.0",
            providerStateSignature: "providers-v1",
            treeSignature: "tree-v1"
        )
        let underSampled = WarmPathManifest(
            application: application,
            taskID: "activate-save",
            targetFingerprint: "save-v1",
            verificationOracle: "saved",
            contextIdentity: context,
            candidates: [candidate(samples: 2, freshUntil: now.addingTimeInterval(60))],
            updatedAt: now
        )

        let underSampledReport = WarmPathSelection.select(
            manifest: underSampled,
            context: WarmPathSelectionContext(
                application: application,
                targetFingerprint: "save-v1",
                grantedPermissions: ["Accessibility"],
                contextIdentity: context,
                requireContextIdentity: true,
                now: now
            )
        )
        XCTAssertNil(underSampledReport.selectedRoute)
        XCTAssertTrue(underSampledReport.assessments[0].reasons.contains {
            $0.contains("insufficient successful evidence")
        })

        let promoted = WarmPathManifest(
            application: application,
            taskID: "activate-save",
            targetFingerprint: "save-v1",
            verificationOracle: "saved",
            contextIdentity: context,
            candidates: [candidate(samples: 3, freshUntil: now.addingTimeInterval(60))],
            updatedAt: now
        )
        let changedContextReport = WarmPathSelection.select(
            manifest: promoted,
            context: WarmPathSelectionContext(
                application: application,
                targetFingerprint: "save-v1",
                grantedPermissions: ["Accessibility"],
                contextIdentity: WarmPathContextIdentity(
                    osVersion: "macOS 26.1",
                    providerStateSignature: "providers-v1",
                    treeSignature: "tree-v1"
                ),
                requireContextIdentity: true,
                now: now
            )
        )
        XCTAssertNil(changedContextReport.selectedRoute)
        XCTAssertTrue(changedContextReport.assessments[0].reasons.contains("OS version changed; rebenchmark required"))
    }

    func testFailedOutcomeExpiresRouteAndTracksTelemetry() throws {
        let directory = temporaryDirectory("outcome")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 20_000)
        let store = WarmPathStore(directory: directory, now: { now })
        let application = app(version: "1")
        _ = try store.recordBenchmark(
            application: application,
            taskID: "activate-save",
            targetFingerprint: "save-v1",
            verificationOracle: "saved",
            route: .accessibility,
            requiredPermissions: ["Accessibility"],
            latencyMs: 12,
            p50LatencyMs: 11,
            p95LatencyMs: 18,
            verificationRate: 1,
            samples: 3,
            contextIdentity: WarmPathContextIdentity(
                osVersion: "macOS 26.0",
                providerStateSignature: "providers-v1",
                treeSignature: "tree-v1"
            )
        )

        let updated = try XCTUnwrap(try store.recordOutcome(
            application: application,
            taskID: "activate-save",
            targetFingerprint: "save-v1",
            route: .accessibility,
            warmRouteHit: true,
            fallbackUsed: false,
            verified: false,
            failureReason: "stale_element"
        ))
        let candidate = try XCTUnwrap(updated.candidates.first)
        XCTAssertFalse(candidate.isFresh(at: now))
        XCTAssertEqual(candidate.telemetry.selectionCount, 1)
        XCTAssertEqual(candidate.telemetry.warmHitCount, 1)
        XCTAssertEqual(candidate.telemetry.staleRouteCount, 1)
        XCTAssertEqual(candidate.telemetry.verificationFailureCount, 1)
        XCTAssertEqual(candidate.measuredP50LatencyMs, 11)
    }

    func testWarmSelectionRanksByP50ThenP95() {
        let now = Date(timeIntervalSince1970: 25_000)
        let application = identity(version: "1")
        let manifest = WarmPathManifest(
            application: application,
            taskID: "activate-save",
            targetFingerprint: "save-v1",
            verificationOracle: "saved",
            candidates: [
                RouteCandidate(
                    route: .accessibility,
                    measuredEndToEndLatencyMs: 8,
                    measuredP50LatencyMs: 7,
                    measuredP95LatencyMs: 12,
                    verificationRate: 1,
                    sampleCount: 3,
                    freshUntil: now.addingTimeInterval(60)
                ),
                RouteCandidate(
                    route: .keyboard,
                    measuredEndToEndLatencyMs: 6,
                    measuredP50LatencyMs: 5,
                    measuredP95LatencyMs: 20,
                    verificationRate: 1,
                    sampleCount: 3,
                    freshUntil: now.addingTimeInterval(60)
                )
            ],
            updatedAt: now
        )

        let report = WarmPathSelection.select(
            manifest: manifest,
            context: WarmPathSelectionContext(
                application: application,
                targetFingerprint: "save-v1",
                now: now
            )
        )

        XCTAssertEqual(report.selectedRoute, .keyboard)
        XCTAssertTrue(report.reason.contains("p50 latency"))
    }

    func testWarmPathStoreEvictsOldestManifestAtCapacity() throws {
        let directory = temporaryDirectory("capacity")
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSince1970: 30_000)
        let store = WarmPathStore(directory: directory, capacity: 2, now: { now })

        for index in 1...3 {
            let application = app(version: "\(index)")
            _ = try store.recordBenchmark(
                application: application,
                taskID: "task-\(index)",
                targetFingerprint: "target-\(index)",
                verificationOracle: "verified",
                route: .accessibility,
                latencyMs: Double(index),
                p95LatencyMs: Double(index),
                verificationRate: 1,
                samples: 3
            )
            now = now.addingTimeInterval(1)
        }

        let manifests = store.list()
        XCTAssertEqual(manifests.count, 2)
        XCTAssertEqual(Set(manifests.map(\.taskID)), ["task-2", "task-3"])
    }

    private func identity(version: String) -> WarmPathApplicationIdentity {
        WarmPathApplicationIdentity(
            name: "Example",
            bundleID: "com.example.app",
            path: "/Applications/Example.app",
            version: version
        )
    }

    private func app(version: String) -> AppInfo {
        AppInfo(
            name: "Example",
            bundleID: "com.example.app",
            path: "/Applications/Example.app",
            isRunning: true,
            processID: 42,
            bundleVersion: version
        )
    }

    private func candidate(samples: Int, freshUntil: Date) -> RouteCandidate {
        RouteCandidate(
            route: .accessibility,
            requiredPermissions: ["Accessibility"],
            measuredEndToEndLatencyMs: 12,
            measuredP50LatencyMs: 11,
            measuredP95LatencyMs: 18,
            verificationRate: 1,
            sampleCount: samples,
            freshUntil: freshUntil
        )
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        URL(fileURLWithPath: "/private/tmp/macctl-warm-layer-\(suffix)-\(UUID().uuidString)")
    }
}
