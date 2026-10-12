# Vitals v0.2.2

带来键盘流极速操作、深度 Wi-Fi 射频监控、全局数值一键复制与多项体验精细打磨。

要求：**macOS 14+ / Apple Silicon**。

## 新特性

- **全局快捷键 ⌥V 呼出总览**：在任意应用或全屏下，键盘按下 `⌥ + V`（Option + V）瞬间在当前屏幕中央呼出悬浮总览面板，再按一次或按 `Esc` / `⌘W` 立即收起。基于原生 Carbon API，**无需系统辅助功能（Accessibility）提权**。总览面板底部菜单支持开启/关闭。
- **Wi-Fi 射频链路监控（网络详情页）**：采用 Apple 原生 `CoreWLAN` 框架，毫秒级按需只读采样当前 Wi-Fi 的**物理协商速率（Tx Rate）**、**信号强度（RSSI）与评级**、**信噪比（SNR）**、**噪声基底**、**信道与频段（2.4G/5G/6G，20/40/80/160MHz）**。
- **全局数值一键复制 + Toast 反馈**：详情页中的所有参数（IP 地址、MAC 地址、监听端口号、SSH 别名与各项指标），点击即可复制到剪贴板，底部中央伴有极简半透明 Toast 胶囊提示。
- **TOP 进程快捷动作**：CPU / 内存详情页的 TOP 进程表支持点击 PID 标签直接复制；右键可唤起上下文菜单（拷贝 PID、拷贝进程名、一键打开系统活动监视器）。
- **菜单栏固定槽位防抖**：「CPU + 内存」菜单栏显示模式重构为工业级固定槽位与锚点对齐体系，宽度恒定锁死为 83.0pt，彻底消除数字跳动与位数变化时系统状态栏的横向抖动。

## 交互与稳定性改进

- **详情窗口极速关闭**：所有详情窗口现已原生支持 `⌘W` 和 `Esc` 按键关闭；总览面板点击外部时自动平滑收起。
- **单实例分发保障**：构建脚本（`build.sh`）自动将编译产物安装至 `/Applications/Vitals.app` 并清理本地中间 bundle，杜绝 Spotlight 与 Raycast 启动器索引到重复应用。
- **自检套件扩充**：`Vitals --selftest` 扩充了菜单栏固定槽宽恒定性验证与 Wi-Fi 射频数据模型解析断言。

---

# Vitals v0.2.1

修四处会悄悄出错的问题、让内网体检说真话，并新增一条命令行自检。功能面与 v0.2.0 相同：五张卡片 + 60 秒迷你曲线、五个详情页、网络体检、监听端口、SSH 可达性、登录项审计、温度与功耗、历史曲线、阈值告警。

要求：**macOS 14+ / Apple Silicon**。

## 修正

- **子进程输出不再被截断**：`Shell` 改为并发读管道。旧写法"先等进程退出、再读管道"，输出一旦超过管道缓冲（64KB）就会截断并白等满超时——`sfltool dumpbtm` 实测 58KB，就贴着上限。「服务 · 自启」页在开机自启项多的时候不会再偶发少一半。
- **PD 身份不再"回流"**：拔电后每 60 秒的定时刷新会把拔电前读到的适配器 VID/PID 写回数据快照（虽然界面暂时看不出来，但 `--dump` 已经露馅）。现在只在接电时刷新。
- **SSH 配置解析**：支持 tab 分隔（旧版只认空格，tab 写的配置整行被丢掉）与 `Host a b c` 一行多别名（旧版只认第一个）。
- **历史曲线少读一天文件**：每小时重建曲线时会多读一个用不到的 jsonl，去掉。

## 网络体检更诚实

「内网主机（走隧道）」这个标题此前是写死的，现在按**实际路径**生成：

```
✅ 内网主机（走隧道 utun2）  192.168.1.50 · 延迟 7 ms
❌ 内网主机（经 en0）        192.168.1.50 不通
```

如果显示「经 en0」而目标本该走隧道，多半是目标地址落在了**你当前 Wi-Fi 的网段**里——本地直连路由比 VPN 推的大网段更精确，会把这一段整个遮蔽在本地网（换个不在本网段的目标地址即可）。

## 新增命令行

`Vitals --selftest`：纯函数自检（路由 CIDR 规范化 / CPU tick 回绕差分 / SSH 配置解析 / BTM 前缀剥离 / 历史聚合 / 格式化），32 条断言，退出码即结果——系统更新后一条命令就能确认这些解析逻辑没被改坏。

## 安装

1. 下载 `Vitals-0.2.1.dmg`，打开后把 **Vitals.app** 拖进 **Applications**
2. **首次打开需要放行**（本版是 ad-hoc 签名，没做 Apple 公证）：
   - 图形方式：先双击一次被拦 → 打开「系统设置 → 隐私与安全性」→ 在「安全性」区域点「**仍要打开**」→ 输入密码
   - 终端方式：`xattr -dr com.apple.quarantine /Applications/Vitals.app`
   - 或者改用终端下载安装（`curl` 不打隔离属性，不会触发 Gatekeeper）：
     ```bash
     curl -L -o /tmp/Vitals.dmg https://github.com/isaleafa/Vitals/releases/download/v0.2.1/Vitals-0.2.1.dmg
     hdiutil attach /tmp/Vitals.dmg
     ditto "/Volumes/Vitals 0.2.1/Vitals.app" /Applications/Vitals.app
     hdiutil detach "/Volumes/Vitals 0.2.1"
     open /Applications/Vitals.app
     ```
3. **必须从 `/Applications` 运行**：macOS 的菜单栏机制与 Hidden Bar 这类工具只认这里的副本
4. 如果你用 Hidden Bar：按住 ⌘ 把 Vitals 图标拖到折叠箭头右侧即可常显

## 说明

- **数据全部只读**：IOKit / Mach / sysctl / getifaddrs / launchd，不装任何内核扩展，不触发授权弹窗
- **不联网**：没有任何遥测或更新检查；联网行为只发生在你自己点「网络体检」和 SSH 探测时
- 温度与功耗走 Apple Silicon 的 SMC / IOReport 通道，**Intel 机器未测试**

完整说明、数据来源与已知边界、命令行工具、架构见 [README](https://github.com/isaleafa/Vitals#readme)。
