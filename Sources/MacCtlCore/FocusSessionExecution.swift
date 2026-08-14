import AppKit
import CryptoKit
import Foundation

public enum FocusSessionExecutionOperation: String, Equatable {
    case openBrief = "document.open-focus-brief"
    case openScratchpad = "document.open-focus-scratchpad"
    case arrangeWorkspace = "workspace.arrange-focus-session"

    var expectedRoute: AppAdapterRoute {
        switch self {
        case .openBrief, .openScratchpad: return .native
        case .arrangeWorkspace: return .accessibility
        }
    }
}

public struct FocusSessionExecutionRequest: Equatable {
    public let operation: FocusSessionExecutionOperation
    public let displayID: UInt32?
    public let layout: FocusSessionLayoutName?

    public init(
        operation: FocusSessionExecutionOperation,
        displayID: UInt32? = nil,
        layout: FocusSessionLayoutName? = nil
    ) throws {
        if operation == .arrangeWorkspace, displayID == nil || layout == nil {
            throw FocusSessionExecutionError.invalidDisplayTarget
        }
        self.operation = operation
        self.displayID = displayID
        self.layout = layout
    }

    public init(operation: FocusSessionExecutionOperation, parameters: [String: JSONValue]) throws {
        let rawDisplayID = parameters["display_id"]?.intValue
        let displayID = rawDisplayID.flatMap(UInt32.init(exactly:))
        let layout = parameters["layout_name"]?.stringValue.flatMap(FocusSessionLayoutName.init(rawValue:))
        try self.init(operation: operation, displayID: displayID, layout: layout)
    }
}

public struct FocusSessionExecutionResult: Equatable {
    public let route: AppAdapterRoute
    public let applicationBundleID: String
    public let fixtureDigest: String?

    public init(route: AppAdapterRoute, applicationBundleID: String, fixtureDigest: String? = nil) {
        self.route = route
        self.applicationBundleID = applicationBundleID
        self.fixtureDigest = fixtureDigest
    }
}

/// Matches a live focused window to a product-owned fixture without retaining
/// raw Accessibility values. AXDocument is authoritative when available;
/// exact title-digest equality is the fail-closed fallback for apps such as
/// TextEdit that may omit AXDocument on an otherwise visible document window.
public enum FocusSessionFixtureWindowIdentity {
    public static func matches(
        expectedURL: URL,
        observedDocumentURL: URL?,
        observedWindowTitle: String?
    ) -> Bool {
        if observedDocumentURL?.standardizedFileURL == expectedURL.standardizedFileURL {
            return true
        }
        guard let observedWindowTitle, !observedWindowTitle.isEmpty else {
            return false
        }
        return digest(observedWindowTitle) == digest(expectedURL.lastPathComponent)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum FocusSessionVerificationPoll {
    public static func untilVerified(
        maximumAttempts: Int = 20,
        interval: TimeInterval = 0.1,
        sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        observe: () throws -> Bool
    ) rethrows -> Bool {
        let attempts = max(1, maximumAttempts)
        for index in 0..<attempts {
            if try observe() { return true }
            if index + 1 < attempts { sleep(interval) }
        }
        return false
    }
}

public protocol FocusSessionActionExecuting {
    func execute(_ request: FocusSessionExecutionRequest) throws -> FocusSessionExecutionResult
    func verify(_ request: FocusSessionExecutionRequest) throws -> Bool
}

public enum FocusSessionExecutionError: Error, LocalizedError, Equatable {
    case applicationUnavailable(String)
    case fixtureCreationFailed
    case fixtureOpenFailed
    case windowUnavailable(String)
    case invalidDisplayTarget
    case layoutVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .applicationUnavailable(let bundleID):
            return "Focus-session application is unavailable: \(bundleID)"
        case .fixtureCreationFailed:
            return "The public-safe focus-session fixture could not be created"
        case .fixtureOpenFailed:
            return "The public-safe focus-session fixture could not be opened"
        case .windowUnavailable(let bundleID):
            return "The focus-session window is unavailable: \(bundleID)"
        case .invalidDisplayTarget:
            return "The focus-session layout requires an explicit connected display ID and named layout"
        case .layoutVerificationFailed:
            return "The focus-session layout could not be verified"
        }
    }
}

/// Executes only the three product-owned focus-session effects. It accepts no
/// caller-provided path, content, application, or frame.
public final class SystemFocusSessionActionExecutor: FocusSessionActionExecuting {
    private let workspace: NSWorkspace
    private let accessibilityController: AccessibilityController
    private let fixtureDirectory: URL
    private let displayProvider: FocusSessionDisplayProviding

    public init(
        workspace: NSWorkspace = .shared,
        accessibilityController: AccessibilityController,
        displayProvider: FocusSessionDisplayProviding = SystemFocusSessionDisplayProvider(),
        fixtureDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macctl-public-focus-session-v1", isDirectory: true)
    ) {
        self.workspace = workspace
        self.accessibilityController = accessibilityController
        self.displayProvider = displayProvider
        self.fixtureDirectory = fixtureDirectory
    }

    public func execute(_ request: FocusSessionExecutionRequest) throws -> FocusSessionExecutionResult {
        switch request.operation {
        case .openBrief:
            let fixture = try materializeBrief()
            try open(fixture.url, withBundleID: FocusSessionVerifier.previewBundleID)
            return FocusSessionExecutionResult(
                route: .native,
                applicationBundleID: FocusSessionVerifier.previewBundleID,
                fixtureDigest: fixture.digest
            )
        case .openScratchpad:
            let fixture = try materializeScratchpad()
            try open(fixture.url, withBundleID: FocusSessionVerifier.textEditBundleID)
            return FocusSessionExecutionResult(
                route: .native,
                applicationBundleID: FocusSessionVerifier.textEditBundleID,
                fixtureDigest: fixture.digest
            )
        case .arrangeWorkspace:
            try arrangeWorkspace(request)
            return FocusSessionExecutionResult(
                route: .accessibility,
                applicationBundleID: FocusSessionVerifier.previewBundleID
            )
        }
    }

    public func verify(_ request: FocusSessionExecutionRequest) throws -> Bool {
        switch request.operation {
        case .openBrief:
            let fixture = try materializeBrief()
            return try verifyOpenFixture(
                fixture.url,
                digest: fixture.digest,
                bundleID: FocusSessionVerifier.previewBundleID
            )
        case .openScratchpad:
            let fixture = try materializeScratchpad()
            return try verifyOpenFixture(
                fixture.url,
                digest: fixture.digest,
                bundleID: FocusSessionVerifier.textEditBundleID
            )
        case .arrangeWorkspace:
            guard let displayID = request.displayID, let layout = request.layout else { return false }
            let display = try FocusSessionDisplayResolver.resolve(
                id: displayID,
                from: displayProvider.connectedDisplays()
            )
            let targets = FocusSessionLayoutResolver.targetFrames(
                layout: layout,
                visibleFrame: display.visibleFrame
            )
            let briefPID = try runningPID(bundleID: FocusSessionVerifier.previewBundleID)
            let scratchpadPID = try runningPID(bundleID: FocusSessionVerifier.textEditBundleID)
            let briefFixture = try materializeBrief()
            let scratchpadFixture = try materializeScratchpad()
            guard let brief = try accessibilityController.fixtureWindowBounds(
                pid: briefPID,
                expectedURL: briefFixture.url,
                expectedTitleDigest: fixtureTitleDigest(briefFixture.url)
            ), let scratchpad = try accessibilityController.fixtureWindowBounds(
                pid: scratchpadPID,
                expectedURL: scratchpadFixture.url,
                expectedTitleDigest: fixtureTitleDigest(scratchpadFixture.url)
            ) else {
                return false
            }
            return approximatelyEqual(brief, cgRect(targets.brief))
                && approximatelyEqual(scratchpad, cgRect(targets.scratchpad))
        }
    }

    private func materializeBrief() throws -> (url: URL, digest: String) {
        try prepareFixtureDirectory()
        let url = fixtureDirectory.appendingPathComponent("Synthetic Research Brief.png")
        let size = NSSize(width: 1200, height: 800)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.91, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let title = "SYNTHETIC RESEARCH BRIEF"
        let body = "Question\nHow should a small team evaluate an AI-assisted workflow?\n\nSuccess criteria\n• Observable outcome\n• Human review boundary\n• Reproducible evidence\n\nPublic-safe demonstration fixture — no customer or private data"
        title.draw(
            at: NSPoint(x: 72, y: 680),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 28, weight: .bold),
                .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)
            ]
        )
        body.draw(
            in: NSRect(x: 72, y: 180, width: 960, height: 440),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 24),
                .foregroundColor: NSColor(calibratedWhite: 0.18, alpha: 1)
            ]
        )
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw FocusSessionExecutionError.fixtureCreationFailed
        }
        try data.write(to: url, options: .atomic)
        return (url, digest(data))
    }

    private func materializeScratchpad() throws -> (url: URL, digest: String) {
        try prepareFixtureDirectory()
        let url = fixtureDirectory.appendingPathComponent("Synthetic Research Scratchpad.txt")
        let data = Data("""
        SYNTHETIC RESEARCH SCRATCHPAD

        Evidence observed:
        -

        Human review:
        -

        Limitations:
        -

        Public-safe demonstration fixture — no customer or private data
        """.utf8)
        try data.write(to: url, options: .atomic)
        return (url, digest(data))
    }

    private func prepareFixtureDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: fixtureDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw FocusSessionExecutionError.fixtureCreationFailed
        }
    }

    private func open(_ fixtureURL: URL, withBundleID bundleID: String) throws {
        guard let applicationURL = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            throw FocusSessionExecutionError.applicationUnavailable(bundleID)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        let completion = DispatchSemaphore(value: 0)
        var openError: Error?
        workspace.open([fixtureURL], withApplicationAt: applicationURL, configuration: configuration) { _, error in
            openError = error
            completion.signal()
        }
        guard completion.wait(timeout: .now() + 8) == .success, openError == nil else {
            throw FocusSessionExecutionError.fixtureOpenFailed
        }
    }

    private func arrangeWorkspace(_ request: FocusSessionExecutionRequest) throws {
        guard let displayID = request.displayID, let layout = request.layout else {
            throw FocusSessionExecutionError.invalidDisplayTarget
        }
        let display = try FocusSessionDisplayResolver.resolve(
            id: displayID,
            from: displayProvider.connectedDisplays()
        )
        let targets = FocusSessionLayoutResolver.targetFrames(
            layout: layout,
            visibleFrame: display.visibleFrame
        )
        let briefPID = try runningPID(bundleID: FocusSessionVerifier.previewBundleID)
        let scratchpadPID = try runningPID(bundleID: FocusSessionVerifier.textEditBundleID)
        let briefFixture = try materializeBrief()
        let scratchpadFixture = try materializeScratchpad()
        try accessibilityController.setFixtureWindowFrame(
            pid: briefPID,
            expectedURL: briefFixture.url,
            expectedTitleDigest: fixtureTitleDigest(briefFixture.url),
            frame: cgRect(targets.brief)
        )
        try accessibilityController.setFixtureWindowFrame(
            pid: scratchpadPID,
            expectedURL: scratchpadFixture.url,
            expectedTitleDigest: fixtureTitleDigest(scratchpadFixture.url),
            frame: cgRect(targets.scratchpad)
        )
    }

    private func verifyOpenFixture(_ url: URL, digest expectedDigest: String, bundleID: String) throws -> Bool {
        guard let data = try? Data(contentsOf: url), digest(data) == expectedDigest else { return false }
        return try FocusSessionVerificationPoll.untilVerified {
            do {
                let pid = try runningPID(bundleID: bundleID)
                return try accessibilityController.fixtureWindowBounds(
                    pid: pid,
                    expectedURL: url,
                    expectedTitleDigest: fixtureTitleDigest(url)
                ) != nil
            } catch AccessibilityControllerError.elementNotFound {
                return false
            } catch FocusSessionExecutionError.windowUnavailable {
                return false
            } catch {
                throw error
            }
        }
    }

    private func cgRect(_ frame: FocusSessionWindowFrame) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    private func approximatelyEqual(_ observed: CGRect, _ expected: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(observed.minX - expected.minX) <= tolerance
            && abs(observed.minY - expected.minY) <= tolerance
            && abs(observed.width - expected.width) <= tolerance
            && abs(observed.height - expected.height) <= tolerance
    }

    private func runningPID(bundleID: String) throws -> pid_t {
        guard let application = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }) else {
            throw FocusSessionExecutionError.windowUnavailable(bundleID)
        }
        return application.processIdentifier
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fixtureTitleDigest(_ url: URL) -> String {
        digest(Data(url.lastPathComponent.utf8))
    }
}
