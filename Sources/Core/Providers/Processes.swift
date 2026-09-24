import Foundation

struct ProcInfo: Codable, Identifiable {
    var pid: Int
    var cpu: Double        // %CPU（相对单核，Activity Monitor 口径）
    var mem: Double        // %MEM
    var name: String
    var id: Int { pid }
}

/// 进程 TOP：走 `ps`（只读）。只在有详情页打开时才采样（见 Sampler 的按需开关）。
enum ProcessesProvider {
    static func byCPU(limit: Int = 8) -> [ProcInfo] {
        parse(Shell.run("/bin/ps", ["-Aceo", "pid,pcpu,pmem,comm", "-r"]), limit: limit)
    }

    static func byMemory(limit: Int = 8) -> [ProcInfo] {
        let rows = parse(Shell.run("/bin/ps", ["-Aceo", "pid,pcpu,pmem,comm", "-m"]), limit: 60)
        return Array(rows.sorted { $0.mem > $1.mem }.prefix(limit))
    }

    private static func parse(_ output: String, limit: Int) -> [ProcInfo] {
        var rows: [ProcInfo] = []
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int(parts[0]),
                  let cpu = Double(parts[1]),
                  let mem = Double(parts[2]) else { continue }
            rows.append(ProcInfo(pid: pid, cpu: cpu, mem: mem, name: String(parts[3])))
            if rows.count >= limit { break }
        }
        return rows
    }
}
