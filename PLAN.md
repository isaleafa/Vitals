# Vitals — 实现方案

> **一句话**：一个 Mac 菜单栏工具箱 + 实时系统监视器。点菜单栏图标弹出面板，一眼看清电源、CPU、内存、磁盘、网络。
> **状态**：M0 数据验证完成、**M1（采样引擎 + 菜单栏 + 总览页）已完成并实测**（2026-09-23）。M0 的探针脚本在 `probes/`，M1 的成品截图在 `docs/m1-overview.png`。
> **命名**：App = **Vitals**（生命体征）；电源页 = **Pulse**（脉搏）。仓库名 `vitals`，Bundle ID `top.liyi830.vitals`。

---

## 1. 项目定位

- **参考物**：PowerMaster 的充电详情面板（`reference/toolbox-ref.jpg`）——分组行式信息密度 + 右侧数值 + 实时曲线 + 底部操作栏，这个视觉语言就是 Vitals 的基准。
- **范围**：电源/充电（含 PD 协商细节）、CPU、内存、磁盘（容量/速率/SMART）、网络（接口/路由/速率）。
- **非目标**（明确不做）：远程或多机监控、云同步、iOS 版、上架 Mac App Store（读取 IORegistry 与私有接口，审核过不了；自用 + GitHub/DMG 分发）。
- **后期候选**：CPU/GPU 温度与功耗、风扇；以及「工具箱」里的非监控类工具（工具宫格会给它们留位置）。

## 2. 形态与交互

### 2.1 四种界面

| 界面 | 触达方式 | 内容 |
|---|---|---|
| 菜单栏常驻 | 始终在 | 图标（gauge）+ 一个可配置的短数字，默认 `CPU%`；可选 内存压力 / 瓦数 / 关闭文字 |
| 弹窗面板 | 左键点图标 | **总览页**：五张卡片（电源/CPU/内存/磁盘/网络），每张 = 主数值 + 副信息 + 60 秒迷你曲线；点卡片进详情 |
| 详情窗口 | 面板内点击卡片 | 五项指标的详情页（见 2.2）+ 历史曲线切换（1 小时 / 24 小时 / 7 天）。**打开时在鼠标所在那块屏幕的正中央、并强制提到最前**（不被其它窗口压住）；同一页面再次点击复用已有窗口 |
| 设置窗口 | 面板右下「偏好设置…」 | 采样间隔、菜单栏显示项、历史保留、开机自启、阈值告警开关、单位口径 |

### 2.2 页面清单

**总览（Overview）** — 五卡片；每卡右下角显示该指标最近 60 秒趋势；任一指标超阈值时卡片边框染色。

**CPU**
- 总使用率（大数字 + 环形进度）、分核柱状（按 4 性能核 / 4 能效核分组着色）、负载 1/5/15、开机时长
- 进程 TOP 5（%CPU），带「复制 PID / 复制进程名」

**内存（Memory）**
- 已用 / 可用 / 压缩 / 联动 wired 构成条；交换已用；**内存压力**徽标（正常/警告/严重，黄/红）
- 进程 TOP 5（内存占用）

**存储（Storage）**
- 容量条（已用 / 可用，APFS 口径注明）、各卷（系统 / 数据）
- 实时读 / 写 MB/s + IOPS，双线曲线；近 24h 读写曲线
- SMART 摘要：损耗百分比、备用块、温度、通电时长、累计写入；NAND 型号/固件（`AppleANS3CGv2Controller`）

**网络（Network）** ← 用户点名的重点
- **系统代理**（新增）：读 `CFNetworkCopySystemProxySettings` 显示 HTTP/HTTPS/SOCKS 端点，并用 `lsof` 查出**监听进程名**（如 `verge-mihomo`）——Clash 这类工具默认在代理层接管流量、**不建隧道接口**，不显示这一层用户会以为"第二个 VPN 不见了"
- **接口卡列表**（默认只显示活跃接口；`显示空闲接口` 开关可看全部，空闲项标"空闲"）：名称、UP/RUNNING、MTU、**IP/CIDR**（v4+v6）、**点对点对端（→ 10.8.0.1）**、MAC、实时 ↓/↑、★ 标记承载默认路由的接口
- **路由表**（按接口分组，目标规范化为完整 CIDR）：
  `en0: default → 10.0.0.1 · 10.0.0.0/24 · 203.0.113.10/32 → 10.0.0.1·主机 …`
  `utun2: 192.168.0.0/16 · 10.8.0.1/32`
  筛选器：全部 / 隧道 / 直连 / 主机；IPv6 开关
- **诊断句**（自动生成，一句话）："去 192.168.1.x 走 utun2；去公网走 en0"
- 每接口速率（列表右侧，活跃接口按速率排序）

**电源（Pulse）** — 即参考截图那页
- 充电状态 / 电量大数字；输入电压 / 电流 / **功率**（实时功率曲线）
- 适配器：名称（VID/PID 库命中时）、额定功率、当前档位、PD 版本、厂商 + VID
- 支持档位表：每档 `电压 / 电流 → 瓦数`，当前档位绿点标记
- 循环次数；健康度**双口径**（官方 `93% / Good` + 原始容量比 `83.9%`，都标注来源）
- 23 小时功率曲线（近 24h）

### 2.3 阈值与染色（默认值，可在设置里改）

| 指标 | 黄（警告） | 红（严重） |
|---|---|---|
| CPU | > 80% 持续 30s | > 95% 持续 10s |
| 内存压力 | 系统 pressure = 警告(2) | 严重(4) |
| 磁盘可用 | < 15% | < 8% |
| 电源 | 接了电源但未充电且非满电 | 掉电/充电器功率骤降（PD 重协商）|

## 3. 架构

```
Vitals.app  (@main MenuBarExtra .window)
├── Shell        MenuBarExtra 标签 + 面板/窗口/设置 的场景与路由
├── Sampler      actor，1 秒 tick —— 唯一数据入口
│   ├── Providers   CPU / Memory / Disk / Network / Routes / Power（每个独立、可失败）
│   ├── DiffEngine  与"上一帧"做差分；处理 32 位回绕、睡眠唤醒、时钟跳变
│   └── History     RingBuffer（1s×3600）+ 降采样落盘（1 分钟/点）
├── State        @Observable AppState（最新快照 + 历史切片 + 阈值状态）
└── Views        Overview / CPU / Memory / Storage / Network / Power / Settings
```

**数据流**：`Timer(1s)` → `Sampler.sample()` 并发跑各 provider → 原始计数器交 `DiffEngine` 算速率/使用率 → 组装不可变 `Snapshot` → 写 `AppState`（主线程）→ SwiftUI 自动重绘；每 60 秒把 1 分钟聚合点追加到历史文件。

**关键约定**
- 所有速率类指标（CPU%、网络/磁盘 MB/s）**一律是两次采样取差**，不依赖任何单次可读的"瞬时值"。
- 每个 provider 独立 try；任一失败只让对应字段显示 `—`，绝不影响其他指标与 UI。
- 睡眠/唤醒（`NSWorkspace.didWakeNotification`）后清空差分基线，避免第一帧假尖峰。
- 事件驱动优先：电源插拔（IOKit interest notification on `AppleSmartBattery`）、网络/路由变化（`NWPathMonitor`）触发立即刷新，1 秒定时器只是兜底。
- 采样在后台 actor，UI 只读快照；单 tick 目标耗时 < 20ms（原生调用，Python 探针 0.1s 是含子进程的开销）。**落地后的分层**：主线程只做毫秒级原生采样（实测 0.27ms/帧），子进程类（netstat/lsof/ps/smartctl/system_profiler）与 IOKit 大树遍历走后台串行队列。

**历史存储**：`~/Library/Application Support/Vitals/history/YYYY-MM-DD.jsonl`，每分钟一行：
```json
{"t":1789992000,"cpu":38.9,"mem_used":12.4,"mem_press":2,"swap_mb":1974,
 "disk_r":0.2,"disk_w":9.3,"net":{"en0":[57,6],"utun2":[0.3,0.1]},
 "power_w":13.2,"charge":100,"charging":false,"cycles":108}
```
保留 30 天（可配）；启动时加载当日 + 所需天数喂给 24h/7d 曲线。不引入数据库依赖。

## 4. 数据源规格（全部本机实测，无需 root）

| 指标 | 来源 | 原生实现（App 内） | 本机实测 |
|---|---|---|---|
| CPU 总/各核 | Mach `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | 同款 C API | 8 核 = 4P + 4E，P 核更忙 |
| 负载 / 开机时长 | `sysctl vm.loadavg` / `kern.boottime` | `sysctlbyname` | 4.8/5.0/4.3 |
| 内存 | `vm_stat`（16KB/页）+ `vm.swapusage` + `kern.memorystatus_vm_pressure_level` | `host_statistics64` | 已用 12.3/16GB、压缩 6.9GB、交换 1.9GB、**压力=警告** |
| 磁盘容量 | `statvfs('/System/Volumes/Data')` | `URLResourceValues` | 995GB，可用 903GB |
| 磁盘速率/IOPS | IOKit `IOBlockStorageDriver.Statistics` 累计计数器差分 | IOKit 直读 | 读 0.2 / 写 9.3 MB/s |
| 磁盘健康 | `smartctl -a /dev/disk0`（无需 sudo，60ms） | 子进程调用 | 损耗 0%、备用块 99%、48°C、累计写入 12.8TB |
| 网络接口/地址 | `getifaddrs`（AF_LINK 计数器 / AF_INET[6] 地址） | 同款 C API | en0 `10.0.0.5/24`；utun2 `10.8.0.2/24`；21 个接口仅 4 个活跃 |
| 网络计数 | `struct if_data`（**32 位，4GiB 回绕**） | 同上 | 已与 netstat 64 位对账（差值恰为 2³² 整数倍） |
| 路由表 | `netstat -rn -f inet`（**6ms**） | `sysctl NET_RT_DUMP` 拿精确 netmask | 17 条 v4 / 39 条 v6（滤后 6 条） |
| 电源/充电 | `ioreg AppleSmartBattery`：`AdapterDetails`(含 `UsbHvcMenu` 档位表、`UsbHvcHvcIndex` 当前档位)、`PowerTelemetryData`(输入 V/mA/mW)、`BatteryData`、`CycleCount` | IOKit `IOPSCopyExternalPowerAdapterDetails` + IORegistry | 20.39V / 379mA / 7.7W；94W 适配器；循环 108 |
| PD 身份 | IORegistry `IOPortTransportComponentCCUSBPDSOP` 节点 | 同款 | `VendorID` / `ProductID` / `Specification Revision`(=PD 版本) |
| 官方健康度 | `system_profiler -json SPPowerDataType` | 子进程（低频缓存） | 93% / Good |
| 温度、功耗（M5） | ⚠️ 无公开接口 | `IOHIDEventSystemClient` + IOReport（私有，无需 root）；备选 `powermetrics`（需 sudo，有 `cpu_power/gpu_power/thermal` 采样器） | NAND 温度传感器存在但是 IOHID 事件值 |

权限：上述读取**均不需要任何授权**；唯一需要用户动作的是「开机自启」（首次在系统设置里允许）。

## 5. 技术选型与工程结构

- **语言/框架**：Swift 6.4 + SwiftUI（`MenuBarExtra(.window)`）+ Swift Charts + Observation；**零第三方依赖**。
- **目标**：macOS 14.0+，arm64（Intel 可选，不作要求）。
- **构建（无 Xcode 路线，已验证）**：本机只有 Command Line Tools，沿用 `~/Projects/h3cvpn/build_app.sh` 的成熟做法：
  ```bash
  swiftc -O -parse-as-library -sdk "$(xcrun --show-sdk-path)" \
      -target "$(uname -m)-apple-macosx14.0" \
      -o "build/Vitals.app/Contents/MacOS/Vitals" $(find Sources -name '*.swift')
  # + 手写 Info.plist（LSUIElement=true）+ codesign --force --sign - 临时签名
  ```
  实测：SwiftUI + MenuBarExtra + Charts 的 spike 用上面命令 **1 秒编出 70KB arm64 可执行文件**。
- **工程结构（截至 M1，实际落地）**：
  ```
  vitals/
  ├── PLAN.md                 ← 本文档
  ├── probes/                 ← M0 数据验证脚本（Python）
  ├── reference/              ← 参考截图
  ├── docs/m1-overview.png    ← M1 成品截图（存档）
  ├── Sources/
  │   ├── App/VitalsApp.swift          # @main、MenuBarExtra、--dump/--bench/--preview
  │   ├── Core/Snapshot.swift          # 快照数据结构（Codable）
  │   ├── Core/RawCounters.swift       # 原始计数器打包
  │   ├── Core/DiffEngine.swift        # 差分/回绕/活跃接口过滤
  │   ├── Core/Sampler.swift           # 1 秒 tick
  │   ├── Core/AppState.swift          # ObservableObject + 60 点环形缓冲
  │   ├── Core/Sysctl.swift            # sysctl/Mach 小工具
  │   ├── Core/Format.swift            # 数值格式化
  │   ├── Core/Dump.swift              # --dump / --bench
  │   ├── Core/Providers/{CPU,Memory,Disk,Network,Power}.swift   # Routes 在 M2
  │   └── UI/{OverviewPanel,Sparkline}.swift
  └── scripts/{build.sh,run.sh}        # 无 Xcode 构建 / 构建并重启
  ```
  开发期常用：`swiftc` 编译由 `scripts/build.sh` 封装；`Vitals --dump` 对账数据、`Vitals --bench 500` 测采样开销、`Vitals --preview` 开窗口截图调 UI。安装/重启走 `scripts/run.sh`（会把 `.app` 装到 `/Applications` 再启动——macOS 27 的菜单栏机制只认 /Applications 里的副本，见附录 C 第 13 条）。
- **自启**：优先 `SMAppService.mainApp`（macOS 13+）；若临时签名下注册失败，退回 `~/Library/LaunchAgents` plist（方案有 Plan B）。
- **调试**：`scripts/run.sh` 先跑命令行模式（`Vitals --dump` 打印一帧 JSON，便于比对探针输出），再 `open build/Vitals.app`；日志写 `~/Library/Logs/Vitals.log`。装 Xcode 能换来可视化调试，但非必需（列为待定决策）。

## 6. 里程碑

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| **M0 ✅** | 数据验证（`probes/`） | 已完成：两个脚本实时输出全部指标；采样 0.1s/轮；`--net` 输出接口+路由 |
| **M1 ✅** | 采样引擎 + 菜单栏骨架 + 总览页 | **已完成（2026-09-23）**：五卡片 + 60 秒迷你曲线渲染正常（`docs/m1-overview.png`）；菜单栏显示仪表盘图标 + CPU%；`--dump` 与探针逐项对账一致（负载/内存/交换/循环次数/适配器瓦数全部相同）；**稳态 0.3% CPU、RSS 78MB、单帧采集 0.27ms** |
| **M2 ✅** | 五个详情页 | **已完成（2026-09-23）**：CPU（总览 + 分核柱状，4 性能核/4 能效核分组着色 + 进程 TOP）、内存（构成条 + 交换/压缩/压力 + 进程 TOP）、存储（容量条 + 实时读写/IOPS + SMART 摘要）、**网络（系统代理层 + 接口卡含点对点对端 + 路由表按接口分组、目标规范成完整 CIDR、隧道/直连/主机筛选、IPv6 开关、一句话诊断 + 空闲接口开关）**、电源 Pulse（输入 V/mA/W + 适配器 VID/PID/PD 版本 + 档位表带当前档位绿点 + 健康度双口径）。重指标按需采样（页面打开才采），常态开销 **0.4% CPU / RSS 79MB**。菜单栏默认改为**电源**（电池图标 + 电量%，接电源带闪电），已可替掉系统电池项。 |
| **M3 ✅** | 历史与曲线 | **已完成（2026-09-23）**：每分钟 1 条记录落盘 `~/Library/Application Support/Vitals/history/YYYY-MM-DD.jsonl`（保留 30 天，启动时清理过期）；五个详情页都加了「历史」区块（**1 小时 / 24 小时 / 7 天** 三档切换，聚合桶 60s/300s/3600s → 60/288/168 点）；曲线 x 轴按**真实时间**映射、数据缺口超过 2.5 个桶就断开不连线（应用没运行/机器睡觉不会画出假线）；带最值·均值·时间端点；睡眠唤醒重置差分基线（无假尖峰）；重启后历史从磁盘加载。开销仍是 **0.6~0.9% CPU / RSS 72MB**（历史计算全在后台队列）。 |
| **M4 ✅** | 自启 + 图标 | **已完成（2026-09-23）**：①开机自启（`SMAppService` 正规登录项，ad-hoc 签名也认；被拒自动退回 LaunchAgent）+ 面板开关 + `Vitals --login-item on\|off`；②应用图标纯代码生成（`scripts/make-icon.swift` → `.iconset` → `.icns`，进构建流程，10 个尺寸）。 |

## 6b. 功能路线图（2026-09-24 与用户确认，**按顺序推进**）

用户已确认要这 7 项，其余设置项**明确砍掉**（采样间隔 / 历史保留天数 / 菜单栏显示项——没人会调，只增加出错面）。

| # | 功能 | 内容 | 验收标准 |
|---|---|---|---|
| **1 ✅** | **网络一键体检** | 网络页顶部「网络体检」按钮 + **九项探测**：默认网关 / 内网主机（走隧道）/ 公网（国内 ping）/ DNS 解析 / **代理 · Google / GitHub / YouTube**（经系统代理，测「墙外站通不通」）/ **直连 · 百度 / GitHub**（绕过代理作对照）；每项显示通断 + 延迟 + 经哪个接口或代理；逐条回填、整轮约 3.1 秒。**打开网络页即自动跑一次**（按钮改为「重跑体检」；实现走 `DetailWindows` 打开窗口时的 `onDetailPageOpened` 回调，因为窗口复用时 SwiftUI 的 onAppear 不保证再触发） | **已完成（2026-09-24）**：实测九项全绿——内网 8ms **经 utun2**、代理三项 HTTP 204/200（经 127.0.0.1:7897）、直连两项 200；`Vitals --check-network` 命令行核对，`--preview net --run-checks` 截图核对 |
| **2 ✅** | **监听端口 / 自建服务清单** | 列出本机监听端口，标注监听进程 + 是否属于已知自建服务 | **已完成（2026-09-24）**：网络页「监听端口 / 自建服务」区块，`lsof -nP -iTCP -sTCP:LISTEN`（0.66 秒）按进程归并；**默认只显示自建/已知服务**（Clash 内核 7897、Clash Verge、FRP、h3cvpn、SSH… 带中文备注），"显示全部"可看其余（本机共 29 个监听进程）；`Vitals --ports` 可命令行核对。**已知缺口**：frpc 这类"只往外连"的服务不监听端口、天然不在列表里 → 由第 5 项（自启/后台服务审计）覆盖 |
| **3 ✅** | **SSH 主机可达性** | 读 `~/.ssh/config` 的 Host 列表，一键测连通/延迟；**配 `ProxyJump` 的条目走 `ssh -J` 端到端探测**（TCP 直连对这类条目会误报） | **已完成（2026-09-24）**：解析 Host/HostName/User/Port/ProxyJump（跳过通配块），**原生 socket 非阻塞 connect + select 超时**测延迟（不开子进程）；**并发**探测 8 台（0.65 秒）；网络页「SSH 主机」区块 + 打开本页自动探测 + `Vitals --ssh` 命令行核对。实测 9 台：4090-VPN / macmini / LynServer / **macpro（6006 直连，11ms）** / **macpro-via-mini（经 macmini 跳板，1016ms）** / MyWin / APP1 / APP2 均通；ecust-isaleefa（校园网 10.9.9.9）从当前网络不可达。⚠️ 早期版本曾把 macpro 报成「本地 2222 未起」，那是**误报**：探测只按 `HostName:Port` 做 TCP、不认 `ProxyJump`，而 `127.0.0.1:2222` 的隧道只在 macmini 侧监听 → 探的其实是本机的 2222（2026-09-24 用户指出后已修：配 ProxyJump 的条目改走 `ssh -J <jump> <alias> true` 端到端探测） |
| **4 ✅** | **温度 / 功耗**（原 M5） | CPU/GPU 温度与功耗曲线（私有通道，无需 root）；NAND 温度进存储页 | **已完成（2026-09-24）**：**温度**——CPU（SMC `Tp*/Te*/Ts*` 平均）/GPU（SMC `Tg*`）/电池（HID）/NAND（HID），共 35 个 HID + ~100 个 SMC 传感器；**功耗**——系统功耗（电池遥测，整机）/ SoC 功耗（SMC `PSTR`）/ GPU 功耗（IOReport），GPU 温度历史曲线已进 CPU 页。**与成熟实现 macmon 对账**（brew 装的官方 bottle）：同一时刻 GPU 56.9 vs 57.0 °C、CPU 61.1 vs 57.9 °C ✓；**CPU 功耗在 macmon 上同样是 0**（连 ANE/RAM 也是）→ 确认是本机通道特性，不是本应用的 bug |
| **5 ✅** | **登录项 / 后台服务审计** | 列 `launchctl` 里的用户级自建项（frpc / h3cvpn daemon / menubar…），标出异常、僵尸、重复 | **已完成（2026-09-24）**：新增「服务 · 自启」页（面板底部有入口）——数据源全部是系统自带、**免 root**：三个 plist 目录 + `launchctl list`/`launchctl print system/<label>`（PID、上次退出码）+ **`sfltool dumpbtm`**（系统「设置 → 登录项」背后的 BTM 账本：启用/禁用状态、最后使用时间）。本机 25 项（运行中 5、异常 1）：frpc / H3CVPNMenu / h3cvpn.daemon / RustDesk 均在运行，异常项是我迁移 h3cvpn 时留下的备份文件 `local.h3cvpn.menubar.plist.bak-*`（可删）；`Vitals (top.liyi830.vitals)` 已被系统收录为登录项 ✓；另标出 4 个已禁用的 App 登录项（ChatGPT / LibreOffice / Office Licensing / RustDesk）|
| **6 ✅** | **电池健康趋势**（充电器型号库按用户判断**砍掉**） | 历史里加健康度，按周采样看衰减 | **已完成（2026-09-24）**：历史记录加 `h`(官方口径%)/`hr`(容量比%)/`cap`(满充容量 mAh)/`cyc`(循环次数) 四个**可选**字段（老记录不受影响）；电源页新增「电池健康趋势」（青=官方%、橙=容量比%，共用纵轴）+「容量与循环」明细；周期扩到 **30 天**（每 6 小时一点，与历史保留上限一致）。整机侧用合成数据验证过曲线渲染（验完即删，不留假数据）。**注意曲线从今天开始积累**——健康度变化本来就慢，30 天档才有意义 |
| **7 ✅** | **阈值染色与告警（轻量）** | 只对真异常染色/提示：CPU 持续 >90%、内存压力=严重、磁盘可用 <8%、电池健康显著下降；**本机常年在内存「警告」档，阈值按「严重」才提示**；触发时面板/菜单栏可见、不产生日常噪音 | **已完成（2026-09-24）**：面板顶部红色告警横幅 + 对应卡片变红（CPU/磁盘）；**菜单栏图标在有告警时切换为 ⚠️ 警告三角**；阈值——CPU ≥90% 连续 30 秒 / 内存压力=严重 / 磁盘可用 <8% / 健康度 5 天内掉 ≥2 点；`Vitals --alerts` 打印瞬时评估、`--alert-demo` 可复现告警样式。**七项路线图至此全部完成** |

之后（原 M6）打磨项：`⌘C` 复制数值、导出 CSV/PNG、README ✅、**DMG/GitHub 分发 ✅（2026-09-24：`scripts/package.sh` 本地打包 + `.github/workflows/release.yml` 推 `v*` 标签自动发版；v0.1.0 已发布并实测下载→挂载→运行）**。

每个里程碑结束都跑一遍「验收清单」并留一份截图存档。

## 7. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| 适配器"产品名/厂商名"系统不给 | 电源页两项显示不全 | 自建 VID/PID → 厂商/型号小库（先录入自己的充电器）；查不到降级显示 VID/PID + 功率 |
| 电池健康度存在双口径（83.9% vs 93%） | 数字被质疑 | 两口径并列显示并标注来源；不合并 |
| 温度/功耗是私有接口 | M5 可能被系统更新破坏 | 独立 provider，失败即整块隐藏；不牵连其他功能 |
| 无 Xcode 的调试体验一般 | 修 bug 慢 | `--dump` 命令行模式 + 日志；必要时再装 Xcode |
| macOS 升级改 IORegistry 键名 | 字段读不到 | 所有 provider 容错：缺失显示 `—`，附「上次成功读取」时间 |
| 临时签名 + 登录项（SMAppService）可能不配合 | 开机自启失败 | Plan B：LaunchAgents plist |
| 私有 API 无法上架 | 分发受限 | 定位自用；分享走 GitHub + DMG（附公证说明或告知用户右键打开） |

## 8. 总验收清单

- [ ] 菜单栏常驻，点开面板 0.2s 内渲染完成
- [ ] 五项指标全部实时刷新（默认 1s），与 `probes/` 输出一致
- [ ] 网络页：接口（IP/CIDR/MAC/速率/累计，★默认路由）+ 路由表（CIDR、按接口分组、隧道/直连筛选）+ 诊断句
- [ ] 电源页：档位表含当前档位标记；PD 版本/VID 正确；功率曲线含近 24h
- [ ] 历史：1h/24h/7d 切换，重启不丢，睡眠唤醒无假尖峰
- [ ] 阈值染色按 2.3 生效，且可在设置关闭
- [ ] 自身开销：CPU < 2%、内存 < 80MB（跑满 1 小时）
- [ ] 异常路径：拔电源、插拔网线/切 Wi-Fi、VPN 断开、睡眠唤醒——均不崩、不卡、数值自愈

## 9. 附录

### A. 参考截图字段 ↔ 本机系统字段

| 截图（PowerMaster） | 本机来源 | 实测值 |
|---|---|---|
| 已接通电源 / 充电状态 | `AppleSmartBattery.ExternalConnected / IsCharging` | 已接通、已充满 |
| 输入电压 / 电流 / 功率 | `PowerTelemetryData.SystemVoltageIn / SystemCurrentIn / SystemPowerIn` | 20.39V / 379mA / 7.7W |
| 循环次数 | `CycleCount` | 108 |
| 额定功率 / 当前档位 | `AdapterDetails.Watts` / `{AdapterVoltage, Current}` | 94W / 20V·4.69A |
| 支持档位（绿点） | `AdapterDetails.UsbHvcMenu` + `UsbHvcHvcIndex` | 5V/2.96A、9V/2.98A、15V/2.99A、20V/4.69A |
| PD 版本 3.0 | PD 身份节点 `Specification Revision` | 3 |
| 厂商 + 0x2FE6 | 同节点 `Vendor ID` + 自建厂商库 | 1507（0x05E3） |
| 电池健康度「—」 | 官方 `system_profiler` / 自算容量比 | 93% / Good ；83.9% |
| 功率曲线 24h | 自采样落盘 | — |

### B. 探针脚本用法（M0 产物）

```bash
python3 probes/sysmon-probe.py --watch 1 --top --smart --net --net6   # 实时面板
python3 probes/sysmon-probe.py --json                                  # 喂 UI/存档
python3 probes/power-probe.py --watch 5                                # 电源专项
```

### C. 坑清单（都已踩过并绕过）

1. `netstat -ib` 单次 **5.2 秒**（`-b` 太贵）→ 用 `getifaddrs`；`iostat` 每次**阻塞 1 秒** → 用 IOKit 计数器。
2. 网络计数器是 **32 位**，4GiB 回绕 → 差值必须 `& 0xFFFFFFFF`（已用 netstat 对账验证）。
3. `netstat -rn` 的目的地是简写（`10.0.0/24`、`192.168.0/16`、`127`）→ 要规范化成 CIDR；四段无前缀 = `/32` 主机路由。
4. IPv6 路由表 39 条里 9 条是各 utun 的 default → 只保留与 IPv4 默认路由同接口的。
5. 单文件/多文件 `@main` 必须加 `-parse-as-library`，否则报 "top-level code"。
6. **CLT 工具链没有 SwiftUIMacros 插件 → `@State` 编译不过**（`plugin for module 'SwiftUIMacros' not found`）。改用 `ObservableObject` + `@Published` + `@ObservedObject` / `@StateObject`；`@Observable` / `@Environment(Model.self)` 反而能编（Observation 宏在 CLT 里有）。App/Scene/MenuBarExtra 本身都没问题。
7. `URL.resourceValues` 读磁盘容量实测 **16ms/次**（曾是采样里最贵的一环）；换 `statfs` 后 0.001ms，整个 `collect()` 从 **16.5ms → 0.27ms**。
8. IOKit 要**缓存服务句柄 + 只读单个键**：每次 `IORegistryEntryCreateCFProperties` 会把 AppleSmartBattery 里巨大的 IOReport 数据一并建出来。
9. Apple Silicon 上 `AppleSmartBattery` **没有** `Temperature` 键；`powermetrics` 没有 `smc` 采样器。
10. 电池"健康度"两个口径差 9 个点，必须标注来源。
11. 内存 16GB 在本机长期处于「警告」压力档（压缩 ~7GB）——本 App 的第一个真实用户场景。
12. 菜单栏图标会被 **Hidden Bar** 折叠进隐藏区（截屏都拍不到）；要常显就 ⌘-拖动图标到箭头**右侧**（macOS 27 上箭头就是分界，没有分隔符了）。开发期用 `Vitals --preview` 开窗口截图/调 UI，不要跟 Hidden Bar 较劲。
13. **自建 App 必须从 `/Applications` 运行**：从 `build/` 目录跑的菜单栏 App 会被 Hidden Bar 按 App 隐藏，跟它在菜单栏的位置无关（同一二进制、同一 bundle id，`ditto` 进 /Applications 即恢复正常——2026-09-23 对照实验确认）。`scripts/run.sh` 已改为「构建 → 安装到 /Applications → 重启」。
14. 新启动/刚更新的 App 的图标由 **macOS 插到状态区最左槽位**（在隐藏区内），所以"新生"图标默认是隐藏的；用户 ⌘-拖到箭头右侧一次，之后 macOS 按 App 记住位置。没有任何 App 能代替用户移动别的 App 的图标。
15. `@State` 不可用（见第 6 条）带来的连带影响：**页面本地的 Picker/Toggle 状态**要用页面自己的 `ObservableObject` + `@StateObject`（例：`NetworkPageModel`），不能写 `@State private var`。
16. 泛型 View 里不能放 `static let`（`PageShell` 踩过）→ 格式化器放文件级 `private enum`。
17. **详情页根视图必须有 `ScrollView`**（用户实测反馈：打开"显示空闲接口"后 24 个接口超出窗口，既没有滚动条也不能滚）。配 `.scrollIndicators(.visible)` 让滚动条常显，否则用户不知道这页能滚。
18. **一切开子进程的采样必须放后台队列**（`netstat` / `lsof` / `ps` / `smartctl` / `system_profiler`），主线程只保留毫秒级原生调用（Mach/IOKit/getifaddrs，约 0.27ms）。`lsof` 在本机可能几百毫秒，堵在主线程会让界面发懵。Sampler 现在按此分层：轻采样在主线程，重采样走 `workQueue` 后回主线程赋值。
19. **功率有两个口径，必须标清楚**（用户反馈"拔电了为什么还有充电功率"）：拔电后 `PowerTelemetryData.SystemPowerIn` 就是 **0**（它不是负载），电池侧的真实数值在 `BatteryPower`（放电为负，≈ -SystemLoad）+ 电池 `Voltage`/`Amperage`。显示规则：接电显示**输入功率**（橙）、拔电显示**放电功率**（紫），数值旁永远带标签，曲线画两条线共用 Y 轴（插拔时能看出哪条归零）。另：拔电后不要显示缓存的适配器/PD 身份。
20. 开发期截图核对的小工具：`--preview <page>` 会把窗口号打在 stdout，外层用 `screencapture -x -l <窗口号>` 按窗口截图——**不受窗口前后层级影响**（否则前面有别的窗口时截到的是别人）。
21. **按需采样的页面必须"打开即采"**：如果只挂在 `tickCount % 30 == 0` 这类轮次上，用户打开页面后要对着"读取中…"等 30 秒，看着就像功能没实装（用户实测反馈 SSD 健康页）。Sampler 现在监听 want 开关的 false→true 边沿立刻采一次，之后再按轮次刷新。
22. 解析 `smartctl` 这类 "键: 值" 文本要**精确匹配 `键:`**，否则 `Available Spare` 会把 `Available Spare Threshold` 那行也抓进来（实测踩过：备用块显示成了 Threshold 的值）。数值记得补单位（小时/次/°C），字段名在界面上用中文。
29. **菜单栏标签还有个坑：`if` 条件分支会让整个图标不渲染**。实测写 `if 有告警 { Image(systemName:) } else { Image(nsImage:) }` —— 图标直接消失（ViewBuilder 包成 `_ConditionalContent`，那个 status item 的渲染路径不吃）。正确做法：保持「单个 `Image`」的形状，只在两张 `NSImage` 之间切换（`Image(nsImage: cond ? a : b)`）。
28. **登录项 / 后台服务的权威数据源（免 root）**：① plist 目录（`~/Library/LaunchAgents`、`/Library/LaunchAgents`、`/Library/LaunchDaemons`）给静态配置（Label/Program/RunAtLoad/KeepAlive）；② `launchctl list` 给用户域的 **PID + 上次退出码**，系统域用 `launchctl print system/<label>`（**不需要 root**，state/program/pid/last exit 都能读）；③ **`sfltool dumpbtm`** 是「设置 → 通用 → 登录项」背后的 BTM 数据库，**也不需要 root**，给出 `Disposition: [enabled/disabled]`、`Last Use`、plist URL —— **要报"谁在自启"，直接读系统自己的账本，别自己推断**。注意 BTM 的 `Identifier` 带类型前缀（`16.` 守护进程 / `8.` 代理 / `2.` App 项），比对前要剥掉。
28b. **分发：ad-hoc 签名的 App 在 macOS 26/27 上是被"硬拦"，不是"提示"**（2026-09-24 实测，为发 DMG 时验证）。给 app 副本打上 `com.apple.quarantine` 后：① `open` / 双击 → **进程根本不起来**（无新进程）；② 直接 exec 包内二进制 → **零输出、静默被杀**；③ `spctl -a -vv` 对**本地构建的副本也判 rejected**（ad-hoc 没有 Developer ID 一律拒）——**但没打隔离属性时照常启动**，所以判定关键是 quarantine 属性、不是 spctl 的结论。放行三法：系统设置→隐私与安全性→「仍要打开」（得先双击被拦一次才有这个按钮）；`xattr -dr com.apple.quarantine`（实测有效）；**或干脆用 `curl` 下载——curl 只打 `com.apple.provenance`、不打 `com.apple.quarantine`，完全绕过 Gatekeeper**（README 给了 curl 一键装）。结论：开源 macOS App 不做 Apple 公证（$99/年）就必须把这三条写进文档。
28c. **打包 DMG：macOS 27 起 `hdiutil create` 已弃用**，新语法 `diskutil image create from --volumeName <名> --format UDZO <源文件夹> <输出.dmg>`（实测可用；同内容 830K vs 旧命令 1.2M）。**打包脚本要自带挂载自检**：`hdiutil attach` 回来确认 `Vitals.app` 与 `Applications` 软链都在、`codesign -v` 通过，再 detach —— 否则发出去的 DMG 少了软链，只有下载者会发现。
28d. **登录项「能不能管」的实测结论（2026-09-24，调研开源项目 + 本机逐条验证）**。起因：我曾凭 `sfltool --help` 就下结论"第三方 App 登录项管不了"，用户质疑后重查，结论要分三类（**这才是权威版**）：

| 对象 | 能力 | 机制 / 证据 |
|---|---|---|
| **磁盘上有 plist 的 launchd 项**（`~/Library/LaunchAgents`、`/Library/LaunchAgents|Daemons`；本机 22 项里 18 项属此类：frpc、h3cvpn、Clash Verge、RustDesk…） | **加载/卸载/禁用/启用全都能**，用户级**不需要任何授权** | `launchctl bootstrap/bootout/disable/enable gui/$UID/<label>`。**已用临时探针 agent 走通全流程**（bootstrap→print 可见→disable→`launchctl print-disabled gui/501` 显示 disabled→enable→bootout→删 plist），全程无 sudo。`/Library/*` 的项属主是 root，改它们要管理员授权 |
| **「Open at Login」列表里的 App**（本机 6 项：CC Switch / PixPin / Vitals / Maccy / RClick / Hidden Bar） | **读得到，但增删等于白改** | 公开 API `LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems, nil)` + `CopySnapshot` / `InsertItemURL` / `ListItemRemove` 都可用（`CoreServices`/`SharedFileList.framework`，ad-hoc 签名即可、无需 entitlement，CLI 头文件就在 CLT 里）。**但**插入成功后该条**不出现在系统账本 `sfltool dumpbtm` 里** —— macOS 13+ 已经把登录项迁到 BTM（dump 头部 `ServiceManagement migrated: true`），这份 legacy 会话列表已成单向镜像，系统设置读的是 BTM。所以写入对用户不可见，别做成功能 |
| **App 内嵌的后台任务**（无磁盘 plist，如 `CC Switch - background tasks`） | **做不到** | 真正干活的写接口在私有框架 `BackgroundTaskManagement.framework` 的 `BTMAgentConnection`（`setUserElection:forURL:reply:`）。无签名进程调用 → `-54 permErr`；自己签上那些私有 entitlement → 内核 **SIGKILL**（Apple 用 entitlement 锁死）。GitHub 上也没有调用该写接口的开源项目。**只能一键跳系统设置**：`open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"`（Apple 自己 `openLoginItemsWithReply:` 干的就是这个） |

- **坑：`kLSSharedFileListItemLast` 在 macOS 27 上会让进程 SIGSEGV**（`LSSharedFileListInsertItemURL` 用它当插入锚点必崩，Python/Swift 都一样、开关沙箱都一样）。**改用列表里某个真实项当锚点就正常**（插入返回非空、`ListItemRemove` 返回 0）。
- 读取登录项列表的显示名等于用户的"Open at Login"列表，可用来做审计展示；但**改**要走 launchd 那条路。

27. **Apple Silicon 读数私有通道的实测边界（本机 M2 Air / macOS 27，2026-09-24）**——四条路**全部可用**，我一开始全判错了，根因是两个自己的 bug：
- ✅ **IOReport**：`IOReportCopyChannelsInGroup("Energy Model")` + `CreateSubscription` + `CreateSamples` + **`CreateSamplesDelta`** → GPU 功耗（单位 nJ；**必须读差分样本**，读普通样本全是 0）。CPU/DRAM/ANE 通道恒 0 —— **macmon 在本机同样是 0**，属机器/系统层面的通道特性。
- ✅ **IOHIDEventSystemClient**（温度）：`Create` + `SetMatching({PrimaryUsagePage:0xFF00, PrimaryUsage:5})` + `CopyServices` + `IOHIDServiceClientCopyEvent(svc, 15, 0, 0)` + `IOHIDEventGetFloatValue(ev, 15<<16)`，本机 35 个传感器（`PMU tdie*`、`gas gauge battery`、`NAND CH0 temp`）。
  ⚠️ **坑 1：遍历必须用 `CFArrayGetCount` + `CFArrayGetValueAtIndex`**；用 Swift 的 `as? [UnsafeMutableRawPointer]` 强转 CFArray 会得到空数组，看起来像"系统不给服务"（我据此误判过一次）。
- ✅ **SMC user client**（macmon 对 M2/M3 用的路线）：服务名 **`AppleSMCKeysEndpoint`**，`IOServiceOpen(..., 0, ...)`，`IOConnectCallStructMethod(conn, 2, ...)`，80 字节结构；command（偏移 42）：`5`=读值 `8`=按键号读键名 `9`=读键信息；`result`（偏移 40）非 0 即失败（132=键不存在）。CPU = `Tp*/Te*/Ts*`、GPU = `Tg*`、系统/SoC 功耗 = `PSTR`、风扇 = `F*Ac`，只认 4 字节 `flt`。
  ⚠️ **坑 2：键要按小端写入缓冲区**（macmon 把键打包成大端 u32 再写内存，在小端机上就是反序字节）；写成大端 → 每个键都返回 132「键不存在」（我据此**误判成"SMC 在这台机不可用"**）。键名列举（command 8）的输出同样要反转回来。
- 💡 调试这类私有 API：探针开场 `setbuf(stdout, nil)`（崩溃/中断时不留缓冲丢失）；**先读成熟实现源码**（macmon `src_lib/sources.rs`+`metrics.rs` 是权威参考），`macmon debug` 还能直接当"对照仪器"打印每条通道/传感器的原始读数。

### D. 待定决策（括号内为我的默认建议）

- 装不装 Xcode（**不装**，先用 CLI 工具链）
- 菜单栏默认显示项（**CPU%**）
- 界面语言（**中文界面 + 英文名 Vitals**）
- 历史保留时长（**30 天**）
- 是否要告警通知（**先只做面板染色，通知放 M6 之后**）
