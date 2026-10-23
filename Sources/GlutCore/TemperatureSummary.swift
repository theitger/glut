import Foundation

public enum TemperatureReading {
    public static func isPlausible(_ value: Double, group: SensorGroup) -> Bool {
        guard value.isFinite else { return false }
        // M2 core sensors can return single-digit sentinel readings when unavailable.
        return group == .cpu ? (10...120).contains(value) : (0...130).contains(value)
    }
}

public enum TemperatureSummary {
    public static func componentMean(_ group: SensorGroup, sensors: [Sensor]) -> Double? {
        let values = componentValues(group, sensors: sensors)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
    public static func componentPeak(_ group: SensorGroup, sensors: [Sensor]) -> Double? {
        componentValues(group, sensors: sensors).max()
    }
    private static func componentValues(_ group: SensorGroup, sensors: [Sensor]) -> [Double] {
        let mapped = sensors.filter { $0.group == group && $0.isKnown }
        let cores = mapped.filter { sensor in
            if group == .cpu { return sensor.name.localizedCaseInsensitiveContains("core") }
            if group == .gpu { return sensor.name.hasPrefix("GPU ") && sensor.name.dropFirst(4).first?.isNumber == true }
            return false
        }
        let candidates: [Sensor]
        if !cores.isEmpty { candidates = cores }
        else {
            // Use a consistent package/diode source, rather than mixing in heatsinks and proximity.
            let preferred = group == .cpu ? ["TCAD", "TC0D", "TC0P"] : ["TG0D", "TGDD", "TCGC", "TG0P"]
            if let sensor = preferred.compactMap({ key in mapped.first { $0.id == key } }).first { candidates = [sensor] }
            else { candidates = mapped }
        }
        return candidates.compactMap(\.celsius).filter { TemperatureReading.isPlausible($0, group: group) }
    }

    public static func rollingMean(_ group: SensorGroup, history: [Snapshot], window: TimeInterval = 10) -> Double? {
        guard window > 0, let latest = history.last,
              componentMean(group, sensors: latest.sensors) != nil else { return nil }
        let values = history.filter { $0.date > latest.date.addingTimeInterval(-window) && $0.date <= latest.date }
            .compactMap { componentMean(group, sensors: $0.sensors) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
