import Foundation
import IOKit

// MARK: - Temperatures (IOHID)

struct Temperatures {
    var cpuAvg: Double?     // average of SoC/CPU die sensors
    var cpuMax: Double?     // hottest die sensor
    var gpu: Double?
    var ssd: Double?
    var battery: Double?
}

/// Reads Apple Silicon thermal sensors through the HID event system.
/// The service list is resolved once; each sample is just one cheap event copy per sensor.
final class ThermalSensors {
    enum Kind { case cpu, gpu, ssd, battery }

    private static let eventTypeTemperature: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    private let client: IOHIDEventSystemClient?
    private var sensors: [(service: IOHIDServiceClient, kind: Kind)] = []

    init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        guard let client else { return }
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        // The same physical sensor is published by several HID services (e.g. 3× "PMU tdie4").
        // Each read is an IPC round-trip to hidd (~0.8 ms), so keep one service per sensor name.
        var seen = Set<String>()
        for service in services {
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String,
                  let kind = Self.classify(name), seen.insert(name).inserted else { continue }
            sensors.append((service, kind))
        }
    }

    var kinds: Set<Kind> { Set(sensors.map(\.kind)) }

    /// Maps sensor names across chip generations, e.g. M1 "pACC MTR Temp Sensor2",
    /// "GPU MTR Temp Sensor1", M2+ "PMU tdie4", plus "NAND CH0 temp" and "gas gauge battery".
    private static func classify(_ name: String) -> Kind? {
        let n = name.lowercased()
        if n.contains("battery") { return .battery }
        if n.contains("nand") { return .ssd }
        if n.contains("gpu") { return .gpu }
        if n.contains("tdie") || n.contains("acc mtr") || n.contains("soc mtr") || n.contains("soc die") { return .cpu }
        return nil
    }

    func read() -> Temperatures {
        var cpuSum = 0.0, cpuCount = 0.0
        var result = Temperatures()
        for (service, kind) in sensors {
            guard let event = IOHIDServiceClientCopyEvent(service, Self.eventTypeTemperature, 0, 0) else { continue }
            let value = IOHIDEventGetFloatValue(event, Self.temperatureField)
            // Unpopulated sensors report large negative sentinels; ignore anything implausible.
            guard value > 1, value < 150 else { continue }
            switch kind {
            case .cpu:
                cpuSum += value; cpuCount += 1
                result.cpuMax = max(result.cpuMax ?? value, value)
            case .gpu: result.gpu = max(result.gpu ?? value, value)
            case .ssd: result.ssd = max(result.ssd ?? value, value)
            case .battery: result.battery = max(result.battery ?? value, value)
            }
        }
        if cpuCount > 0 { result.cpuAvg = cpuSum / cpuCount }
        return result
    }
}

// MARK: - Fans (AppleSMC)

struct Fan {
    var rpm: Double
    var maxRPM: Double
}

final class SMC {
    private var connection: io_connect_t = 0
    private var keyInfo: [UInt32: (size: UInt32, type: UInt32)] = [:]
    private var fanMax: [Double] = []
    private var gpuKeys: [String] = []

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
        let count = Int(number("FNum") ?? 0)
        fanMax = (0..<count).map { number("F\($0)Mx") ?? 0 }
        gpuKeys = discoverGPUKeys()
    }

    deinit { IOServiceClose(connection) }

    var fanCount: Int { fanMax.count }

    func fans() -> [Fan] {
        fanMax.enumerated().compactMap { i, maxRPM in
            number("F\(i)Ac").map { Fan(rpm: max(0, $0), maxRPM: maxRPM) }
        }
    }

    var hasGPUTemperature: Bool { !gpuKeys.isEmpty }

    /// Average and hottest of the GPU die sensors.
    func gpuTemperature() -> (average: Double, hottest: Double)? {
        let values = gpuKeys.compactMap(number).filter { $0 > 1 && $0 < 150 }
        guard let hottest = values.max() else { return nil }
        return (values.reduce(0, +) / Double(values.count), hottest)
    }

    /// Apple Silicon names GPU die sensors `Tg0x`/`Tg1x`; which ones exist varies by chip, so probe once.
    /// (Checked on an M4 Pro: these climb from ~42 to ~75 °C under a GPU-only load while CPU sensors barely move.)
    private func discoverGPUKeys() -> [String] {
        let suffixes = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        let float = Self.fourCC("flt ")
        return ["Tg0", "Tg1"].flatMap { prefix in suffixes.map { prefix + String($0) } }.filter { key in
            guard info(for: key)?.type == float, let value = number(key) else { return false }
            return value > 1 && value < 150
        }
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let status = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParamStruct>.stride, &output, &outputSize)
        return status == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private func info(for key: String) -> (size: UInt32, type: UInt32)? {
        let code = Self.fourCC(key)
        if let cached = keyInfo[code] { return cached }
        var input = SMCParamStruct()
        input.key = code
        input.data8 = 9 // kSMCGetKeyInfo
        guard let out = call(&input) else { return nil }
        keyInfo[code] = (out.keyInfo.dataSize, out.keyInfo.dataType)
        return keyInfo[code]
    }

    private func read(_ key: String) -> (type: UInt32, bytes: [UInt8])? {
        let code = Self.fourCC(key)
        guard let info = info(for: key) else { return nil }
        var input = SMCParamStruct()
        input.key = code
        input.keyInfo.dataSize = info.size
        input.data8 = 5 // kSMCReadKey
        guard let out = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(min(info.size, 32)))) }
        return (info.type, bytes)
    }

    private func number(_ key: String) -> Double? {
        guard let (type, b) = read(key), !b.isEmpty else { return nil }
        switch type {
        case Self.fourCC("flt ") where b.count >= 4:
            return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        case Self.fourCC("fpe2") where b.count >= 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case Self.fourCC("ui8 "):
            return Double(b[0])
        case Self.fourCC("ui16") where b.count >= 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case Self.fourCC("ui32") where b.count >= 4:
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default:
            return nil
        }
    }
}

// MARK: - GPU (IOAccelerator)

struct GPUUsage {
    var utilization: Double = 0      // 0...1, "Device Utilization %"
    var memoryInUse: Double = 0      // bytes of unified memory the GPU is using
    var temperature: Double?         // average die temperature, °C
    var hottest: Double?
}

/// Reads the GPU driver's own counters from the IORegistry (the numbers Activity Monitor's GPU History uses).
/// One property read per sample, about 0.02 ms.
final class GPUStats {
    private let service: io_service_t
    let coreCount: Int

    init() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        coreCount = service == 0 ? 0
            : (IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, nil, 0)?.takeRetainedValue() as? Int ?? 0)
    }

    deinit { if service != 0 { IOObjectRelease(service) } }

    func sample() -> GPUUsage {
        var usage = GPUUsage()
        guard service != 0,
              let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, nil, 0)?
                  .takeRetainedValue() as? [String: Any] else { return usage }
        usage.utilization = Double(stats["Device Utilization %"] as? Int ?? 0) / 100
        usage.memoryInUse = Double(stats["In use system memory"] as? Int ?? 0)
        return usage
    }
}
