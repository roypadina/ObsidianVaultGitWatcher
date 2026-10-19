# Contributing to Obsidian Vault Git Watcher

Thanks for your interest! Bug reports, feature ideas, docs and code are all welcome.

## Ground rules

- **`main` is protected.** No direct pushes; changes land via Pull Request and are
  reviewed/merged by the maintainer ([@roypadina](https://github.com/roypadina)).
- Be respectful — see the [Code of Conduct](CODE_OF_CONDUCT.md).
- Keep changes focused. One logical change per PR, smallest diff that solves it.

## Getting started

```bash
git clone https://github.com/roypadina/ObsidianVaultGitWatcher.git
cd ObsidianVaultGitWatcher
./build.sh                 # builds build/ObsidianVaultGitWatcher.app
build/ObsidianVaultGitWatcher.app/Contents/MacOS/ObsidianVaultGitWatcher --selftest
```

Requirements: **macOS 14+** and the Xcode command line tools (`xcode-select --install`).
No Xcode project and no third-party dependencies: `build.sh` runs `swiftc` over `App/*.swift`.

To try a change without touching your real vaults, point the app at a throwaway config:

```bash
OBSIDIAN_VAULT_GIT_WATCHER_CONFIG=/tmp/ovgw-test/config.json \
  build/ObsidianVaultGitWatcher.app/Contents/MacOS/ObsidianVaultGitWatcher
```

## Layout

- `App/Core.swift` — vaults, git calls, the reminder schedule, live status.
- `App/Config.swift` — `config.json` (schema, validation, live reload).
- `App/Scheduler.swift` — the scheduled check and the `--selftest` suite.
- `App/AppDelegate.swift` — menu bar icon and menu, FSEvents, timers.
- `App/Settings.swift` — the Settings window (SwiftUI); `App/About.swift` — About window.
- `App/Dialogs.swift` — reminder dialog, commit and push.
- `Assets/icons` — SVG sources for the app and menu bar icons; regenerate the PNG/icns
  with `Scripts/make_icons.sh` (needs `brew install librsvg`).

## Workflow

1. **Fork** and branch: `git checkout -b feat/my-thing`.
2. Make your change; run `--selftest` (add a case for new logic) and try it in the built app.
3. Match the surrounding style; no drive-by refactors.
4. Open a **Pull Request** against `main`. CI must be green and the maintainer must approve.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org): `feat: ...`, `fix: ...`, `docs: ...`.

## Reporting bugs / requesting features

Use the [issue templates](https://github.com/roypadina/ObsidianVaultGitWatcher/issues/new/choose).
