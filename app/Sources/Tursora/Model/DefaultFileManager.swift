import AppKit
import UniformTypeIdentifiers

/// Whether Tursora is the application macOS opens a folder with.
///
/// macOS has no user-facing "default file manager" setting the way it has one
/// for the browser or mail. What it has is the handler for the `public.folder`
/// content type, which is what a double-clicked folder, an "open the enclosing
/// folder" action and `open <dir>` all go through. Other file managers have
/// long set it by writing `NSFileViewer` and a `LSHandlers` entry into
/// LaunchServices' own preferences; Tursora asks the system instead, through
/// `NSWorkspace.setDefaultApplication(at:toOpen:)`, so the user sees macOS's
/// own confirmation and nothing is written behind their back (D86).
///
/// Nothing here caches: the answer is whatever LaunchServices says right now,
/// because the user can change it in another application at any time.
enum DefaultFileManager {

    /// The type a folder is opened as.
    static let folderType = UTType.folder

    /// The application macOS currently opens a folder with, if any.
    static func currentHandlerURL(workspace: NSWorkspace = .shared) -> URL? {
        workspace.urlForApplication(toOpen: folderType)
    }

    /// The name shown to the user for whatever currently holds the role, so a
    /// settings line can say what it would be replacing.
    static func currentHandlerName(workspace: NSWorkspace = .shared) -> String? {
        currentHandlerURL(workspace: workspace).map {
            FileManager.default.displayName(atPath: $0.path)
        }
    }

    /// Whether the running application is that handler.
    ///
    /// Compared by bundle identifier rather than by URL: the same application
    /// has a different path when it is run from a build folder, from a disk
    /// image or from /Applications, and a path comparison would then report
    /// "not the default" for an application that is.
    static func isCurrent(workspace: NSWorkspace = .shared,
                          bundle: Bundle = .main) -> Bool {
        guard let identifier = bundle.bundleIdentifier,
              let handler = currentHandlerURL(workspace: workspace),
              let handlerBundle = Bundle(url: handler),
              let handlerIdentifier = handlerBundle.bundleIdentifier else { return false }
        return handlerIdentifier == identifier
    }

    /// Asks macOS to make this application the handler for folders. The system
    /// puts its own confirmation in front of the user, so this returns without
    /// having changed anything if they decline — the completion reports what
    /// the system decided, not what was requested.
    static func makeCurrent(workspace: NSWorkspace = .shared,
                            bundle: Bundle = .main,
                            completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = bundle.bundleURL as URL?, bundle.bundleIdentifier != nil else {
            completion(.failure(Failure.notAnApplication)); return
        }
        workspace.setDefaultApplication(at: url, toOpen: folderType) { error in
            DispatchQueue.main.async {
                if let error { completion(.failure(error)) } else { completion(.success(())) }
            }
        }
    }

    enum Failure: LocalizedError {
        case notAnApplication

        var errorDescription: String? {
            switch self {
            case .notAnApplication:
                return "Tursora has to be running from an application bundle to become the default."
            }
        }
    }

    /// What the settings line says, given the current state. Pure, so the
    /// wording is checked without touching LaunchServices.
    static func statusText(isCurrent: Bool, currentName: String?) -> String {
        if isCurrent { return "Tursora opens folders." }
        guard let currentName, !currentName.isEmpty else {
            return "Folders open in another application."
        }
        return "Folders open in \(currentName)."
    }
}
