// Entry point. No args -> the persistent menu bar app (the only shipped mode).
// The flags below are test/debug hooks onto the exact same functions the app uses
// internally — they exist so the single binary stays testable without a companion
// script, not as a second public interface.
import AppKit

let argv = Array(CommandLine.arguments.dropFirst())

func arg(after flag: String) -> String? {
    guard let i = argv.firstIndex(of: flag), argv.count > i + 1 else { return nil }
    return argv[i + 1]
}

/// `--vault NAME` (display name, folder name or path) narrows the flags below to one
/// vault; default: every configured vault, enabled or not.
func selectedVaults() -> [Vault] {
    guard let n = arg(after: "--vault") else { return store.vaults }
    return store.vaults.filter { $0.name == n || ($0.path as NSString).lastPathComponent == n || $0.path == expand(n) }
}

/// State-changing flags act on exactly one vault, never silently on all of them.
func oneVault() -> Vault {
    let vs = selectedVaults()
    guard vs.count == 1 else {
        FileHandle.standardError.write(Data("Pick one vault with --vault: \(store.vaults.map(\.name).joined(separator: ", "))\n".utf8))
        exit(2)
    }
    return vs[0]
}

if argv.contains("--selftest") {
    selftest()
} else if argv.contains("--status") {
    cliStatus(selectedVaults())
} else if argv.contains("--commit") {
    cliCommit(oneVault(), arg(after: "--commit") ?? "")
} else if argv.contains("--snooze-hours") {
    cliSnoozeHours(oneVault(), arg(after: "--snooze-hours") ?? "1")
} else if argv.contains("--snooze-tomorrow") {
    cliSnoozeTomorrow(oneVault())
} else if argv.contains("--skip") {
    cliSkip(oneVault())
} else if let dir = arg(after: "--snapshots") {
    snapshotSettings(to: dir) // debug: README/wiki images, rendered off screen
} else if argv.contains("--check-now") {
    selectedVaults().filter(\.cfg.enabled).forEach(runScheduledCheck) // debug: force one scheduled check synchronously (may show a real dialog)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
