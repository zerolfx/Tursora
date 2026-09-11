import Foundation
import NetFS

protocol ServerMounting: AnyObject {
    func mount(_ url: URL, completion: @escaping (Result<[URL], Error>) -> Void)
    func cancel()
}

/// Native network mounts remain ordinary file URLs throughout the browser.
/// NetAuth owns authentication, Keychain access and share selection.
final class ServerConnection: ServerMounting {
    enum ConnectionError: LocalizedError, Equatable {
        case invalidAddress, unsupportedScheme, embeddedPassword, noMountPoints, smokeTest

        var errorDescription: String? {
            switch self {
            case .invalidAddress: return "Enter a server address such as smb://server/share."
            case .unsupportedScheme: return "Use smb://, nfs://, https:// or http:// for WebDAV, or afp:// for a legacy server."
            case .embeddedPassword: return "Remove the password from the address. macOS will ask for credentials when needed."
            case .noMountPoints: return "macOS did not return a mounted folder. Try connecting again."
            case .smokeTest: return "Network connections are disabled during smoke tests."
            }
        }
    }

    static func validatedURL(_ address: String) throws -> URL {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var parts = URLComponents(string: input), let scheme = parts.scheme?.lowercased() else {
            throw ConnectionError.invalidAddress
        }
        guard ["smb", "cifs", "nfs", "http", "https", "afp"].contains(scheme) else {
            throw ConnectionError.unsupportedScheme
        }
        guard input.contains("://"), let host = parts.host, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }), parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw ConnectionError.invalidAddress
        }
        guard parts.password == nil else { throw ConnectionError.embeddedPassword }
        parts.scheme = scheme == "cifs" ? "smb" : scheme
        guard let url = parts.url else { throw ConnectionError.invalidAddress }
        return url
    }

    private var requestID: AsyncRequestID?
    private var generation = 0

    func mount(_ url: URL, completion: @escaping (Result<[URL], Error>) -> Void) {
        cancel()
        guard !SmokeTest.isRequested else {
            completion(.failure(ConnectionError.smokeTest))
            return
        }
        let address: URL
        do { address = try Self.validatedURL(url.absoluteString) }
        catch { completion(.failure(error)); return }
        let currentGeneration = generation
        let options = NSMutableDictionary(dictionary: [kNAUIOptionKey: kNAUIOptionAllowUI])
        let mountOptions = NSMutableDictionary(dictionary: [kNetFSOpenURLMountKey: true])
        // Passing HTTP(S) directly to NetFS is essential: opening its default
        // URL handler would launch a web browser instead of mounting WebDAV.
        let status = NetFSMountURLAsync(address as CFURL, nil, nil, nil, options, mountOptions,
                                       &requestID, DispatchQueue.main) { [weak self] status, _, points in
            guard let self, self.generation == currentGeneration else { return }
            self.requestID = nil
            guard status == 0 else { completion(.failure(Self.error(status))); return }
            let urls = (points as? [String] ?? []).filter { $0.hasPrefix("/") }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            guard !urls.isEmpty else { completion(.failure(ConnectionError.noMountPoints)); return }
            completion(.success(urls))
        }
        if status != 0 {
            requestID = nil
            completion(.failure(Self.error(status)))
        }
    }

    func cancel() {
        generation += 1
        if let requestID { _ = NetFSMountURLCancel(requestID) }
        requestID = nil
    }

    static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSOSStatusErrorDomain && error.code == -128)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ECANCELED))
    }

    private static func error(_ status: Int32) -> NSError {
        NSError(domain: status > 0 ? NSPOSIXErrorDomain : NSOSStatusErrorDomain, code: Int(status))
    }

    deinit { cancel() }
}
