import AppKit
import Foundation
import UserNotifications

private final class MouseOnlyButton: NSButton {
    private var receivedMouseDown = false

    override func mouseDown(with event: NSEvent) {
        receivedMouseDown = true
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }

    func consumeMouseClick() -> Bool {
        defer { receivedMouseDown = false }
        return receivedMouseDown
    }
}

/// Ambient, state-aware menu-bar control center for approvals and active input authority.
/// Approval tokens remain confined to the private action map and never enter the snapshot,
/// status-item labels, tooltips, or accessibility presentation.
public final class ApprovalHUD: NSObject {
    public var approveHandler: ((String) -> ResponseEnvelope)?
    public var denyHandler: ((String) -> ResponseEnvelope)?
    public var stopHandler: (() -> ResponseEnvelope)?
    public var approvalPendingHandler: ((String) -> Bool)?
    public var pendingApprovalsHandler: (() -> [ApprovalRecord])?
    public var snapshotHandler: (() -> ControlCenterSnapshot)?
    /// A Codex-owned opener may be registered by the host. Arbitrary URLs are
    /// never opened by the HUD; without this callback the source reference is
    /// displayed as informational only.
    public var authorizationSourceOpener: ((String) -> Bool)?

    private var statusItem: NSStatusItem?
    let popover = NSPopover()
    private var displayTimer: Timer?
    private var tokenByOperationID: [String: String] = [:]
    private var sourceByAuthorizationID: [String: String] = [:]
    private var notifiedAuthorizationIDs: Set<String> = []
    private var actionError: String?
    private let capsLockMonitor: CapsLockMonitor

    public init(capsLockMonitor: CapsLockMonitor = CapsLockMonitor()) {
        self.capsLockMonitor = capsLockMonitor
        super.init()
    }

    deinit {
        displayTimer?.invalidate()
        capsLockMonitor.stop()
    }

    public func start() {
        onMain { [weak self] in
            guard let self, self.statusItem == nil else { return }
            NSApplication.shared.setActivationPolicy(.accessory)
            self.popover.behavior = .transient
            self.popover.animates = true
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(self.toggleControlCenter)
            item.button?.sendAction(on: [.leftMouseUp])
            item.button?.setAccessibilityIdentifier("macctl.control-center.status")
            self.statusItem = item
            self.capsLockMonitor.onDoubleTap = { [weak self] in
                guard let self, self.hasAttention() else { return }
                self.showControlCenter()
            }
            _ = self.capsLockMonitor.start()
            self.displayTimer = Timer.scheduledTimer(
                withTimeInterval: 1,
                repeats: true
            ) { [weak self] _ in self?.refresh() }
            self.refresh()
        }
    }

    /// Approval arrivals are ambient. They update the menu-bar item but never
    /// activate the app, open the popover, or steal focus.
    public func present(_ approval: ApprovalRecord) {
        _ = approval
        refresh()
    }

    /// Authorization notices are explanatory alerts. They may produce one
    /// deduplicated local notification when macOS has already authorized
    /// notifications, but they never grant or deny the native request.
    public func present(_ notice: AuthorizationNotice) {
        onMain { [weak self] in
            guard let self else { return }
            self.notifyAuthorizationNoticeIfAuthorized(notice)
            self.refreshOnMain()
        }
    }

    public func bringToFront() {
        guard hasAttention() else { return }
        showControlCenter()
    }

    public func refresh() {
        onMain { [weak self] in self?.refreshOnMain() }
    }

    @objc private func toggleControlCenter() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showControlCenter()
        }
    }

    private func showControlCenter() {
        onMain { [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            // NSPopover raises an Objective-C exception when shown before a
            // content controller exists. Hidden refreshes intentionally avoid
            // rebuilding the view every second, so the click path must force
            // the first content build before presentation.
            self.refreshOnMain(populatePopover: true)
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func refreshOnMain(populatePopover: Bool = false) {
        let approvals = pendingApprovals()
        tokenByOperationID = Dictionary(
            uniqueKeysWithValues: approvals.map { ($0.operationID, $0.token) }
        )
        let snapshot = snapshotHandler?() ?? ControlCenterSnapshot(
            approvals: approvals.map(ControlCenterApproval.init),
            execution: nil,
            permissions: []
        )
        sourceByAuthorizationID = Dictionary(
            uniqueKeysWithValues: snapshot.authorizationNotices.compactMap { notice in
                notice.sourceReference.map { (notice.requestID, $0) }
            }
        )
        let presentation = ControlCenterPresentation.make(snapshot: snapshot)
        updateStatusItem(presentation)
        if populatePopover || popover.isShown {
            popover.contentViewController = makePopover(snapshot: snapshot, approvals: approvals)
        }
    }

    private func pendingApprovals() -> [ApprovalRecord] {
        let now = Date()
        return (pendingApprovalsHandler?() ?? [])
            .filter { $0.expiresAt > now }
            .sorted {
                if $0.expiresAt == $1.expiresAt { return $0.operationID < $1.operationID }
                return $0.expiresAt < $1.expiresAt
            }
    }

    private func updateStatusItem(_ presentation: ControlCenterPresentation) {
        guard let item = statusItem, let button = item.button else { return }
        let compact = presentation.state == .idle
        let width = compact ? 30.0 : min(max(86, CGFloat(presentation.label.count * 7 + 48)), 190)
        item.length = width
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = statusImage(presentation: presentation, size: NSSize(width: width - 4, height: 24))
        button.toolTip = presentation.tooltip
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        button.setAccessibilityHelp("Click to open the macctl control center")
    }

    private func statusImage(
        presentation: ControlCenterPresentation,
        size: NSSize
    ) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let fill: NSColor
            switch presentation.state {
            case .idle: fill = NSColor.controlAccentColor.withAlphaComponent(0.16)
            case .authorization: fill = NSColor.systemRed.withAlphaComponent(0.96)
            case .approval: fill = NSColor.systemOrange.withAlphaComponent(0.92)
            case .focusing: fill = NSColor.systemBlue.withAlphaComponent(0.48)
            case .focused: fill = NSColor.systemBlue.withAlphaComponent(0.62)
            case .handsOff: fill = NSColor.systemBlue.withAlphaComponent(0.92)
            case .leased: fill = NSColor.systemBlue.withAlphaComponent(0.90)
            case .frozen: fill = NSColor.systemPurple.withAlphaComponent(0.92)
            case .stopping, .degraded: fill = NSColor.systemRed.withAlphaComponent(0.90)
            }
            let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 11, yRadius: 11)
            fill.setFill()
            pill.fill()

            let ringRect = NSRect(x: 6, y: 5, width: 14, height: 14)
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let track = NSBezierPath(ovalIn: ringRect)
            track.lineWidth = 2
            track.stroke()
            if let fraction = presentation.ringFraction {
                let ring = NSBezierPath()
                let center = NSPoint(x: ringRect.midX, y: ringRect.midY)
                ring.appendArc(
                    withCenter: center,
                    radius: ringRect.width / 2,
                    startAngle: 90,
                    endAngle: 90 - CGFloat(360 * fraction),
                    clockwise: true
                )
                NSColor.white.setStroke()
                ring.lineWidth = 2
                ring.lineCapStyle = .round
                ring.stroke()
            }

            if presentation.state == .idle {
                NSColor.labelColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.midX - 3, y: rect.midY - 3, width: 6, height: 6)).fill()
            } else {
                let textRect = NSRect(x: 27, y: 4, width: rect.width - 34, height: 16)
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: paragraph
                ]
                (presentation.label as NSString).draw(in: textRect, withAttributes: attributes)
                if presentation.authorizationCount > 0,
                   presentation.state != .authorization {
                    let badgeRect = NSRect(x: rect.maxX - 14, y: rect.maxY - 10, width: 12, height: 10)
                    NSColor.systemRed.setFill()
                    NSBezierPath(roundedRect: badgeRect, xRadius: 5, yRadius: 5).fill()
                } else if presentation.pendingCount > 0,
                          [.focusing, .focused, .handsOff, .leased, .frozen, .stopping].contains(presentation.state) {
                    let badgeRect = NSRect(x: rect.maxX - 14, y: rect.maxY - 10, width: 12, height: 10)
                    NSColor.systemOrange.setFill()
                    NSBezierPath(roundedRect: badgeRect, xRadius: 5, yRadius: 5).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private func makePopover(
        snapshot: ControlCenterSnapshot,
        approvals: [ApprovalRecord]
    ) -> NSViewController {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("macctl.approval.window")
        root.setAccessibilityLabel("Mac Control approval list")

        let heading = NSTextField(labelWithString: "Mac Control")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        root.addArrangedSubview(heading)

        let missing = snapshot.permissions.filter { $0.state == "missing" || $0.state == "unknown" }
        let health = missing.isEmpty
            ? "Daemon ready · permissions available"
            : "Needs attention · " + missing.map(\.name).joined(separator: ", ")
        let healthLabel = secondaryLabel(health)
        healthLabel.setAccessibilityIdentifier("macctl.control-center.health")
        healthLabel.textColor = missing.isEmpty ? .secondaryLabelColor : .systemRed
        root.addArrangedSubview(healthLabel)

        if let error = actionError {
            let errorLabel = wrappingLabel(error)
            errorLabel.textColor = .systemRed
            root.addArrangedSubview(errorLabel)
        }

        let authorizationNotices = snapshot.authorizationNotices.filter {
            $0.state == .pending && $0.expiresAt > Date()
        }
        if !authorizationNotices.isEmpty {
            root.addArrangedSubview(separator())
            root.addArrangedSubview(sectionLabel("AUTHORIZATION REQUESTS · \(authorizationNotices.count)"))
            root.addArrangedSubview(wrappingLabel(
                "A command may be asking macOS for sensitive access. Review the source and native prompt yourself; Mac Control cannot Allow or Deny it."
            ))
            for (index, notice) in authorizationNotices.enumerated() {
                root.addArrangedSubview(authorizationRow(notice))
                if index < authorizationNotices.count - 1 {
                    root.addArrangedSubview(separator())
                }
            }
        }

        let handsOffVisible = (snapshot.handsOffSession?.expiresAt ?? .distantPast) > Date()
            && snapshot.execution?.physicalInputMode != .suppressed
            && snapshot.execution?.stopping != true
        if handsOffVisible, let handsOffSession = snapshot.handsOffSession {
            root.addArrangedSubview(separator())
            root.addArrangedSubview(sectionLabel("HANDS OFF"))
            let target = handsOffSession.applicationName.map { " in \($0)" } ?? ""
            let provider = handsOffSession.provider.replacingOccurrences(of: "_", with: " ")
            root.addArrangedSubview(wrappingLabel(
                "An agent-controlled \(provider) run is active\(target). Do not use the keyboard or trackpad."
            ))
            root.addArrangedSubview(secondaryLabel(
                "\(durationLabel(handsOffSession.expiresAt.timeIntervalSinceNow)) remaining · heartbeat required"
            ))
            let stop = NSButton(title: "Stop & Release", target: self, action: #selector(stopAndRelease(_:)))
            stop.bezelStyle = .rounded
            stop.focusRingType = .none
            stop.contentTintColor = .systemRed
            stop.setAccessibilityLabel("Stop the hands-off Mac Control run and release input authority")
            root.addArrangedSubview(stop)
        } else if let execution = snapshot.execution {
            root.addArrangedSubview(separator())
            let isFocused = execution.focusPolicy == .foreground && execution.applicationName != nil && !execution.stopping
            root.addArrangedSubview(sectionLabel(
                execution.stopping ? "STOPPING" : (isFocused ? "FOCUSED CONTROL" : "ACTIVE CONTROL")
            ))
            let target = execution.applicationName.map { " · \($0)" } ?? ""
            root.addArrangedSubview(wrappingLabel(execution.summary + target))
            let input = execution.physicalInputMode == .suppressed
                ? "Physical keyboard frozen"
                : "Keyboard shared"
            root.addArrangedSubview(secondaryLabel(
                "\(input) · \(durationLabel(execution.expiresAt.timeIntervalSinceNow)) remaining"
            ))
            if let progress = execution.taskProgress {
                root.addArrangedSubview(taskProgressView(progress))
            }
            let stop = NSButton(title: "Stop & Release", target: self, action: #selector(stopAndRelease(_:)))
            stop.bezelStyle = .rounded
            stop.focusRingType = .none
            stop.contentTintColor = .systemRed
            stop.setAccessibilityLabel("Stop active Mac Control task and release input authority")
            root.addArrangedSubview(stop)
        } else if let focusActivity = snapshot.focusActivity, focusActivity.expiresAt > Date() {
            root.addArrangedSubview(separator())
            let focused = focusActivity.phase == .focused
            root.addArrangedSubview(sectionLabel(focused ? "FOCUSED" : "FOCUSING"))
            root.addArrangedSubview(wrappingLabel(
                "Mac Control is \(focused ? "focused on" : "moving focus to") \(focusActivity.applicationName)."
            ))
            root.addArrangedSubview(secondaryLabel("The foreground app may change during this test."))
        }

        if snapshot.execution == nil,
           let outcome = snapshot.taskOutcome,
           outcome.expiresAt > Date() {
            root.addArrangedSubview(separator())
            root.addArrangedSubview(sectionLabel(
                outcome.progress.state == .completed ? "TASK COMPLETED" : "TASK STOPPED"
            ))
            let target = outcome.applicationName.map { " · \($0)" } ?? ""
            root.addArrangedSubview(wrappingLabel(outcome.summary + target))
            root.addArrangedSubview(taskProgressView(outcome.progress))
        }

        root.addArrangedSubview(separator())
        let approvalHeading = sectionLabel("APPROVALS · \(approvals.count)")
        approvalHeading.setAccessibilityIdentifier("macctl.approval.count")
        root.addArrangedSubview(approvalHeading)
        if approvals.isEmpty {
            root.addArrangedSubview(secondaryLabel("No approvals are waiting."))
        } else {
            for (index, approval) in approvals.enumerated() {
                root.addArrangedSubview(approvalRow(approval))
                if index < approvals.count - 1 {
                    root.addArrangedSubview(separator())
                }
            }
        }

        root.addArrangedSubview(separator())
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill
        let available = secondaryLabel(
            snapshot.execution == nil && snapshot.handsOffSession == nil
                ? "Computer available"
                : "Computer controlled"
        )
        footer.addArrangedSubview(available)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)
        let quit = NSButton(title: "Quit daemon", target: self, action: #selector(quitDaemon(_:)))
        quit.bezelStyle = .inline
        quit.focusRingType = .none
        footer.addArrangedSubview(quit)
        root.addArrangedSubview(footer)

        let controller = NSViewController()
        controller.view = root
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 360)
        ])
        root.layoutSubtreeIfNeeded()
        let contentHeight = min(max(root.fittingSize.height, 180), 620)
        controller.preferredContentSize = NSSize(width: 392, height: contentHeight)
        return controller
    }

    private func taskProgressView(_ progress: ControlCenterTaskProgress) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.setAccessibilityIdentifier("macctl.task.progress")
        stack.setAccessibilityLabel(
            "Task progress, \(progress.completedStepCount) of \(progress.totalStepCount) steps verified"
        )

        let heading = sectionLabel(
            "PROGRESS · \(progress.completedStepCount) OF \(progress.totalStepCount) VERIFIED"
        )
        heading.setAccessibilityIdentifier("macctl.task.progress.count")
        stack.addArrangedSubview(heading)

        for step in progress.steps {
            let marker: String
            switch step.state {
            case .pending: marker = "○"
            case .running: marker = "◉"
            case .verified: marker = "✓"
            case .stopped: marker = "■"
            }
            let row = secondaryLabel("\(marker) \(step.label) · \(step.state.rawValue.capitalized)")
            row.setAccessibilityIdentifier("macctl.task.progress.\(step.stepID)")
            row.setAccessibilityLabel("\(step.label), \(step.state.rawValue)")
            if step.state == .stopped { row.textColor = .systemRed }
            stack.addArrangedSubview(row)
        }

        if let errorCode = progress.lastErrorCode {
            let message = "Stopped safely · " + errorCode
                .replacingOccurrences(of: "_", with: " ")
            let error = secondaryLabel(message)
            error.textColor = .systemRed
            error.setAccessibilityIdentifier("macctl.task.progress.error")
            stack.addArrangedSubview(error)
        }
        return stack
    }

    private func approvalRow(_ approval: ApprovalRecord) -> NSView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 5
        // The popover already supplies the system material. Keep queue rows
        // transparent so we do not stack an opaque card over that glass; use
        // rhythm and hairline separators for grouping instead.
        card.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)

        let title = wrappingLabel(approval.summary)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        card.addArrangedSubview(title)
        var detail = "\(approval.risk.rawValue.capitalized) · expires in \(durationLabel(approval.expiresAt.timeIntervalSinceNow))"
        if approval.keyboardFreezeRequired { detail += " · keyboard freeze approved" }
        card.addArrangedSubview(secondaryLabel(detail))

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 7
        let approvalTitle = approval.handoffTarget.map { "Approve & Focus \($0.applicationName)" } ?? "Approve"
        let approve = MouseOnlyButton(title: approvalTitle, target: self, action: #selector(approve(_:)))
        approve.identifier = NSUserInterfaceItemIdentifier(approval.operationID)
        approve.setAccessibilityIdentifier("macctl.approval.approve.\(approval.operationID)")
        approve.bezelStyle = .rounded
        approve.focusRingType = .none
        approve.keyEquivalent = ""
        approve.setAccessibilityLabel(approvalTitle + ", mouse activation required")
        let deny = NSButton(title: "Deny", target: self, action: #selector(deny(_:)))
        deny.identifier = NSUserInterfaceItemIdentifier(approval.operationID)
        deny.setAccessibilityIdentifier("macctl.approval.deny.\(approval.operationID)")
        deny.bezelStyle = .inline
        deny.focusRingType = .none
        deny.keyEquivalent = ""
        deny.setAccessibilityLabel("Deny approval")
        actions.addArrangedSubview(approve)
        actions.addArrangedSubview(deny)
        card.addArrangedSubview(actions)
        return card
    }

    private func authorizationRow(_ notice: AuthorizationNotice) -> NSView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 5
        card.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)

        let title = wrappingLabel(notice.summary)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = notice.provenance == .unverified ? .systemRed : .labelColor
        card.addArrangedSubview(title)

        var details = ["Project: \(notice.project)"]
        if let repository = notice.repository { details.append("Repository: \(repository)") }
        if let task = notice.taskID ?? notice.taskTitle {
            details.append("Task: \(task)")
        }
        if let thread = notice.threadID ?? notice.threadTitle {
            details.append("Thread: \(thread)")
        }
        details.append("Requesting: \(notice.requestingExecutable ?? "unknown executable")")
        if let helper = notice.requestingHelper { details.append("Helper: \(helper)") }
        if let observed = notice.observedIdentity {
            var peer = observed.executableName ?? "unknown executable"
            if let processID = observed.processID { peer += " · PID \(processID)" }
            details.append("Observed socket peer: \(peer)")
        }
        if let target = notice.targetService { details.append("Target: \(target)") }
        details.append("Action: \(notice.action)")
        details.append(
            "Expires in \(durationLabel(notice.expiresAt.timeIntervalSinceNow)) · provenance: \(notice.provenance.rawValue.uppercased())"
        )
        let detail = wrappingLabel(details.joined(separator: "\n"))
        detail.textColor = notice.provenance == .unverified ? .systemRed : .secondaryLabelColor
        card.addArrangedSubview(detail)

        if let sourceReference = notice.sourceReference {
            card.addArrangedSubview(secondaryLabel("Source: \(sourceReference)"))
            if authorizationSourceOpener != nil {
                let open = NSButton(title: "Open source", target: self, action: #selector(openAuthorizationSource(_:)))
                open.identifier = NSUserInterfaceItemIdentifier(notice.requestID)
                open.bezelStyle = .inline
                open.focusRingType = .none
                open.keyEquivalent = ""
                open.setAccessibilityLabel("Open registered Codex source for authorization request")
                card.addArrangedSubview(open)
            } else {
                card.addArrangedSubview(secondaryLabel(
                    "Open source unavailable: no registered Codex opener is configured."
                ))
            }
        } else {
            card.addArrangedSubview(secondaryLabel("Source reference unavailable."))
        }
        return card
    }

    @objc private func approve(_ sender: MouseOnlyButton) {
        guard sender.consumeMouseClick(),
              let operationID = sender.identifier?.rawValue,
              let token = tokenByOperationID[operationID] else {
            rejectNonMouse("approve")
            return
        }
        let response = approveHandler?(token)
        actionError = response?.status == .succeeded
            ? nil
            : response?.error?.message ?? "Approval failed; the request remains pending"
        refresh()
    }

    @objc private func deny(_ sender: NSButton) {
        guard let operationID = sender.identifier?.rawValue,
              let token = tokenByOperationID[operationID] else {
            actionError = "Deny failed because the approval is no longer pending"
            refresh()
            return
        }
        let response = denyHandler?(token)
        actionError = response?.status == .succeeded ? nil : response?.error?.message ?? "Deny failed"
        refresh()
    }

    @objc private func stopAndRelease(_ sender: NSButton) {
        _ = sender
        let response = stopHandler?()
        actionError = response?.status == .succeeded
            ? nil
            : response?.error?.message ?? "Could not stop the active execution"
        refresh()
    }

    @objc private func openAuthorizationSource(_ sender: NSButton) {
        guard let requestID = sender.identifier?.rawValue,
              let source = sourceByAuthorizationID[requestID] else {
            actionError = "Source opening is unavailable because the registered reference is missing"
            refresh()
            return
        }
        actionError = authorizationSourceOpener?(source) == true
            ? nil
            : "Source opening was unavailable through the registered Codex opener"
        refresh()
    }

    @objc private func quitDaemon(_ sender: NSButton) {
        _ = sender
        NSApplication.shared.terminate(nil)
    }

    private func rejectNonMouse(_ action: String) {
        SafeLog().record(
            event: "control_center_rejected",
            metadata: ["action": action, "reason": "non_mouse"]
        )
    }

    static func shouldDismissAfterAction(
        response: ResponseEnvelope,
        approvalIsPending: Bool?
    ) -> Bool {
        response.status == .succeeded || approvalIsPending == false
    }

    private func sectionLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func secondaryLabel(_ value: String) -> NSTextField {
        let label = wrappingLabel(value)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func wrappingLabel(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(ceil(seconds)))
        return value >= 60 ? "\(value / 60)m \(value % 60)s" : "\(value)s"
    }

    private func hasAttention() -> Bool {
        let snapshot = snapshotHandler?()
        return !pendingApprovals().isEmpty || snapshot?.authorizationNotices.contains {
            $0.state == .pending && $0.expiresAt > Date()
        } == true
    }

    private func notifyAuthorizationNoticeIfAuthorized(_ notice: AuthorizationNotice) {
        guard !notifiedAuthorizationIDs.contains(notice.requestID) else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self,
                  [.authorized, .provisional].contains(settings.authorizationStatus) else {
                return
            }
            DispatchQueue.main.async {
                guard !self.notifiedAuthorizationIDs.contains(notice.requestID) else { return }
                self.notifiedAuthorizationIDs.insert(notice.requestID)
            }
            let content = UNMutableNotificationContent()
            content.title = "Sensitive request needs your attention"
            let target = notice.targetService.map { " for \($0)" } ?? ""
            content.body = "\(notice.project): \(notice.action)\(target). Review Mac Control for provenance; macOS Allow/Deny remains yours."
            content.sound = .default
            content.threadIdentifier = "macctl-authorization"
            let request = UNNotificationRequest(
                identifier: "macctl.authorization.\(notice.requestID)",
                content: content,
                trigger: nil
            )
            center.add(request) { [weak self] error in
                guard let self, error != nil else { return }
                DispatchQueue.main.async {
                    self.notifiedAuthorizationIDs.remove(notice.requestID)
                }
            }
        }
    }

    private func onMain(_ operation: @escaping () -> Void) {
        if Thread.isMainThread { operation() } else { DispatchQueue.main.async(execute: operation) }
    }
}
