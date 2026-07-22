import Foundation

public struct MacCtlCodeSigningIdentity: Codable, Equatable {
    public let hash: String
    public let name: String

    public init(hash: String, name: String) {
        self.hash = hash
        self.name = name
    }
}

public struct MacCtlCodeSignature: Codable, Equatable {
    public let valid: Bool
    public let identity: String?
    public let teamIdentifier: String?
    public let bundleIdentifier: String?

    public init(
        valid: Bool,
        identity: String? = nil,
        teamIdentifier: String? = nil,
        bundleIdentifier: String? = nil
    ) {
        self.valid = valid
        self.identity = identity
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifier = bundleIdentifier
    }

    public static let unavailable = MacCtlCodeSignature(valid: false)
}

public enum MacCtlCodeSigningError: Error, LocalizedError, Equatable {
    case securityUnavailable
    case noValidIdentity
    case configuredIdentityUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .securityUnavailable:
            return "The macOS security tool could not enumerate code-signing identities"
        case .noValidIdentity:
            return "No valid persistent code-signing identity is available; install an Apple Development or Developer ID Application certificate"
        case .configuredIdentityUnavailable(let value):
            return "The configured macctl code-signing identity is not available: \(value)"
        }
    }
}

public enum MacCtlCodeSigning {
    public static let environmentVariable = "MACCTL_CODESIGN_IDENTITY"

    public static func parseIdentities(_ output: String) -> [MacCtlCodeSigningIdentity] {
        let pattern = try? NSRegularExpression(
            pattern: #"^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.*)"\s*$"#
        )
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let pattern else { return nil }
            let value = String(line)
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = pattern.firstMatch(in: value, range: range),
                  match.numberOfRanges == 3,
                  let hashRange = Range(match.range(at: 1), in: value),
                  let nameRange = Range(match.range(at: 2), in: value) else {
                return nil
            }
            return MacCtlCodeSigningIdentity(
                hash: String(value[hashRange]).uppercased(),
                name: String(value[nameRange])
            )
        }
    }

    public static func preferredIdentity(
        from identities: [MacCtlCodeSigningIdentity]
    ) -> MacCtlCodeSigningIdentity? {
        identities.first(where: { $0.name.hasPrefix("Apple Development:") })
            ?? identities.first(where: { $0.name.hasPrefix("Developer ID Application:") })
            ?? identities.first
    }

    public static func resolve() throws -> MacCtlCodeSigningIdentity {
        let identities = try availableIdentities()
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment[environmentVariable], !configured.isEmpty {
            guard let identity = matchingIdentity(configured, in: identities) else {
                throw MacCtlCodeSigningError.configuredIdentityUnavailable(configured)
            }
            try persist(identity)
            return identity
        }

        if let persisted = loadPersistedIdentity(),
           let identity = identities.first(where: {
               $0.hash.caseInsensitiveCompare(persisted.hash) == .orderedSame
           }) {
            return identity
        }

        guard let identity = preferredIdentity(from: identities) else {
            throw MacCtlCodeSigningError.noValidIdentity
        }
        try persist(identity)
        return identity
    }

    public static func inspect(bundleURL: URL) -> MacCtlCodeSignature {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            return .unavailable
        }
        guard let verification = try? ProcessRunner.run(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", bundleURL.path],
            timeout: 10
        ), verification.status == 0 else {
            return MacCtlCodeSignature(valid: false)
        }
        guard let details = try? ProcessRunner.run(
            executable: "/usr/bin/codesign",
            arguments: ["-dvvv", bundleURL.path],
            timeout: 10
        ) else {
            return MacCtlCodeSignature(valid: true)
        }
        let text = details.stdout + "\n" + details.stderr
        return MacCtlCodeSignature(
            valid: true,
            identity: authorityFields(in: text).first(where: {
                !$0.contains("Worldwide Developer Relations") && !$0.contains("Apple Root CA")
            }),
            teamIdentifier: field("TeamIdentifier", in: text),
            bundleIdentifier: field("Identifier", in: text)
        )
    }

    private static func availableIdentities() throws -> [MacCtlCodeSigningIdentity] {
        guard let result = try? ProcessRunner.run(
            executable: "/usr/bin/security",
            arguments: ["find-identity", "-v", "-p", "codesigning"],
            timeout: 10
        ), result.status == 0 else {
            throw MacCtlCodeSigningError.securityUnavailable
        }
        let identities = parseIdentities(result.stdout)
        guard !identities.isEmpty else {
            throw MacCtlCodeSigningError.noValidIdentity
        }
        return identities
    }

    private static func matchingIdentity(
        _ value: String,
        in identities: [MacCtlCodeSigningIdentity]
    ) -> MacCtlCodeSigningIdentity? {
        identities.first(where: {
            $0.hash.caseInsensitiveCompare(value) == .orderedSame || $0.name == value
        })
    }

    private static func loadPersistedIdentity() -> MacCtlCodeSigningIdentity? {
        guard let data = try? Data(contentsOf: MacCtlPaths.signingIdentityURL) else {
            return nil
        }
        return try? JSONCodec.decode(MacCtlCodeSigningIdentity.self, from: data)
    }

    private static func persist(_ identity: MacCtlCodeSigningIdentity) throws {
        try MacCtlPaths.ensureDirectories()
        let data = try JSONCodec.encode(identity)
        try data.write(to: MacCtlPaths.signingIdentityURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: MacCtlPaths.signingIdentityURL.path
        )
    }

    private static func authorityFields(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let value = String(line)
            guard value.hasPrefix("Authority=") else { return nil }
            return String(value.dropFirst("Authority=".count))
        }
    }

    private static func field(_ name: String, in text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let value = String(line)
            let prefix = "\(name)="
            guard value.hasPrefix(prefix) else { return nil }
            return String(value.dropFirst(prefix.count))
        }.first
    }
}
