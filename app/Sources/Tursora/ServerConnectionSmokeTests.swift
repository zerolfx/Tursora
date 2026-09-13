import AppKit

enum ServerConnectionSmokeTests: SmokeSuite {
    static func run() {
        print("== server connections ==")
        check("server: SMB share and whitespace normalization",
              (try? ServerConnection.validatedURL("  smb://nas.local/Team  ").absoluteString) == "smb://nas.local/Team")
        check("server: CIFS normalizes to SMB",
              (try? ServerConnection.validatedURL("CIFS://nas/Share").scheme) == "smb")
        check("server: native network schemes validate",
              ["nfs://server/export", "afp://server/Share", "http://server/webdav", "https://server:8443/dav"].allSatisfy {
                  (try? ServerConnection.validatedURL($0)) != nil
              })
        check("server: IPv6 and escaped share names validate",
              (try? ServerConnection.validatedURL("smb://[::1]/Team%20Files")) != nil)
        check("server: unsupported and malformed addresses reject",
              ["", "server", "file:///tmp", "ftp://server", "sftp://server", "smb:///share",
               "smb://bad host/share", "smb://server:0/share", "smb://server:65536/share",
               "smb://server/share?token=secret", "smb://server/share#fragment", "smb://ser\nver/share"].allSatisfy {
                  (try? ServerConnection.validatedURL($0)) == nil
              })
        var passwordError: Error?
        do { _ = try ServerConnection.validatedURL("smb://user:secret@server/share") }
        catch { passwordError = error }
        check("server: embedded passwords stay out of mounts and error text",
              passwordError as? ServerConnection.ConnectionError == .embeddedPassword
              && !(passwordError?.localizedDescription.contains("secret") ?? true))
        check("server: remote volumes offer Eject without removable flags",
              PlacesModel.canEjectVolume(isVolume: true, isLocal: false, isRemovable: false, isEjectable: false))
        check("server: fixed local volumes and nested favourites cannot eject",
              !PlacesModel.canEjectVolume(isVolume: true, isLocal: true, isRemovable: false, isEjectable: false)
              && !PlacesModel.canEjectVolume(isVolume: false, isLocal: false, isRemovable: true, isEjectable: true))
        check("server: removable disks retain Eject",
              PlacesModel.canEjectVolume(isVolume: true, isLocal: true, isRemovable: true, isEjectable: false))
        check("server: remote volumes use a network symbol",
              PlacesModel.volumeSymbol(isLocal: false, isInternal: false, isRemovable: true) == "network")

        let focusMount = MockMount()
        let focusController = ServerConnectionController(connection: focusMount)
        let field = focusController.addressField
        check("server UI: finishing field editing has no submission action",
              field.action == nil && field.cell?.sendsActionOnEndEditing == false)
        field.stringValue = "smb://never-contact.invalid/share"
        focusController.window?.makeFirstResponder(field)
        check("server UI: the hidden window starts an address field editor", field.currentEditor() != nil)
        focusController.window?.makeFirstResponder(focusController.cancelButton)
        check("server UI: moving focus from a valid address never starts a mount",
              focusMount.urls.isEmpty && !focusController.isConnecting && focusController.messageLabel.stringValue.isEmpty)
        focusController.window?.makeFirstResponder(field)
        focusController.cancelButton.performClick(nil)
        check("server UI: Cancel ends address editing without starting a connection",
              focusMount.urls.isEmpty && !focusController.isConnecting && focusController.messageLabel.stringValue.isEmpty)
        let fieldEditor = NSTextView()
        check("server UI: Tab is left to normal focus handling",
              !focusController.control(field, textView: fieldEditor, doCommandBy: #selector(NSResponder.insertTab(_:)))
              && focusMount.urls.isEmpty)
        let returnMount = MockMount()
        let returnController = ServerConnectionController(connection: returnMount)
        returnController.addressField.stringValue = "smb://stale.invalid/share"
        returnController.window?.makeFirstResponder(returnController.addressField)
        guard let returnEditor = returnController.addressField.currentEditor() as? NSTextView else {
            check("server UI: Return has a real address field editor", false)
            return
        }
        returnEditor.string = "smb://typed.invalid/share"
        check("server UI: Return submits the latest field editor text exactly once",
              returnController.control(returnController.addressField, textView: returnEditor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
              && returnMount.urls.map(\.absoluteString) == ["smb://typed.invalid/share"] && returnController.isConnecting)
        check("server UI: Escape cancels a pending connection without another submit",
              returnController.control(returnController.addressField, textView: returnEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
              && returnMount.urls.count == 1 && !returnController.isConnecting)

        let mount = MockMount()
        let controller = ServerConnectionController(connection: mount)
        controller.addressField.stringValue = "ftp://server"
        controller.connect(nil)
        check("server UI: invalid input stays inline without invoking mount",
              mount.urls.isEmpty && !controller.messageLabel.stringValue.isEmpty && !controller.isConnecting)
        controller.addressField.stringValue = "https://server/dav"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.addressField))
        check("server UI: editing clears an old validation error without connecting",
              controller.messageLabel.stringValue.isEmpty && mount.urls.isEmpty)
        controller.connectButton.performClick(nil)
        check("server UI: WebDAV goes to mount service and disables duplicate submits",
              mount.urls.first?.scheme == "https" && controller.isConnecting && !controller.connectButton.isEnabled)
        controller.connect(nil)
        check("server UI: repeated Connect cannot start a second request", mount.urls.count == 1)
        mount.completion?(.failure(NSError(domain: NSPOSIXErrorDomain, code: Int(EHOSTUNREACH))))
        check("server UI: mount failure restores controls and shows inline error",
              !controller.isConnecting && controller.connectButton.isEnabled && !controller.messageLabel.stringValue.isEmpty)
        var navigated: URL?
        controller.onMount = { navigated = $0 }
        controller.connect(nil)
        let mountedURL = URL(fileURLWithPath: "/Volumes/Tursora Smoke Share", isDirectory: true)
        mount.completion?(.success([mountedURL]))
        check("server UI: successful mount navigates with a local file URL", navigated == mountedURL)
        navigated = nil
        controller.connect(nil)
        let staleCompletion = mount.completion
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        staleCompletion?(.success([mountedURL]))
        check("server UI: closing cancels and ignores stale completion",
              mount.cancelCount > 0 && !controller.isConnecting && navigated == nil)
        check("server: system user cancellation is distinct from failure",
              ServerConnection.isCancellation(NSError(domain: NSOSStatusErrorDomain, code: -128))
              && !ServerConnection.isCancellation(NSError(domain: NSPOSIXErrorDomain, code: Int(EHOSTUNREACH))))
        var blockedNetwork = false
        ServerConnection().mount(URL(string: "smb://never-contact.invalid/share")!) { result in
            if case .failure(let error) = result {
                blockedNetwork = error as? ServerConnection.ConnectionError == .smokeTest
            }
        }
        check("server: smoke mode blocks real network and authentication UI", blockedNetwork)
    }

    private final class MockMount: ServerMounting {
        var urls: [URL] = []
        var cancelCount = 0
        var completion: ((Result<[URL], Error>) -> Void)?
        func mount(_ url: URL, completion: @escaping (Result<[URL], Error>) -> Void) {
            urls.append(url)
            self.completion = completion
        }
        func cancel() { cancelCount += 1 }
    }
}
