// config.json: the watched vaults with their settings, plus a few app-wide settings.
// Schema version 2. A version 1 file (no "version" key, vault entries with only
// path/state) still loads: every newer key is optional and defaults to the behaviour
// the app had before it had settings. The Settings window edits `store.config`; each
// change is saved to config.json and applied live (AppDelegate.applyConfig). A hand
// edit of config.json is picked up live too (ConfigStore.reloadFromDisk).
import Combine
import Foundation

let configVersion = 2
let store = ConfigStore() // the app's (and the CLI flags') config; read once, then kept live
let configPath = ProcessInfo.processInfo.environment["OBSIDIAN_VAULT_GIT_WATCHER_CONFIG"]
    .map { NSString(string: $0).expandingTildeInPath }
    ?? (NSHomeDirectory() + "/Library/Application Support/ObsidianVaultGitWatcher/config.json")

enum StageMode: String, Codable, CaseIterable { case all, tracked }
enum NotifyStyle: String, Codable, CaseIterable { case dialog, banner }
enum IconMode: String, Codable, CaseIterable { case always, whenNeeded }

struct VaultConfig: Codable, Identifiable {
    var id = UUID() // in memory only (Settings selection), never written
    var path: String
    var state = "" // state file, relative to config.json's folder unless absolute or ~
    var name = "" // display name; "" = folder name
    var enabled = true
    var quietMinutes = 60
    var reminderTime = "10:00"
    var reminderDays = [1, 2, 3, 4, 5, 6, 7] // Calendar weekdays, 1 = Sunday
    var snoozeHours: [Double] = [1, 3]
    var commitMessage = "Vault update {date}"
    var stage = StageMode.all
    var push = true
    var remote = "" // "" = the branch's upstream
    var branch = "" // "" = the branch's upstream
    var ignore = [".obsidian/workspace*.json", ".stversions", ".stfolder"]
    var notify = NotifyStyle.dialog
    var obsidianVault = "" // "" = open the folder with the Obsidian app

    enum CodingKeys: String, CodingKey {
        case path, state, name, enabled, quietMinutes, reminderTime, reminderDays, snoozeHours,
             commitMessage, stage, push, remote, branch, ignore, notify, obsidianVault
    }

    init(path: String) { self.path = path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func opt<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        path = try c.decode(String.self, forKey: .path)
        state = try opt(.state, state)
        name = try opt(.name, name)
        enabled = try opt(.enabled, enabled)
        quietMinutes = try opt(.quietMinutes, quietMinutes)
        reminderTime = try opt(.reminderTime, reminderTime)
        reminderDays = try opt(.reminderDays, reminderDays)
        snoozeHours = try opt(.snoozeHours, snoozeHours)
        commitMessage = try opt(.commitMessage, commitMessage)
        stage = try opt(.stage, stage)
        push = try opt(.push, push)
        remote = try opt(.remote, remote)
        branch = try opt(.branch, branch)
        ignore = try opt(.ignore, ignore)
        notify = try opt(.notify, notify)
        obsidianVault = try opt(.obsidianVault, obsidianVault)
    }

    var quietSeconds: TimeInterval { TimeInterval(quietMinutes * 60) }
    var displayName: String { name.isEmpty ? (expand(path) as NSString).lastPathComponent : name }

    /// Everything wrong with this entry, worded for an inline error or the log.
    func problems() -> [String] {
        var p: [String] = []
        if path.trimmingCharacters(in: .whitespaces).isEmpty { p.append("path is empty") }
        if !(1...1440).contains(quietMinutes) { p.append("quietMinutes must be 1 to 1440") }
        if parseTime(reminderTime) == nil { p.append("reminderTime must be HH:mm") }
        if reminderDays.isEmpty || !reminderDays.allSatisfy((1...7).contains) {
            p.append("reminderDays must list weekdays 1 (Sunday) to 7")
        }
        if !snoozeHours.allSatisfy({ $0 > 0 && $0 <= 336 }) { p.append("snoozeHours must be more than 0 and at most 336") }
        if commitMessage.trimmingCharacters(in: .whitespaces).isEmpty { p.append("commitMessage is empty") }
        if let e = refNameProblem(remote) { p.append("remote: \(e)") }
        if let e = refNameProblem(branch) { p.append("branch: \(e)") }
        p += ignore.compactMap { i in ignoreProblem(i).map { "ignore \"\(i)\": \($0)" } }
        return p
    }
}

struct AppConfig: Codable {
    var version = configVersion
    var menuBarIcon = IconMode.always
    var showFileCount = false
    var logFile = "~/Library/Logs/obsidian-vault-git-watcher.log"
    var vaults: [VaultConfig] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        menuBarIcon = try c.decodeIfPresent(IconMode.self, forKey: .menuBarIcon) ?? menuBarIcon
        showFileCount = try c.decodeIfPresent(Bool.self, forKey: .showFileCount) ?? showFileCount
        logFile = try c.decodeIfPresent(String.self, forKey: .logFile) ?? logFile
        vaults = try c.decode([VaultConfig].self, forKey: .vaults)
    }
}

struct ConfigError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - validation helpers (shared by config loading and the Settings fields)

func expand(_ path: String) -> String { NSString(string: path).expandingTildeInPath }
func abbreviate(_ path: String) -> String { NSString(string: path).abbreviatingWithTildeInPath }
/// Real path as FSEvents reports it (/private/var/..., not /var/...); unchanged if it doesn't exist.
func resolved(_ path: String) -> String {
    guard let p = realpath(path, nil) else { return path }
    defer { free(p) }
    return String(cString: p)
}

/// "HH:mm" -> (hour, minute)
func parseTime(_ s: String) -> (Int, Int)? {
    let parts = s.split(separator: ":")
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
    return (h, m)
}

/// Remote/branch names go to `git push` as arguments: keep them to plain ref names so
/// one can never be read as an option ("--upload-pack=...").
func refNameProblem(_ s: String) -> String? {
    if s.isEmpty { return nil }
    let ok = s.range(of: #"^[A-Za-z0-9_][A-Za-z0-9._/-]*$"#, options: .regularExpression) != nil
    return ok && !s.contains("..") && !s.hasSuffix("/") && !s.hasSuffix(".lock")
        ? nil : "use letters, digits and . _ / - only, without \"..\" or a leading - or ."
}

/// Ignore entries are git pathspecs relative to the vault folder (globs allowed).
func ignoreProblem(_ s: String) -> String? {
    if s.isEmpty { return nil }
    if s.hasPrefix("/") || s.hasPrefix("~") { return "use a path relative to the vault folder" }
    if s.split(separator: "/").contains("..") { return "\"..\" is not allowed" }
    return nil
}

/// Comma-separated snooze hours ("1, 3, 0.5"); nil if any entry isn't a valid number.
func parseHours(_ s: String) -> [Double]? {
    let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let hours = parts.compactMap(Double.init)
    return hours.count == parts.count && hours.allSatisfy({ $0 > 0 && $0 <= 336 }) ? hours : nil
}

func formatHours(_ h: Double) -> String { h == h.rounded() ? String(Int(h)) : String(h) }

/// state-<folder>.json, numbered when another vault already uses that name.
func defaultStateName(_ path: String, taken: [String]) -> String {
    let folder = (expand(path) as NSString).lastPathComponent
    let used = Set(taken.map { $0.lowercased() })
    var name = "state-\(folder).json"
    var n = 2
    while used.contains(name.lowercased()) { name = "state-\(folder)-\(n).json"; n += 1 }
    return name
}

/// Why `path` can't be watched (nil = fine): it must be the top folder of a git work
/// tree, with a remote when adding it (so there is somewhere to push).
func vaultFolderProblem(_ path: String, requireRemote: Bool) -> String? {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return "Folder not found" }
    let probe = Vault(path: path, statePath: "")
    guard let top = try? git(probe, ["rev-parse", "--show-toplevel"]) else {
        return "Not a git repository. Run `git init` in it and add a remote first."
    }
    guard resolved(top) == resolved(path) else { return "This folder is inside the git repository at \(abbreviate(top)). Choose that folder instead." }
    if requireRemote, ((try? git(probe, ["remote"])) ?? "").isEmpty {
        return "The repository has no remote to push to. Add one with `git remote add origin <url>`."
    }
    return nil
}

private func describe(_ error: Error) -> String {
    guard let d = error as? DecodingError else { return "\(error)" }
    func at(_ path: [CodingKey]) -> String {
        path.isEmpty ? "" : " (at " + path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".") + ")"
    }
    switch d {
    case .keyNotFound(let k, let c): return "missing \"\(k.stringValue)\"" + at(c.codingPath)
    case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
        return c.debugDescription.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + at(c.codingPath)
    @unknown default: return "\(d)"
    }
}

/// Decode and validate. Fills in the state file of entries that have none (the name the
/// version 1 app used), so a later save writes it out and the state stays put.
func parseConfig(_ data: Data) throws -> AppConfig {
    var c: AppConfig
    do { c = try JSONDecoder().decode(AppConfig.self, from: data) } catch { throw ConfigError(describe(error)) }
    guard c.version <= configVersion else {
        throw ConfigError("written by a newer version of the app (schema \(c.version), this one reads up to \(configVersion))")
    }
    for i in c.vaults.indices where c.vaults[i].state.isEmpty {
        c.vaults[i].state = defaultStateName(c.vaults[i].path, taken: c.vaults.map(\.state))
    }
    var problems = c.vaults.enumerated().flatMap { i, v in v.problems().map { "vault \(i + 1) (\(v.path)): \($0)" } }
    if c.logFile.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("logFile is empty") }
    let paths = c.vaults.map { expand($0.path) }
    if Set(paths).count != paths.count { problems.append("the same folder is listed twice") }
    let states = c.vaults.map { $0.state.lowercased() }
    if Set(states).count != states.count { problems.append("two vaults use the same state file") }
    guard problems.isEmpty else { throw ConfigError(problems.joined(separator: "; ")) }
    return c
}

// MARK: - the live config

final class ConfigStore: ObservableObject {
    let path: String
    var dir: String { (path as NSString).deletingLastPathComponent }

    @Published var config = AppConfig() { didSet { if !reloading { scheduleSave() } } }
    @Published var statuses: [UUID: Status] = [:] // filled by AppDelegate.refreshDisplay
    @Published var loadError: String?
    @Published var selection: UUID? // the vault shown in Settings
    @Published var generation = 0 // bumped when config.json is replaced from outside

    var onApply: (() -> Void)?
    private(set) var isFirstRun = false // no config.json yet
    private var lastDisk: Data?
    private var needsBackup = false // the file on disk is version 1 or unreadable
    private var reloading = false
    private var pendingSave: DispatchWorkItem?

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    init(path: String = configPath) {
        self.path = path
        guard let data = FileManager.default.contents(atPath: path) else {
            if FileManager.default.fileExists(atPath: path) { loadError = "config.json can't be read" } else { isFirstRun = true }
            return // first run: no vaults until one is added in Settings; nothing is written yet
        }
        do {
            let c = try parseConfig(data)
            reloading = true; config = c; reloading = false
            lastDisk = data
            needsBackup = c.version < configVersion
        } catch {
            loadError = "config.json can't be used: \(error). No vaults are watched until it's fixed."
            needsBackup = true
            logLine(loadError!)
        }
    }

    /// Every configured vault, enabled or not.
    var vaults: [Vault] { config.vaults.map { Vault($0, dir: dir) } }
    var active: [Vault] { vaults.filter(\.cfg.enabled) }

    func vaultConfig(_ id: UUID) -> VaultConfig? { config.vaults.first { $0.id == id } }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Writes config.json (if it changed) and applies it. The first save over a version 1
    /// or unreadable file keeps the old file as config.json.bak.
    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        var c = config
        c.version = configVersion
        guard let data = try? Self.encoder.encode(c), data != lastDisk else { return }
        let fm = FileManager.default
        if needsBackup, fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path + ".bak")
            try? fm.copyItem(atPath: path, toPath: path + ".bak")
        }
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            lastDisk = data
            needsBackup = false
            loadError = nil
        } catch {
            loadError = "Couldn't save config.json: \(error.localizedDescription)"
            logLine(loadError!)
        }
        onApply?()
    }

    /// config.json changed on disk (hand edit): use it if it's valid, otherwise keep the
    /// current settings and say why.
    func reloadFromDisk() {
        guard let data = FileManager.default.contents(atPath: path), data != lastDisk else { return }
        do {
            var c = try parseConfig(data)
            for i in c.vaults.indices { // keep ids so the Settings selection survives
                if let old = config.vaults.first(where: { $0.state == c.vaults[i].state }) { c.vaults[i].id = old.id }
            }
            replace(with: c, from: data)
            logLine("Reloaded \(path)")
        } catch {
            loadError = "config.json changed but can't be used: \(error). Still using the previous settings."
            needsBackup = true // a save from Settings would replace it: keep the hand edit as .bak
            logLine(loadError!)
        }
    }

    /// Import, or a reload: swap the whole config. `from` = the bytes already on disk.
    func replace(with c: AppConfig, from data: Data? = nil) {
        pendingSave?.cancel()
        reloading = true; config = c; reloading = false
        generation += 1
        if selection.flatMap(vaultConfig) == nil { selection = c.vaults.first?.id }
        if let data {
            lastDisk = data
            needsBackup = c.version < configVersion
            loadError = nil
            onApply?()
        } else {
            save()
        }
    }

    /// Settings "Import…": like a reload, but the file being replaced is kept as config.json.bak.
    func importConfig(_ c: AppConfig) {
        needsBackup = true
        replace(with: c)
    }

    private func folderProblem(_ p: String, except id: UUID?) -> String? {
        if let problem = vaultFolderProblem(p, requireRemote: true) { return problem }
        let others = vaults.filter { $0.cfg.id != id }
        return others.contains { resolved($0.path) == resolved(p) } ? "This folder is already in the list." : nil
    }

    /// Adds the folder at `rawPath` (validated) and returns its id.
    func addVault(_ rawPath: String) -> Result<UUID, ConfigError> {
        let p = expand(rawPath)
        if let problem = folderProblem(p, except: nil) { return .failure(ConfigError(problem)) }
        var v = VaultConfig(path: abbreviate(p))
        v.state = defaultStateName(p, taken: config.vaults.map(\.state))
        config.vaults.append(v)
        return .success(v.id)
    }

    /// Points a vault at another folder (validated); its state file stays.
    func changeFolder(_ id: UUID, to rawPath: String) -> ConfigError? {
        let p = expand(rawPath)
        if let problem = folderProblem(p, except: id) { return ConfigError(problem) }
        if let i = config.vaults.firstIndex(where: { $0.id == id }) { config.vaults[i].path = abbreviate(p) }
        return nil
    }

    /// Stops watching the vault and deletes its state file; the folder itself is untouched.
    func remove(_ id: UUID) {
        guard let i = config.vaults.firstIndex(where: { $0.id == id }) else { return }
        let statePath = Vault(config.vaults[i], dir: dir).statePath
        config.vaults.remove(at: i)
        try? FileManager.default.removeItem(atPath: statePath)
        if selection == id { selection = config.vaults.indices.contains(i) ? config.vaults[i].id : config.vaults.last?.id }
    }

    func exportData() -> Data? {
        var c = config
        c.version = configVersion
        return try? Self.encoder.encode(c)
    }
}
