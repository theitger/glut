import Foundation

public enum SensorGroup: String, CaseIterable, Codable {
    case cpu = "CPU", gpu = "GPU", battery = "Battery", memory = "Memory"
    case storage = "Storage", system = "System", other = "Other"
}

public struct Sensor: Identifiable, Codable {
    public var isKnown: Bool { !name.hasPrefix("Sensor ") && !name.contains(" · ") }
    public var id: String
    public var name: String
    public var group: SensorGroup
    public var celsius: Double?
    public var maximum: Double?
    public init(key: String, name: String, group: SensorGroup, celsius: Double?) {
        self.id = key; self.name = name; self.group = group
        self.celsius = celsius; self.maximum = celsius
    }
}

public struct Fan: Identifiable, Codable {
    public var id: Int
    public var name: String
    public var actual: Double?
    public var minimum: Double?
    public var maximum: Double?
    public var target: Double?
    public var forced: Bool?
    public init(id: Int, name: String, actual: Double?, minimum: Double?, maximum: Double?, target: Double?, forced: Bool?) {
        self.id = id; self.name = name; self.actual = actual
        self.minimum = minimum; self.maximum = maximum; self.target = target; self.forced = forced
    }
}

public enum ControlMode: String, Codable, CaseIterable {
    case system = "System", manual = "Manual", automatic = "Auto Boost", max = "Max"
}

public struct BoostRule: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var sensor: String
    public var threshold: Double
    public var percent: Double
    public var enabled: Bool
    public init(sensor: String, threshold: Double = 75, percent: Double = 75, enabled: Bool = true) {
        self.sensor = sensor; self.threshold = threshold; self.percent = percent; self.enabled = enabled
    }
}

public struct FanRequest: Codable {
    public var mode: ControlMode
    public var percent: Double
    public var rules: [BoostRule]
    public init(mode: ControlMode, percent: Double = 70, rules: [BoostRule] = []) {
        self.mode = mode; self.percent = percent; self.rules = rules
    }
    public func validate() throws {
        guard percent.isFinite, (0...100).contains(percent), rules.count <= 64 else {
            throw GlutError.message("Invalid fan percentage or too many rules.")
        }
        for rule in rules {
            guard rule.sensor.utf8.count == 4, rule.sensor.hasPrefix("T"),
                  rule.threshold.isFinite, (10...120).contains(rule.threshold),
                  rule.percent.isFinite, (0...100).contains(rule.percent) else {
                throw GlutError.message("Invalid temperature rule.")
            }
        }
    }
}

public struct FanResponse: Codable {
    public var error: String?
    public init(error: String? = nil) { self.error = error }
}

public enum GlutError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public enum FanPolicy {
    // The highest matching rule wins. Hysteresis prevents rapid mode changes at a threshold.
    public static func boost(rules: [BoostRule], temperatures: [String: Double], active: Set<UUID>) throws -> (Double?, Set<UUID>) {
        var next = Set<UUID>()
        var percent: Double?
        for rule in rules where rule.enabled {
            guard let value = temperatures[rule.sensor], value.isFinite, (0...130).contains(value) else {
                throw GlutError.message("Rule sensor \(rule.sensor) is unavailable. Returning control to macOS.")
            }
            let threshold = active.contains(rule.id) ? rule.threshold - 3 : rule.threshold
            if value >= threshold {
                next.insert(rule.id)
                percent = max(percent ?? 0, rule.percent)
            }
        }
        return (percent, next)
    }
    public static func rpm(percent: Double, minimum: Double, maximum: Double) throws -> Double {
        guard percent.isFinite, minimum.isFinite, maximum.isFinite,
              (0...100).contains(percent), minimum >= 0, maximum > minimum, maximum < 30000 else {
            throw GlutError.message("Invalid fan limits; refusing to change fan speed.")
        }
        return minimum + (maximum - minimum) * percent / 100
    }
}

public enum CSV {
    public static func field(_ value: String) -> String {
        // Prevent spreadsheet formulas when opening an exported log.
        let safe = value.first.map { "=+-@".contains($0) } == true ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    public static func snapshot(date: Date, sensors: [Sensor], fans: [Fan]) -> String {
        let time = ISO8601DateFormatter().string(from: date)
        var lines = sensors.map { [time, "temperature", $0.id, $0.name, $0.celsius.map { String($0) } ?? "", "C"] }
        lines += fans.map { [time, "fan", String($0.id), $0.name, $0.actual.map { String($0) } ?? "", "RPM"] }
        return lines.map { $0.map(field).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }
}
