// Thin wrappers used both by the menu bar actions (AppDelegate) and by the debug/test
// argv flags in main.swift, so there is exactly one place each action is implemented.
import Foundation

func cliStatus(_ vs: [Vault]) {
    let list: [[String: Any]] = vs.map { v in
        let s = currentStatus(v)
        var obj: [String: Any] = ["vault": v.name, "path": v.path, "enabled": v.cfg.enabled, "state": s.state, "files": s.files]
        if let due = s.due { obj["due"] = due }
        if s.unpushed > 0 { obj["unpushed"] = s.unpushed }
        if let error = s.error { obj["error"] = error }
        return obj
    }
    if let data = try? JSONSerialization.data(withJSONObject: list, options: .withoutEscapingSlashes),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func cliCommit(_ v: Vault, _ msg: String) {
    var s = loadState(v)
    if commitAndPush(v, msg) { s.removeAll() }
    saveState(v, s)
}

func cliSnoozeHours(_ v: Vault, _ hoursStr: String) {
    var s = loadState(v)
    let now = Date()
    ensureTracking(&s, fingerprint(v), now)
    s["due"] = isoString(now.addingTimeInterval((Double(hoursStr) ?? 1) * 3600))
    saveState(v, s)
}

func cliSnoozeTomorrow(_ v: Vault) {
    var s = loadState(v)
    let now = Date()
    ensureTracking(&s, fingerprint(v), now)
    s["due"] = isoString(nextDaily(now, v.cfg))
    saveState(v, s)
}

func cliSkip(_ v: Vault) {
    var s = loadState(v)
    s["skipped"] = fingerprint(v)
    saveState(v, s)
}
