import Foundation

public protocol FanHardware: AnyObject {
    func number(_ key: String) -> Double?
    func setSpeed(fan: Fan, percent: Double) throws
    func restoreSystem(fans: [Fan]) throws
}
extension SMC: FanHardware {}

/// Owns one session's mutations. Transport failures must call close(), including EOF and timeout.
public final class FanSession {
    private let hardware: FanHardware
    private let fans: [Fan]
    private var touched = false
    private var active = Set<UUID>()
    private var lastMode: ControlMode = .system

    public init(hardware: FanHardware, fans: [Fan]) throws {
        guard !fans.isEmpty else { throw GlutError.message("No controllable fans were found.") }
        self.hardware = hardware; self.fans = fans
    }
    public func apply(_ request: FanRequest) throws {
        do {
            try request.validate()
            if request.mode != lastMode { active.removeAll() }
            let percent = try target(request)
            if let percent {
                touched = true // A failure after the first write must reset every fan.
                for fan in fans { try hardware.setSpeed(fan: fan, percent: percent) }
            } else { try close() }
            lastMode = request.mode
        } catch {
            let original = error.localizedDescription
            do { try close() }
            catch { throw GlutError.message(original + " Reset also failed: " + error.localizedDescription) }
            throw error
        }
    }
    private func target(_ request: FanRequest) throws -> Double? {
        switch request.mode {
        case .system: return nil
        case .manual: return request.percent
        case .max: return 100
        case .automatic:
            let keys = Set(request.rules.filter(\.enabled).map(\.sensor))
            let chip = Machine.chip
            let readings = Dictionary(uniqueKeysWithValues: keys.compactMap { key -> (String, Double)? in
                let group = SensorCatalog.describe(key, chip: chip).1
                guard let value = hardware.number(key), TemperatureReading.isPlausible(value, group: group) else { return nil }
                return (key, value)
            })
            let result = try FanPolicy.boost(rules: request.rules, temperatures: readings, active: active)
            active = result.1
            return result.0
        }
    }
    public func close() throws {
        guard touched else { return }
        try hardware.restoreSystem(fans: fans)
        touched = false
    }
}
