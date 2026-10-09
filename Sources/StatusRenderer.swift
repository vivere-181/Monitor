import AppKit

/// Renders the whole menu bar item as a single image, the way Apple's own extras work:
/// a monochrome template that macOS tints for any menu bar appearance. Only when a metric
/// is near its limit is the image drawn in color, so that metric can turn orange or red.
enum StatusRenderer {
    private enum Element {
        case symbol(String)
        case label(String)
        case text(String, reserve: String)
        case bar(Double)
        case ring(Double)
        case graph([Double])
    }

    /// A metric's elements, drawn in the alert color when there is one.
    private typealias Segment = (elements: [Element], color: NSColor?)

    private static let height: CGFloat = 22
    private static let elementGap: CGFloat = 3
    private static let segmentGap: CGFloat = 9
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private static let labelFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    private static var symbols: [String: NSImage] = [:]

    /// Returns the image plus a signature so callers can skip identical updates.
    static func render(monitor: Monitor, settings: Settings, alerts: AlertState) -> (image: NSImage, signature: String) {
        let s = monitor.snapshot
        let icons = settings.labelStyle == .icons
        let text = settings.labelStyle == .text
        let colors = settings.alertColors
        var segments: [Segment] = []
        var hiddenAlert = AlertLevel.normal

        if settings.showTemperature {
            let unit = settings.temperatureStyle == .withUnit
            let value = Format.temperature(s.temps.cpuAvg, fahrenheit: settings.fahrenheit, unit: unit)
            let reserve = (settings.fahrenheit ? "188°" : "88°") + (unit ? "C" : "")
            segments.append(((icons ? [.symbol("thermometer.medium")] : []) + [.text(value, reserve: reserve)],
                             colors ? alerts.temperature.color : nil))
        } else {
            hiddenAlert = max(hiddenAlert, alerts.temperature)
        }
        if settings.showCPU {
            segments.append(((icons ? [.symbol("cpu")] : text ? [.label("CPU")] : [])
                + [metric(s.cpu.total, history: monitor.cpuHistory, style: settings.cpuStyle)],
                colors ? alerts.cpu.color : nil))
        } else {
            hiddenAlert = max(hiddenAlert, alerts.cpu)
        }
        if settings.showGPU {
            segments.append(((icons ? [.symbol("cube")] : text ? [.label("GPU")] : [])
                + [metric(s.gpu.utilization, history: monitor.gpuHistory, style: settings.gpuStyle)], nil))
        }
        if settings.showMemory {
            segments.append(((icons ? [.symbol("memorychip")] : text ? [.label("MEM")] : [])
                + [metric(s.memory.fraction, history: monitor.memoryHistory, style: settings.memoryStyle)],
                colors ? alerts.memory.color : nil))
        } else {
            hiddenAlert = max(hiddenAlert, alerts.memory)
        }
        if segments.isEmpty { segments = [([.symbol("thermometer.medium")], nil)] }
        // A metric that's near its limit but not shown still gets a small warning sign.
        if colors, let color = hiddenAlert.color {
            segments.append(([.symbol("exclamationmark.triangle.fill")], color))
        }

        let template = segments.allSatisfy { $0.color == nil }
        let signature = "\(segments.map { "\($0.elements)|\($0.color.map(String.init(describing:)) ?? "-")" })"
        let widths = segments.map { $0.elements.map(width) }
        let total = widths.map { $0.reduce(0, +) + elementGap * CGFloat($0.count - 1) }.reduce(0, +)
            + segmentGap * CGFloat(segments.count - 1)

        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: true) { _ in
            var x: CGFloat = 0
            for (i, segment) in segments.enumerated() {
                if i > 0 { x += segmentGap }
                let base: NSColor = segment.color ?? (template ? .black : .labelColor)
                for (j, element) in segment.elements.enumerated() {
                    if j > 0 { x += elementGap }
                    draw(element, x: x, width: widths[i][j], base: base)
                    x += widths[i][j]
                }
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = accessibilityText(snapshot: s, settings: settings, alerts: alerts)
        return (image, signature)
    }

    private static func metric(_ value: Double, history: [Double], style: Settings.MetricStyle) -> Element {
        switch style {
        case .percentage: .text(Format.percent(value), reserve: "88%")
        case .bar: .bar(value)
        case .ring: .ring(value)
        case .graph: .graph(history)
        }
    }

    // MARK: Measuring & drawing

    private static func symbol(_ name: String) -> NSImage? {
        if let cached = symbols[name] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig)
        symbols[name] = image
        return image
    }

    private static func attributed(_ string: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    private static func width(_ element: Element) -> CGFloat {
        switch element {
        case .symbol(let name): symbol(name)?.size.width ?? 0
        case .label(let s): attributed(s, labelFont, .black).size().width
        case .text(let s, let reserve):
            max(attributed(s, valueFont, .black).size().width, attributed(reserve, valueFont, .black).size().width)
        case .bar: 24
        case .ring: 14
        case .graph: CGFloat(Monitor.miniHistoryLength) * 2
        }
    }

    private static func draw(_ element: Element, x: CGFloat, width: CGFloat, base: NSColor) {
        let midY = height / 2
        switch element {
        case .symbol(let name):
            guard let image = symbol(name) else { return }
            let rect = NSRect(x: x, y: midY - image.size.height / 2, width: image.size.width, height: image.size.height)
            tinted(image, base).draw(in: rect)

        case .label(let s):
            let a = attributed(s, labelFont, base.withAlphaComponent(0.6))
            a.draw(at: NSPoint(x: x, y: midY - a.size().height / 2))

        case .text(let s, _):
            let a = attributed(s, valueFont, base)
            // Right-align inside the reserved width so the item doesn't jiggle as digits change.
            a.draw(at: NSPoint(x: x + width - a.size().width, y: midY - a.size().height / 2))

        case .bar(let value):
            let outer = NSRect(x: x + 0.5, y: midY - 5, width: width - 1, height: 10)
            base.withAlphaComponent(0.45).setStroke()
            let outline = NSBezierPath(roundedRect: outer, xRadius: 3.5, yRadius: 3.5)
            outline.lineWidth = 1
            outline.stroke()
            let inner = outer.insetBy(dx: 2, dy: 2)
            base.setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: max(1.5, inner.width * clamp(value)), height: inner.height),
                         xRadius: 1.5, yRadius: 1.5).fill()

        case .ring(let value):
            let center = NSPoint(x: x + width / 2, y: midY)
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: 5.5, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.5
            base.withAlphaComponent(0.25).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: 5.5, startAngle: -90, endAngle: -90 + 360 * clamp(value), clockwise: false)
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            base.setStroke()
            if value > 0.005 { arc.stroke() }

        case .graph(let values):
            let area = NSRect(x: x, y: midY - 7, width: width, height: 14)
            base.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: area, xRadius: 2, yRadius: 2).fill()
            base.setFill()
            for (i, v) in values.reversed().enumerated() {
                let h = max(1, area.height * clamp(v))
                NSRect(x: area.maxX - CGFloat(i + 1) * 2, y: area.maxY - h, width: 1.5, height: h).fill()
            }
        }
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func clamp(_ v: Double) -> CGFloat { CGFloat(min(1, max(0, v))) }

    private static func accessibilityText(snapshot s: Snapshot, settings: Settings, alerts: AlertState) -> String {
        func flag(_ level: AlertLevel) -> String { level == .critical ? " (critical)" : level == .warning ? " (high)" : "" }
        var parts = ["Temperature \(Format.temperature(s.temps.cpuAvg, fahrenheit: settings.fahrenheit, unit: true))\(flag(alerts.temperature))"]
        parts.append("CPU \(Format.percent(s.cpu.total))\(flag(alerts.cpu))")
        if settings.showGPU { parts.append("GPU \(Format.percent(s.gpu.utilization))") }
        parts.append("Memory \(Format.percent(s.memory.fraction))\(flag(alerts.memory))")
        return parts.joined(separator: ", ")
    }
}
