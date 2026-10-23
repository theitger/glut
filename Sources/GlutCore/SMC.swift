import Foundation
import IOKit

public struct SMCValue {
    public let type: String
    public let bytes: [UInt8]
    public var number: Double? { Self.decode(type: type, bytes: bytes) }

    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16", "ui32":
            let count = type == "ui16" ? 2 : 4
            guard bytes.count >= count else { return nil }
            return Double(bytes.prefix(count).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        default:
            guard bytes.count >= 2, type.count == 4 else { return nil }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            let chars = Array(type)
            guard let fractional = chars[3].hexDigitValue else { return nil }
            if type.hasPrefix("sp") { return Double(Int16(bitPattern: raw)) / pow(2, Double(fractional)) }
            if type.hasPrefix("fp") { return Double(raw) / pow(2, Double(fractional)) }
            return nil
        }
    }
}

// Instances are confined to one serial queue (or the helper's single event loop).
public final class SMC {
    private var connection: io_connect_t = 0
    private var metadata: [String: SMCKeyData_t.keyInfo_t] = [:]

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw GlutError.message("AppleSMC is unavailable on this Mac.") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else { throw failure("Open AppleSMC", result) }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func failure(_ context: String, _ code: kern_return_t) -> GlutError {
        .message("\(context): \(String(cString: mach_error_string(code))) (\(code)).")
    }
    private func code(_ key: String) throws -> UInt32 {
        guard key.utf8.count == 4 else { throw GlutError.message("SMC keys must have four bytes.") }
        return key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
    private func string(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii) ?? "????"
    }
    private func call(_ input: inout SMCKeyData_t) throws -> SMCKeyData_t {
        var output = SMCKeyData_t()
        var size = MemoryLayout<SMCKeyData_t>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, size, &output, &size)
        guard result == kIOReturnSuccess else { throw failure("AppleSMC operation", result) }
        guard output.result == 0 else {
            throw GlutError.message("SMC rejected operation for \(string(input.key)) (0x\(String(output.result, radix: 16))).")
        }
        return output
    }
    public func read(_ key: String) throws -> SMCValue {
        var input = SMCKeyData_t()
        input.key = try code(key)
        let info: SMCKeyData_t.keyInfo_t
        if let cached = metadata[key] { info = cached }
        else {
            input.data8 = 9
            info = try call(&input).keyInfo
            guard (1...32).contains(info.dataSize) else { throw GlutError.message("Invalid SMC value size for \(key).") }
            metadata[key] = info
        }
        input.keyInfo.dataSize = info.dataSize
        input.data8 = 5
        var output = try call(&input)
        let bytes = withUnsafeBytes(of: &output.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return SMCValue(type: string(info.dataType), bytes: bytes)
    }
    public func number(_ key: String) -> Double? {
        // Missing keys are expected during discovery. Live sensor failures remain nil in the UI.
        (try? read(key))?.number
    }
    public func keys() throws -> [String] {
        guard let count = number("#KEY"), count.isFinite, (1...30000).contains(count) else {
            throw GlutError.message("AppleSMC did not return a valid sensor count.")
        }
        var keys: [String] = []
        for index in 0..<Int(count) {
            var input = SMCKeyData_t()
            input.data8 = 8; input.data32 = UInt32(index)
            keys.append(string(try call(&input).key))
        }
        return keys
    }
    public func fans() -> [Fan] {
        guard let count = number("FNum"), count.isFinite, (0...10).contains(count) else { return [] }
        return (0..<Int(count)).map { id in
            let label = (try? read("F\(id)ID")).flatMap { value -> String? in
                guard value.type == "{fds", value.bytes.count > 4 else { return nil }
                return String(bytes: value.bytes.dropFirst(4).prefix { $0 != 0 }, encoding: .utf8)?.trimmingCharacters(in: .whitespaces)
            }
            let mode = number(modeKey(id))
            return Fan(id: id, name: label.flatMap { $0.isEmpty ? nil : $0 } ?? "Fan \(id + 1)",
                       actual: number("F\(id)Ac"), minimum: number("F\(id)Mn"), maximum: number("F\(id)Mx"),
                       target: number("F\(id)Tg"), forced: mode.map { $0 == 1 })
        }
    }
    private func modeKey(_ id: Int) -> String {
        number("F\(id)md") != nil ? "F\(id)md" : "F\(id)Md"
    }
    private func write(_ key: String, bytes: [UInt8]) throws {
        let old = try read(key)
        guard bytes.count == old.bytes.count, bytes.count <= 32 else { throw GlutError.message("SMC write size mismatch.") }
        var input = SMCKeyData_t()
        input.key = try code(key); input.data8 = 6
        input.keyInfo.dataSize = UInt32(bytes.count)
        withUnsafeMutableBytes(of: &input.bytes) { destination in
            destination.copyBytes(from: bytes)
        }
        _ = try call(&input)
    }
    private func writeByte(_ key: String, value: UInt8) throws {
        var bytes = try read(key).bytes
        bytes[0] = value
        try write(key, bytes: bytes)
    }
    public func setSpeed(fan: Fan, percent: Double) throws {
        guard let minimum = fan.minimum, let maximum = fan.maximum else {
            throw GlutError.message("Fan \(fan.id) has no readable speed limits.")
        }
        let rpm = try FanPolicy.rpm(percent: percent, minimum: minimum, maximum: maximum)
        let key = "F\(fan.id)Tg"
        let value = try read(key)
        let bytes: [UInt8]
        if value.type == "flt ", value.bytes.count == 4 {
            var speed = Float(rpm)
            bytes = withUnsafeBytes(of: &speed) { Array($0) }
        } else if value.type == "fpe2", value.bytes.count == 2, rpm <= 16383 {
            let raw = UInt16(rpm * 4)
            bytes = [UInt8(raw >> 8), UInt8(raw & 255)]
        } else { throw GlutError.message("Unsupported fan target encoding: \(value.type).") }
        try setMode(fan.id, manual: true)
        try write(key, bytes: bytes)
        guard let target = number(key), abs(target - rpm) < 100 else {
            throw GlutError.message("Fan \(fan.id + 1) did not accept its target speed.")
        }
    }
    private func setMode(_ id: Int, manual: Bool) throws {
        #if arch(arm64)
        let key = modeKey(id)
        do { try writeByte(key, value: manual ? 1 : 0) }
        catch {
            guard manual, number("Ftst") != nil else { throw error }
            try writeByte("Ftst", value: 1)
            Thread.sleep(forTimeInterval: 3)
            try writeByte(key, value: 1)
        }
        if !manual {
            let target = "F\(id)Tg"
            let value = try read(target)
            try write(target, bytes: Array(repeating: 0, count: value.bytes.count))
        }
        #else
        if number("F\(id)Md") != nil { try writeByte("F\(id)Md", value: manual ? 1 : 0) }
        var bytes = try read("FS! ").bytes
        guard bytes.count == 2 else { throw GlutError.message("Unsupported Intel fan mode encoding.") }
        var mask = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        if manual { mask |= 1 << id } else { mask &= ~(1 << id) }
        bytes = [UInt8(mask >> 8), UInt8(mask & 255)]
        try write("FS! ", bytes: bytes)
        #endif
    }
    public func restoreSystem(fans: [Fan]) throws {
        var errors: [String] = []
        // Attempt every reset even when one firmware write fails.
        for fan in fans {
            do { try setMode(fan.id, manual: false) }
            catch { errors.append(error.localizedDescription) }
        }
        #if arch(arm64)
        if number("Ftst") != nil {
            do { try writeByte("Ftst", value: 0) }
            catch { errors.append(error.localizedDescription) }
        }
        #endif
        guard errors.isEmpty else { throw GlutError.message(errors.joined(separator: "\n")) }
    }
}
