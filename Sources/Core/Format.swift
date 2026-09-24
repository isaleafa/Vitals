import Foundation

/// 数值格式化（UI 与 --dump 共用）。
enum Fmt {
    static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_000_000_000
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(b) / 1_000_000)
    }

    static func gb(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / 1_073_741_824) }

    static func rate(_ bps: Double) -> String {
        if bps >= 1_048_576 { return String(format: "%.1f MB/s", bps / 1_048_576) }
        if bps >= 1024 { return String(format: "%.0f KB/s", bps / 1024) }
        return String(format: "%.0f B/s", bps)
    }

    static func percent(_ v: Double) -> String { String(format: "%.1f%%", v) }

    static func pct0(_ v: Double) -> String { String(format: "%.0f%%", v) }

    static func duration(_ t: TimeInterval) -> String {
        let d = Int(t) / 86_400, h = (Int(t) % 86_400) / 3600, m = (Int(t) % 3600) / 60
        return d > 0 ? "\(d)天\(h)小时" : "\(h)小时\(m)分"
    }
}
