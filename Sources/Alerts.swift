import AppKit
import UserNotifications

enum AlertLevel: Int, Comparable {
    case normal, warning, critical

    static func < (a: AlertLevel, b: AlertLevel) -> Bool { a.rawValue < b.rawValue }

    var color: NSColor? {
        switch self {
        case .normal: nil
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }
}

struct AlertState: Equatable {
    var temperature = AlertLevel.normal
    var cpu = AlertLevel.normal
    var memory = AlertLevel.normal
}

/// Turns samples into normal / warning / critical levels and posts a notification when a metric gets worse.
/// Levels use hysteresis (a metric has to drop a bit below its threshold to clear) so colors don't flicker,
/// and CPU is averaged over 30 s so short bursts don't count.
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let criticalTemperature = 95.0
    static let cpuWindow: TimeInterval = 30
    static let notificationCooldown: TimeInterval = 10 * 60

    private(set) var state = AlertState()
    private(set) var cpuAverage = 0.0
    private var cpuSamples: [(time: TimeInterval, value: Double)] = []
    private var notified: [String: (level: AlertLevel, time: Date)] = [:]

    /// Called when the user clicks a notification.
    var onOpen: (() -> Void)?

    /// Hooks up notification clicks. Only valid inside the app bundle.
    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: Evaluation

    func evaluate(_ s: Snapshot, settings: Settings) {
        let previous = state

        if let t = s.temps.cpuAvg {
            let warning = settings.temperatureWarning
            let throttling = s.thermalState == .serious || s.thermalState == .critical
            if t >= Self.criticalTemperature || throttling || (previous.temperature == .critical && t >= Self.criticalTemperature - 3) {
                state.temperature = .critical
            } else if t >= warning || (previous.temperature >= .warning && t >= warning - 3) {
                state.temperature = .warning
            } else {
                state.temperature = .normal
            }
        } else {
            state.temperature = .normal
        }

        let now = ProcessInfo.processInfo.systemUptime
        cpuSamples.append((now, s.cpu.total))
        cpuSamples.removeAll { now - $0.time > Self.cpuWindow }
        cpuAverage = cpuSamples.map(\.value).reduce(0, +) / Double(cpuSamples.count)
        // Wait for most of a window of data before judging (e.g. right after launch).
        let enoughData = now - (cpuSamples.first?.time ?? now) >= Self.cpuWindow * 0.8
        let cpuWarning = settings.cpuWarning
        if !enoughData {
            state.cpu = .normal
        } else if cpuAverage >= 0.98 || (previous.cpu == .critical && cpuAverage >= 0.93) {
            state.cpu = .critical
        } else if cpuAverage >= cpuWarning || (previous.cpu >= .warning && cpuAverage >= cpuWarning - 0.1) {
            state.cpu = .warning
        } else {
            state.cpu = .normal
        }

        switch (s.memory.pressure, settings.memoryAlert) {
        case (.critical, _): state.memory = .critical
        case (.warning, .elevated): state.memory = .warning
        default: state.memory = .normal
        }

        if settings.alertNotifications { notifyChanges(s, settings: settings) }
    }

    // MARK: Notifications

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func sendTest() {
        post(id: "test", title: "Monitor alerts are on",
             body: "You'll get a notification when your Mac runs hot, the CPU stays busy, or memory runs low.", critical: false)
    }

    private func notifyChanges(_ s: Snapshot, settings: Settings) {
        let f = settings.fahrenheit
        let temp = Format.temperature(s.temps.cpuAvg, fahrenheit: f, unit: true)
        let throttling = s.thermalState == .serious || s.thermalState == .critical
        let cpu = Format.percent(cpuAverage)
        let memory = "\(Format.gigabytes(s.memory.used)) of \(Format.gigabytes(s.memory.total)) GB in use"

        notify("temperature", state.temperature) { critical in
            critical
                ? ("Your Mac is overheating", throttling
                    ? "CPU temperature is \(temp), and macOS is slowing the chip down to cool it."
                    : "CPU temperature is \(temp).")
                : ("Your Mac is running hot", "CPU temperature is \(temp).")
        }
        notify("cpu", state.cpu) { critical in
            (critical ? "CPU is maxed out" : "High CPU load",
             "CPU has averaged \(cpu) over the last 30 seconds. Activity Monitor shows which apps are using it.")
        }
        notify("memory", state.memory) { critical in
            critical
                ? ("Memory is almost full", "Memory pressure is critical (\(memory)). Your Mac may slow down until you quit some apps.")
                : ("Memory is running low", "Memory pressure is elevated (\(memory)). Quitting apps you aren't using will help.")
        }
    }

    /// Notifies when a metric gets worse: at most once per cooldown per metric, but always when it escalates to critical.
    private func notify(_ key: String, _ level: AlertLevel, message: (Bool) -> (title: String, body: String)) {
        let record = notified[key] ?? (.normal, .distantPast)
        guard level > record.level else {
            notified[key] = (level, record.time) // remember improvements so the next rise can notify again
            return
        }
        let escalation = record.level == .warning && level == .critical
        guard escalation || Date().timeIntervalSince(record.time) >= Self.notificationCooldown else {
            notified[key] = (level, record.time)
            return
        }
        notified[key] = (level, Date())
        let (title, body) = message(level == .critical)
        post(id: key, title: title, body: body, critical: level == .critical)
    }

    private func post(id: String, title: String, body: String, critical: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if critical { content.sound = .default }
        // Reusing the identifier replaces the previous notification for the same metric.
        let request = UNNotificationRequest(identifier: "monitor.\(id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.onOpen?() }
        completionHandler()
    }
}
