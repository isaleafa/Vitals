import SwiftUI

/// 电源详情页（Pulse）：复刻参考面板——电量/输入功率/适配器/支持档位（当前档位绿点）/循环次数/健康度双口径。
struct PowerPage: View {
    @ObservedObject var state: AppState

    private var power: PowerStats { state.snapshot.power }

    var body: some View {
        PageShell(state: state,
                  title: "电源 · Pulse",
                  subtitle: statusText) {
            SectionBox(title: "电池") {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: state.menuBarSymbol).font(.system(size: 22))
                    Text("\(power.charge)%")
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary)
                        if let cycles = power.cycles {
                            Text("循环次数 \(cycles)").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
                // 两条线共用一条 Y 轴：插电时橙线有值、紫线归零；拔电时反过来
                SparklineChart(series: [
                    (values: state.inputPowerHistory, color: .orange),
                    (values: state.dischargePowerHistory, color: .purple),
                ])
                .frame(height: 44)
                HStack(spacing: 14) {
                    LegendDot(color: .orange, text: "输入功率（插电才有）")
                    LegendDot(color: .purple, text: "放电功率（拔电才有）")
                    Spacer()
                    Text("当前：\(power.powerLabel)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(power.externalPower ? Color.orange : Color.purple)
                }
                Text("两条线共用一条纵轴，所以插拔时能看出哪条归零；更长周期看下面的「功率历史」。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)

                InfoRow(label: "充电状态", value: statusText, mono: false)
                if power.externalPower {
                    InfoRow(label: "输入电压", value: String(format: "%.2f V", power.inputVoltage))
                    InfoRow(label: "输入电流", value: String(format: "%.0f mA", power.inputCurrent))
                    InfoRow(label: "输入功率", value: String(format: "%.1f W", power.inputWatts), color: .orange)
                } else {
                    InfoRow(label: "放电功率", value: String(format: "%.1f W", power.dischargeWatts), color: .orange)
                    if let millivolts = power.batteryVoltage {
                        InfoRow(label: "电池电压", value: String(format: "%.2f V", Double(millivolts) / 1000))
                    }
                    if let milliamps = power.batteryCurrent {
                        InfoRow(label: "电池电流", value: "\(milliamps) mA")
                    }
                    Text("拔电后没有「输入功率」这回事——上面显示的是电池放电功率（约等于当前系统负载）。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                InfoRow(label: "电池温度",
                        value: state.snapshot.thermal.batteryTemp.map { String(format: "%.1f °C", $0) } ?? "—",
                        color: .pink)
                InfoRow(label: "电池健康度", value: healthText, mono: false)
            }

            HistorySection(state: state, title: "功率历史",
                           series: [(points: state.historyBundle.powerIn, color: .orange),
                                    (points: state.historyBundle.powerDis, color: .purple)],
                           unit: "W", decimals: 1)

            HistorySection(state: state, title: "电池健康趋势",
                           series: [(points: state.historyBundle.healthOfficial, color: .teal),
                                    (points: state.historyBundle.healthRaw, color: .orange)],
                           unit: "%", decimals: 1, zeroBased: false)

            SectionBox(title: "容量与循环") {
                let power = state.snapshot.power
                InfoRow(label: "官方最大容量", value: power.healthOfficialPercent.map { "\($0)%" } ?? "—", color: .teal)
                InfoRow(label: "自算容量比", value: power.healthRawPercent.map { String(format: "%.1f%%", $0) } ?? "—", color: .orange)
                InfoRow(label: "满充 / 设计容量",
                        value: "\(power.fullChargeCapacity.map(String.init) ?? "—") / \(power.designCapacity.map(String.init) ?? "—") mAh")
                InfoRow(label: "循环次数", value: power.cycles.map(String.init) ?? "—")
                Text("健康度两个口径都在图上（青=官方 %，橙=容量比 %）；变化很慢，按 24 小时/7 天/30 天看才有意义——30 天档是历史保留上限。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            SectionBox(title: "适配器") {
                if !power.externalPower {
                    Text("未接电源（适配器信息只在插电时才有）")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    InfoRow(label: "名称", value: power.vendorName ?? "未知厂商（VID 库里还没有）", mono: false)
                    InfoRow(label: "额定功率", value: power.adapterWatts.map { "\($0) W" } ?? "—")
                    InfoRow(label: "当前档位", value: currentGearText)
                    InfoRow(label: "PD 版本", value: power.pdRevision.map { "PD \($0).0" } ?? "—")
                    InfoRow(label: "厂商 / VID", value: vendorText, mono: false)
                }
            }

            SectionBox(title: "支持档位") {
                if power.gears.isEmpty {
                    Text("（未接电源，或这台充电器没上报档位）")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                ForEach(power.gears) { gear in
                    HStack(spacing: 8) {
                        Image(systemName: gear.index == power.activeGear ? "circle.inset.filled" : "circle")
                            .font(.system(size: 9))
                            .foregroundStyle(gear.index == power.activeGear ? Color.green : Color.secondary)
                        Text(gear.text).font(.system(size: 11, design: .monospaced))
                        Spacer()
                        Text(gear.wattsText).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var statusText: String {
        if power.charging { return "充电中" }
        if power.externalPower { return power.charge >= 100 ? "已接通电源（已充满）" : "已接通电源（未充电）" }
        return "电池供电"
    }

    private var currentGearText: String {
        guard let voltage = power.adapterVoltage, let current = power.adapterCurrent, voltage > 0 else { return "—" }
        return String(format: "%g V / %.2f A", Double(voltage) / 1000, Double(current) / 1000)
    }

    private var vendorText: String {
        var parts: [String] = []
        if let name = power.vendorName { parts.append(name) }
        if let vid = power.adapterVID { parts.append(String(format: "0x%04X", vid)) }
        if let pid = power.adapterPID { parts.append(String(format: "PID 0x%04X", pid)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var healthText: String {
        var parts: [String] = []
        if let official = power.healthOfficialPercent {
            let suffix = power.healthOfficialText.map { " \($0)" } ?? ""
            parts.append("\(official)%（官方口径\(suffix)）")
        }
        if let raw = power.healthRawPercent {
            let design = power.designCapacity.map { "\($0)" } ?? "?"
            let full = power.fullChargeCapacity.map { "\($0)" } ?? "?"
            parts.append(String(format: "%.1f%%（容量比 %@/%@ mAh）", raw, full, design))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: "  ·  ")
    }
}
