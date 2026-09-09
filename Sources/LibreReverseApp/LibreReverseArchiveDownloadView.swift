#if os(macOS)
import AppKit

/// Estimates only the current transfer, never the unknown size of the next step.
struct LibreReverseDownloadEstimate {
    private var startedAt: TimeInterval?
    private var initialBytes: Int64 = 0
    private var lastChangeAt: TimeInterval = 0
    private(set) var completed: Int64 = 0
    private(set) var total: Int64 = 0

    mutating func update(completed: Int64, total: Int64, now: TimeInterval) {
        let bytes = max(0, completed)
        if startedAt == nil || bytes < self.completed || total != self.total {
            startedAt = now
            initialBytes = bytes
            lastChangeAt = now
        }
        if bytes != self.completed { lastChangeAt = now }
        self.completed = bytes
        self.total = max(0, total)
    }

    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }

    func status(now: TimeInterval) -> String {
        guard let fraction, let startedAt else { return "Estimating time remaining…" }
        if fraction >= 1 { return "Finishing up…" }
        let percent = "\(Int(fraction * 100))%"
        if now - lastChangeAt >= 15 { return "\(percent) · Waiting for download…" }
        let elapsed = now - startedAt
        let transferred = completed - initialBytes
        guard elapsed >= 3, transferred >= 65_536 else {
            return "\(percent) · Estimating time remaining…"
        }
        let remaining = Double(max(0, total - completed)) * elapsed / Double(transferred)
        let wait: String
        if remaining < 60 {
            wait = "Less than a minute"
        } else if remaining < 3_600 {
            wait = "About \(Int(ceil(remaining / 60))) min"
        } else {
            wait = "About \(Int(ceil(remaining / 3_600))) hr"
        }
        return "\(percent) · \(wait) for this step"
    }
}

@MainActor
final class LibreReverseDownloadProgressBar: NSView {
    var fraction: Double? { didSet { needsDisplay = true } }
    private let spinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Download progress")
    }

    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 16) }

    func setActive(_ active: Bool) {
        spinner.isHidden = !active || fraction != nil
        if spinner.isHidden { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let fraction else { return }
        let track = NSRect(x: 0, y: bounds.midY - 1.5, width: bounds.width, height: 3)
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        var fill = track
        fill.size.width *= min(1, max(0, fraction))
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

@MainActor
final class LibreReverseArchiveDownloadView: NSVisualEffectView {
    let titleLabel = NSTextField(wrappingLabelWithString: "This recording is archived")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let downloadButton = NSButton(title: "Download recording", target: nil, action: nil)
    let progress = LibreReverseDownloadProgressBar()
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progressGroup = NSView()
    private var estimate = LibreReverseDownloadEstimate()
    private var transferID: String?
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        material = .underWindowBackground
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 0.97).cgColor

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .white
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.64)
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.86)
        for label in [titleLabel, detailLabel, statusLabel] {
            label.alignment = .center
            label.maximumNumberOfLines = 3
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        downloadButton.bezelStyle = .rounded
        downloadButton.bezelColor = .systemBlue
        downloadButton.contentTintColor = .white
        downloadButton.controlSize = .large
        downloadButton.setAccessibilityIdentifier("timeline.archive.downloadDay")
        progress.setAccessibilityIdentifier("timeline.archive.downloadProgress")
        statusLabel.setAccessibilityIdentifier("timeline.archive.downloadStatus")

        let actionArea = NSView()
        for child in [progress, statusLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            progressGroup.addSubview(child)
        }
        for child in [downloadButton, progressGroup] {
            child.translatesAutoresizingMaskIntoConstraints = false
            actionArea.addSubview(child)
        }
        let archiveSymbol = NSImageView()
        archiveSymbol.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .light))
        archiveSymbol.contentTintColor = NSColor.white.withAlphaComponent(0.40)
        archiveSymbol.heightAnchor.constraint(equalToConstant: 36).isActive = true
        archiveSymbol.setAccessibilityElement(false)
        let stack = NSStackView(views: [archiveSymbol, titleLabel, detailLabel, actionArea])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionArea.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionArea.heightAnchor.constraint(equalToConstant: 64),
            downloadButton.centerXAnchor.constraint(equalTo: actionArea.centerXAnchor),
            downloadButton.centerYAnchor.constraint(equalTo: actionArea.centerYAnchor),
            downloadButton.widthAnchor.constraint(equalToConstant: 194),
            downloadButton.heightAnchor.constraint(equalToConstant: 36),
            progressGroup.centerXAnchor.constraint(equalTo: actionArea.centerXAnchor),
            progressGroup.widthAnchor.constraint(equalTo: actionArea.widthAnchor),
            progressGroup.topAnchor.constraint(equalTo: actionArea.topAnchor),
            progressGroup.bottomAnchor.constraint(equalTo: actionArea.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: progressGroup.leadingAnchor, constant: 24),
            progress.trailingAnchor.constraint(equalTo: progressGroup.trailingAnchor, constant: -24),
            progress.topAnchor.constraint(equalTo: progressGroup.topAnchor, constant: 12),
            statusLabel.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 10),
            statusLabel.widthAnchor.constraint(equalTo: progressGroup.widthAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: progressGroup.centerXAnchor),
        ])
        // A preferred width allows smaller windows without ambiguous layout.
        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: 440)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
        setDownloading(false)
    }

    required init?(coder: NSCoder) { nil }

    func beginTransfer(id: String) {
        if transferID != id {
            transferID = id
            estimate = LibreReverseDownloadEstimate()
        }
        setDownloading(true)
        refreshStatus()
    }

    func updateTransfer(id: String, completed: Int64, total: Int64, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        beginTransfer(id: id)
        estimate.update(completed: completed, total: total, now: now)
        refreshStatus(now: now)
    }

    func setDownloading(_ downloading: Bool) {
        progressGroup.isHidden = !downloading
        downloadButton.isHidden = downloading
        if downloading {
            refreshStatus()
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refreshStatus() }
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
            progress.setActive(false)
        }
    }

    func showWaiting(_ message: String) {
        estimate = LibreReverseDownloadEstimate()
        transferID = nil
        setDownloading(true)
        timer?.invalidate()
        timer = nil
        statusLabel.stringValue = message
        progress.setAccessibilityValue(message)
    }

    func resetTransfer() {
        transferID = nil
        estimate = LibreReverseDownloadEstimate()
    }

    private func refreshStatus(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        progress.isHidden = false
        progress.fraction = estimate.fraction
        progress.setActive(!progressGroup.isHidden)
        statusLabel.stringValue = estimate.status(now: now)
        progress.setAccessibilityValue(statusLabel.stringValue)
    }

    deinit { timer?.invalidate() }
}
#endif
