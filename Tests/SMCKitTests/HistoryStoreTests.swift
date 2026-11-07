import Foundation
import SQLite3
import Testing
@testable import SMCKit

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("thermal-test-\(UUID().uuidString).sqlite")
}

private func snap(_ t: TimeInterval, battery: Double, die: Double = 50, charging: Bool = true,
                  percent: Int = 50, rawMax: Int = 6286) -> Snapshot {
    let b = BatteryStatus(percent: percent, isCharging: charging, externalConnected: true, fullyCharged: false,
                          voltage: 12, amperage: 2000, cycleCount: 3, designCapacity: 6249, rawMaxCapacity: rawMax,
                          notChargingReason: 0, adapterWatts: 96, maximumCapacity: 100)
    return Snapshot(date: Date(timeIntervalSince1970: t), sensors: [
        SensorReading(id: "smc:TB0T", name: "Battery 1", group: .battery, celsius: battery),
        SensorReading(id: "hid:PMU tdie1", name: "Die 1", group: .soc, celsius: die),
    ], fans: [], battery: b)
}

private func rowCount(_ url: URL, _ sql: String) -> Int {
    var db: OpaquePointer?
    sqlite3_open(url.path, &db)
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -1
}

@Suite struct HistoryStoreTests {
    let t0: TimeInterval = 1_800_000_000   // aligned to the hour

    @Test func bucketsIntoTiers() async {
        let url = tempURL()
        let store = HistoryStore(url: url)
        for i in 0..<7200 { await store.record(snap(t0 + Double(i), battery: 25 + Double(i % 60) / 60)) }
        await store.flush()
        let s = await store.stats()
        #expect(s.rows["r"] == 1440)     // 2 h / 5 s
        #expect(s.rows["m"] == 120)
        #expect(s.rows["h"] == 2)
    }

    @Test func averagesAndBand() async {
        let store = HistoryStore(url: tempURL())
        for i in 0..<120 { await store.record(snap(t0 + Double(i), battery: i < 60 ? 24 : 26)) }
        let now = Date(timeIntervalSince1970: t0 + 120)
        let pts = await store.series([Metric.batteryTemp.rawValue], range: .day, now: now)
        #expect(pts.map(\.value) == [24, 26])
        let charging = await store.series([Metric.charging.rawValue], range: .day, now: now)
        #expect(charging.allSatisfy { $0.value == 1 })
        let band = await store.batteryBand(range: .day, now: now)
        #expect(band.count == 2 && band[0].low == 24 && band[1].high == 26)
    }

    @Test func resumesBucketAfterRestart() async {
        let url = tempURL()
        let a = HistoryStore(url: url)
        for i in 0..<1800 { await a.record(snap(t0 + Double(i), battery: 20)) }
        await a.flush()                                     // quit mid-hour
        let b = HistoryStore(url: url)
        for i in 1800..<3600 { await b.record(snap(t0 + Double(i), battery: 30)) }
        await b.flush()
        let hour = await b.series([Metric.batteryTemp.rawValue], range: .year, now: Date(timeIntervalSince1970: t0 + 3600))
        #expect(hour.count == 1)
        #expect(abs(hour[0].value - 25) < 0.01)            // both halves, not just the second
    }

    @Test func pruneKeepsHourTierForever() async {
        let url = tempURL()
        let store = HistoryStore(url: url)
        for i in stride(from: 0, to: 7200, by: 5) { await store.record(snap(t0 + Double(i), battery: 25)) }
        await store.flush()
        await store.pruneForTesting(now: Date(timeIntervalSince1970: t0 + 400 * 86_400))
        let s = await store.stats()
        #expect(s.rows["r"] == nil && s.rows["m"] == nil)
        #expect(s.rows["h"] == 2)
    }

    @Test func recordsBatteryHealthDaily() async {
        let store = HistoryStore(url: tempURL())
        await store.record(snap(t0, battery: 25, rawMax: 6286))
        await store.record(snap(t0 + 86_400, battery: 25, rawMax: 6200))
        let h = await store.batteryHealth()
        #expect(h.count == 2)
        #expect(abs(h[0].health - 6286.0 / 6249 * 100) < 0.01)
        #expect(h[1].maximumCapacity == 100 && h[1].cycles == 3)
    }

    @Test func migratesV1Tables() async {
        let url = tempURL()
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, """
            CREATE TABLE metric (id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL);
            CREATE TABLE raw (ts INTEGER NOT NULL, metric INTEGER NOT NULL, value REAL NOT NULL);
            CREATE TABLE minute (ts INTEGER NOT NULL, metric INTEGER NOT NULL, value REAL NOT NULL);
            INSERT INTO metric VALUES (1, 'battery.temp'), (2, 'die.max'), (3, 'sensor:hid:PMU tdie1');
            INSERT INTO raw VALUES (\(Int(t0)), 1, 24), (\(Int(t0) + 1), 1, 26), (\(Int(t0)), 2, 50);
            INSERT INTO minute VALUES (\(Int(t0)), 1, 25), (\(Int(t0) + 60), 1, 27), (\(Int(t0)), 3, 99);
            """, nil, nil, nil)
        sqlite3_close(db)

        let store = HistoryStore(url: url)
        let now = Date(timeIntervalSince1970: t0 + 120)
        let recent = await store.series([Metric.batteryTemp.rawValue], range: .hour, now: now)
        #expect(recent.first?.value == 25)                 // 24 and 26 in one 5 s bucket
        let minute = await store.series([Metric.batteryTemp.rawValue], range: .day, now: now)
        #expect(minute.map(\.value) == [25, 27])
        #expect(rowCount(url, "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('raw','minute','metric')") == 0)
    }
}
