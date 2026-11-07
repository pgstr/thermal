import Foundation
import SQLite3

/// Summary series recorded from every snapshot.
public enum Metric: String, CaseIterable, Sendable {
    case batteryTemp = "battery.temp"
    case dieMax = "die.max"
    case dieAvg = "die.avg"
    case storageTemp = "storage.temp"
    case fanRPM = "fan.rpm"
    case batteryPercent = "battery.percent"
    case batteryWatts = "battery.watts"
    case charging = "charging"          // 0/1 per sample; bucket average = fraction of time charging
    case onAC = "ac"
    case batteryHealth = "battery.health"   // raw max capacity ÷ design, %

    public var title: String {
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
        case .batteryHealth: "Battery health"
        }
    }

    /// SQL column name.
    var column: String { rawValue.replacingOccurrences(of: ".", with: "_") }

    public static func values(from s: Snapshot) -> [Metric: Double] {
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
            v[.batteryHealth] = b.health
        }
        return v
    }
}

public struct HistoryPoint: Sendable, Identifiable {
    public let date: Date
    public let metric: String
    public let value: Double
    public var id: String { "\(metric)@\(date.timeIntervalSince1970)" }
}

/// Battery temperature range within one bucket (for the min–max band).
public struct HistoryBand: Sendable, Identifiable {
    public let date: Date
    public let low: Double
    public let high: Double
    public var id: TimeInterval { date.timeIntervalSince1970 }
}

/// One row per day, kept forever. Health = raw max capacity ÷ design capacity, which swings by
/// a few percent within a day, so the daily mean plus min/max are kept.
public struct BatteryHealthPoint: Sendable, Identifiable {
    public let day: Date
    public let health: Double            // daily mean, %
    public let low: Double
    public let high: Double
    public let maximumCapacity: Int?     // Apple's figure, %
    public let cycles: Int
    public let samples: Int
    public let fromPowerLog: Bool        // imported from macOS's power log (vs. Thermal's hourly samples)
    public var id: TimeInterval { day.timeIntervalSince1970 }
}

public enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case hour = "1 h", day = "24 h", week = "7 d", month = "30 d", year = "1 y"
    public var id: String { rawValue }
    public var seconds: TimeInterval {
        switch self {
        case .hour: 3600
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .year: 365 * 86_400
        }
    }
    /// Query bucket (≤ ~1500 points per chart).
    public var bucket: Int {
        switch self { case .hour: 5; case .day: 60; case .week: 600; case .month: 1800; case .year: 43_200 }
    }
    var tier: HistoryStore.Tier {
        switch self { case .hour: .recent; case .day, .week, .month: .minute; case .year: .hour }
    }
}

/// Long-term history in SQLite, sized to grow slowly (~7 MB steady + ~1 MB/year).
///
/// Wide rows (one per time bucket, all metrics as columns) in three tiers:
/// | tier   | bucket | kept    | feeds        |
/// | recent | 5 s    | 48 h    | 1 h view     |
/// | minute | 60 s   | 30 days | 24 h–30 d    |
/// | hour   | 3600 s | forever | 1 y view     |
/// plus `battery_daily` (daily health mean/min/max, Apple's max capacity, cycles), kept forever,
/// filled from macOS's power log where available and from hourly samples otherwise.
/// Buckets are averaged in memory; completed rows are written in batches every 30 s.
public actor HistoryStore {
    public enum Tier: String, CaseIterable, Sendable {
        case recent = "r", minute = "m", hour = "h"
        var seconds: Int64 { switch self { case .recent: 5; case .minute: 60; case .hour: 3600 } }
        var retention: TimeInterval? {
            switch self { case .recent: 48 * 3600; case .minute: 30 * 86_400; case .hour: nil }
        }
    }

    public let url: URL
    private var db: OpaquePointer?
    private var buckets: [Tier: Bucket] = [:]
    private var pending: [Row] = []
    private var lastWrite = Date.distantPast
    private var lastPrune = Date.distantPast
    private var lastHealthDay: String?

    private static let columns = Metric.allCases.map(\.column)

    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thermal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.sqlite")
    }

    // MARK: Schema and migration

    private func openIfNeeded() -> Bool {
        if db != nil { return true }
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { db = nil; return false }
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        let cols = Self.columns.map { "\($0) REAL" }.joined(separator: ", ")
        exec("""
            CREATE TABLE IF NOT EXISTS samples (
                tier TEXT NOT NULL, ts INTEGER NOT NULL, n INTEGER NOT NULL,
                \(cols), battery_temp_min REAL, battery_temp_max REAL, die_peak REAL,
                PRIMARY KEY (tier, ts)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS battery_daily (
                day TEXT PRIMARY KEY, health REAL, max_capacity INTEGER, cycles INTEGER,
                design_mah INTEGER, raw_max_mah INTEGER);
            CREATE TABLE IF NOT EXISTS powerlog_days (
                file TEXT NOT NULL, day TEXT NOT NULL, health_sum REAL, health_min REAL, health_max REAL,
                n INTEGER, max_capacity INTEGER, cycles INTEGER, design_mah INTEGER, raw_max_mah INTEGER,
                PRIMARY KEY (file, day)) WITHOUT ROWID;
            """)
        // Metrics added after the table was created (e.g. battery.health) become new columns.
        let sampleColumns = columnNames("samples")
        for col in Self.columns where !sampleColumns.contains(col) {
            exec("ALTER TABLE samples ADD COLUMN \(col) REAL")
        }
        // battery_daily v2 columns (daily mean + min/max, sample count, source).
        let existing = columnNames("battery_daily")
        for (col, type) in [("health_min", "REAL"), ("health_max", "REAL"), ("n", "INTEGER DEFAULT 1"),
                            ("source", "TEXT DEFAULT 'thermal'")] where !existing.contains(col) {
            exec("ALTER TABLE battery_daily ADD COLUMN \(col) \(type)")
        }
        migrateV1IfNeeded()
        return true
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    private func columnNames(_ table: String) -> Set<String> {
        var out = Set<String>()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW { out.insert(String(cString: sqlite3_column_text(stmt, 1))) }
        return out
    }

    private func tableExists(_ name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// v1 stored one row per (timestamp, metric) in `raw` (1 Hz) and `minute` (+ every sensor).
    /// Pivot the summary metrics into the new tiers, then drop the old tables and compact.
    private func migrateV1IfNeeded() {
        guard tableExists("raw"), tableExists("minute"), tableExists("metric") else { return }
        func pivot(_ table: String, tier: Tier) -> String {
            let b = tier.seconds
            let avgs = Metric.allCases.map { "AVG(CASE WHEN m.key='\($0.rawValue)' THEN t.value END)" }.joined(separator: ", ")
            let bt = "CASE WHEN m.key='battery.temp' THEN t.value END"
            return """
                INSERT OR REPLACE INTO samples (tier, ts, n, \(Self.columns.joined(separator: ", ")),
                    battery_temp_min, battery_temp_max, die_peak)
                SELECT '\(tier.rawValue)', (t.ts / \(b)) * \(b), COUNT(DISTINCT t.ts), \(avgs),
                    MIN(\(bt)), MAX(\(bt)), MAX(CASE WHEN m.key='die.max' THEN t.value END)
                FROM \(table) t JOIN metric m ON m.id = t.metric
                WHERE m.key NOT LIKE 'sensor:%' AND m.key NOT LIKE 'fan%.rpm'
                GROUP BY (t.ts / \(b)) * \(b);
                """
        }
        let ok = exec("BEGIN")
            && exec(pivot("raw", tier: .recent))
            && exec(pivot("minute", tier: .minute))
            && exec(pivot("minute", tier: .hour))
            && exec("DROP TABLE raw; DROP TABLE minute; DROP TABLE metric;")
            && exec("COMMIT")
        if ok { exec("VACUUM") } else { exec("ROLLBACK") }
    }

    // MARK: Recording

    private struct Bucket {
        var start: Int64
        var n = 0
        var sums = [Double](repeating: 0, count: Metric.allCases.count)
        var counts = [Int](repeating: 0, count: Metric.allCases.count)
        var batteryMin = Double.infinity, batteryMax = -Double.infinity, diePeak = -Double.infinity

        mutating func add(_ v: [Metric: Double]) {
            n += 1
            for (i, m) in Metric.allCases.enumerated() {
                if let x = v[m] { sums[i] += x; counts[i] += 1 }
            }
            if let t = v[.batteryTemp] { batteryMin = min(batteryMin, t); batteryMax = max(batteryMax, t) }
            if let d = v[.dieMax] { diePeak = max(diePeak, d) }
        }

        func row(_ tier: Tier) -> Row {
            Row(tier: tier, ts: start, n: n,
                values: zip(sums, counts).map { $1 > 0 ? $0 / Double($1) : nil },
                batteryMin: batteryMin.isFinite ? batteryMin : nil,
                batteryMax: batteryMax.isFinite ? batteryMax : nil,
                diePeak: diePeak.isFinite ? diePeak : nil)
        }
    }

    private struct Row {
        let tier: Tier, ts: Int64, n: Int
        let values: [Double?]
        let batteryMin: Double?, batteryMax: Double?, diePeak: Double?
    }

    public func record(_ s: Snapshot) {
        guard openIfNeeded() else { return }
        let ts = Int64(s.date.timeIntervalSince1970)
        let values = Metric.values(from: s)
        for tier in Tier.allCases {
            let start = ts / tier.seconds * tier.seconds
            if var b = buckets[tier], b.start == start {
                b.add(values)
                buckets[tier] = b
            } else {
                if let done = buckets[tier] { pending.append(done.row(tier)) }
                var b = resumed(tier, start: start)   // continue a bucket written before a restart
                b.add(values)
                buckets[tier] = b
            }
        }
        recordHealth(s)
        if s.date.timeIntervalSince(lastWrite) >= 30 { write(); lastWrite = s.date }
        if s.date.timeIntervalSince(lastPrune) >= 3600 { prune(now: s.date); lastPrune = s.date }
    }

    /// Starts a bucket from an existing row (written by flush before quitting), so an hour isn't
    /// overwritten with only the minutes after a restart.
    private func resumed(_ tier: Tier, start: Int64) -> Bucket {
        var b = Bucket(start: start)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let cols = Self.columns.joined(separator: ", ")
        sqlite3_prepare_v2(db, "SELECT n, \(cols), battery_temp_min, battery_temp_max, die_peak FROM samples WHERE tier=?1 AND ts=?2", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, tier.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, start)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return b }
        let n = Int(sqlite3_column_int64(stmt, 0))
        b.n = n
        for i in 0..<Self.columns.count where sqlite3_column_type(stmt, Int32(i + 1)) != SQLITE_NULL {
            b.sums[i] = sqlite3_column_double(stmt, Int32(i + 1)) * Double(n)
            b.counts[i] = n
        }
        let k = Int32(Self.columns.count + 1)
        if sqlite3_column_type(stmt, k) != SQLITE_NULL { b.batteryMin = sqlite3_column_double(stmt, k) }
        if sqlite3_column_type(stmt, k + 1) != SQLITE_NULL { b.batteryMax = sqlite3_column_double(stmt, k + 1) }
        if sqlite3_column_type(stmt, k + 2) != SQLITE_NULL { b.diePeak = sqlite3_column_double(stmt, k + 2) }
        return b
    }

    private func write() {
        guard !pending.isEmpty else { return }
        let cols = Self.columns.joined(separator: ", ")
        let marks = (1...(Self.columns.count + 6)).map { "?\($0)" }.joined(separator: ", ")
        exec("BEGIN")
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO samples (tier, ts, n, \(cols), battery_temp_min, battery_temp_max, die_peak) VALUES (\(marks))", -1, &stmt, nil)
        for r in pending {
            sqlite3_bind_text(stmt, 1, r.tier.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, r.ts)
            sqlite3_bind_int64(stmt, 3, Int64(r.n))
            var i: Int32 = 4
            for v in r.values + [r.batteryMin, r.batteryMax, r.diePeak] {
                if let v { sqlite3_bind_double(stmt, i, v) } else { sqlite3_bind_null(stmt, i) }
                i += 1
            }
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
        sqlite3_finalize(stmt)
        exec("COMMIT")
        pending.removeAll(keepingCapacity: true)
    }

    /// Once per hour: fold the current health into today's mean/min/max. Days imported from the
    /// macOS power log (hundreds of samples per day) are left alone.
    private func recordHealth(_ s: Snapshot) {
        guard let b = s.battery, b.designCapacity > 0, let health = b.health else { return }
        let day = Self.dayString(s.date)
        let key = day + String(Int(s.date.timeIntervalSince1970) / 3600)
        guard key != lastHealthDay else { return }
        lastHealthDay = key
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(db, """
            INSERT INTO battery_daily (day, health, health_min, health_max, n, max_capacity, cycles,
                                       design_mah, raw_max_mah, source)
            VALUES (?1, ?2, ?2, ?2, 1, ?3, ?4, ?5, ?6, 'thermal')
            ON CONFLICT(day) DO UPDATE SET
                health = (health * n + excluded.health) / (n + 1),
                health_min = MIN(COALESCE(health_min, health), excluded.health),
                health_max = MAX(COALESCE(health_max, health), excluded.health),
                n = n + 1, max_capacity = excluded.max_capacity, cycles = excluded.cycles,
                design_mah = excluded.design_mah, raw_max_mah = excluded.raw_max_mah
            WHERE source = 'thermal'
            """, -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, day, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, health)
        if let m = b.maximumCapacity { sqlite3_bind_int64(stmt, 3, Int64(m)) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_int64(stmt, 4, Int64(b.cycleCount))
        sqlite3_bind_int64(stmt, 5, Int64(b.designCapacity))
        sqlite3_bind_int64(stmt, 6, Int64(b.rawMaxCapacity))
        sqlite3_step(stmt)
    }

    // MARK: macOS power log import

    public static let powerLogDirectory = URL(fileURLWithPath: "/private/var/db/powerlog/Library/BatteryLife")

    /// Imports daily battery health from macOS's power log (world-readable, opened read-only).
    /// Archives (`Archives/*.PLSQL.gz`) are imported once and kept even after macOS deletes them;
    /// the current log is re-read on every call. Returns the number of days now backed by the log.
    @discardableResult
    public func importPowerLog(current: URL? = HistoryStore.powerLogDirectory.appendingPathComponent("CurrentPowerlog.PLSQL"),
                               archives: [URL]? = nil) -> Int {
        guard openIfNeeded() else { return 0 }
        let archiveFiles = archives ?? ((try? FileManager.default.contentsOfDirectory(
            at: Self.powerLogDirectory.appendingPathComponent("Archives"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".PLSQL.gz") || $0.lastPathComponent.hasSuffix(".PLSQL") }
        let done = importedPowerLogFiles()
        for url in archiveFiles where !done.contains(url.lastPathComponent) {
            importPowerLogFile(url, as: url.lastPathComponent)
        }
        if let current, FileManager.default.isReadableFile(atPath: current.path) {
            importPowerLogFile(current, as: "current")
        }
        // Rebuild the power-log-backed days from all files (a day can span two files).
        exec("""
            INSERT OR REPLACE INTO battery_daily (day, health, health_min, health_max, n, max_capacity, cycles,
                                                  design_mah, raw_max_mah, source)
            SELECT day, SUM(health_sum) / SUM(n), MIN(health_min), MAX(health_max), SUM(n), MAX(max_capacity),
                   MAX(cycles), MAX(design_mah), MAX(raw_max_mah), 'powerlog'
            FROM powerlog_days GROUP BY day
            """)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(db, "SELECT COUNT(DISTINCT day) FROM powerlog_days", -1, &stmt, nil)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func importedPowerLogFiles() -> Set<String> {
        var out = Set<String>()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(db, "SELECT DISTINCT file FROM powerlog_days", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW { out.insert(String(cString: sqlite3_column_text(stmt, 0))) }
        return out
    }

    private func importPowerLogFile(_ url: URL, as name: String) {
        var path = url.path
        var temp: URL?
        if url.pathExtension == "gz" {
            // Decompress to a temporary file; macOS keeps archives gzipped.
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("thermal-powerlog-\(UUID().uuidString).PLSQL")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            p.arguments = ["-c", url.path]
            guard FileManager.default.createFile(atPath: out.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: out) else { return }
            p.standardOutput = handle
            guard (try? p.run()) != nil else { return }
            p.waitUntilExit()
            try? handle.close()
            guard p.terminationStatus == 0 else { try? FileManager.default.removeItem(at: out); return }
            path = out.path
            temp = out
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }

        var log: OpaquePointer?
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &log, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(log); return
        }
        defer { sqlite3_close(log) }
        var q: OpaquePointer?
        defer { sqlite3_finalize(q) }
        // Private Apple schema: if it changes, the prepare fails and nothing is imported.
        let sql = """
            SELECT date(timestamp, 'unixepoch', 'localtime') AS d,
                   SUM(AppleRawMaxCapacity * 100.0 / DesignCapacity), MIN(AppleRawMaxCapacity * 100.0 / DesignCapacity),
                   MAX(AppleRawMaxCapacity * 100.0 / DesignCapacity), COUNT(*), MAX(MaxCapacity), MAX(CycleCount),
                   MAX(DesignCapacity), CAST(AVG(AppleRawMaxCapacity) AS INTEGER)
            FROM PLBatteryAgent_EventBackward_Battery
            WHERE DesignCapacity > 0 AND AppleRawMaxCapacity > 0
            GROUP BY d
            """
        guard sqlite3_prepare_v2(log, sql, -1, &q, nil) == SQLITE_OK else { return }
        exec("BEGIN")
        exec("DELETE FROM powerlog_days WHERE file = '\(name.replacingOccurrences(of: "'", with: "''"))'")
        var ins: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO powerlog_days VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)", -1, &ins, nil)
        while sqlite3_step(q) == SQLITE_ROW {
            sqlite3_bind_text(ins, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(ins, 2, String(cString: sqlite3_column_text(q, 0)), -1, SQLITE_TRANSIENT)
            for i in 1...3 { sqlite3_bind_double(ins, Int32(i + 2), sqlite3_column_double(q, Int32(i))) }
            for i in 4...8 { sqlite3_bind_int64(ins, Int32(i + 2), sqlite3_column_int64(q, Int32(i))) }
            sqlite3_step(ins)
            sqlite3_reset(ins)
        }
        sqlite3_finalize(ins)
        exec("COMMIT")
    }

    private static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func prune(now: Date) {
        for tier in Tier.allCases {
            guard let keep = tier.retention else { continue }
            exec("DELETE FROM samples WHERE tier='\(tier.rawValue)' AND ts < \(Int64(now.timeIntervalSince1970 - keep))")
        }
    }

    /// Write completed and in-progress buckets (call on quit). In-progress rows are resumed on
    /// the next launch.
    public func flush() {
        guard db != nil else { return }
        for (tier, b) in buckets { pending.append(b.row(tier)) }
        write()
    }

    /// Test hook: prune as if it were `now`.
    func pruneForTesting(now: Date) { prune(now: now) }

    // MARK: Queries

    private func includePendingRows() {
        write()
        // Also show the current, unfinished buckets.
        for (tier, b) in buckets { pending.append(b.row(tier)) }
        write()
    }

    /// Bucketed averages for the given metric keys over the range ending at `now`.
    public func series(_ keys: [String], range: HistoryRange, now: Date = Date()) -> [HistoryPoint] {
        guard openIfNeeded() else { return [] }
        includePendingRows()
        let since = Int64(now.timeIntervalSince1970 - range.seconds)
        let b = range.bucket
        var out: [HistoryPoint] = []
        for key in keys {
            guard let col = Metric(rawValue: key)?.column else { continue }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT (ts / \(b)) * \(b) AS t, SUM(\(col) * n) / SUM(n) FROM samples
                WHERE tier = ?1 AND ts >= ?2 AND \(col) IS NOT NULL GROUP BY t ORDER BY t
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, range.tier.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, since)
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(HistoryPoint(
                    date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0))),
                    metric: key, value: sqlite3_column_double(stmt, 1)))
            }
        }
        return out
    }

    /// Battery temperature min–max per bucket.
    public func batteryBand(range: HistoryRange, now: Date = Date()) -> [HistoryBand] {
        guard openIfNeeded() else { return [] }
        includePendingRows()
        let since = Int64(now.timeIntervalSince1970 - range.seconds)
        let b = range.bucket
        var out: [HistoryBand] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT (ts / \(b)) * \(b) AS t, MIN(battery_temp_min), MAX(battery_temp_max) FROM samples
            WHERE tier = ?1 AND ts >= ?2 AND battery_temp_min IS NOT NULL GROUP BY t ORDER BY t
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, range.tier.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, since)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(HistoryBand(date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0))),
                                   low: sqlite3_column_double(stmt, 1), high: sqlite3_column_double(stmt, 2)))
        }
        return out
    }

    /// All recorded days, oldest first.
    public func batteryHealth() -> [BatteryHealthPoint] {
        guard openIfNeeded() else { return [] }
        var out: [BatteryHealthPoint] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(db, """
            SELECT day, health, COALESCE(health_min, health), COALESCE(health_max, health), max_capacity, cycles,
                   COALESCE(n, 1), COALESCE(source, 'thermal') = 'powerlog'
            FROM battery_daily ORDER BY day
            """, -1, &stmt, nil)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dayText = sqlite3_column_text(stmt, 0), let day = f.date(from: String(cString: dayText)) else { continue }
            out.append(BatteryHealthPoint(
                day: day, health: sqlite3_column_double(stmt, 1),
                low: sqlite3_column_double(stmt, 2), high: sqlite3_column_double(stmt, 3),
                maximumCapacity: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 4)),
                cycles: Int(sqlite3_column_int64(stmt, 5)),
                samples: Int(sqlite3_column_int64(stmt, 6)),
                fromPowerLog: sqlite3_column_int64(stmt, 7) != 0))
        }
        return out
    }

    public struct Stats: Sendable {
        public let rows: [String: Int]
        public let bytes: Int
        public let since: Date?
    }

    public func stats() -> Stats {
        guard openIfNeeded() else { return Stats(rows: [:], bytes: 0, since: nil) }
        var rows: [String: Int] = [:]
        var since: Date?
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT tier, COUNT(*), MIN(ts) FROM samples GROUP BY tier", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tier = String(cString: sqlite3_column_text(stmt, 0))
            rows[tier] = Int(sqlite3_column_int64(stmt, 1))
            let first = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 2)))
            since = min(since ?? first, first)
        }
        sqlite3_finalize(stmt)
        let fm = FileManager.default
        let bytes = [url.path, url.path + "-wal"].compactMap { (try? fm.attributesOfItem(atPath: $0)[.size]) as? Int }.reduce(0, +)
        return Stats(rows: rows, bytes: bytes, since: since)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
