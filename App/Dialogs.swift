// Dialogs, ported from the original Python prototype's osa()/ask_main()/commit().
// The scheduled reminder is a native NSAlert so the snooze picker can sit in the same
// window as the commit field (osascript's display dialog caps out at 3 buttons); its
// "giving up after 3600" auto-dismiss is kept with a modal-mode Timer. Alerts and
// notifications after a commit are still osascript calls.
import Cocoa

/// Runs AppleScript `lines` wrapped in `on run argv ... end run`, passing argv
/// positionally (avoids quoting). nil on error/cancel.
@discardableResult
func osa(_ lines: [String], _ argv: [String]) -> String? {
    var cmdArgs: [String] = []
    for line in (["on run argv"] + lines + ["end run"]) { cmdArgs += ["-e", line] }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = cmdArgs + argv
    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func notify(_ text: String, title: String) {
    osa(["display notification (item 1 of argv) with title (item 2 of argv)"], [text, title])
}

func hoursLabel(_ h: Double) -> String {
    h < 1 ? "\(Int((h * 60).rounded())) minutes" : "\(formatHours(h)) hour\(h == 1 ? "" : "s")"
}

/// "Until tomorrow 10:00" / "Until Monday 10:00": the snooze that waits for the next reminder time.
func untilLabel(_ cfg: VaultConfig) -> String {
    let d = nextDaily(Date(), cfg)
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    let cal = Calendar.current
    let day = cal.isDateInToday(d) ? "today" : cal.isDateInTomorrow(d) ? "tomorrow" : d.formatted(.dateTime.weekday(.wide))
    return "Until \(day) \(f.string(from: d))"
}

typealias SnoozeChoice = (title: String, until: (Date) -> Date)

/// The reminder dialog: Commit / Snooze / Skip, with a commit message field and the snooze
/// duration picker in the same window (also rendered by --snapshot-settings).
func reminderAlert(_ v: Vault, _ changes: String) -> (NSAlert, NSTextField, NSPopUpButton, [SnoozeChoice]) {
    let snoozeChoices: [SnoozeChoice] = v.cfg.snoozeHours.map { h in
        (hoursLabel(h), { $0.addingTimeInterval(h * 3600) })
    } + [(untilLabel(v.cfg), { nextDaily($0, v.cfg) })]

    let alert = NSAlert()
    alert.messageText = v.title
    alert.informativeText = "Uncommitted changes in \(v.name):\n\n\(changes)"
    for title in ["Commit", "Snooze", "Skip these changes"] { alert.addButton(withTitle: title) }

    let field = NSTextField(frame: NSRect(x: 0, y: 32, width: 300, height: 24))
    field.placeholderString = "Commit message (optional)"
    let label = NSTextField(labelWithString: "Snooze for:")
    label.frame = NSRect(x: 0, y: 4, width: 80, height: 18)
    let picker = NSPopUpButton(frame: NSRect(x: 80, y: 0, width: 220, height: 26), pullsDown: false)
    picker.addItems(withTitles: snoozeChoices.map(\.title))
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
    [field, label, picker].forEach(box.addSubview)
    alert.accessoryView = box
    alert.window.initialFirstResponder = field
    return (alert, field, picker, snoozeChoices)
}

/// The scheduled reminder: shows reminderAlert(); auto-dismisses after an hour.
func askMain(_ v: Vault, _ changes: String) -> (button: String, message: String, snoozeUntil: Date) {
    // AppKit must run on main; the scheduled check calls this from AppDelegate.checkQueue.
    if !Thread.isMainThread { return DispatchQueue.main.sync { askMain(v, changes) } }
    let (alert, field, picker, snoozeChoices) = reminderAlert(v, changes)

    // abortModal() is the documented way to end runModal() from a timer -> returns .abort
    let timeout = Timer(timeInterval: 3600, repeats: false) { _ in NSApplication.shared.abortModal() }
    RunLoop.main.add(timeout, forMode: .modalPanel)
    NSApplication.shared.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    timeout.invalidate()

    let msg = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let until = snoozeChoices[picker.indexOfSelectedItem].until(Date())
    switch response {
    case .alertFirstButtonReturn: return ("Commit", msg, until)
    case .alertSecondButtonReturn: return ("Snooze", msg, until)
    case .alertThirdButtonReturn: return ("Skip these changes", msg, until)
    default: return ("dismiss", msg, until) // timed out
    }
}

enum CommitError: Error, CustomStringConvertible {
    case commit(String) // nothing landed
    case push(String) // committed locally, push failed
    var description: String { switch self { case .commit(let m), .push(let m): return m } }
}

/// Stage (the vault's stage mode and ignore list), commit, push if the vault pushes.
/// An empty `msg` uses the vault's message template. Returns the commit message.
func commitVault(_ v: Vault, _ msg: String, now: Date = Date()) throws -> String {
    let message = msg.isEmpty ? expandTemplate(v.cfg.commitMessage, v, files: statusLines(v).count, now: now) : msg
    do {
        try git(v, addArgs(v))
        try git(v, ["commit", "-q", "-m", message])
    } catch {
        throw CommitError.commit("\(error)")
    }
    if v.cfg.push {
        do { try git(v, pushArgs(v)) } catch { throw CommitError.push("\(error)") }
    }
    return message
}

/// {date} {time} {files} {vault} in the commit message template.
func expandTemplate(_ template: String, _ v: Vault, files: Int, now: Date = Date()) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    let date = f.string(from: now)
    f.dateFormat = "HH:mm"
    let out = template
        .replacingOccurrences(of: "{date}", with: date)
        .replacingOccurrences(of: "{time}", with: f.string(from: now))
        .replacingOccurrences(of: "{files}", with: String(files))
        .replacingOccurrences(of: "{vault}", with: v.name)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return out.isEmpty ? "Vault update \(date)" : out
}

/// `git push`, or to the vault's own remote/branch when set.
func pushArgs(_ v: Vault) -> [String] {
    if v.cfg.remote.isEmpty && v.cfg.branch.isEmpty { return ["push", "-q"] }
    let remote = v.cfg.remote.isEmpty ? upstreamRemote(v) : v.cfg.remote
    return ["push", "-q", remote, v.cfg.branch.isEmpty ? "HEAD" : "HEAD:refs/heads/\(v.cfg.branch)"]
}

/// Menu "Push": for commits a failed push (or a terminal commit) left behind.
func pushNow(_ v: Vault) {
    do {
        try git(v, pushArgs(v))
        notify("Pushed", title: v.title)
    } catch {
        logLine("\(v.name): push failed: \(error)")
        osa(["display alert (item 1 of argv) message (item 2 of argv) as warning"], ["Push failed - \(v.name)", "\(error)"])
    }
}

@discardableResult
func commitAndPush(_ v: Vault, _ msg: String) -> Bool {
    do {
        let message = try commitVault(v, msg)
        notify(v.cfg.push ? "Committed and pushed: \(message)" : "Committed: \(message)", title: v.title)
        return true
    } catch CommitError.push(let error) {
        logLine("\(v.name): push failed: \(error)")
        osa(["display alert (item 1 of argv) message (item 2 of argv) as warning"],
            ["Committed, but push failed - \(v.name)", "\(error)\n\nRun `git push` in \(v.path)."])
        return true
    } catch {
        logLine("\(v.name): commit failed: \(error)")
        osa(["display alert (item 1 of argv) message (item 2 of argv) as critical"],
            ["Commit failed - \(v.name)", "\(error)"])
        return false
    }
}
