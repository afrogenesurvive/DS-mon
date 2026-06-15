import SwiftUI
import Charts
// MARK: - 柱状图

struct UsageBarChart: View {
    let data: [TokenBar]
    let frameWidth: CGFloat
    @State private var hoveredLabel: String?
    @State private var pendingLabel: String?
    @State private var hoverTask: Task<Void, Never>?
    @State private var hoverLocation: CGPoint?

    private var hoveredBar: TokenBar? {
        guard let label = hoveredLabel else { return nil }
        return data.first { $0.label == label }
    }

    private var hasData: Bool {
        guard let bar = hoveredBar else { return false }
        return bar.hitTokens > 0 || bar.missTokens > 0 || bar.outTokens > 0
    }

    private var segments: [TokenBarSegment] {
        data.flatMap { bar in
            [
                TokenBarSegment(label: bar.label, type: Strings.chartOut, value: bar.outTokens),
                TokenBarSegment(label: bar.label, type: Strings.chartMiss, value: bar.missTokens),
                TokenBarSegment(label: bar.label, type: Strings.chartHit, value: bar.hitTokens),
            ]
        }
    }

    var body: some View {
        chartView
            .overlay(alignment: .topLeading) {
                if let bar = hoveredBar, hasData, let loc = hoverLocation {
                    tooltipContent(bar)
                        .fixedSize()
                        .offset(x: clampTooltipX(mouseX: loc.x),
                                y: max(loc.y - 56, 4))
                }
            }
    }

    /// 将 tooltip 的 x 偏移钳制在 [4, frameWidth - tooltipW - 4] 内
    private func clampTooltipX(mouseX: CGFloat) -> CGFloat {
        let tooltipW: CGFloat = 180
        let margin: CGFloat = 4
        let rawX = mouseX < frameWidth * 0.5 ? mouseX + 14 : mouseX - tooltipW
        return max(margin, min(rawX, frameWidth - tooltipW - margin))
    }

    private var requestScale: Double {
        let maxTokens = data.map { $0.missTokens + $0.hitTokens + $0.outTokens }.max() ?? 1
        let maxCount = data.map { $0.requestCount }.max() ?? 1
        return maxCount > 0 ? Double(maxTokens) / Double(maxCount) * 0.35 : 1
    }

    private var chartView: some View {
        Chart {
            ForEach(segments) { seg in
                BarMark(
                    x: .value("Time", seg.label),
                    y: .value("Tokens", seg.value)
                )
                .foregroundStyle(by: .value("Type", seg.type))
            }
            let scale = requestScale
            ForEach(data) { bar in
                LineMark(
                    x: .value("Time", bar.label),
                    y: .value("Requests", Double(bar.requestCount) * scale)
                )
                .foregroundStyle(.orange)
                .lineStyle(StrokeStyle(lineWidth: 0.75))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartForegroundStyleScale(foregroundScale)
        .chartLegend(position: .bottom, spacing: 4)
        .chartXAxis {
            if data.count <= 12 {
                AxisMarks { value in
                    AxisValueLabel(anchor: .top)
                        .font(.system(size: 7))
                }
            }
        }
        .chartYAxis {
            AxisMarks { val in
                AxisGridLine()
                    .foregroundStyle(.tertiary)
                if let n = val.as(Int.self) {
                    AxisValueLabel(anchor: .leading) {
                        Text(Strings.tokensShort(n))
                            .font(.system(size: 7))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in chartOverlay(proxy: proxy) }
    }

    private var foregroundScale: KeyValuePairs<String, Color> {
        [
            Strings.chartHit: Color(red: 0.53, green: 0.81, blue: 0.98),
            Strings.chartMiss: Color(red: 0.37, green: 0.63, blue: 0.92),
            Strings.chartOut: Color(red: 0.22, green: 0.46, blue: 0.85),
        ]
    }

    private func chartOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let origin = (proxy.plotFrame.flatMap { geometry[$0] } ?? .zero).origin
                        let pt = CGPoint(
                            x: location.x - origin.x,
                            y: location.y - origin.y
                        )
                        let val: (String, Int)? = proxy.value(at: pt, as: (String, Int).self)
                        let label = val?.0
                        let onBars = (val?.1 ?? 0) > 0
                        hoverLocation = onBars ? location : nil
                        if onBars, label != pendingLabel {
                            hoverTask?.cancel()
                            pendingLabel = label
                            hoveredLabel = nil
                            if let label, data.first(where: { $0.label == label }).map({ $0.hitTokens > 0 || $0.missTokens > 0 || $0.outTokens > 0 }) == true {
                                hoverTask = Task {
                                    try? await Task.sleep(nanoseconds: 300_000_000)
                                    if !Task.isCancelled {
                                        hoveredLabel = label
                                    }
                                }
                            }
                        } else if !onBars {
                            hoverTask?.cancel()
                            pendingLabel = nil
                            hoveredLabel = nil
                        }
                    case .ended:
                        hoverTask?.cancel()
                        pendingLabel = nil
                        hoveredLabel = nil
                        hoverLocation = nil
                    }
                }
        }
    }

    @ViewBuilder
    private func tooltipContent(_ bar: TokenBar) -> some View {
        let total = bar.missTokens + bar.hitTokens + bar.outTokens
        let input = bar.missTokens + bar.hitTokens
        let hitRate = input > 0 ? Double(bar.hitTokens) / Double(input) * 100 : 0
        VStack(alignment: .trailing, spacing: 2) {
            HStack {
                Text(bar.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Text("\(Strings.chartTotal) \(total)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.primary)
            }
            Divider()
            tooltipRow(Strings.requestsLabel, "\(bar.requestCount)")
            tooltipRow(Strings.chartHit, bar.hitTokens, color: Color(red: 0.53, green: 0.81, blue: 0.98))
            tooltipRow(Strings.chartMiss, bar.missTokens, color: Color(red: 0.37, green: 0.63, blue: 0.92))
            tooltipRow(Strings.chartOut, bar.outTokens, color: Color(red: 0.22, green: 0.46, blue: 0.85))
            tooltipRow(Strings.cachedTokensLabel, String(format: "%.0f%%", hitRate))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.regularMaterial)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
    }

    private func tooltipRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.primary)
        }
    }

    private func tooltipRow(_ label: String, _ value: Int, color: Color? = nil) -> some View {
        HStack(spacing: 8) {
            if let color {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Spacer(minLength: 16)
            Text("\(value)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.primary)
        }
    }
}

struct TokenBarSegment: Identifiable {
    let label: String
    let type: String
    let value: Int
    var id: String { "\(label)-\(type)" }
}

struct LegendEntry: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundColor(.secondary)
        }
    }
}

// MARK: - 矩形立体指示灯（SwiftUI）

/// 小圆角矩形指示灯：顶部高光 + 底部暗面 + 外发光
struct StatusDotView: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .overlay {
                LinearGradient(
                    colors: [.white.opacity(0.25), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.4), radius: 3, x: 0, y: 0)
    }
}