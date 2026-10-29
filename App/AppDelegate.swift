// Menu bar UI: status icon + menu, on top of the scheduler in Scheduler.swift. AppKit
// only, no third-party deps. The menu bar glyph is a template image with a per-state badge
// (menuBarImage in About.swift); vault submenu items use SF Symbols.
// Config changes (Settings window, import, hand edits of config.json) land in
// applyConfig(), which re-applies everything live.
import Cocoa

func promptText(title: String, message: String, defaultValue: String, confirm: String, fieldLabel: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: confirm)
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.stringValue = defaultValue
    field.setAccessibilityLabel(fieldLabel)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    NSApp.activate()
    return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // ponytail: a serial queue instead of a lock — overlapping scheduleCheck() calls
    // (an FSEvent landing during an already-open hour-long dialog) just queue up harmlessly.
    let checkQueue = DispatchQueue(label: "com.roypadina.obsidian-vault-git-watcher.check")
    // statuses run git too; off the main thread, and never stuck behind an open dialog
    let statusQueue = DispatchQueue(label: "com.roypadina.obsidian-vault-git-watcher.status")
    var checkPending = false
    var refreshPending = false
    var refreshAgain = false
    var deadlineTimer: Timer?
    var safetyNetTimer: Timer?
    let watcher = VaultWatcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = mainMenu()
        statusItem.button?.imagePosition = .imageLeading

        store.onApply = { [weak self] in self?.applyConfig() }
        watcher.onEvents = { [weak self] in self?.handleEvents($0) }

        // ponytail: FSEvents can coalesce or drop events under load; a cheap 30-min
        // full rescan is a safety net so a dropped event can't wedge the reminder
        // forever. Drop this if it's never observed to matter in practice.
        safetyNetTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.scheduleCheck()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        applyConfig() // also the catch-up check: covers login and "was quit for a while"
        logLine("Started, watching \(store.active.count) of \(store.vaults.count) vaults")
        // first run of an installed copy: start at login by default (a reminder app has to run)
        if store.isFirstRun, Bundle.main.bundlePath.hasPrefix("/Applications/"), !LaunchAgent.isInstalled {
            LaunchAgent.setEnabled(true)
        }
        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            WelcomeWindow.show() // its Open Settings button leads to the Vaults pane
        } else if store.config.vaults.isEmpty { openSettings() } // unreadable config, or every vault removed: nothing to watch yet
    }

    /// Opening the app again (Finder, Spotlight) while it runs shows Settings: the way
    /// back when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    /// Launch, and every config change: log file, watched paths, menu, timers, a check.
    func applyConfig() {
        redirectLog(store.config.logFile)
        watcher.stop()
        watcher.start(paths: Array(Set(store.active.map(\.path) + [store.dir])))
        refreshDisplay()
        scheduleCheck()
    }

    /// FSEvents: config.json changed -> reload it; a vault changed outside its ignored paths -> check.
    func handleEvents(_ paths: [String]) {
        // async: a reload restarts the FSEvents stream, which mustn't happen inside its own callback
        if paths.contains(resolved(store.path)) { DispatchQueue.main.async { store.reloadFromDisk() } }
        let active = store.active.map { ($0, resolved($0.path)) }
        if paths.contains(where: { p in active.contains { $0.0.isRelevant(p, realPath: $0.1) } }) { scheduleCheck() }
    }

    // Timer deadlines drift across sleep, and the vault may have changed while asleep
    // (FSEvents delivered late or missed): re-check now, which re-arms via refreshDisplay().
    @objc func didWake() { scheduleCheck() }

    func scheduleCheck() {
        guard !checkPending else { return }
        checkPending = true
        let vs = store.active // snapshot: Settings may change the config while a dialog is open
        checkQueue.async { [weak self] in
            // one vault after another, so two reminders never stack up as nested modals;
            // the next vault is checked as soon as the previous dialog closes.
            vs.forEach(runScheduledCheck)
            DispatchQueue.main.async {
                self?.checkPending = false
                self?.refreshDisplay()
            }
        }
    }

    // MARK: - Status -> icon + menu

    func refreshDisplay() {
        guard !refreshPending else { refreshAgain = true; return }
        refreshPending = true
        let vs = store.vaults
        statusQueue.async { [weak self] in
            let statuses = vs.map { ($0, currentStatus($0)) }
            DispatchQueue.main.async { self?.show(statuses) }
        }
    }

    func show(_ statuses: [(Vault, Status)]) {
        refreshPending = false
        store.statuses = Dictionary(statuses.map { ($0.0.cfg.id, $0.1) }, uniquingKeysWith: { a, _ in a })
        let active = statuses.filter { $0.0.cfg.enabled }
        // one icon for all vaults: the most urgent state wins
        let state = ["pending", "error", "snoozed", "skipped"].first { st in active.contains { $0.1.state == st } } ?? "clean"
        let files = active.filter { ["pending", "snoozed"].contains($0.1.state) }.reduce(0) { $0 + $1.1.files }
        if let button = statusItem.button {
            button.image = menuBarImage(for: state)
            let urgent = active.first { $0.1.state == state && state != "clean" }
            let label = urgent.map { "\(appName): \($0.0.name), \(statusText($0.1))" } ?? "\(appName): all vaults clean"
            button.setAccessibilityLabel(label)
            button.toolTip = label
            button.title = store.config.showFileCount && files > 0 ? "\(files)" : ""
        }
        statusItem.isVisible = store.config.menuBarIcon == .always || ["pending", "error"].contains(state)
        statusItem.menu = buildMenu(active)
        rearmTimer()
        if refreshAgain { refreshAgain = false; refreshDisplay() }
    }

    /// Arms exactly one Timer for the earliest vault's next deadline (see
    /// nextDeadline). Called after every state change: the scheduled check, wake,
    /// and every menu action all end in refreshDisplay(), so this is the one place
    /// that keeps the timer in sync with reality.
    func rearmTimer() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let next = store.active.compactMap({ nextDeadline(loadState($0), Date(), $0.cfg) }).min() else { return }
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in self?.scheduleCheck() }
        RunLoop.main.add(t, forMode: .common)
        deadlineTimer = t
    }

    /// One submenu per watched vault, titled with the vault name and its status.
    func buildMenu(_ statuses: [(Vault, Status)]) -> NSMenu {
        let menu = NSMenu()
        if statuses.isEmpty {
            menu.addItem(withTitle: store.config.vaults.isEmpty ? "No vaults yet" : "No vault is watched", action: nil, keyEquivalent: "")
        }

        for (v, s) in statuses {
            let vaultItem = NSMenuItem(title: "\(v.name) — \(statusText(s))", action: nil, keyEquivalent: "")
            vaultItem.image = NSImage(systemSymbolName: symbolName(for: s.state), accessibilityDescription: s.state)
            let sub = NSMenu()

            if ["pending", "snoozed", "skipped"].contains(s.state) {
                addItem(sub, "Commit & push…", #selector(commitAction), v)

                let snoozeItem = NSMenuItem(title: "Snooze…", action: nil, keyEquivalent: "")
                let snoozeMenu = NSMenu()
                for h in v.cfg.snoozeHours {
                    addItem(snoozeMenu, hoursLabel(h), #selector(snoozeFor), v).tag = Int((h * 60).rounded())
                }
                addItem(snoozeMenu, "Custom…", #selector(snoozeCustom), v)
                addItem(snoozeMenu, untilLabel(v.cfg), #selector(snoozeTomorrow), v)
                snoozeItem.submenu = snoozeMenu
                sub.addItem(snoozeItem)

                addItem(sub, "Skip these changes", #selector(skipAction), v)
                sub.addItem(.separator())
            }
            if s.unpushed > 0 {
                addItem(sub, "Push \(s.unpushed) commit\(s.unpushed == 1 ? "" : "s")", #selector(pushAction), v)
                sub.addItem(.separator())
            }

            addItem(sub, "Open vault folder", #selector(openFolder), v)
            addItem(sub, "Open in Obsidian", #selector(openObsidian), v)
            addItem(sub, "Vault Settings…", #selector(openSettings), v)
            vaultItem.submenu = sub
            menu.addItem(vaultItem)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "About \(appName)", action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Support on Ko-fi ☕", action: #selector(koFi), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit \(appName)", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    /// Menu item whose action gets its vault back via representedObject.
    @discardableResult
    func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ v: Vault) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = v
        return item
    }

    /// The menu bar while a window is open and AccessoryWindows has made us a regular app (MBX-15);
    /// its key equivalents also work while the app is an accessory: ⌘, ⌘W ⌘Q and the text-editing keys.
    func mainMenu() -> NSMenu {
        let main = NSMenu(), app = NSMenu(), services = NSMenu(title: "Services")
        let window = NSMenu(title: "Window"), help = NSMenu(title: "Help")
        func add(_ m: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                 _ mask: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = m.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.target = target
        }
        add(app, "About \(appName)", #selector(about), target: self)
        app.addItem(.separator())
        add(app, "Settings…", #selector(openSettings), ",", target: self)
        app.addItem(.separator())
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        app.addItem(.separator())
        add(app, "Hide \(appName)", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")
        add(window, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        add(help, "\(appName) Help", #selector(openHelp), "?", target: self)

        let edit = NSMenu(title: "Edit")
        for (t, action, key) in [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
                                 ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                                 ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: t, action: action, keyEquivalent: key)
        }
        for (title, sub) in [(appName, app), ("Edit", edit), ("Window", window), ("Help", help)] {
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = sub
        }
        NSApp.servicesMenu = services
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        return main
    }

    @MainActor @objc func openSettings(_ sender: Any? = nil) {
        let v = (sender as? NSMenuItem)?.representedObject as? Vault
        if let v { store.selection = v.cfg.id }
        SettingsWindow.show(vaultsTab: v != nil)
        refreshDisplay()
    }

    @objc func commitAction(_ sender: NSMenuItem) {
        let v = sender.representedObject as! Vault
        guard let msg = promptText(title: "Commit \(v.name) changes", message: "Commit message (empty: \"\(v.cfg.commitMessage)\"):", defaultValue: "", confirm: "Commit", fieldLabel: "Commit message") else { return }
        cliCommit(v, msg)
        refreshDisplay()
    }

    @objc func snoozeFor(_ sender: NSMenuItem) {
        cliSnoozeHours(sender.representedObject as! Vault, String(Double(sender.tag) / 60))
        refreshDisplay()
    }

    @objc func snoozeCustom(_ sender: NSMenuItem) {
        let v = sender.representedObject as! Vault
        var message = "Snooze for how many hours?"
        var input = "3"
        // ask again until it is one positive number: cliSnoozeHours would turn "abc" into 1 hour and "0" into now
        while let text = promptText(title: "Snooze \(v.name)", message: message, defaultValue: input, confirm: "Snooze", fieldLabel: "Hours") {
            if let hours = parseHours(text), hours.count == 1 {
                cliSnoozeHours(v, String(hours[0]))
                refreshDisplay()
                return
            }
            input = text
            message = "Enter hours, for example 0.5 or 3."
        }
    }

    @objc func snoozeTomorrow(_ sender: NSMenuItem) { cliSnoozeTomorrow(sender.representedObject as! Vault); refreshDisplay() }

    @objc func skipAction(_ sender: NSMenuItem) { cliSkip(sender.representedObject as! Vault); refreshDisplay() }

    @objc func pushAction(_ sender: NSMenuItem) { pushNow(sender.representedObject as! Vault); refreshDisplay() }

    @objc func openFolder(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: (sender.representedObject as! Vault).path))
    }

    @objc func openObsidian(_ sender: NSMenuItem) {
        let v = sender.representedObject as! Vault
        if !v.cfg.obsidianVault.isEmpty,
           let name = v.cfg.obsidianVault.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
           let url = URL(string: "obsidian://open?vault=\(name)") {
            NSWorkspace.shared.open(url)
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Obsidian", v.path]
        try? p.run()
    }

    @MainActor @objc func about() { AboutWindow.show() }

    @objc func openHelp() { NSWorkspace.shared.open(repoURL.appendingPathComponent("wiki")) }

    @objc func koFi() { NSWorkspace.shared.open(koFiURL) }

    @objc func quit() { NSApp.terminate(nil) }
}
