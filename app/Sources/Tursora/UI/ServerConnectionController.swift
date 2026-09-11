import AppKit

/// A small address window; the system presents authentication and mounts.
final class ServerConnectionController: NSWindowController, NSWindowDelegate {
    private static let shared = ServerConnectionController()

    static func show(relativeTo parent: NSWindow?, onMount: @escaping (URL) -> Void) {
        guard !SmokeTest.isRequested else { return }
        let controller = shared
        if !controller.isConnecting { controller.onMount = onMount }
        if let parent, let window = controller.window, !window.isVisible {
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2,
                                          y: parent.frame.midY - window.frame.height / 2))
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if !controller.isConnecting { controller.window?.makeFirstResponder(controller.addressField) }
    }

    let addressField = NSTextField(string: "")
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let connection: ServerMounting
    private(set) var isConnecting = false
    var onMount: ((URL) -> Void)?
    private var generation = 0

    init(connection: ServerMounting = ServerConnection()) {
        self.connection = connection
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 226),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Connect to Server"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let label = NSTextField(labelWithString: "Server Address")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        addressField.placeholderString = "smb://server/share"
        addressField.setAccessibilityLabel("Server Address")
        addressField.target = self
        addressField.action = #selector(connect(_:))
        let help = NSTextField(wrappingLabelWithString:
            "Use SMB, NFS, WebDAV (https://), or legacy AFP. macOS handles sign-in; connected volumes appear in Locations.")
        help.font = .systemFont(ofSize: 12)
        help.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .systemRed
        messageLabel.setAccessibilityIdentifier("serverConnectionMessage")
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connect(_:))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        let buttons = NSStackView(views: [progress, NSView(), cancelButton, connectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [label, addressField, help, messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            messageLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
        for view in [addressField, help, messageLabel, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @objc func connect(_ sender: Any?) {
        guard !isConnecting else { return }
        let url: URL
        do { url = try ServerConnection.validatedURL(addressField.stringValue) }
        catch { showError(error); return }
        generation += 1
        let currentGeneration = generation
        setConnecting(true)
        messageLabel.stringValue = "Connecting… macOS may ask you to sign in."
        messageLabel.textColor = .secondaryLabelColor
        connection.mount(url) { [weak self] result in
            guard let self, self.generation == currentGeneration else { return }
            self.setConnecting(false)
            switch result {
            case .success(let urls):
                self.messageLabel.stringValue = ""
                self.close()
                if let first = urls.first { self.onMount?(first) }
            case .failure(let error):
                if ServerConnection.isCancellation(error) { self.messageLabel.stringValue = "" }
                else { self.showError(error) }
            }
        }
    }

    private func showError(_ error: Error) {
        messageLabel.stringValue = error.localizedDescription
        messageLabel.textColor = .systemRed
        if SmokeTest.isRequested { print("Connect to Server: \(error.localizedDescription)") }
    }

    private func setConnecting(_ connecting: Bool) {
        isConnecting = connecting
        addressField.isEnabled = !connecting
        connectButton.isEnabled = !connecting
        if connecting { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    @objc func cancel(_ sender: Any?) { close() }

    func windowWillClose(_ notification: Notification) {
        generation += 1
        connection.cancel()
        setConnecting(false)
        messageLabel.stringValue = ""
    }
}
