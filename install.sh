#!/bin/sh
# Rebuilds and installs ObsidianVaultGitWatcher.app into /Applications, then reloads
# the LaunchAgent so it runs from there (not from build/). One command per update.
set -e
cd "$(dirname "$0")"

./build.sh dist

TMP=$(mktemp -d)
ditto -x -k dist/ObsidianVaultGitWatcher.zip "$TMP"
rm -rf /Applications/ObsidianVaultGitWatcher.app
mv "$TMP/ObsidianVaultGitWatcher.app" /Applications/
rm -rf "$TMP"

cp com.roypadina.obsidian-vault-git-watcher.plist ~/Library/LaunchAgents/
launchctl bootout gui/$(id -u)/com.roypadina.obsidian-vault-git-watcher 2>/dev/null || true
# bootout returns before the job is gone; bootstrapping too early fails with "5: Input/output error"
i=0; while launchctl print gui/$(id -u)/com.roypadina.obsidian-vault-git-watcher >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.roypadina.obsidian-vault-git-watcher.plist

echo "Installed /Applications/ObsidianVaultGitWatcher.app and reloaded the LaunchAgent."
