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
            Button(action: {
                let urlStr = ProviderManager.shared.activeProvider?.developerPlatformURL ?? ""
                guard !urlStr.isEmpty, let url = URL(string: urlStr) else { return }
                // 先尝试默认浏览器，失败再 fallback 到 Safari
                let ok = NSWorkspace.shared.open(url)
                if !ok,
                   let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
                    NSWorkspace.shared.open([url],
                        withApplicationAt: safariURL,
                        configuration: NSWorkspace.OpenConfiguration())
                }
            }) {
                Text(stats.providerName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(4)
            .help(ProviderManager.shared.activeProvider?.developerPlatformURL ?? "")
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
        if stats.isWarningBalance { return .orange }
        return .green
    }

    private var statusText: String {
        if stats.isLoading { return Strings.badgeLoading }
        if stats.errorMessage != nil { return Strings.badgeError }
        if stats.isWarningBalance { return Strings.badgeWarning }
        return Strings.badgeNormal
    }

    private var statusBadgeBackground: Color {
        if stats.isLoading { return Color.gray.opacity(0.1) }
        if stats.errorMessage != nil { return Color.orange.opacity(0.1) }
        if stats.isLowBalance { return Color.red.opacity(0.08) }
        if stats.isWarningBalance { return Color.orange.opacity(0.08) }
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
                if !stats.providerIsFree {
                    Text("¥")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] }
                }
                Text(stats.balanceText.replacingOccurrences(of: "¥", with: ""))
                    .font(.system(size: 18, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(balanceColor)
            }

            if stats.grantedBalance > 0 || stats.toppedUpBalance > 0 {
                HStack(spacing: 12) {
                    Label(stats.toppedUpText, systemImage: "creditcard.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.blue)
                    Label(stats.grantedText, systemImage: "gift.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.green)
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
        if stats.isWarningBalance { return .orange }
        return .green
    }

    private var balanceColor: Color {
        if stats.isLowBalance { return stats.blinkOn ? .red : .red.opacity(0.4) }
        if stats.isWarningBalance { return .orange }
        return Color(nsColor: .labelColor)
    }

    private var infoSection: some View {
        VStack(spacing: 4) {
            infoRow(icon: "bell.fill", iconColor: .orange, label: Strings.thresholdLabel, value: String(format: "¥%.0f", stats.threshold), valueColor: .orange)
            infoRow(icon: "star.fill", iconColor: .yellow, label: Strings.defaultModelLabel2, value: stats.defaultModelText)
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
                    if u.cachedTokens > 0 { usageRow("square.split.2x2", .teal, Strings.cachedTokensLabel, String(format: "%.0f%%", u.cacheHitRate)) }
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
        Task { @MainActor in
            let store = UsageStore.shared
            let pid = stats.providerID.isEmpty ? nil : stats.providerID
            switch usagePeriod {
            case 0:
                usageData = await store.queryDaily(limit: 1, providerId: pid).first
                chartData = await store.queryHourlyBreakdown(providerId: pid)
            case 1:
                usageData = await store.queryWeekly(limit: 1, providerId: pid).first
                chartData = await store.queryDailyBreakdown(providerId: pid)
            default:
                usageData = await store.queryMonthly(limit: 1, providerId: pid).first
                chartData = await store.queryWeeklyBreakdown(providerId: pid)
            }
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
                loadUsage()
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

