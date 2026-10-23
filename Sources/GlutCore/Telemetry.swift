import Foundation
import IOKit

public enum Machine {
    public static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "Unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "Unknown" }
        return String(cString: bytes)
    }
    public static var chip: String { sysctl("machdep.cpu.brand_string") }
    public static var model: String { sysctl("hw.model") }
    public static func battery() -> [String: String] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        if let cycles = values["CycleCount"] as? Int { result["Cycle count"] = String(cycles) }
        if let capacity = values["AppleRawMaxCapacity"] as? Double,
           let design = values["DesignCapacity"] as? Double, design > 0 {
            result["Maximum capacity"] = String(format: "%.0f%%", min(100, capacity / design * 100))
        }
        if let charging = values["IsCharging"] as? Bool { result["Charging"] = charging ? "Yes" : "No" }
        if let level = values["CurrentCapacity"] as? Int { result["Charge"] = "\(level)%" }
        return result
    }
    public static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

public struct Snapshot: Codable {
    public var date: Date
    public var sensors: [Sensor]
    public var fans: [Fan]
    public var thermalState: String
    public var battery: [String: String]
}

public final class Telemetry {
    private let smc: SMC
    private var sensors: [Sensor] = []
    public init() throws {
        smc = try SMC()
        let chip = Machine.chip
        sensors = try smc.keys().filter { $0.hasPrefix("T") }.compactMap { key in
            guard let value = try? smc.read(key),
                  value.type == "flt " || value.type.hasPrefix("sp") || value.type.hasPrefix("fp"),
                  let number = value.number, (0...130).contains(number) else { return nil }
            let (name, group) = SensorCatalog.describe(key, chip: chip)
            return Sensor(key: key, name: name, group: group,
                          celsius: TemperatureReading.isPlausible(number, group: group) ? number : nil)
        }.sorted { ($0.group.rawValue, $0.name, $0.id) < ($1.group.rawValue, $1.name, $1.id) }
        guard !sensors.isEmpty else { throw GlutError.message("No readable temperature sensors found. This Mac may need additional sensor support.") }
    }
    public func resetMaximums() { for i in sensors.indices { sensors[i].maximum = nil } }
    public func sample() -> Snapshot {
        for i in sensors.indices {
            let value = smc.number(sensors[i].id)
            sensors[i].celsius = value.flatMap { TemperatureReading.isPlausible($0, group: sensors[i].group) ? $0 : nil }
            if let current = sensors[i].celsius { sensors[i].maximum = max(sensors[i].maximum ?? current, current) }
        }
        return Snapshot(date: Date(), sensors: sensors, fans: smc.fans(), thermalState: Machine.thermalState, battery: Machine.battery())
    }
}
