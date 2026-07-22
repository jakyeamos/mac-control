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
            return render(sendOrLocal(method: "app.open", params: ["name": .string(name)], localFallback: false))
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
                throw CLIError.usage("Usage: macctl workflow validate <workflow>")
            }
            return render(sendOrLocal(method: "workflow.validate", params: ["workflow": .string(workflow)], localFallback: true))
        case "prepare":
            guard let workflow = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl workflow prepare <workflow> [--ephemeral-stdin]")
            }
            var params: [String: JSONValue] = ["workflow": .string(workflow)]
            try addEphemeralInputs(from: args, to: &params)
            return render(sendOrLocal(method: "workflow.prepare", params: params, localFallback: false))
        case "run":
            guard let workflow = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl workflow run <workflow> [--approval-token <token>] [--ephemeral-stdin]")
            }
            var params: [String: JSONValue] = ["workflow": .string(workflow)]
            if let tokenIndex = args.firstIndex(of: "--approval-token"), args.indices.contains(tokenIndex + 1) {
                params["approval_token"] = .string(args[tokenIndex + 1])
            }
            try addEphemeralInputs(from: args, to: &params)
            return render(sendOrLocal(method: "workflow.run", params: params, localFallback: false))
        default:
            throw CLIError.usage("Usage: macctl workflow list|validate|prepare|run <workflow> [--ephemeral-stdin]")
        }
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

    private func runIPhone(_ args: [String]) throws -> Int32 {
        guard let subcommand = args.first else {
            throw CLIError.usage("Usage: macctl iphone status|open-app <name>")
        }
        switch subcommand {
        case "status":
            return render(sendOrLocal(method: "iphone.status", params: [:], localFallback: true))
        case "open-app":
            guard let name = args.dropFirst().first else {
                throw CLIError.usage("Usage: macctl iphone open-app <name>")
            }
            return render(sendOrLocal(method: "iphone.open-app", params: ["name": .string(name)], localFallback: false))
        default:
            throw CLIError.usage("Usage: macctl iphone status|open-app <name>")
        }
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
        macctl app open <name-or-bundle-id>
        macctl workflow list|validate|prepare|run <workflow> [--ephemeral-stdin]
        macctl approval list|approve|deny <token>
        macctl receipts list|status
        macctl release check [--json]
        macctl iphone status|open-app <name>
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
