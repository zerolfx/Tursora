import AppKit

/// Window-wide terminal status, independent of the pane whose footer hosts it.
struct TerminalStatusPresentation: Equatable {
    let title: String
    let detail: String
    let isEnabled: Bool
    let hasTasks: Bool

    static func make(state: TerminalPanelPresentation.State?, visible: Bool,
                     activity: TerminalActivitySnapshot?, enabled: Bool) -> Self {
        let tasks = activity?.tasks ?? []
        let location = visible ? "visible" : "hidden"
        let title: String
        let description: String
        if !tasks.isEmpty {
            title = "Terminal · \(tasks.count) \(tasks.count == 1 ? "task" : "tasks")"
            let stopped = tasks.filter(\.isStopped).count
            description = "\(tasks.count) terminal \(tasks.count == 1 ? "process" : "processes"), \(location)" + (stopped > 0 ? " (\(stopped) stopped)." : ".")
        } else if activity?.informationUnavailable == true {
            title = "Terminal · Check"
            description = "Terminal activity could not be checked; the session is \(location)."
        } else {
            switch state {
            case .running:
                title = visible ? "Terminal · Running" : "Terminal · Hidden"
                description = "The shell session is running and \(location). Hiding it keeps its work running."
            case .ended:
                title = "Terminal · Ended"
                description = "The shell has ended. Its output is retained."
            case .failedToStart:
                title = "Terminal · Error"
                description = "The terminal could not start. Open it to see the error."
            case .ready, .none:
                title = "Terminal"
                description = "No shell has been started."
            }
        }
        let action = enabled ? (visible ? "Click to hide the terminal." : "Click to show the terminal.")
            : "Enable Terminal in Settings to show this session."
        return Self(title: title, detail: description + " " + action, isEnabled: enabled, hasTasks: !tasks.isEmpty)
    }
}
