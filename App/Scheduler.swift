// The scheduled check: mirrors the original Python prototype's main(). Runs on a background
// queue (see AppDelegate.scheduleCheck) since askMain() can block for up to an hour.
import Foundation

func runScheduledCheck(_ v: Vault) {
    var s = loadState(v)
    let fp = fingerprint(v)
    guard step(&s, fp, Date(), v.cfg) else { saveState(v, s); return }

    let lines = statusLines(v)
    if v.cfg.notify == .banner { // a banner can't take an answer: treat it like a dismissed dialog
        notify("\(lines.count) file\(lines.count == 1 ? "" : "s") uncommitted. Commit from the menu bar.", title: v.title)
        logLine("\(v.name): reminder banner, \(lines.count) files")
        s["due"] = isoString(nextDaily(Date(), v.cfg))
        saveState(v, s)
        return
    }
    logLine("\(v.name): reminder dialog, \(lines.count) files")
    let shown = lines.prefix(15).joined(separator: "\n")
    let changes = shown + (lines.count > 15 ? "\n… and \(lines.count - 15) more" : "")
    let (button, msg, snoozeUntil) = askMain(v, changes)
    let now = Date()
    switch button {
    case "Commit" where commitAndPush(v, msg):
        s.removeAll()
    case "Skip these changes":
        s["skipped"] = fp
    case "Snooze":
        s["due"] = isoString(snoozeUntil)
    default: // dismissed / timed out / commit failed -> next daily reminder
        s["due"] = isoString(nextDaily(now, v.cfg))
    }
    saveState(v, s)
}

func selftest() {
    func d(_ y: Int, _ mo: Int, _ da: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = da; c.hour = h; c.minute = mi; c.second = 0
        return Calendar.current.date(from: c)!
    }
    let t0 = d(2026, 9, 26, 12, 0)
    let hour: TimeInterval = 3600
    var s: State = [:]

    precondition(!step(&s, nil, t0) && s.isEmpty)
    precondition(!step(&s, "A", t0), "no reminder right away")
    precondition(!step(&s, "A", t0.addingTimeInterval(0.9 * hour)))
    precondition(step(&s, "A", t0.addingTimeInterval(1.1 * hour)), "reminder after a quiet hour")
    s["due"] = isoString(nextDaily(t0.addingTimeInterval(1.1 * hour))) // dismissed -> tomorrow 10:00
    precondition(s["due"] == "2026-09-27T10:00:00")
    precondition(!step(&s, "B", t0.addingTimeInterval(3 * hour)), "new edits keep tomorrow's schedule")
    precondition(!step(&s, "B", t0.addingTimeInterval(5 * hour)))
    precondition(step(&s, "B", d(2026, 9, 27, 14, 30)), "missed 10:00 fires on wake")
    s["skipped"] = "B"
    precondition(!step(&s, "B", d(2026, 9, 29, 11, 0)), "skipped changes stay silent")
    let t1 = d(2026, 9, 29, 12, 0)
    precondition(!step(&s, "C", t1) && s["due"] == nil, "new changes after skip start fresh")
    precondition(step(&s, "C", t1.addingTimeInterval(1.1 * hour)))
    s["due"] = isoString(t1.addingTimeInterval(2.1 * hour)) // snoozed 1 hour
    precondition(!step(&s, "C", t1.addingTimeInterval(1.5 * hour)) && step(&s, "C", t1.addingTimeInterval(2.2 * hour)))
    precondition(!step(&s, nil, t1.addingTimeInterval(3 * hour)) && s.isEmpty, "clean vault resets everything")
    precondition(nextDaily(d(2026, 9, 26, 8, 0)) == d(2026, 9, 26, 10, 0))

    // nextDeadline(): exactly when step() would fire, never a past time while waiting on "due".
    var ns: State = [:]
    precondition(nextDeadline(ns, t0) == nil, "no fp -> no timer needed")
    ns["fp"] = "X"; ns["since"] = isoString(t0)
    precondition(nextDeadline(ns, t0) == t0.addingTimeInterval(hour), "no due -> since+quiet")
    ns["due"] = isoString(t0.addingTimeInterval(2 * hour))
    precondition(nextDeadline(ns, t0) == t0.addingTimeInterval(2 * hour), "due later than since+quiet -> due wins")
    ns["due"] = isoString(t0.addingTimeInterval(0.5 * hour))
    precondition(nextDeadline(ns, t0) == t0.addingTimeInterval(hour), "due earlier than since+quiet -> since+quiet wins")
    ns["due"] = isoString(d(2026, 9, 27, 10, 0)) // reminder dismissed at 14:00 -> tomorrow 10:00
    precondition(nextDeadline(ns, t0.addingTimeInterval(2 * hour)) == d(2026, 9, 27, 10, 0), "after a dismiss: wait for due, not the long-past quiet hour")
    ns["skipped"] = "X"
    precondition(nextDeadline(ns, t0) == nil, "skipped -> no timer needed")

    // Per-vault settings: quiet period, reminder time and days.
    var cfg = VaultConfig(path: "/x")
    cfg.quietMinutes = 15
    cfg.reminderTime = "07:30"
    cfg.reminderDays = [2, 3, 4, 5, 6] // Monday to Friday
    let fri = d(2026, 10, 16, 15, 0)
    precondition(Calendar.current.component(.weekday, from: fri) == 6)
    precondition(nextDaily(fri, cfg) == d(2026, 10, 19, 7, 30), "weekdays only: Friday afternoon -> Monday 07:30")
    precondition(nextDaily(d(2026, 10, 19, 6, 0), cfg) == d(2026, 10, 19, 7, 30))
    var ws: State = [:]
    precondition(!step(&ws, "W", fri, cfg) && step(&ws, "W", fri.addingTimeInterval(16 * 60), cfg), "custom quiet period")
    let sat = d(2026, 10, 17, 12, 0)
    var ss: State = [:]
    precondition(!step(&ss, "S", sat, cfg) && !step(&ss, "S", sat.addingTimeInterval(hour), cfg), "no reminder on a day off")
    precondition(ss["due"] == "2026-10-19T07:30:00" && nextDeadline(ss, sat.addingTimeInterval(hour), cfg) == d(2026, 10, 19, 7, 30), "...it waits for the next reminder day")
    precondition(step(&ss, "S", d(2026, 10, 19, 7, 31), cfg))

    // Config: version 1 files keep loading with their state files; bad values are refused.
    let home = NSHomeDirectory()
    let v1 = try! parseConfig(Data(#"{"vaults":[{"path":"~/Obsidian/Notes","state":"state.json"},{"path":"/x/Work"},{"path":"/y/Work"},{"path":"/z/W","state":"~/w.json"}]}"#.utf8))
    precondition(v1.version == 1 && v1.vaults.map(\.state) == ["state.json", "state-Work.json", "state-Work-2.json", "~/w.json"])
    precondition(v1.vaults.map { Vault($0, dir: "/cfg").statePath } == ["/cfg/state.json", "/cfg/state-Work.json", "/cfg/state-Work-2.json", home + "/w.json"])
    precondition(Vault(v1.vaults[0], dir: "/cfg").path == home + "/Obsidian/Notes" && v1.vaults[0].displayName == "Notes")
    let old = v1.vaults[0]
    precondition(old.enabled && old.quietMinutes == 60 && old.reminderTime == "10:00" && old.reminderDays.count == 7 && old.snoozeHours == [1, 3]
        && old.commitMessage == "Vault update {date}" && old.stage == .all && old.push && old.remote.isEmpty && old.branch.isEmpty
        && old.notify == .dialog && old.ignore == [".obsidian/workspace*.json", ".stversions", ".stfolder"], "version 1 entries keep the old behaviour")
    for bad in [#"{"vaults":[{"state":"x.json"}]}"#, #"{"vaults":[{"path":"/a","quietMinutes":0}]}"#, #"{"vaults":[{"path":"/a","reminderTime":"25:00"}]}"#,
                #"{"vaults":[{"path":"/a","reminderDays":[]}]}"#, #"{"vaults":[{"path":"/a","remote":"--upload-pack=x"}]}"#,
                #"{"vaults":[{"path":"/a","branch":"a..b"}]}"#, #"{"vaults":[{"path":"/a","ignore":["../x"]}]}"#, #"{"vaults":[{"path":"/a","notify":"popup"}]}"#,
                #"{"vaults":[{"path":"/a","snoozeHours":[0]}]}"#, #"{"vaults":[{"path":"/a"},{"path":"/a"}]}"#, #"{"version":3,"vaults":[]}"#, "not json"] {
        precondition((try? parseConfig(Data(bad.utf8))) == nil, "refused: \(bad)")
    }
    precondition(parseHours("1, 3,0.5") == [1, 3, 0.5] && parseHours("1, x") == nil && parseHours("") == [])
    let ig = Vault(path: "/r", statePath: "")
    precondition(!ig.isRelevant("/r/.obsidian/workspace.json", realPath: "/r") && !ig.isRelevant("/r/.stversions/a/b.md", realPath: "/r")
        && ig.isRelevant("/r/note.md", realPath: "/r") && ig.isRelevant("/r/.git/index", realPath: "/r") && !ig.isRelevant("/rx/note.md", realPath: "/r"),
        "ignored paths don't wake the watcher")

    // Throwaway repos (with bare remotes) for everything that runs git.
    let tmp = NSTemporaryDirectory() + "ovgw-selftest-" + UUID().uuidString
    let fm = FileManager.default
    defer { try? fm.removeItem(atPath: tmp) }
    func sh(_ dir: String, _ args: [String]) { try! git(Vault(path: dir, statePath: ""), args) }
    func write(_ path: String, _ text: String) {
        try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! text.write(toFile: path, atomically: true, encoding: .utf8)
    }
    func repo(_ name: String, remote: Bool = true) -> String {
        let p = tmp + "/" + name
        write(p + "/note.md", "x")
        try! fm.createDirectory(atPath: tmp + "/hooks", withIntermediateDirectories: true)
        sh(p, ["init", "-q", "-b", "main"])
        for (k, v) in ["user.name": "t", "user.email": "t@t", "commit.gpgsign": "false", "core.hooksPath": tmp + "/hooks"] { sh(p, ["config", k, v]) }
        sh(p, ["add", "-A"])
        sh(p, ["commit", "-q", "-m", "init"])
        if remote {
            sh(tmp, ["init", "-q", "--bare", "\(name).git"])
            sh(p, ["remote", "add", "origin", "\(tmp)/\(name).git"])
            sh(p, ["push", "-q", "-u", "origin", "main"])
        }
        return p
    }

    // ConfigStore: first run, add (validated), save, reload, remove.
    let cfgPath = tmp + "/cfg/config.json"
    let s1 = ConfigStore(path: cfgPath)
    precondition(s1.config.vaults.isEmpty && s1.loadError == nil && !fm.fileExists(atPath: cfgPath), "first run: no vaults, nothing written")
    try! fm.createDirectory(atPath: tmp + "/plain", withIntermediateDirectories: true)
    func addFails(_ p: String, _ text: String) -> Bool {
        if case .failure(let e) = s1.addVault(p) { return e.description.contains(text) }
        return false
    }
    precondition(addFails(tmp + "/plain", "Not a git repository") && addFails(repo("NoRemote", remote: false), "no remote")
        && addFails(tmp + "/missing", "not found"), "the + button only takes git repos with a remote")
    let pa = repo("A"), pb = repo("B")
    guard case .success(let idA) = s1.addVault(pa), case .success(let idB) = s1.addVault(pb) else { preconditionFailure("add A and B") }
    precondition(addFails(pa, "already"), "no duplicates")
    s1.config.vaults[0].name = "Alpha"
    s1.save()
    let onDisk = try! JSONSerialization.jsonObject(with: fm.contents(atPath: cfgPath)!) as! [String: Any]
    precondition(onDisk["version"] as? Int == 2, "schema version written")
    let s2 = ConfigStore(path: cfgPath)
    precondition(s2.config.vaults.map(\.state) == ["state-A.json", "state-B.json"] && s2.config.vaults.map(\.name) == ["Alpha", ""], "saved and read back")

    // Settings take effect: stage mode, ignore list, message template, push target.
    func vault(_ id: UUID) -> Vault { s1.vaults.first { $0.cfg.id == id }! }
    precondition(currentStatus(vault(idA)).state == "clean")
    write(pa + "/note.md", "y")
    write(pa + "/new.md", "new")
    write(pa + "/.obsidian/workspace.json", "{}")
    s1.config.vaults[0].stage = .tracked
    s1.config.vaults[0].commitMessage = "{vault}: {files} file(s) on {date}"
    precondition(statusLines(vault(idA)).count == 1, "tracked only: new and ignored files don't count")
    let msgA = try! commitVault(vault(idA), "", now: t0)
    precondition(msgA == "Alpha: 1 file(s) on 2026-09-26", "template tokens: \(msgA)")
    precondition((try! git(vault(idA), ["rev-parse", "HEAD"])) == (try! git(Vault(path: tmp + "/A.git", statePath: ""), ["rev-parse", "main"])), "committed and pushed")
    precondition(currentStatus(vault(idA)).state == "clean", "tracked only: an untracked file is not a reminder")
    s1.config.vaults[0].stage = .all
    let st = currentStatus(vault(idA))
    precondition(st.state == "pending" && st.files == 1 && statusLines(vault(idA)) == ["?? new.md"], "all changes: the new file counts, the ignored one never does")
    s1.config.vaults[0].push = false
    _ = try! commitVault(vault(idA), "by hand")
    precondition((try! git(vault(idA), ["show", "--name-only", "--format=%s", "HEAD"])).split(separator: "\n") == ["by hand", "new.md"], "ignored file not committed")
    precondition(unpushedCount(vault(idA)) == 1 && currentStatus(vault(idA)).state == "clean", "push off: unpushed commits are expected")
    s1.config.vaults[0].push = true
    precondition(currentStatus(vault(idA)).state == "error" && currentStatus(vault(idA)).unpushed == 1, "push on: unpushed commits show as an error")
    s1.config.vaults[0].remote = "origin"
    s1.config.vaults[0].branch = "other"
    precondition(pushArgs(vault(idA)) == ["push", "-q", "origin", "HEAD:refs/heads/other"])
    try! git(vault(idA), pushArgs(vault(idA)))
    precondition(unpushedCount(vault(idA)) == 0, "pushed to the configured remote/branch")
    s1.config.vaults[0].remote = "nope"
    write(pa + "/note.md", "z")
    do { _ = try commitVault(vault(idA), "x"); preconditionFailure("push to a missing remote must fail") } catch CommitError.push {} catch { preconditionFailure("\(error)") }
    precondition(currentStatus(vault(idA)).state == "clean", "...but the commit landed")
    precondition(currentStatus(Vault(path: tmp + "/missing", statePath: "")).error == "Folder not found"
        && currentStatus(Vault(path: tmp + "/plain", statePath: "")).error == "Not a git repository", "error states")
    var off = vault(idA)
    off.cfg.enabled = false
    precondition(currentStatus(off).state == "disabled")

    // Per-vault state: snooze and skip stay with their own vault and state file.
    let a = Vault(path: repo("C"), statePath: tmp + "/state-C.json")
    let b = Vault(path: repo("D"), statePath: tmp + "/state-D.json")
    for v in [a, b] {
        write(v.path + "/note.md", "y")
        precondition(currentStatus(v).state == "pending")
    }
    cliSnoozeHours(a, "1")
    precondition(currentStatus(a).state == "snoozed" && currentStatus(b).state == "pending", "snooze is per vault")
    cliSkip(b)
    precondition(currentStatus(a).state == "snoozed" && currentStatus(b).state == "skipped", "skip is per vault")
    precondition(loadState(a)["skipped"] == nil && loadState(b)["due"] == nil, "separate state files")

    // A hand edit of config.json applies; a broken one is refused and changes nothing.
    var edited = s1.config
    edited.vaults[0].quietMinutes = 5
    try! ConfigStore.encoder.encode(edited).write(to: URL(fileURLWithPath: cfgPath))
    s1.reloadFromDisk()
    precondition(s1.config.vaults[0].quietMinutes == 5 && s1.config.vaults[0].id == idA && s1.loadError == nil, "hand edit picked up, ids kept")
    write(cfgPath, "{oops")
    s1.reloadFromDisk()
    precondition(s1.config.vaults.count == 2 && s1.loadError != nil, "broken edit refused")
    s1.config.vaults[0].quietMinutes = 6
    s1.save()
    precondition(s1.loadError == nil && (try? parseConfig(fm.contents(atPath: cfgPath)!)) != nil
        && fm.contents(atPath: cfgPath + ".bak") == Data("{oops".utf8), "the next change saves over it, the broken file kept as .bak")

    // Remove: the vault and its state file go, the folder stays.
    cliSkip(vault(idB))
    let stateB = vault(idB).statePath
    precondition(fm.fileExists(atPath: stateB))
    s1.remove(idB)
    s1.save()
    precondition(!fm.fileExists(atPath: stateB) && fm.fileExists(atPath: pb) && ConfigStore(path: cfgPath).config.vaults.count == 1, "removed")

    // Upgrading a version 1 file keeps it as config.json.bak; so does an import.
    let v1Path = tmp + "/v1/config.json"
    let v1Text = #"{"vaults":[{"path":"\#(pa)","state":"state.json"}]}"#
    write(v1Path, v1Text)
    let s3 = ConfigStore(path: v1Path)
    precondition(s3.config.vaults[0].state == "state.json" && fm.contents(atPath: v1Path) == Data(v1Text.utf8), "loading never rewrites the file")
    s3.config.vaults[0].quietMinutes = 30
    s3.save()
    precondition(fm.contents(atPath: v1Path + ".bak") == Data(v1Text.utf8) && ConfigStore(path: v1Path).config.vaults[0].state == "state.json", "v1 kept as .bak, state file kept")
    s3.importConfig(AppConfig())
    precondition(ConfigStore(path: v1Path).config.vaults.isEmpty && (try! parseConfig(fm.contents(atPath: v1Path + ".bak")!)).vaults[0].quietMinutes == 30, "import keeps the replaced config as .bak")

    print("selftest ok")
}
