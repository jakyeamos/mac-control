import CryptoKit
import Foundation

/// A normalized snapshot of one running GUI application. Runtime handles are
/// deliberately excluded so deterministic callers can inject catalogs and so
/// no NSRunningApplication object crosses the daemon boundary.
public struct RunningApplicationDescriptor: Equatable {
    public let name: String
    public let bundleID: String?
    public let path: String
    public let processID: Int32
    public let launchDate: Date?
    public let bundleVersion: String?

    public init(
        name: String,
        bundleID: String?,
        path: String,
        processID: Int32,
        launchDate: Date?,
        bundleVersion: String? = nil
    ) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.processID = processID
        self.launchDate = launchDate
        self.bundleVersion = bundleVersion
    }
}

/// A live, read-only application-instance identity. `instanceRef` is present
/// only when the platform supplied a launch date, preventing a reused PID from
/// silently resolving to a relaunched process.
public struct ApplicationInstanceInfo: Codable, Equatable {
    public let schemaVersion = "macctl-app-instance/v1"
    public let name: String
    public let bundleID: String?
    public let path: String
    public let bundleVersion: String?
    public let processID: Int32
    public let instanceRef: String?

    public init(descriptor: RunningApplicationDescriptor) {
        name = descriptor.name
        bundleID = descriptor.bundleID
        path = descriptor.path
        bundleVersion = descriptor.bundleVersion
        processID = descriptor.processID
        instanceRef = descriptor.launchDate.map { launchDate in
            Self.makeInstanceRef(
                processID: descriptor.processID,
                bundleID: descriptor.bundleID,
                path: descriptor.path,
                launchDate: launchDate
            )
        }
    }

    public init(application: AppInfo, processID: Int32, instanceRef: String? = nil) {
        name = application.name
        bundleID = application.bundleID
        path = application.path
        bundleVersion = application.bundleVersion
        self.processID = processID
        self.instanceRef = instanceRef
    }

    public var application: AppInfo {
        AppInfo(
            name: name,
            bundleID: bundleID,
            path: path,
            isRunning: true,
            processID: processID,
            bundleVersion: bundleVersion
        )
    }

    private static func makeInstanceRef(
        processID: Int32,
        bundleID: String?,
        path: String,
        launchDate: Date
    ) -> String {
        let launchMicroseconds = Int64((launchDate.timeIntervalSince1970 * 1_000_000).rounded())
        let canonical = [
            "macctl-app-instance/v1",
            String(processID),
            bundleID ?? "",
            URL(fileURLWithPath: path).standardizedFileURL.path,
            String(launchMicroseconds)
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case name
        case bundleID = "bundle_id"
        case path
        case bundleVersion = "bundle_version"
        case processID = "process_id"
        case instanceRef = "instance_ref"
    }
}

public struct ApplicationInstanceCatalog: Codable, Equatable {
    public let schemaVersion = "macctl-app-instance-catalog/v1"
    public let application: String
    public let instances: [ApplicationInstanceInfo]

    public init(application: String, instances: [ApplicationInstanceInfo]) {
        self.application = application
        self.instances = instances
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case application, instances
    }
}

/// Supplied fields are conjunctive. A stale or mismatched field never falls
/// back to a broader application-level match.
public struct ApplicationTargetSelector: Codable, Equatable {
    public let application: String
    public let processID: Int32?
    public let instanceRef: String?
    public let windowRef: String?

    public init(
        application: String,
        processID: Int32? = nil,
        instanceRef: String? = nil,
        windowRef: String? = nil
    ) {
        self.application = application
        self.processID = processID
        self.instanceRef = instanceRef
        self.windowRef = windowRef
    }

    public var isInstanceSpecific: Bool {
        processID != nil || instanceRef != nil
    }

    private enum CodingKeys: String, CodingKey {
        case application
        case processID = "process_id"
        case instanceRef = "instance_ref"
        case windowRef = "window_ref"
    }
}

public enum ApplicationTargetResolutionError: Error, LocalizedError, Equatable {
    case targetMissing
    case targetAmbiguous(Int)
    case targetChanged

    public var errorDescription: String? {
        switch self {
        case .targetMissing:
            return "The requested running application instance could not be resolved"
        case .targetAmbiguous(let count):
            return "The application selector matched \(count) running instances; provide a process ID or instance reference"
        case .targetChanged:
            return "The requested application instance changed or restarted"
        }
    }
}
