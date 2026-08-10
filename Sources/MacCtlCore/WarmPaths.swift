import CryptoKit
import Foundation

/// A stable, redacted identity used for route measurements.  A path and
/// bundle identifier identify the installed app; the version invalidates
/// measurements after an app update.
public struct WarmPathApplicationIdentity: Codable, Equatable {
    public let name: String
    public let bundleID: String?
    public let path: String
    public let version: String?

    public init(name: String, bundleID: String?, path: String, version: String? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.version = version
    }

    public init(application: AppInfo) {
        self.init(
            name: application.name,
            bundleID: application.bundleID,
            path: application.path,
            version: application.bundleVersion
        )
    }

    public func matchesInstalledApplication(_ other: WarmPathApplicationIdentity) -> Bool {
        if let bundleID, let otherBundleID = other.bundleID {
            return bundleID == otherBundleID
        }
        return path == other.path
    }

    public var displayName: String {
        bundleID ?? path
    }
}

/// The route names are intentionally data, not a universal precedence ladder.
/// A manifest may declare only the routes measured for one app/task/target.
public enum RouteMeasurementSource: String, Codable, Equatable {
    case daemonExecuted = "daemon_executed"
    case callerSupplied = "caller_supplied"
}

public struct WarmPathContextIdentity: Codable, Equatable {
    public let osVersion: String
    public let providerStateSignature: String
    public let treeSignature: String?

    public init(osVersion: String, providerStateSignature: String, treeSignature: String? = nil) {
        self.osVersion = osVersion
        self.providerStateSignature = providerStateSignature
        self.treeSignature = treeSignature
    }
}

public struct WarmPathTelemetry: Codable, Equatable {
    public let selectionCount: Int
    public let warmHitCount: Int
    public let fallbackCount: Int
    public let staleRouteCount: Int
    public let verificationFailureCount: Int
    public let lastFailureReason: String?

    public init(
        selectionCount: Int = 0,
        warmHitCount: Int = 0,
        fallbackCount: Int = 0,
        staleRouteCount: Int = 0,
        verificationFailureCount: Int = 0,
        lastFailureReason: String? = nil
    ) {
        self.selectionCount = max(0, selectionCount)
        self.warmHitCount = max(0, warmHitCount)
        self.fallbackCount = max(0, fallbackCount)
        self.staleRouteCount = max(0, staleRouteCount)
        self.verificationFailureCount = max(0, verificationFailureCount)
        self.lastFailureReason = lastFailureReason
    }

    public var warmRouteHitRate: Double? {
        guard selectionCount > 0 else { return nil }
        return Double(warmHitCount) / Double(selectionCount)
    }
}

public struct RouteCandidate: Codable, Equatable {
    public static let minimumWarmSamples = 3

    public let route: ControlActionRoute
    public let measurementSource: RouteMeasurementSource
    public let requiredPermissions: [String]
    public let measuredEndToEndLatencyMs: Double?
    public let measuredP50LatencyMs: Double?
    public let measuredP95LatencyMs: Double?
    public let verificationRate: Double?
    public let recoveries: Int
    public let sampleCount: Int
    public let freshUntil: Date?
    public let tabCount: Int
    public let scrollCount: Int
    public let coordinateUse: Bool
    public let userHelpCount: Int
    public let declaredFallbackRoutes: [ControlActionRoute]
    public let telemetry: WarmPathTelemetry

    public init(
        route: ControlActionRoute,
        measurementSource: RouteMeasurementSource = .daemonExecuted,
        requiredPermissions: [String] = [],
        measuredEndToEndLatencyMs: Double? = nil,
        measuredP50LatencyMs: Double? = nil,
        measuredP95LatencyMs: Double? = nil,
        verificationRate: Double? = nil,
        recoveries: Int = 0,
        sampleCount: Int = 0,
        freshUntil: Date? = nil,
        tabCount: Int = 0,
        scrollCount: Int = 0,
        coordinateUse: Bool = false,
        userHelpCount: Int = 0,
        declaredFallbackRoutes: [ControlActionRoute] = [],
        telemetry: WarmPathTelemetry = WarmPathTelemetry()
    ) {
        self.route = route
        self.measurementSource = measurementSource
        self.requiredPermissions = requiredPermissions
        self.measuredEndToEndLatencyMs = measuredEndToEndLatencyMs
        self.measuredP50LatencyMs = measuredP50LatencyMs ?? measuredEndToEndLatencyMs
        self.measuredP95LatencyMs = measuredP95LatencyMs
        self.verificationRate = verificationRate
        self.recoveries = max(0, recoveries)
        self.sampleCount = max(0, sampleCount)
        self.freshUntil = freshUntil
        self.tabCount = max(0, tabCount)
        self.scrollCount = max(0, scrollCount)
        self.coordinateUse = coordinateUse
        self.userHelpCount = max(0, userHelpCount)
        self.declaredFallbackRoutes = declaredFallbackRoutes
        self.telemetry = telemetry
    }

    private enum CodingKeys: String, CodingKey {
        case route
        case measurementSource = "measurement_source"
        case requiredPermissions
        case measuredEndToEndLatencyMs
        case measuredP50LatencyMs
        case measuredP95LatencyMs
        case verificationRate
        case recoveries
        case sampleCount
        case freshUntil
        case tabCount
        case scrollCount
        case coordinateUse
        case userHelpCount
        case declaredFallbackRoutes
        case telemetry
    }

    /// Older manifests are treated as caller-supplied inventory until the
    /// daemon produces a fresh measurement.  This prevents a legacy JSON file
    /// from silently becoming route-selection authority after the provenance
    /// contract is upgraded.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.route = try container.decode(ControlActionRoute.self, forKey: .route)
        self.measurementSource = try container.decodeIfPresent(
            RouteMeasurementSource.self,
            forKey: .measurementSource
        ) ?? .callerSupplied
        self.requiredPermissions = try container.decodeIfPresent([String].self, forKey: .requiredPermissions) ?? []
        self.measuredEndToEndLatencyMs = try container.decodeIfPresent(Double.self, forKey: .measuredEndToEndLatencyMs)
        self.measuredP50LatencyMs = try container.decodeIfPresent(Double.self, forKey: .measuredP50LatencyMs)
            ?? self.measuredEndToEndLatencyMs
        self.measuredP95LatencyMs = try container.decodeIfPresent(Double.self, forKey: .measuredP95LatencyMs)
        self.verificationRate = try container.decodeIfPresent(Double.self, forKey: .verificationRate)
        self.recoveries = max(0, try container.decodeIfPresent(Int.self, forKey: .recoveries) ?? 0)
        self.sampleCount = max(0, try container.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0)
        self.freshUntil = try container.decodeIfPresent(Date.self, forKey: .freshUntil)
        self.tabCount = max(0, try container.decodeIfPresent(Int.self, forKey: .tabCount) ?? 0)
        self.scrollCount = max(0, try container.decodeIfPresent(Int.self, forKey: .scrollCount) ?? 0)
        self.coordinateUse = try container.decodeIfPresent(Bool.self, forKey: .coordinateUse) ?? false
        self.userHelpCount = max(0, try container.decodeIfPresent(Int.self, forKey: .userHelpCount) ?? 0)
        self.declaredFallbackRoutes = try container.decodeIfPresent(
            [ControlActionRoute].self,
            forKey: .declaredFallbackRoutes
        ) ?? []
        self.telemetry = try container.decodeIfPresent(WarmPathTelemetry.self, forKey: .telemetry)
            ?? WarmPathTelemetry()
    }

    fileprivate var hasCompleteMeasurement: Bool {
        sampleCount > 0
            && measuredEndToEndLatencyMs.map({ $0.isFinite && $0 >= 0 }) == true
            && measuredP95LatencyMs.map({ $0.isFinite && $0 >= 0 }) == true
            && verificationRate != nil
    }

    public var isMeasured: Bool {
        measurementSource == .daemonExecuted && hasCompleteMeasurement
    }

    public func isWarm(at date: Date) -> Bool {
        isMeasured && sampleCount >= Self.minimumWarmSamples && verificationRate == 1 && isFresh(at: date)
    }

    public func isFresh(at date: Date) -> Bool {
        guard let freshUntil else { return false }
        return freshUntil > date
    }
}

public struct WarmPathManifest: Codable, Equatable {
    public let schemaVersion: Int
    public let application: WarmPathApplicationIdentity
    public let taskID: String
    public let targetFingerprint: String
    public let verificationOracle: String
    public let visualCoordinateOptIn: Bool
    public let contextIdentity: WarmPathContextIdentity?
    public let candidates: [RouteCandidate]
    public let updatedAt: Date

    public init(
        schemaVersion: Int = 2,
        application: WarmPathApplicationIdentity,
        taskID: String,
        targetFingerprint: String,
        verificationOracle: String,
        visualCoordinateOptIn: Bool = false,
        contextIdentity: WarmPathContextIdentity? = nil,
        candidates: [RouteCandidate],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.application = application
        self.taskID = taskID
        self.targetFingerprint = targetFingerprint
        self.verificationOracle = verificationOracle
        self.visualCoordinateOptIn = visualCoordinateOptIn
        self.contextIdentity = contextIdentity
        self.candidates = candidates
        self.updatedAt = updatedAt
    }
}

public struct WarmPathSelectionContext {
    public let application: WarmPathApplicationIdentity
    public let targetFingerprint: String
    public let grantedPermissions: Set<String>
    public let targetIsUnique: Bool
    public let verificationAvailable: Bool
    public let contextIdentity: WarmPathContextIdentity?
    public let requireContextIdentity: Bool
    public let now: Date

    public init(
        application: WarmPathApplicationIdentity,
        targetFingerprint: String,
        grantedPermissions: Set<String> = [],
        targetIsUnique: Bool = true,
        verificationAvailable: Bool = true,
        contextIdentity: WarmPathContextIdentity? = nil,
        requireContextIdentity: Bool = false,
        now: Date = Date()
    ) {
        self.application = application
        self.targetFingerprint = targetFingerprint
        self.grantedPermissions = Set(grantedPermissions.map(Self.normalizePermission))
        self.targetIsUnique = targetIsUnique
        self.verificationAvailable = verificationAvailable
        self.contextIdentity = contextIdentity
        self.requireContextIdentity = requireContextIdentity
        self.now = now
    }

    private static func normalizePermission(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public struct RouteCandidateAssessment: Codable, Equatable {
    public let candidate: RouteCandidate
    public let eligible: Bool
    public let reasons: [String]

    public init(candidate: RouteCandidate, eligible: Bool, reasons: [String]) {
        self.candidate = candidate
        self.eligible = eligible
        self.reasons = reasons
    }
}

public struct RouteSelectionReport: Codable, Equatable {
    public let application: WarmPathApplicationIdentity
    public let taskID: String
    public let targetFingerprint: String
    public let verificationOracle: String?
    public let selectedRoute: ControlActionRoute?
    public let fallbackChain: [ControlActionRoute]
    public let assessments: [RouteCandidateAssessment]
    public let reason: String

    public init(
        application: WarmPathApplicationIdentity,
        taskID: String,
        targetFingerprint: String,
        verificationOracle: String?,
        selectedRoute: ControlActionRoute?,
        fallbackChain: [ControlActionRoute] = [],
        assessments: [RouteCandidateAssessment],
        reason: String
    ) {
        self.application = application
        self.taskID = taskID
        self.targetFingerprint = targetFingerprint
        self.verificationOracle = verificationOracle
        self.selectedRoute = selectedRoute
        self.fallbackChain = fallbackChain
        self.assessments = assessments
        self.reason = reason
    }

    public var isUsable: Bool { selectedRoute != nil }
}

public enum WarmPathSelection {
    /// Selects only measured, fresh, permission-compatible routes.  This is a
    /// pure function so route choice can be tested without touching an app.
    public static func select(
        manifest: WarmPathManifest,
        context: WarmPathSelectionContext
    ) -> RouteSelectionReport {
        var globalReasons: [String] = []
        if manifest.taskID.isEmpty || context.targetFingerprint.isEmpty {
            globalReasons.append("task and target fingerprint are required")
        }
        if !manifest.application.matchesInstalledApplication(context.application) {
            globalReasons.append("application identity changed")
        } else if manifest.application.version != context.application.version {
            globalReasons.append("application version changed; rebenchmark required")
        }
        if manifest.targetFingerprint != context.targetFingerprint {
            globalReasons.append("target fingerprint changed")
        }
        if manifest.verificationOracle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !context.verificationAvailable {
            globalReasons.append("verification oracle is unavailable")
        }
        if !context.targetIsUnique {
            globalReasons.append("target is ambiguous")
        }
        if context.requireContextIdentity {
            guard let manifestContext = manifest.contextIdentity,
                  let liveContext = context.contextIdentity else {
                globalReasons.append("route context identity is unavailable; rebenchmark required")
                return selectionReport(
                    manifest: manifest,
                    context: context,
                    globalReasons: globalReasons
                )
            }
            if manifestContext.osVersion != liveContext.osVersion {
                globalReasons.append("OS version changed; rebenchmark required")
            }
            if manifestContext.providerStateSignature != liveContext.providerStateSignature {
                globalReasons.append("provider state changed; rebenchmark required")
            }
            if let expectedTree = manifestContext.treeSignature {
                guard let liveTree = liveContext.treeSignature else {
                    globalReasons.append("tree signature is unavailable; deep audit required")
                    return selectionReport(
                        manifest: manifest,
                        context: context,
                        globalReasons: globalReasons
                    )
                }
                if expectedTree != liveTree {
                    globalReasons.append("tree signature changed; rebenchmark required")
                }
            }
        }

        return selectionReport(manifest: manifest, context: context, globalReasons: globalReasons)
    }

    private static func selectionReport(
        manifest: WarmPathManifest,
        context: WarmPathSelectionContext,
        globalReasons: [String]
    ) -> RouteSelectionReport {

        let assessments = manifest.candidates.map { candidate in
            var reasons = globalReasons
            if !candidate.hasCompleteMeasurement {
                reasons.append("unmeasured")
            } else if candidate.measurementSource != .daemonExecuted {
                reasons.append("caller-supplied measurement is not eligible; daemon benchmark required")
            } else if candidate.sampleCount < RouteCandidate.minimumWarmSamples {
                reasons.append("insufficient successful evidence; at least \(RouteCandidate.minimumWarmSamples) verified samples are required")
            } else if !candidate.isFresh(at: context.now) {
                reasons.append("stale")
            }
            if let verificationRate = candidate.verificationRate,
               verificationRate < 1.0 {
                reasons.append("verification rate is below 100%")
            }
            let missingPermissions = candidate.requiredPermissions.filter {
                !context.grantedPermissions.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            if !missingPermissions.isEmpty {
                reasons.append("missing permissions: \(missingPermissions.joined(separator: ", "))")
            }
            if isVisualOrCoordinate(candidate.route), !manifest.visualCoordinateOptIn {
                reasons.append("visual or coordinate route is not registered for this task")
            }
            let eligible = reasons.isEmpty
            return RouteCandidateAssessment(candidate: candidate, eligible: eligible, reasons: reasons)
        }

        let eligible = assessments.filter { $0.eligible }.sorted { lhs, rhs in
            let left = lhs.candidate
            let right = rhs.candidate
            let leftP50 = left.measuredP50LatencyMs
                ?? left.measuredEndToEndLatencyMs
                ?? .greatestFiniteMagnitude
            let rightP50 = right.measuredP50LatencyMs
                ?? right.measuredEndToEndLatencyMs
                ?? .greatestFiniteMagnitude
            if leftP50 != rightP50 { return leftP50 < rightP50 }
            if left.measuredP95LatencyMs != right.measuredP95LatencyMs {
                return (left.measuredP95LatencyMs ?? .greatestFiniteMagnitude)
                    < (right.measuredP95LatencyMs ?? .greatestFiniteMagnitude)
            }
            if left.recoveries != right.recoveries { return left.recoveries < right.recoveries }
            return left.route.rawValue < right.route.rawValue
        }
        let selected = eligible.first?.candidate
        let eligibleRoutes = Set(eligible.map { $0.candidate.route })
        let fallbackChain = selected?.declaredFallbackRoutes.filter { eligibleRoutes.contains($0) } ?? []
        let reason: String
        if selected != nil {
            reason = "selected measured fresh route by p50 latency, p95 latency, and recovery count"
                + (fallbackChain.isEmpty ? "" : "; only declared pre-action fallbacks are eligible")
        } else {
            let unproven = assessments.filter {
                $0.reasons.contains("unmeasured")
                    || $0.reasons.contains("stale")
                    || $0.reasons.contains("caller-supplied measurement is not eligible; daemon benchmark required")
                    || $0.reasons.contains { $0.hasPrefix("insufficient successful evidence") }
                    || $0.reasons.contains { $0.contains("rebenchmark required") }
            }
            reason = unproven.isEmpty
                ? "no eligible route"
                : "no eligible route; unmeasured or stale candidates require rebenchmarking"
        }
        return RouteSelectionReport(
            application: context.application,
            taskID: manifest.taskID,
            targetFingerprint: context.targetFingerprint,
            verificationOracle: manifest.verificationOracle.isEmpty ? nil : manifest.verificationOracle,
            selectedRoute: selected?.route,
            fallbackChain: fallbackChain,
            assessments: assessments,
            reason: reason
        )
    }

    private static func isVisualOrCoordinate(_ route: ControlActionRoute) -> Bool {
        switch route {
        case .visual, .normalizedCoordinate, .rawCoordinate:
            return true
        case .accessibility, .keyboard, .scroll:
            return false
        }
    }
}

public enum WarmPathStoreError: Error, LocalizedError, Equatable {
    case invalidManifest(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let message): return "Invalid warm-path manifest: \(message)"
        case .writeFailed(let message): return "Could not persist warm-path manifest: \(message)"
        }
    }
}

public enum WarmPathSelectionError: Error, LocalizedError, Equatable {
    case taskRequired
    case targetFingerprintRequired
    case manifestNotFound
    case noEligibleRoute

    public var errorDescription: String? {
        switch self {
        case .taskRequired: return "A warm-path route selection requires a task identifier"
        case .targetFingerprintRequired: return "A warm-path route selection requires a target fingerprint"
        case .manifestNotFound: return "No measured warm-path manifest exists for this app, task, and target"
        case .noEligibleRoute: return "No fresh, measured, permission-compatible route is eligible; rebenchmark before driving"
        }
    }
}

public struct WarmPathStoreStatus: Codable, Equatable {
    public let directory: String
    public let directoryOwnerOnly: Bool
    public let filesOwnerOnly: Bool

    public init(directory: String, directoryOwnerOnly: Bool, filesOwnerOnly: Bool) {
        self.directory = directory
        self.directoryOwnerOnly = directoryOwnerOnly
        self.filesOwnerOnly = filesOwnerOnly
    }
}

public final class WarmPathStore {
    public static let defaultFreshness: TimeInterval = 7 * 24 * 60 * 60
    public static let defaultCapacity = 128

    private let fileManager: FileManager
    private let now: () -> Date
    private let capacity: Int
    public let directory: URL

    public init(
        directory: URL = MacCtlPaths.warmPathsDirectory,
        fileManager: FileManager = .default,
        capacity: Int = WarmPathStore.defaultCapacity,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.capacity = max(1, capacity)
        self.now = now
    }

    public func list() -> [WarmPathManifest] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONCodec.decode(WarmPathManifest.self, from: data)
            }
            .sorted { lhs, rhs in
                if lhs.application.displayName != rhs.application.displayName {
                    return lhs.application.displayName < rhs.application.displayName
                }
                if lhs.taskID != rhs.taskID { return lhs.taskID < rhs.taskID }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    public func status() -> WarmPathStoreStatus {
        let directoryPermissions: NSNumber? = {
            guard let attributes = try? fileManager.attributesOfItem(atPath: directory.path) else {
                return nil
            }
            return attributes[.posixPermissions] as? NSNumber
        }()
        let fileURLs = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let filesOwnerOnly = fileURLs
            .filter { $0.pathExtension == "json" }
            .allSatisfy { url in
                guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                      let permissions = attributes[.posixPermissions] as? NSNumber else {
                    return false
                }
                return permissions.intValue & 0o077 == 0
            }
        return WarmPathStoreStatus(
            directory: directory.path,
            directoryOwnerOnly: directoryPermissions.map { $0.intValue & 0o077 == 0 } ?? false,
            filesOwnerOnly: directoryPermissions != nil && filesOwnerOnly
        )
    }

    public func inspect(
        application: AppInfo,
        taskID: String,
        targetFingerprint: String? = nil
    ) -> WarmPathManifest? {
        let identity = WarmPathApplicationIdentity(application: application)
        return list()
            .filter {
                $0.taskID == taskID
                    && $0.application.matchesInstalledApplication(identity)
                    && (targetFingerprint == nil || $0.targetFingerprint == targetFingerprint)
            }
            .sorted { lhs, rhs in
                let lhsExact = lhs.application.version == identity.version
                let rhsExact = rhs.application.version == identity.version
                if lhsExact != rhsExact { return lhsExact }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
    }

    @discardableResult
    public func save(_ manifest: WarmPathManifest) throws -> WarmPathManifest {
        guard (1...2).contains(manifest.schemaVersion) else {
            throw WarmPathStoreError.invalidManifest("unsupported schema version")
        }
        guard !manifest.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.targetFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WarmPathStoreError.invalidManifest("task_id and target_fingerprint are required")
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONCodec.encode(manifest)
            let url = directory.appendingPathComponent(Self.filename(for: manifest))
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try enforceCapacity()
            return manifest
        } catch {
            throw WarmPathStoreError.writeFailed(error.localizedDescription)
        }
    }

    @discardableResult
    public func recordBenchmark(
        application: AppInfo,
        taskID: String,
        targetFingerprint: String,
        verificationOracle: String,
        route: ControlActionRoute,
        requiredPermissions: [String] = [],
        latencyMs: Double,
        p50LatencyMs: Double? = nil,
        p95LatencyMs: Double,
        verificationRate: Double,
        recoveries: Int = 0,
        samples: Int = 1,
        freshness: TimeInterval = WarmPathStore.defaultFreshness,
        tabCount: Int = 0,
        scrollCount: Int = 0,
        coordinateUse: Bool = false,
        userHelpCount: Int = 0,
        visualCoordinateOptIn: Bool = false,
        declaredFallbackRoutes: [ControlActionRoute] = [],
        measurementSource: RouteMeasurementSource = .daemonExecuted,
        contextIdentity: WarmPathContextIdentity? = nil
    ) throws -> WarmPathManifest {
        guard latencyMs.isFinite, latencyMs >= 0,
              p95LatencyMs.isFinite, p95LatencyMs >= 0,
              (0...1).contains(verificationRate), samples > 0,
              freshness > 0 else {
            throw WarmPathStoreError.invalidManifest("benchmark metrics are outside supported bounds")
        }
        let existing = inspect(application: application, taskID: taskID, targetFingerprint: targetFingerprint)
            .flatMap { manifest in
                manifest.application.version == application.bundleVersion ? manifest : nil
            }
        var candidates = existing?.candidates ?? []
        let candidate = RouteCandidate(
            route: route,
            measurementSource: measurementSource,
            requiredPermissions: requiredPermissions,
            measuredEndToEndLatencyMs: latencyMs,
            measuredP50LatencyMs: p50LatencyMs ?? latencyMs,
            measuredP95LatencyMs: p95LatencyMs,
            verificationRate: verificationRate,
            recoveries: recoveries,
            sampleCount: samples,
            freshUntil: now().addingTimeInterval(freshness),
            tabCount: tabCount,
            scrollCount: scrollCount,
            coordinateUse: coordinateUse,
            userHelpCount: userHelpCount,
            declaredFallbackRoutes: declaredFallbackRoutes,
            telemetry: candidates.first(where: { $0.route == route })?.telemetry ?? WarmPathTelemetry()
        )
        candidates.removeAll { $0.route == route }
        candidates.append(candidate)
        return try save(WarmPathManifest(
            application: WarmPathApplicationIdentity(application: application),
            taskID: taskID,
            targetFingerprint: targetFingerprint,
            verificationOracle: verificationOracle,
            visualCoordinateOptIn: visualCoordinateOptIn || (existing?.visualCoordinateOptIn ?? false),
            contextIdentity: contextIdentity,
            candidates: candidates,
            updatedAt: now()
        ))
    }

    /// Records route health and atomically expires a failed route. This cache
    /// update remains advisory: failure to persist it must not change the
    /// already-observed action result.
    @discardableResult
    public func recordOutcome(
        application: AppInfo,
        taskID: String,
        targetFingerprint: String,
        route: ControlActionRoute,
        warmRouteHit: Bool,
        fallbackUsed: Bool,
        verified: Bool,
        failureReason: String? = nil
    ) throws -> WarmPathManifest? {
        guard let existing = inspect(
            application: application,
            taskID: taskID,
            targetFingerprint: targetFingerprint
        ), existing.application.version == application.bundleVersion,
              let index = existing.candidates.firstIndex(where: { $0.route == route }) else {
            return nil
        }
        var candidates = existing.candidates
        let candidate = candidates[index]
        let staleFailure = !verified && failureReason == "stale_element"
        let telemetry = WarmPathTelemetry(
            selectionCount: candidate.telemetry.selectionCount + 1,
            warmHitCount: candidate.telemetry.warmHitCount + (warmRouteHit ? 1 : 0),
            fallbackCount: candidate.telemetry.fallbackCount + (fallbackUsed ? 1 : 0),
            staleRouteCount: candidate.telemetry.staleRouteCount + (staleFailure ? 1 : 0),
            verificationFailureCount: candidate.telemetry.verificationFailureCount + (verified ? 0 : 1),
            lastFailureReason: verified ? candidate.telemetry.lastFailureReason : failureReason
        )
        candidates[index] = RouteCandidate(
            route: candidate.route,
            measurementSource: candidate.measurementSource,
            requiredPermissions: candidate.requiredPermissions,
            measuredEndToEndLatencyMs: candidate.measuredEndToEndLatencyMs,
            measuredP50LatencyMs: candidate.measuredP50LatencyMs,
            measuredP95LatencyMs: candidate.measuredP95LatencyMs,
            verificationRate: candidate.verificationRate,
            recoveries: candidate.recoveries,
            sampleCount: candidate.sampleCount,
            freshUntil: verified ? candidate.freshUntil : now(),
            tabCount: candidate.tabCount,
            scrollCount: candidate.scrollCount,
            coordinateUse: candidate.coordinateUse,
            userHelpCount: candidate.userHelpCount,
            declaredFallbackRoutes: candidate.declaredFallbackRoutes,
            telemetry: telemetry
        )
        return try save(WarmPathManifest(
            application: existing.application,
            taskID: existing.taskID,
            targetFingerprint: existing.targetFingerprint,
            verificationOracle: existing.verificationOracle,
            visualCoordinateOptIn: existing.visualCoordinateOptIn,
            contextIdentity: existing.contextIdentity,
            candidates: candidates,
            updatedAt: now()
        ))
    }

    private func enforceCapacity() throws {
        let excess = list().sorted { $0.updatedAt > $1.updatedAt }.dropFirst(capacity)
        for manifest in excess {
            try fileManager.removeItem(at: directory.appendingPathComponent(Self.filename(for: manifest)))
        }
    }

    private static func filename(for manifest: WarmPathManifest) -> String {
        let identity = "\(manifest.application.bundleID ?? manifest.application.path)|\(manifest.application.version ?? "")|\(manifest.taskID)|\(manifest.targetFingerprint)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(digest).json"
    }
}
