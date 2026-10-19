// About window (custom and fit to content: the standard About panel's credits box clips)
// and the menu bar icon.
import AppKit
import SwiftUI

let appName = "Obsidian Vault Git Watcher"
let repoURL = URL(string: "https://github.com/roypadina/ObsidianVaultGitWatcher")!
let koFiURL = URL(string: "https://ko-fi.com/roypadina")!

enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            w.title = "About \(appName)"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    private let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 2) {
                Text(appName).font(.title.bold())
                Text("Version \(info["CFBundleShortVersionString"] as? String ?? "dev") (\(info["CFBundleVersion"] as? String ?? "-"))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                Text("Made by Roy Padina").font(.headline)
                Text("I'm a software engineer from Israel who builds small, focused Mac tools to fix the little annoyances in my own day — then shares them free and open source.")
                Text("If this app saves you time, a coffee on Ko-fi keeps the next one coming. ☕")
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Link(destination: koFiURL) { Text("Support on Ko-fi ☕").frame(minWidth: 140) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Link(destination: repoURL) { Text("GitHub").frame(minWidth: 70) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }

            Link("Report an issue", destination: repoURL.appendingPathComponent("issues"))
                .font(.callout)

            Divider().padding(.vertical, 4)

            Text("\(appName) © Roy Padina · MIT License. Not affiliated with Obsidian.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 380)
    }
}

/// The menu bar glyph (template: follows light/dark and the menu bar tint), with a small
/// badge for the most urgent state. Falls back to an SF Symbol outside the app bundle.
func menuBarImage(for state: String) -> NSImage {
    let base = Bundle.main.image(forResource: "menubar")
        ?? NSImage(systemSymbolName: "diamond", accessibilityDescription: nil)!
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
