import AppKit

/// The main menu, built in code (no nib). Items use nil targets so the
/// responder chain decides who handles them: the window controller for
/// navigation, the file list for selection-related commands, text fields for
/// editing commands.
enum MainMenu {

    static func build() -> NSMenu {
        ShortcutDispatcher.installInputProtection()
        let menu = makeMenu(registerSystemMenus: true)
        applyPreferences(to: menu)
        return menu
    }

    /// Builds the same declarations without mutating NSApp or reading settings.
    /// This keeps the shortcut catalog complete when commands are added later.
    static func shortcutDefinitions() -> [ShortcutAction] {
        var result: [ShortcutAction] = []
        func visit(_ menu: NSMenu, category: String) {
            for item in menu.items {
                if let submenu = item.submenu {
                    visit(submenu, category: category.isEmpty ? item.title : category + " → " + item.title)
                } else if let action = item.action {
                    result.append(ShortcutAction(id: item.identifier!.rawValue, title: item.title,
                        category: category, selector: NSStringFromSelector(action),
                        representedObject: item.representedObject as? String,
                        defaultShortcut: item.keyEquivalent.isEmpty ? nil : .init(keyEquivalent: item.keyEquivalent,
                            modifierFlags: item.keyEquivalentModifierMask), context: .application))
                }
            }
        }
        visit(makeMenu(registerSystemMenus: false), category: "")
        return result
    }

    private static func makeMenu(registerSystemMenus: Bool) -> NSMenu {
        let menu = ShortcutMenu()
        menu.addItem(appMenu())
        menu.addItem(fileMenu())
        menu.addItem(editMenu())
        menu.addItem(viewMenu())
        menu.addItem(goMenu())
        menu.addItem(windowMenu(registerSystemMenus: registerSystemMenus))
        menu.addItem(helpMenu(registerSystemMenus: registerSystemMenus))
        assignShortcutIdentifiers(in: menu)
        return menu
    }

    private static func assignShortcutIdentifiers(in menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { assignShortcutIdentifiers(in: submenu) }
            guard let action = item.action else { continue }
            var id = "menu." + NSStringFromSelector(action).replacingOccurrences(of: ":", with: "")
            if let argument = item.representedObject as? String { id += "." + argument }
            if item.title == "Go to Folder…" { id += ".goToFolder" }
            item.identifier = NSUserInterfaceItemIdentifier(id)
        }
    }

    static func applyPreferences(to menu: NSMenu, shortcuts: ShortcutStore = AppPreferences.shared.shortcuts) {
        for item in menu.items {
            if let submenu = item.submenu { applyPreferences(to: submenu, shortcuts: shortcuts) }
            if let id = item.identifier?.rawValue, ShortcutCatalog.action(id) != nil {
                let binding = shortcuts.shortcut(for: id)
                item.keyEquivalent = binding?.keyEquivalent ?? ""
                item.keyEquivalentModifierMask = binding?.modifierFlags ?? []
                // Arbitrary bindings cannot remain AppKit alternates: alternates
                // require adjacent rows sharing an equivalent and base modifiers.
                if ["menu.showInspector", "menu.getSummaryInfo"].contains(id) {
                    let info = shortcuts.shortcut(for: "menu.getInfo")
                    func compatible(_ value: AppPreferences.Shortcut?) -> Bool {
                        guard let value, let info else { return false }
                        return value.keyEquivalent == info.keyEquivalent
                            && value.modifierFlags.isSuperset(of: info.modifierFlags)
                            && value.modifierFlags != info.modifierFlags
                    }
                    // Summary can join Get Info only through the immediately
                    // preceding compatible Inspector alternate. An independently
                    // rebound/cleared Inspector starts a new menu row instead.
                    item.isAlternate = compatible(binding) && (id == "menu.showInspector"
                        || compatible(shortcuts.shortcut(for: "menu.showInspector")))
                }
                if let baseID = ["menu.moveItemsHere": "menu.paste", "menu.deselectAllFiles": "menu.selectAll"][id] {
                    let base = shortcuts.shortcut(for: baseID)
                    item.isAlternate = binding != nil && base != nil
                        && binding!.keyEquivalent == base!.keyEquivalent
                        && binding!.modifierFlags.isSuperset(of: base!.modifierFlags)
                        && binding!.modifierFlags != base!.modifierFlags
                }
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
        add(menu, "Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)))
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
        add(menu, "New Folder with Selection", #selector(BrowserViewController.newFolderWithSelection(_:)), "n", [.command, .control], symbol: "folder.badge.plus")
        menu.addItem(.separator())
        add(menu, "Open", #selector(MainWindowController.openSelection(_:)), key(NSDownArrowFunctionKey))
        add(menu, "Show Package Contents", #selector(BrowserViewController.showPackageContents(_:)))
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
        // Finder puts Empty Trash on ⇧⌘⌫, but NSMenu ignores Shift for a ⌫ key
        // equivalent: a ⇧⌘⌫ item answers a plain ⌘⌫ event and vice versa (probed
        // on this machine; see docs/research/trash.md). Move to Trash comes first,
        // so ⇧⌘⌫ would reach it instead — and once a user clears that binding,
        // ⌘⌫ would reach Empty Trash, which cannot be undone. It ships unbound and
        // stays assignable from Settings ▸ Shortcuts.
        add(menu, TrashLocation.emptyTrashMenuTitle, #selector(BrowserViewController.emptyTrash(_:)), "", [], symbol: "trash.slash")
        menu.addItem(.separator())
        add(menu, "Close Tab", #selector(MainWindowController.closeTab(_:)), "w")
        add(menu, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        add(menu, "Reopen Closed Tab", #selector(MainWindowController.reopenClosedTab(_:)), "t", [.command, .shift])
        let recent = NSMenuItem(title: "Recently Closed Tabs", action: nil, keyEquivalent: "")
        recent.submenu = RecentlyClosedTabsMenu()
        menu.addItem(recent)
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
        add(menu, "Move Items Here", #selector(BrowserViewController.moveItemsHere(_:)), "v", [.command, .option], alternate: true)
        add(menu, "Select All", #selector(NSText.selectAll(_:)), "a", symbol: "character.textbox")
        add(menu, "Deselect All", #selector(BrowserViewController.deselectAllFiles(_:)), "a", [.command, .option], alternate: true)
        add(menu, "Invert Selection", #selector(BrowserViewController.invertFileSelection(_:)))
        menu.addItem(.separator())
        add(menu, "Copy to Other Pane", #selector(BrowserViewController.copyToOtherPane(_:)), "c", [.command, .shift])
        add(menu, "Move to Other Pane", #selector(BrowserViewController.moveToOtherPane(_:)), "m", [.command, .shift])
        return item
    }

    private static func viewMenu() -> NSMenuItem {
        let (item, menu) = submenu("View")
        add(menu, "as Icons", #selector(BrowserViewController.viewAsIcons(_:)), "1", [.command, .option], symbol: "square.grid.2x2")
        add(menu, "as List", #selector(BrowserViewController.viewAsList(_:)), "2", [.command, .option], symbol: "list.bullet")
        add(menu, "as Columns", #selector(BrowserViewController.viewAsColumns(_:)), "3", [.command, .option], symbol: "rectangle.split.3x1")
        add(menu, "Show View Options", #selector(MainWindowController.showViewOptions(_:)), "j", symbol: "slider.horizontal.3")
        menu.addItem(.separator())
        add(menu, "Zoom In", #selector(BrowserViewController.zoomIn(_:)), "+", symbol: "plus.magnifyingglass")
        add(menu, "Zoom Out", #selector(BrowserViewController.zoomOut(_:)), "-", symbol: "minus.magnifyingglass")
        add(menu, "Actual Size", #selector(BrowserViewController.zoomActualSize(_:)), "0")
        // ⇧⌘P is Finder's preview pane, so the pane takes it and the
        // thumbnail toggle moves to ⌃⌘P (D82). A user who had already
        // customised either binding keeps their own choice: the store
        // only supplies a default where the user set nothing.
        add(menu, "Show Preview", #selector(MainWindowController.togglePreviewPane(_:)), "p", [.command, .shift],
            symbol: "sidebar.right")
        add(menu, "Show Previews", #selector(BrowserViewController.togglePreviews(_:)), "p", [.command, .control])
        menu.addItem(.separator())
        add(menu, "Search…", #selector(MainWindowController.showSearch(_:)), "f", [.command, .shift], symbol: "doc.text.magnifyingglass")
        add(menu, "Filter", #selector(MainWindowController.focusFilter(_:)), "f", symbol: "magnifyingglass")
        add(menu, "Show Hidden Files", #selector(MainWindowController.toggleHiddenFiles(_:)), ".", [.command, .shift])
        add(menu, "Reload", #selector(MainWindowController.reload(_:)), "r", symbol: "arrow.clockwise")
        menu.addItem(.separator())
        add(menu, "Use Groups", #selector(MainWindowController.toggleGroups(_:)), "0", [.command, .control], symbol: "square.grid.3x1.below.line.grid.1x2")
        menu.addItem(groupByMenuItem(applyBindings: false))
        let (sortItem, sortMenu) = submenu("Sort By")
        for (title, key) in [("Name", "name"), ("Date Modified", "dateModified"),
                             ("Date Created", "dateCreated"), ("Date Last Opened", "dateLastOpened"),
                             ("Date Added", "dateAdded"), ("Size", "size"), ("Kind", "kind")] {
            add(sortMenu, title, #selector(MainWindowController.sortBy(_:)), "", []).representedObject = key
        }
        sortMenu.addItem(.separator())
        add(sortMenu, "Ascending", #selector(MainWindowController.toggleSortOrder(_:)), "", [])
        menu.addItem(sortItem)
        menu.addItem(.separator())
        let (memoryItem, memoryMenu) = submenu("Folder View Settings")
        add(memoryMenu, "Remember Each Folder", #selector(MainWindowController.rememberFolderViews(_:)), "", [])
        add(memoryMenu, "Use One View for All Folders", #selector(MainWindowController.useUnifiedFolderView(_:)), "", [])
        memoryMenu.addItem(.separator())
        add(memoryMenu, "Use Current Settings as Default", #selector(MainWindowController.useCurrentViewAsDefault(_:)), "", [])
        add(memoryMenu, "Restore This Folder to Default", #selector(MainWindowController.restoreFolderViewDefaults(_:)), "", [])
        memoryMenu.addItem(.separator())
        add(memoryMenu, "Calculate all sizes", #selector(MainWindowController.toggleCalculateAllSizes(_:)), "", [])
        menu.addItem(memoryItem)
        menu.addItem(.separator())
        add(menu, "Split View", #selector(MainWindowController.toggleSplit(_:)), "d", [.command, .shift], symbol: "rectangle.split.2x1")
        add(menu, "Focus Other Pane", #selector(MainWindowController.focusOtherPane(_:)), "\t", [.option])
        menu.addItem(.separator())
        add(menu, "Show Terminal", #selector(MainWindowController.toggleTerminal(_:)), key(NSF4FunctionKey), [])
        add(menu, "Show Sidebar", #selector(MainWindowController.toggleSidebar(_:)), "s", [.command, .control], symbol: "sidebar.leading")
        add(menu, "Show Folders", #selector(MainWindowController.toggleFoldersPanel(_:)), key(NSF7FunctionKey), [], symbol: "list.bullet.indent")
        menu.addItem(.separator())
        // ⇧⌘P already belongs to Show Previews; ⇧⌘O is free and matches the
        // "open quickly" convention. Customisable through the shortcut catalog.
        add(menu, "Command Palette…", #selector(MainWindowController.showCommandPalette(_:)), "o", [.command, .shift], symbol: "command")
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
    static func groupByMenuItem(applyBindings: Bool = true) -> NSMenuItem {
        let (item, menu) = submenu("Group By")
        item.image = MenuIcons.image("arrow.up.arrow.down")
        let keys: [(GroupKey, String)] = [
            (.none, ""), (.name, "1"), (.kind, "2"), (.application, ""), (.dateLastOpened, "3"),
            (.dateAdded, "4"), (.dateModified, "5"), (.dateCreated, "6"), (.size, "7"),
        ]
        for (key, shortcut) in keys {
            let mi = add(menu, key.title, #selector(MainWindowController.groupBy(_:)), shortcut, shortcut.isEmpty ? [] : [.command, .control])
            mi.representedObject = key.rawValue
            if key == .none { menu.addItem(.separator()) }
        }
        assignShortcutIdentifiers(in: menu)
        if applyBindings { applyPreferences(to: menu) }
        return item
    }

    private static func goMenu() -> NSMenuItem {
        let (item, menu) = submenu("Go")
        add(menu, "Back", #selector(MainWindowController.goBack(_:)), "[", symbol: "chevron.backward")
        add(menu, "Forward", #selector(MainWindowController.goForward(_:)), "]", symbol: "chevron.forward")
        add(menu, "Enclosing Folder", #selector(MainWindowController.goUp(_:)), key(NSUpArrowFunctionKey), symbol: "arrow.up.folder|folder")
        menu.addItem(.separator())
        add(menu, "Home", #selector(MainWindowController.goHome(_:)), "h", [.command, .shift], symbol: "house")
        add(menu, TrashLocation.placeName, #selector(MainWindowController.goTrash(_:)), symbol: TrashLocation.symbolName)
        menu.addItem(.separator())
        add(menu, "Edit Location", #selector(MainWindowController.editLocation(_:)), "l")
        add(menu, "Go to Folder…", #selector(MainWindowController.editLocation(_:)), "g", [.command, .shift], symbol: "arrow.forward.folder|folder")
        add(menu, "Connect to Server…", #selector(MainWindowController.connectToServer(_:)), "k", symbol: "rectangle.connected.to.line.below")
        return item
    }

    private static func windowMenu(registerSystemMenus: Bool) -> NSMenuItem {
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
        if registerSystemMenus { NSApp.windowsMenu = menu }
        return item
    }

    private static func helpMenu(registerSystemMenus: Bool) -> NSMenuItem {
        let (item, menu) = submenu("Help")
        if registerSystemMenus { NSApp.helpMenu = menu }
        return item
    }
}

/// NSEvent and NSMenu use different Backspace / Forward Delete characters.
/// Normalize a copy solely for menu matching, leaving the responder's original
/// editing / terminal event intact when no enabled menu item handles it.
private final class ShortcutMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        super.performKeyEquivalent(with: AppPreferences.Shortcut.eventForMenu(event))
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
