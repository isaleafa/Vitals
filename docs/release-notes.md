# Vitals v0.1.0

首个公开版本：macOS 菜单栏上的**系统工具箱 + 实时监视器**。电源、CPU、内存、存储、网络五大实时面板，外加网络体检、SSH 主机可达性、监听端口、登录项审计与阈值告警。**全部只读、无需 root、不联网上报。**

要求：**macOS 14+ / Apple Silicon**。

## 安装

1. 下载 `Vitals-0.1.0.dmg`，打开后把 **Vitals.app** 拖进 **Applications**
2. **首次打开需要放行**（本版是 ad-hoc 签名，没做 Apple 公证）：
   - 图形方式：先双击一次被拦 → 打开「系统设置 → 隐私与安全性」→ 在「安全性」区域点「**仍要打开**」→ 输入密码
   - 终端方式：`xattr -dr com.apple.quarantine /Applications/Vitals.app`
   - 或者改用终端下载安装（`curl` 不打隔离属性，不会触发 Gatekeeper）：
     ```bash
     curl -L -o /tmp/Vitals.dmg https://github.com/isaleafa/Vitals/releases/download/v0.1.0/Vitals-0.1.0.dmg
     hdiutil attach /tmp/Vitals.dmg
     ditto "/Volumes/Vitals 0.1.0/Vitals.app" /Applications/Vitals.app
     hdiutil detach "/Volumes/Vitals 0.1.0"
     open /Applications/Vitals.app
     ```
3. **必须从 `/Applications` 运行**：macOS 的菜单栏机制与 Hidden Bar 这类工具只认这里的副本
4. 如果你用 Hidden Bar：按住 ⌘ 把 Vitals 图标拖到折叠箭头右侧即可常显

## 这个版本有什么

**菜单栏**：自绘电池图标（细长比例、插电带闪电），可以直接替掉系统自带电池项；有告警时自动变成 ⚠️。

**总览面板**：五张卡片（CPU / 内存 / 存储 / 网络 / 电源），每张带 60 秒迷你曲线；点卡片进详情页，窗口在鼠标所在屏幕正中央打开。

**五个详情页**

| 页面 | 内容 |
|---|---|
| CPU | 总使用率曲线、分核柱状（性能核/能效核分组）、负载与开机时长、进程 TOP、温度与功耗、CPU 温度历史 |
| 内存 | 构成条、压力徽标、交换、进程 TOP、内存历史 |
| 存储 | 容量条、实时读写/IOPS、吞吐历史、SMART 摘要、NAND 温度 |
| 网络 | 网络体检、系统代理层、接口卡、路由表（完整 CIDR + 分组筛选）、监听端口、SSH 主机、流量历史 |
| 电源 · Pulse | 电量/循环、输入电压电流功率（或放电功率）、电池温度、健康度双口径、适配器身份与支持档位表、功率历史、健康趋势 |

**网络一键体检**：打开网络页自动跑，九项逐条给通断 + 延迟 + 走哪个接口/代理（网关 / 内网 / 公网 / DNS / 代理三项 / 直连两项）。

**历史曲线**：每分钟 1 条落盘，支持 1 小时 / 24 小时 / 7 天 / 30 天；x 轴按真实时间，数据缺口自动断线，睡眠唤醒重置差分基线。

**阈值告警**：CPU 持续 ≥90% 满 30 秒 / 内存压力严重 / 磁盘可用 <8% / 电池健康 5 天内掉 ≥2 点。

## 说明

- **数据全部只读**：IOKit / Mach / sysctl / getifaddrs / launchd，不装任何内核扩展，不触发授权弹窗
- **不联网**：没有任何遥测或更新检查；联网行为只发生在你自己点「网络体检」和 SSH 探测时
- 温度与功耗走 Apple Silicon 的 SMC / IOReport 通道，**Intel 机器未测试**

完整说明、数据来源与已知边界、命令行工具、架构见 [README](https://github.com/isaleafa/Vitals#readme)。
