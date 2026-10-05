import Foundation

// MARK: - CPU

struct CPUUsage {
    var total: Double = 0          // 0...1
    var perCore: [Double] = []     // 0...1, efficiency cores first
    var efficiencyCores = 0
}

final class CPUStats {
    private var previous: [UInt32] = []
    let efficiencyCores: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // perflevel1 is the efficiency cluster; Apple Silicon numbers E-cores first.
        return sysctlbyname("hw.perflevel1.logicalcpu", &value, &size, nil, 0) == 0 ? Int(value) : 0
    }()

    func sample() -> CPUUsage {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return CPUUsage(efficiencyCores: efficiencyCores) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }

        let current = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { previous = current }
        guard previous.count == current.count else { return CPUUsage(efficiencyCores: efficiencyCores) }

        let states = Int(CPU_STATE_MAX)
        var perCore: [Double] = []
        perCore.reserveCapacity(Int(cpuCount))
        var busyAll = 0.0, totalAll = 0.0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * states
            func delta(_ state: Int32) -> Double { Double(current[base + Int(state)] &- previous[base + Int(state)]) }
            let busy = delta(CPU_STATE_USER) + delta(CPU_STATE_SYSTEM) + delta(CPU_STATE_NICE)
            let total = busy + delta(CPU_STATE_IDLE)
            perCore.append(total > 0 ? busy / total : 0)
            busyAll += busy; totalAll += total
        }
        return CPUUsage(total: totalAll > 0 ? busyAll / totalAll : 0, perCore: perCore, efficiencyCores: efficiencyCores)
    }
}

// MARK: - Memory

enum MemoryPressure: Int {
    case normal = 1, warning = 2, critical = 4
}

struct MemoryUsage {
    var total: Double = Double(ProcessInfo.processInfo.physicalMemory)
    var app: Double = 0
    var wired: Double = 0
    var compressed: Double = 0
    var pressure: MemoryPressure = .normal
    var swapUsed: Double = 0

    var used: Double { app + wired + compressed }
    var fraction: Double { total > 0 ? min(1, used / total) : 0 }
}

enum MemoryStats {
    /// Matches Activity Monitor's "Memory Used" (App + Wired + Compressed).
    static func sample(includeDetails: Bool) -> MemoryUsage {
        var usage = MemoryUsage()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            usage.app = Double(stats.internal_page_count &- stats.purgeable_count) * page
            usage.wired = Double(stats.wire_count) * page
            usage.compressed = Double(stats.compressor_page_count) * page
        }
        // Pressure drives alerts, so it's read every sample (one sysctl).
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            usage.pressure = MemoryPressure(rawValue: Int(level)) ?? .normal
        }
        guard includeDetails else { return usage }

        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            usage.swapUsed = Double(swap.xsu_used)
        }
        return usage
    }
}

// MARK: - Monitor model

struct Snapshot {
    var temps = Temperatures()
    var cpu = CPUUsage()
    var memory = MemoryUsage()
    var fans: [Fan] = []
    var load: [Double] = [0, 0, 0]
    var thermalState: ProcessInfo.ThermalState = .nominal
}

/// Owns the single sampling timer. Expensive-ish extras (fans, swap, load)
/// are only read while a detail view is actually on screen.
/// Sensor reads block on IPC to hidd/SMC, so they run on a background queue and
/// results are published back on the main thread.
final class Monitor {
    static let historyLength = 90
    static let miniHistoryLength = 14

    private(set) var snapshot = Snapshot()
    private(set) var history: [Double] = []         // CPU temperature, °C
    private(set) var cpuHistory: [Double] = []      // 0...1, for the menu bar graph style
    private(set) var memoryHistory: [Double] = []   // 0...1

    /// Fixed at launch, so layouts don't jump around between samples.
    let sensorKinds: Set<ThermalSensors.Kind>
    let fanCount: Int

    // Only touched on `queue`.
    private let thermal = ThermalSensors()
    private let cpuStats = CPUStats()
    private let smc = SMC()

    private let queue = DispatchQueue(label: "monitor.sampling", qos: .utility)
    private var sampling = false
    private var timer: Timer?

    init() {
        sensorKinds = thermal.kinds
        fanCount = smc?.fanCount ?? 0
    }

    var onUpdate: (() -> Void)?

    var interval: TimeInterval = 2 {
        didSet { if interval != oldValue { schedule() } }
    }

    var detailVisible = false {
        didSet { if detailVisible && !oldValue { tick() } }
    }

    func start() {
        queue.async { [cpuStats] in _ = cpuStats.sample() } // prime the CPU tick counters
        tick()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = interval * 0.25 // let the system coalesce wakeups
        RunLoop.main.add(timer, forMode: .common) // keep ticking while the menu is open
        self.timer = timer
    }

    func tick() {
        guard !sampling else { return }
        sampling = true
        let detail = detailVisible
        let previous = snapshot
        queue.async { [self] in
            let next = sample(from: previous, detail: detail)
            DispatchQueue.main.async { [self] in
                sampling = false
                publish(next)
            }
        }
    }

    /// Synchronous variant for one-off use (e.g. `--render`).
    func tickNow() {
        let detail = detailVisible
        let previous = snapshot
        publish(queue.sync { sample(from: previous, detail: detail) })
    }

    private func sample(from previous: Snapshot, detail: Bool) -> Snapshot {
        var s = previous
        s.temps = thermal.read()
        s.cpu = cpuStats.sample()
        s.memory = MemoryStats.sample(includeDetails: detail)
        s.thermalState = ProcessInfo.processInfo.thermalState
        if detail {
            s.fans = smc?.fans() ?? []
            var load = [0.0, 0.0, 0.0]
            if getloadavg(&load, 3) == 3 { s.load = load }
        }
        return s
    }

    private func publish(_ next: Snapshot) {
        snapshot = next
        if let t = next.temps.cpuAvg { Self.append(t, to: &history, limit: Self.historyLength) }
        Self.append(next.cpu.total, to: &cpuHistory, limit: Self.miniHistoryLength)
        Self.append(next.memory.fraction, to: &memoryHistory, limit: Self.miniHistoryLength)
        onUpdate?()
    }

    private static func append(_ value: Double, to buffer: inout [Double], limit: Int) {
        if buffer.count >= limit { buffer.removeFirst() }
        buffer.append(value)
    }
}
