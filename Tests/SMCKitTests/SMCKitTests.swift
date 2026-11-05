import Foundation
import Testing
@testable import SMCKit

@Suite struct SMCValueDecoding {
    @Test func floatIsLittleEndian() {
        // TB0T read on the M5 Pro: 6066b241 = 22.3 °C
        let v = SMCValue(key: "TB0T", type: "flt ", bytes: [0x60, 0x66, 0xb2, 0x41])
        #expect(abs(v.number! - 22.3) < 0.01)
    }

    @Test func integersAreLittleEndian() {
        // B0DC = 6249 mAh = DesignCapacity from IORegistry
        #expect(SMCValue(key: "B0DC", type: "ui16", bytes: [0x69, 0x18]).number == 6249)
        #expect(SMCValue(key: "x", type: "ui32", bytes: [0x01, 0, 0, 0]).number == 1)
        #expect(SMCValue(key: "x", type: "si16", bytes: [0xff, 0xff]).number == -1)
    }

    @Test func legacyFixedPointIsBigEndian() {
        #expect(SMCValue(key: "x", type: "sp78", bytes: [0x1a, 0x80]).number == 26.5)
        #expect(SMCValue(key: "x", type: "fpe2", bytes: [0x00, 0x08]).number == 2)
    }

    @Test func unknownTypeHasNoNumber() {
        #expect(SMCValue(key: "x", type: "hex_", bytes: [0x07]).number == nil)
        #expect(SMCValue(key: "x", type: "hex_", bytes: [0x07]).hex == "07")
    }
}

@Suite struct Catalog {
    let catalog = SensorCatalog()

    func hid(_ name: String, _ c: Double, index: Int = 0) -> HIDTemperature {
        HIDTemperature(index: index, name: name, location: 0x5450_3162, celsius: c)
    }

    @Test func mergesDuplicateDiesUsingMax() {
        let r = catalog.readings(hid: [hid("PMU tdie1", 50), hid("PMU tdie1", 52.5), hid("PMU tdie1", 51)], smcBattery: [])
        #expect(r.count == 1)
        #expect(r[0].id == "hid:PMU tdie1")
        #expect(r[0].name == "Die 1")
        #expect(r[0].celsius == 52.5)
        #expect(r[0].group == .soc)
    }

    @Test func dropsImplausibleAndDuplicateChannels() {
        let r = catalog.readings(
            hid: [hid("PMU tdev1", -9201), hid("gas gauge battery", 22), hid("NAND CH0 temp", 33)],
            smcBattery: [("TB0T", 22.3), ("TB1T", -9000)])
        #expect(r.map(\.id) == ["smc:TB0T", "hid:NAND CH0 temp"])
        #expect(r.first { $0.id == "hid:NAND CH0 temp" }?.group == .storage)
    }

    @Test func sortsDiesNaturally() {
        let r = catalog.readings(hid: [hid("PMU tdie10", 50), hid("PMU tdie2", 50), hid("PMU tdie1", 50)], smcBattery: [])
        #expect(r.map(\.name) == ["Die 1", "Die 2", "Die 10"])
    }

    @Test func overridesAndHiddenApply() {
        let c = SensorCatalog(overrides: ["hid:PMU tdie1": .gpu], hidden: ["hid:PMU tdie2"])
        let r = c.readings(hid: [hid("PMU tdie1", 60), hid("PMU tdie2", 50)], smcBattery: [])
        #expect(r.count == 1)
        #expect(r[0].group == .gpu)
    }
}

@Suite struct LiveHardware {
    @Test func snapshotHasBatteryDiesAndFans() async throws {
        let reader = SensorReader()
        try #require(await reader.smcAvailable)
        let s = await reader.snapshot()
        #expect(s.sensors(in: .battery).count == 3)
        #expect(s.sensors(in: .soc).count == 14)
        #expect(s.fans.count == 2)
        #expect(s.battery != nil)
        #expect((15...60).contains(s.batteryTemperature ?? 0))
    }
}
