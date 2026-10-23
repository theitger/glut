import XCTest
@testable import GlutCore

private final class FakeHardware: FanHardware {
    var readings: [String: Double] = ["TC0P": 85]
    var writes: [(Int, Double)] = []
    var resets: [[Int]] = []
    var failFan: Int?
    var failReset = false
    func number(_ key: String) -> Double? { readings[key] }
    func setSpeed(fan: Fan, percent: Double) throws {
        writes.append((fan.id, percent))
        if fan.id == failFan { throw GlutError.message("Firmware rejected target") }
    }
    func restoreSystem(fans: [Fan]) throws {
        resets.append(fans.map(\.id))
        if failReset { throw GlutError.message("Firmware rejected reset") }
    }
}

final class FanSessionTests: XCTestCase {
    private func fans() -> [Fan] {
        (0...1).map { Fan(id: $0, name: "Fan", actual: 2000, minimum: 1200, maximum: 6000, target: 2000, forced: false) }
    }
    func testPartialFanWriteRestoresEveryFan() throws {
        let hardware = FakeHardware(); hardware.failFan = 1
        let session = try FanSession(hardware: hardware, fans: fans())
        XCTAssertThrowsError(try session.apply(FanRequest(mode: .max)))
        XCTAssertEqual(hardware.writes.map(\.0), [0, 1])
        XCTAssertEqual(hardware.resets, [[0, 1]])
    }
    func testDisconnectCleanupRestoresSystemOnce() throws {
        let hardware = FakeHardware()
        let session = try FanSession(hardware: hardware, fans: fans())
        try session.apply(FanRequest(mode: .manual, percent: 60))
        try session.close()
        try session.close()
        XCTAssertEqual(hardware.resets, [[0, 1]])
        XCTAssertEqual(hardware.writes.map(\.1), [60, 60])
    }
    func testIdleSessionDoesNotOverrideSystem() throws {
        let hardware = FakeHardware()
        let session = try FanSession(hardware: hardware, fans: fans())
        try session.apply(FanRequest(mode: .system))
        try session.close()
        XCTAssertTrue(hardware.resets.isEmpty)
        XCTAssertTrue(hardware.writes.isEmpty)
    }
    func testAutomaticRuleClearingReturnsToSystem() throws {
        let hardware = FakeHardware()
        let session = try FanSession(hardware: hardware, fans: fans())
        let request = FanRequest(mode: .automatic, rules: [BoostRule(sensor: "TC0P", threshold: 80, percent: 90)])
        try session.apply(request)
        hardware.readings["TC0P"] = 78
        try session.apply(request)
        XCTAssertTrue(hardware.resets.isEmpty)
        hardware.readings["TC0P"] = 76
        try session.apply(request)
        XCTAssertEqual(hardware.resets, [[0, 1]])
    }
    func testMissingLiveRuleSensorResetsActiveControl() throws {
        let hardware = FakeHardware()
        let session = try FanSession(hardware: hardware, fans: fans())
        let request = FanRequest(mode: .automatic, rules: [BoostRule(sensor: "TC0P")])
        try session.apply(request)
        hardware.readings = [:]
        XCTAssertThrowsError(try session.apply(request))
        XCTAssertEqual(hardware.resets, [[0, 1]])
    }
    func testInvalidRequestResetsPreviousControl() throws {
        let hardware = FakeHardware()
        let session = try FanSession(hardware: hardware, fans: fans())
        try session.apply(FanRequest(mode: .max))
        XCTAssertThrowsError(try session.apply(FanRequest(mode: .manual, percent: 101)))
        XCTAssertEqual(hardware.resets, [[0, 1]])
    }
    func testImplausibleLiveCPUReadingResetsInsteadOfSilentlyClearingRule() throws {
        let hardware = FakeHardware()
        let session = try FanSession(hardware: hardware, fans: fans())
        let request = FanRequest(mode: .automatic, rules: [BoostRule(sensor: "TC0P")])
        try session.apply(request)
        hardware.readings["TC0P"] = 6.7
        XCTAssertThrowsError(try session.apply(request))
        XCTAssertEqual(hardware.resets, [[0, 1]])
    }
    func testFailedResetCanBeRetriedAndReportsBothFailures() throws {
        let hardware = FakeHardware(); hardware.failFan = 1; hardware.failReset = true
        let session = try FanSession(hardware: hardware, fans: fans())
        XCTAssertThrowsError(try session.apply(FanRequest(mode: .max))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Firmware rejected target"))
            XCTAssertTrue(error.localizedDescription.contains("Reset also failed"))
        }
        hardware.failReset = false
        try session.close()
        XCTAssertEqual(hardware.resets.count, 2)
    }
    func testEmptyHardwareIsRejected() {
        XCTAssertThrowsError(try FanSession(hardware: FakeHardware(), fans: []))
    }
}
