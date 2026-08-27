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

    @State private var selectedTab: Int = 0
    @State private var licenseSeats: [SeatRecord] = []
    @State private var licenseFilter: LicenseSeatFilter = .valid

    // 折叠区段状态（DeepSeek 页）
    @State private var showAccountSection = true    // 余额/充值/提示行
    @State private var showUsageStatsSection = true // 用量统计
    @State private var showUsageListSection = true  // 请求列表/图表
    @State private var showSourceUsageSection = true // 来源用量（图表/列表）

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            appTitleRow
            providerTabRow
            Divider().padding(.horizontal, 14)
            tabBar
            Divider().padding(.horizontal, 14)
            if selectedTab == 0 {
                ScrollView {
                    deepSeekTabContent
                }
            } else {
                ScrollView {
                    if selectedTab == 1 { licenseTabContent }
                    else if selectedTab == 2 { gitHubTabContent }
                    else { awsTabContent }
                }
            }
            Divider().padding(.horizontal, 14)
            actionBar
        }
        .padding(.vertical, 16)
        .frame(width: AppConfig.popoverWidth)
        .frame(maxHeight: 550)
        .scrollIndicators(.hidden)
        .onAppear { loadUsage(); loadSourceUsage(); loadSourceOptions() }
        .onReceive(NotificationCenter.default.publisher(for: .usageRecorded)) { _ in
            loadUsage(); loadSourceUsage(); loadSourceOptions()
        }
        .onChange(of: stats.providerID) { _, _ in loadUsage(); loadSourceUsage(); loadSourceOptions() }
    }

    private var appTitleRow: some View {
        HStack(spacing: 6) {
            Text("dev_mon")
                .font(.system(size: 13, weight: .semibold))
            Text("v\(versionString)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            statusBadge
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // 提供商标签行：样式与 Usage/License 等 tab 一致
    private var providerTabRow: some View {
        HStack(spacing: 4) {
            ForEach(ProviderManager.shared.providers, id: \.id) { provider in
                providerTabButton(provider)
            }
            Spacer()
            iconButton(icon: "arrow.up.right.square", label: Strings.openConsole, color: .blue,
                       action: openConsole)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func providerTabButton(_ provider: any Provider) -> some View {
        let active = stats.providerID == provider.id
        let tint = providerTint(provider.id)
        let tooltipFormat = provider.isSpendBased
            ? Strings.providerTabTooltipSpend
            : Strings.providerTabTooltipBalance
        return Button {
            ProviderManager.shared.setDefaultProvider(id: provider.id)
        } label: {
            ProviderLogo(provider: provider, size: 12)
                .modifier(IconButtonChrome(color: tint, active: active))
        }
        .buttonStyle(.plain)
        .modifier(HoverTooltip(text: String(format: tooltipFormat, provider.name), position: .below))
        .fixedSize()
    }

    private func openConsole() {
        let urlStr = ProviderManager.shared.activeProvider?.developerPlatformURL ?? ""
        guard !urlStr.isEmpty, let url = URL(string: urlStr) else { return }
        let ok = NSWorkspace.shared.open(url)
        if !ok,
           let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.open([url],
                withApplicationAt: safariURL,
                configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private var statusBadge: some View {
        StatusDotView(color: statusIndicatorColor, size: 7)
            .padding(.horizontal, 4)
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
                Text(stats.providerIsSpendBased ? Strings.monthSpend : Strings.currentBalance)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                if !stats.providerIsFree {
                    Text(Strings.currencySymbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] }
                }
                Text(stats.balanceText.replacingOccurrences(of: Strings.currencySymbol, with: ""))
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
                    Spacer()
                }
            }
            if stats.hasTokenUsageAPI {
                let tu = stats.tokenUsage
                if tu.inputTokens + tu.outputTokens + tu.cachedInputTokens > 0 {
                    HStack(spacing: 10) {
                        Label(String(format: Strings.tokenInputText, Self.compactTokens(tu.inputTokens)), systemImage: "arrow.down.left.circle")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                        Label(String(format: Strings.tokenOutputText, Self.compactTokens(tu.outputTokens)), systemImage: "arrow.up.right.circle")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                        Label(String(format: Strings.tokenCachedText, Self.compactTokens(tu.cachedInputTokens)), systemImage: "bolt.circle")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            if stats.providerIsSpendBased && stats.hasBudget {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 9)).foregroundColor(.secondary).frame(width: 14)
                    Text(Strings.monthlyBudgetLabel)
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%@%.2f", Strings.currencySymbol, stats.monthlyBudget))
                        .font(.system(size: 9).monospacedDigit())
                }
                HStack(spacing: 6) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 9)).foregroundColor(.secondary).frame(width: 14)
                    Text(Strings.balanceLabel)
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%@%.2f", Strings.currencySymbol, stats.remainingBudget))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundColor(stats.budgetFraction >= 0.8 ? .orange : .secondary)
                }
                Text(stats.budgetSourceText)
                    .font(.system(size: 7))
                    .foregroundColor(.secondary)
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
            infoRow(icon: "bell.fill", iconColor: .orange, label: Strings.thresholdLabel, value: "\(Strings.currencySymbol)\(String(format: "%.0f", stats.threshold))", valueColor: .orange)
            infoRow(icon: "star.fill", iconColor: .yellow, label: Strings.defaultModelLabel2, value: stats.defaultModelText)
            infoRow(icon: stats.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    iconColor: stats.isAvailable ? .green : .red,
                    label: Strings.accountStatus,
                    value: stats.availabilityText,
                    valueColor: stats.isAvailable ? .green : .red)
            if stats.supportsPricingWindow {
                infoRow(icon: stats.isPeakHour ? "sun.max.fill" : "moon.zzz.fill",
                        iconColor: stats.isPeakHour ? .yellow : .green,
                        label: Strings.pricingWindowLabel,
                        value: stats.pricingWindowDetailText,
                        valueColor: stats.isPeakHour ? .yellow : .green)
            }
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
    @State private var showChart = true

    // Source Usage section state
    @State private var usageSubTab = 0           // 0 = Usage Stats, 1 = Source Usage
    @State private var sourcePeriod = 0          // 0=today, 1=week, 2=month
    @State private var sourceShowChart = true
    @State private var sourceMode = 0            // 0 = aggregate, 1 = individual
    @State private var selectedSource = ""       // "" = all sources
    @State private var sourceData: [SourceUsage] = []
    @State private var sourceChartData: [TokenBar] = []
    @State private var sourceOptions: [String] = []
    @State private var aggregateSortKey = "cost"
    @State private var aggregateSortAsc = false

    private var usageSection: some View {
        VStack(spacing: 0) {
            CollapsibleSection(title: Strings.usageTitle, icon: "brain.head.profile",
                               isExpanded: $showUsageStatsSection) {
                usageStatsContent
            }
            CollapsibleSection(title: Strings.requestHistoryTitle, icon: "chart.bar",
                               isExpanded: $showUsageListSection) {
                usageListContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var usageStatsContent: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 2) {
                    pillTab(Strings.todayLabel, tag: 0, selection: $usagePeriod)
                    pillTab(Strings.weekLabel, tag: 1, selection: $usagePeriod)
                    pillTab(Strings.monthLabel, tag: 2, selection: $usagePeriod)
                }
                .font(.system(size: 10))
                .onChange(of: usagePeriod) { _, _ in loadUsage() }
                Spacer()
                Button(action: { showChart.toggle() }) {
                    Image(systemName: showChart ? "list.bullet" : "chart.bar.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }

            if let u = usageData, u.requestCount > 0, usagePeriod != 0 || isTodayData(u) {
                VStack(spacing: 5) {
                    usageRow("arrow.left.arrow.right", .blue, Strings.requestsLabel, Strings.requestsCount(u.requestCount))
                    usageRow("text.word.spacing", .blue.opacity(0.7), Strings.totalTokensLabel, Strings.tokensShort(u.totalTokens))
                    if u.cachedTokens > 0 { usageRow("square.split.2x2", .teal, Strings.cachedTokensLabel, String(format: "%.0f%%", u.cacheHitRate)) }
                    if u.reasoningTokens > 0 {
                        usageRow("brain.head.profile", .orange, Strings.reasoningTokensLabel, Strings.tokensShort(u.reasoningTokens))
                    }
                    usageRow("yensign.circle", .orange, Strings.estimatedCostLabel, Strings.costShort(u.estimatedCost))
                    usageRow("stopwatch", .teal.opacity(0.7), Strings.latencyLabel, Strings.latencyMsFormat(u.avgLatencyMs))
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

    @ViewBuilder
    private var usageListContent: some View {
        Group {
            if let u = usageData, u.requestCount > 0, usagePeriod != 0 || isTodayData(u), !chartData.isEmpty {
                if showChart {
                    UsageBarChart(data: chartData, frameWidth: AppConfig.contentWidth)
                        .frame(height: 120)
                        .padding(.top, 10)
                } else {
                    RequestListView(frameWidth: AppConfig.contentWidth, providerId: activeUsageProviderId, since: usagePeriodStart)
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

    private func isTodayData(_ u: AggregatedUsage) -> Bool {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return u.period == f.string(from: Date())
    }

    private var activeUsageProviderId: String? {
        stats.providerID.isEmpty ? nil : stats.providerID
    }

    private var usagePeriodStart: Date? {
        let cal = Calendar.current
        switch usagePeriod {
        case 0: return cal.startOfDay(for: Date())
        case 1: return cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))
        default: return cal.date(from: cal.dateComponents([.year, .month], from: Date()))
        }
    }

    private func loadUsage() {
        Task { @MainActor in
            let store = UsageStore.shared
            let pid = activeUsageProviderId
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

    // MARK: - Source Usage

    private static let sourceTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd:MM:yyyy HH:mm"
        return f
    }()

    private func loadSourceOptions() {
        Task { @MainActor in
            sourceOptions = await UsageStore.shared.distinctSources()
            if !selectedSource.isEmpty && !sourceOptions.contains(selectedSource) {
                selectedSource = ""
            }
        }
    }

    private var sourcePeriodStart: Date? {
        let cal = Calendar.current
        switch sourcePeriod {
        case 0: return cal.startOfDay(for: Date())
        case 1: return cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))
        default: return cal.date(from: cal.dateComponents([.year, .month], from: Date()))
        }
    }

    private func loadSourceUsage() {
        let src = selectedSource.isEmpty ? nil : selectedSource
        let since = sourcePeriodStart
        Task { @MainActor in
            let store = UsageStore.shared
            let pid = activeUsageProviderId
            if sourceMode == 0 {
                let rows = await store.aggregateBySourceIP(since: since, sourceIP: src, providerId: pid)
                sourceData = rows
                sourceChartData = rows.map { item in
                    TokenBar(label: sourceDisplayName(item),
                             missTokens: item.promptTokens - item.cachedTokens,
                             hitTokens: item.cachedTokens,
                             outTokens: item.completionTokens,
                             requestCount: item.requestCount)
                }
            } else {
                switch sourcePeriod {
                case 0:
                    sourceChartData = await store.queryHourlyBreakdown(providerId: pid, sourceIP: src)
                case 1:
                    sourceChartData = await store.queryDailyBreakdown(providerId: pid, sourceIP: src)
                default:
                    sourceChartData = await store.queryWeeklyBreakdown(providerId: pid, sourceIP: src)
                }
            }
        }
    }

    private var sourceUsageSection: some View {
        VStack(spacing: 0) {
            CollapsibleSection(title: Strings.sourceUsageTitle, icon: "network",
                               isExpanded: $showSourceUsageSection) {
                VStack(spacing: 8) {
                    sourceToolbar
                    if sourceMode == 0 {
                        sourceAggregateContent
                    } else {
                        sourceIndividualContent
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var sourceToolbar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                sourceFilterMenu
                Spacer()
                modePills
                Button(action: { sourceShowChart.toggle() }) {
                    Image(systemName: sourceShowChart ? "list.bullet" : "chart.bar.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 2) {
                pillTab(Strings.todayLabel, tag: 0, selection: $sourcePeriod)
                pillTab(Strings.weekLabel, tag: 1, selection: $sourcePeriod)
                pillTab(Strings.monthLabel, tag: 2, selection: $sourcePeriod)
                Spacer()
            }
            .font(.system(size: 10))
            .onChange(of: sourcePeriod) { _, _ in loadSourceUsage() }
        }
        .onChange(of: sourceMode) { _, _ in loadSourceUsage() }
        .onChange(of: selectedSource) { _, _ in loadSourceUsage() }
    }

    private var sourceFilterMenu: some View {
        Menu {
            Button(Strings.allSources) { selectedSource = "" }
            if !sourceOptions.isEmpty { Divider() }
            ForEach(sourceOptions, id: \.self) { src in
                Button(src) { selectedSource = src }
            }
        } label: {
            HStack(spacing: 3) {
                Text(selectedSource.isEmpty ? Strings.allSources : selectedSource)
                    .font(.system(size: 9))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: 110, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .menuStyle(.borderlessButton)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(4)
    }

    private var modePills: some View {
        HStack(spacing: 2) {
            pillTab(Strings.aggregateLabel, tag: 0, selection: $sourceMode, hPad: 6)
            pillTab(Strings.individualLabel, tag: 1, selection: $sourceMode, hPad: 6)
        }
        .font(.system(size: 9))
    }

    private func sourceDisplayName(_ item: SourceUsage) -> String {
        item.sourceIP.isEmpty ? Strings.localSourceLabel : item.sourceIP
    }

    private var sortedSourceData: [SourceUsage] {
        sourceData.sorted { a, b in
            switch aggregateSortKey {
            case "source":
                let sa = sourceDisplayName(a), sb = sourceDisplayName(b)
                return aggregateSortAsc ? sa < sb : sa > sb
            case "pid":
                return aggregateSortAsc ? a.providerIds < b.providerIds : a.providerIds > b.providerIds
            case "req":
                return aggregateSortAsc ? a.requestCount < b.requestCount : a.requestCount > b.requestCount
            case "tokens":
                return aggregateSortAsc ? a.totalTokens < b.totalTokens : a.totalTokens > b.totalTokens
            case "last":
                return aggregateSortAsc ? a.lastTimestamp < b.lastTimestamp : a.lastTimestamp > b.lastTimestamp
            default:
                return aggregateSortAsc ? a.totalCost < b.totalCost : a.totalCost > b.totalCost
            }
        }
    }

    @ViewBuilder
    private func aggregateSortableHeader(_ title: String, key: String, width: CGFloat, align: Alignment) -> some View {
        Button {
            if aggregateSortKey == key {
                aggregateSortAsc.toggle()
            } else {
                aggregateSortKey = key
                aggregateSortAsc = false
            }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if aggregateSortKey == key {
                    Image(systemName: aggregateSortAsc ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7))
                }
            }
            .frame(width: width, alignment: align)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
    }

    @ViewBuilder
    private var sourceAggregateContent: some View {
        if sourceData.isEmpty {
            emptySourceState
        } else if sourceShowChart {
            UsageBarChart(data: sourceChartData, frameWidth: AppConfig.contentWidth)
                .frame(height: 120)
                .padding(.top, 6)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    aggregateSortableHeader("Source", key: "source", width: 60, align: .leading)
                    aggregateSortableHeader("pid", key: "pid", width: 46, align: .leading)
                    aggregateSortableHeader("Req", key: "req", width: 24, align: .trailing)
                    aggregateSortableHeader("Tokens", key: "tokens", width: 34, align: .trailing)
                    aggregateSortableHeader("Cost", key: "cost", width: 44, align: .trailing)
                    aggregateSortableHeader(Strings.lastSeenLabel, key: "last", width: 50, align: .trailing)
                }
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedSourceData, id: \.sourceIP) { item in
                            HStack(spacing: 6) {
                                Text(sourceDisplayName(item))
                                    .font(.system(size: 8.5))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: 60, alignment: .leading)
                                Text(item.providerIds.isEmpty ? "—" : item.providerIds)
                                    .font(.system(size: 8.5))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: 46, alignment: .leading)
                                    .foregroundColor(.secondary)
                                Text("\(item.requestCount)")
                                    .font(.system(size: 8.5).monospacedDigit())
                                    .frame(width: 24, alignment: .trailing)
                                Text(Strings.tokensShort(item.totalTokens))
                                    .font(.system(size: 8.5).monospacedDigit())
                                    .frame(width: 34, alignment: .trailing)
                                Text(Strings.costShort(item.totalCost))
                                    .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                                    .frame(width: 44, alignment: .trailing)
                                Text(Self.sourceTimeFormatter.string(from: item.lastTimestamp))
                                    .font(.system(size: 7).monospacedDigit())
                                    .frame(width: 50, alignment: .trailing)
                                    .foregroundColor(.secondary)
                                    .help(Strings.lastSeenLabel)
                            }
                            .foregroundColor(.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            if item.sourceIP != sortedSourceData.last?.sourceIP {
                                Divider().padding(.leading, 8)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 260)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var sourceListID: String {
        "\(selectedSource)|\(stats.providerID)|\(sourcePeriodStart?.timeIntervalSince1970 ?? 0)"
    }

    @ViewBuilder
    private var sourceIndividualContent: some View {
        if sourceShowChart {
            if sourceChartData.isEmpty {
                emptySourceState
            } else {
                UsageBarChart(data: sourceChartData, frameWidth: AppConfig.contentWidth)
                    .frame(height: 120)
                    .padding(.top, 6)
            }
        } else {
            SourceRequestListView(frameWidth: AppConfig.contentWidth, sourceIP: selectedSource, since: sourcePeriodStart, providerId: activeUsageProviderId)
                .id(sourceListID)
        }
    }

    private var emptySourceState: some View {
        HStack {
            Spacer()
            Text(Strings.noUsageData)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var usageSwitcher: some View {
        HStack(spacing: 4) {
            subTabButton(Strings.usageTitle, tag: 0)
            subTabButton(Strings.sourceUsageTitle, tag: 1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func subTabButton(_ title: String, tag: Int) -> some View {
        let active = usageSubTab == tag
        return Button(action: { usageSubTab = tag }) {
            Text(title)
                .font(.system(size: 10, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .white : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(active ? Color.blue : Color.clear)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .modifier(HoverTooltip(text: title, position: .below))
    }

    // MARK: - Cloud Helpers (reused by GitHub & AWS tabs)

    private static func compactTokens(_ n: Double) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", n / 1_000) }
        return String(format: "%.0f", n)
    }

    private func cloudRow(icon: String, color: Color, label: String, value: String, progress: Double, progressColor: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 8)).foregroundColor(color).frame(width: 14)
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            Spacer()
            ProgressBar(value: progress, color: progressColor)
                .frame(width: 60, height: 6)
            Text(value)
                .font(.system(size: 8).monospacedDigit())
        }
    }

    private func cloudStatusText(g: GitHubUsageTracker?, a: AWSUsageTracker?) -> String {
        if let gh = g {
            if gh.usage.isWithinFreeTier { return Strings.githubFreeStatus }
            if gh.usage.isMinutesWarning || gh.usage.isStorageWarning { return Strings.githubWarningStatus }
            return Strings.githubExceededStatus
        }
        if let aw = a {
            if aw.status.isWithinFreeTier { return Strings.awsFreeStatus }
            if aw.status.isWarning { return Strings.awsWarningStatus }
            return Strings.awsExceededStatus
        }
        return ""
    }

    private func cloudStatusColor(g: GitHubUsageTracker?, a: AWSUsageTracker?) -> Color {
        if let gh = g {
            if gh.usage.isWithinFreeTier { return .green }
            if gh.usage.isMinutesWarning || gh.usage.isStorageWarning { return .orange }
            return .red
        }
        if let aw = a {
            if aw.status.isWithinFreeTier { return .green }
            if aw.status.isWarning { return .orange }
            return .red
        }
        return .secondary
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(title: Strings.usageTabTitle, icon: "brain.head.profile", tag: 0, tooltip: Strings.usageTabTooltip)
            tabButton(title: Strings.licenseTabTitle, icon: "checkmark.shield.fill", tag: 1, tooltip: Strings.licenseTabTooltip)
            tabButton(title: "GitHub", icon: "logo.github", tag: 2, tooltip: Strings.githubTabTooltip)
            tabButton(title: "AWS", icon: "cloud.fill", tag: 3, tooltip: Strings.awsTabTooltip)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func tabButton(title: String, icon: String, tag: Int, tooltip: String) -> some View {
        let active = selectedTab == tag
        return Button(action: { selectedTab = tag }) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9))
                Text(title).font(.system(size: 10, weight: active ? .semibold : .regular))
            }
            .foregroundColor(active ? .white : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(active ? Color.blue : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .modifier(HoverTooltip(text: tooltip, position: .below))
    }

    // MARK: - DeepSeek Tab

    private var deepSeekTabContent: some View {
        VStack(spacing: 0) {
            CollapsibleSection(title: Strings.accountSectionTitle, icon: "wallet.pass.fill",
                               isExpanded: $showAccountSection) {
                balanceSection
                Divider().padding(.horizontal, 14)
                infoSection
            }
            usageSwitcher
            Divider().padding(.horizontal, 14)
            if usageSubTab == 0 {
                usageSection
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                sourceUsageSection
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    // MARK: - License Tab

    private enum LicenseSeatFilter: String, CaseIterable {
        case valid, revoked, expired
    }

    private var filteredLicenseSeats: [SeatRecord] {
        switch licenseFilter {
        case .valid: return licenseSeats.filter { !$0.revoked && !$0.isExpired }
        case .revoked: return licenseSeats.filter { $0.revoked }
        case .expired: return licenseSeats.filter { !$0.revoked && $0.isExpired }
        }
    }

    private var licenseFilterLabel: String {
        switch licenseFilter {
        case .valid: return Strings.licenseFilterValid
        case .revoked: return Strings.licenseFilterRevoked
        case .expired: return Strings.licenseFilterExpired
        }
    }

    private var licenseTabContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
                Text(Strings.licenseSection)
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Text(Strings.licenseSeatCount(licenseSeats.count))
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }

            Picker("", selection: $licenseFilter) {
                Text(Strings.licenseFilterValid).tag(LicenseSeatFilter.valid)
                Text(Strings.licenseFilterRevoked).tag(LicenseSeatFilter.revoked)
                Text(Strings.licenseFilterExpired).tag(LicenseSeatFilter.expired)
            }
            .pickerStyle(.segmented)
            .font(.system(size: 8))

            if licenseSeats.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                    Text(Strings.licenseNoSeats)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } else if filteredLicenseSeats.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                    Text(Strings.licenseNoFilteredSeats(licenseFilterLabel))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(filteredLicenseSeats) { seat in
                    licenseRow(seat)
                }
            }

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                Text(Strings.licensePopoverManageHint)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    _ = SeatRegistry.shared.checkLicenses()
                    licenseSeats = SeatRegistry.shared.seats
                } label: {
                    Label(Strings.licenseCheckButton, systemImage: "checkmark.shield")
                        .font(.system(size: 8))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onAppear { licenseSeats = SeatRegistry.shared.seats }
        .onReceive(NotificationCenter.default.publisher(for: .seatRegistryChanged)) { _ in
            licenseSeats = SeatRegistry.shared.seats
        }
    }

    private func licenseRow(_ seat: SeatRecord) -> some View {
        HStack(spacing: 8) {
            Image(systemName: seat.revoked ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(seat.revoked ? .red : .green)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(seat.sub)
                    .font(.system(size: 9))
                    .monospaced()
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("kid: \(seat.kid.isEmpty ? "—" : seat.kid)")
                        .font(.system(size: 7))
                        .foregroundColor(.secondary)
                    Text(Strings.licenseCountdown(seat.exp))
                        .font(.system(size: 7))
                        .foregroundColor(seat.revoked ? .red : .secondary)
                }
            }
            Spacer()
            Text(seat.revoked ? Strings.licenseRevokedBadge : Strings.licenseActiveBadge)
                .font(.system(size: 7, weight: .semibold))
                .foregroundColor(seat.revoked ? .red : .green)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background((seat.revoked ? Color.red : Color.green).opacity(0.12))
                .cornerRadius(4)
        }
        .padding(6)
        .background(seat.revoked ? Color.red.opacity(0.06) : Color.gray.opacity(0.06))
        .cornerRadius(6)
    }

    // MARK: - GitHub Tab

    private var gitHubTabContent: some View {
        VStack(spacing: 0) {
            if stats.gitHub.isLoading {
                Spacer(minLength: 40)
                HStack { Spacer(); ProgressView().scaleEffect(1.2); Spacer() }
                Spacer(minLength: 40)
            } else if let err = stats.gitHub.errorMessage {
                Spacer(minLength: 40)
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundColor(.orange)
                    Text(err).font(.caption).foregroundColor(.orange).multilineTextAlignment(.center)
                    Text("Settings -> Services to configure")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 40)
            } else {
                gitHubDataView
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var gitHubDataView: some View {
        VStack(alignment: .leading, spacing: 8) {
            let gh = stats.gitHub.usage
            cloudRow(icon: "play.display", color: .green, label: Strings.githubComputeLabel,
                     value: String(format: "%d / %d min", gh.minutesUsed, gh.includedMinutes),
                     progress: gh.minutesPercentage / 100, progressColor: gh.isMinutesWarning ? .orange : .green)
            cloudRow(icon: "externaldrive", color: .blue, label: Strings.githubStorageLabel,
                     value: String(format: "%.0f / %.0f MB", gh.storageMB, gh.storageLimitMB),
                     progress: gh.storagePercentage / 100, progressColor: gh.isStorageWarning ? .orange : .blue)
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 8)).foregroundColor(.teal).frame(width: 14)
                Text(String(format: Strings.githubDaysLeft, gh.billingCycleDaysLeft))
                    .font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text(cloudStatusText(g: stats.gitHub, a: nil))
                    .font(.system(size: 8))
                    .foregroundColor(cloudStatusColor(g: stats.gitHub, a: nil))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - AWS Tab

    private var awsTabContent: some View {
        VStack(spacing: 0) {
            if stats.aws.isLoading {
                Spacer(minLength: 40)
                HStack { Spacer(); ProgressView().scaleEffect(1.2); Spacer() }
                Spacer(minLength: 40)
            } else if let err = stats.aws.errorMessage {
                Spacer(minLength: 40)
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundColor(.orange)
                    Text(err).font(.caption).foregroundColor(.orange).multilineTextAlignment(.center)
                    Text("Settings -> Services to configure")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 40)
            } else {
                awsDataView
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var awsDataView: some View {
        VStack(alignment: .leading, spacing: 8) {
            let aw = stats.aws.status
            cloudRow(icon: "clock", color: .green, label: Strings.awsHoursLabel,
                     value: String(format: "%.0f / %.0f hrs", aw.ec2RunningHours, aw.freeTierLimitHours),
                     progress: aw.usagePercentage / 100, progressColor: aw.isWarning ? .orange : .green)
            if let forecast = aw.forecastedHours {
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 8)).foregroundColor(.teal).frame(width: 14)
                    Text(Strings.awsForecastLabel).font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: Strings.awsForecastFormat, forecast))
                        .font(.system(size: 9).monospacedDigit())
                }
            }
            let b = stats.aws.billing
            if b.creditsApplied > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard.fill").font(.system(size: 8)).foregroundColor(.green).frame(width: 14)
                    Text(Strings.awsCreditsLabel).font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "+$%.2f", b.creditsApplied))
                        .font(.system(size: 9).monospacedDigit()).foregroundColor(.green)
                }
            }
            if b.ec2CreditsApplied > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack").font(.system(size: 8)).foregroundColor(.purple).frame(width: 14)
                    Text(Strings.awsEc2CreditsLabel).font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "+$%.2f", b.ec2CreditsApplied))
                        .font(.system(size: 9).monospacedDigit()).foregroundColor(.green)
                }
            }
            if b.monthToDateCost > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "dollarsign.circle").font(.system(size: 8)).foregroundColor(.orange).frame(width: 14)
                    Text(Strings.awsMtdCostLabel).font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "$%.2f", b.monthToDateCost))
                        .font(.system(size: 9).monospacedDigit()).foregroundColor(.orange)
                }
            }
            if let fc = b.forecastedCost {
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 8)).foregroundColor(.teal).frame(width: 14)
                    Text(Strings.awsCostForecastLabel).font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "~$%.2f", fc))
                        .font(.system(size: 9).monospacedDigit()).foregroundColor(.teal)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "server.rack").font(.system(size: 8)).foregroundColor(.purple).frame(width: 14)
                Text(Strings.awsInstancesLabel).font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text(String(format: Strings.awsInstancesFormat, aw.instanceCount, aw.eligibleCount, aw.nonEligibleCount))
                    .font(.system(size: 9).monospacedDigit())
            }
            if !aw.nonEligibleInstances.isEmpty {
                ForEach(aw.nonEligibleInstances) { inst in
                    HStack(spacing: 12) {
                        Text(inst.instanceId).font(.system(size: 8)).frame(width: 80, alignment: .leading).lineLimit(1)
                        Text(inst.instanceType).font(.system(size: 8)).frame(width: 60, alignment: .leading)
                        Spacer()
                        Image(systemName: "xmark.circle.fill").font(.system(size: 7)).foregroundColor(.red)
                        Text(String(format: Strings.awsNoLabel, 30.0))
                            .font(.system(size: 7)).foregroundColor(.red)
                    }
                }
            }
            if aw.estimatedOverageCost > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "yensign.circle").font(.system(size: 8)).foregroundColor(.orange).frame(width: 14)
                    Text(Strings.awsOverageLabel).font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "$%.2f", aw.estimatedOverageCost))
                        .font(.system(size: 9).monospacedDigit()).foregroundColor(.orange)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 8)).foregroundColor(.secondary).frame(width: 14)
                Text(cloudStatusText(g: nil, a: stats.aws))
                    .font(.system(size: 8))
                    .foregroundColor(cloudStatusColor(g: nil, a: stats.aws))
            }
        }
        .padding(.vertical, 4)
    }

    private func pillTab(_ label: String, tag: Int, selection: Binding<Int>, hPad: CGFloat = 10) -> some View {
        let active = selection.wrappedValue == tag
        return Text(label)
            .foregroundColor(active ? .primary : .secondary)
            .padding(.horizontal, hPad)
            .padding(.vertical, 3)
            .background(active ? Color(nsColor: .selectedControlColor).opacity(0.4) : .clear)
            .cornerRadius(6)
            .onTapGesture { selection.wrappedValue = tag }
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            Spacer()
            iconButton(icon: "arrow.clockwise", label: Strings.refresh, color: .blue) {
                stats.refresh()
                stats.gitHub.refresh()
                stats.aws.refresh()
                loadUsage()
            }
            iconButton(icon: "square.and.arrow.up", label: Strings.exportUsageButton, color: .teal) {
                UsageExporter.exportUsage()
            }
            iconButton(icon: "square.and.arrow.down", label: Strings.configExportButton, color: .purple) {
                ConfigExporter.exportConfig()
            }
            iconButton(icon: "square.and.arrow.up.on.square", label: Strings.configImportButton, color: .purple) {
                ConfigExporter.importConfig()
                stats.refresh()
                stats.gitHub.refresh()
                stats.aws.refresh()
                loadUsage()
            }
            iconButton(icon: "gearshape", label: Strings.settings, color: .secondary) {
                StatusBarController.shared.closePopover()
                StatusBarController.shared.showSettings()
            }
            iconButton(icon: "power", label: Strings.quit, color: .red) {
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

    private func iconButton(icon: String, label: String, color: Color, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .modifier(IconButtonChrome(color: color, active: active))
        }
        .buttonStyle(.plain)
        .modifier(HoverTooltip(text: label, position: .above))
        .fixedSize()
    }
}

/// 图标按钮外框：底部操作栏与提供商标签行共用同一几何与配色，保证视觉一致。
/// - active: 选中态为蓝底白图标；未选中态为着色底 + 同色图标。
struct IconButtonChrome: ViewModifier {
    let color: Color
    var active: Bool = false

    func body(content: Content) -> some View {
        content
            .foregroundColor(active ? .white : color)
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
            .background(active ? Color.blue : color.opacity(0.12))
            .cornerRadius(6)
    }
}

/// 自定义悬停提示。SwiftUI 的 .help() 在无边框 popUpMenu 级窗口中（菜单栏弹出面板）不会显示，
/// 因此改用 onHover + overlay 实现（与 UsageBarChart 的悬停 tooltip 同一思路）。
struct HoverTooltip: ViewModifier {
    enum Position { case above, below }

    let text: String
    var position: Position = .below

    @State private var hovering = false
    @State private var tooltipID = UUID()

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .background(TooltipAnchor(text: text, position: position, isPresented: hovering, id: tooltipID))
            .zIndex(hovering ? 10_000 : 0)
    }
}

private struct TooltipAnchor: NSViewRepresentable {
    let text: String
    let position: HoverTooltip.Position
    let isPresented: Bool
    let id: UUID

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in
            if isPresented {
                FloatingTooltipController.shared.show(text: text, from: nsView, position: position, id: id)
            } else {
                FloatingTooltipController.shared.hide(id: id)
            }
        }
    }
}

private struct FloatingTooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundColor(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
            )
            .fixedSize()
            .allowsHitTesting(false)
    }
}

@MainActor
private final class FloatingTooltipController {
    static let shared = FloatingTooltipController()

    private var panel: NSPanel?
    private var currentID: UUID?

    func show(text: String, from anchor: NSView, position: HoverTooltip.Position, id: UUID) {
        guard let sourceWindow = anchor.window else { return }
        let host = NSHostingController(rootView: FloatingTooltipBubble(text: text))
        host.view.frame.size = host.view.fittingSize
        let size = host.view.fittingSize
        let panel = panel ?? makePanel()
        panel.contentView = host.view
        panel.setContentSize(size)
        currentID = id

        if panel.parent !== sourceWindow {
            panel.parent?.removeChildWindow(panel)
            sourceWindow.addChildWindow(panel, ordered: .above)
        }
        panel.level = NSWindow.Level(
            rawValue: max(NSWindow.Level.popUpMenu.rawValue, sourceWindow.level.rawValue + 1)
        )

        let anchorRect = anchor.convert(anchor.bounds, to: nil)
        let screenRect = sourceWindow.convertToScreen(anchorRect)
        let gap: CGFloat = 6
        var origin = NSPoint(
            x: screenRect.midX - size.width / 2,
            y: position == .above ? screenRect.maxY + gap : screenRect.minY - size.height - gap
        )

        if let screen = sourceWindow.screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            origin.x = min(max(origin.x, frame.minX + 4), frame.maxX - size.width - 4)
            origin.y = min(max(origin.y, frame.minY + 4), frame.maxY - size.height - 4)
        }

        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide(id: UUID) {
        guard currentID == id else { return }
        panel?.orderOut(nil)
        currentID = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}
