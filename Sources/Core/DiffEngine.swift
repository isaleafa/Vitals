import Foundation

/// 差分引擎：原始计数器（两帧）→ 一帧 Snapshot。
/// 所有速率类指标（CPU%、磁盘/网络 MB/s）都是两次采样取差，不依赖任何"瞬时值"。
enum DiffEngine {
    static func snapshot(prev: RawCounters?, cur: RawCounters) -> Snapshot {
        var s = Snapshot()
        s.time = Date(timeIntervalSince1970: cur.t)
        let dt = max(cur.t - (prev?.t ?? cur.t), 0.001)

        // ── CPU ──
        if let curCPU = cur.cpu {
            if let prevCPU = prev?.cpu, prevCPU.count == curCPU.count {
                let per = CPUProvider.usage(prev: prevCPU, cur: curCPU)
                s.cpu.perCore = per
                s.cpu.total = per.isEmpty ? 0 : per.reduce(0, +) / Double(per.count)
            }
            s.cpu.load = Sysctl.loadAverage()
            s.cpu.uptime = Sysctl.uptime()
        }

        // ── 内存（瞬时值）──
        if let m = cur.memory {
            s.memory.totalBytes = m.total
            s.memory.usedBytes = m.active + m.wired + m.compressor
            s.memory.availBytes = m.free + m.inactive
            s.memory.compressedBytes = m.compressor
            s.memory.swapUsedBytes = m.swapUsed
            s.memory.pressure = Int(m.pressure)
        }

        // ── 磁盘 ──
        if let cap = cur.diskCap {
            s.disk.totalBytes = cap.total
            s.disk.freeBytes = cap.free
        }
        if let d = cur.disk, let p = prev?.disk {
            s.disk.readBps = Double(d.readBytes &- p.readBytes) / dt
            s.disk.writeBps = Double(d.writeBytes &- p.writeBytes) / dt
            s.disk.iops = Double(d.ops &- p.ops) / dt
        }

        // ── 网络（速率 + 活跃/空闲分类）──
        var all: [NetIface] = []
        var active: [NetIface] = []
        for (name, c) in cur.net {
            var i = NetIface(name: name)
            i.up = c.up
            i.addrs = c.addrs
            i.peer = c.peer
            i.mac = c.mac
            i.mtu = c.mtu
            i.rxTotal = UInt64(c.rx)
            i.txTotal = UInt64(c.tx)
            if let p = prev?.net[name] {
                // struct if_data 是 32 位计数器，4GiB 回绕 → 用 &- 再取模
                i.rxBps = Double(UInt64(c.rx &- p.rx)) / dt
                i.txBps = Double(UInt64(c.tx &- p.tx)) / dt
            }
            let hasV4 = c.addrs.contains { !$0.contains(":") }
            i.idle = !(hasV4 || (UInt64(c.rx) + UInt64(c.tx)) >= 1_000_000)
            all.append(i)
            if !i.idle { active.append(i) }
        }
        active.sort { ($0.rxBps + $0.txBps) > ($1.rxBps + $1.txBps) }
        all.sort { ($0.idle ? 1 : 0, $0.name) < ($1.idle ? 1 : 0, $1.name) }   // 活跃在前，其余按名字
        s.net.interfaces = active
        s.net.allInterfaces = all

        // ── 电源（瞬时值）──
        if let p = cur.power { s.power = p }

        // ── 功耗明细（IOReport，读不到的留空）──
        let energy = IOReportEnergy.shared.read()
        s.energy = EnergyStats(gpuWatts: energy.gpuWatts, cpuWatts: energy.cpuWatts)
        s.thermal = HIDSensors.shared.read()

        return s
    }
}
