import AppKit
import ServiceManagement

/// A System Settings–style grouped form, built with plain AppKit views.
/// Created on demand and released when closed.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let settings: Settings
    private let onChange: () -> Void
    private let onClose: () -> Void

    private let preview = NSImageView()
    private let temperatureSwitch = NSSwitch()
    private let cpuSwitch = NSSwitch()
    private let memorySwitch = NSSwitch()
    private let gpuSwitch = NSSwitch()
    private let gpuStylePopup = NSPopUpButton()
    private let temperatureStylePopup = NSPopUpButton()
    private let cpuStylePopup = NSPopUpButton()
    private let memoryStylePopup = NSPopUpButton()
    private let labelPopup = NSPopUpButton()
    private let unitControl = NSSegmentedControl(labels: ["Celsius", "Fahrenheit"], trackingMode: .selectOne, target: nil, action: nil)
    private let intervalPopup = NSPopUpButton()
    private let loginSwitch = NSSwitch()
    private let alertColorsSwitch = NSSwitch()
    private let notificationsSwitch = NSSwitch()
    private let testButton = NSButton(title: "Send Test", target: nil, action: nil)
    private let temperatureWarningPopup = NSPopUpButton()
    private let cpuWarningPopup = NSPopUpButton()
    private let memoryAlertPopup = NSPopUpButton()
    private let alerts: Alerts

    private static let intervals = [1, 2, 5, 10]

    init(settings: Settings, alerts: Alerts, onChange: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.settings = settings
        self.alerts = alerts
        self.onChange = onChange
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        window.title = "Monitor Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeContent()
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        syncControls()
    }

    func updatePreview(_ image: NSImage) {
        preview.image = image
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    // MARK: Layout

    private func makeContent() -> NSView {
        for (popup, titles) in [
            (cpuStylePopup, Settings.MetricStyle.allCases.map(\.title)),
            (memoryStylePopup, Settings.MetricStyle.allCases.map(\.title)),
            (gpuStylePopup, Settings.MetricStyle.allCases.map(\.title)),
            (labelPopup, Settings.LabelStyle.allCases.map(\.title)),
            (intervalPopup, Self.intervals.map { $0 == 1 ? "Every second" : "Every \($0) seconds" }),
            (cpuWarningPopup, Settings.cpuThresholds.map(Format.percent)),
            (memoryAlertPopup, Settings.MemoryAlert.allCases.map(\.title)),
            (temperatureWarningPopup, Settings.temperatureThresholds.map { _ in "" }), // titles depend on the unit
        ] {
            popup.addItems(withTitles: titles)
        }
        temperatureStylePopup.addItems(withTitles: ["", ""]) // titles depend on the unit; set in syncControls()

        for control in [temperatureSwitch, cpuSwitch, memorySwitch, gpuSwitch, loginSwitch, alertColorsSwitch, notificationsSwitch, testButton] as [NSControl] { control.controlSize = .small }
        testButton.font = .systemFont(ofSize: 11)
        for control in [temperatureStylePopup, cpuStylePopup, memoryStylePopup, gpuStylePopup, labelPopup, intervalPopup,
                        temperatureWarningPopup, cpuWarningPopup, memoryAlertPopup] { control.controlSize = .small; control.font = .systemFont(ofSize: 11) }
        unitControl.controlSize = .small
        for popup in [temperatureStylePopup, cpuStylePopup, memoryStylePopup, gpuStylePopup] {
            popup.widthAnchor.constraint(equalToConstant: 118).isActive = true
        }

        let bindings: [(NSControl, Selector)] = [
            (temperatureSwitch, #selector(changed)), (cpuSwitch, #selector(changed)), (memorySwitch, #selector(changed)),
            (gpuSwitch, #selector(changed)), (gpuStylePopup, #selector(changed)),
            (temperatureStylePopup, #selector(changed)), (cpuStylePopup, #selector(changed)), (memoryStylePopup, #selector(changed)),
            (labelPopup, #selector(changed)), (unitControl, #selector(changed)), (intervalPopup, #selector(changed)),
            (loginSwitch, #selector(toggleLogin)),
            (alertColorsSwitch, #selector(changed)), (temperatureWarningPopup, #selector(changed)),
            (cpuWarningPopup, #selector(changed)), (memoryAlertPopup, #selector(changed)),
            (notificationsSwitch, #selector(toggleNotifications)), (testButton, #selector(sendTest)),
        ]
        for (control, action) in bindings {
            control.target = self
            control.action = action
        }
        preview.imageScaling = .scaleNone

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let menuBar = section("Menu Bar", [
            row("Preview", [preview]),
            row("Temperature", [temperatureStylePopup, temperatureSwitch]),
            row("CPU", [cpuStylePopup, cpuSwitch]),
            row("GPU", [gpuStylePopup, gpuSwitch]),
            row("Memory", [memoryStylePopup, memorySwitch]),
            row("Labels", [labelPopup]),
        ], footer: "Bar, Ring and Graph show usage as a small gauge instead of a number.").views
        let alertSection = section("Alerts", [
            row("Color menu bar near limits", [alertColorsSwitch]),
            row("Notifications", [testButton, notificationsSwitch]),
            row("Temperature warning at", [temperatureWarningPopup]),
            row("CPU warning at", [cpuWarningPopup]),
            row("Memory warning at", [memoryAlertPopup]),
        ], footer: "Orange means a metric passed your warning level. Red means critical: \(Format.temperature(Alerts.criticalTemperature, fahrenheit: settings.fahrenheit, unit: true)) or macOS slowing the chip to cool it, CPU near 100%, or critical memory pressure. CPU is averaged over 30 seconds, so short bursts don't count.").views
        let general = section("General", [
            row("Temperature unit", [unitControl]),
            row("Update", [intervalPopup]),
            row("Launch at login", [loginSwitch]),
        ], footer: "Less frequent updates use slightly less energy.").views

        for view in menuBar + [spacer(14)] + alertSection + [spacer(14)] + general {
            stack.addArrangedSubview(view)
            if view is GroupBox { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        }
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return stack
    }

    private func section(_ title: String, _ rows: [NSView], footer: String) -> (views: [NSView], rows: NSStackView) {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 13, weight: .semibold)

        let box = GroupBox()
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.spacing = 0
        inner.translatesAutoresizingMaskIntoConstraints = false
        setRows(rows, in: inner)
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            inner.topAnchor.constraint(equalTo: box.topAnchor),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])

        let note = NSTextField(wrappingLabelWithString: footer)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 410
        return ([header, box, note], inner)
    }

    private func setRows(_ rows: [NSView], in inner: NSStackView) {
        inner.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let line = NSBox()
                line.boxType = .separator
                inner.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -24).isActive = true
            }
            inner.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
    }


    private func row(_ title: String, _ controls: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label] + controls)
        row.orientation = .horizontal
        row.distribution = .fill // the label (lowest hugging priority) absorbs the slack, pushing controls right
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        return row
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    // MARK: State

    private func syncControls() {
        temperatureSwitch.state = settings.showTemperature ? .on : .off
        cpuSwitch.state = settings.showCPU ? .on : .off
        memorySwitch.state = settings.showMemory ? .on : .off
        gpuSwitch.state = settings.showGPU ? .on : .off
        gpuStylePopup.selectItem(at: settings.gpuStyle.rawValue)
        gpuStylePopup.isEnabled = settings.showGPU
        let unit = settings.fahrenheit ? "F" : "C"
        temperatureStylePopup.item(at: 0)?.title = "48°"
        temperatureStylePopup.item(at: 1)?.title = "48°\(unit)"
        for (i, celsius) in Settings.temperatureThresholds.enumerated() {
            temperatureWarningPopup.item(at: i)?.title = Format.temperature(celsius, fahrenheit: settings.fahrenheit, unit: true)
        }
        temperatureWarningPopup.selectItem(at: Settings.temperatureThresholds.firstIndex(of: settings.temperatureWarning) ?? 3)
        cpuWarningPopup.selectItem(at: Settings.cpuThresholds.firstIndex(of: settings.cpuWarning) ?? 2)
        memoryAlertPopup.selectItem(at: settings.memoryAlert.rawValue)
        alertColorsSwitch.state = settings.alertColors ? .on : .off
        notificationsSwitch.state = settings.alertNotifications ? .on : .off
        testButton.isEnabled = settings.alertNotifications
        temperatureStylePopup.selectItem(at: settings.temperatureStyle.rawValue)
        cpuStylePopup.selectItem(at: settings.cpuStyle.rawValue)
        memoryStylePopup.selectItem(at: settings.memoryStyle.rawValue)
        labelPopup.selectItem(at: settings.labelStyle.rawValue)
        unitControl.selectedSegment = settings.fahrenheit ? 1 : 0
        intervalPopup.selectItem(at: Self.intervals.firstIndex(of: Int(settings.interval)) ?? 1)
        loginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off

        temperatureStylePopup.isEnabled = settings.showTemperature
        cpuStylePopup.isEnabled = settings.showCPU
        memoryStylePopup.isEnabled = settings.showMemory
        labelPopup.isEnabled = settings.showCPU || settings.showMemory || settings.showGPU || settings.showTemperature
    }

    @objc private func changed() {
        settings.showTemperature = temperatureSwitch.state == .on
        settings.showCPU = cpuSwitch.state == .on
        settings.showMemory = memorySwitch.state == .on
        settings.showGPU = gpuSwitch.state == .on
        settings.gpuStyle = Settings.MetricStyle(rawValue: gpuStylePopup.indexOfSelectedItem) ?? .percentage
        settings.temperatureStyle = Settings.TemperatureStyle(rawValue: temperatureStylePopup.indexOfSelectedItem) ?? .degrees
        settings.cpuStyle = Settings.MetricStyle(rawValue: cpuStylePopup.indexOfSelectedItem) ?? .percentage
        settings.memoryStyle = Settings.MetricStyle(rawValue: memoryStylePopup.indexOfSelectedItem) ?? .percentage
        settings.labelStyle = Settings.LabelStyle(rawValue: labelPopup.indexOfSelectedItem) ?? .icons
        settings.fahrenheit = unitControl.selectedSegment == 1
        settings.interval = TimeInterval(Self.intervals[max(0, intervalPopup.indexOfSelectedItem)])
        settings.alertColors = alertColorsSwitch.state == .on
        settings.temperatureWarning = Settings.temperatureThresholds[max(0, temperatureWarningPopup.indexOfSelectedItem)]
        settings.cpuWarning = Settings.cpuThresholds[max(0, cpuWarningPopup.indexOfSelectedItem)]
        settings.memoryAlert = Settings.MemoryAlert(rawValue: memoryAlertPopup.indexOfSelectedItem) ?? .elevated
        syncControls()
        onChange()
    }

    @objc private func toggleNotifications() {
        guard notificationsSwitch.state == .on else {
            settings.alertNotifications = false
            syncControls()
            return
        }
        alerts.requestAuthorization { [weak self] granted in
            guard let self else { return }
            settings.alertNotifications = granted
            syncControls()
            if !granted { showNotificationsBlocked() }
        }
    }

    @objc private func sendTest() {
        alerts.sendTest()
    }

    private func showNotificationsBlocked() {
        let alert = NSAlert()
        alert.messageText = "Notifications are off for Monitor"
        alert.informativeText = "Allow notifications for Monitor in System Settings › Notifications, then turn this on again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn,
                  let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        do {
            if loginSwitch.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't change the login item"
            alert.beginSheetModal(for: window)
        }
        syncControls()
    }
}

/// Rounded "inset grouped" background, like the boxes in System Settings.
private final class GroupBox: NSView {
    private static let fill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.03)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        Self.fill.setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        path.stroke()
    }
}
