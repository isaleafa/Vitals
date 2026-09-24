import Foundation

/// `Vitals --dump`：命令行模式——采两帧（间隔 1 秒）算出差分，打印一帧 JSON 后退出。
/// 用来和 `probes/` 的输出对账，也是没有 Xcode 时的主要调试手段。
enum DumpMode {
    static func run() {
        let before = RawCounters.collect()
        Thread.sleep(forTimeInterval: 1.0)
        let after = RawCounters.collect()
        var snapshot = DiffEngine.snapshot(prev: before, cur: after)

        // 低频项（正式跑时由 Sampler 定时补充，这里为了一次性核对也带上）
        // 拔电时没有适配器身份可读，别把缓存里的旧值填进来
        if snapshot.power.externalPower, let pd = PDIdentity.read() {
            snapshot.power.adapterVID = pd.vendorID
            snapshot.power.adapterPID = pd.productID
            snapshot.power.pdRevision = pd.specRevision
        }
        if let health = PowerProvider.officialHealth() {
            snapshot.power.healthOfficialPercent = health.percent
            snapshot.power.healthOfficialText = health.text
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot), let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            print("{\"error\": \"encode failed\"}")
        }
    }

    /// `Vitals --bench [次数]`：逐 Provider 测单次采集耗时，找热点。
    static func bench(iterations: Int = 50) {
        _ = RawCounters.collect()   // 预热（第一次会匹配 IOKit 服务、建缓存）
        let n = max(1, iterations)
        var results: [(String, Double)] = []

        func measure(_ name: String, _ block: () -> Void) {
            let start = Date()
            for _ in 0..<n { block() }
            results.append((name, Date().timeIntervalSince(start) / Double(n) * 1000))
        }

        measure("CPU") { _ = CPUProvider.read() }
        measure("内存") { _ = MemoryProvider.read() }
        measure("磁盘计数") { _ = DiskProvider.readCounters() }
        measure("磁盘容量") { _ = DiskProvider.capacity() }
        measure("网络") { _ = NetworkProvider.read() }
        measure("电源") { _ = PowerProvider.read() }
        measure("负载+开机") { _ = Sysctl.loadAverage(); _ = Sysctl.uptime() }
        measure("合计 collect()") { _ = RawCounters.collect() }

        print("每次调用耗时（\(n) 次平均）:")
        for (name, ms) in results {
            print(String(format: "  %@ %7.3f ms", name.padding(toLength: 14, withPad: " ", startingAt: 0), ms))
        }
    }
}
