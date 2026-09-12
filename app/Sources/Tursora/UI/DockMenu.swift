import AppKit

enum DockMenu {
    static func make(target: AppDelegate, directories: DockMenuDirectories) -> NSMenu {
        let menu = NSMenu(title: "Tursora")
        menu.autoenablesItems = false
        for command in DockMenuCommand.allCases {
            if command == .downloads { menu.addItem(.separator()) }
            let action: Selector
            switch command {
            case .newWindow: action = #selector(AppDelegate.newWindowFromDock(_:))
            case .downloads: action = #selector(AppDelegate.openDownloadsFromDock(_:))
            case .applications: action = #selector(AppDelegate.openApplicationsFromDock(_:))
            }
            let item = NSMenuItem(title: command.title, action: action, keyEquivalent: "")
            item.target = target
            item.isEnabled = command.destination(in: directories) != nil
            menu.addItem(item)
        }
        return menu
    }
}
