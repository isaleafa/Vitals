# Vitals v0.2.0

macOS 菜单栏上的**系统工具箱 + 实时监视器**：电源、CPU、内存、存储、网络五大实时面板，外加网络体检、SSH 主机可达性、监听端口、登录项审计与阈值告警。**全部只读、无需 root、不联网上报。**

要求：**macOS 14+ / Apple Silicon**。

## 本版新增（相对 v0.1.0）

**菜单栏显示两档可选**——点面板底部的小图标切换，选择会记住（`battery` / `cpuMem`）：

- `电池`（默认）：自绘电池图标，可替掉系统自带的电池项
- `CPU + 内存`：直接在菜单栏常显两个数，如 `27% │ 12.8G`（等宽数字、两段之间带分隔线；2x 屏上按屏幕缩放渲染，字不虚）

**总览面板更紧凑**——底部从 3 行压成 1 行，面板高度减少约 50pt：

- 「开机自启」压缩成标题行右侧的 mini 开关（悬停有状态提示），不再单独占一行
- 「服务与自启 →」并入底部状态行
- 开关的反馈消息（"需在系统设置里允许 Vitals" 等）挂在标题行下方、右对齐

其余功能与 v0.1.0 相同：五张卡片 + 60 秒迷你曲线、五个详情页（CPU / 内存 / 存储 / 网络 / 电源 · Pulse）、网络一键体检九项、监听端口、SSH 可达性（含 `ProxyJump`）、登录项审计、温度与功耗（SMC / IOHID / IOReport）、历史曲线（1h / 24h / 7d / 30d）、阈值告警。

## 安装

1. 下载 `Vitals-0.2.0.dmg`，打开后把 **Vitals.app** 拖进 **Applications**
2. **首次打开需要放行**（本版是 ad-hoc 签名，没做 Apple 公证）：
   - 图形方式：先双击一次被拦 → 打开「系统设置 → 隐私与安全性」→ 在「安全性」区域点「**仍要打开**」→ 输入密码
   - 终端方式：`xattr -dr com.apple.quarantine /Applications/Vitals.app`
   - 或者改用终端下载安装（`curl` 不打隔离属性，不会触发 Gatekeeper）：
     ```bash
     curl -L -o /tmp/Vitals.dmg https://github.com/isaleafa/Vitals/releases/download/v0.2.0/Vitals-0.2.0.dmg
     hdiutil attach /tmp/Vitals.dmg
     ditto "/Volumes/Vitals 0.2.0/Vitals.app" /Applications/Vitals.app
     hdiutil detach "/Volumes/Vitals 0.2.0"
     open /Applications/Vitals.app
     ```
3. **必须从 `/Applications` 运行**：macOS 的菜单栏机制与 Hidden Bar 这类工具只认这里的副本
4. 如果你用 Hidden Bar：按住 ⌘ 把 Vitals 图标拖到折叠箭头右侧即可常显

## 说明

- **数据全部只读**：IOKit / Mach / sysctl / getifaddrs / launchd，不装任何内核扩展，不触发授权弹窗
- **不联网**：没有任何遥测或更新检查；联网行为只发生在你自己点「网络体检」和 SSH 探测时
- 温度与功耗走 Apple Silicon 的 SMC / IOReport 通道，**Intel 机器未测试**

完整说明、数据来源与已知边界、命令行工具、架构见 [README](https://github.com/isaleafa/Vitals#readme)。
