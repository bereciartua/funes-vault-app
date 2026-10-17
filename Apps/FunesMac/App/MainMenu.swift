import AppKit

/// The main menu while a window is open. An accessory app still needs Edit's items, or ⌘C, ⌘V
/// and ⌘Z don't reach text fields.
@MainActor
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Funes Vault")
        app.addItem(withTitle: String(localized: "About Funes Vault"),
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(item(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), ",", target))
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Hide Funes Vault"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: String(localized: "Quit Funes Vault"), action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")
        add(app, to: main)

        let file = NSMenu(title: String(localized: "File"))
        file.addItem(item(String(localized: "New Memory"), #selector(AppDelegate.newMemory(_:)), "n", target))
        let remember = item(String(localized: "Remember…"), #selector(AppDelegate.remember(_:)), "m", target)
        remember.keyEquivalentModifierMask = [.option, .command]
        file.addItem(remember)
        file.addItem(.separator())
        file.addItem(withTitle: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, to: main)

        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.shift, .command]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(item(String(localized: "Find…"), #selector(AppDelegate.findInVault(_:)), "f", target))
        add(edit, to: main)

        let view = NSMenu(title: String(localized: "View"))
        for (index, section) in AppSection.allCases.enumerated() {
            let entry = item(section.title, #selector(AppDelegate.showSection(_:)), "\(index + 1)", target)
            entry.representedObject = section.rawValue
            view.addItem(entry)
        }
        add(view, to: main)

        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)),
                       keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(window, to: main)
        NSApp.windowsMenu = window
        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
    }
}
