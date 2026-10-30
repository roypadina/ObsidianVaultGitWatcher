// Obsidian Vault Git Watcher demo. The menu is an NSMenu and the reminder an NSAlert (neither renders offscreen as-is), so every
// string is copied from the app's source with a File.swift:line comment and drawn with kit primitives. The menu bar glyph is the
// app's real menuBarImage(for:) over its real menubar@2x.png (asset dir: env OVGW_ASSETS, default Assets/icons).
import AppKit
import SwiftUI

private let assets = ProcessInfo.processInfo.environment["OVGW_ASSETS"] ?? "Assets/icons"

/// About.swift:100 menuBarImage(for:), verbatim except the base image: the app loads "menubar" from its bundle, here the same PNG from the repo.
func menuBarImage(for state: String) -> NSImage {
    let base = NSImage(contentsOfFile: "\(assets)/menubar@2x.png")!
    base.size = NSSize(width: 18, height: 18)
    let badges = ["pending": "circle.fill", "error": "exclamationmark.circle.fill",
                  "snoozed": "clock.fill", "skipped": "eye.slash.circle.fill"]
    let symbol = badges[state].flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
        .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
        base.draw(in: rect)
        if let symbol {
            let badge = NSRect(x: 10, y: 0, width: 8, height: 8)
            NSGraphicsContext.current?.compositingOperation = .destinationOut // a gap around the badge
            NSBezierPath(ovalIn: badge.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            symbol.draw(in: badge)
        }
        return true
    }
    image.isTemplate = true
    return image
}

/// The template glyph tinted like the menu bar draws it (white on the dark bar), 18 pt at the demo's pixel density.
@MainActor private func glyph(_ state: String) -> CGImage {
    let px = Int((18 * Demo.scale).rounded())
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let r = NSRect(x: 0, y: 0, width: px, height: px)
    menuBarImage(for: state).draw(in: r)
    NSColor(white: 1, alpha: 0.95).setFill()
    r.fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

// AppDelegate.swift:164 buildMenu: "<vault name> — <statusText>" with symbolName(for: state) (Core.swift:288), a submenu per vault.
// Core.swift:307 statusText: pending "<n> file(s) uncommitted", clean "Clean". Fake vaults: Notes (3 changes), Journal (clean).
private let menuRows: [MenuMock.Row] = [
    .item("Notes — 3 files uncommitted", symbol: "exclamationmark.circle", submenu: true),   // AppDelegate.swift:164-165
    .item("Journal — Clean", symbol: "checkmark.circle", submenu: true),                    // AppDelegate.swift:164-165
    .separator,                                                                             // :196
    .item("Settings…", key: "⌘,"),                                                          // :197
    .separator,                                                                             // :198
    .item("About Obsidian Vault Git Watcher"),                                              // :199  "About \(appName)", appName = About.swift:6
    .item("Support on Ko-fi ☕"),                                                            // :200
    .item("Quit Obsidian Vault Git Watcher", key: "⌘Q"),                                    // :201
]

// The same menu after the commit: Notes is clean now (Core.swift:310 statusText "Clean", Core.swift:290 symbolName "checkmark.circle").
private let menuRowsClean: [MenuMock.Row] = [.item("Notes — Clean", symbol: "checkmark.circle", submenu: true)] + menuRows.dropFirst()

// AppDelegate.swift:168-191: a vault with uncommitted changes gets Commit & push…, Snooze… (own submenu), Skip these changes, a
// separator, then Open vault folder / Open in Obsidian / Vault Settings… (no "Push" row: nothing is committed-but-unpushed).
private let subRows: [MenuMock.Row] = [
    .item("Commit & push…"),                       // :169
    .item("Snooze…", submenu: true),               // :171
    .item("Skip these changes"),                   // :181
    .separator,                                    // :182
    .item("Open vault folder"),                    // :189
    .item("Open in Obsidian"),                     // :190
    .item("Vault Settings…"),                      // :191
]

/// The NSAlert from Dialogs.swift reminderAlert(): app icon, bold message, changed files, commit message field, "Snooze for:" popup
/// and the three buttons (the first is the default button, accent-coloured). Metrics measured from the app's own --snapshots render
/// of this dialog (docs/screenshots/reminder.png: 332 x 374 pt).
private struct ReminderDialog: View {
    let icon: NSImage
    let typed: String
    let caret: Bool
    private let accent = Color(red: 0.04, green: 0.52, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: icon).resizable().frame(width: 64, height: 64).padding(.leading, 20).padding(.bottom, 16)
            Text("Notes has uncommitted changes").font(.system(size: 13, weight: .bold)).padding(.leading, 22)           // Dialogs.swift:55
            // Dialogs.swift:56 informativeText = Scheduler.swift:36 changeLine() per `git status --short` line:
            // " M Reading list.md" -> "Modified: Reading list.md", "?? Daily/" -> "New: Daily/", "?? Projects/" -> "New: Projects/"
            Text("Modified: Reading list.md\nNew: Daily/\nNew: Projects/").font(.system(size: 13)).padding(.leading, 22).padding(.top, 10)
            field.padding(.leading, 16).padding(.top, 14)
            snoozeRow.padding(.leading, 16).padding(.top, 6)
            VStack(spacing: 6) {
                button("Commit", primary: true)            // Dialogs.swift:57 (first button = default)
                button("Snooze", primary: false)           // :57
                button("Skip these changes", primary: false)  // :57
            }.frame(width: 332).padding(.top, 16)
            Spacer(minLength: 0)
        }
        .padding(.top, 20).frame(width: 332, height: 374, alignment: .topLeading)
    }

    /// Dialogs.swift:59-60: 300 x 24 field, placeholder "Commit message (optional)", first responder (so the caret blinks from the start).
    private var field: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.22))
            RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            // first responder (Dialogs.swift:70 initialFirstResponder): macOS 26 draws the accent focus ring, ~3 pt outside the field
            RoundedRectangle(cornerRadius: 9.5, style: .continuous).strokeBorder(accent.opacity(0.5), lineWidth: 3).padding(-3)
            HStack(spacing: 0) {
                if typed.isEmpty { Rectangle().fill(.white.opacity(caret ? 0.9 : 0)).frame(width: 1, height: 15).padding(.trailing, 1) }
                Text(typed.isEmpty ? "Commit message (optional)" : typed).font(.system(size: 13))
                    .foregroundStyle(typed.isEmpty ? Color.white.opacity(0.35) : .white)
                if !typed.isEmpty { Rectangle().fill(.white.opacity(caret ? 0.9 : 0)).frame(width: 1, height: 15).padding(.leading, 1) }
            }.padding(.leading, 8)
        }.frame(width: 300, height: 24)
    }

    /// Dialogs.swift:62-68: "Snooze for:" label (80 pt) + popup (220 pt) whose first item is hoursLabel(1) = "1 hour" (Dialogs.swift:31, snoozeHours [1, 3]: Config.swift:29).
    private var snoozeRow: some View {
        HStack(spacing: 0) {
            Text("Snooze for:").font(.system(size: 13)).frame(width: 80, alignment: .leading)
            HStack {
                Text("1 hour").font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 10).frame(width: 220, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.14)))
        }
    }

    private func button(_ title: String, primary: Bool) -> some View {
        Text(title).font(.system(size: 13)).frame(width: 232, height: 28)
            .background(Capsule().fill(primary ? accent : Color.white.opacity(0.14)))
    }
}

private let W = Demo.size.width, H = Demo.size.height
private let dialogOrigin = CGPoint(x: (W - 332) / 2, y: 74)   // NSAlert windows centre on the screen, slightly above the middle
private let commitButton = CGPoint(x: dialogOrigin.x + 166, y: dialogOrigin.y + 20 + 64 + 16 + 16 + 10 + 48 + 14 + 24 + 6 + 26 + 16 + 14)   // centre of "Commit"
private let message = "Weekly review"
// Clocks of equal width, so the status item stays put between scenes. An hour of quiet separates the two (Config.swift:26 quietMinutes = 60).
private let clockEditing = "Thu Oct 30 10:41 AM", clockReminder = "Thu Oct 30 11:42 AM"

@MainActor func vaultWatcherScenes() -> [Scene] {
    let icon = NSImage(contentsOfFile: "\(assets)/AppIcon-1024.png")!
    var dialogCache: [String: CGImage] = [:]
    func dialog(_ typed: String, caret: Bool) -> CGImage {
        let key = "\(typed)|\(caret)"
        if let hit = dialogCache[key] { return hit }
        let img = renderView(ReminderDialog(icon: icon, typed: typed, caret: caret))!
        dialogCache[key] = img
        return img
    }
    let calm = glyph("clean"), pending = glyph("pending")

    // The kit's menu bar takes one SF-Symbol/text item: reserve an 18 pt blank slot for the app's real glyph and draw it on top.
    // (showFileCount is off by default, Config.swift:93, so the status item is the glyph alone.)
    let space = NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 13)]).size().width
    let slot = StatusItem(text: String(repeating: " ", count: Int((18 / space).rounded(.up))))
    let item = Canvas(background: nil).menuBar(app: slot, clock: clockEditing)
    let glyphRect = CGRect(x: item.midX - 9, y: Demo.barHeight / 2 - 9, width: 18, height: 18)

    func bar(_ c: Canvas, dot: Bool, clock: String, pressed: Bool = false) {
        c.menuBar(app: slot, appActive: pressed, clock: clock)
        c.draw(dot ? pending : calm, in: glyphRect)   // AppDelegate.swift:127,134: one icon for all vaults, the most urgent state wins
    }

    // menus: parent under the status item; the "Notes" submenu opens to the left, as AppKit flips it at the screen edge, top row level with "Notes"
    let menu = Canvas.menuFrame(menuRows, under: item)
    let rowFrames = MenuMock.frames(menuRows).map { $0.offsetBy(dx: menu.minX, dy: menu.minY) }
    func rowCenter(_ i: Int) -> CGPoint { CGPoint(x: menu.maxX - 40, y: rowFrames[i].midY) }
    let subSize = MenuMock.size(subRows)
    let subX = menu.minX + 4 - subSize.width
    let subDy = rowFrames[0].minY - MenuMock.pad - (Demo.barHeight + 2)
    func drawSubmenu(_ c: Canvas, alpha: CGFloat) {
        let mc = Canvas(background: nil)
        mc.menu(subRows, under: CGRect(x: subX, y: 0, width: 1, height: 1), alpha: alpha)
        c.draw(mc.image, in: Demo.bounds.offsetBy(dx: 0, dy: subDy))
    }

    // 1. the badge: a vault gets uncommitted changes (AppDelegate.show() swaps the glyph at once)
    let s1 = Scene(name: "icon", duration: 2.0, caption: "A dot appears when a vault has uncommitted changes") { t in
        let c = Canvas()
        bar(c, dot: t >= 0.6, clock: clockEditing)
        return c.image
    }

    // 2. the menu: click opens it at once; hovering "Notes" opens its submenu; a click on the desktop closes everything at once
    let path2 = CursorPath(start: CGPoint(x: W * 0.78, y: H * 0.42),
                           moves: [.init(t0: 0.10, t1: 0.60, to: CGPoint(x: item.midX, y: Demo.barHeight / 2)),
                                   .init(t0: 0.95, t1: 1.35, to: rowCenter(0)),
                                   .init(t0: 2.55, t1: 2.95, to: CGPoint(x: W * 0.86, y: H * 0.62))],
                           clicks: [0.70, 3.00])
    let s2 = Scene(name: "menu", duration: 3.4, caption: "Each vault shows its status in the menu") { t in
        let c = Canvas()
        let open = t >= 0.70 && t < 3.00
        bar(c, dot: true, clock: clockEditing, pressed: open)
        if open { c.menu(menuRows, under: item, hover: path2.position(t), alpha: CGFloat(ramp(t, 0.70, 0.82))) }
        if t >= 1.55 && t < 2.60 { drawSubmenu(c, alpha: CGFloat(ramp(t, 1.55, 1.67))) }   // AppKit opens a submenu ~0.2 s after the pointer rests on its row
        let click = path2.click(t)
        c.cursor(at: path2.position(t), alpha: CGFloat(ramp(t, 0.0, 0.25) * (1 - ramp(t, 3.10, 3.30))), press: click.press, pulse: click.pulse)
        return c.image
    }

    // 3. an hour later the scheduled check shows the reminder (Scheduler.swift runScheduledCheck -> askMain -> NSAlert.runModal): it appears at once
    let s3 = Scene(name: "reminder", duration: 2.2, caption: "After you stop editing, a reminder lists the changes") { t in
        let c = Canvas()
        bar(c, dot: true, clock: clockReminder)
        c.panel(dialog("", caret: Int(t * 2) % 2 == 0), at: dialogOrigin, radius: 26, alpha: CGFloat(ramp(t, 0.10, 0.28)))
        return c.image
    }

    // 4. type a message, click Commit: the dialog closes at once, git commit + push run, the next refresh clears the badge (~0.4 s)
    let path4 = CursorPath(start: CGPoint(x: W * 0.74, y: H * 0.78),
                           moves: [.init(t0: 1.35, t1: 1.90, to: commitButton)],
                           clicks: [2.00])
    let s4 = Scene(name: "commit", duration: 3.0, caption: "Type a message, click Commit, and it's pushed") { t in
        let c = Canvas()
        let typedCount = max(0, min(message.count, Int((t - 0.30) * 11)))
        let gone = ramp(t, 2.00, 2.10)
        bar(c, dot: t < 2.40, clock: clockReminder)
        if gone < 1 {
            c.panel(dialog(String(message.prefix(typedCount)), caret: Int((t + 2.2) * 2) % 2 == 0), at: dialogOrigin, radius: 26, alpha: CGFloat(1 - gone))
        }
        let click = path4.click(t)
        c.cursor(at: path4.position(t), alpha: CGFloat(ramp(t, 1.20, 1.40) * (1 - ramp(t, 2.15, 2.40))), press: click.press, pulse: click.pulse)
        return c.image
    }

    // 5. the payoff: no badge, and the menu now reads "Clean" for every vault
    let path5 = CursorPath(start: CGPoint(x: W * 0.78, y: H * 0.42),
                           moves: [.init(t0: 0.10, t1: 0.55, to: CGPoint(x: item.midX, y: Demo.barHeight / 2))],
                           clicks: [0.65])
    let s5 = Scene(name: "clean", duration: 2.2, caption: "Back to clean until you edit again") { t in
        let c = Canvas()
        let open = t >= 0.65
        bar(c, dot: false, clock: clockReminder, pressed: open)
        if open { c.menu(menuRowsClean, under: item, hover: path5.position(t), alpha: CGFloat(ramp(t, 0.65, 0.77))) }
        let click = path5.click(t)
        c.cursor(at: path5.position(t), alpha: CGFloat(ramp(t, 0.0, 0.25) * (1 - ramp(t, 1.90, 2.10))), press: click.press, pulse: click.pulse)
        return c.image
    }
    return [s1, s2, s3, s4, s5]
}

@main struct VaultWatcherDemo {
    @MainActor static func main() { Demo.run(scenes: vaultWatcherScenes()) }
}
