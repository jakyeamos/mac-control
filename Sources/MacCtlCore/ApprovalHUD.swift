import AppKit
import Foundation

/// Transient menu-bar safety surface for active Mac Control authority.
/// It stays hidden while idle and never presents approvals, general attention,
/// focus announcements, or completed task history.
public final class ApprovalHUD: NSObject {
    public var stopHandler: (() -> ResponseEnvelope)?
    public var snapshotHandler: (() -> ControlCenterSnapshot)?

    private var statusItem: NSStatusItem?
    let popover = NSPopover()
    private var displayTimer: Timer?
    private var actionError: String?

    public override init() { super.init() }

    deinit {
        displayTimer?.invalidate()
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
            item.button?.setAccessibilityIdentifier("macctl.control-safety.status")
            item.isVisible = false
            self.statusItem = item
            self.displayTimer = Timer.scheduledTimer(
                withTimeInterval: 1,
                repeats: true
            ) { [weak self] _ in self?.refresh() }
            self.refresh()
        }
    }

    public func bringToFront() {
        guard statusItem?.isVisible == true else { return }
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
        let snapshot = snapshotHandler?() ?? ControlCenterSnapshot(
            approvals: [],
            execution: nil,
            permissions: []
        )
        let presentation = ControlCenterPresentation.make(snapshot: snapshot)
        updateStatusItem(presentation)
        if presentation.showsStatusItem && (populatePopover || popover.isShown) {
            popover.contentViewController = makePopover(snapshot: snapshot)
        } else if !presentation.showsStatusItem && popover.isShown {
            popover.performClose(nil)
        }
    }

    private func updateStatusItem(_ presentation: ControlCenterPresentation) {
        guard let item = statusItem, let button = item.button else { return }
        item.isVisible = presentation.showsStatusItem
        guard presentation.showsStatusItem else { return }
        let width = min(max(86, CGFloat(presentation.label.count * 7 + 48)), 190)
        item.length = width
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = statusImage(presentation: presentation, size: NSSize(width: width - 4, height: 24))
        button.toolTip = presentation.tooltip
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        button.setAccessibilityHelp("Click to open Mac Control safety controls")
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
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private func makePopover(snapshot: ControlCenterSnapshot) -> NSViewController {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("macctl.control-safety.window")
        root.setAccessibilityLabel("Mac Control safety controls")

        let heading = NSTextField(labelWithString: "Mac Control")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        root.addArrangedSubview(heading)

        let missing = snapshot.permissions.filter { $0.state == "missing" || $0.state == "unknown" }
        let health = missing.isEmpty
            ? "Daemon ready · permissions available"
            : "Needs attention · " + missing.map(\.name).joined(separator: ", ")
        let healthLabel = secondaryLabel(health)
        healthLabel.setAccessibilityIdentifier("macctl.control-safety.health")
        healthLabel.textColor = missing.isEmpty ? .secondaryLabelColor : .systemRed
        root.addArrangedSubview(healthLabel)

        if let error = actionError {
            let errorLabel = wrappingLabel(error)
            errorLabel.textColor = .systemRed
            root.addArrangedSubview(errorLabel)
        }

        if let drain = snapshot.lifecycleDrain, drain.expiresAt > Date() {
            root.addArrangedSubview(separator())
            root.addArrangedSubview(sectionLabel("DAEMON LIFECYCLE"))
            root.addArrangedSubview(wrappingLabel(
                "Mac Control is \(drain.operation == .upgrade ? "updating" : "restarting") after draining active authority."
            ))
            root.addArrangedSubview(secondaryLabel(
                "\(durationLabel(drain.expiresAt.timeIntervalSinceNow)) remaining"
            ))
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

    @objc private func stopAndRelease(_ sender: NSButton) {
        _ = sender
        let response = stopHandler?()
        actionError = response?.status == .succeeded
            ? nil
            : response?.error?.message ?? "Could not stop the active execution"
        refresh()
    }

    @objc private func quitDaemon(_ sender: NSButton) {
        _ = sender
        NSApplication.shared.terminate(nil)
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
