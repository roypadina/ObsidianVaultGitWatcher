# Changelog

All notable changes to Obsidian Vault Git Watcher are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
