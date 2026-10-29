// First-launch welcome (MBX-18): why the app exists, how to use it, how to get back in without the
// icon (MBX-8) and the login switch (MBX-17). Shown once from AppDelegate, again from Settings > General.
import AppKit
import SwiftUI

@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView(
                onOpenSettings: { window?.close(); SettingsWindow.show(vaultsTab: true) },
                onDone: { window?.close() })))
            w.title = "Welcome"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            // Release the window on close so the next open builds the toggle's state afresh.
            Task { @MainActor in
                for await _ in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification, object: w) { break }
                window = nil
            }
        }
        if let window { AccessoryWindows.shared.show(window) }
    }
}

struct WelcomeView: View {
    let onOpenSettings: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to \(appName)").font(.title2.bold())
                    Text("Notes you edit in Obsidian can sit uncommitted and unpushed for days. This app reminds you to commit and push once you stop editing a vault.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            row("menubar.rectangle", "\(appName) lives in the menu bar.",
                "Click the icon to commit and push, snooze a reminder or open Settings. Each vault has its own submenu.")
            row("bell.badge", "It reminds you when you stop editing.",
                "After an hour with no edits, a reminder lists the changed files: Commit, Snooze or Skip. You can change the wait and the reminder time for each vault.")
            row("arrow.triangle.branch", "Add vaults that use git.",
                "Add any Obsidian vault that is a git repository with a remote. Folders you don't add are never touched.")
            row("questionmark.circle", "Icon missing?",
                "Open the app again from Applications to get Settings. If Show the icon is set to Only when a vault needs attention, the icon hides while every vault is clean.")
            VStack(alignment: .leading, spacing: 4) { LaunchAtLoginToggle() }
            SupportBox()
            HStack {
                Button("Open Settings", action: onOpenSettings)
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Quiet Ko-fi box (house style H1): the app's own next step stays the primary button, so this one is `.bordered`.
struct SupportBox: View {
    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free and open source").font(.headline)
                    Text("If \(appName) saves you time, a coffee on Ko-fi keeps the next one coming.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Link("Support on Ko-fi ☕", destination: koFiURL).buttonStyle(.bordered)
            }
            .padding(4)
        }
    }
}
