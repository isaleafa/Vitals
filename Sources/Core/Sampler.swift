import AppKit
import Foundation

/// 采样器：1 秒 tick，跑各 Provider → 差分 → 写 AppState。
///
/// 线程模型（关键）：
/// - **主线程**只做毫秒级原生采样（Mach/IOKit/getifaddrs，约 0.27ms）；
/// - 一切**要开子进程**的采样（netstat / lsof / ps / smartctl / system_profiler）和
///   IOKit 大树遍历（PD 身份）都丢到后台串行队列，算完再回主线程赋值——
///   否则主线程会被 `lsof` 这类命令堵住几百毫秒到几秒，界面直接卡住（2026-09-23 踩过）。
final class Sampler {
    var interval: TimeInterval = 1

    private var timer: Timer?
    private var previous: RawCounters?
    private let state: AppState
    private var tickCount = 0
    private let workQueue = DispatchQueue(label: "vitals.onDemand", qos: .utility)

    // 低频项缓存：每帧都填进快照（只在到点时刷新），否则下一帧就丢了
    private var pdInfo: PDIdentity.Info?
    private var officialHealth: (percent: Int?, text: String?)?
    private var lastExternalPower: Bool?
    private var lastWantRoutes = false
    private var lastWantProcesses = false
    private var lastWantSmart = false

    // 每分钟一条历史记录：这一分钟内逐秒累加，整分时求平均写盘
    private var accumulator = MinuteAccumulator()

    private struct MinuteAccumulator {
        var count = 0
        var cpu = 0.0, mem = 0.0, swap = 0.0
        var dr = 0.0, dw = 0.0
        var nrx = 0.0, ntx = 0.0
        var pin = 0.0, pdis = 0.0
        var press = 1, charge = 0
        var cpuTemp = 0.0
        var cpuTempCount = 0
        var healthOfficial = 0.0, healthOfficialCount = 0
        var healthRaw = 0.0, healthRawCount = 0
        var capacity = 0.0, capacityCount = 0
        var cycles = 0

        mutating func add(_ snapshot: Snapshot) {
            count += 1
            cpu += snapshot.cpu.total
            mem += Double(snapshot.memory.usedBytes) / 1_073_741_824
            swap += Double(snapshot.memory.swapUsedBytes) / 1_048_576
            dr += snapshot.disk.readBps / 1_048_576
            dw += snapshot.disk.writeBps / 1_048_576
            nrx += snapshot.net.interfaces.reduce(0) { $0 + $1.rxBps } / 1024
            ntx += snapshot.net.interfaces.reduce(0) { $0 + $1.txBps } / 1024
            pin += snapshot.power.inputWatts
            pdis += snapshot.power.dischargeWatts
            press = snapshot.memory.pressure
            charge = snapshot.power.charge
            if let temp = snapshot.thermal.cpuTemp {
                cpuTemp += temp
                cpuTempCount += 1
            }
            if let value = snapshot.power.healthOfficialPercent {
                healthOfficial += Double(value); healthOfficialCount += 1
            }
            if let value = snapshot.power.healthRawPercent {
                healthRaw += value; healthRawCount += 1
            }
            if let value = snapshot.power.fullChargeCapacity {
                capacity += Double(value); capacityCount += 1
            }
            if let value = snapshot.power.cycles { cycles = value }
        }

        func record(minute: Int) -> HistoryRecord? {
            guard count > 0 else { return nil }
            let n = Double(count)
            return HistoryRecord(t: minute, cpu: cpu / n, mem: mem / n, press: press, swap: swap / n,
                                 dr: dr / n, dw: dw / n, nrx: nrx / n, ntx: ntx / n,
                                 pin: pin / n, pdis: pdis / n, chg: charge,
                                 cc: cpuTempCount > 0 ? cpuTemp / Double(cpuTempCount) : nil,
                                 h: healthOfficialCount > 0 ? healthOfficial / Double(healthOfficialCount) : nil,
                                 hr: healthRawCount > 0 ? healthRaw / Double(healthRawCount) : nil,
                                 cap: capacityCount > 0 ? capacity / Double(capacityCount) : nil,
                                 cyc: cycles > 0 ? Double(cycles) : nil)
        }
    }

    init(state: AppState) { self.state = state }

    func start() {
        stop()
        state.onNetworkPageOpened = { [weak self] in
            self?.refreshRoutes()
            self?.refreshProxy(withListener: true)
        }
        state.onHistoryReloadNeeded = { [weak self] in self?.refreshHistory() }
        state.runNetworkChecks = { [weak self] in self?.startNetworkChecks() }
        state.probeSSHHosts = { [weak self] in self?.startSSHProbe() }
        state.refreshLaunchItems = { [weak self] in
            self?.workQueue.async {
                let items = LaunchItemsProvider.read()
                self?.onMain { self?.state.launchItems = items }
            }
        }

        // 启动时清一次过期历史（保留 30 天）并把曲线数据读出来
        HistoryStore.shared.prune()
        refreshHistory()

        // 睡眠唤醒：差分基线重置，避免醒来第一帧出现假尖峰（速率指标）
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.previous = nil
            self.accumulator = MinuteAccumulator()
        }

        tick()   // 立即采一帧（首帧没有速率，只有瞬时值）
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()   // Timer 回调本来就在主线程
        }
        RunLoop.main.add(timer, forMode: .common)   // .common：菜单打开时也继续刷
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 主线程：轻量采样

    private func tick() {
        let raw = RawCounters.collect()
        var snapshot = DiffEngine.snapshot(prev: previous, cur: raw)
        previous = raw
        tickCount += 1

        if let pd = pdInfo {
            snapshot.power.adapterVID = pd.vendorID
            snapshot.power.adapterPID = pd.productID
            snapshot.power.pdRevision = pd.specRevision
        }
        if let health = officialHealth {
            snapshot.power.healthOfficialPercent = health.percent
            snapshot.power.healthOfficialText = health.text
        }
        state.apply(snapshot)

        // 历史：整分写盘 + 刷新曲线
        accumulator.add(snapshot)
        if tickCount % 60 == 0, let record = accumulator.record(minute: alignedMinute()) {
            HistoryStore.shared.append(record)
            HistoryStore.shared.invalidateToday()
            accumulator = MinuteAccumulator()
            refreshHistory()
        }

        // 插拔电：插上立刻刷新 PD 身份；拔掉就清掉（别让页面显示过期的适配器信息）
        if lastExternalPower != snapshot.power.externalPower {
            lastExternalPower = snapshot.power.externalPower
            if snapshot.power.externalPower {
                refreshPDIdentity()
            } else {
                pdInfo = nil
            }
        }

        // 低频 / 按需项：全部转到后台
        if tickCount == 1 || tickCount % 60 == 0 { refreshPDIdentity() }
        if tickCount == 2 || tickCount % 300 == 0 { refreshOfficialHealth() }

        // 页面刚打开（开关 false→true）：立刻采一次，别让用户对着"读取中…"等 30 秒
        if state.wantRoutes && !lastWantRoutes {
            refreshRoutes()
            refreshProxy(withListener: true)
            refreshServices()
        }
        if state.wantProcesses && !lastWantProcesses { refreshProcesses() }
        if state.wantSmart && !lastWantSmart { refreshSmart() }
        lastWantRoutes = state.wantRoutes
        lastWantProcesses = state.wantProcesses
        lastWantSmart = state.wantSmart

        // 页面保持打开时的定时刷新
        if state.wantRoutes {
            if tickCount % 3 == 0 { refreshRoutes() }
            if tickCount % 15 == 0 {
                refreshProxy(withListener: true)   // lsof 稍贵，低频
                refreshServices()
            }
        }
        if state.wantProcesses, tickCount % 5 == 0 { refreshProcesses() }
        if state.wantSmart, tickCount % 30 == 0 { refreshSmart() }
    }

    // MARK: - 后台：子进程 / 大树遍历，算完回主线程赋值

    private func onMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private func refreshPDIdentity() {
        workQueue.async { [weak self] in
            let info = PDIdentity.read()
            guard let info else { return }
            self?.onMain { self?.pdInfo = info }
        }
    }

    private func refreshOfficialHealth() {
        workQueue.async { [weak self] in
            let health = PowerProvider.officialHealth()
            guard let health else { return }
            self?.onMain { self?.officialHealth = health }
        }
    }

    private func refreshRoutes() {
        workQueue.async { [weak self] in
            let v4 = RoutesProvider.read(family: "inet")
            let v6 = RoutesProvider.read(family: "inet6")
            let defaultIface = v4.first { $0.dest == "default" }?.iface
            self?.onMain {
                self?.state.routes = v4
                self?.state.routes6 = v6
                self?.state.defaultRouteIface = defaultIface
            }
        }
    }

    private func refreshProxy(withListener: Bool) {
        workQueue.async { [weak self] in
            var proxy = ProxyProvider.read()
            if withListener, let port = proxy.port {
                proxy.processName = ProxyProvider.listenerName(port: port)
            }
            self?.onMain { self?.state.proxy = proxy }
        }
    }

    private func refreshProcesses() {
        workQueue.async { [weak self] in
            let byCPU = ProcessesProvider.byCPU()
            let byMemory = ProcessesProvider.byMemory()
            self?.onMain {
                self?.state.processesByCPU = byCPU
                self?.state.processesByMemory = byMemory
            }
        }
    }

    private func refreshSmart() {
        workQueue.async { [weak self] in
            let smart = SmartProvider.read()
            self?.onMain { self?.state.smart = smart }
        }
    }

    /// SSH 主机探测：读 ~/.ssh/config 后**并发**探每一台（串行会太慢）。
    private func startSSHProbe() {
        guard !state.sshProbing else { return }
        state.sshProbing = true
        var hosts = SSHHostsProvider.parse()
        state.sshHosts = hosts
        guard !hosts.isEmpty else {
            state.sshProbing = false
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [String: (Bool, Double?)] = [:]   // 并发只往字典里写（加锁），别并发改同一个数组
        for host in hosts {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let outcome = SSHHostsProvider.probe(host)
                lock.lock()
                results[host.alias] = outcome
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            for index in hosts.indices {
                if let outcome = results[hosts[index].alias] {
                    hosts[index].reachable = outcome.0
                    hosts[index].latencyMS = outcome.1
                }
            }
            self.state.sshHosts = hosts
            self.state.sshProbing = false
        }
    }

    /// 监听端口清单（lsof，后台）
    private func refreshServices() {
        workQueue.async { [weak self] in
            let services = ListeningPortsProvider.read()
            self?.onMain { self?.state.services = services }
        }
    }

    /// 网络体检：逐条在后台上跑（ping/dig/curl），跑完一条回填一条。
    private func startNetworkChecks() {
        guard !state.checksRunning else { return }
        state.checksRunning = true
        let items = NetworkCheckProvider.items().map { NetworkCheckResult(id: $0.id, title: $0.title) }
        state.checks = items
        let proxy = state.proxy.http ?? ProxyProvider.read().http
        workQueue.async { [weak self] in
            guard let self else { return }
            for (index, item) in NetworkCheckProvider.items().enumerated() {
                self.onMain {
                    if index < self.state.checks.count { self.state.checks[index].status = .running }
                }
                let result = NetworkCheckProvider.run(item.id, proxy: proxy)
                self.onMain {
                    if index < self.state.checks.count { self.state.checks[index] = result }
                }
            }
            self.onMain { self.state.checksRunning = false }
        }
    }

    /// 按当前周期重建曲线数据（后台读盘 + 聚合，回主线程赋值）。
    private func refreshHistory() {
        let period = state.historyPeriod
        workQueue.async { [weak self] in
            let bundle = HistoryBundle.build(period: period)
            // 电池健康明显下降（官方口径，窗口跨度 ≥ 5 天且掉了 ≥ 2 个点）
            var healthAlert: String?
            let health = bundle.healthOfficial
            if let first = health.first, let last = health.last,
               Double(last.t - first.t) >= 5 * 86_400, first.value - last.value >= 2 {
                healthAlert = String(format: "电池健康度较 5 天前下降 %.1f 个点（%.1f%% → %.1f%%）",
                                     first.value - last.value, first.value, last.value)
            }
            self?.onMain {
                self?.state.historyBundle = bundle
                self?.state.healthAlert = healthAlert
            }
        }
    }

    /// 对齐到整分（历史记录的 t）
    private func alignedMinute() -> Int {
        Int(Date().timeIntervalSince1970 / 60) * 60
    }
}
