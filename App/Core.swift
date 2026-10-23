// Core scheduling/git logic, originally ported 1:1 from an earlier Python prototype.
// Rules (defaults; each vault can change them in Settings): remind only after the vault
// has been quiet (unchanged) for 1 hour; after a reminder, remind again at the next
// 10:00 (missed while asleep -> on wake); Snooze: 1 hour / custom hours / until the
// next 10:00; Skip: ignore exactly this set of changes until something changes again.
import Foundation

// MARK: - watched vaults (config entries resolved to absolute paths, see Config.swift)

struct Vault {
    let path: String // absolute
    let statePath: String // absolute
    var cfg: VaultConfig
    var name: String { cfg.displayName }
    var title: String { "Obsidian Vault Git Watcher - \(name)" }

    init(_ cfg: VaultConfig, dir: String) {
        self.cfg = cfg
        path = expand(cfg.path)
        let state = expand(cfg.state.isEmpty ? defaultStateName(cfg.path, taken: []) : cfg.state)
        statePath = state.hasPrefix("/") ? state : dir + "/" + state
    }

    init(path: String, statePath: String, cfg: VaultConfig? = nil) {
        self.path = path
        self.statePath = statePath
        self.cfg = cfg ?? VaultConfig(path: path)
    }

    /// An FSEvents path inside this vault and not under one of its ignored paths.
    func isRelevant(_ eventPath: String, realPath: String) -> Bool {
        guard eventPath.hasPrefix(realPath + "/") else { return false }
        var prefix = ""
        for part in eventPath.dropFirst(realPath.count + 1).split(separator: "/") {
            prefix += (prefix.isEmpty ? "" : "/") + part
            if cfg.ignore.contains(where: { fnmatch($0, prefix, FNM_PATHNAME) == 0 }) { return false }
        }
        return true
    }
}

/// Timestamped line to stderr, which the menu bar app points at its log file.
func logLine(_ msg: String) {
    FileHandle.standardError.write(Data("\(isoString(Date())) \(msg)\n".utf8))
}

private var currentLogPath = ""

/// Send stderr (logLine, git errors) to `file`; called on launch and when the setting changes.
func redirectLog(_ file: String) {
    let p = expand(file)
    guard p != currentLogPath else { return }
    try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let fd = open(p, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { logLine("Can't open log file \(p)"); return }
    dup2(fd, STDERR_FILENO)
    close(fd)
    currentLogPath = p
}

enum GitError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let m): return m } }
}

private var foundGit: String?

/// Real git: Homebrew (Apple Silicon, then Intel) before /usr/bin/git. That one is only a shim
/// until the Xcode command line tools exist (running it would pop the install prompt), so it
/// counts only if `xcode-select -p` succeeds. Not found: a clear error, never the prompt.
func gitExecutable() throws -> String {
    if let foundGit { return foundGit }
    let fm = FileManager.default
    var found = ["/opt/homebrew/bin/git", "/usr/local/bin/git"].first { fm.isExecutableFile(atPath: $0) }
    if found == nil, fm.isExecutableFile(atPath: "/usr/bin/git") {
        let x = Process()
        x.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        x.arguments = ["-p"]
        x.standardOutput = FileHandle.nullDevice; x.standardError = FileHandle.nullDevice
        if (try? x.run()) != nil { x.waitUntilExit(); if x.terminationStatus == 0 { found = "/usr/bin/git" } }
    }
    guard let found else {
        throw GitError.failed("git not found. Install it with Homebrew (brew install git) or the Xcode command line tools (xcode-select --install).")
    }
    foundGit = found
    return found
}

@discardableResult
func git(_ v: Vault, _ args: [String], extraEnv: [String: String]? = nil) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: try gitExecutable())
    p.arguments = ["-C", v.path] + args
    if let extraEnv {
        var e = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { e[k] = v }
        p.environment = e
    }
    let outPipe = Pipe(); let errPipe = Pipe()
    p.standardOutput = outPipe; p.standardError = errPipe
    try p.run()
    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" // before wait: a full pipe would block git
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw GitError.failed("git \(args.joined(separator: " ")): \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// `-- . :(exclude)...`: the whole vault minus its ignored paths.
func pathspec(_ v: Vault) -> [String] {
    ["--", "."] + v.cfg.ignore.map { ":(exclude,glob)\($0)" }
}

/// How the vault's changes are staged: everything (`git add -A`) or tracked files only.
func addArgs(_ v: Vault) -> [String] {
    ["add", v.cfg.stage == .tracked ? "-u" : "-A"] + pathspec(v)
}

/// Tree hash the commit action would commit right now; nil if nothing to commit (or on
/// any git error — this is a long-running daemon now, a transient git hiccup should
/// skip a cycle, not take the whole app down).
func fingerprint(_ v: Vault) -> String? {
    let tmpDir = NSTemporaryDirectory() + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }
    let extraEnv = ["GIT_INDEX_FILE": tmpDir + "/index"]
    do {
        try git(v, ["read-tree", "HEAD"], extraEnv: extraEnv)
        try git(v, addArgs(v), extraEnv: extraEnv)
        let tree = try git(v, ["write-tree"], extraEnv: extraEnv)
        let head = try git(v, ["rev-parse", "HEAD^{tree}"])
        return tree == head ? nil : tree
    } catch {
        return nil
    }
}

func statusLines(_ v: Vault) -> [String] {
    // --no-optional-locks: never hold index.lock against a commit running on another queue
    let args = ["--no-optional-locks", "status", "--short"] + (v.cfg.stage == .tracked ? ["-uno"] : []) + pathspec(v)
    return (try? git(v, args))?.split(separator: "\n").map(String.init) ?? []
}

/// The next reminder time (default 10:00) after `now`, on one of the vault's reminder days.
func nextDaily(_ now: Date, _ cfg: VaultConfig = VaultConfig(path: "")) -> Date {
    let cal = Calendar.current
    let (h, m) = parseTime(cfg.reminderTime) ?? (10, 0)
    let today = cal.startOfDay(for: now)
    for offset in 0...7 {
        guard let day = cal.date(byAdding: .day, value: offset, to: today),
              let t = cal.date(bySettingHour: h, minute: m, second: 0, of: day) else { continue }
        if t > now && cfg.reminderDays.contains(cal.component(.weekday, from: t)) { return t }
    }
    return now.addingTimeInterval(86400) // unreachable: config validation requires a reminder day
}

// MARK: - state.json (plain string dict, same shape the original Python prototype wrote:
// fp/since/due/skipped). Dates are naive local "yyyy-MM-ddTHH:mm:ss", matching
// Python's datetime.isoformat() closely enough that the existing state.json (with or
// without a fractional-seconds suffix, which we don't need at this granularity) still
// parses on the very first run of the merged app.
typealias State = [String: String]

private let isoFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return f
}()

func isoString(_ d: Date) -> String { isoFormatter.string(from: d) }

func isoDate(_ s: String) -> Date? {
    isoFormatter.date(from: String(s.split(separator: ".", maxSplits: 1)[0]))
}

func loadState(_ v: Vault) -> State {
    guard let data = FileManager.default.contents(atPath: v.statePath),
          let obj = try? JSONSerialization.jsonObject(with: data) as? State else { return [:] }
    return obj
}

func saveState(_ v: Vault, _ s: State) {
    let dir = (v.statePath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: s) {
        try? data.write(to: URL(fileURLWithPath: v.statePath))
    }
}

/// Update state `s` for the current fingerprint; return true if a reminder is due.
@discardableResult
func step(_ s: inout State, _ fp: String?, _ now: Date, _ cfg: VaultConfig = VaultConfig(path: "")) -> Bool {
    guard let fp else { s.removeAll(); return false }
    if fp != s["fp"] {
        if s["fp"] == nil || s["fp"] == s["skipped"] {
            s.removeValue(forKey: "due") // fresh set of changes: first reminder after the quiet hour
        }
        s["fp"] = fp
        s["since"] = isoString(now)
    }
    if fp == s["skipped"] { return false }
    guard let since = s["since"].flatMap(isoDate) else { return false }
    if now.timeIntervalSince(since) < cfg.quietSeconds { return false }
    if let due = s["due"].flatMap(isoDate), now < due { return false }
    // not one of the vault's reminder days: wait for the next reminder time instead
    guard cfg.reminderDays.contains(Calendar.current.component(.weekday, from: now)) else {
        s["due"] = isoString(nextDaily(now, cfg))
        return false
    }
    return true
}

/// Make sure `s` has fp/since for the current fingerprint (menu actions can fire
/// before the timer's next step() tick has ever recorded one).
func ensureTracking(_ s: inout State, _ fp: String?, _ now: Date) {
    guard let fp else { return }
    if fp != s["fp"] {
        s["fp"] = fp
        s["since"] = isoString(now)
    }
}

/// When step() will next fire for the current fingerprint: the quiet hour has elapsed
/// AND (if set) "due" has passed -- the LATER of the two. step() stays the single source
/// of truth; the timer only re-runs it. (The earlier of the two was already in the past
/// once a reminder had been dismissed or snoozed, so the timer re-armed in the past and
/// re-checked in a tight loop until "due".)
func nextDeadline(_ s: State, _ now: Date, _ cfg: VaultConfig = VaultConfig(path: "")) -> Date? {
    guard let fp = s["fp"], fp != s["skipped"] else { return nil }
    guard let since = s["since"].flatMap(isoDate) else { return nil }
    let quietEnds = since.addingTimeInterval(cfg.quietSeconds)
    guard let due = s["due"].flatMap(isoDate) else { return quietEnds }
    return max(quietEnds, due)
}

// MARK: - live status classification (menu bar + Settings)

struct Status {
    var state = "clean" // clean | pending | snoozed | skipped | disabled | error
    var files = 0
    var due: String?
    var unpushed = 0
    var error: String?
}

/// Commits on HEAD that the push target doesn't have yet (0 if unknown).
func unpushedCount(_ v: Vault) -> Int {
    var target = "@{u}"
    if !v.cfg.remote.isEmpty || !v.cfg.branch.isEmpty {
        let branch = v.cfg.branch.isEmpty ? ((try? git(v, ["branch", "--show-current"])) ?? "") : v.cfg.branch
        target = "\(v.cfg.remote.isEmpty ? upstreamRemote(v) : v.cfg.remote)/\(branch)"
    }
    return Int((try? git(v, ["rev-list", "--count", "\(target)..HEAD"])) ?? "") ?? 0
}

/// The remote of the current branch's upstream; "origin" if there is none.
func upstreamRemote(_ v: Vault) -> String {
    (try? git(v, ["rev-parse", "--abbrev-ref", "@{u}"]))?.split(separator: "/").first.map(String.init) ?? "origin"
}

func currentStatus(_ v: Vault) -> Status {
    guard v.cfg.enabled else { return Status(state: "disabled") }
    if let problem = vaultFolderProblem(v.path, requireRemote: false) {
        return Status(state: "error", error: problem.components(separatedBy: ". ")[0])
    }
    guard (try? git(v, ["rev-parse", "-q", "--verify", "HEAD"])) != nil else { return Status(state: "error", error: "No commits yet") }
    let s = loadState(v)
    let fp = fingerprint(v)
    let now = Date()
    let unpushed = v.cfg.push ? unpushedCount(v) : 0
    guard let fp else {
        guard unpushed > 0 else { return Status(state: "clean") }
        return Status(state: "error", unpushed: unpushed, error: "\(unpushed) commit\(unpushed == 1 ? "" : "s") not pushed")
    }
    let files = statusLines(v).count
    if fp == s["skipped"] { return Status(state: "skipped", files: files, unpushed: unpushed) }
    if let dueStr = s["due"], fp == s["fp"], let due = isoDate(dueStr), now < due {
        return Status(state: "snoozed", files: files, due: dueStr, unpushed: unpushed)
    }
    return Status(state: "pending", files: files, unpushed: unpushed)
}

func symbolName(for state: String) -> String {
    switch state {
    case "clean": return "checkmark.circle"
    case "skipped": return "eye.slash.circle"
    case "snoozed": return "clock.badge.exclamationmark"
    case "disabled": return "pause.circle"
    case "error": return "exclamationmark.triangle"
    default: return "exclamationmark.circle" // "pending"
    }
}

func dueLabel(_ iso: String) -> String {
    guard let d = isoDate(iso) else { return iso }
    let out = DateFormatter()
    out.dateFormat = "MMM d, HH:mm"
    return out.string(from: d)
}

/// One line per vault, used by the menu and the Settings list.
func statusText(_ s: Status) -> String {
    let files = "\(s.files) file\(s.files == 1 ? "" : "s")"
    switch s.state {
    case "clean": return "Clean"
    case "skipped": return "Skipped changes (\(files))"
    case "snoozed": return "\(files) uncommitted, snoozed until \(dueLabel(s.due ?? ""))"
    case "disabled": return "Not watched"
    case "error": return s.error ?? "Error"
    default: return "\(files) uncommitted"
    }
}
