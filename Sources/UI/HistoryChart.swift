import SwiftUI

/// 历史曲线区块：周期切换（1 小时 / 24 小时 / 7 天）+ 折线 + 最值/均值 + 时间轴端点。
/// 数据来自 `state.historyBundle`（在后台按周期聚合好）。
struct HistorySection: View {
    @ObservedObject var state: AppState
    let title: String
    let series: [(points: [HistoryPoint], color: Color)]
    let unit: String
    var decimals: Int = 0
    var zeroBased = true

    private var allPoints: [HistoryPoint] { series.flatMap(\.points) }

    var body: some View {
        SectionBox(title: title) {
            Picker("", selection: $state.historyPeriod) {
                ForEach(HistoryPeriod.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if allPoints.isEmpty {
                Text("还没有历史数据——本应用运行满 1 分钟后开始记录（每分钟 1 点，保留 30 天）。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                HistoryChartView(series: series,
                                 bucket: state.historyPeriod.bucketSeconds,
                                 zeroBased: zeroBased)
                    .frame(height: 90)
                HStack(spacing: 14) {
                    ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                        LegendDot(color: item.color, text: "\(caption(item.points)) \(unit)")
                    }
                    Spacer()
                    let values = allPoints.map(\.value)
                    if let maxValue = values.max(), let minValue = values.min(), !values.isEmpty {
                        Text("最大 \(format(maxValue)) · 最小 \(format(minValue)) · 均值 \(format(values.reduce(0, +) / Double(values.count))) \(unit)")
                            .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                HStack {
                    Text(Self.clock.string(from: Date(timeIntervalSince1970: TimeInterval(allPoints.first?.t ?? 0))))
                    Spacer()
                    Text(Self.clock.string(from: Date(timeIntervalSince1970: TimeInterval(allPoints.last?.t ?? 0))))
                }
                .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }

    private func caption(_ points: [HistoryPoint]) -> String {
        guard let last = points.last else { return "—" }
        return "当前 \(format(last.value))"
    }

    private func format(_ value: Double) -> String {
        decimals == 0 ? String(format: "%.0f", value) : String(format: "%.\(decimals)f", value)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

/// 折线本体：x 按**真实时间**映射（数据有缺口时不连线——比如应用没运行或机器在睡觉）。
struct HistoryChartView: View {
    let series: [(points: [HistoryPoint], color: Color)]
    let bucket: TimeInterval
    var zeroBased = true

    var body: some View {
        GeometryReader { geo in
            let all = series.flatMap(\.points)
            let t0 = all.map(\.t).min() ?? 0
            let t1 = max(all.map(\.t).max() ?? t0 + 1, t0 + 1)
            let values = all.map(\.value)
            let low = min(values.min() ?? 0, zeroBased ? 0 : .greatestFiniteMagnitude)
            let high = max(values.max() ?? 1, low + 0.0001)
            ZStack {
                if zeroBased, low < 0 {
                    // 有空时再画零线（目前数据都是非负，留个口）
                    Path { path in
                        let y = self.y(0, low: low, high: high, height: geo.size.height)
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                }
                ForEach(Array(series.enumerated()), id: \.offset) { index, item in
                    let segments = segment(item.points, gap: bucket * 2.5)
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, points in
                        // 第一条线带淡填充，便于看趋势
                        if index == 0, points.count > 1 {
                            Path { path in
                                let first = project(points[0], t0: t0, t1: t1, low: low, high: high, size: geo.size)
                                path.move(to: CGPoint(x: first.x, y: geo.size.height))
                                for point in points {
                                    path.addLine(to: project(point, t0: t0, t1: t1, low: low, high: high, size: geo.size))
                                }
                                let last = project(points[points.count - 1], t0: t0, t1: t1, low: low, high: high, size: geo.size)
                                path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                                path.closeSubpath()
                            }
                            .fill(item.color.opacity(0.12))
                        }
                        Path { path in
                            guard let first = points.first else { return }
                            path.move(to: project(first, t0: t0, t1: t1, low: low, high: high, size: geo.size))
                            for point in points.dropFirst() {
                                path.addLine(to: project(point, t0: t0, t1: t1, low: low, high: high, size: geo.size))
                            }
                        }
                        .stroke(item.color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .drawingGroup()
    }

    /// 时间上有大缺口（超过 2.5 个桶）就断开，避免画出一条"其实没数据"的线。
    private func segment(_ points: [HistoryPoint], gap: TimeInterval) -> [[HistoryPoint]] {
        var result: [[HistoryPoint]] = []
        var current: [HistoryPoint] = []
        for point in points {
            if let last = current.last, Double(point.t - last.t) > gap {
                if current.count > 1 { result.append(current) }
                current = []
            }
            current.append(point)
        }
        if current.count > 1 { result.append(current) }
        return result
    }

    private func project(_ point: HistoryPoint, t0: Int, t1: Int, low: Double, high: Double, size: CGSize) -> CGPoint {
        let x = CGFloat(Double(point.t - t0) / Double(t1 - t0)) * size.width
        return CGPoint(x: x, y: y(point.value, low: low, high: high, height: size.height))
    }

    private func y(_ value: Double, low: Double, high: Double, height: CGFloat) -> CGFloat {
        let ratio = (value - low) / (high - low)
        return height - CGFloat(ratio) * (height - 4) - 2
    }
}
