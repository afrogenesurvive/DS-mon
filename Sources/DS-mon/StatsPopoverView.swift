import SwiftUI
import AppKit
import Charts

// MARK: - SwiftUI 弹出内容

struct StatsPopoverView: View {
    let stats: DeepSeekStats

    /// 版本号：优先读 Info.plist，fallback 到硬编码（SPM debug 模式）
    private var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().padding(.horizontal, 14)
            balanceSection
            Divider().padding(.horizontal, 14)
            infoSection
            Divider().padding(.horizontal, 14)
            usageSection
            Spacer()
            Divider().padding(.horizontal, 14)
            actionBar
        }
        .padding(.vertical, 12)
        .onAppear { loadUsage() }
        .onReceive(NotificationCenter.default.publisher(for: .usageRecorded)) { _ in
            loadUsage()
        }
    }

    private var headerSection: some View {
        HStack(spacing: 6) {
            Text("DS-mon")
                .font(.system(size: 13, weight: .semibold))
            Text("v\(versionString)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            statusBadge
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            StatusDotView(color: statusIndicatorColor, size: 7)
            Text(statusText)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusBadgeBackground)
        .cornerRadius(8)
    }

    private var statusIndicatorColor: Color {
        if stats.isLoading { return .gray }
        if stats.errorMessage != nil { return .orange }
        if stats.isLowBalance { return stats.blinkOn ? .red : .red.opacity(0.4) }
        return .green
    }

    private var statusText: String {
        if stats.isLoading { return Strings.badgeLoading }
        if stats.errorMessage != nil { return Strings.badgeError }
        return Strings.badgeNormal
    }

    private var statusBadgeBackground: Color {
        if stats.isLoading { return Color.gray.opacity(0.1) }
        if stats.errorMessage != nil { return Color.orange.opacity(0.1) }
        if stats.isLowBalance { return Color.red.opacity(0.08) }
        return Color.green.opacity(0.1)
    }

    private var balanceSection: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                StatusDotView(color: statusDotColor, size: 6)
                Text(Strings.currentBalance)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Text("¥")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] }
                Text(stats.balanceText.replacingOccurrences(of: "¥", with: ""))
                    .font(.system(size: 18, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(balanceColor)
            }

            if stats.grantedBalance > 0 || stats.toppedUpBalance > 0 {
                HStack(spacing: 12) {
                    Label(stats.grantedText, systemImage: "gift.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.green)
                    Label(stats.toppedUpText, systemImage: "creditcard.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.blue)
                    Spacer()
                }
                .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var statusDotColor: Color {
        if stats.isLoading { return .gray }
        if stats.errorMessage != nil { return .orange }
        if stats.isLowBalance { return stats.blinkOn ? .red : .red.opacity(0.4) }
        return .green
    }

    private var balanceColor: Color {
        if stats.isLowBalance { return stats.blinkOn ? .red : .red.opacity(0.4) }
        return Color(nsColor: .labelColor)
    }

    private var infoSection: some View {
        VStack(spacing: 4) {
            infoRow(icon: "bell.fill", iconColor: .orange, label: Strings.thresholdLabel, value: String(format: "¥%.0f", stats.threshold), valueColor: .orange)
            infoRow(icon: "cube.2.fill", iconColor: .teal, label: Strings.availableModels, value: stats.modelsText)
            infoRow(icon: stats.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    iconColor: stats.isAvailable ? .green : .red,
                    label: Strings.accountStatus,
                    value: stats.availabilityText,
                    valueColor: stats.isAvailable ? .green : .red)
            if let error = stats.errorMessage {
                infoRow(icon: "exclamationmark.triangle.fill", iconColor: .orange, label: Strings.errorLabel, value: error, valueColor: .orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func infoRow(icon: String, iconColor: Color, label: String, value: String, valueColor: Color = .secondary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundColor(iconColor)
                .frame(width: 12)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10))
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Usage Stats

    @State private var usagePeriod: Int = 0  // 0=today, 1=week, 2=month
    @State private var usageData: AggregatedUsage?
    @State private var chartData: [TokenBar] = []

    private var usageSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text(Strings.usageTitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 2) {
                    pillTab(Strings.todayLabel, tag: 0)
                    pillTab(Strings.weekLabel, tag: 1)
                    pillTab(Strings.monthLabel, tag: 2)
                }
                .font(.system(size: 10))
                .onChange(of: usagePeriod) { _, _ in loadUsage() }
            }

            if let u = usageData, u.requestCount > 0 {
                VStack(spacing: 5) {
                    usageRow("arrow.left.arrow.right", .blue, Strings.requestsLabel, Strings.requestsCount(u.requestCount))
                    usageRow("text.word.spacing", .blue.opacity(0.7), Strings.totalTokensLabel, Strings.tokensShort(u.totalTokens))
                    usageRow("square.split.2x2", .teal, Strings.cachedTokensLabel, String(format: "%.0f%%", u.cacheHitRate))
                    if u.reasoningTokens > 0 {
                        usageRow("brain.head.profile", .orange, Strings.reasoningTokensLabel, Strings.tokensShort(u.reasoningTokens))
                    }
                    usageRow("yensign.circle", .orange, Strings.costLabel, Strings.costShort(u.estimatedCost))
                    usageRow("stopwatch", .teal.opacity(0.7), Strings.latencyLabel, Strings.latencyMsFormat(u.avgLatencyMs))
                }

                if !chartData.isEmpty {
                    UsageBarChart(data: chartData, frameWidth: 262)
                        .frame(height: 120)
                        .padding(.top, 10)
                }
            } else {
                HStack {
                    Spacer()
                    Text(Strings.noUsageData)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func usageRow(_ icon: String, _ color: Color, _ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundColor(color)
                .frame(width: 12)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.primary)
        }
    }

    private func loadUsage() {
        let store = UsageStore.shared
        switch usagePeriod {
        case 0:
            usageData = store.queryDaily(limit: 1).first
            chartData = store.queryHourlyBreakdown()
        case 1:
            usageData = store.queryWeekly(limit: 1).first
            chartData = store.queryDailyBreakdown()
        default:
            usageData = store.queryMonthly(limit: 1).first
            chartData = store.queryWeeklyBreakdown()
        }
    }

    private func pillTab(_ label: String, tag: Int) -> some View {
        let active = usagePeriod == tag
        return Text(label)
            .foregroundColor(active ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(active ? Color(nsColor: .selectedControlColor).opacity(0.4) : .clear)
            .cornerRadius(6)
            .onTapGesture { usagePeriod = tag }
    }

    private var actionBar: some View {
        HStack(spacing: 4) {
            Spacer()

            actionButton(icon: "arrow.clockwise", label: Strings.refresh, color: .blue) {
                stats.refresh()
            }
            actionButton(icon: "gearshape", label: Strings.settings, color: .secondary) {
                StatusBarController.shared.closePopover()
                StatusBarController.shared.showSettings()
            }
            actionButton(icon: "power", label: Strings.quit, color: .red) {
                StatusBarController.shared.closePopover()
                let alert = NSAlert()
                alert.messageText = Strings.quitTitle
                alert.informativeText = Strings.quitMessage
                alert.alertStyle = .informational
                alert.addButton(withTitle: Strings.quitConfirm)
                alert.addButton(withTitle: Strings.cancel)
                if alert.runModal() == .alertFirstButtonReturn {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private func actionButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(label)
                    .font(.system(size: 10))
            }
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

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

    private var chartView: some View {
        let chart = Chart(segments) { seg in
            BarMark(
                x: .value("Time", seg.label),
                y: .value("Tokens", seg.value)
            )
            .foregroundStyle(by: .value("Type", seg.type))
        }
        return chart
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