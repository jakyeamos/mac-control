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
            case "logs":
                return render(sendOrLocal(method: "logs", params: [:], localFallback: true))
            case "iphone":
                return try runIPhone(commandArguments)
            case "keyboard":
                return try runKeyboard(commandArguments)
            case "control":
                return try runControl(commandArguments)
            case "task":
                return try runTask(commandArguments)
            case "adapter":
                return try runAdapter(commandArguments)
            case "daemon":
                return try runDaemon(commandArguments)
            case "install":
                return try runInstall()
            case "help", "--help", "-h":
                printHelp()
                return 0
            default:
                throw CLIError.usage("Unknown command: \(command)")
            }
        } catch {
            let response = ResponseEnvelope(
                requestID: UUID().uuidString,
                status: .failed,
                error: MacCtlError(code: "cli_error", message: error.localizedDescription)
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
            throw CLIError.usage("Usage: macctl workflow list|validate|prepare|run <workflow> [--driving-lease <token>]")
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
                throw CLIError.usage("Usage: macctl workflow run <workflow> [--background] [--approval-token <token>] [--driving-lease <token>] [--ephemeral-stdin]")
            }
            var params: [String: JSONValue] = ["workflow": .string(workflow)]
            try addFocusPolicy(from: args, to: &params)
            if let tokenIndex = args.firstIndex(of: "--approval-token"), args.indices.contains(tokenIndex + 1) {
                params["approval_token"] = .string(args[tokenIndex + 1])
            }
            try addDrivingLease(from: args, to: &params)
            try addEphemeralInputs(from: args, to: &params)
            return render(sendOrLocal(method: "workflow.run", params: params, localFallback: false))
        default:
            throw CLIError.usage("Usage: macctl workflow list|validate|prepare|run <workflow> [--background] [--driving-lease <token>] [--ephemeral-stdin]")
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

    private func addDrivingLease(
        from args: [String],
        to params: inout [String: JSONValue]
    ) throws {
        guard let leaseIndex = args.firstIndex(of: "--driving-lease") else { return }
        guard args.indices.contains(leaseIndex + 1) else {
            throw CLIError.usage("--driving-lease requires a lease token")
        }
        params["driving_lease_token"] = .string(args[leaseIndex + 1])
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

    private func runIPhone(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl iphone status|drive begin|drive end <token>|open-app <name> --driving-lease <token>")
        }
        switch subcommand {
        case "status":
            return render(sendOrLocal(method: "iphone.status", params: [:], localFallback: true))
        case "drive":
            guard let action = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl iphone drive begin|end <token>")
            }
            switch action {
            case "begin":
                return render(sendOrLocal(method: "iphone.drive.begin", params: [:], localFallback: false))
            case "end":
                guard let token = args.dropFirst(2).first else {
                    throw CLIError.usage("Usage: macctl iphone drive end <token>")
                }
                return render(sendOrLocal(
                    method: "iphone.drive.end",
                    params: ["driving_lease_token": .string(token)],
                    localFallback: false
                ))
            default:
                throw CLIError.usage("Usage: macctl iphone drive begin|end <token>")
            }
        case "open-app":
            guard let name = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl iphone open-app <name> --driving-lease <token>")
            }
            var params: [String: JSONValue] = ["name": .string(name)]
            try addDrivingLease(from: args, to: &params)
            return render(sendOrLocal(method: "iphone.open-app", params: params, localFallback: false))
        default:
            throw CLIError.usage("Usage: macctl iphone status|drive begin|drive end <token>|open-app <name> --driving-lease <token>")
        }
    }

    private func runKeyboard(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl keyboard status|setup|enable|inspect|lease|navigate|send")
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
            throw CLIError.usage("Usage: macctl keyboard status|setup|enable|inspect|lease|navigate|send")
        }
    }

    private func runControl(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl control status|perform <action> (--lease-token <token> | --app <app> --confirm)")
        }
        switch subcommand {
        case "status":
            return render(sendOrLocal(method: "control.status", params: [:], localFallback: true))
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
            var selector: [String: JSONValue] = [:]
            let stringOptions: [(String, String)] = [
                ("--role", "role"),
                ("--identifier", "identifier"),
                ("--title", "title"),
                ("--subrole", "subrole"),
                ("--contains-text", "containsText"),
                ("--image-anchor", "imageAnchor")
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
            throw CLIError.usage("Usage: macctl control status|perform <action> (--lease-token <token> | --app <app> --confirm)")
        }
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
            guard args.contains("--confirm") else {
                throw CLIError.usage("Usage: macctl keyboard lease acquire --scope app --app \"<name>\" [--seconds N] --confirm")
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

    private func runDaemon(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl daemon install|remove|restart|status")
        }
        let manager = LaunchAgentManager()
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

    private func runInstall() throws -> Int32 {
        let paths = try LaunchAgentManager().installUserBinaries(from: CommandLine.arguments[0])
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
                if let token = response.result.objectValue?["driving_lease_token"]?.stringValue {
                    print("driving lease token: \(token)")
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
        macctl workflow list|validate|prepare|run <workflow> [--background] [--driving-lease <token>] [--ephemeral-stdin]
        macctl approval list|approve|deny <token>
        macctl receipts list|status
        macctl release check [--json]
        macctl iphone status|drive begin|drive end <token>|open-app <name> --driving-lease <token>
        macctl keyboard status|setup|enable --confirm|inspect
        macctl keyboard lease acquire --scope app --app "<name>" [--seconds N] --confirm
        macctl keyboard lease acquire --scope session [--seconds N] --confirm
        macctl keyboard lease release <token>
        macctl keyboard navigate <command> --lease-token <token> [--count N]
        macctl keyboard send <key>... --lease-token <token>
        macctl control status [--json]
        macctl control perform <action> (--lease-token <token> | --app <app> --confirm) [--title <title>] [--role <role>]
        macctl task prepare|run|status|resume|cancel
        macctl task prepare --plan-stdin [--json]
        macctl task run|resume --plan-stdin --approval-token <token> [--lease-token <token>]
        macctl task status|cancel <task-id>
        macctl adapter capabilities [--json]
        macctl daemon install|remove|restart|status
        macctl logs [--json]
        macctl install
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
