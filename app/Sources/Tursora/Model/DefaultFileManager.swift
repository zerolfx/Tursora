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

    /// Why LaunchServices will refuse to register this bundle as the handler,
    /// or nil when nothing is in the way.
    ///
    /// Worth reporting *before* the request, because the system's own error for
    /// all of these is `NSCocoaErrorDomain` 256, "The file couldn't be opened."
    /// — measured — which tells the user nothing they can act on.
    enum LocationProblem: Equatable {
        /// No bundle identifier: the bare executable, not an application.
        case notAnApplication
        /// A temporary location. App Translocation puts a quarantined copy —
        /// which is what an ad-hoc-signed app opened from a downloaded disk
        /// image is — under a private temporary path it cannot be registered
        /// from.
        case temporary
        /// Opened straight from a disk image, which is mounted read-only.
        case readOnlyVolume

        var explanation: String {
            switch self {
            case .notAnApplication:
                return "Tursora has to be running from an application bundle to become the default."
            case .temporary:
                return "Move Tursora to your Applications folder and open it from there. "
                    + "macOS will not let an application running from a temporary location become "
                    + "the default, and a copy opened straight from a downloaded disk image runs "
                    + "from one."
            case .readOnlyVolume:
                return "Copy Tursora to your Applications folder and open it from there. "
                    + "An application running from a disk image cannot become the default."
            }
        }
    }

    static func locationProblem(bundle: Bundle = .main) -> LocationProblem? {
        guard bundle.bundleIdentifier != nil else { return .notAnApplication }
        let url = bundle.bundleURL
        if (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return .readOnlyVolume
        }
        let path = url.resolvingSymlinksInPath().path
        // App Translocation mounts live under the private temporary tree too,
        // so one test covers both; the marker is checked first for clarity.
        if path.contains("/AppTranslocation/") { return .temporary }
        if path.hasPrefix("/private/var/folders/") || path.hasPrefix(NSTemporaryDirectory()) {
            return .temporary
        }
        return nil
    }

    /// Asks macOS to make this application the handler for folders. The system
    /// puts its own confirmation in front of the user, so this returns without
    /// having changed anything if they decline — the completion reports what
    /// the system decided, not what was requested.
    static func makeCurrent(workspace: NSWorkspace = .shared,
                            bundle: Bundle = .main,
                            completion: @escaping (Result<Void, Error>) -> Void) {
        if let problem = locationProblem(bundle: bundle) {
            completion(.failure(Failure.unusableLocation(problem))); return
        }
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
        case unusableLocation(LocationProblem)

        var errorDescription: String? {
            switch self {
            case .notAnApplication:
                return LocationProblem.notAnApplication.explanation
            case .unusableLocation(let problem):
                return problem.explanation
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
