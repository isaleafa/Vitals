import Foundation

/// SSD 健康摘要：走 `smartctl -a /dev/disk0`（本机实测无需 sudo，约 60ms）。
/// 字段名在界面上一律用中文；返回**有序**数组（顺序固定，不按字母排）。
enum SmartProvider {
    private static let fields: [(key: String, label: String)] = [
        ("Model Number", "型号"),
        ("Firmware Version", "固件版本"),
        ("Percentage Used", "损耗百分比"),
        ("Available Spare", "可用备用块"),
        ("Temperature", "温度"),
        ("Data Units Written", "累计写入"),
        ("Power On Hours", "通电时长"),
        ("Power Cycles", "通电次数"),
        ("Unsafe Shutdowns", "异常断电次数"),
        ("Media and Data Integrity Errors", "介质/数据完整性错误"),
    ]

    static func read() -> [(label: String, value: String)] {
        guard let path = Shell.which("smartctl") else {
            return [("状态", "未找到 smartctl（brew install smartmontools）")]
        }
        let output = Shell.run(path, ["-a", "/dev/disk0"], timeout: 3)
        guard !output.isEmpty else {
            return [("状态", "smartctl 无输出（可能没有读取 /dev/disk0 的权限）")]
        }

        var raw: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            for field in fields where text.hasPrefix(field.key + ":") {   // 必须精确到冒号，
                let value = text.dropFirst(field.key.count + 1)          // 否则 "Available Spare"
                raw[field.key] = value.trimmingCharacters(in: .whitespaces)  // 会误抓 "Available Spare Threshold"
            }
        }
        if raw.isEmpty {
            return [("状态", "smartctl 未返回可解析的字段")]
        }

        return fields.compactMap { field in
            guard let value = raw[field.key] else { return nil }
            return (label: field.label, value: prettify(key: field.key, value: value))
        }
    }

    /// 数值清洗：温度换成 °C、累计写入取人类可读值、纯数字的加上单位。
    private static func prettify(key: String, value: String) -> String {
        var text = value
        switch key {
        case "Temperature":
            text = text.replacingOccurrences(of: " Celsius", with: " °C")
        case "Data Units Written":
            if let start = text.firstIndex(of: "["), let end = text.firstIndex(of: "]") {
                text = String(text[text.index(after: start)..<end])
            }
        case "Power On Hours":
            if text.allSatisfy(\.isNumber) { text += " 小时" }
        case "Power Cycles", "Unsafe Shutdowns", "Media and Data Integrity Errors":
            if text.allSatisfy(\.isNumber) { text += " 次" }
        default:
            break
        }
        return text
    }
}
