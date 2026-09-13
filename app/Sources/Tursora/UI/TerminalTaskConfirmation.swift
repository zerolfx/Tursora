import AppKit

/// Shared by quit, window close and restart so hidden jobs receive the same
/// protection as visible ones. Merely hiding a panel never reaches this path.
enum TerminalTaskConfirmation {
    enum Action: Equatable { case quit, closeWindow, restart }
    typealias Decision = (Action, [TerminalActivitySnapshot]) -> Bool

    static func confirm(action: Action, activities: [TerminalActivitySnapshot]) -> Bool {
        guard activities.contains(where: \.requiresConfirmation) else { return true }
        guard !SmokeTest.isRequested else {
            print("Terminal tasks are active; cancelling the headless close request.")
            return false
        }
        return makeAlert(action: action, activities: activities).runModal() == .alertSecondButtonReturn
    }

    static func makeAlert(action: Action, activities: [TerminalActivitySnapshot]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let verb: String
        switch action {
        case .quit:
            alert.messageText = "Quit Tursora and Stop Terminal Tasks?"
            verb = "Quit and Stop Tasks"
        case .closeWindow:
            alert.messageText = "Close Window and Stop Terminal Tasks?"
            verb = "Close and Stop Tasks"
        case .restart:
            alert.messageText = "Restart Terminal and Stop Tasks?"
            verb = "Restart and Stop Tasks"
        }
        let active = activities.filter(\.requiresConfirmation)
        let names = Array(Set(active.flatMap(\.tasks).map { sanitized($0.name) })).sorted()
        let taskText = names.isEmpty ? "" : "\n\nTasks: " + names.prefix(6).joined(separator: ", ") + (names.count > 6 ? ", …" : "")
        let unknown = active.contains(where: \.informationUnavailable)
            ? "\n\nSome terminal activity could not be checked. The session may still have running work." : ""
        let summary = active.contains { !$0.tasks.isEmpty }
            ? "Terminal tasks are still active, including in hidden panels."
            : "A terminal session may still have active tasks, including in hidden panels."
        alert.informativeText = summary + " Continuing will end these sessions and may interrupt their work." + taskText + unknown
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let stop = alert.addButton(withTitle: verb)
        stop.keyEquivalent = ""
        stop.hasDestructiveAction = true
        return alert
    }

    private static func sanitized(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(80)))
    }
}
