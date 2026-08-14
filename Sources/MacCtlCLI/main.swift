import Foundation
import MacCtlCore

struct CLI {
    private let arguments: [String]
    private let jsonOutput: Bool
    private let localService = MacCtlService(permissionContext: "client")

    init(arguments: [String]) {
        self.arguments = arguments
        self.jsonOutput = arguments.contains("--json")
    }

    func run() -> Int32 {
        let filtered = arguments.filter { $0 != "--json" }
        guard let command = filtered.first else {
            printHelp()
            return 0
        }
        let commandArguments = Array(filtered.dropFirst())
        do {
            switch command {
            case "version", "--version", "-V":
                return renderVersion()
            case "doctor", "status":
                return render(sendOrLocal(method: command, params: [:], localFallback: false))
            case "capabilities":
                return render(sendOrLocal(method: command, params: [:], localFallback: true))
            case "app":
                return try runApp(commandArguments)
            case "action":
                return try runAction(commandArguments)
            case "window":
                return try runWindow(commandArguments)
            case "workflow":
                return try runWorkflow(commandArguments)
            case "approval":
                return try runApproval(commandArguments)
            case "receipts":
                return try runReceipts(commandArguments)
            case "release":
                return try runRelease(commandArguments)
            case "route":
                return try runRoute(commandArguments)
            case "accessibility":
                return try runAccessibility(commandArguments)
            case "ideal-state":
                return try runIdealState(commandArguments)
            case "logs":
                return render(sendOrLocal(method: "logs", params: [:], localFallback: true))
            case "keyboard":
                return try runKeyboard(commandArguments)
        case "control":
            return try runControl(commandArguments)
            case "shortcut":
                return try runShortcut(commandArguments)
            case "task":
                return try runTask(commandArguments)
            case "adapter":
                return try runAdapter(commandArguments)
            case "daemon":
                return try runDaemon(commandArguments)
            case "install":
                return try runInstall(commandArguments)
            case "help", "--help", "-h":
                printHelp()
                return 0
            default:
                throw CLIError.usage("Unknown command: \(command)")
            }
        } catch {
            let lifecycleFailure: Bool
            switch error {
            case LaunchAgentError.lifecycleBlocked, LaunchAgentError.lifecycleInterlockUnavailable:
                lifecycleFailure = true
            default:
                lifecycleFailure = false
            }
            let response = ResponseEnvelope(
                requestID: UUID().uuidString,
                status: lifecycleFailure ? .blocked : .failed,
                error: MacCtlError(
                    code: lifecycleFailure
                        ? MacCtlErrorCode.daemonLifecycleBlocked.rawValue
                        : "cli_error",
                    message: error.localizedDescription
                )
            )
            return render(response)
        }
    }

    private func runApp(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl app list|instances --app <app>|bind --app <app> --process-id <pid>|open <name-or-bundle-id>")
        }
        switch subcommand {
        case "list":
            return render(sendOrLocal(method: "app.list", params: [:], localFallback: true))
        case "instances":
            return render(sendOrLocal(
                method: "app.instances",
                params: ["app": .string(try requiredOption("--app", from: args))],
                localFallback: false
            ))
        case "bind":
            let rawProcessID = try requiredOption("--process-id", from: args)
            guard let processID = Int32(rawProcessID), processID > 0 else {
                throw CLIError.usage("--process-id must be a positive 32-bit process ID")
            }
            return render(sendOrLocal(
                method: "app.bind",
                params: [
                    "app": .string(try requiredOption("--app", from: args)),
                    "process_id": .number(Double(processID))
                ],
                localFallback: false
            ))
        case "open":
            guard let name = args.dropFirst().first else { throw CLIError.usage("Usage: macctl app open <name-or-bundle-id>") }
            var params: [String: JSONValue] = ["name": .string(name)]
            try addFocusPolicy(from: args, to: &params)
            return render(sendOrLocal(method: "app.open", params: params, localFallback: false))
        default:
            throw CLIError.usage("Usage: macctl app list|instances --app <app>|bind --app <app> --process-id <pid>|open <name-or-bundle-id>")
        }
    }

    private func runAction(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl action resolve --intent-stdin | run <resolution-id>")
        }
        switch subcommand {
        case "resolve":
            guard args.contains("--intent-stdin") else {
                throw CLIError.usage("Usage: macctl action resolve --intent-stdin")
            }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard !data.isEmpty,
                  let intent = try? JSONCodec.decode(JSONValue.self, from: data),
                  intent.objectValue != nil else {
                throw CLIError.usage("--intent-stdin expects one macctl-action-intent/v1 JSON object")
            }
            return render(sendOrLocal(
                method: "action.resolve",
                params: ["intent": intent],
                localFallback: false
            ))
        case "run":
            guard let resolutionID = args.dropFirst().first, !resolutionID.hasPrefix("--") else {
                throw CLIError.usage("Usage: macctl action run <resolution-id>")
            }
            return render(sendOrLocal(
                method: "action.run",
                params: ["resolution_id": .string(resolutionID)],
                localFallback: false
            ))
        default:
            throw CLIError.usage("Usage: macctl action resolve --intent-stdin | run <resolution-id>")
        }
    }

    private func runWorkflow(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl workflow list|validate|prepare|run <workflow>")
        }
        switch subcommand {
        case "list":
            return render(sendOrLocal(method: "workflow.list", params: [:], localFallback: true))
        case "validate":
            guard let workflow = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl workflow validate <workflow> [--focus-policy automatic|foreground|background]")
            }
            var params: [String: JSONValue] = ["workflow": .string(workflow)]
            try addFocusPolicy(from: args, to: &params)
            return render(sendOrLocal(method: "workflow.validate", params: params, localFallback: true))
        case "prepare":
            guard let workflow = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl workflow prepare <workflow> [--focus-policy automatic|foreground|background] [--ephemeral-stdin]")
            }
            var params: [String: JSONValue] = ["workflow": .string(workflow)]
            try addFocusPolicy(from: args, to: &params)
            try addEphemeralInputs(from: args, to: &params)
            return render(sendOrLocal(method: "workflow.prepare", params: params, localFallback: false))
        case "run":
            guard let workflow = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl workflow run <workflow> [--focus-policy automatic|foreground|background] [--approval-token <token>] [--ephemeral-stdin]")
            }
            var params: [String: JSONValue] = ["workflow": .string(workflow)]
            try addFocusPolicy(from: args, to: &params)
            if let tokenIndex = args.firstIndex(of: "--approval-token"), args.indices.contains(tokenIndex + 1) {
                params["approval_token"] = .string(args[tokenIndex + 1])
            }
            try addEphemeralInputs(from: args, to: &params)
            return render(sendOrLocal(method: "workflow.run", params: params, localFallback: false))
        default:
            throw CLIError.usage("Usage: macctl workflow list|validate|prepare|run <workflow> [--focus-policy automatic|foreground|background] [--ephemeral-stdin]")
        }
    }

    private func addFocusPolicy(
        from args: [String],
        to params: inout [String: JSONValue]
    ) throws {
        let explicit = try optionalOption("--focus-policy", from: args)
        let shorthand = args.contains("--background")
        guard !(explicit != nil && shorthand) else {
            throw CLIError.usage("Use either --focus-policy or --background, not both")
        }
        let raw = explicit ?? (shorthand ? FocusPolicy.background.rawValue : FocusPolicy.automatic.rawValue)
        guard let policy = FocusPolicy(rawValue: raw) else {
            throw CLIError.usage("--focus-policy must be automatic, foreground, or background")
        }
        params["focus_policy"] = .string(policy.rawValue)
    }

    private func addControlFocusPolicy(
        from args: [String],
        to params: inout [String: JSONValue]
    ) throws {
        let explicit = try optionalOption("--focus-policy", from: args)
        let shorthand = args.contains("--background")
        guard !(explicit != nil && shorthand) else {
            throw CLIError.usage("Use either --focus-policy or --background, not both")
        }
        let raw = explicit ?? (shorthand ? FocusPolicy.background.rawValue : FocusPolicy.automatic.rawValue)
        guard let policy = FocusPolicy(rawValue: raw) else {
            throw CLIError.usage("--focus-policy must be automatic, foreground, or background")
        }
        params["focus_policy"] = .string(policy.rawValue)
    }

    private func addControlTargetSurface(
        from args: [String],
        to params: inout [String: JSONValue]
    ) throws {
        guard let raw = try optionalOption("--target-surface", from: args) else { return }
        let normalized = raw.lowercased().replacingOccurrences(of: "-", with: "_")
        guard let surface = ControlTargetSurface(rawValue: normalized) else {
            throw CLIError.usage("--target-surface must be mac-app-ui or web-content")
        }
        params["target_surface"] = .string(surface.rawValue)
    }

    private func addEphemeralInputs(
        from args: [String],
        to params: inout [String: JSONValue]
    ) throws {
        guard args.contains("--ephemeral-stdin") else { return }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty,
              let value = try? JSONCodec.decode(JSONValue.self, from: data),
              value.objectValue != nil else {
            throw CLIError.usage("--ephemeral-stdin expects a JSON object of string values on stdin")
        }
        params["ephemeral_inputs"] = value
    }

    private func runApproval(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl approval list|approve|deny <token>")
        }
        switch subcommand {
        case "list":
            return render(sendOrLocal(method: "approval.list", params: [:], localFallback: false))
        case "approve", "deny":
            guard let token = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl approval \(subcommand) <token>")
            }
            return render(sendOrLocal(method: "approval.\(subcommand)", params: ["token": .string(token)], localFallback: false))
        default:
            throw CLIError.usage("Usage: macctl approval list|approve|deny <token>")
        }
    }

    private func runReceipts(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl receipts list|status|trace <trace-id>|trace-complete --stdin")
        }
        switch subcommand {
        case "list":
            return render(sendOrLocal(method: "receipts.list", params: [:], localFallback: true))
        case "status":
            return render(sendOrLocal(method: "receipts.status", params: [:], localFallback: true))
        case "trace":
            guard args.count == 2, let traceID = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl receipts trace <trace-id>")
            }
            return render(sendOrLocal(
                method: "receipts.trace",
                params: ["trace_id": .string(traceID)],
                localFallback: false
            ))
        case "trace-complete":
            guard args.count == 2, args[1] == "--stdin" else {
                throw CLIError.usage("Usage: macctl receipts trace-complete --stdin")
            }
            let maximumCompletionBytes = 8_192
            let data = try FileHandle.standardInput.read(upToCount: maximumCompletionBytes + 1) ?? Data()
            guard !data.isEmpty, data.count <= maximumCompletionBytes,
                  let value = try? JSONCodec.decode(JSONValue.self, from: data),
                  let params = value.objectValue else {
                throw CLIError.usage("receipts trace-complete --stdin expects one bounded JSON object")
            }
            return render(sendOrLocal(
                method: "receipts.trace.complete",
                params: params,
                localFallback: false
            ))
        default:
            throw CLIError.usage("Usage: macctl receipts list|status|trace <trace-id>|trace-complete --stdin")
        }
    }

    private func runRelease(_ args: [String]) throws -> Int32 {
        guard args.first == "check" else {
            throw CLIError.usage("Usage: macctl release check")
        }
        let report = ReleaseGate().evaluate()
        if jsonOutput {
            if let data = try? JSONCodec.encode(report), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        } else {
            print(report.passed ? "release: passed" : "release: blocked")
            for check in report.checks {
                print("\(check.state.rawValue): \(check.id) — \(check.message)")
            }
        }
        return report.passed ? 0 : 1
    }

    private func runRoute(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl route list|inspect|benchmark|register")
        }
        switch subcommand {
        case "list":
            return render(sendOrLocal(method: "route.list", params: [:], localFallback: true))
        case "inspect":
            var params: [String: JSONValue] = [
                "app": .string(try requiredOption("--app", from: args)),
                "task": .string(try requiredOption("--task", from: args))
            ]
            if let target = try optionalOption("--target-fingerprint", from: args) {
                params["target_fingerprint"] = .string(target)
            }
            return render(sendOrLocal(method: "route.inspect", params: params, localFallback: true))
        case "benchmark":
            var params: [String: JSONValue] = [
                "app": .string(try requiredOption("--app", from: args)),
                "task": .string(try requiredOption("--task", from: args)),
                "target_fingerprint": .string(try requiredOption("--target-fingerprint", from: args)),
                "route": .string(try requiredOption("--route", from: args)),
                "verification_oracle": .string(try requiredOption("--verification-oracle", from: args)),
                "action": .string(try requiredOption("--action", from: args)),
                "confirm": .bool(args.contains("--confirm"))
            ]
            let optionalNumbers: [(String, String)] = [
                ("--samples", "samples"),
                ("--warmups", "warmups"),
                ("--count", "count"),
                ("--amount", "amount"),
                ("--reset-amount", "reset_amount"),
                ("--inter-key-ms", "inter_key_ms"),
                ("--freshness-seconds", "freshness_seconds"),
                ("--tab-count", "tab_count"),
                ("--scroll-count", "scroll_count"),
                ("--user-help-count", "user_help_count")
            ]
            for (option, key) in optionalNumbers {
                if let raw = try optionalOption(option, from: args) {
                    guard let value = Double(raw) else {
                        throw CLIError.usage("\(option) must be a number")
                    }
                    params[key] = .number(value)
                }
            }
            if let direction = try optionalOption("--direction", from: args) {
                params["direction"] = .string(direction)
            }
            if let resetDirection = try optionalOption("--reset-direction", from: args) {
                params["reset_direction"] = .string(resetDirection)
            }
            if let resetAction = try optionalOption("--reset-action", from: args) {
                params["reset_action"] = .string(resetAction)
            }
            if let resetRoute = try optionalOption("--reset-route", from: args) {
                params["reset_route"] = .string(resetRoute)
            }
            if let permissions = try optionalOption("--required-permissions", from: args) {
                params["required_permissions"] = .array(
                    permissions.split(separator: ",").map { .string(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                )
            }
            if let fallbacks = try optionalOption("--fallback-routes", from: args) {
                params["fallback_routes"] = .array(
                    fallbacks.split(separator: ",").map { .string(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                )
            }
            if args.contains("--coordinate-use") {
                params["coordinate_use"] = .bool(true)
            }
            if args.contains("--visual-coordinate-opt-in") {
                params["visual_coordinate_opt_in"] = .bool(true)
            }
            if args.contains("--allow-raw-coordinate") {
                params["allow_raw_coordinate"] = .bool(true)
            }
            var selector: [String: JSONValue] = [:]
            let stringOptions: [(String, String)] = [
                ("--role", "role"),
                ("--identifier", "identifier"),
                ("--locator-digest", "locatorDigest"),
                ("--ancestor-digest", "ancestorDigest"),
                ("--geometry-digest", "geometryDigest"),
                ("--title", "title"),
                ("--subrole", "subrole"),
                ("--contains-text", "containsText"),
                ("--image-anchor", "imageAnchor"),
                ("--window-title", "windowTitle"),
                ("--window-identifier", "windowIdentifier")
            ]
            for (option, key) in stringOptions {
                if let value = try optionalOption(option, from: args) {
                    selector[key] = .string(value)
                }
            }
            let numberOptions: [(String, String)] = [
                ("--normalized-x", "normalizedX"),
                ("--normalized-y", "normalizedY"),
                ("--raw-x", "rawX"),
                ("--raw-y", "rawY")
            ]
            for (option, key) in numberOptions {
                if let raw = try optionalOption(option, from: args) {
                    guard let value = Double(raw) else {
                        throw CLIError.usage("\(option) must be a number")
                    }
                    selector[key] = .number(value)
                }
            }
            if !selector.isEmpty {
                params["selector"] = .object(selector)
            }
            guard args.contains("--confirm") else {
                throw CLIError.usage("route benchmark requires --confirm")
            }
            return render(sendOrLocal(method: "route.benchmark", params: params, localFallback: false))
        case "register":
            var params: [String: JSONValue] = [
                "app": .string(try requiredOption("--app", from: args)),
                "task": .string(try requiredOption("--task", from: args)),
                "target_fingerprint": .string(try requiredOption("--target-fingerprint", from: args)),
                "route": .string(try requiredOption("--route", from: args)),
                "verification_oracle": .string(try requiredOption("--verification-oracle", from: args)),
                "latency_ms": .number(try requiredDoubleOption("--latency-ms", from: args)),
                "p95_latency_ms": .number(try requiredDoubleOption("--p95-ms", from: args)),
                "verification_rate": .number(try requiredDoubleOption("--verification-rate", from: args)),
                "confirm": .bool(args.contains("--confirm"))
            ]
            let optionalNumbers: [(String, String)] = [
                ("--recoveries", "recoveries"),
                ("--samples", "samples"),
                ("--freshness-seconds", "freshness_seconds"),
                ("--tab-count", "tab_count"),
                ("--scroll-count", "scroll_count"),
                ("--user-help-count", "user_help_count")
            ]
            for (option, key) in optionalNumbers {
                if let raw = try optionalOption(option, from: args) {
                    guard let value = Double(raw) else {
                        throw CLIError.usage("\(option) must be a number")
                    }
                    params[key] = .number(value)
                }
            }
            if let permissions = try optionalOption("--required-permissions", from: args) {
                params["required_permissions"] = .array(
                    permissions.split(separator: ",").map { .string(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                )
            }
            if let fallbacks = try optionalOption("--fallback-routes", from: args) {
                params["fallback_routes"] = .array(
                    fallbacks.split(separator: ",").map { .string(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                )
            }
            if args.contains("--coordinate-use") {
                params["coordinate_use"] = .bool(true)
            }
            if args.contains("--visual-coordinate-opt-in") {
                params["visual_coordinate_opt_in"] = .bool(true)
            }
            guard args.contains("--confirm") else {
                throw CLIError.usage("route register requires --confirm")
            }
            return render(sendOrLocal(method: "route.register", params: params, localFallback: false))
        default:
            throw CLIError.usage("Usage: macctl route list|inspect|benchmark|register")
        }
    }

    private func runAccessibility(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl accessibility tree|audit")
        }
        switch subcommand {
        case "tree":
            var params: [String: JSONValue] = [
                "app": .string(try requiredOption("--app", from: args))
            ]
            try addReadOnlyTargetOptions(from: args, to: &params)
            if let maxNodes = try optionalOption("--max-nodes", from: args) {
                guard let value = Int(maxNodes), value > 0 else {
                    throw CLIError.usage("--max-nodes must be a positive integer")
                }
                params["max_nodes"] = .number(Double(value))
            }
            if let maxDepth = try optionalOption("--max-depth", from: args) {
                guard let value = Int(maxDepth), value >= 0 else {
                    throw CLIError.usage("--max-depth must be a non-negative integer")
                }
                params["max_depth"] = .number(Double(value))
            }
            return render(sendOrLocal(method: "accessibility.tree", params: params, localFallback: false))
        case "audit":
            let manifestPath = try requiredOption("--manifest", from: args)
            return render(sendOrLocal(
                method: "accessibility.audit",
                params: [
                    "app": .string(try requiredOption("--app", from: args)),
                    "manifest": try readJSONValue(at: manifestPath)
                ],
                localFallback: false
            ))
        default:
            throw CLIError.usage("Usage: macctl accessibility tree|audit")
        }
    }

    private func runIdealState(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl ideal-state validate|audit")
        }
        let manifestPath = try requiredOption("--manifest", from: args)
        let manifestValue = try readJSONValue(at: manifestPath)
        switch subcommand {
        case "validate":
            let data = try JSONCodec.encode(manifestValue)
            let manifest: MacControlIdealStateManifest
            do {
                manifest = try JSONCodec.decode(MacControlIdealStateManifest.self, from: data)
            } catch {
                throw CLIError.usage("Manifest is not a valid Mac Control ideal-state manifest")
            }
            let validation = MacControlIdealStateManifestValidator.validate(manifest)
            if jsonOutput {
                return renderValue(validation)
            }
            print(validation.valid ? "valid" : "invalid")
            for error in validation.errors {
                print("error: \(error)")
            }
            return validation.valid ? 0 : 1
        case "audit":
            return render(sendOrLocal(
                method: "ideal-state.audit",
                params: [
                    "app": .string(try requiredOption("--app", from: args)),
                    "manifest": manifestValue
                ],
                localFallback: false
            ))
        default:
            throw CLIError.usage("Usage: macctl ideal-state validate|audit")
        }
    }

    private func readJSONValue(at path: String) throws -> JSONValue {
        do {
            return try JSONCodec.decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw CLIError.usage("Could not read JSON manifest at \(path)")
        }
    }

    private func runKeyboard(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl keyboard status|setup|enable|inspect|lease|freeze|navigate|send")
        }
        switch subcommand {
        case "status":
            return render(sendOrLocal(method: "keyboard.status", params: [:], localFallback: false))
        case "setup":
            return render(sendOrLocal(method: "keyboard.setup", params: [:], localFallback: true))
        case "enable":
            guard args.contains("--confirm") else {
                throw CLIError.usage("Usage: macctl keyboard enable --confirm [--json]")
            }
            return render(sendOrLocal(
                method: "keyboard.enable",
                params: ["confirm": .bool(true)],
                localFallback: false
            ))
        case "inspect":
            return render(sendOrLocal(method: "keyboard.inspect", params: [:], localFallback: false))
        case "lease":
            return try runKeyboardLease(Array(args.dropFirst()))
        case "freeze":
            return try runKeyboardFreeze(Array(args.dropFirst()))
        case "navigate":
            guard let command = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl keyboard navigate <command> --lease-token <token> [--count N]")
            }
            let token = try requiredOption("--lease-token", from: args)
            var params: [String: JSONValue] = [
                "command": .string(command),
                "lease_token": .string(token)
            ]
            if let count = try optionalOption("--count", from: args) {
                guard let value = Int(count), value > 0 else {
                    throw CLIError.usage("--count must be a positive integer")
                }
                params["count"] = .number(Double(value))
            }
            if let milliseconds = try optionalOption("--inter-key-ms", from: args) {
                guard let value = Double(milliseconds) else {
                    throw CLIError.usage("--inter-key-ms must be a number")
                }
                params["inter_key_ms"] = .number(value)
            }
            return render(sendOrLocal(method: "keyboard.navigate", params: params, localFallback: false))
        case "send":
            let token = try requiredOption("--lease-token", from: args)
            var keys: [String] = []
            var index = 1
            while index < args.count {
                if args[index] == "--lease-token" || args[index] == "--inter-key-ms" {
                    index += 2
                } else {
                    keys.append(args[index])
                    index += 1
                }
            }
            guard !keys.isEmpty else {
                throw CLIError.usage("Usage: macctl keyboard send <key>... --lease-token <token>")
            }
            var params: [String: JSONValue] = [
                "keys": .array(keys.map(JSONValue.string)),
                "lease_token": .string(token)
            ]
            if let milliseconds = try optionalOption("--inter-key-ms", from: args) {
                guard let value = Double(milliseconds) else {
                    throw CLIError.usage("--inter-key-ms must be a number")
                }
                params["inter_key_ms"] = .number(value)
            }
            return render(sendOrLocal(method: "keyboard.send", params: params, localFallback: false))
        default:
            throw CLIError.usage("Usage: macctl keyboard status|setup|enable|inspect|lease|freeze|navigate|send")
        }
    }

    private func runControl(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl control status|limitations|authorization|hands-off|perform|batch|capabilities|capability-audit|capability-audit-batch")
        }
        switch subcommand {
        case "status":
            return render(sendOrLocal(method: "control.status", params: [:], localFallback: true))
        case "limitations":
            return try runLimitations(Array(args.dropFirst()))
        case "hands-off":
            return try runHandsOffSession(Array(args.dropFirst()))
        case "authorization":
            return try runAuthorization(Array(args.dropFirst()))
        case "capabilities":
            let application = try requiredOption("--app", from: args)
            var params: [String: JSONValue] = ["app": .string(application)]
            try addControlTargetSurface(from: args, to: &params)
            if let task = try optionalOption("--task", from: args) {
                params["task"] = .string(task)
            }
            if let targetFingerprint = try optionalOption("--target-fingerprint", from: args) {
                params["target_fingerprint"] = .string(targetFingerprint)
            }
            return render(sendControlRequest(method: "control.capabilities", params: params))
        case "capability-audit":
            var params: [String: JSONValue] = [
                "app": .string(try requiredOption("--app", from: args))
            ]
            if let maxNodes = try optionalOption("--max-nodes", from: args) {
                guard let value = Int(maxNodes), value > 0 else {
                    throw CLIError.usage("--max-nodes must be a positive integer")
                }
                params["max_nodes"] = .number(Double(value))
            }
            if let maxDepth = try optionalOption("--max-depth", from: args) {
                guard let value = Int(maxDepth), value >= 0 else {
                    throw CLIError.usage("--max-depth must be a non-negative integer")
                }
                params["max_depth"] = .number(Double(value))
            }
            return render(sendOrLocal(method: "control.capability_audit", params: params, localFallback: false))
        case "capability-audit-batch":
            var params: [String: JSONValue] = [:]
            if let apps = try optionalOption("--apps", from: args) {
                let selectors = apps
                    .split(separator: ",", omittingEmptySubsequences: true)
                    .map { JSONValue.string(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard !selectors.isEmpty else {
                    throw CLIError.usage("--apps must contain at least one app selector")
                }
                params["apps"] = .array(selectors)
            }
            if args.contains("--all-applicable") {
                params["all_applicable"] = .bool(true)
            }
            if let runID = try optionalOption("--run-id", from: args) {
                params["run_id"] = .string(runID)
            }
            for (option, key, minimum) in [
                ("--max-nodes", "max_nodes", 1),
                ("--max-depth", "max_depth", 0),
                ("--max-apps", "max_apps", 1),
                ("--max-concurrency", "max_concurrency", 1)
            ] {
                if let raw = try optionalOption(option, from: args) {
                    guard let value = Int(raw), value >= minimum else {
                        throw CLIError.usage("(option) must be an integer >= (minimum)")
                    }
                    params[key] = .number(Double(value))
                }
            }
            guard params["run_id"] != nil || params["apps"] != nil || params["all_applicable"]?.boolValue == true else {
                throw CLIError.usage("Usage: macctl control capability-audit-batch --all-applicable [--max-apps N] [--run-id ID]")
            }
            guard !(params["run_id"] != nil && (params["apps"] != nil || params["all_applicable"] != nil)) else {
                throw CLIError.usage("--run-id cannot be combined with --apps or --all-applicable")
            }
            return render(sendOrLocal(method: "control.capability_audit_batch", params: params, localFallback: false))
        case "batch":
            let application = try requiredOption("--app", from: args)
            guard args.contains("--confirm") else {
                throw CLIError.usage("control batch requires --confirm")
            }
            guard args.contains("--actions-stdin") else {
                throw CLIError.usage("control batch requires --actions-stdin")
            }
            var params = try controlBatchParameters(from: args)
            params["app"] = .string(application)
            params["confirm"] = .bool(true)
            return render(sendControlRequest(method: "control.batch", params: params))
        case "perform":
            guard let action = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl control perform <action> (--lease-token <token> | --app <app> --confirm) [--focus-policy automatic|foreground|background] [--target-surface mac-app-ui|web-content] [selector options]")
            }
            var params: [String: JSONValue] = ["action": .string(action)]
            try addControlFocusPolicy(from: args, to: &params)
            try addControlTargetSurface(from: args, to: &params)
            let leaseToken = try optionalOption("--lease-token", from: args)
            let application = try optionalOption("--app", from: args)
            guard (leaseToken == nil) != (application == nil) else {
                throw CLIError.usage("Provide exactly one of --lease-token or --app")
            }
            if let leaseToken {
                guard !args.contains("--confirm") else {
                    throw CLIError.usage("--confirm is only valid with --app")
                }
                params["lease_token"] = .string(leaseToken)
            }
            if let application {
                guard args.contains("--confirm") else {
                    throw CLIError.usage("Atomic app control requires --confirm")
                }
                params["app"] = .string(application)
                params["confirm"] = .bool(true)
            }
            if let task = try optionalOption("--task", from: args) {
                params["task"] = .string(task)
            }
            if let targetFingerprint = try optionalOption("--target-fingerprint", from: args) {
                params["target_fingerprint"] = .string(targetFingerprint)
            }
            if let sessionID = try optionalOption("--hands-off-session-id", from: args) {
                params["hands_off_session_id"] = .string(sessionID)
            }
            if let route = try optionalOption("--route", from: args) {
                params["route"] = .string(route)
            }
            if action.lowercased() == "scroll" {
                guard application != nil, leaseToken == nil else {
                    throw CLIError.usage("Semantic scrolling requires --app <app> --confirm")
                }
                params["direction"] = .string(try requiredOption("--direction", from: args))
                guard let amount = Int(try requiredOption("--amount", from: args)), amount > 0 else {
                    throw CLIError.usage("--amount must be a positive integer")
                }
                params["amount"] = .number(Double(amount))
                if let fallback = try optionalOption("--fallback", from: args) {
                    let normalized = fallback.lowercased().replacingOccurrences(of: "-", with: "_")
                    guard ["input_scroll", "computer_use"].contains(normalized) else {
                        throw CLIError.usage("--fallback must be input-scroll or computer-use")
                    }
                    params["fallback_route"] = .string(normalized)
                }
            }
            if let count = try optionalOption("--count", from: args) {
                guard let value = Int(count), value > 0 else {
                    throw CLIError.usage("--count must be a positive integer")
                }
                params["count"] = .number(Double(value))
            }
            if let milliseconds = try optionalOption("--inter-key-ms", from: args) {
                guard let value = Double(milliseconds) else {
                    throw CLIError.usage("--inter-key-ms must be a number")
                }
                params["inter_key_ms"] = .number(value)
            }
            if let rawExpectedItems = try optionalOption("--expected-menu-items", from: args) {
                guard action.lowercased().replacingOccurrences(of: "_", with: "-") == "context-menu" else {
                    throw CLIError.usage("--expected-menu-items is only valid for context-menu")
                }
                let items = rawExpectedItems.split(separator: ",").map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                guard !items.isEmpty else {
                    throw CLIError.usage("--expected-menu-items must contain at least one item")
                }
                params["expected_menu_items"] = .array(items.map(JSONValue.string))
            }
            var selector: [String: JSONValue] = [:]
            let stringOptions: [(String, String)] = [
                ("--role", "role"),
                ("--identifier", "identifier"),
                ("--locator-digest", "locatorDigest"),
                ("--ancestor-digest", "ancestorDigest"),
                ("--geometry-digest", "geometryDigest"),
                ("--title", "title"),
                ("--subrole", "subrole"),
                ("--contains-text", "containsText"),
                ("--image-anchor", "imageAnchor"),
                ("--window-title", "windowTitle"),
                ("--window-identifier", "windowIdentifier")
            ]
            for (option, key) in stringOptions {
                if let value = try optionalOption(option, from: args) {
                    selector[key] = .string(value)
                }
            }
            let numberOptions: [(String, String)] = [
                ("--normalized-x", "normalizedX"),
                ("--normalized-y", "normalizedY"),
                ("--raw-x", "rawX"),
                ("--raw-y", "rawY")
            ]
            for (option, key) in numberOptions {
                if let raw = try optionalOption(option, from: args) {
                    guard let value = Double(raw) else {
                        throw CLIError.usage("\(option) must be a number")
                    }
                    selector[key] = .number(value)
                }
            }
            if args.contains("--allow-raw-coordinate") {
                params["allow_raw_coordinate"] = .bool(true)
            }
            if !selector.isEmpty {
                params["selector"] = .object(selector)
            }
            return render(sendControlRequest(method: "control.perform", params: params))
        default:
            throw CLIError.usage("Usage: macctl control status|authorization|hands-off|perform|batch|capabilities|capability-audit|capability-audit-batch")
        }
    }

    private func runLimitations(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            return render(localService.localReadOnlyHandle(RequestEnvelope(method: "control.limitations")))
        }
        switch subcommand {
        case "propose":
            guard args.count == 2, args[1] == "--stdin" else {
                throw CLIError.usage("Usage: macctl control limitations propose --stdin [--json]")
            }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard !data.isEmpty,
                  let input = try? JSONCodec.decode(MacControlLimitationProposalInput.self, from: data) else {
                throw CLIError.usage(
                    "--stdin expects one mac-control-limitation-proposal/v1 input JSON object"
                )
            }
            let proposal = try MacControlLimitationProposalStore().append(input)
            return renderValue(MacControlLimitationsProposalSubmission(proposal: proposal))
        case "proposals":
            guard args.dropFirst().isEmpty else {
                throw CLIError.usage("Usage: macctl control limitations proposals [--json]")
            }
            let store = MacControlLimitationProposalStore()
            return renderValue(MacControlLimitationsProposalList(
                proposals: try store.list(),
                ownerOnlyStorage: store.ownerOnlyStorage()
            ))
        default:
            throw CLIError.usage(
                "Usage: macctl control limitations [--json] | propose --stdin [--json] | proposals [--json]"
            )
        }
    }

    private func runWindow(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl window displays|list|inspect|place|restore")
        }
        switch subcommand {
        case "displays":
            return renderValue(NativeWindowDisplayCatalog(
                displays: SystemNativeWindowDisplayProvider().connectedDisplays()
            ))
        case "list":
            var params: [String: JSONValue] = [
                "app": .string(try requiredOption("--app", from: args))
            ]
            try addReadOnlyTargetOptions(from: args, to: &params)
            return render(sendOrLocal(method: "window.list", params: params, localFallback: false))
        case "inspect":
            var params: [String: JSONValue] = [
                "app": .string(try requiredOption("--app", from: args))
            ]
            try addReadOnlyTargetOptions(from: args, to: &params)
            return render(sendOrLocal(
                method: "window.inspect",
                params: params,
                localFallback: false
            ))
        case "place":
            guard args.contains("--confirm") else {
                throw CLIError.usage("window place requires --confirm")
            }
            if let target = try optionalOption("--window", from: args), target != "focused" {
                throw CLIError.usage("--window currently supports only focused")
            }
            let rawDisplayID = try requiredOption("--display-id", from: args)
            guard let displayID = UInt32(rawDisplayID) else {
                throw CLIError.usage("--display-id must be an unsigned 32-bit ID from `macctl window displays`")
            }
            let rawLayout = try requiredOption("--layout", from: args)
            guard NativeWindowLayoutName(rawValue: rawLayout) != nil else {
                throw CLIError.usage("--layout must be one of: \(NativeWindowLayoutName.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return render(sendOrLocal(
                method: "window.place",
                params: [
                    "app": .string(try requiredOption("--app", from: args)),
                    "window": .string("focused"),
                    "display_id": .number(Double(displayID)),
                    "layout": .string(rawLayout),
                    "confirm": .bool(true)
                ],
                localFallback: false
            ))
        case "restore":
            guard args.contains("--confirm") else {
                throw CLIError.usage("window restore requires --confirm")
            }
            return render(sendOrLocal(
                method: "window.restore",
                params: [
                    "restore_token": .string(try requiredOption("--restore-token", from: args)),
                    "confirm": .bool(true)
                ],
                localFallback: false
            ))
        default:
            throw CLIError.usage("Usage: macctl window displays|list|inspect|place|restore")
        }
    }

    private func addReadOnlyTargetOptions(
        from args: [String],
        to params: inout [String: JSONValue]
    ) throws {
        if let rawProcessID = try optionalOption("--process-id", from: args) {
            guard let processID = Int32(rawProcessID), processID > 0 else {
                throw CLIError.usage("--process-id must be a positive 32-bit process ID")
            }
            params["process_id"] = .number(Double(processID))
        }
        if let instanceRef = try optionalOption("--instance-ref", from: args) {
            guard !instanceRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError.usage("--instance-ref must not be empty")
            }
            params["instance_ref"] = .string(instanceRef)
        }
        if let windowRef = try optionalOption("--window-ref", from: args) {
            guard !windowRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError.usage("--window-ref must not be empty")
            }
            params["window_ref"] = .string(windowRef)
        }
    }

    private func runAuthorization(_ args: [String]) throws -> Int32 {
        guard let action = args.first else {
            throw CLIError.usage("Usage: macctl control authorization prepare|bind|list|resolve")
        }
        let forbidden = ["--command", "--args", "--prompt", "--password", "--token", "--secret", "--stdin"]
        guard args.allSatisfy({ !forbidden.contains($0) }) else {
            throw CLIError.usage("Authorization notices accept safe context only; raw commands, prompts, passwords, tokens, and private input are rejected")
        }
        switch action {
        case "prepare":
            var params: [String: JSONValue] = [
                "project": .string(try requiredOption("--project", from: args)),
                "action": .string(try requiredOption("--action", from: args)),
                "summary": .string(try requiredOption("--summary", from: args))
            ]
            let stringOptions: [(String, String)] = [
                ("--repository", "repository"),
                ("--task-id", "task_id"),
                ("--task-title", "task_title"),
                ("--thread-id", "thread_id"),
                ("--thread-title", "thread_title"),
                ("--source-reference", "source_reference"),
                ("--requesting-executable", "requesting_executable"),
                ("--requesting-helper", "requesting_helper"),
                ("--target-service", "target_service")
            ]
            for (option, key) in stringOptions {
                if let value = try optionalOption(option, from: args) {
                    params[key] = .string(value)
                }
            }
            if let kind = try optionalOption("--kind", from: args) {
                guard AuthorizationNoticeKind(rawValue: kind.lowercased()) != nil else {
                    throw CLIError.usage("--kind must be keychain, credential, permission, or other")
                }
                params["kind"] = .string(kind.lowercased())
            }
            if let expires = try optionalOption("--expires-in", from: args) {
                guard let value = Double(expires), value.isFinite, value > 0 else {
                    throw CLIError.usage("--expires-in must be a positive number of seconds")
                }
                params["expires_in"] = .number(value)
            }
            return render(sendOrLocal(
                method: "control.authorization.prepare",
                params: params,
                localFallback: false
            ))
        case "bind":
            guard let requestID = args.dropFirst().first, !requestID.hasPrefix("--") else {
                throw CLIError.usage("Usage: macctl control authorization bind <request-id> --process-id <pid>")
            }
            guard let processID = Int(try requiredOption("--process-id", from: args)), processID > 0 else {
                throw CLIError.usage("--process-id must be a positive integer")
            }
            return render(sendOrLocal(
                method: "control.authorization.bind",
                params: [
                    "request_id": .string(requestID),
                    "process_id": .number(Double(processID))
                ],
                localFallback: false
            ))
        case "list":
            return render(sendOrLocal(
                method: "control.authorization.list",
                params: [:],
                localFallback: false
            ))
        case "resolve":
            guard let requestID = args.dropFirst().first, !requestID.hasPrefix("--") else {
                throw CLIError.usage("Usage: macctl control authorization resolve <request-id> --outcome completed|failed|cancelled|timeout|unknown")
            }
            let outcome = try requiredOption("--outcome", from: args).lowercased()
            guard AuthorizationNoticeOutcome(rawValue: outcome) != nil else {
                throw CLIError.usage("--outcome must be completed, failed, cancelled, timeout, or unknown")
            }
            return render(sendOrLocal(
                method: "control.authorization.resolve",
                params: [
                    "request_id": .string(requestID),
                    "outcome": .string(outcome)
                ],
                localFallback: false
            ))
        default:
            throw CLIError.usage("Usage: macctl control authorization prepare|bind|list|resolve")
        }
    }

    private func runHandsOffSession(_ args: [String]) throws -> Int32 {
        guard let action = args.first else {
            throw CLIError.usage("Usage: macctl control hands-off begin|heartbeat|end|status")
        }
        switch action {
        case "begin":
            guard args.contains("--confirm") else {
                throw CLIError.usage("Usage: macctl control hands-off begin --confirm [--provider mac_control|computer_use|hybrid] [--app <app>] [--task <id>] [--seconds N]")
            }
            var params: [String: JSONValue] = ["confirm": .bool(true)]
            if let provider = try optionalOption("--provider", from: args) {
                params["provider"] = .string(provider)
            }
            if let application = try optionalOption("--app", from: args) {
                params["app"] = .string(application)
            }
            if let task = try optionalOption("--task", from: args) {
                params["task_id"] = .string(task)
            }
            if let seconds = try optionalOption("--seconds", from: args) {
                guard let value = Double(seconds), value.isFinite, value > 0 else {
                    throw CLIError.usage("--seconds must be a positive number")
                }
                params["seconds"] = .number(value)
            }
            return render(sendOrLocal(method: "control.hands_off.begin", params: params, localFallback: false))
        case "heartbeat":
            var params: [String: JSONValue] = [
                "session_id": .string(try requiredOption("--session-id", from: args))
            ]
            if let seconds = try optionalOption("--seconds", from: args) {
                guard let value = Double(seconds), value.isFinite, value > 0 else {
                    throw CLIError.usage("--seconds must be a positive number")
                }
                params["seconds"] = .number(value)
            }
            return render(sendOrLocal(method: "control.hands_off.heartbeat", params: params, localFallback: false))
        case "end":
            return render(sendOrLocal(
                method: "control.hands_off.end",
                params: ["session_id": .string(try requiredOption("--session-id", from: args))],
                localFallback: false
            ))
        case "status":
            return render(sendOrLocal(method: "control.hands_off.status", params: [:], localFallback: true))
        default:
            throw CLIError.usage("Usage: macctl control hands-off begin|heartbeat|end|status")
        }
    }

    private func controlBatchParameters(from args: [String]) throws -> [String: JSONValue] {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty, let value = try? JSONCodec.decode(JSONValue.self, from: data) else {
            throw CLIError.usage("--actions-stdin expects a JSON array or {\"actions\": [...]} envelope")
        }
        let actions: JSONValue?
        if let array = value.arrayValue {
            actions = .array(array)
        } else {
            actions = value.objectValue?["actions"]
        }
        guard let actions, actions.arrayValue != nil else {
            throw CLIError.usage("--actions-stdin expects a JSON array or {\"actions\": [...]} envelope")
        }
        var params: [String: JSONValue] = ["actions": actions]
        try addControlFocusPolicy(from: args, to: &params)
        try addControlTargetSurface(from: args, to: &params)
        if let task = try optionalOption("--task", from: args) {
            params["task"] = .string(task)
        }
        if let targetFingerprint = try optionalOption("--target-fingerprint", from: args) {
            params["target_fingerprint"] = .string(targetFingerprint)
        }
        if let sessionID = try optionalOption("--hands-off-session-id", from: args) {
            params["hands_off_session_id"] = .string(sessionID)
        }
        return params
    }

    private func runTask(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl task displays|compose|prepare|run|status|resume|cancel")
        }
        switch subcommand {
        case "displays":
            return renderValue(FocusSessionDisplayCatalogSnapshot(
                displays: SystemFocusSessionDisplayProvider().connectedDisplays()
            ))
        case "compose":
            guard args.dropFirst().first == "focus-session" else {
                throw CLIError.usage("Usage: macctl task compose focus-session --display-id <id> --layout balanced|brief-primary [--request <text>] [--plan] [--json]")
            }
            let request = try optionalOption("--request", from: args)
                ?? FocusSessionPlanComposer.canonicalRequest
            let rawDisplayID = try requiredOption("--display-id", from: args)
            guard let displayID = UInt32(rawDisplayID) else {
                throw CLIError.usage("--display-id must be an unsigned 32-bit display ID from `macctl task displays`")
            }
            let rawLayout = try requiredOption("--layout", from: args)
            guard let layout = FocusSessionLayoutName(rawValue: rawLayout) else {
                throw CLIError.usage("--layout must be one of: \(FocusSessionLayoutName.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let display = try FocusSessionDisplayResolver.resolve(
                id: displayID,
                from: SystemFocusSessionDisplayProvider().connectedDisplays()
            )
            if args.contains("--plan") {
                return renderValue(try FocusSessionPlanComposer.taskPlan(
                    request: request,
                    display: display,
                    layout: layout
                ))
            }
            return renderValue(try FocusSessionPlanComposer.compose(
                request: request,
                display: display,
                layout: layout
            ))
        case "prepare":
            let params = try taskPlanParameters(from: args)
            if params["plan"] == nil {
                throw CLIError.usage("Usage: macctl task prepare --plan-stdin [--json]")
            }
            return render(sendOrLocal(method: "task.prepare", params: params, localFallback: false))
        case "run", "resume":
            var params = try taskPlanParameters(from: args)
            if params["plan"] == nil {
                throw CLIError.usage("Usage: macctl task \(subcommand) --plan-stdin --approval-token <token> [--lease-token <token>]")
            }
            params["approval_token"] = .string(try requiredOption("--approval-token", from: args))
            if let lease = try optionalOption("--lease-token", from: args) {
                params["lease_token"] = .string(lease)
            }
            return render(sendOrLocal(method: "task.\(subcommand)", params: params, localFallback: false))
        case "status", "cancel":
            guard let taskID = args.dropFirst().first, !taskID.hasPrefix("--") else {
                throw CLIError.usage("Usage: macctl task \(subcommand) <task-id>")
            }
            return render(sendOrLocal(
                method: "task.\(subcommand)",
                params: ["task_id": .string(taskID)],
                localFallback: false
            ))
        default:
            throw CLIError.usage("Usage: macctl task displays|compose|prepare|run|status|resume|cancel")
        }
    }

    private func taskPlanParameters(from args: [String]) throws -> [String: JSONValue] {
        guard args.contains("--plan-stdin") else { return [:] }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty, let value = try? JSONCodec.decode(JSONValue.self, from: data),
              let object = value.objectValue else {
            throw CLIError.usage("--plan-stdin expects a JSON task plan or {\"plan\": ...} envelope")
        }
        if let plan = object["plan"] {
            var params: [String: JSONValue] = ["plan": plan]
            if let inputs = object["ephemeral_inputs"] {
                params["ephemeral_inputs"] = inputs
            }
            return params
        }
        return ["plan": value]
    }

    private func runAdapter(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl adapter capabilities|diagnostics")
        }
        switch subcommand {
        case "capabilities":
            return render(sendOrLocal(method: "adapter.capabilities", params: [:], localFallback: true))
        case "diagnostics":
            let adapterID = try requiredOption("--adapter-id", from: args)
            let fixtureID = try requiredOption("--fixture-id", from: args)
            var params: [String: JSONValue] = [
                "adapter_id": .string(adapterID),
                "operation": .string("diagnostics.summary"),
                "fixture_id": .string(fixtureID)
            ]
            if let rawMaxAge = try optionalOption("--max-age-seconds", from: args) {
                guard let maxAge = Double(rawMaxAge), maxAge.isFinite, maxAge > 0, maxAge <= 60 else {
                    throw CLIError.usage("--max-age-seconds must be greater than zero and no more than 60")
                }
                params["max_age_seconds"] = .number(maxAge)
            }
            return render(sendOrLocal(method: "adapter.diagnostics", params: params, localFallback: true))
        default:
            throw CLIError.usage("Usage: macctl adapter capabilities|diagnostics")
        }
    }

    private func runKeyboardFreeze(_ args: [String]) throws -> Int32 {
        guard let action = args.first else {
            throw CLIError.usage("Usage: macctl keyboard freeze acquire|status|release <token>")
        }
        switch action {
        case "acquire":
            let scope = try requiredOption("--scope", from: args).lowercased()
            guard scope == KeyboardLeaseScope.session.rawValue else {
                throw CLIError.usage("Keyboard freeze is session-only; use --scope session")
            }
            guard args.contains("--confirm") else {
                throw CLIError.usage("keyboard freeze acquire requires --confirm")
            }
            var params: [String: JSONValue] = [
                "scope": .string(scope),
                "reason": .string(try requiredOption("--reason", from: args)),
                "confirm": .bool(true)
            ]
            if let seconds = try optionalOption("--seconds", from: args) {
                guard let value = Double(seconds) else {
                    throw CLIError.usage("--seconds must be a number")
                }
                params["seconds"] = .number(value)
            }
            return render(sendOrLocal(method: "keyboard.freeze.acquire", params: params, localFallback: false))
        case "status":
            return render(sendOrLocal(method: "keyboard.freeze.status", params: [:], localFallback: false))
        case "release":
            guard let token = args.dropFirst().first, !token.hasPrefix("--") else {
                throw CLIError.usage("Usage: macctl keyboard freeze release <token>")
            }
            return render(sendOrLocal(
                method: "keyboard.freeze.release",
                params: ["token": .string(token)],
                localFallback: false
            ))
        default:
            throw CLIError.usage("Usage: macctl keyboard freeze acquire|status|release <token>")
        }
    }

    private func runKeyboardLease(_ args: [String]) throws -> Int32 {
        guard let action = args.first else {
            throw CLIError.usage("Usage: macctl keyboard lease acquire|release")
        }
        switch action {
        case "acquire":
            let scope = try requiredOption("--scope", from: args)
            guard KeyboardLeaseScope(rawValue: scope.lowercased()) != nil else {
                throw CLIError.usage("--scope must be app or session")
            }
            var params: [String: JSONValue] = [
                "scope": .string(scope.lowercased()),
                "confirm": .bool(args.contains("--confirm"))
            ]
            if scope.lowercased() == KeyboardLeaseScope.app.rawValue {
                guard let app = try optionalOption("--app", from: args) else {
                    throw CLIError.usage("App-scoped leases require --app \"<name>\"")
                }
                params["app"] = .string(app)
            }
            if let seconds = try optionalOption("--seconds", from: args) {
                guard let value = Double(seconds) else {
                    throw CLIError.usage("--seconds must be a number")
                }
                params["seconds"] = .number(value)
            }
            let suppressPhysicalKeyboard = args.contains("--suppress-physical-keyboard")
            if suppressPhysicalKeyboard, scope.lowercased() != KeyboardLeaseScope.session.rawValue {
                throw CLIError.usage("--suppress-physical-keyboard requires --scope session")
            }
            if suppressPhysicalKeyboard {
                params["physical_input_mode"] = .string("suppressed")
                params["reason"] = .string(try requiredOption("--reason", from: args))
            }
            let navigationMode = args.contains("--navigation-mode")
            let fromPassThrough = args.contains("--from-pass-through")
            if navigationMode, scope.lowercased() != KeyboardLeaseScope.session.rawValue {
                throw CLIError.usage("--navigation-mode requires --scope session")
            }
            if fromPassThrough, !navigationMode {
                throw CLIError.usage("--from-pass-through requires --navigation-mode")
            }
            if navigationMode {
                params["navigation_mode"] = .string("navigation")
                guard fromPassThrough else {
                    throw CLIError.usage("--navigation-mode requires --from-pass-through")
                }
                params["from_pass_through"] = .bool(true)
            }
            guard args.contains("--confirm") else {
                throw CLIError.usage("Usage: macctl keyboard lease acquire --scope app|session [--seconds N] [--navigation-mode --from-pass-through] [--suppress-physical-keyboard --reason <text>] --confirm")
            }
            return render(sendOrLocal(
                method: "keyboard.lease.acquire",
                params: params,
                localFallback: false
            ))
        case "release":
            guard let token = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl keyboard lease release <token>")
            }
            return render(sendOrLocal(
                method: "keyboard.lease.release",
                params: ["token": .string(token)],
                localFallback: false
            ))
        default:
            throw CLIError.usage("Usage: macctl keyboard lease acquire|release")
        }
    }

    private func optionalOption(_ name: String, from args: [String]) throws -> String? {
        guard let index = args.firstIndex(of: name) else { return nil }
        guard args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") else {
            throw CLIError.usage("\(name) requires a value")
        }
        return args[index + 1]
    }

    private func requiredOption(_ name: String, from args: [String]) throws -> String {
        guard let value = try optionalOption(name, from: args) else {
            throw CLIError.usage("Missing required \(name) option")
        }
        return value
    }

    private func requiredDoubleOption(_ name: String, from args: [String]) throws -> Double {
        let raw = try requiredOption(name, from: args)
        guard let value = Double(raw), value.isFinite else {
            throw CLIError.usage("\(name) must be a finite number")
        }
        return value
    }

    private func runShortcut(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl shortcut audit|propose|inspect|setup|run|remove")
        }
        switch subcommand {
        case "audit":
            var params: [String: JSONValue] = [:]
            if let app = try optionalOption("--app", from: args) {
                params["app"] = .string(app)
            }
            return render(sendOrLocal(method: "shortcut.audit", params: params, localFallback: false))
        case "propose":
            let chord = try optionalOption("--chord", from: args)
            var params: [String: JSONValue] = [:]
            if let extensionID = try optionalOption("--extension-id", from: args) {
                guard !args.contains("--app"), !args.contains("--menu-path") else {
                    throw CLIError.usage("Choose either --extension-id/--command-id or --app/--menu-path")
                }
                params["extension_id"] = .string(extensionID)
                params["command_id"] = .string(try requiredOption("--command-id", from: args))
            } else {
                guard !args.contains("--command-id") else {
                    throw CLIError.usage("--command-id requires --extension-id")
                }
                params["app"] = .string(try requiredOption("--app", from: args))
                let rawPath = try requiredOption("--menu-path", from: args)
                let path = rawPath.components(separatedBy: "->").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard path.count >= 2, path.allSatisfy({ !$0.isEmpty }) else {
                    throw CLIError.usage("--menu-path must use exact Menu->Submenu->Command syntax")
                }
                params["menu_path"] = .array(path.map(JSONValue.string))
            }
            if let chord { params["chord"] = .string(chord) }
            if args.contains("--postconditions-stdin") {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard !data.isEmpty,
                      let value = try? JSONCodec.decode(JSONValue.self, from: data) else {
                    throw CLIError.usage("--postconditions-stdin expects a JSON predicate array or {\"postconditions\": [...]} envelope")
                }
                let predicates = value.arrayValue.map(JSONValue.array)
                    ?? value.objectValue?["postconditions"]
                guard let predicates, predicates.arrayValue != nil else {
                    throw CLIError.usage("--postconditions-stdin expects a JSON predicate array or {\"postconditions\": [...]} envelope")
                }
                params["postconditions"] = predicates
            }
            return render(sendOrLocal(method: "shortcut.propose", params: params, localFallback: false))
        case "inspect":
            guard let id = args.dropFirst().first, !id.hasPrefix("--") else {
                throw CLIError.usage("Usage: macctl shortcut inspect <id>")
            }
            return render(sendOrLocal(
                method: "shortcut.inspect",
                params: ["id": .string(id)],
                localFallback: false
            ))
        case "setup", "run", "remove":
            guard let id = args.dropFirst().first, !id.hasPrefix("--") else {
                throw CLIError.usage("Usage: macctl shortcut \(subcommand) <id> [--approval-token <token>]")
            }
            var params: [String: JSONValue] = ["id": .string(id)]
            if let token = try optionalOption("--approval-token", from: args) {
                params["approval_token"] = .string(token)
            }
            if let route = try optionalOption("--route", from: args) {
                guard subcommand == "run", ["accessibility", "keyboard"].contains(route) else {
                    throw CLIError.usage("--route is supported only by shortcut run and must be accessibility or keyboard")
                }
                params["route"] = .string(route)
            }
            return render(sendOrLocal(
                method: "shortcut.\(subcommand)",
                params: params,
                localFallback: false
            ))
        default:
            throw CLIError.usage("Usage: macctl shortcut audit|propose|inspect|setup|run|remove")
        }
    }

    private func runDaemon(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl daemon install|remove|restart|status")
        }
        let manager = LaunchAgentManager(lifecycleInterlock: DaemonLifecycleInterlock(
            allowLegacyIdleSnapshot: args.contains("--allow-legacy-idle-snapshot")
        ))
        switch subcommand {
        case "install":
            let daemonPath = LaunchAgentManager.installedDaemonExecutablePath()
                ?? MacCtlPaths.daemonAppExecutableURL.path
            guard FileManager.default.isExecutableFile(atPath: daemonPath) else {
                throw LaunchAgentError.daemonExecutableMissing
            }
            return renderValue(try manager.install(daemonExecutable: daemonPath))
        case "remove":
            return renderValue(try manager.remove())
        case "restart":
            return renderValue(try manager.restart())
        case "status":
            return renderValue(manager.status())
        default:
            throw CLIError.usage("Usage: macctl daemon install|remove|restart|status")
        }
    }

    private func runInstall(_ args: [String]) throws -> Int32 {
        let unsupported = args.filter { $0 != "--allow-legacy-idle-snapshot" }
        guard unsupported.isEmpty else {
            throw CLIError.usage("Usage: macctl install [--allow-legacy-idle-snapshot]")
        }
        let manager = LaunchAgentManager(lifecycleInterlock: DaemonLifecycleInterlock(
            allowLegacyIdleSnapshot: args.contains("--allow-legacy-idle-snapshot")
        ))
        let paths = try manager.installUserBinaries(from: CommandLine.arguments[0])
        return renderValue(["installed": paths])
    }

    private func sendOrLocal(
        method: String,
        params: [String: JSONValue],
        localFallback: Bool
    ) -> ResponseEnvelope {
        let request = RequestEnvelope(method: method, params: params)
        do {
            return try UnixSocketClient().send(request)
        } catch {
            if localFallback {
                return localService.localReadOnlyHandle(request)
            }
            if method == "doctor" {
                return localService.unavailableDoctorResponse(request: request, socketError: error.localizedDescription)
            }
            if method == "status" {
                return localService.unavailableStatusResponse(request: request, socketError: error.localizedDescription)
            }
            return ResponseEnvelope(
                requestID: request.requestID,
                status: .blocked,
                error: MacCtlError(
                    code: MacCtlErrorCode.daemonUnavailable.rawValue,
                    message: "macctld request failed at \(MacCtlPaths.socketURL.path): \(error.localizedDescription); start it with macctl daemon install"
                )
            )
        }
    }

    /// Keep the browser-provider boundary safe across daemon upgrades. An
    /// older daemon may ignore an unknown target_surface field, so the current
    /// client resolves web-content capability and handoff responses locally
    /// and never sends those requests to a potentially stale daemon.
    private func sendControlRequest(
        method: String,
        params: [String: JSONValue]
    ) -> ResponseEnvelope {
        if params["target_surface"]?.stringValue == ControlTargetSurface.webContent.rawValue {
            let startedAt = Date()
            let localRequest = RequestEnvelope(method: method, params: params)
            let localResponse = localService.localReadOnlyHandle(localRequest)
            guard method != "control.capabilities",
                  localResponse.error?.code == MacCtlErrorCode.providerHandoffRequired.rawValue else {
                return localResponse
            }

            var traceParams: [String: JSONValue] = [
                "source_method": .string(method),
                "source_request_id": .string(localRequest.requestID),
                "source_started_at_ms": .number(startedAt.timeIntervalSince1970 * 1_000),
                "target_surface": .string(ControlTargetSurface.webContent.rawValue),
                "focus_policy": params["focus_policy"] ?? .string(FocusPolicy.automatic.rawValue)
            ]
            for key in ["app", "action", "task", "target_fingerprint", "selector"] {
                if let value = params[key] { traceParams[key] = value }
            }
            if method == "control.batch" { traceParams["action"] = .string("batch") }

            let traceResponse: ResponseEnvelope
            do {
                traceResponse = try UnixSocketClient().send(RequestEnvelope(
                    method: "receipts.trace.begin",
                    params: traceParams
                ))
            } catch {
                return attachTraceUnavailable(to: localResponse)
            }
            guard traceResponse.status == .succeeded,
                  let trace = traceResponse.result["trace"] else {
                return attachTraceUnavailable(to: localResponse)
            }

            var result = localResponse.result.objectValue ?? [:]
            result["trace"] = trace
            result["trace_state"] = .string(CrossProviderTraceState.open.rawValue)
            var details = localResponse.error?.details ?? [:]
            details["trace"] = trace
            details["trace_state"] = .string(CrossProviderTraceState.open.rawValue)
            let error = localResponse.error.map {
                MacCtlError(code: $0.code, message: $0.message, details: details)
            }
            return ResponseEnvelope(
                requestID: localRequest.requestID,
                operationID: traceResponse.operationID,
                status: localResponse.status,
                result: .object(result),
                evidence: localResponse.evidence + traceResponse.evidence,
                error: error,
                outcome: localResponse.outcome
            )
        }
        return sendOrLocal(method: method, params: params, localFallback: false)
    }

    private func attachTraceUnavailable(to response: ResponseEnvelope) -> ResponseEnvelope {
        var result = response.result.objectValue ?? [:]
        result["trace_state"] = .string("unavailable")
        var details = response.error?.details ?? [:]
        details["trace_state"] = .string("unavailable")
        return ResponseEnvelope(
            requestID: response.requestID,
            operationID: response.operationID,
            status: response.status,
            result: .object(result),
            evidence: response.evidence,
            error: response.error.map { MacCtlError(code: $0.code, message: $0.message, details: details) },
            outcome: response.outcome
        )
    }

    private func render(_ response: ResponseEnvelope) -> Int32 {
        if jsonOutput {
            if let data = try? JSONCodec.encode(response), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        } else {
            if response.status == .succeeded || response.status == .prepared {
                print(response.result.objectValue?["message"]?.stringValue ?? response.status.rawValue)
                if let token = response.result.objectValue?["approval"]?.objectValue?["token"]?.stringValue {
                    print("approval token: \(token)")
                }
                if let token = response.result.objectValue?["lease"]?.objectValue?["token"]?.stringValue {
                    print("keyboard lease token: \(token)")
                }
            } else {
                print("\(response.status.rawValue): \(response.error?.message ?? "unknown error")")
            }
        }
        return response.status == .succeeded || response.status == .prepared ? 0 : 1
    }

    private func renderValue<T: Encodable>(_ value: T) -> Int32 {
        if let data = try? JSONCodec.encode(value), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return 0
    }

    private func renderVersion() -> Int32 {
        if jsonOutput {
            return renderValue(MacCtlVersionOutput(version: MacCtlVersion.current))
        }
        print("macctl \(MacCtlVersion.current)")
        return 0
    }

    private func printHelp() {
        print("""
        macctl — command-first macOS control plane

        macctl version [--json]
        macctl --version
        macctl doctor --json
        macctl capabilities --json
        macctl status --json
        macctl app list [--json]
        macctl app instances --app <app> [--json]
        macctl app bind --app <app> --process-id <pid> [--json]
        macctl app open <name-or-bundle-id> [--focus-policy automatic|foreground|background] [--background]
        macctl action resolve --intent-stdin [--json]
        macctl action run <resolution-id> [--json]
        macctl window displays [--json]
        macctl window list --app <app> [--process-id <pid>] [--instance-ref <ref>] [--json]
        macctl window inspect --app <app> [--process-id <pid>] [--instance-ref <ref>] [--window-ref <ref>] [--json]
        macctl window place --app <app> [--window focused] --display-id <id> --layout <name> --confirm [--json]
        macctl window restore --restore-token <token> --confirm [--json]
        macctl workflow list|validate|prepare|run <workflow> [--focus-policy automatic|foreground|background] [--background] [--ephemeral-stdin]
        macctl approval list|approve|deny <token>
        macctl receipts list|status|trace <trace-id>|trace-complete --stdin
        macctl release check [--json]
        macctl keyboard status|setup|enable --confirm|inspect
        macctl keyboard lease acquire --scope app --app "<name>" [--seconds N] --confirm
        macctl keyboard lease acquire --scope session [--seconds N] [--suppress-physical-keyboard --reason <text>] --confirm
        macctl keyboard lease release <token>
        macctl keyboard freeze acquire --scope session --seconds 30 --confirm --reason <text>
        macctl keyboard freeze status
        macctl keyboard freeze release <token>
        macctl keyboard navigate <command> --lease-token <token> [--count N]
        macctl keyboard send <key>... --lease-token <token>
        macctl control status [--json]
        macctl control limitations [--json]
        macctl control limitations propose --stdin [--json]
        macctl control limitations proposals [--json]
        macctl control authorization prepare --project <project> --action <safe-action> --summary <safe-summary> [--repository <repo>] [--task-id <id> --task-title <title>] [--thread-id <id> --thread-title <title>] [--source-reference codex://thread/<id>] [--requesting-executable <name>] [--requesting-helper <name>] [--target-service <service>] [--kind keychain|credential|permission|other] [--expires-in N]
        macctl control authorization bind <request-id> --process-id <pid>
        macctl control authorization list
        macctl control authorization resolve <request-id> --outcome completed|failed|cancelled|timeout|unknown
        macctl control hands-off begin --confirm [--provider mac_control|computer_use|hybrid] [--app <app>] [--task <id>] [--seconds N]
        macctl control hands-off heartbeat|end --session-id <id> [--seconds N]
        macctl control hands-off status
        macctl control capabilities --app <app> [--target-surface mac-app-ui|web-content] [--task <id> --target-fingerprint <fingerprint>]
        macctl control capability-audit --app <app> [--max-nodes N] [--max-depth N]
        macctl control capability-audit-batch --all-applicable [--max-apps N] [--run-id ID]
        macctl control capability-audit-batch --apps <app[,app...]> [--max-apps N]
        macctl control batch --app <app> --actions-stdin --confirm [--focus-policy automatic|foreground|background] [--target-surface mac-app-ui|web-content] [--task <id> --target-fingerprint <fingerprint>] [--hands-off-session-id <id>]
        macctl control perform <action> (--lease-token <token> | --app <app> --confirm) [--focus-policy automatic|foreground|background] [--target-surface mac-app-ui|web-content] [--task <id>] [--hands-off-session-id <id>] [--route <route>] [selector options]
        macctl control perform context-menu --app <app> --confirm --role <role> [--identifier <id>] [--title <title>] [--window-title <title> | --window-identifier <id>] [--expected-menu-items "Item A,Item B"]
        macctl control perform scroll --app <app> --role AXScrollArea [--identifier <id>] [--locator-digest <digest> --ancestor-digest <digest> --geometry-digest <digest>] --direction up|down|left|right --amount N [--fallback input-scroll|computer-use] --confirm
        macctl shortcut audit [--app <app>]
        macctl shortcut propose --app <app> --menu-path "Menu->Submenu->Command" [--chord <chord>] [--postconditions-stdin]
        macctl shortcut propose --extension-id <id> --command-id <id> [--chord <chord>] --postconditions-stdin
        macctl shortcut inspect <id>
        macctl shortcut setup|remove <id> [--approval-token <token>]
        macctl shortcut run <id> [--route accessibility|keyboard] [--approval-token <token>]
        macctl route list|inspect --app <app> --task <task>
        macctl route benchmark --app <app> --task <task> --action <action> --route <route> --confirm
        macctl route benchmark ... --action scroll --route scroll --direction up|down|left|right --amount N [--reset-direction <opposite> --reset-amount N]
        macctl route register --app <app> --task <task> --latency-ms <ms> --p95-ms <ms> --verification-rate <0...1> --confirm
        macctl accessibility tree --app <app> [--process-id <pid>] [--instance-ref <ref>] [--window-ref <ref>]
        macctl accessibility audit --app <app> --manifest <path>
        macctl ideal-state validate --manifest <path> [--json]
        macctl ideal-state audit --app <app> --manifest <path> [--json]
        macctl task displays [--json]
        macctl task compose focus-session --display-id <id> --layout balanced|brief-primary [--request <text>] [--plan] [--json]
        macctl task prepare|run|status|resume|cancel
        macctl task prepare --plan-stdin [--json]
        macctl task run|resume --plan-stdin --approval-token <token> [--lease-token <token>]
        macctl task status|cancel <task-id>
        macctl adapter capabilities [--json]
        macctl adapter diagnostics --adapter-id vscode --fixture-id <id> [--max-age-seconds <seconds>] [--json]
        macctl daemon install|remove|restart|status [--allow-legacy-idle-snapshot]
        macctl logs [--json]
        macctl install [--allow-legacy-idle-snapshot]
        """)
    }
}

private struct MacCtlVersionOutput: Encodable {
    let schemaVersion = "macctl-version/v1"
    let name = "macctl"
    let version: String
}

enum CLIError: Error, LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message): return message
        }
    }
}

exit(CLI(arguments: Array(CommandLine.arguments.dropFirst())).run())
