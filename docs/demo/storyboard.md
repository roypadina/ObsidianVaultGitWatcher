# Obsidian Vault Git Watcher demo — storyboard (12.8 s, loops)

Why it is worth installing: notes edited in Obsidian sit uncommitted for days; the app waits until you stop editing, then reminds you
with the changed files in plain words and commits + pushes in one click. Nothing from the app compiles offscreen as-is (the menu is an
`NSMenu`, the reminder an `NSAlert`), so every on-screen string is copied from the source with a `// File.swift:line` comment and drawn
with kit primitives; the menu bar glyph is the app's real `menuBarImage(for:)` (About.swift) over its real `menubar@2x.png`, the dialog
icon its real `AppIcon-1024.png`. Fake data: vaults "Notes" (3 changes) and "Journal" (clean), README demo names; commit message "Weekly review".

| # | Scene | Start | Dur | What happens | Caption |
|---|-------|-------|-----|--------------|---------|
| 1 | icon | 0.0 | 2.0 | Menu bar, clock 10:41. Calm diamond glyph; at 0.6 s the badge dot appears (a vault now has uncommitted changes). | A dot appears when a vault has uncommitted changes |
| 2 | menu | 2.0 | 3.4 | Cursor to the icon, click: item highlights, menu opens at once (Notes — 3 files uncommitted, Journal — Clean, Settings…, About, Support on Ko-fi, Quit). Hover "Notes": its submenu opens (Commit & push…, Snooze…, Skip these changes, Open vault folder, Open in Obsidian, Vault Settings…). Click on the desktop: both close at once. | Each vault shows its status in the menu |
| 3 | reminder | 5.4 | 2.2 | Clock 11:42 (an hour of quiet later). The reminder dialog appears at once, centred: "Notes has uncommitted changes", Modified/New lines, commit message field, Snooze for: 1 hour, Commit / Snooze / Skip these changes. | After you stop editing, a reminder lists the changes |
| 4 | commit | 7.6 | 3.0 | The message is typed ("Weekly review"), cursor glides to Commit, click: dialog closes at once; 0.4 s later the badge is gone. | Type a message, click Commit, and it's pushed |
| 5 | clean | 10.6 | 2.2 | Calm glyph. Cursor to the icon, click: the menu now reads "Notes — Clean" / "Journal — Clean" (check marks). | Back to clean until you edit again |

Transitions: 0.2 s crossfade between scenes; captions fade old 0–0.12 s / new 0.12–0.35 s; the last 0.2 s dissolves into scene 1's first
frame (calm icon, closed bar: clean loop). Cursor: system arrow, eased glides, click = dip + ripple; visible only while it points at something.
Not shown: the macOS "Committed and pushed" banner (the app sends it through osascript, so it would carry Script Editor's name and icon).
Render: `./render.sh` (swiftc + 30 fps frames + encode).
