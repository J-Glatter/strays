import AppKit
import StraysCore
import SwiftUI

struct StraysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(store)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    /// Paw + count normally; a flame + live watts when something hidden is burning power.
    @ViewBuilder private var menuBarLabel: some View {
        let badge = store.badge
        if badge.hot {
            Text("\(Image(systemName: "flame.fill")) \(badge.hotFigure)")
        } else if badge.count > 0 {
            Text("\(Image(systemName: "pawprint.fill")) \(String(badge.count))")
        } else {
            Image(systemName: "pawprint")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var debugWindow: NSWindow?
    /// `--window` shows the panel in a normal window, for screenshots and debugging.
    private let windowMode = CommandLine.arguments.contains("--window")

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `swift run` has no Info.plist, so LSUIElement doesn't apply; stay out of the Dock anyway.
        NSApp.setActivationPolicy(windowMode ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !windowMode, let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            NSApp.terminate(nil)
            return
        }
        Store.shared.start()
        if windowMode {
            showWindow()
        } else {
            LoginItem.configureOnFirstLaunch()
        }
    }

    private func showWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Strays"
        let args = CommandLine.arguments
        if args.contains("--tall") { PopoverView.maxListHeight = 4_000 }
        PopoverView.expandFirst = args.contains("--expand-first")
        if args.contains("--legend") { Store.shared.showLegend = true }
        if args.contains("--snapshot") {
            Store.shared.pinnedOpen = true
            Store.shared.setOpen(true)
        }
        let host = NSHostingView(rootView: PopoverView().environmentObject(Store.shared))
        window.contentView = host
        window.center()
        // `--float` keeps the window above other apps, like the real menu bar panel,
        // so visibility tests and open-panel measurements aren't skewed by occlusion.
        if args.contains("--float") { window.level = .statusBar }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugWindow = window

        // `--window --visibility-selftest`: hide and re-show the window and check the store follows.
        if args.contains("--visibility-selftest") {
            var log: [String] = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                log.append("shown: open=\(Store.shared.isOpen)")
                window.orderOut(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    log.append("hidden: open=\(Store.shared.isOpen)")
                    window.makeKeyAndOrderFront(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        log.append("reshown: open=\(Store.shared.isOpen)")
                        print(log.joined(separator: "\n"))
                        NSApp.terminate(nil)
                    }
                }
            }
        }

        // `--window --snapshot out.png`: render the panel to a PNG once data has loaded, then quit.
        // Draws our own view, so it needs no Screen Recording permission.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                Self.snapshot(host, to: path)
                NSApp.terminate(nil)
            }
        }
    }

    /// The hosting view is transparent (the menu bar panel supplies the material),
    /// so composite it over the window background colour.
    private static func snapshot(_ view: NSView, to path: String) {
        let bounds = view.bounds
        guard let content = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: content)
        guard let out = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
        content.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
