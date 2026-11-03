import Foundation

enum AdapterDiscoveryError: Error, LocalizedError {
    case invalidScope

    var errorDescription: String? {
        "Discovery accepts adapter_id and operation filters. Operation requires adapter_id; fixture_id and max_age_seconds require the exact vscode diagnostics.summary scope and a fixture_id."
    }
}

/// A bounded, read-only projection of the registry and current fixture state.
/// Availability is advisory; execution always repeats the underlying checks.
enum AdapterDiscovery {
    static func inspect(
        parameters: [String: JSONValue], registry: AppAdapterRegistry,
        reader: VSCodeDiagnosticsReading, appController: AppController
    ) throws -> [String: JSONValue] {
        guard Set(parameters.keys).isSubset(of: VSCodeDiagnosticsOperation.parameterKeys) else {
            throw AdapterDiscoveryError.invalidScope
        }
        func filter(_ key: String) throws -> String? {
            guard let value = parameters[key] else { return nil }
            guard let string = value.stringValue, !string.isEmpty else { throw AdapterDiscoveryError.invalidScope }
            return string
        }
        let adapterID = try filter("adapter_id")
        let operationName = try filter("operation")
        guard operationName == nil || adapterID != nil else { throw AdapterDiscoveryError.invalidScope }
        let hasContext = parameters["fixture_id"] != nil || parameters["max_age_seconds"] != nil
        if hasContext {
            guard adapterID == "vscode", operationName == "diagnostics.summary", parameters["fixture_id"] != nil else {
                throw AdapterDiscoveryError.invalidScope
            }
            _ = try VSCodeDiagnosticsOperation.Input(parameters: parameters)
        }
        var manifests = registry.manifests()
        if let adapterID {
            guard let manifest = registry.manifest(adapterID: adapterID) else {
                throw AppAdapterError.unsupportedAdapter(adapterID)
            }
            manifests = [manifest]
        }
        if let adapterID, let operationName {
            let operation = try registry.operation(adapterID: adapterID, name: operationName)
            manifests = manifests.map {
                AppAdapterManifest(adapterID: $0.adapterID, displayName: $0.displayName,
                                   supportedBundleIdentifiers: $0.supportedBundleIdentifiers, operations: [operation])
            }
        }
        var availability: [JSONValue] = []
        for manifest in manifests {
            for operation in manifest.operations {
                var entry: [String: JSONValue] = [
                    "adapter_id": .string(manifest.adapterID), "operation": .string(operation.name),
                    "state": .string(operation.contract == nil ? "unverified" : "declared"),
                    "reason": .string(operation.contract == nil ? "invocation_contract_unavailable" : "fixture_required")
                ]
                if hasContext {
                    entry["checked_at"] = .string(Date().ISO8601Format())
                    entry["invalidates_on"] = .array([
                        .string("fixture_or_process_identity_changes"),
                        .string("snapshot_changes_or_exceeds_max_age_seconds")
                    ])
                    do {
                        _ = try VSCodeDiagnosticsOperation.read(parameters: parameters, reader: reader, appController: appController)
                        entry["state"] = .string("available")
                        entry["reason"] = .string("fresh_exact_fixture")
                    } catch let error as VSCodeDiagnosticsError {
                        entry["state"] = .string("blocked")
                        entry["reason"] = .string(error.rawValue)
                        entry["message"] = .string(error.localizedDescription)
                    } catch {
                        entry["state"] = .string("blocked")
                        entry["reason"] = .string("fixture_probe_failed")
                        entry["message"] = .string("Fixture inspection failed; retry after checking fixture status.")
                    }
                }
                availability.append(.object(entry))
            }
        }
        let requiresAutomation = manifests.contains { $0.operations.contains { $0.requiredPermissions.contains("Automation") } }
        return [
            "schema_version": .string("adapter-capabilities/v2"),
            "manifests": try JSONValue.fromEncodable(manifests),
            "automation_permissions": try JSONValue.fromEncodable(requiresAutomation ? registry.automationPermissions() : []),
            "availability": .array(availability),
            "authority": .string("discovery_only; execution revalidates identity, freshness, and redaction")
        ]
    }
}
