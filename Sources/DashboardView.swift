import AppKit

enum Heat {
    static func color(_ celsius: Double?) -> NSColor {
        guard let c = celsius else { return .secondaryLabelColor }
        switch c {
        case ..<60: return .systemGreen
        case ..<80: return .systemYellow
        case ..<95: return .systemOrange
        default: return .systemRed
        }
    }

    static func thermalState(_ state: ProcessInfo.ThermalState) -> (String, NSColor) {
        switch state {
        case .nominal: return ("Normal", .secondaryLabelColor)
        case .fair: return ("Fair", .systemYellow)
        case .serious: return ("Throttling", .systemOrange)
        case .critical: return ("Critical", .systemRed)
        @unknown default: return ("Unknown", .secondaryLabelColor)
        }
    }
}

/// Laid out like Apple's own menu bar extras (Battery, Wi‑Fi): bold section headers with the
/// value on the right, circular glyph rows, separators between sections.
/// Drawn in a single pass with no subviews or layers, so it stays cheap in the menu and the window.
final class DashboardView: NSView {
    private enum Row { case ssd, battery, fans, hottest }

    private unowned let monitor: Monitor
    private unowned let settings: Settings
    private unowned let alerts: Alerts
    private let topInset: CGFloat
    private let rows: [Row]

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(monitor: Monitor, settings: Settings, alerts: Alerts, width: CGFloat, topInset: CGFloat = 0) {
        self.monitor = monitor
        self.settings = settings
        self.alerts = alerts
        self.topInset = topInset
        var rows: [Row] = []
        if monitor.sensorKinds.contains(.ssd) { rows.append(.ssd) }
        if monitor.sensorKinds.contains(.battery) { rows.append(.battery) }
        if monitor.fanCount > 0 { rows.append(.fans) }
        self.rows = rows.isEmpty ? [.hottest] : rows
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: topInset + Self.baseHeight + Self.rowHeight * CGFloat(self.rows.count)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Metrics (kept in one place so the frame height matches what draw() uses)

    private static let pad: CGFloat = 14
    private static let rowHeight: CGFloat = 32
    private static let graphHeight: CGFloat = 50
    private static let sectionHeight: CGFloat = 24 + 22 + 8 + 14 + 6 + 13 // header, bars/graph, caption, separator
    private static let baseHeight: CGFloat = 12 + 19 + 25 + graphHeight + 10 + 6 + 13 // temperature
        + sectionHeight * 2 // CPU, GPU
        + 24 + 6 + 10 + 14 + 4 + 14 + 12 // memory

    private static let title = NSFont.systemFont(ofSize: 13, weight: .bold)
    private static let titleValue = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private static let body = NSFont.systemFont(ofSize: 13)
    private static let bodyValue = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private static let small = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let glyphConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    private static var glyphs: [String: NSImage] = [:]

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let s = monitor.snapshot
        let f = settings.fahrenheit
        let pad = Self.pad
        let width = bounds.width - pad * 2
        let right = bounds.width - pad
        var y = topInset + 12

        // Temperature
        // Past the user's warning threshold, use the alert color so the dashboard agrees with the menu bar.
        let heat = alerts.state.temperature.color ?? Heat.color(s.temps.cpuAvg)
        text("Temperature", Self.title, .labelColor, x: pad, y: y)
        text(Format.temperature(s.temps.cpuAvg, fahrenheit: f, unit: true), Self.titleValue, heat, x: right, y: y, alignRight: true)
        y += 19
        let (state, stateColor) = Heat.thermalState(s.thermalState)
        let w = text("Thermal state: ", Self.small, .secondaryLabelColor, x: pad, y: y)
        text(state, Self.small, stateColor, x: pad + w, y: y)
        text("Hottest \(Format.temperature(s.temps.cpuMax, fahrenheit: f))", Self.small, .secondaryLabelColor, x: right, y: y, alignRight: true)
        y += 25

        sparkline(NSRect(x: pad, y: y, width: width, height: Self.graphHeight), color: heat)
        y += Self.graphHeight + 10

        for row in rows {
            sensorRow(row, snapshot: s, y: y)
            y += Self.rowHeight
        }
        y += 6
        separator(y: y)
        y += 13

        // CPU
        text("CPU", Self.title, .labelColor, x: pad, y: y)
        text(Format.percent(s.cpu.total), Self.titleValue, alerts.state.cpu.color ?? .secondaryLabelColor, x: right, y: y, alignRight: true)
        y += 24
        coreBars(NSRect(x: pad, y: y, width: width, height: 22), cpu: s.cpu)
        y += 22 + 8
        let cores = s.cpu.perCore.count, e = s.cpu.efficiencyCores
        text(e > 0 ? "\(cores - e) Performance · \(e) Efficiency" : "\(cores) Cores", Self.small, .secondaryLabelColor, x: pad, y: y)
        text(String(format: "Load %.2f  %.2f  %.2f", s.load[0], s.load[1], s.load[2]), Self.small, .secondaryLabelColor, x: right, y: y, alignRight: true)
        y += 14 + 6
        separator(y: y)
        y += 13

        // GPU
        text("GPU", Self.title, .labelColor, x: pad, y: y)
        text(Format.percent(s.gpu.utilization), Self.titleValue, .secondaryLabelColor, x: right, y: y, alignRight: true)
        y += 24
        usageGraph(NSRect(x: pad, y: y, width: width, height: 22), values: monitor.gpuLongHistory, color: .systemIndigo)
        y += 22 + 8
        let gpuCores = monitor.gpuCoreCount > 0 ? "\(monitor.gpuCoreCount) Cores · " : ""
        text("\(gpuCores)\(Format.gigabytes(s.gpu.memoryInUse)) GB memory", Self.small, .secondaryLabelColor, x: pad, y: y)
        if monitor.hasGPUTemperature {
            let value = Format.temperature(s.gpu.temperature, fahrenheit: f)
            let vw = text(value, Self.small, Heat.color(s.gpu.temperature), x: right, y: y, alignRight: true)
            text("Temperature ", Self.small, .secondaryLabelColor, x: right - vw, y: y, alignRight: true)
        }
        y += 14 + 6
        separator(y: y)
        y += 13

        // Memory
        let m = s.memory
        text("Memory", Self.title, .labelColor, x: pad, y: y)
        text("\(Format.gigabytes(m.used)) of \(Format.gigabytes(m.total)) GB", Self.titleValue, alerts.state.memory.color ?? .secondaryLabelColor, x: right, y: y, alignRight: true)
        y += 24
        bar(NSRect(x: pad, y: y, width: width, height: 6),
            segments: [(m.app / m.total, .systemBlue), (m.wired / m.total, .systemOrange), (m.compressed / m.total, .systemPurple)])
        y += 6 + 10
        var x = pad
        for (label, value, color) in [("App", m.app, NSColor.systemBlue), ("Wired", m.wired, .systemOrange), ("Compressed", m.compressed, .systemPurple)] {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y + 4, width: 7, height: 7)).fill()
            x += 11
            x += text("\(label) \(Format.gigabytes(value))", Self.small, .secondaryLabelColor, x: x, y: y) + 12
        }
        y += 14 + 4
        let (pressure, pressureColor): (String, NSColor) = switch m.pressure {
        case .normal: ("Normal", .secondaryLabelColor)
        case .warning: ("Elevated", .systemOrange)
        case .critical: ("Critical", .systemRed)
        }
        let pw = text("Pressure: ", Self.small, .secondaryLabelColor, x: pad, y: y)
        text(pressure, Self.small, pressureColor, x: pad + pw, y: y)
        text("Swap \(Format.gigabytes(m.swapUsed)) GB", Self.small, .secondaryLabelColor, x: right, y: y, alignRight: true)
    }

    private func sensorRow(_ row: Row, snapshot s: Snapshot, y: CGFloat) {
        let f = settings.fahrenheit
        let symbol: String, title: String, value: String, circle: NSColor
        var glyphColor = NSColor.white
        switch row {
        case .ssd:
            (symbol, title, value, circle) = ("internaldrive", "SSD", Format.temperature(s.temps.ssd, fahrenheit: f), Heat.color(s.temps.ssd))
        case .battery:
            (symbol, title, value, circle) = ("battery.75percent", "Battery", Format.temperature(s.temps.battery, fahrenheit: f), Heat.color(s.temps.battery))
        case .hottest:
            (symbol, title, value, circle) = ("thermometer.high", "Hottest Sensor", Format.temperature(s.temps.cpuMax, fahrenheit: f), Heat.color(s.temps.cpuMax))
        case .fans:
            let rpm = s.fans.isEmpty ? nil : s.fans.map(\.rpm).reduce(0, +) / Double(s.fans.count)
            let spinning = (rpm ?? 0) >= 1
            symbol = "fan"
            title = monitor.fanCount > 1 ? "Fans" : "Fan"
            value = rpm.map { $0 < 1 ? "Off" : "\(Int($0)) rpm" } ?? "—"
            circle = spinning ? .controlAccentColor : .labelColor.withAlphaComponent(0.12)
            if !spinning { glyphColor = .secondaryLabelColor }
        }
        let pad = Self.pad
        let circleRect = NSRect(x: pad, y: y + 3, width: 26, height: 26)
        circle.setFill()
        NSBezierPath(ovalIn: circleRect).fill()
        if let glyph = glyph(symbol, glyphColor) {
            glyph.draw(in: NSRect(x: circleRect.midX - glyph.size.width / 2, y: circleRect.midY - glyph.size.height / 2,
                                  width: glyph.size.width, height: glyph.size.height))
        }
        text(title, Self.body, .labelColor, x: pad + 36, y: y + 7)
        text(value, Self.bodyValue, .secondaryLabelColor, x: bounds.width - pad, y: y + 7, alignRight: true)
    }

    // MARK: Primitives

    @discardableResult
    private func text(_ string: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat, alignRight: Bool = false) -> CGFloat {
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: alignRight ? x - size.width : x, y: y))
        return size.width
    }

    private func glyph(_ name: String, _ color: NSColor) -> NSImage? {
        let key = "\(name)|\(color)"
        if let cached = Self.glyphs[key] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(Self.glyphConfig.applying(.init(paletteColors: [color])))
        Self.glyphs[key] = image
        return image
    }

    private func separator(y: CGFloat) {
        NSColor.separatorColor.setFill()
        NSRect(x: Self.pad, y: y, width: bounds.width - Self.pad * 2, height: 1).fill()
    }

    private func bar(_ rect: NSRect, segments: [(Double, NSColor)]) {
        let track = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        track.fill()
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        var x = rect.minX
        for (fraction, color) in segments {
            let w = rect.width * CGFloat(min(1, max(0, fraction)))
            color.setFill()
            NSRect(x: x, y: rect.minY, width: w, height: rect.height).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func coreBars(_ rect: NSRect, cpu: CPUUsage) {
        let n = cpu.perCore.count
        guard n > 0 else { return }
        let gap: CGFloat = 3
        let clusterGap: CGFloat = cpu.efficiencyCores > 0 && cpu.efficiencyCores < n ? 6 : 0
        let barWidth = (rect.width - gap * CGFloat(n - 1) - clusterGap) / CGFloat(n)
        // Performance cores first (left), matching the caption below.
        let order = Array(cpu.efficiencyCores..<n) + Array(0..<cpu.efficiencyCores)
        var x = rect.minX
        for (position, core) in order.enumerated() {
            if position == n - cpu.efficiencyCores && clusterGap > 0 { x += clusterGap }
            let column = NSRect(x: x, y: rect.minY, width: barWidth, height: rect.height)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: column, xRadius: 2.5, yRadius: 2.5).fill()
            let h = max(2, rect.height * CGFloat(cpu.perCore[core]))
            (core < cpu.efficiencyCores ? NSColor.systemTeal : NSColor.systemBlue).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: column.maxY - h, width: barWidth, height: h), xRadius: 2.5, yRadius: 2.5).fill()
            x += barWidth + gap
        }
    }

    /// Filled 0–100% history, newest on the right, on the same rounded track as the core bars.
    private func usageGraph(_ rect: NSRect, values: [Double], color: NSColor) {
        let track = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        track.fill()
        guard values.count >= 2 else { return }
        let step = rect.width / CGFloat(Monitor.historyLength - 1)
        let startX = rect.maxX - step * CGFloat(values.count - 1)
        let line = NSBezierPath()
        for (i, v) in values.enumerated() {
            let p = NSPoint(x: startX + step * CGFloat(i), y: rect.maxY - 1 - (rect.height - 2) * CGFloat(min(1, max(0, v))))
            i == 0 ? line.move(to: p) : line.line(to: p)
        }
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        fill.line(to: NSPoint(x: startX, y: rect.maxY))
        fill.close()
        color.withAlphaComponent(0.3).setFill()
        fill.fill()
        color.setStroke()
        line.lineWidth = 1.25
        line.lineJoinStyle = .round
        line.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func sparkline(_ rect: NSRect, color: NSColor) {
        let values = monitor.history
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        guard values.count >= 2, let lo0 = values.min(), let hi0 = values.max() else { return }
        let mid = (lo0 + hi0) / 2
        let span = max(hi0 - lo0 + 4, 10) // at least a 10° window so idle noise stays flat
        let lo = mid - span / 2
        let inner = rect.insetBy(dx: 2, dy: 6)
        let step = inner.width / CGFloat(Monitor.historyLength - 1)
        let startX = inner.maxX - step * CGFloat(values.count - 1)
        let line = NSBezierPath()
        for (i, v) in values.enumerated() {
            let p = NSPoint(x: startX + step * CGFloat(i), y: inner.maxY - inner.height * CGFloat((v - lo) / span))
            i == 0 ? line.move(to: p) : line.line(to: p)
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).addClip()
        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: inner.maxX, y: rect.maxY))
        fill.line(to: NSPoint(x: startX, y: rect.maxY))
        fill.close()
        color.withAlphaComponent(0.15).setFill()
        fill.fill()
        NSGraphicsContext.restoreGraphicsState()
        color.setStroke()
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        line.stroke()
    }
}
