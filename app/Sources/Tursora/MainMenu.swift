import AppKit

/// The main menu, built in code (no nib). Items use nil targets so the
/// responder chain decides who handles them: the window controller for
/// navigation, the file list for selection-related commands, text fields for
/// editing commands.
enum MainMenu {

    static func build() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(appMenu())
        menu.addItem(fileMenu())
        menu.addItem(editMenu())
        menu.addItem(viewMenu())
        menu.addItem(goMenu())
        menu.addItem(windowMenu())
        menu.addItem(helpMenu())
        applyPreferences(to: menu)
        return menu
    }

    static func applyPreferences(to menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { applyPreferences(to: submenu) }
            if item.action == #selector(MainWindowController.focusFilter(_:)) {
                item.keyEquivalent = AppPreferences.filterShortcut.keyEquivalent
                item.keyEquivalentModifierMask = AppPreferences.filterShortcut.modifierFlags
            }
            if item.action == #selector(MainWindowController.toggleTerminal(_:)) {
                item.isHidden = !AppPreferences.experimentalTerminalEnabled
            }
        }
    }

    private static func submenu(_ title: String) -> (NSMenuItem, NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return (item, menu)
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?,
                            _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
                            symbol: String? = nil, alternate: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.image = MenuIcons.image(symbol)
        item.isAlternate = alternate
        menu.addItem(item)
        return item
    }

    private static func key(_ functionKey: Int) -> String {
        String(Character(UnicodeScalar(functionKey)!))
    }

    private static func appMenu() -> NSMenuItem {
        let (item, menu) = submenu("Tursora")
        add(menu, "About Tursora", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(AppDelegate.showSettings(_:)), ",")
        menu.addItem(.separator())
        add(menu, "Hide Tursora", #selector(NSApplication.hide(_:)), "h")
        add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, "Quit Tursora", #selector(NSApplication.terminate(_:)), "q")
        return item
    }

    private static func fileMenu() -> NSMenuItem {
        let (item, menu) = submenu("File")
        add(menu, "New Window", #selector(AppDelegate.newWindow(_:)), "n", symbol: "plus.rectangle")
        add(menu, "New Tab", #selector(MainWindowController.newTab(_:)), "t", symbol: "macwindow.badge.plus")
        add(menu, "New Folder", #selector(MainWindowController.newFolder(_:)), "n", [.command, .shift], symbol: "folder.badge.plus")
        menu.addItem(.separator())
        add(menu, "Open", #selector(MainWindowController.openSelection(_:)), key(NSDownArrowFunctionKey))
        add(menu, "Quick Look", #selector(BrowserViewController.quickLook(_:)), "y", symbol: "eye")
        menu.addItem(.separator())
        // Finder: ⌘I, with ⌥ and ⌃ alternates on the same row.
        add(menu, "Get Info", #selector(MainWindowController.getInfo(_:)), "i", symbol: "info.circle")
        add(menu, "Show Inspector", #selector(MainWindowController.showInspector(_:)), "i", [.command, .option], symbol: "info.circle", alternate: true)
        add(menu, "Get Summary Info", #selector(MainWindowController.getSummaryInfo(_:)), "i", [.command, .control], symbol: "info.circle", alternate: true)
        add(menu, "Rename", #selector(BrowserViewController.renameSelection(_:)), symbol: "pencil")
        add(menu, "Duplicate", #selector(BrowserViewController.duplicate(_:)), "d", symbol: "plus.square.on.square")
        add(menu, "Compress", #selector(MainWindowController.compressSelection(_:)), symbol: "doc.zipper")
        add(menu, "Extract", #selector(MainWindowController.extractSelection(_:)), symbol: "doc.zipper")
        add(menu, "Move to Trash", #selector(BrowserViewController.moveToTrash(_:)), "\u{8}", symbol: "trash")
        add(menu, "Delete Immediately…", #selector(BrowserViewController.deletePermanently(_:)), "\u{8}", [.command, .option], symbol: "trash")
        menu.addItem(.separator())
        add(menu, "Close Tab", #selector(MainWindowController.closeTab(_:)), "w")
        add(menu, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        add(menu, "Reopen Closed Tab", #selector(MainWindowController.reopenClosedTab(_:)), "t", [.command, .shift])
        return item
    }

    private static func editMenu() -> NSMenuItem {
        let (item, menu) = submenu("Edit")
        add(menu, "Undo", Selector(("undo:")), "z", symbol: "arrow.uturn.backward")
        add(menu, "Redo", Selector(("redo:")), "Z", symbol: "arrow.uturn.forward")
        menu.addItem(.separator())
        add(menu, "Cut", #selector(NSText.cut(_:)), "x", symbol: "scissors")
        add(menu, "Copy", #selector(NSText.copy(_:)), "c", symbol: "document.on.document|doc.on.doc")
        add(menu, "Paste", #selector(NSText.paste(_:)), "v", symbol: "document.on.clipboard|doc.on.clipboard")
        add(menu, "Select All", #selector(NSText.selectAll(_:)), "a", symbol: "character.textbox")
        menu.addItem(.separator())
        add(menu, "Copy to Other Pane", #selector(BrowserViewController.copyToOtherPane(_:)), "c", [.command, .shift])
        add(menu, "Move to Other Pane", #selector(BrowserViewController.moveToOtherPane(_:)), "m", [.command, .shift])
        return item
    }

    private static func viewMenu() -> NSMenuItem {
        let (item, menu) = submenu("View")
        add(menu, "as Icons", #selector(BrowserViewController.viewAsIcons(_:)), "1", [.command, .option], symbol: "square.grid.2x2")
        add(menu, "as List", #selector(BrowserViewController.viewAsList(_:)), "2", [.command, .option], symbol: "list.bullet")
        menu.addItem(.separator())
        add(menu, "Zoom In", #selector(BrowserViewController.zoomIn(_:)), "+", symbol: "plus.magnifyingglass")
        add(menu, "Zoom Out", #selector(BrowserViewController.zoomOut(_:)), "-", symbol: "minus.magnifyingglass")
        add(menu, "Actual Size", #selector(BrowserViewController.zoomActualSize(_:)), "0")
        add(menu, "Show Previews", #selector(BrowserViewController.togglePreviews(_:)), "p", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Filter", #selector(MainWindowController.focusFilter(_:)), "f", symbol: "magnifyingglass")
        add(menu, "Show Hidden Files", #selector(MainWindowController.toggleHiddenFiles(_:)), ".", [.command, .shift])
        add(menu, "Reload", #selector(MainWindowController.reload(_:)), "r", symbol: "arrow.clockwise")
        menu.addItem(.separator())
        add(menu, "Use Groups", #selector(MainWindowController.toggleGroups(_:)), "0", [.command, .control], symbol: "square.grid.3x1.below.line.grid.1x2")
        menu.addItem(groupByMenuItem())
        let (sortItem, sortMenu) = submenu("Sort By")
        for (title, key) in [("Name", "name"), ("Date Modified", "dateModified"), ("Size", "size"), ("Kind", "kind")] {
            add(sortMenu, title, #selector(MainWindowController.sortBy(_:)), "", []).representedObject = key
        }
        sortMenu.addItem(.separator())
        add(sortMenu, "Ascending", #selector(MainWindowController.toggleSortOrder(_:)), "", [])
        menu.addItem(sortItem)
        menu.addItem(.separator())
        add(menu, "Split View", #selector(MainWindowController.toggleSplit(_:)), "d", [.command, .shift], symbol: "rectangle.split.2x1")
        add(menu, "Focus Other Pane", #selector(MainWindowController.focusOtherPane(_:)), "\t", [.option])
        menu.addItem(.separator())
        add(menu, "Show Terminal", #selector(MainWindowController.toggleTerminal(_:)), key(NSF4FunctionKey), [])
        add(menu, "Show Sidebar", #selector(MainWindowController.toggleSidebar(_:)), "s", [.command, .control], symbol: "sidebar.leading")
        return item
    }

    /// Common file commands from Finder, scoped to the active pane by the window.
    enum FileAction: String {
        case newFolder, open, getInfo, quickLook, rename, duplicate, compress, extract, copy, paste, trash
    }

    static func actionsMenu(target: MainWindowController) -> NSMenu {
        let menu = NSMenu(title: "More")
        let commands: [(String, FileAction, String?)] = [
            ("New Folder", .newFolder, "folder.badge.plus"),
            ("Open", .open, nil),
            ("Get Info", .getInfo, "info.circle"),
            ("Quick Look", .quickLook, "eye"),
            ("Rename", .rename, "pencil"),
            ("Duplicate", .duplicate, "plus.square.on.square"),
            ("Compress", .compress, "doc.zipper"),
            ("Extract", .extract, "doc.zipper"),
            ("Copy", .copy, "document.on.document|doc.on.doc"),
            ("Paste", .paste, "document.on.clipboard|doc.on.clipboard"),
            ("Move to Trash", .trash, "trash"),
        ]
        for (title, command, symbol) in commands {
            if command == .rename || command == .copy || command == .trash { menu.addItem(.separator()) }
            let item = add(menu, title, #selector(MainWindowController.performFileAction(_:)), symbol: symbol)
            item.target = target
            item.representedObject = command.rawValue
        }
        return menu
    }

    /// Finder's Group By submenu, also used by the toolbar's Group button.
    static func groupByMenuItem() -> NSMenuItem {
        let (item, menu) = submenu("Group By")
        item.image = MenuIcons.image("arrow.up.arrow.down")
        let keys: [(GroupKey, String)] = [
            (.none, "0"), (.name, "1"), (.kind, "2"), (.application, ""), (.dateLastOpened, "3"),
            (.dateAdded, "4"), (.dateModified, "5"), (.dateCreated, "6"), (.size, "7"),
        ]
        for (key, shortcut) in keys {
            let mi = add(menu, key.title, #selector(MainWindowController.groupBy(_:)), shortcut, shortcut.isEmpty ? [] : [.command, .control])
            mi.representedObject = key.rawValue
            if key == .none { menu.addItem(.separator()) }
        }
        return item
    }

    private static func goMenu() -> NSMenuItem {
        let (item, menu) = submenu("Go")
        add(menu, "Back", #selector(MainWindowController.goBack(_:)), "[", symbol: "chevron.backward")
        add(menu, "Forward", #selector(MainWindowController.goForward(_:)), "]", symbol: "chevron.forward")
        add(menu, "Enclosing Folder", #selector(MainWindowController.goUp(_:)), key(NSUpArrowFunctionKey), symbol: "arrow.up.folder|folder")
        menu.addItem(.separator())
        add(menu, "Home", #selector(MainWindowController.goHome(_:)), "h", [.command, .shift], symbol: "house")
        menu.addItem(.separator())
        add(menu, "Edit Location", #selector(MainWindowController.editLocation(_:)), "l")
        add(menu, "Go to Folder…", #selector(MainWindowController.editLocation(_:)), "g", [.command, .shift], symbol: "arrow.forward.folder|folder")
        add(menu, "Connect to Server…", #selector(MainWindowController.connectToServer(_:)), "k", symbol: "rectangle.connected.to.line.below")
        return item
    }

    private static func windowMenu() -> NSMenuItem {
        let (item, menu) = submenu("Window")
        add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, "Show Previous Tab", #selector(MainWindowController.previousTab(_:)), "[", [.command, .shift])
        add(menu, "Show Next Tab", #selector(MainWindowController.nextTab(_:)), "]", [.command, .shift])
        menu.addItem(.separator())
        add(menu, "File Operations", #selector(AppDelegate.showFileOperations(_:)))
        menu.addItem(.separator())
        add(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = menu
        return item
    }

    private static func helpMenu() -> NSMenuItem {
        let (item, menu) = submenu("Help")
        NSApp.helpMenu = menu
        return item
    }
}

/// SF Symbols for menu items — the names Finder's own MenuBar.nib uses where
/// it names one, the obvious system symbol elsewhere. "a|b" lists fallbacks
/// for names that are newer than the deployment target.
enum MenuIcons {
    static func image(_ spec: String?) -> NSImage? {
        guard let spec else { return nil }
        for name in spec.split(separator: "|") {
            if let img = NSImage(systemSymbolName: String(name), accessibilityDescription: nil) { return img }
        }
        return nil
    }
}
