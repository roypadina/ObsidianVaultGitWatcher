# Changelog

All notable changes to Obsidian Vault Git Watcher are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Welcome window on first launch (and after this update): what the app does, where its icon is, and the launch-at-login switch. Open it again from Settings > General > Welcome Guide….
- App menu with About, Settings…, Hide, Quit, Window and Help (online help opens the wiki) while a window is open.
- The status icon's VoiceOver label and tooltip name the vault that needs attention.

### Changed
- Settings, About and Welcome now show a Dock icon and the menu bar while open, so they can't get lost behind other apps.
- The reminder is titled "<vault> has uncommitted changes" and lists changes as "Modified: …", "New: …", "Deleted: …"; Hebrew and other non-ASCII file names show as written.
- Failure alerts say what failed ("Couldn't commit …", "Couldn't push …") and what to do next.
- The commit and snooze prompts have Commit and Snooze buttons and labeled fields.
- The status menu ends with "Quit Obsidian Vault Git Watcher".
- Settings > General is tall enough to show the About section without scrolling; minimize and zoom are dimmed.
- Uses the current macOS window-activation call, so the reminder no longer forces its way past the window you are typing in.

### Fixed
- Custom snooze rejects text, zero and negative hours instead of silently snoozing for 1 hour or firing at once.
- Status text and icon in the selected vault row stay readable on the selection color.

## [0.2.4] - 2026-10-25

### Changed
- Releases are now signed with a stable identity, so permissions survive future updates. After this one update you may need to re-allow any macOS permission prompts once.

## [0.2.3] - 2026-10-23

### Added
- About: request a feature / contribute. Two buttons open the feature request form and CONTRIBUTING.md; Ko-fi supporters' requests go to the front of the queue.

## [0.2.2] - 2026-10-23

### Fixed
- git is now found in Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`) before `/usr/bin/git`, so Intel Homebrew works. With no git installed the app shows a clear message instead of triggering macOS's command line tools install prompt. The LaunchAgent PATH includes `/usr/local/bin`.

## [0.2.1] - 2026-10-23

### Changed
- Universal build: now runs on Intel Macs (arm64 + x86_64).
- README polish: Requirements block, macOS 15+ first-launch steps, menu bar screenshot.

## [0.2.0] - 2026-10-19

First public release.

### Added
- Settings window (menu bar → Settings…, ⌘,): add vaults with a folder picker (git
  repository with a remote), remove, reorder, turn watching on or off, live status per vault.
- Per-vault settings: name, quiet period, daily reminder time and days, dialog or banner,
  snooze options, commit message template (`{date}` `{time}` `{files}` `{vault}`), stage
  all or tracked files only, ignored paths, push on/off with remote and branch, Obsidian
  vault name.
- General settings: launch at login, menu bar icon visibility and file count, log file,
  export and import of the config.
- Error states (folder missing, not a git repository, commits not pushed) and a Push item.
- About window and Support on Ko-fi menu items; new app and menu bar icons.
- Homebrew cask: `brew install --cask roypadina/tap/obsidian-vault-git-watcher`.

### Changed
- `config.json` has a schema version (2); version 1 files still load, and every change
  saves and applies live (no relaunch).
- No built-in vaults: the first launch opens Settings.
- Quit really quits; the LaunchAgent restarts the app only after a crash.

## [0.1.0] - 2026-09-26

### Added
- Menu bar app that reminds you to commit and push your vaults: quiet period, daily
  reminder, snooze, skip, commit & push from the dialog or the menu, several vaults from one
  `config.json`.
