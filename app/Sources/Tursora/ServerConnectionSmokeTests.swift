import AppKit

enum ServerConnectionSmokeTests {
    static func run() {
        print("== server connections ==")
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "ok  " : "FAIL") \(name)")
            if !condition { exit(1) }
        }
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

        let mount = MockMount()
        let controller = ServerConnectionController(connection: mount)
        controller.addressField.stringValue = "ftp://server"
        controller.connect(nil)
        check("server UI: invalid input stays inline without invoking mount",
              mount.urls.isEmpty && !controller.messageLabel.stringValue.isEmpty && !controller.isConnecting)
        controller.addressField.stringValue = "https://server/dav"
        controller.connect(nil)
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
