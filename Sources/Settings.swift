import Foundation

final class Settings {
    /// How a 0–100% metric is drawn in the menu bar.
    enum MetricStyle: Int, CaseIterable {
        case percentage, bar, ring, graph

        var title: String {
            switch self {
            case .percentage: "Percentage"
            case .bar: "Bar"
            case .ring: "Ring"
            case .graph: "Graph"
            }
        }
    }

    enum LabelStyle: Int, CaseIterable {
        case icons, text, none

        var title: String {
            switch self {
            case .icons: "Icons"
            case .text: "Text"
            case .none: "None"
            }
        }
    }

    enum TemperatureStyle: Int, CaseIterable {
        case degrees, withUnit

        var title: String {
            switch self {
            case .degrees: "48°"
            case .withUnit: "48°C"
            }
        }
    }

    /// When memory counts as "near the limit". Based on macOS memory pressure, not % used,
    /// because macOS compresses memory and a high "used" figure is often fine.
    enum MemoryAlert: Int, CaseIterable {
        case elevated, critical

        var title: String {
            switch self {
            case .elevated: "Elevated pressure"
            case .critical: "Critical pressure"
            }
        }
    }

    static let temperatureThresholds: [Double] = [70, 75, 80, 85, 90]
    static let cpuThresholds: [Double] = [0.7, 0.8, 0.9, 0.95]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "showTemperature": true,
            "showCPU": false,
            "showMemory": false,
            "showGPU": false,
            "fahrenheit": false,
            "interval": 2.0,
            "dashboardOpen": true,
            "alertColors": true,
            "alertNotifications": false,
            "temperatureWarning": 85.0,
            "cpuWarning": 0.9,
        ])
        // Migrate the single "menu bar shows" option from 1.0.
        if let old = defaults.object(forKey: "barMode") as? Int {
            showCPU = old >= 1
            showMemory = old >= 2
            defaults.removeObject(forKey: "barMode")
        }
    }

    var showTemperature: Bool {
        get { defaults.bool(forKey: "showTemperature") }
        set { defaults.set(newValue, forKey: "showTemperature") }
    }

    var showCPU: Bool {
        get { defaults.bool(forKey: "showCPU") }
        set { defaults.set(newValue, forKey: "showCPU") }
    }

    var showMemory: Bool {
        get { defaults.bool(forKey: "showMemory") }
        set { defaults.set(newValue, forKey: "showMemory") }
    }

    var showGPU: Bool {
        get { defaults.bool(forKey: "showGPU") }
        set { defaults.set(newValue, forKey: "showGPU") }
    }

    var gpuStyle: MetricStyle {
        get { MetricStyle(rawValue: defaults.integer(forKey: "gpuStyle")) ?? .percentage }
        set { defaults.set(newValue.rawValue, forKey: "gpuStyle") }
    }

    var temperatureStyle: TemperatureStyle {
        get { TemperatureStyle(rawValue: defaults.integer(forKey: "temperatureStyle")) ?? .degrees }
        set { defaults.set(newValue.rawValue, forKey: "temperatureStyle") }
    }

    var cpuStyle: MetricStyle {
        get { MetricStyle(rawValue: defaults.integer(forKey: "cpuStyle")) ?? .percentage }
        set { defaults.set(newValue.rawValue, forKey: "cpuStyle") }
    }

    var memoryStyle: MetricStyle {
        get { MetricStyle(rawValue: defaults.integer(forKey: "memoryStyle")) ?? .percentage }
        set { defaults.set(newValue.rawValue, forKey: "memoryStyle") }
    }

    var labelStyle: LabelStyle {
        get { LabelStyle(rawValue: defaults.integer(forKey: "labelStyle")) ?? .icons }
        set { defaults.set(newValue.rawValue, forKey: "labelStyle") }
    }

    var alertColors: Bool {
        get { defaults.bool(forKey: "alertColors") }
        set { defaults.set(newValue, forKey: "alertColors") }
    }

    var alertNotifications: Bool {
        get { defaults.bool(forKey: "alertNotifications") }
        set { defaults.set(newValue, forKey: "alertNotifications") }
    }

    /// °C at which the temperature turns orange.
    var temperatureWarning: Double {
        get { defaults.double(forKey: "temperatureWarning") }
        set { defaults.set(newValue, forKey: "temperatureWarning") }
    }

    /// 0...1 sustained CPU usage at which CPU turns orange.
    var cpuWarning: Double {
        get { defaults.double(forKey: "cpuWarning") }
        set { defaults.set(newValue, forKey: "cpuWarning") }
    }

    var memoryAlert: MemoryAlert {
        get { MemoryAlert(rawValue: defaults.integer(forKey: "memoryAlert")) ?? .elevated }
        set { defaults.set(newValue.rawValue, forKey: "memoryAlert") }
    }

    var fahrenheit: Bool {
        get { defaults.bool(forKey: "fahrenheit") }
        set { defaults.set(newValue, forKey: "fahrenheit") }
    }

    var interval: TimeInterval {
        get { max(1, defaults.double(forKey: "interval")) }
        set { defaults.set(newValue, forKey: "interval") }
    }

    var dashboardOpen: Bool {
        get { defaults.bool(forKey: "dashboardOpen") }
        set { defaults.set(newValue, forKey: "dashboardOpen") }
    }
}

enum Format {
    static func temperature(_ celsius: Double?, fahrenheit: Bool, unit: Bool = false) -> String {
        guard let celsius else { return "--°" }
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))°" + (unit ? (fahrenheit ? "F" : "C") : "")
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func gigabytes(_ bytes: Double) -> String {
        String(format: "%.1f", bytes / 1_073_741_824)
    }
}
