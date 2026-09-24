import Foundation

/// 历史记录：每分钟一条，落到 `~/Library/Application Support/Vitals/history/YYYY-MM-DD.jsonl`。
struct HistoryRecord: Codable {
    var t: Int          // unix 秒（对齐到分钟）
    var cpu: Double     // %
    var mem: Double     // GB 已用
    var press: Int      // 内存压力
    var swap: Double    // MB
    var dr: Double      // 磁盘读 MB/s
    var dw: Double      // 磁盘写 MB/s
    var nrx: Double     // 网络下行 KB/s（全接口合计）
    var ntx: Double     // 网络上行 KB/s
    var pin: Double     // 输入功率 W（接电时）
    var pdis: Double    // 放电功率 W（电池时）
    var chg: Int        // 电量 %
    var cc: Double?     // CPU 温度（2026-09-24 起才有，老的记录里没有）
    var h: Double?      // 电池健康度-官方口径 %
    var hr: Double?     // 电池健康度-容量比 %
    var cap: Double?    // 当前满充容量 mAh
    var cyc: Double?    // 循环次数
}

/// 曲线上的一个点（已按周期聚合）。
struct HistoryPoint: Identifiable {
    var t: Int
    var value: Double
    var id: Int { t }

    var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }
}

/// 时间跨度。
enum HistoryPeriod: String, CaseIterable, Identifiable {
    case hour = "1 小时"
    case day = "24 小时"
    case week = "7 天"
    case month = "30 天"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }

    /// 聚合桶大小：让点数落在 120 ~ 240 之间。
    var bucketSeconds: TimeInterval {
        switch self {
        case .hour: return 60          // 60 点（每分钟）
        case .day: return 300          // 288 点（每 5 分钟）
        case .week: return 3600        // 168 点（每小时）
        case .month: return 6 * 3600   // 120 点（每 6 小时）
        }
    }
}

/// 一个周期下、页面上要用的所有序列（在后台线程算好，UI 直接画）。
struct HistoryBundle {
    var cpu: [HistoryPoint] = []
    var mem: [HistoryPoint] = []
    var diskRead: [HistoryPoint] = []
    var diskWrite: [HistoryPoint] = []
    var netRx: [HistoryPoint] = []
    var netTx: [HistoryPoint] = []
    var powerIn: [HistoryPoint] = []
    var powerDis: [HistoryPoint] = []
    var cpuTemp: [HistoryPoint] = []
    var healthOfficial: [HistoryPoint] = []
    var healthRaw: [HistoryPoint] = []
    var cycleCount: [HistoryPoint] = []

    var isEmpty: Bool { cpu.isEmpty }

    static func build(period: HistoryPeriod) -> HistoryBundle {
        let records = HistoryStore.shared.records(within: period.seconds)
        guard !records.isEmpty else { return HistoryBundle() }
        let bucket = period.bucketSeconds
        func series(_ metric: (HistoryRecord) -> Double?) -> [HistoryPoint] {
            var sums: [Int: Double] = [:]
            var counts: [Int: Int] = [:]
            for record in records {
                guard let value = metric(record) else { continue }   // 缺字段的记录直接跳过，不补 0
                let key = Int(Double(record.t) / bucket) * Int(bucket)
                sums[key, default: 0] += value
                counts[key, default: 0] += 1
            }
            return sums.keys.sorted().map { key in
                HistoryPoint(t: key, value: (sums[key] ?? 0) / Double(counts[key] ?? 1))
            }
        }
        var bundle = HistoryBundle()
        bundle.cpu = series { $0.cpu }
        bundle.mem = series { $0.mem }
        bundle.diskRead = series { $0.dr }
        bundle.diskWrite = series { $0.dw }
        bundle.netRx = series { $0.nrx }
        bundle.netTx = series { $0.ntx }
        bundle.powerIn = series { $0.pin }
        bundle.powerDis = series { $0.pdis }
        bundle.cpuTemp = series { $0.cc }
        bundle.healthOfficial = series { $0.h }
        bundle.healthRaw = series { $0.hr }
        bundle.cycleCount = series { $0.cyc }
        return bundle
    }
}

/// 历史存储：按天一个 JSONL 文件，追加写；读的时候按天缓存。
final class HistoryStore {
    static let shared = HistoryStore()

    private let directory: URL
    private let queue = DispatchQueue(label: "vitals.history", qos: .utility)
    private var cache: [String: [HistoryRecord]] = [:]
    let keepDays = 30

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directory = base.appendingPathComponent("Vitals/history", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - 写

    func append(_ record: HistoryRecord) {
        queue.async { [directory] in
            let url = directory.appendingPathComponent(Self.fileName(for: record.t))
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(record) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data + Data([0x0A]))
            } else {
                try? (data + Data([0x0A])).write(to: url)
            }
        }
    }

    /// 删除超过保留期的文件（启动时 + 每天调用一次都行）。
    func prune() {
        queue.async { [directory, keepDays] in
            let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
            let formatter = Self.fileFormatter
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let date = formatter.date(from: file.deletingPathExtension().lastPathComponent) else { continue }
                if date < cutoff { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    // MARK: - 读

    /// 取最近 `within` 秒内的记录（按天读文件 + 内存缓存；后台线程也会调，做了锁）。
    func records(within seconds: TimeInterval) -> [HistoryRecord] {
        let now = Date()
        let cutoff = Int(now.timeIntervalSince1970 - seconds)
        var result: [HistoryRecord] = []
        let days = Int(seconds / 86_400) + 1
        for offset in 0..<max(1, days + 1) {
            let day = Int(now.timeIntervalSince1970) - offset * 86_400
            result.append(contentsOf: cachedRecords(for: day))
        }
        return result.filter { $0.t >= cutoff }.sorted { $0.t < $1.t }
    }

    private func cachedRecords(for timestamp: Int) -> [HistoryRecord] {
        let name = Self.fileName(for: timestamp)
        return queue.sync {
            if let cached = cache[name] { return cached }
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                cache[name] = []
                return []
            }
            let decoder = JSONDecoder()
            let records = text.split(separator: "\n").compactMap { line -> HistoryRecord? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(HistoryRecord.self, from: data)
            }
            cache[name] = records
            return records
        }
    }

    /// 让"当天"的缓存失效（刚追加过，下次读取要重新读盘）。
    func invalidateToday() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cache[Self.fileName(for: Int(Date().timeIntervalSince1970))] = nil
        }
    }

    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func fileName(for timestamp: Int) -> String {
        fileFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp))) + ".jsonl"
    }
}
