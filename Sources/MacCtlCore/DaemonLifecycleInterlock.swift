import Foundation

public enum DaemonLifecycleInterlockMode: String, Codable, Equatable {
    case atomicDrain = "atomic_drain"
    case legacyIdleSnapshot = "legacy_idle_snapshot"
    case unhealthyRecovery = "unhealthy_recovery"
}

public struct DaemonLifecycleInterlockResult: Codable, Equatable {
    public let operation: DaemonLifecycleOperation
    public let mode: DaemonLifecycleInterlockMode

    public init(operation: DaemonLifecycleOperation, mode: DaemonLifecycleInterlockMode) {
        self.operation = operation
        self.mode = mode
    }
}

/// Negotiates an atomic mutation drain with the live daemon before any
/// installed files or launchd state change. The legacy snapshot path exists
/// only to bootstrap the first interlock-capable upgrade; once the installed
/// daemon supports the lifecycle method, every transition uses the atomic path.
public final class DaemonLifecycleInterlock {
    public typealias Sender = (RequestEnvelope) throws -> ResponseEnvelope

    private let send: Sender
    private let allowLegacyIdleSnapshot: Bool

    public init(
        allowLegacyIdleSnapshot: Bool = false,
        send: @escaping Sender = { try UnixSocketClient().send($0) }
    ) {
        self.allowLegacyIdleSnapshot = allowLegacyIdleSnapshot
        self.send = send
    }

    public func prepare(
        operation: DaemonLifecycleOperation,
        launchAgentStatus: LaunchAgentStatus
    ) throws -> DaemonLifecycleInterlockResult {
        let request = RequestEnvelope(
            method: "daemon.lifecycle.prepare",
            params: ["operation": .string(operation.rawValue)]
        )
        let response: ResponseEnvelope
        do {
            response = try send(request)
        } catch {
            guard !launchAgentStatus.healthy else {
                throw LaunchAgentError.lifecycleInterlockUnavailable(error.localizedDescription)
            }
            return DaemonLifecycleInterlockResult(operation: operation, mode: .unhealthyRecovery)
        }

        if response.status == .succeeded {
            return DaemonLifecycleInterlockResult(operation: operation, mode: .atomicDrain)
        }
        if response.error?.code == MacCtlErrorCode.unsupportedMethod.rawValue {
            guard allowLegacyIdleSnapshot else {
                throw LaunchAgentError.lifecycleInterlockUnavailable(
                    "The installed daemon predates atomic lifecycle drains; inspect the control center, clear all authority, then repeat once with --allow-legacy-idle-snapshot"
                )
            }
            return try prepareLegacyUpgrade(operation: operation)
        }
        throw LaunchAgentError.lifecycleBlocked(
            response.error?.message ?? "The daemon declined the lifecycle drain"
        )
    }

    private func prepareLegacyUpgrade(
        operation: DaemonLifecycleOperation
    ) throws -> DaemonLifecycleInterlockResult {
        let response: ResponseEnvelope
        do {
            response = try send(RequestEnvelope(method: "control.center.snapshot"))
        } catch {
            throw LaunchAgentError.lifecycleInterlockUnavailable(error.localizedDescription)
        }
        guard response.status == .succeeded else {
            throw LaunchAgentError.lifecycleInterlockUnavailable(
                response.error?.message ?? "The legacy daemon did not provide an idle snapshot"
            )
        }
        let data = try JSONCodec.encode(response.result)
        let snapshot: ControlCenterSnapshot
        do {
            snapshot = try JSONCodec.decode(ControlCenterSnapshot.self, from: data)
        } catch {
            throw LaunchAgentError.lifecycleInterlockUnavailable(
                "The legacy daemon returned an invalid control-center snapshot"
            )
        }
        guard snapshot.approvals.isEmpty, snapshot.execution == nil else {
            throw LaunchAgentError.lifecycleBlocked(
                "Legacy daemon upgrade blocked by \(snapshot.approvals.count) pending approval(s) or active execution"
            )
        }
        return DaemonLifecycleInterlockResult(operation: operation, mode: .legacyIdleSnapshot)
    }
}
