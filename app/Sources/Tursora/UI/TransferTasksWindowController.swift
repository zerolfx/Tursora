import AppKit

/// App-owned task registry and its nonmodal inspector. A pane or window may go
/// away while a transfer is running; this controller keeps its controls and
/// originating window alive until the worker reaches a terminal state.
final class TransferTasksWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TransferTasksWindowController()

    private final class Entry {
        let task: TransferTask
        let row: TransferTaskRowView
        var ownerWindow: NSWindow?
        var didPresentFailure = false

        init(task: TransferTask, row: TransferTaskRowView, ownerWindow: NSWindow?) {
            self.task = task
            self.row = row
            self.ownerWindow = ownerWindow
        }
    }

    private struct CompletionWaiter {
        let ids: Set<UUID>
        let completion: () -> Void
    }

    private var entries: [Entry] = []
    private var waiters: [CompletionWaiter] = []
    private var timer: Timer?
    private let rowsStack = NSStackView()
    private let summaryLabel = NSTextField(labelWithString: "No file operations")
    let clearFinishedButton = NSButton(title: "Clear Finished", target: nil, action: nil)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Copies, moves, duplicates and ZIP extractions appear here. Each operation has its own controls.")
    private let scrollView = NSScrollView()

    var hasActiveTasks: Bool { entries.contains { !$0.task.snapshot.isTerminal } }
    var taskIDs: [UUID] { entries.map { $0.task.id } }
    var displayedTaskIDs: [UUID] { rowsStack.arrangedSubviews.compactMap { ($0 as? TransferTaskRowView)?.task.id } }
    private(set) var taskPresentationCount = 0
    private(set) var lastPresentedTaskID: UUID?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "File Operations"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 330)
        super.init(window: window)
        window.delegate = self
        window.center()
        buildContent()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate() }

    /// Called on main with the task's original window, before starting its worker.
    func track(_ task: TransferTask, ownerWindow: NSWindow? = nil,
               title: String? = nil, destinationDescription: String? = nil) {
        precondition(Thread.isMainThread)
        guard !entries.contains(where: { $0.task.id == task.id }) else { return }
        let row = TransferTaskRowView(task: task, title: title, destinationDescription: destinationDescription)
        entries.insert(Entry(task: task, row: row, ownerWindow: ownerWindow), at: 0)
        rowsStack.insertArrangedSubview(row, at: 0)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        refresh()
        startTimer()
        // Fast operations should not steal focus. A conflict always opens the
        // inspector immediately, while longer transfers become visible shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak task] in
            guard let self, let task, !task.snapshot.isTerminal else { return }
            self.show(activate: false, revealing: task.id)
        }
    }

    func row(for taskID: UUID) -> TransferTaskRowView? {
        entries.first { $0.task.id == taskID }?.row
    }

    func hasActiveTasks(ownedBy window: NSWindow) -> Bool {
        entries.contains { $0.ownerWindow === window && !$0.task.snapshot.isTerminal }
    }

    /// The reply is deliberately asynchronous: one task's conflict must never
    /// block another task's Pause, Resume, Cancel, or conflict controls.
    func resolveConflict(for task: TransferTask, conflict: FileOperations.Conflict,
                         reply: @escaping (FileOperations.ConflictDecision) -> Void) {
        precondition(Thread.isMainThread)
        guard !task.snapshot.isTerminal else {
            reply(.init(resolution: .cancel))
            return
        }
        if row(for: task.id) == nil { track(task) }
        row(for: task.id)?.presentConflict(conflict, reply: reply)
        refresh()
        show(activate: true, revealing: task.id)
    }

    func show() { show(activate: true) }

    private func show(activate: Bool, revealing taskID: UUID? = nil,
                      refreshFirst: Bool = true, bringForward: Bool = false) {
        precondition(Thread.isMainThread)
        if refreshFirst { refresh() }
        if let taskID {
            taskPresentationCount += 1
            lastPresentedTaskID = taskID
        }
        if !SmokeTest.isRequested {
            if activate {
                showWindow(nil)
                window?.makeKeyAndOrderFront(nil)
            } else if bringForward || window?.isVisible != true {
                window?.orderFront(nil)
            }
        }
        if let taskID, let row = row(for: taskID) {
            window?.contentView?.layoutSubtreeIfNeeded()
            scrollView.documentView?.layoutSubtreeIfNeeded()
            row.scrollToVisible(row.bounds)
        }
    }

    /// Completion means every selected worker has stopped writing, including
    /// cleanup after cancellation. App termination can safely wait on this.
    func cancelAll(completion: @escaping () -> Void) {
        cancel(entries.filter { !$0.task.snapshot.isTerminal }, completion: completion)
    }

    func cancelTasks(ownedBy window: NSWindow, completion: @escaping () -> Void) {
        cancel(entries.filter { $0.ownerWindow === window && !$0.task.snapshot.isTerminal },
               completion: completion)
    }

    private func cancel(_ selected: [Entry], completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        guard !selected.isEmpty else { DispatchQueue.main.async(execute: completion); return }
        waiters.append(CompletionWaiter(ids: Set(selected.map { $0.task.id }), completion: completion))
        selected.forEach { $0.task.cancel() }
        startTimer()
        refresh()
    }

    /// Also exposed to smoke tests so controls can be inspected without waiting
    /// for a timer or making the inspector visible.
    func refresh() {
        precondition(Thread.isMainThread)
        var active = 0
        var finished = 0
        var activeIDs = Set<UUID>()
        var failedTaskToPresent: UUID?
        for entry in entries {
            let snapshot = entry.task.snapshot
            entry.row.update(snapshot)
            if snapshot.isTerminal {
                finished += 1
                entry.ownerWindow = nil
                if !snapshot.failures.isEmpty && !entry.didPresentFailure {
                    entry.didPresentFailure = true
                    // One window reveals the newest failure when several tasks
                    // finish together; every failure remains in its own row.
                    if failedTaskToPresent == nil { failedTaskToPresent = entry.task.id }
                }
            } else {
                active += 1
                activeIDs.insert(entry.task.id)
            }
        }
        summaryLabel.stringValue = active > 0
            ? "\(active) active operation\(active == 1 ? "" : "s")"
            : (finished > 0 ? "\(finished) finished operation\(finished == 1 ? "" : "s")" : "No file operations")
        clearFinishedButton.isEnabled = finished > 0
        emptyLabel.isHidden = !entries.isEmpty
        if active == 0 {
            timer?.invalidate()
            timer = nil
        }
        // Clear Finished may remove one completed member while another selected
        // task is still stopping. Missing IDs have already stopped; waiting on
        // terminal IDs that remain in the history would never finish that group.
        let ready = waiters.filter { $0.ids.isDisjoint(with: activeIDs) }
        waiters.removeAll { $0.ids.isDisjoint(with: activeIDs) }
        // Remove before calling out: termination and window-close callbacks may
        // synchronously reenter this registry.
        // AppKit must receive a termination reply after applicationShouldTerminate
        // has returned .terminateLater, even when a worker finishes in this poll.
        ready.forEach { waiter in DispatchQueue.main.async(execute: waiter.completion) }
        if let taskID = failedTaskToPresent {
            show(activate: false, revealing: taskID, refreshFirst: false, bringForward: true)
        }
    }

    @objc func clearFinished(_ sender: Any?) {
        precondition(Thread.isMainThread)
        // Deliver callbacks before removing their terminal task IDs.
        refresh()
        entries.removeAll { entry in
            guard entry.task.snapshot.isTerminal else { return false }
            rowsStack.removeArrangedSubview(entry.row)
            entry.row.removeFromSuperview()
            return true
        }
        refresh()
    }

    private func startTimer() {
        guard timer == nil, hasActiveTasks else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        summaryLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        summaryLabel.setAccessibilityIdentifier("transferSummary")
        clearFinishedButton.bezelStyle = .rounded
        clearFinishedButton.target = self
        clearFinishedButton.action = #selector(clearFinished(_:))
        let header = NSStackView(views: [summaryLabel, NSView(), clearFinishedButton])
        header.orientation = .horizontal
        header.spacing = 10
        let footer = NSTextField(wrappingLabelWithString:
            "Operations keep running when this window closes. Reopen File Operations from the Window menu.")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 12
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)
        scrollView.documentView = document
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 1),
            rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -1),
            document.bottomAnchor.constraint(equalTo: rowsStack.bottomAnchor, constant: 8),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        for view in [header, scrollView, footer, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 30),
            emptyLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -30),
        ])
    }
}

/// A single task's controls. No filesystem reads or mutations occur in this view.
final class TransferTaskRowView: AdaptiveLayerView {
    let task: TransferTask
    let titleLabel = NSTextField(labelWithString: "")
    let stateLabel = NSTextField(labelWithString: "")
    let sourceLabel = NSTextField(labelWithString: "")
    let destinationLabel = NSTextField(labelWithString: "")
    let currentItemLabel = NSTextField(labelWithString: "")
    let bytesLabel = NSTextField(labelWithString: "")
    let rateLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let progressIndicator = NSProgressIndicator()
    let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let conflictLabel = NSTextField(wrappingLabelWithString: "")
    let conflictDetailLabel = NSTextField(wrappingLabelWithString: "")
    let applyToAllButton = NSButton(checkboxWithTitle: "Apply to all", target: nil, action: nil)
    let errorsLabel = NSTextField(wrappingLabelWithString: "")
    let errorsDisclosureButton = NSButton(title: "Show All Errors", target: nil, action: nil)
    private(set) var conflictButtons: [FileOperations.ConflictResolution: NSButton] = [:]
    private let conflictStack = NSStackView()
    private var conflictReply: ((FileOperations.ConflictDecision) -> Void)?
    private var conflictRemaining = 1
    private var showsAllErrors = false
    private let titleOverride: String?
    private let destinationDescription: String?

    init(task: TransferTask, title: String? = nil, destinationDescription: String? = nil) {
        self.task = task
        self.titleOverride = title
        self.destinationDescription = destinationDescription
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        semanticBorderColor = .separatorColor
        setAccessibilityIdentifier("transferTask-\(task.id.uuidString)")
        buildContent()
        update(task.snapshot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var hasPendingConflict: Bool { conflictReply != nil }

    func update(_ snapshot: TransferTask.Snapshot) {
        stateLabel.stringValue = !snapshot.isTerminal && snapshot.isCancellationRequested ? "Cancelling…"
            : !snapshot.isTerminal && snapshot.isPauseRequested && snapshot.state != .paused ? "Pausing…" : Self.stateTitle(snapshot.state)
        stateLabel.textColor = snapshot.state == .failed ? .systemRed
            : snapshot.state == .partial ? .systemOrange : .secondaryLabelColor
        if snapshot.isTerminal {
            detailLabel.stringValue = "\(snapshot.successfulItems) completed · \(snapshot.skippedItems) skipped"
        } else { detailLabel.stringValue = snapshot.phaseDetail }
        let displayedFailures = showsAllErrors ? snapshot.failures : Array(snapshot.failures.prefix(3))
        errorsLabel.stringValue = displayedFailures.map {
            "\($0.url.path): \($0.error.localizedDescription)"
        }.joined(separator: "\n")
        errorsLabel.isHidden = snapshot.failures.isEmpty
        errorsDisclosureButton.isHidden = snapshot.failures.count <= 3
        errorsDisclosureButton.title = showsAllErrors ? "Show Fewer Errors" : "Show All \(snapshot.failures.count) Errors"
        let current = snapshot.isTerminal ? nil : snapshot.currentItem
        currentItemLabel.stringValue = current.map { "Current: \($0.lastPathComponent)" } ?? ""
        currentItemLabel.toolTip = current?.path
        let copied = ByteCountFormatter.string(fromByteCount: snapshot.completedBytes, countStyle: .file)
        progressIndicator.isHidden = snapshot.isTerminal || snapshot.totalBytes == 0
        if let total = snapshot.totalBytes {
            bytesLabel.stringValue = total == 0 ? "No file data to transfer"
                : "\(copied) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
            setIndeterminate(false)
            progressIndicator.maxValue = Double(max(total, 1))
            progressIndicator.doubleValue = Double(min(snapshot.completedBytes, max(total, 0)))
        } else {
            bytesLabel.stringValue = snapshot.completedBytes > 0 ? "\(copied) · total unknown" : "Total size unknown"
            setIndeterminate(!snapshot.isTerminal && snapshot.state != .paused)
        }
        if snapshot.state == .running, let rate = snapshot.bytesPerSecond, rate > 0, rate.isFinite {
            rateLabel.stringValue = "\(ByteCountFormatter.string(fromByteCount: Int64(min(rate, Double(Int64.max - 1024))), countStyle: .file))/s"
            if snapshot.totalBytes != nil, let eta = snapshot.estimatedTimeRemaining, eta.isFinite, eta >= 0 {
                rateLabel.stringValue += " · \(Self.remainingTime(eta)) remaining"
            }
        } else { rateLabel.stringValue = "" }
        pauseButton.title = snapshot.state == .paused ? "Resume" : "Pause"
        pauseButton.isEnabled = !snapshot.isCancellationRequested && (snapshot.state == .paused || (snapshot.canPause && !snapshot.isPauseRequested))
        // A worker with no pause checkpoint must not offer a button that does
        // nothing; Cancel stays available.
        pauseButton.isHidden = snapshot.isTerminal || !snapshot.supportsPause
        cancelButton.isEnabled = !snapshot.isTerminal && !snapshot.isCancellationRequested
        cancelButton.isHidden = snapshot.isTerminal
        if snapshot.isTerminal { dismissConflict() }
        conflictButtons.values.forEach { $0.isEnabled = !snapshot.isTerminal && snapshot.state != .paused && !snapshot.isCancellationRequested }
        applyToAllButton.isEnabled = !snapshot.isTerminal && snapshot.state != .paused && !snapshot.isCancellationRequested
    }

    func presentConflict(_ conflict: FileOperations.Conflict,
                         reply: @escaping (FileOperations.ConflictDecision) -> Void) {
        conflictReply = reply
        conflictRemaining = conflict.remaining
        conflictLabel.stringValue = "“\(conflict.destination.lastPathComponent)” already exists. Choose what this operation should do."
        conflictLabel.toolTip = "Incoming: \(conflict.source.path)\nExisting: \(conflict.destination.path)"
        let dates = DateFormatter()
        dates.dateStyle = .medium
        dates.timeStyle = .short
        func describe(_ prefix: String, url: URL, info: FileOperations.Conflict.Info) -> String {
            let size = info.isDirectory ? "folder" : ByteCountFormatter.string(fromByteCount: info.size, countStyle: .file)
            let date = info.date.map { dates.string(from: $0) } ?? "unknown date"
            return "\(prefix): \(url.path)\n\(size), modified \(date)"
        }
        var descriptions = [describe("Incoming", url: conflict.source, info: conflict.sourceInfo),
                            describe("Existing", url: conflict.destination, info: conflict.destinationInfo)]
        if let incoming = conflict.sourceInfo.date, let existing = conflict.destinationInfo.date {
            if incoming > existing { descriptions.append("The incoming item is newer.") }
            else if incoming < existing { descriptions.append("The incoming item is older.") }
            else { descriptions.append("Both items were modified at the same time.") }
        }
        conflictDetailLabel.stringValue = descriptions.joined(separator: "\n")
        applyToAllButton.state = .off
        applyToAllButton.title = "Apply to all (\(conflict.remaining) items)"
        applyToAllButton.isHidden = conflict.remaining <= 1
        conflictStack.isHidden = false
        // The model supplies the cached folder check, so rendering does no I/O.
        conflictButtons[.merge]?.isHidden = !conflict.bothFolders
    }

    private func dismissConflict() {
        conflictReply = nil
        conflictStack.isHidden = true
    }

    @objc func togglePause(_ sender: Any?) {
        if task.snapshot.state == .paused { task.resume() } else { task.pause() }
        update(task.snapshot)
    }

    @objc func cancel(_ sender: Any?) {
        task.cancel()
        update(task.snapshot)
    }

    @objc private func toggleErrors(_ sender: Any?) {
        showsAllErrors.toggle()
        update(task.snapshot)
    }

    @objc private func chooseConflict(_ sender: NSButton) {
        guard let reply = conflictReply,
              let resolution = conflictButtons.first(where: { $0.value === sender })?.key else { return }
        let all = conflictRemaining > 1 && applyToAllButton.state == .on && resolution != .cancel
        dismissConflict()
        reply(.init(resolution: resolution, applyToAll: all))
        update(task.snapshot)
    }

    private func setIndeterminate(_ indeterminate: Bool) {
        if progressIndicator.isIndeterminate != indeterminate {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = indeterminate
        }
        if indeterminate { progressIndicator.startAnimation(nil) }
    }

    private func buildContent() {
        let noun = task.kind == .move ? "Move" : task.kind == .extract ? "Extract" : task.kind == .compress ? "Compress" : "Copy"
        titleLabel.stringValue = titleOverride ?? (task.sources.count == 1
            ? "\(noun) “\(task.sources[0].lastPathComponent)”"
            : "\(noun) \(task.sources.count) items")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let sourceParents = Set(task.sources.map { $0.deletingLastPathComponent().path })
        sourceLabel.stringValue = sourceParents.count > 1 ? "From: \(sourceParents.count) folders"
            : task.sources.first.map { "From: \($0.deletingLastPathComponent().path)" } ?? ""
        sourceLabel.toolTip = task.sources.map(\.path).joined(separator: "\n")
        destinationLabel.stringValue = "To: \(destinationDescription ?? task.destination.path)"
        destinationLabel.toolTip = destinationDescription ?? task.destination.path
        for label in [sourceLabel, destinationLabel, currentItemLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        bytesLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        bytesLabel.toolTip = "Byte counts cover file data; metadata is finalized separately."
        rateLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        rateLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        errorsLabel.font = .systemFont(ofSize: 11)
        errorsLabel.textColor = .systemRed
        errorsLabel.isSelectable = true
        errorsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        errorsDisclosureButton.bezelStyle = .inline
        errorsDisclosureButton.controlSize = .small
        errorsDisclosureButton.target = self
        errorsDisclosureButton.action = #selector(toggleErrors(_:))
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(togglePause(_:))
        pauseButton.setAccessibilityIdentifier("transferPause-\(task.id.uuidString)")
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.setAccessibilityIdentifier("transferCancel-\(task.id.uuidString)")
        let titleRow = NSStackView(views: [titleLabel, NSView(), stateLabel])
        let amountRow = NSStackView(views: [bytesLabel, NSView(), rateLabel])
        let controlRow = NSStackView(views: [detailLabel, NSView(), pauseButton, cancelButton])
        for row in [titleRow, amountRow, controlRow] {
            row.orientation = .horizontal
            row.spacing = 8
        }

        conflictLabel.font = .systemFont(ofSize: 12, weight: .medium)
        conflictLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        conflictDetailLabel.font = .systemFont(ofSize: 11)
        conflictDetailLabel.textColor = .secondaryLabelColor
        conflictDetailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let conflictActionRow = NSStackView()
        conflictActionRow.orientation = .horizontal
        conflictActionRow.spacing = 6
        for (title, resolution) in [("Keep Both", FileOperations.ConflictResolution.keepBoth),
                                    ("Merge", .merge), ("Skip", .skip), ("Stop", .cancel), ("Replace", .replace)] {
            let button = NSButton(title: title, target: self, action: #selector(chooseConflict(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.hasDestructiveAction = resolution == .replace
            button.setAccessibilityIdentifier("transferConflict-\(title)-\(task.id.uuidString)")
            conflictButtons[resolution] = button
            conflictActionRow.addArrangedSubview(button)
        }
        let separator = NSBox()
        separator.boxType = .separator
        conflictStack.orientation = .vertical
        conflictStack.alignment = .leading
        conflictStack.spacing = 8
        conflictStack.isHidden = true
        [separator, conflictLabel, conflictDetailLabel, applyToAllButton, conflictActionRow].forEach { conflictStack.addArrangedSubview($0) }
        separator.widthAnchor.constraint(equalTo: conflictStack.widthAnchor).isActive = true
        conflictLabel.widthAnchor.constraint(equalTo: conflictStack.widthAnchor).isActive = true
        conflictDetailLabel.widthAnchor.constraint(equalTo: conflictStack.widthAnchor).isActive = true

        let stack = NSStackView(views: [titleRow, sourceLabel, destinationLabel, currentItemLabel,
                                       progressIndicator, amountRow, controlRow, errorsLabel, errorsDisclosureButton, conflictStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
        ])
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    static func stateTitle(_ state: TransferTask.State) -> String {
        switch state {
        case .preparing: return "Preparing…"
        case .running: return "Transferring"
        case .paused: return "Paused"
        case .waitingForConflict: return "Needs a decision"
        case .finishing: return "Finishing…"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .partial: return "Partially completed"
        case .failed: return "Failed"
        }
    }

    static func remainingTime(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "less than a second" }
        if seconds < 60 { return "about \(Int(seconds.rounded(.up)))s" }
        if seconds < 3600 { return "about \(Int((seconds / 60).rounded(.up)))m" }
        return "about \(Int(min((seconds / 3600).rounded(.up), 9999)))h"
    }
}
