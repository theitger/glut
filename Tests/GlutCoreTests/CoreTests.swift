import XCTest
@testable import GlutCore

final class CoreTests: XCTestCase {
    func testSignedFixedPointTemperatures() {
        XCTAssertEqual(SMCValue.decode(type: "sp78", bytes: [0x19, 0x80]), 25.5)
        XCTAssertEqual(SMCValue.decode(type: "sp78", bytes: [0xfe, 0x80]), -1.5)
        XCTAssertNil(SMCValue.decode(type: "sp78", bytes: [1]))
    }
    func testFloatAndFanDecoding() {
        XCTAssertEqual(SMCValue.decode(type: "flt ", bytes: [0, 0, 0x48, 0x42]), 50)
        XCTAssertEqual(SMCValue.decode(type: "fpe2", bytes: [0x1f, 0x40]), 2000)
        XCTAssertEqual(SMCValue.decode(type: "ui8 ", bytes: [0]), 0)
        XCTAssertNil(SMCValue.decode(type: "flt ", bytes: [0, 0, 0x80, 0x7f]))
        XCTAssertNil(SMCValue.decode(type: "flt ", bytes: [0, 0]))
    }
    func testHighestRuleWinsAndHysteresis() throws {
        let low = BoostRule(sensor: "TC0P", threshold: 60, percent: 40)
        let high = BoostRule(sensor: "TC0P", threshold: 80, percent: 90)
        let rules = [low, high]
        let first = try FanPolicy.boost(rules: rules, temperatures: ["TC0P": 85], active: [])
        XCTAssertEqual(first.0, 90)
        let second = try FanPolicy.boost(rules: rules, temperatures: ["TC0P": 78], active: first.1)
        XCTAssertEqual(second.0, 90)
        let third = try FanPolicy.boost(rules: rules, temperatures: ["TC0P": 76], active: second.1)
        XCTAssertEqual(third.0, 40)
        XCTAssertNil(try FanPolicy.boost(rules: rules, temperatures: ["TC0P": 56], active: third.1).0)
    }
    func testMissingEnabledSensorFailsInsteadOfDisablingCooling() {
        let rule = BoostRule(sensor: "TC0P")
        XCTAssertThrowsError(try FanPolicy.boost(rules: [rule], temperatures: [:], active: []))
        XCTAssertThrowsError(try FanPolicy.boost(rules: [rule], temperatures: ["TC0P": .nan], active: []))
        XCTAssertNoThrow(try FanPolicy.boost(rules: [BoostRule(sensor: "TC0P", enabled: false)], temperatures: [:], active: []))
    }
    func testUntrustedHelperRequestsAreRejected() {
        XCTAssertThrowsError(try FanRequest(mode: .manual, percent: .infinity).validate())
        XCTAssertThrowsError(try FanRequest(mode: .manual, percent: -1).validate())
        XCTAssertThrowsError(try FanRequest(mode: .automatic, rules: [BoostRule(sensor: "FS! ")]).validate())
        XCTAssertThrowsError(try FanRequest(mode: .automatic, rules: [BoostRule(sensor: "TC0P", threshold: .nan)]).validate())
        XCTAssertThrowsError(try FanRequest(mode: .automatic, rules: Array(repeating: BoostRule(sensor: "TC0P"), count: 65)).validate())
    }
    func testRPMClampingAndBadFirmwareLimits() throws {
        XCTAssertEqual(try FanPolicy.rpm(percent: 0, minimum: 1200, maximum: 6000), 1200)
        XCTAssertEqual(try FanPolicy.rpm(percent: 50, minimum: 1200, maximum: 6000), 3600)
        XCTAssertEqual(try FanPolicy.rpm(percent: 100, minimum: 1200, maximum: 6000), 6000)
        XCTAssertThrowsError(try FanPolicy.rpm(percent: 50, minimum: 6000, maximum: 1200))
        XCTAssertThrowsError(try FanPolicy.rpm(percent: 50, minimum: 0, maximum: .nan))
    }
    func testLabelsAreSpecificToChipGeneration() {
        XCTAssertEqual(SensorCatalog.describe("Tp09", chip: "Apple M1 Pro").0, "CPU efficiency core 1")
        XCTAssertEqual(SensorCatalog.describe("Tp09", chip: "Apple M4 Pro").0, "CPU performance core 3")
        XCTAssertEqual(SensorCatalog.describe("Tp0P", chip: "Intel Core i7").0, "Powerboard")
        XCTAssertEqual(SensorCatalog.describe("Tp0P", chip: "Apple M1").0, "CPU performance core 6")
        XCTAssertEqual(SensorCatalog.describe("Te05", chip: "Apple M2 Pro").0, "CPU · Te05")
        XCTAssertEqual(SensorCatalog.describe("Tzzz", chip: "Apple M4").1, .other)
    }
    func testCSVQuotesAndFormulaInjection() {
        XCTAssertEqual(CSV.field("A, \"B\""), "\"A, \"\"B\"\"\"")
        XCTAssertEqual(CSV.field("=1+1"), "\"'=1+1\"")
    }
    func testSocketFramingAndMalformedJSON() throws {
        var sockets: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { sockets.forEach { close($0) } }
        try LocalSocket.send(FanRequest(mode: .max), to: sockets[0])
        let request = try LocalSocket.receive(FanRequest.self, from: sockets[1])
        XCTAssertEqual(request.mode, .max)
        let invalid = Data("{bad json}\n".utf8)
        invalid.withUnsafeBytes { _ = write(sockets[0], $0.baseAddress, $0.count) }
        XCTAssertThrowsError(try LocalSocket.receive(FanRequest.self, from: sockets[1]))
    }
    func testUnprivilegedHelperImpersonationIsRejected() throws {
        XCTAssertThrowsError(try FanConnection(path: "/tmp/arbitrary.sock"))
        XCTAssertThrowsError(try LocalSocket.address(String(repeating: "a", count: 200)))
    }
    func testSocketTimeoutAndEOF() throws {
        var sockets: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[1]) }
        try LocalSocket.configure(sockets[1], seconds: 1)
        XCTAssertThrowsError(try LocalSocket.receive(FanResponse.self, from: sockets[1]))
        close(sockets[0])
        XCTAssertThrowsError(try LocalSocket.receive(FanResponse.self, from: sockets[1]))
        XCTAssertThrowsError(try LocalSocket.configure(-1, seconds: 1))
    }
}
