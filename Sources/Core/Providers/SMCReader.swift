import Foundation
import IOKit

/// SMC（AppleSMC）读取器 —— 按成熟实现 **macmon**（`src_lib/sources.rs` 的 `SMC`）1:1 移植。
///
/// 为什么需要它：IOHIDEventSystem（见 `HIDSensors`）在 M2 上给不到 GPU 温度，而 SMC 的
/// `Tg*` 键可以（macmon 对 M2/M3 就是走 SMC 的：CPU = `Tp*`/`Te*`/`Ts*`，GPU = `Tg*`，风扇 = `F*Ac`，
/// 且只认 4 字节 `flt` 类型）。
///
/// 协议要点（照抄 macmon，别自己发挥）：
/// - 打开的服务是 **`AppleSMCKeysEndpoint`**（不是 `AppleSMC` 本身）；`IOServiceOpen(..., 0, ...)`
/// - 数据交换：`IOConnectCallStructMethod(conn, selector=2, ...)`，结构 80 字节
/// - 命令走 `data8`：`5`=读值、`8`=按键号读键名、`9`=读键信息
/// - `result`（偏移 40）非 0 即失败（132 = 键不存在）
final class SMCReader {
    static let shared = SMCReader()

    private var connection: io_connect_t = 0
    private var keyInfoCache: [String: (size: UInt32, type: UInt32)] = [:]
    private let structSize = 80
    private let floatType: UInt32 = 0x666C7420   // "flt "

    private init() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &nameBuffer)
            guard String(cString: nameBuffer) == "AppleSMCKeysEndpoint" else { continue }
            var conn: io_connect_t = 0
            if IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS {
                connection = conn
                return
            }
        }
    }

    var isAvailable: Bool { connection != 0 }

    // MARK: - 协议

    private func keyInt(_ key: String) -> UInt32? {
        guard key.utf8.count == 4 else { return nil }
        return key.utf8.reduce(0) { ($0 << 8) + UInt32($1) }
    }

    private func exchange(_ input: [UInt8]) -> [UInt8]? {
        guard connection != 0 else { return nil }
        var mutableInput = input
        var output = [UInt8](repeating: 0, count: structSize)
        var outputSize = structSize
        let result = mutableInput.withUnsafeBytes { inputBuffer -> kern_return_t in
            output.withUnsafeMutableBytes { outputBuffer in
                IOConnectCallStructMethod(connection, 2,
                                          inputBuffer.baseAddress, structSize,
                                          outputBuffer.baseAddress, &outputSize)
            }
        }
        guard result == KERN_SUCCESS, output[40] == 0 else { return nil }
        return output
    }

    private func makeInput(key: UInt32?, keyInfo: (size: UInt32, type: UInt32)?, command: UInt8, index: UInt32? = nil) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: structSize)
        if let key {
            // ⚠️ 键要按**小端**写入（macmon 把键打包成大端 u32 再写内存，在小端机上就是反序字节）。
            // 写错顺序的后果是每个键都返回 132「键不存在」（2026-09-24 实测踩过）。
            buffer[0] = UInt8(key & 0xFF);         buffer[1] = UInt8((key >> 8) & 0xFF)
            buffer[2] = UInt8((key >> 16) & 0xFF); buffer[3] = UInt8((key >> 24) & 0xFF)
        }
        if let keyInfo {
            for (offset, value) in [(28, keyInfo.size), (32, keyInfo.type)] {
                buffer[offset] = UInt8(value & 0xFF)
                buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
                buffer[offset + 2] = UInt8((value >> 16) & 0xFF)
                buffer[offset + 3] = UInt8((value >> 24) & 0xFF)
            }
        }
        buffer[42] = command
        if let index {
            buffer[44] = UInt8(index & 0xFF); buffer[45] = UInt8((index >> 8) & 0xFF)
            buffer[46] = UInt8((index >> 16) & 0xFF); buffer[47] = UInt8((index >> 24) & 0xFF)
        }
        return buffer
    }

    private func keyInfo(_ key: String) -> (size: UInt32, type: UInt32)? {
        if let cached = keyInfoCache[key] { return cached }
        guard let keyInt = keyInt(key),
              let output = exchange(makeInput(key: keyInt, keyInfo: nil, command: 9)) else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(output[offset]) | UInt32(output[offset + 1]) << 8
                | UInt32(output[offset + 2]) << 16 | UInt32(output[offset + 3]) << 24
        }
        let info = (size: u32(28), type: u32(32))
        keyInfoCache[key] = info
        return info
    }

    /// 读一个四字节 float 键（`flt `）。macmon 对所有温度键都这么读。
    func readFloat(_ key: String) -> Double? {
        guard let keyInt = keyInt(key), let info = keyInfo(key),
              info.size == 4, info.type == floatType,
              let output = exchange(makeInput(key: keyInt, keyInfo: info, command: 5)) else { return nil }
        let bytes = Array(output[48..<52])
        let value = bytes.withUnsafeBytes { $0.load(as: Float.self) }   // 小端
        guard value.isFinite else { return nil }
        return Double(value)
    }

    /// 全部键名（`#KEY` 给出数量，再按键号逐个取）。
    func allKeys() -> [String] {
        guard let count = readUInt32("#KEY") else { return [] }
        var keys: [String] = []
        for index in 0..<min(count, 4096) {
            guard let output = exchange(makeInput(key: nil, keyInfo: nil, command: 8, index: index)) else { continue }
            let bytes = Array(output[0..<4].reversed())   // 输出也是小端，取名字要对调回来
            guard let name = String(bytes: bytes, encoding: .ascii), name.count == 4 else { continue }
            keys.append(name)
        }
        return keys
    }

    /// 读 32 位整数键（如 `#KEY`）。
    func readUInt32(_ key: String) -> UInt32? {
        guard let keyInt = keyInt(key), let info = keyInfo(key),
              let output = exchange(makeInput(key: keyInt, keyInfo: info, command: 5)) else { return nil }
        var value: UInt32 = 0
        for index in 0..<min(Int(info.size), 4) {
            value |= UInt32(output[48 + index]) << (8 * index)
        }
        return value
    }

    // MARK: - 温度（macmon 的键规则）

    enum SensorGroup { case cpu, gpu }

    private var cachedGroups: (cpu: [String], gpu: [String], fans: [String])?

    /// 按 macmon 的规则取平均：CPU = `Tp*`/`Te*`/`Ts*`，GPU = `Tg*`（只认 4 字节 float，过滤 0~150）。
    func averageTemperature(_ group: SensorGroup) -> Double? {
        var cache: [String: [String]] = [:]
        let keys = temperatureKeys(cache: &cache)
        let list = group == .gpu ? keys.gpu : keys.cpu
        let values = list.compactMap { readFloat($0) }.filter { $0 > 0 && $0 < 150 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// 按 macmon 的规则分类：CPU = `Tp*`/`Te*`/`Ts*`，GPU = `Tg*`，风扇 = `F*Ac`（只要 4 字节 float）。
    func temperatureKeys(cache: inout [String: [String]]) -> (cpu: [String], gpu: [String], fans: [String]) {
        if let cachedGroups { return cachedGroups }
        if let cpu = cache["cpu"] { return (cpu, cache["gpu"] ?? [], cache["fans"] ?? []) }
        var cpu: [String] = [], gpu: [String] = [], fans: [String] = []
        for name in allKeys() {
            if name.count == 4, name.hasPrefix("F"), name.hasSuffix("Ac") {
                fans.append(name)
                continue
            }
            let isCPU = name.hasPrefix("Tp") || name.hasPrefix("Te") || name.hasPrefix("Ts")
            let isGPU = name.hasPrefix("Tg")
            guard isCPU || isGPU else { continue }
            guard let info = keyInfo(name), info.size == 4, info.type == floatType else { continue }
            if isCPU { cpu.append(name) } else { gpu.append(name) }
        }
        let result = (cpu: cpu.sorted(), gpu: gpu.sorted(), fans: fans.sorted())
        cachedGroups = result
        cache["cpu"] = result.cpu; cache["gpu"] = result.gpu; cache["fans"] = result.fans
        return result
    }
}
