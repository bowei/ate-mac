import AppKit
import Combine
import SwiftUI

/// Owns the controller, the menu bar icon and the status window. A left click
/// on the icon opens the window; a right click shows a short menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let controller = Controller()
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // @Published fires before the change lands; the tooltip reads the
        // controller, so wait for the next run loop turn.
        controller.$phase.combineLatest(controller.$ready, controller.$detail)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, ready, _ in self?.updateIcon(phase: phase, ready: ready) }
            .store(in: &cancellables)
        // Open the window on first use, so there's something to click Start in.
        controller.$phase.first { $0 != .unknown }
            .sink { [weak self] phase in if phase == .notCreated { self?.showWindow() } }
            .store(in: &cancellables)
    }

    /// Clicking the app in Finder or the Dock while it runs opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    private func updateIcon(phase: Phase, ready: Bool) {
        let name: String
        switch phase {
        case .failed: name = "exclamationmark.triangle"
        case .running where ready: name = "shippingbox.fill"
        default: name = "shippingbox"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Substrate")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Substrate: \(controller.statusText)"
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            showWindow()
        }
    }

    // MARK: Window

    func showWindow() {
        let window = self.window ?? makeWindow()
        self.window = window
        // A regular app gets a Dock icon and a place in Cmd-Tab while the
        // window is open; windowWillClose switches back.
        NSApp.setActivationPolicy(.regular)
        controller.windowVisible = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: StatusWindow(controller: controller))
        // The window sets the size, not the SwiftUI content.
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.title = "Substrate"
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 960, height: 640))
        if !window.setFrameUsingName("StatusWindow") {
            window.center()
        }
        window.setFrameAutosaveName("StatusWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        controller.windowVisible = false
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Menu

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(item("Open Status Window") { [weak self] in self?.showWindow() })
        menu.addItem(.separator())
        let status = NSMenuItem(title: controller.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        switch controller.phase {
        case .notCreated, .stopped, .failed:
            menu.addItem(item("Start") { [weak self] in self?.controller.start() })
        case .running:
            menu.addItem(item("Stop") { [weak self] in self?.controller.stop() })
            menu.addItem(item("Restart") { [weak self] in self?.controller.restart() })
        default:
            break
        }
        menu.addItem(item("Copy Shell Setup") { [weak self] in self?.controller.copyShellSetup() })
        menu.addItem(item("Show Log") { [weak self] in self?.controller.showLog() })
        menu.addItem(.separator())
        menu.addItem(item("Quit") { NSApp.terminate(nil) })
        if controller.phase == .running {
            menu.addItem(item("Stop and Quit") { [weak self] in
                self?.controller.stop { NSApp.terminate(nil) }
            })
        }
        // Attaching the menu only for this click keeps left clicks opening
        // the window.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, action: action)
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { run() }
}
