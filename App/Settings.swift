// Settings window: toolbar tabs (General, Vaults) in an AppKit window, SwiftUI inside.
// Every control edits `store.config` directly; ConfigStore saves config.json and the app
// re-applies it live (AppDelegate.applyConfig). Text that needs checking is held as a
// draft and only written once valid, with the problem shown under the field.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// One size per pane (SET-8): General is a form, Vaults needs the width for its split view.
private let generalSize = CGSize(width: 800, height: 780)
private let vaultsSize = CGSize(width: 800, height: 600)

/// Real windows from a menu-bar-only app (MBX-15): Dock icon and menu bar while one is open, back to
/// `.accessory` when the last one closes. The reminder's NSAlert can't become main, so it doesn't count.
@MainActor
final class AccessoryWindows: NSObject, NSWindowDelegate {
    static let shared = AccessoryWindows()

    func show(_ window: NSWindow) {
        window.delegate = self
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
        if !others { NSApp.setActivationPolicy(.accessory) }
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(vaultsTab: Bool = false) {
        let w = window ?? make()
        window = w
        if vaultsTab { (w.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = 1 }
        AccessoryWindows.shared.show(w)
    }

    private static func make() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for (label, symbol, view, size) in [("General", "gearshape", AnyView(GeneralPane()), generalSize),
                                            ("Vaults", "folder", AnyView(VaultsPane()), vaultsSize)] {
            let host = NSHostingController(rootView: view.environmentObject(store))
            host.sizingOptions = [] // fixed pane size; the tab view controller sizes the window from it
            host.preferredContentSize = size
            host.title = label // becomes the window title
            let item = NSTabViewItem(viewController: host)
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = 1
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.miniaturizeButton)?.isEnabled = false // the window can't resize: dim, don't hide
        w.standardWindowButton(.zoomButton)?.isEnabled = false
        w.center()
        return w
    }
}

// MARK: - General

struct GeneralPane: View {
    @EnvironmentObject var store: ConfigStore
    @SwiftUI.State private var note: (text: String, isError: Bool)?

    var body: some View {
        Form {
            if let error = store.loadError {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            Section("Startup") { LaunchAtLoginToggle() }
            Section("Menu bar") {
                Picker("Show the icon", selection: $store.config.menuBarIcon) {
                    Text("Always").tag(IconMode.always)
                    Text("Only when a vault needs attention").tag(IconMode.whenNeeded)
                }
                Toggle("Show the number of uncommitted files", isOn: $store.config.showFileCount)
                if store.config.menuBarIcon == .whenNeeded {
                    Caption("While the icon is hidden, open the app again (from Finder or Spotlight) to get back to Settings.")
                }
            }
            Section("Log") {
                LabeledContent("Log file") { PathText(path: store.config.logFile) }
                HStack {
                    Spacer()
                    Button("Change…", action: chooseLog)
                    Button("Show in Finder") { reveal(expand(store.config.logFile)) }
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: expand(store.config.logFile))) }
                }
            }
            Section("Configuration") {
                LabeledContent("Config file") { PathText(path: store.path) }
                HStack {
                    Spacer()
                    Button("Show in Finder") { reveal(store.path) }
                    Button("Export…", action: exportConfig)
                    Button("Import…", action: importConfig)
                }
                if let note { Text(note.text).font(.caption).foregroundStyle(note.isError ? .red : .secondary) }
            }
            Section("About") {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(appName).font(.headline)
                        Text("Version " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("About \(appName)…") { AboutWindow.show() }
                    Button("Welcome Guide…") { WelcomeWindow.show() }
                    Button("Support on Ko-fi ☕") { NSWorkspace.shared.open(koFiURL) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: generalSize.width, height: generalSize.height)
    }

    func chooseLog() {
        let panel = NSSavePanel()
        let current = URL(fileURLWithPath: expand(store.config.logFile))
        panel.directoryURL = current.deletingLastPathComponent()
        panel.nameFieldStringValue = current.lastPathComponent
        panel.prompt = "Use"
        panel.message = "Choose where the app writes its log."
        if panel.runModal() == .OK, let url = panel.url { store.config.logFile = abbreviate(url.path) }
    }

    func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ObsidianVaultGitWatcher-config.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = store.exportData() else { return }
        do {
            try data.write(to: url, options: .atomic)
            note = ("Exported \(store.config.vaults.count) vault(s) to \(abbreviate(url.path)).", false)
        } catch {
            note = ("Export failed: \(error.localizedDescription)", true)
        }
    }

    func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let c = try parseConfig(try Data(contentsOf: url))
            let alert = NSAlert()
            alert.messageText = "Replace your settings with “\(url.lastPathComponent)”?"
            alert.informativeText = "Its \(c.vaults.count) vault(s) replace the \(store.config.vaults.count) you have now. "
                + "Vault folders are not touched. The current config is kept as config.json.bak."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            store.importConfig(c)
            note = ("Imported \(c.vaults.count) vault(s) from \(url.lastPathComponent).", false)
        } catch {
            note = ("Can't import \(url.lastPathComponent): \(error)", true)
        }
    }
}

/// Settings > General and the welcome window: the LaunchAgent switch (not SMAppService: KeepAlive restarts after a crash).
/// A Group, so each caller lays the toggle and its help out in its own container.
struct LaunchAtLoginToggle: View {
    @SwiftUI.State private var launchAtLogin = false

    var body: some View {
        Group {
            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: {
                LaunchAgent.setEnabled($0)
                launchAtLogin = LaunchAgent.isEnabled
            }))
            // Process.waitUntilExit spins the run loop: never call it while SwiftUI is updating
            .task { launchAtLogin = await Task.detached { LaunchAgent.isEnabled }.value }
            Caption("Starts the app when you log in and restarts it if it crashes. Quit stops it until the next login.")
        }
    }
}

/// Start at login = a LaunchAgent plist in ~/Library/LaunchAgents (install.sh writes the
/// same one). launchd loads it at the next login: turning it on never starts a second copy
/// now, turning it off never stops this one. KeepAlive only after a crash, so Quit quits.
enum LaunchAgent {
    static let label = "com.roypadina.obsidian-vault-git-watcher"
    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }
    static var isEnabled: Bool {
        guard isInstalled else { return false }
        let out = launchctl(["print-disabled", "gui/\(getuid())"])
        return !out.contains("\"\(label)\" => disabled") && !out.contains("\"\(label)\" => true")
    }

    static func setEnabled(_ on: Bool) {
        guard on else {
            try? FileManager.default.removeItem(atPath: plistPath)
            logLine("Launch at login off")
            return
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [Bundle.main.executablePath ?? "/Applications/ObsidianVaultGitWatcher.app/Contents/MacOS/ObsidianVaultGitWatcher"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
        ]
        do {
            try FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            _ = launchctl(["enable", "gui/\(getuid())/\(label)"]) // clears an old "disabled" override
            logLine("Launch at login on")
        } catch {
            logLine("Can't write \(plistPath): \(error)")
        }
    }

    private static func launchctl(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Vaults

struct VaultsPane: View {
    @EnvironmentObject var store: ConfigStore
    @SwiftUI.State private var removing: VaultConfig?
    @SwiftUI.State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Divider()
            }
            panes
        }
        .frame(width: vaultsSize.width, height: vaultsSize.height)
        .onAppear { if selected == nil { store.selection = store.config.vaults.first?.id } }
        .alert("Remove “\(removing?.displayName ?? "")”?",
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { v in
            Button("Remove", role: .destructive) { store.remove(v.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The app stops watching this folder and forgets its reminder state. The folder and its git history are not touched.")
        }
        .alert("Can't use this folder", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(problem ?? "")
        }
    }

    var panes: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $store.selection) {
                    ForEach(store.config.vaults) { v in
                        VaultRow(vault: v, status: store.statuses[v.id], enabled: binding(v.id).enabled).tag(v.id)
                    }
                    .onMove { store.config.vaults.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset)
                .onDeleteCommand { removing = selected }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let v = store.vaultConfig(id) { contextMenu(v) }
                }
                Divider()
                HStack(spacing: 2) {
                    Button(action: add) { Image(systemName: "plus").frame(width: 22, height: 18) }
                        .help("Add a vault")
                        .accessibilityLabel("Add vault")
                    Button { removing = selected } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                        .disabled(selected == nil)
                        .help("Remove the selected vault")
                        .accessibilityLabel("Remove vault")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 260)
            Divider()
            detail
        }
    }

    var selected: VaultConfig? { store.selection.flatMap(store.vaultConfig) }

    @ViewBuilder var detail: some View {
        if let v = selected {
            VaultDetail(vault: binding(v.id), status: store.statuses[v.id], changeFolder: { changeFolder(v.id) })
                .id("\(v.id)-\(store.generation)") // fresh drafts per vault and after an outside reload
        } else {
            ContentUnavailableView {
                Label(store.config.vaults.isEmpty ? "No vaults yet" : "No vault selected", systemImage: "folder.badge.plus")
            } description: {
                Text("Add an Obsidian vault, or any git repository with a remote, to get a reminder when it has changes that aren't committed and pushed.")
            } actions: {
                Button("Add Vault…", action: add)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder func contextMenu(_ v: VaultConfig) -> some View {
        let i = store.config.vaults.firstIndex { $0.id == v.id } ?? 0
        Button("Show in Finder") { reveal(expand(v.path)) }
        Button("Move Up") { store.config.vaults.swapAt(i, i - 1) }.disabled(i == 0)
        Button("Move Down") { store.config.vaults.swapAt(i, i + 1) }.disabled(i == store.config.vaults.count - 1)
        Divider()
        Button("Remove…") { removing = v }
    }

    /// Edits the vault with this id, wherever it is in the list (safe if it's removed meanwhile).
    func binding(_ id: UUID) -> Binding<VaultConfig> {
        Binding(get: { store.vaultConfig(id) ?? VaultConfig(path: "") },
                set: { v in if let i = store.config.vaults.firstIndex(where: { $0.id == id }) { store.config.vaults[i] = v } })
    }

    func add() {
        guard let p = pickFolder(prompt: "Add Vault") else { return }
        switch store.addVault(p) {
        case .success(let id): store.selection = id
        case .failure(let e): problem = e.description
        }
    }

    func changeFolder(_ id: UUID) {
        guard let p = pickFolder(prompt: "Use Folder") else { return }
        if let e = store.changeFolder(id, to: p) { problem = e.description }
    }

    func pickFolder(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = "Choose a vault folder. It must be a git repository with a remote."
        let obsidian = NSHomeDirectory() + "/Obsidian"
        if FileManager.default.fileExists(atPath: obsidian) { panel.directoryURL = URL(fileURLWithPath: obsidian) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

struct VaultRow: View {
    @Environment(\.backgroundProminence) private var prominence // .increased: the row is selected, on the accent color
    let vault: VaultConfig
    let status: Status?
    @Binding var enabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Watch \(vault.displayName)", isOn: $enabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(vault.displayName)
                    .foregroundStyle(enabled ? .primary : .secondary)
                Text(status.map(statusText) ?? "Checking…")
                    .font(.caption)
                    .foregroundStyle(status?.state == "error" && prominence != .increased ? .red : .secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            StatusIcon(state: status?.state)
        }
        .padding(.vertical, 3)
    }
}

struct StatusIcon: View {
    @Environment(\.backgroundProminence) private var prominence
    let state: String?
    var body: some View {
        let color: Color = switch state {
        case "clean": .green
        case "pending": .orange
        case "snoozed": .blue
        case "error": .red
        default: .secondary
        }
        Image(systemName: symbolName(for: state ?? "clean"))
            .foregroundStyle(prominence == .increased ? .primary : color)
            .opacity(state == nil ? 0 : 1)
            .accessibilityHidden(true) // the status text next to it says the same
    }
}

struct VaultDetail: View {
    @Binding var vault: VaultConfig
    let status: Status?
    let changeFolder: () -> Void
    @SwiftUI.State private var remotes: [String]?

    var folderName: String { (expand(vault.path) as NSString).lastPathComponent }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    StatusIcon(state: status?.state).font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vault.displayName).font(.headline)
                        Text(status.map(statusText) ?? "Checking…")
                            .foregroundStyle(status?.state == "error" ? .red : .secondary)
                    }
                    Spacer()
                    Toggle("Watch this vault", isOn: $vault.enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help(vault.enabled ? "Watching this vault" : "Not watching this vault")
                }
            }
            Section("Vault") {
                TextField("Name", text: $vault.name, prompt: Text(folderName))
                LabeledContent("Folder") {
                    HStack {
                        PathText(path: vault.path)
                        Button("Show in Finder") { reveal(expand(vault.path)) }
                        Button("Change…", action: changeFolder)
                    }
                }
                TextField("Obsidian vault name", text: $vault.obsidianVault, prompt: Text(folderName))
                Caption("Used by Open in Obsidian. Leave it empty to open the folder with the Obsidian app.")
            }
            Section("Reminders") {
                LabeledContent("Remind after") {
                    HStack {
                        TextField("Quiet minutes", value: quietMinutes, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Stepper("Quiet minutes", value: quietMinutes, in: 1...1440, step: 5).labelsHidden()
                        Text("minutes without changes")
                    }
                }
                DatePicker("Daily reminder at", selection: reminderTime, displayedComponents: .hourAndMinute)
                LabeledContent("On") { DayPicker(days: $vault.reminderDays) }
                Caption("A dismissed reminder comes back at this time. On other days, reminders wait for the next reminder day.")
                Picker("Remind with", selection: $vault.notify) {
                    Text("A dialog").tag(NotifyStyle.dialog)
                    Text("A notification banner").tag(NotifyStyle.banner)
                }
                CheckedField(title: "Snooze options (hours)", prompt: "1, 3", value: snoozeText) {
                    parseHours($0) == nil ? "Enter hours separated by commas, for example 1, 3 or 0.5" : nil
                }
                Caption("Offered in the reminder dialog and the menu, followed by “\(untilLabel(vault))”.")
            }
            Section("Commit") {
                CheckedField(title: "Message", prompt: "Vault update {date}", value: $vault.commitMessage) {
                    $0.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter a message" : nil
                }
                Caption("Used when you leave the commit message empty. Tokens: {date} {time} {files} {vault}. "
                    + "Right now: “\(expandTemplate(vault.commitMessage, Vault(path: expand(vault.path), statePath: "", cfg: vault), files: status?.files ?? 0))”")
                Picker("Stage", selection: $vault.stage) {
                    Text("All changes, including new files (git add -A)").tag(StageMode.all)
                    Text("Only files git already tracks (git add -u)").tag(StageMode.tracked)
                }
                .pickerStyle(.radioGroup)
                IgnoreEditor(entries: $vault.ignore)
            }
            Section("Push") {
                Toggle("Push after committing", isOn: $vault.push)
                CheckedField(title: "Remote", prompt: "upstream", value: $vault.remote, check: remoteProblem)
                    .disabled(!vault.push)
                CheckedField(title: "Branch", prompt: "upstream", value: $vault.branch, check: refNameProblem)
                    .disabled(!vault.push)
                Caption("Leave both empty to push to the current branch's upstream.")
            }
        }
        .formStyle(.grouped)
        .task { // off the main thread: Process.waitUntilExit spins the run loop
            let path = expand(vault.path)
            remotes = await Task.detached { (try? git(Vault(path: path, statePath: ""), ["remote"]))?.split(separator: "\n").map(String.init) }.value
        }
    }

    var quietMinutes: Binding<Int> {
        Binding(get: { vault.quietMinutes }, set: { vault.quietMinutes = min(max($0, 1), 1440) })
    }

    var reminderTime: Binding<Date> {
        Binding(get: {
            let (h, m) = parseTime(vault.reminderTime) ?? (10, 0)
            return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            vault.reminderTime = String(format: "%02d:%02d", c.hour ?? 10, c.minute ?? 0)
        })
    }

    var snoozeText: Binding<String> {
        Binding(get: { vault.snoozeHours.map(formatHours).joined(separator: ", ") },
                set: { vault.snoozeHours = parseHours($0) ?? vault.snoozeHours })
    }

    func remoteProblem(_ s: String) -> String? {
        if let e = refNameProblem(s) { return e }
        guard !s.isEmpty, let remotes, !remotes.contains(s) else { return nil }
        return "This repository has no remote named “\(s)”" + (remotes.isEmpty ? "" : " (it has \(remotes.joined(separator: ", ")))")
    }
}

/// Seven day buttons in the user's week order; filled = reminders on that day.
struct DayPicker: View {
    @Binding var days: [Int]

    var body: some View {
        let cal = Calendar.current
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { k in
                let day = (cal.firstWeekday - 1 + k) % 7 + 1
                let on = days.contains(day)
                let button = Button(cal.shortStandaloneWeekdaySymbols[day - 1]) {
                    let new = on ? days.filter { $0 != day } : (days + [day]).sorted()
                    if !new.isEmpty { days = new } // at least one day stays on
                }
                .help(cal.standaloneWeekdaySymbols[day - 1])
                .accessibilityLabel(cal.standaloneWeekdaySymbols[day - 1])
                .accessibilityValue(on ? "on" : "off")
                .accessibilityAddTraits(on ? .isSelected : [])
                if on { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
            }
        }
    }
}

/// A text field whose value is only saved while `check` finds nothing wrong.
struct CheckedField: View {
    let title: String
    let prompt: String
    @Binding var value: String
    let check: (String) -> String?
    @SwiftUI.State private var draft: String?

    var body: some View {
        let text = draft ?? value
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
                TextField(title, text: Binding(get: { text }, set: { new in
                    draft = new
                    if check(new) == nil { value = new }
                }), prompt: Text(prompt))
                .labelsHidden()
                if let error = check(text) {
                    Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.trailing)
                }
            }
        }
    }
}

struct IgnoreEditor: View {
    @Binding var entries: [String]
    @SwiftUI.State private var drafts: [String]?

    var body: some View {
        let rows = drafts ?? entries
        LabeledContent("Ignored paths") {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(rows.indices, id: \.self) { i in
                    HStack {
                        TextField("Ignored path \(i + 1)", text: Binding(get: { (drafts ?? entries).indices.contains(i) ? (drafts ?? entries)[i] : "" },
                                                                        set: { update(i, $0) }),
                                  prompt: Text("folder or *.glob"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        Button { remove(i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove this path")
                            .accessibilityLabel("Remove ignored path \(rows[i])")
                    }
                    if let e = ignoreProblem(rows[i]) { Text(e).font(.caption).foregroundStyle(.red) }
                }
                Button { drafts = rows + [""] } label: { Label("Add Path", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
        }
        Caption("Relative to the vault folder; * and ** wildcards work. Changes under these paths never trigger a reminder and are never committed.")
    }

    func update(_ i: Int, _ s: String) {
        var d = drafts ?? entries
        guard d.indices.contains(i) else { return }
        d[i] = s
        commit(d)
    }

    func remove(_ i: Int) {
        var d = drafts ?? entries
        guard d.indices.contains(i) else { return }
        d.remove(at: i)
        commit(d)
    }

    func commit(_ d: [String]) {
        drafts = d
        if d.allSatisfy({ ignoreProblem($0) == nil }) { entries = d.filter { !$0.isEmpty } }
    }
}

// MARK: - small pieces

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct PathText: View {
    let path: String
    var body: some View {
        Text(abbreviate(expand(path)))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(expand(path))
    }
}

func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

/// Debug (--snapshots DIR): README/wiki images, light and dark, rendered in windows that
/// are never put on screen: both Settings panes, About, the reminder dialog (for the first
/// vault) and the menu bar icon states.
func snapshotSettings(to dir: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    if let icon = Bundle.main.image(forResource: "AppIcon") { app.applicationIconImage = icon } // not loaded without a Dock presence
    store.statuses = Dictionary(store.vaults.map { ($0.cfg.id, currentStatus($0)) }, uniquingKeysWith: { a, _ in a })
    store.selection = store.config.vaults.first?.id
    var shots: [(name: String, view: AnyView, size: CGSize?)] = [
        ("general", AnyView(GeneralPane()), generalSize), ("vaults", AnyView(VaultsPane()), vaultsSize),
        ("about", AnyView(AboutView()), nil), ("welcome", AnyView(WelcomeView(onOpenSettings: {}, onDone: {})), nil),
    ]
    var jobs: [(String, AnyView, CGSize?, NSAppearance.Name)] = []
    for shot in shots { jobs += [("\(shot.name)-light", shot.view, shot.size, .aqua), ("\(shot.name)-dark", shot.view, shot.size, .darkAqua)] }
    shots.removeAll()
    var windows: [NSWindow] = []

    func write(_ view: NSView, _ name: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let out = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // flatten onto the window background: a window's own background isn't part of its views
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        (view.window?.appearance ?? view.effectiveAppearance).performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: rep.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: rep.size))
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    func extras() {
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                if mode == "light", let v = store.active.first { // its vibrant background renders white off screen: light only
                    let lines = statusLines(v)
                    let (alert, _, _, _) = reminderAlert(v, lines.prefix(15).joined(separator: "\n"))
                    alert.window.appearance = NSAppearance(named: appearance)
                    alert.layout()
                    write(alert.window.contentView!, "dialog-\(mode)")
                }
                // menu bar states: template glyphs tinted like the menu bar draws them
                let states = ["clean", "pending", "error", "snoozed", "skipped"]
                let strip = NSImage(size: NSSize(width: 18 * states.count + 14 * (states.count + 1), height: 30), flipped: false) { rect in
                    (mode == "light" ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.17, alpha: 1)).setFill()
                    rect.fill()
                    for (k, st) in states.enumerated() {
                        let r = NSRect(x: 14 + k * 32, y: 6, width: 18, height: 18)
                        let tinted = NSImage(size: r.size, flipped: false) { b in
                            menuBarImage(for: st).draw(in: b)
                            (mode == "light" ? NSColor.black : NSColor.white).setFill()
                            b.fill(using: .sourceAtop)
                            return true
                        }
                        tinted.draw(in: r)
                    }
                    return true
                }
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(strip.size.width) * 4, pixelsHigh: Int(strip.size.height) * 4,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = strip.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                strip.draw(in: NSRect(origin: .zero, size: strip.size))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/menubar-\(mode).png"))
            }
        }
    }

    func next() {
        guard !jobs.isEmpty else {
            extras()
            print("wrote PNGs to \(dir)")
            exit(0)
        }
        let (name, view, size, appearance) = jobs.removeFirst()
        let host = NSHostingView(rootView: view.environmentObject(store))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size ?? host.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: appearance)
        w.contentView = host
        windows.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { // let SwiftUI lay out and run onAppear/task
            write(w.contentView!, name)
            next()
        }
    }
    DispatchQueue.main.async { next() }
    app.run()
}
