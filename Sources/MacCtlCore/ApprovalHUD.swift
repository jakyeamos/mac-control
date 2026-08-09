import AppKit
import Foundation

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

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var displayTimer: Timer?
    private var tokenByOperationID: [String: String] = [:]
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
            self.statusItem = item
            self.capsLockMonitor.onDoubleTap = { [weak self] in
                guard let self, !self.pendingApprovals().isEmpty else { return }
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
    /// activate the app, open the popover, post a notification, or steal focus.
    public func present(_ approval: ApprovalRecord) {
        _ = approval
        refresh()
    }

    public func bringToFront() {
        guard !pendingApprovals().isEmpty else { return }
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
            self.refreshOnMain()
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func refreshOnMain() {
        let approvals = pendingApprovals()
        tokenByOperationID = Dictionary(
            uniqueKeysWithValues: approvals.map { ($0.operationID, $0.token) }
        )
        let snapshot = snapshotHandler?() ?? ControlCenterSnapshot(
            approvals: approvals.map(ControlCenterApproval.init),
            execution: nil,
            permissions: []
        )
        let presentation = ControlCenterPresentation.make(snapshot: snapshot)
        updateStatusItem(presentation)
        if popover.isShown {
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
            case .approval: fill = NSColor.systemOrange.withAlphaComponent(0.92)
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
                if presentation.pendingCount > 0,
                   [.leased, .frozen, .stopping].contains(presentation.state) {
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

        let heading = NSTextField(labelWithString: "Mac Control")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        root.addArrangedSubview(heading)

        let missing = snapshot.permissions.filter { $0.state == "missing" || $0.state == "unknown" }
        let health = missing.isEmpty
            ? "Daemon ready · permissions available"
            : "Needs attention · " + missing.map(\.name).joined(separator: ", ")
        let healthLabel = secondaryLabel(health)
        healthLabel.textColor = missing.isEmpty ? .secondaryLabelColor : .systemRed
        root.addArrangedSubview(healthLabel)

        if let error = actionError {
            let errorLabel = wrappingLabel(error)
            errorLabel.textColor = .systemRed
            root.addArrangedSubview(errorLabel)
        }

        if let execution = snapshot.execution {
            root.addArrangedSubview(separator())
            root.addArrangedSubview(sectionLabel(execution.stopping ? "STOPPING" : "ACTIVE CONTROL"))
            let target = execution.applicationName.map { " · \($0)" } ?? ""
            root.addArrangedSubview(wrappingLabel(execution.summary + target))
            let input = execution.physicalInputMode == .suppressed
                ? "Physical keyboard frozen"
                : "Keyboard shared"
            root.addArrangedSubview(secondaryLabel(
                "\(input) · \(durationLabel(execution.expiresAt.timeIntervalSinceNow)) remaining"
            ))
            let stop = MouseOnlyButton(title: "Stop & Release", target: self, action: #selector(stopAndRelease(_:)))
            stop.bezelStyle = .rounded
            stop.contentTintColor = .systemRed
            stop.setAccessibilityLabel("Stop active Mac Control task and release input authority")
            root.addArrangedSubview(stop)
        }

        root.addArrangedSubview(separator())
        root.addArrangedSubview(sectionLabel("APPROVALS · \(approvals.count)"))
        if approvals.isEmpty {
            root.addArrangedSubview(secondaryLabel("No approvals are waiting."))
        } else {
            for approval in approvals {
                root.addArrangedSubview(approvalRow(approval))
            }
        }

        root.addArrangedSubview(separator())
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill
        let available = secondaryLabel(snapshot.execution == nil ? "Computer available" : "Computer leased")
        footer.addArrangedSubview(available)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)
        let quit = MouseOnlyButton(title: "Quit daemon", target: self, action: #selector(quitDaemon(_:)))
        quit.bezelStyle = .inline
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

    private func approvalRow(_ approval: ApprovalRecord) -> NSView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 5
        card.edgeInsets = NSEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

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
        approve.bezelStyle = .rounded
        approve.keyEquivalent = ""
        approve.setAccessibilityLabel(approvalTitle + ", mouse activation required")
        let deny = MouseOnlyButton(title: "Deny", target: self, action: #selector(deny(_:)))
        deny.identifier = NSUserInterfaceItemIdentifier(approval.operationID)
        deny.bezelStyle = .inline
        deny.keyEquivalent = ""
        deny.setAccessibilityLabel("Deny approval, mouse activation required")
        actions.addArrangedSubview(approve)
        actions.addArrangedSubview(deny)
        card.addArrangedSubview(actions)
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

    @objc private func deny(_ sender: MouseOnlyButton) {
        guard sender.consumeMouseClick(),
              let operationID = sender.identifier?.rawValue,
              let token = tokenByOperationID[operationID] else {
            rejectNonMouse("deny")
            return
        }
        let response = denyHandler?(token)
        actionError = response?.status == .succeeded ? nil : response?.error?.message ?? "Deny failed"
        refresh()
    }

    @objc private func stopAndRelease(_ sender: MouseOnlyButton) {
        guard sender.consumeMouseClick() else {
            rejectNonMouse("stop")
            return
        }
        let response = stopHandler?()
        actionError = response?.status == .succeeded
            ? nil
            : response?.error?.message ?? "Could not stop the active execution"
        refresh()
    }

    @objc private func quitDaemon(_ sender: MouseOnlyButton) {
        guard sender.consumeMouseClick() else {
            rejectNonMouse("quit")
            return
        }
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

    private func onMain(_ operation: @escaping () -> Void) {
        if Thread.isMainThread { operation() } else { DispatchQueue.main.async(execute: operation) }
    }
}
