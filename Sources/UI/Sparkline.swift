import SwiftUI

/// 单条迷你曲线（总览卡片用）。
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var filled = true

    var body: some View {
        SparklineChart(series: [(values: values, color: color)], filled: filled)
    }
}

/// 多条迷你曲线，**共用同一条 Y 轴**（详情页用，比如"输入功率 vs 放电功率"两条线）。
struct SparklineChart: View {
    var series: [(values: [Double], color: Color)]
    var filled = false

    var body: some View {
        GeometryReader { geo in
            let scale = Scale(series: series, size: geo.size)
            ZStack {
                if filled, let only = series.first {
                    let points = scale.points(only.values)
                    if points.count > 1 {
                        Path { path in
                            path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                            for point in points { path.addLine(to: point) }
                            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                            path.closeSubpath()
                        }
                        .fill(only.color.opacity(0.14))
                    }
                }
                ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                    Path { path in
                        let points = scale.points(item.values)
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(item.color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .drawingGroup()   // 合到一层离屏渲染，减少每秒重绘开销
    }

    /// 把多条线的数据映射到同一坐标系（所以"哪条归零"一眼可见）。
    private struct Scale {
        let count: Int
        let low: Double
        let span: Double
        let size: CGSize

        init(series: [(values: [Double], color: Color)], size: CGSize) {
            let numbers = series.flatMap(\.values)
            let low = numbers.min() ?? 0
            let high = numbers.max() ?? 1
            self.count = series.map(\.values.count).max() ?? 0
            self.low = low
            self.span = max(high - low, 0.0001)   // 全平时给最小跨度，别除零
            self.size = size
        }

        func points(_ values: [Double]) -> [CGPoint] {
            guard values.count > 1, size.width > 1, count > 1 else { return [] }
            let step = size.width / CGFloat(count - 1)
            return values.enumerated().map { index, value in
                let y = size.height - CGFloat((value - low) / span) * (size.height - 3) - 1.5
                return CGPoint(x: CGFloat(index) * step, y: y)
            }
        }
    }
}
