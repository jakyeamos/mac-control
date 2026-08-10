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
            case "doctor", "status":
                return render(sendOrLocal(method: command, params: [:], localFallback: false))
            case "capabilities":
                return render(sendOrLocal(method: command, params: [:], localFallback: true))
            case "app":
                return try runApp(commandArguments)
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
        guard let subcommand = args.first else { throw CLIError.usage("Usage: macctl app list|open <name-or-bundle-id>") }
        switch subcommand {
        case "list":
            return render(sendOrLocal(method: "app.list", params: [:], localFallback: true))
        case "open":
            guard let name = args.dropFirst().first else { throw CLIError.usage("Usage: macctl app open <name-or-bundle-id>") }
            var params: [String: JSONValue] = ["name": .string(name)]
            try addFocusPolicy(from: args, to: &params)
            return render(sendOrLocal(method: "app.open", params: params, localFallback: false))
        default:
            throw CLIError.usage("Usage: macctl app list|open <name-or-bundle-id>")
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
                throw CLIError.usage("Usage: macctl workflow validate <workflow> [--background]")
            }
            var params: [String: JSONValue] = ["workflow": .string(workflow)]
            try addFocusPolicy(from: args, to: &params)
            return render(sendOrLocal(method: "workflow.validate", params: params, localFallback: true))
        case "prepare":
            guard let workflow = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl workflow prepare <workflow> [--background] [--ephemeral-stdin]")
            }
            var params: [String: JSONValue] = ["workflow": .string(workflow)]
            try addFocusPolicy(from: args, to: &params)
            try addEphemeralInputs(from: args, to: &params)
            return render(sendOrLocal(method: "workflow.prepare", params: params, localFallback: false))
        case "run":
            guard let workflow = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl workflow run <workflow> [--background] [--approval-token <token>] [--ephemeral-stdin]")
            }
            var params: [String: JSONValue] = ["workflow": .string(workflow)]
            try addFocusPolicy(from: args, to: &params)
            if let tokenIndex = args.firstIndex(of: "--approval-token"), args.indices.contains(tokenIndex + 1) {
                params["approval_token"] = .string(args[tokenIndex + 1])
            }
            try addEphemeralInputs(from: args, to: &params)
            return render(sendOrLocal(method: "workflow.run", params: params, localFallback: false))
        default:
            throw CLIError.usage("Usage: macctl workflow list|validate|prepare|run <workflow> [--background] [--ephemeral-stdin]")
        }
    }

    private func addFocusPolicy(
        from args: [String],
        to params: inout [String: JSONValue]
    ) throws {
        guard args.contains("--background") else { return }
        params["focus_policy"] = .string(FocusPolicy.background.rawValue)
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
            throw CLIError.usage("Usage: macctl receipts list|status")
        }
        switch subcommand {
        case "list":
            return render(sendOrLocal(method: "receipts.list", params: [:], localFallback: true))
        case "status":
            return render(sendOrLocal(method: "receipts.status", params: [:], localFallback: true))
        default:
            throw CLIError.usage("Usage: macctl receipts list|status")
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
            throw CLIError.usage("Usage: macctl control status|perform|batch|capabilities|capability-audit|capability-audit-batch")
        }
        switch subcommand {
        case "status":
            return render(sendOrLocal(method: "control.status", params: [:], localFallback: true))
        case "capabilities":
            let application = try requiredOption("--app", from: args)
            var params: [String: JSONValue] = ["app": .string(application)]
            if let task = try optionalOption("--task", from: args) {
                params["task"] = .string(task)
            }
            if let targetFingerprint = try optionalOption("--target-fingerprint", from: args) {
                params["target_fingerprint"] = .string(targetFingerprint)
            }
            return render(sendOrLocal(method: "control.capabilities", params: params, localFallback: false))
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
            return render(sendOrLocal(method: "control.batch", params: params, localFallback: false))
        case "perform":
            guard let action = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl control perform <action> (--lease-token <token> | --app <app> --confirm) [selector options]")
            }
            var params: [String: JSONValue] = ["action": .string(action)]
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
            return render(sendOrLocal(method: "control.perform", params: params, localFallback: false))
        default:
            throw CLIError.usage("Usage: macctl control status|perform|batch|capabilities|capability-audit|capability-audit-batch")
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
        if let task = try optionalOption("--task", from: args) {
            params["task"] = .string(task)
        }
        if let targetFingerprint = try optionalOption("--target-fingerprint", from: args) {
            params["target_fingerprint"] = .string(targetFingerprint)
        }
        return params
    }

    private func runTask(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl task prepare|run|status|resume|cancel")
        }
        switch subcommand {
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
            throw CLIError.usage("Usage: macctl task prepare|run|status|resume|cancel")
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
        guard args.first == "capabilities" else {
            throw CLIError.usage("Usage: macctl adapter capabilities [--json]")
        }
        return render(sendOrLocal(method: "adapter.capabilities", params: [:], localFallback: true))
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
            guard args.contains("--confirm") else {
                throw CLIError.usage("Usage: macctl keyboard lease acquire --scope app|session [--seconds N] [--suppress-physical-keyboard --reason <text>] --confirm")
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

    private func printHelp() {
        print("""
        macctl — command-first macOS control plane

        macctl doctor --json
        macctl capabilities --json
        macctl status --json
        macctl app list [--json]
        macctl app open <name-or-bundle-id> [--background]
        macctl workflow list|validate|prepare|run <workflow> [--background] [--ephemeral-stdin]
        macctl approval list|approve|deny <token>
        macctl receipts list|status
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
        macctl control capabilities --app <app> [--task <id> --target-fingerprint <fingerprint>]
        macctl control capability-audit --app <app> [--max-nodes N] [--max-depth N]
        macctl control capability-audit-batch --all-applicable [--max-apps N] [--run-id ID]
        macctl control capability-audit-batch --apps <app[,app...]> [--max-apps N]
        macctl control batch --app <app> --actions-stdin --confirm [--task <id> --target-fingerprint <fingerprint>]
        macctl control perform <action> (--lease-token <token> | --app <app> --confirm) [--task <id>] [--route <route>] [selector options]
        macctl control perform context-menu --app <app> --confirm --role <role> [--identifier <id>] [--title <title>] [--window-title <title> | --window-identifier <id>] [--expected-menu-items "Item A,Item B"]
        macctl control perform scroll --app <app> --role AXScrollArea [--identifier <id>] --direction up|down|left|right --amount N [--fallback input-scroll|computer-use] --confirm
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
        macctl accessibility tree --app <app>
        macctl accessibility audit --app <app> --manifest <path>
        macctl ideal-state validate --manifest <path> [--json]
        macctl ideal-state audit --app <app> --manifest <path> [--json]
        macctl task prepare|run|status|resume|cancel
        macctl task prepare --plan-stdin [--json]
        macctl task run|resume --plan-stdin --approval-token <token> [--lease-token <token>]
        macctl task status|cancel <task-id>
        macctl adapter capabilities [--json]
        macctl daemon install|remove|restart|status [--allow-legacy-idle-snapshot]
        macctl logs [--json]
        macctl install [--allow-legacy-idle-snapshot]
        """)
    }
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
