import XCTest
@testable import GlutCore

final class TemperatureSummaryTests: XCTestCase {
    private func sensor(_ id: String, _ name: String, _ value: Double?) -> Sensor {
        Sensor(key: id, name: name, group: .cpu, celsius: value)
    }
    private func snapshot(_ time: Double, _ value: Double?) -> Snapshot {
        Snapshot(date: Date(timeIntervalSince1970: time), sensors: [sensor("Tp01", "CPU performance core 1", value)], fans: [], thermalState: "Nominal", battery: [:])
    }
    func testM2UnavailableCoreSentinelsAreRejected() {
        for value in [4.6, 6.7, 0, -1, Double.nan, .infinity, 121] {
            XCTAssertFalse(TemperatureReading.isPlausible(value, group: .cpu))
        }
        XCTAssertTrue(TemperatureReading.isPlausible(72.5, group: .cpu))
        XCTAssertTrue(TemperatureReading.isPlausible(105, group: .cpu))
        XCTAssertTrue(TemperatureReading.isPlausible(6.7, group: .system))
    }
    func testCoreAverageExcludesUnavailableUnknownAndHeatsinkSources() {
        let sensors = [sensor("Tp01", "CPU performance core 1", 70), sensor("Tp05", "CPU performance core 2", 80),
                       sensor("Tp1h", "CPU efficiency core 1", 6.7), sensor("TC0H", "CPU heatsink", 40),
                       sensor("TCMz", "CPU · TCMz", 110)]
        XCTAssertEqual(TemperatureSummary.componentMean(.cpu, sensors: sensors), 75)
        XCTAssertEqual(TemperatureSummary.componentPeak(.cpu, sensors: sensors), 80)
    }
    func testFailedCoreReadIsNotReplacedWithStaleOrZeroValue() {
        XCTAssertNil(TemperatureSummary.componentMean(.cpu, sensors: [sensor("Tp01", "CPU performance core 1", nil)]))
        XCTAssertNil(TemperatureSummary.rollingMean(.cpu, history: [snapshot(0, 80), snapshot(2, nil)]))
    }
    func testRollingMeanUsesOnlyCurrentTenSecondWindow() {
        let history = [snapshot(0, 100), snapshot(2, 60), snapshot(10, 80)]
        XCTAssertEqual(TemperatureSummary.rollingMean(.cpu, history: history), 70)
        XCTAssertEqual(TemperatureSummary.rollingMean(.cpu, history: [snapshot(0, 100), snapshot(20, 60)]), 60)
        XCTAssertNil(TemperatureSummary.rollingMean(.cpu, history: []))
    }
    func testDisplayAveragingDoesNotAlterRawTemperatures() {
        let history = [snapshot(0, 60), snapshot(2, 100)]
        XCTAssertEqual(TemperatureSummary.rollingMean(.cpu, history: history), 80)
        XCTAssertEqual(history.last?.sensors.first?.celsius, 100)
        XCTAssertEqual(history.last?.sensors.first?.maximum, 100)
    }
    func testPackageFallbackDoesNotMixInProximityAndHeatsink() {
        let sensors = [sensor("TCAD", "CPU package", 75), sensor("TC0P", "CPU proximity", 50), sensor("TC0H", "CPU heatsink", 40)]
        XCTAssertEqual(TemperatureSummary.componentMean(.cpu, sensors: sensors), 75)
    }
}
