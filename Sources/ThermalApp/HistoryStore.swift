import Foundation
import SMCKit
import SQLite3

/// Summary series recorded every second (and rolled up per minute).
enum Metric: String, CaseIterable, Sendable {
    case batteryTemp = "battery.temp"
    case dieMax = "die.max"
    case dieAvg = "die.avg"
    case storageTemp = "storage.temp"
    case fanRPM = "fan.rpm"
    case batteryPercent = "battery.percent"
    case batteryWatts = "battery.watts"
    case charging = "charging"
    case onAC = "ac"

    var title: String {
        switch self {
        case .batteryTemp: "Battery"
        case .dieMax: "Hottest die"
        case .dieAvg: "Die average"
        case .storageTemp: "Storage"
        case .fanRPM: "Fans"
        case .batteryPercent: "Charge"
        case .batteryWatts: "Battery power"
        case .charging: "Charging"
        case .onAC: "On AC"
        }
    }

    static func values(from s: Snapshot) -> [Metric: Double] {
        var v: [Metric: Double] = [:]
        v[.batteryTemp] = s.batteryTemperature
        v[.dieMax] = s.hottestDie
        v[.dieAvg] = [s.average(.cpu), s.average(.gpu), s.average(.soc)].compactMap { $0 }.max()
        v[.storageTemp] = s.max(.storage)
        v[.fanRPM] = s.fans.isEmpty ? nil : s.averageFanRPM
        if let b = s.battery {
            v[.batteryPercent] = Double(b.percent)
            v[.batteryWatts] = b.batteryWatts
            v[.charging] = b.isCharging ? 1 : 0
            v[.onAC] = b.externalConnected ? 1 : 0
        }
        return v
    }
}

struct HistoryPoint: Sendable, Identifiable {
    let date: Date
    let metric: String
    let value: Double
    var id: String { "\(metric)@\(date.timeIntervalSince1970)" }
}

enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case hour = "1 h", day = "24 h", week = "7 d", month = "30 d"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self { case .hour: 3600; case .day: 86_400; case .week: 7 * 86_400; case .month: 30 * 86_400 }
    }
    /// Bucket size used for the query (keeps every chart at ≤ ~1500 points).
    var bucket: Int {
        switch self { case .hour: 5; case .day: 60; case .week: 600; case .month: 1800 }
    }
}

/// SQLite-backed history.
/// - `raw`: summary metrics at 1 Hz, kept 24 h.
/// - `minute`: per-minute averages of summary metrics **and every sensor**, kept 30 days.
/// Writes are batched (one transaction every 10 s); minute averages are computed in memory.
actor HistoryStore {
    static let rawRetention: TimeInterval = 86_400
    static let minuteRetention: TimeInterval = 30 * 86_400

    private var db: OpaquePointer?
    private var metricIDs: [String: Int64] = [:]
    private var pendingRaw: [(ts: Int64, key: String, value: Double)] = []
    private var minuteBucket: Int64 = 0
    private var minuteSums: [String: (sum: Double, count: Int)] = [:]
    private var lastFlush = Date.distantPast
    private var lastPrune = Date.distantPast

    let url: URL

    init(url: URL) {
        self.url = url
    }

    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thermal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.sqlite")
    }

    private func openIfNeeded() -> Bool {
        if db != nil { return true }
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { db = nil; return false }
        exec("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS metric (id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL);
            CREATE TABLE IF NOT EXISTS raw (ts INTEGER NOT NULL, metric INTEGER NOT NULL, value REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS raw_metric_ts ON raw(metric, ts);
            CREATE TABLE IF NOT EXISTS minute (ts INTEGER NOT NULL, metric INTEGER NOT NULL, value REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS minute_metric_ts ON minute(metric, ts);
            """)
        return true
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func metricID(_ key: String) -> Int64? {
        if let id = metricIDs[key] { return id }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO metric(key) VALUES (?1)", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        var sel: OpaquePointer?
        defer { sqlite3_finalize(sel) }
        sqlite3_prepare_v2(db, "SELECT id FROM metric WHERE key = ?1", -1, &sel, nil)
        sqlite3_bind_text(sel, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(sel) == SQLITE_ROW else { return nil }
        let id = sqlite3_column_int64(sel, 0)
        metricIDs[key] = id
        return id
    }

    func record(_ s: Snapshot) {
        guard openIfNeeded() else { return }
        let ts = Int64(s.date.timeIntervalSince1970)
        let summary = Metric.values(from: s)
        for (m, v) in summary { pendingRaw.append((ts, m.rawValue, v)) }

        // Minute roll-up: summary metrics plus every individual sensor and fan.
        let bucket = ts / 60 * 60
        if bucket != minuteBucket {
            flushMinute()
            minuteBucket = bucket
        }
        func add(_ key: String, _ v: Double) {
            let cur = minuteSums[key] ?? (0, 0)
            minuteSums[key] = (cur.sum + v, cur.count + 1)
        }
        for (m, v) in summary { add(m.rawValue, v) }
        for r in s.sensors { add("sensor:" + r.id, r.celsius) }
        for f in s.fans { add("fan\(f.id).rpm", f.actualRPM) }

        if s.date.timeIntervalSince(lastFlush) >= 10 { flushRaw(); lastFlush = s.date }
        if s.date.timeIntervalSince(lastPrune) >= 3600 { prune(now: s.date); lastPrune = s.date }
    }

    private func insert(_ table: String, _ rows: [(ts: Int64, key: String, value: Double)]) {
        guard !rows.isEmpty else { return }
        exec("BEGIN")
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO \(table)(ts, metric, value) VALUES (?1, ?2, ?3)", -1, &stmt, nil)
        for r in rows {
            guard let id = metricID(r.key) else { continue }
            sqlite3_bind_int64(stmt, 1, r.ts)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_bind_double(stmt, 3, r.value)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
        sqlite3_finalize(stmt)
        exec("COMMIT")
    }

    private func flushRaw() {
        insert("raw", pendingRaw)
        pendingRaw.removeAll(keepingCapacity: true)
    }

    private func flushMinute() {
        guard minuteBucket != 0, !minuteSums.isEmpty else { return }
        insert("minute", minuteSums.map { (minuteBucket, $0.key, $0.value.sum / Double($0.value.count)) })
        minuteSums.removeAll(keepingCapacity: true)
    }

    private func prune(now: Date) {
        let rawCut = Int64(now.timeIntervalSince1970 - Self.rawRetention)
        let minCut = Int64(now.timeIntervalSince1970 - Self.minuteRetention)
        exec("DELETE FROM raw WHERE ts < \(rawCut); DELETE FROM minute WHERE ts < \(minCut);")
    }

    /// Flush everything pending (call on quit).
    func flush() {
        guard db != nil else { return }
        flushRaw()
        flushMinute()
    }

    /// Bucketed averages for the given metric keys over the range ending now.
    func series(_ keys: [String], range: HistoryRange, now: Date = Date()) -> [HistoryPoint] {
        guard openIfNeeded() else { return [] }
        flushRaw()   // include the last few seconds
        let since = Int64(now.timeIntervalSince1970 - range.seconds)
        // 1 h comes from the 1 Hz table; longer ranges from minute averages.
        let table = range == .hour ? "raw" : "minute"
        let b = range.bucket
        var out: [HistoryPoint] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT (ts / \(b)) * \(b) AS t, AVG(value) FROM \(table)
            WHERE metric = ?1 AND ts >= ?2 GROUP BY t ORDER BY t
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        for key in keys {
            guard let id = metricIDs[key] ?? metricID(key) else { continue }
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_bind_int64(stmt, 2, since)
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(HistoryPoint(
                    date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0))),
                    metric: key,
                    value: sqlite3_column_double(stmt, 1)))
            }
        }
        return out
    }

    func stats() -> (rawRows: Int, minuteRows: Int, bytes: Int) {
        guard openIfNeeded() else { return (0, 0, 0) }
        func count(_ t: String) -> Int {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(t)", -1, &stmt, nil)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return (count("raw"), count("minute"), size)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
