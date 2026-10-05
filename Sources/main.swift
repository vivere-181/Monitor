import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let settings = Settings()
    private let monitor = Monitor()
    private let alerts = Alerts()
    private var statusItem: NSStatusItem!
    private var menuView: DashboardView!
    private var window: NSWindow?
    private var windowView: DashboardView?
    private var settingsController: SettingsWindowController?
    private var menuOpen = false
    private var lastSignature = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        alerts.activate()
        alerts.onOpen = { [weak self] in self?.showDashboard() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.menu = buildStatusMenu()

        monitor.interval = settings.interval
        monitor.onUpdate = { [weak self] in self?.refresh() }
        monitor.start()

        if settings.dashboardOpen { showDashboard() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Updates

    private func refresh() {
        alerts.evaluate(monitor.snapshot, settings: settings)
        updateStatusItem()
        if menuOpen { menuView.needsDisplay = true }
        if isWindowOnScreen { windowView?.needsDisplay = true }
    }

    private func updateStatusItem(force: Bool = false) {
        let (image, signature) = StatusRenderer.render(monitor: monitor, settings: settings, alerts: alerts.state)
        settingsController?.updatePreview(image)
        guard force || signature != lastSignature else { return }
        lastSignature = signature
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityLabel(image.accessibilityDescription)
    }

    private func settingsChanged() {
        monitor.interval = settings.interval
        updateStatusItem(force: true)
        if menuOpen { menuView.needsDisplay = true }
        windowView?.needsDisplay = true
    }

    private var isWindowOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    private func updateDetailVisibility() {
        monitor.detailVisible = menuOpen || isWindowOnScreen
    }

    /// Show a Dock icon and app menu only while one of our windows is open.
    private func updateActivationPolicy() {
        NSApp.setActivationPolicy(window != nil || settingsController != nil ? .regular : .accessory)
    }

    private func activate() {
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: Status menu

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        menuView = DashboardView(monitor: monitor, settings: settings, alerts: alerts, width: 300)
        let dashboardItem = NSMenuItem()
        dashboardItem.view = menuView
        menu.addItem(dashboardItem)
        menu.addItem(.separator())
        menu.addItem(item("Open Dashboard", #selector(openDashboard), key: "d"))
        menu.addItem(item("Activity Monitor", #selector(openActivityMonitor)))
        menu.addItem(.separator())
        menu.addItem(item("Monitor Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Monitor", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        menuOpen = true
        updateDetailVisibility()
        menuView.needsDisplay = true
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        menuOpen = false
        updateDetailVisibility()
    }

    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Settings window

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                settings: settings,
                alerts: alerts,
                onChange: { [weak self] in self?.settingsChanged() },
                onClose: { [weak self] in
                    // Release the window entirely once it's closed.
                    DispatchQueue.main.async {
                        self?.settingsController = nil
                        self?.updateActivationPolicy()
                    }
                })
            updateStatusItem(force: true)
        }
        updateActivationPolicy()
        settingsController?.window.makeKeyAndOrderFront(nil)
        activate()
    }

    // MARK: Dashboard window

    @objc private func openDashboard() { showDashboard() }

    private func showDashboard() {
        if window == nil {
            let titlebar: CGFloat = 28
            let view = DashboardView(monitor: monitor, settings: settings, alerts: alerts, width: 340, topInset: titlebar)
            let window = NSWindow(contentRect: view.frame,
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Monitor"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = view
            window.center()
            window.setFrameAutosaveName("Dashboard")

            self.window = window
            self.windowView = view
        }
        updateActivationPolicy()
        window?.makeKeyAndOrderFront(nil)
        activate()
        settings.dashboardOpen = true
        updateDetailVisibility()
        windowView?.needsDisplay = true
    }

    func windowWillClose(_ notification: Notification) {
        // Free the dashboard entirely; drop back to menu-bar-only if nothing else is open.
        window?.delegate = nil
        window = nil
        windowView = nil
        settings.dashboardOpen = false
        updateActivationPolicy()
        updateDetailVisibility()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateDetailVisibility()
    }

    // MARK: Main menu (visible while a window is open)

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Monitor", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(openSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Monitor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu("Monitor", appMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Dashboard", #selector(openDashboard), key: "d"))
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu("Window", windowMenu))
        NSApp.windowsMenu = windowMenu
        return main
    }
}

// MARK: - Entry point

/// `Monitor --render out.png [--dark]` draws the dashboard to an image and exits (handy for checking layout).
func renderSnapshot(to path: String, dark: Bool) {
    let settings = Settings()
    let monitor = Monitor()
    monitor.detailVisible = true
    monitor.tickNow()
    Thread.sleep(forTimeInterval: 1)
    monitor.tickNow()
    let view = DashboardView(monitor: monitor, settings: settings, alerts: Alerts(), width: 300)
    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let container = NSView(frame: view.frame)
    container.wantsLayer = true
    container.layer?.backgroundColor = (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
    container.addSubview(view)
    guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
    container.cacheDisplay(in: container.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
    renderSnapshot(to: args[i + 1], dark: args.contains("--dark"))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
