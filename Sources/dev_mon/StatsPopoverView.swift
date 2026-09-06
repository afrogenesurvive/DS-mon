import SwiftUI
import AppKit
import Charts

// MARK: - AWS 实例操作确认（Start / Stop / 添加入站规则）

private struct AWSConfirmRequest: Identifiable {
    enum Kind {
        case start
        case stop
        case ingress
        case removeRule(AWSIngressRule)
    }
    let kind: Kind
    let instanceId: String
    let groupId: String?
    var id: String { instanceId }
}

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

    // AWS 页子页签（Overview / Instances）与实例操作状态
    @State private var awsSubTab = 0
    @State private var awsSelectedID: String?
    @State private var awsPending: Set<String> = []
    @State private var awsConfirmRequest: AWSConfirmRequest?
    @State private var showAwsConfirm = false
    @State private var awsActionMessage: String?
    @State private var awsActionSuccess = true
    // SG 入站规则编辑器（内嵌卡片；nil = 新增，非 nil = 编辑已有规则）
    @State private var awsRuleEditorGroupId: String?
    @State private var awsEditingRule: AWSIngressRule?
    @State private var awsRuleProto = "tcp"
    @State private var awsRuleFromPort = ""
    @State private var awsRuleToPort = ""
    @State private var awsRuleSource = "0.0.0.0/0"
    @State private var awsRuleDesc = ""
    @State private var awsRuleSaving = false

    // 折叠区段状态（DeepSeek 页）
    @State private var showAccountSection = true    // 余额/充值/提示行
    @State private var showUsageStatsSection = true // 用量统计
    @State private var showUsageListSection = true  // 请求列表/图表
    @State private var showSourceUsageSection = true // 来源用量（图表/列表）

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            appTitleRow
            Divider().padding(.horizontal, 14)
            tabBar
            Divider().padding(.horizontal, 14)
            if selectedTab == 0 {
                // AI 模型图标页签：仅在 AI Usage（用量）页显示，位于主 tab 栏下方
                providerTabRow
                Divider().padding(.horizontal, 14)
            }
            if selectedTab == 0 {
                ScrollView {
                    deepSeekTabContent
                }
            } else if selectedTab == 3 {
                // AWS 页自行管理滚动/布局：Instances 面板需要固定高度窗口内的
                // 双栏 + 独立滚动侧栏。
                awsTabContent
            } else {
                ScrollView {
                    if selectedTab == 1 { licenseTabContent }
                    else { gitHubTabContent }
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
        .alert(Strings.awsConfirmTitle, isPresented: $showAwsConfirm, presenting: awsConfirmRequest) { req in
            Button(Strings.cancel, role: .cancel) {}
            Button(awsConfirmButtonLabel) {
                performAWS(req)
            }
        } message: { req in
            Text(awsConfirmMessage(req))
        }
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
        HStack(spacing: 8) {
            ForEach(ProviderManager.shared.providers, id: \.id) { provider in
                providerTabButton(provider)
            }
            Spacer()
            iconButton(icon: "arrow.up.right.square", label: Strings.openConsole, color: .blue,
                       action: openConsole)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
            if let wallet = stats.walletBalance {
                HStack(spacing: 6) {
                    Image(systemName: "wallet.pass.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                    Text(Strings.walletLabel)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%@%.2f", Strings.currencySymbol, wallet))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Text(Strings.walletHint)
                    .font(.system(size: 7))
                    .foregroundColor(.secondary)
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
                    Text(Strings.remainingBudgetLabel)
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

            if let quota = stats.quota {
                quotaBlock(quota)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 套餐用量（Z.AI Coding Plan 等；内部接口数据）

    @ViewBuilder
    private func quotaBlock(_ quota: ProviderQuotaUsage) -> some View {
        VStack(spacing: 3) {
            if let plan = quota.planName {
                quotaRow(icon: "sparkles.rectangle.stack", label: Strings.quotaPlanName, value: plan, valueColor: .secondary)
            }
            if let renew = quota.renewalDate {
                quotaRow(
                    icon: "calendar",
                    label: Strings.quotaRenewDate,
                    value: renew.formatted(date: .abbreviated, time: .omitted),
                    valueColor: .secondary
                )
            }
            ForEach(quota.windows, id: \.kind) { window in
                quotaRow(
                    icon: "gauge.with.dots.needle.67percent",
                    label: quotaTitle(window.kind),
                    value: "\(quotaFraction(window)) · \(Int(window.percent.rounded()))%",
                    valueColor: window.percent >= 80 ? .orange : .secondary
                )
            }
            Text(Strings.quotaUsageHint)
                .font(.system(size: 7))
                .foregroundColor(.secondary)
        }
    }

    private func quotaRow(icon: String, label: String, value: String, valueColor: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(valueColor)
        }
    }

    private func quotaTitle(_ kind: ProviderQuotaWindowKind) -> String {
        switch kind {
        case .session5h:     return Strings.quotaSession5h
        case .weekly7d:      return Strings.quotaWeekly7d
        case .searchMonthly: return Strings.quotaSearchMonthly
        }
    }

    private func quotaFraction(_ window: ProviderQuotaWindow) -> String {
        switch window.kind {
        case .searchMonthly:
            return "\(Int(window.used)) / \(Int(window.limit))"
        default:
            return "\(Self.compactTokens(window.used)) / \(Self.compactTokens(window.limit))"
        }
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
                awsSubTabBar
                Divider().padding(.horizontal, 14)
                if awsSubTab == 0 {
                    ScrollView {
                        awsDataView
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                } else {
                    awsInstancesView
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if b.lifetimeCreditsApplied > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 8)).foregroundColor(.green).frame(width: 14)
                    Text(Strings.awsLifetimeCreditsLabel).font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "+$%.2f", b.lifetimeCreditsApplied))
                        .font(.system(size: 9).monospacedDigit()).foregroundColor(.green)
                }
            }
            if b.maxCredits > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard").font(.system(size: 8)).foregroundColor(.teal).frame(width: 14)
                    Text(Strings.awsRemainingCreditsLabel).font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: Strings.awsRemainingCreditsFormat, b.remainingCredits, b.maxCredits))
                        .font(.system(size: 9).monospacedDigit()).foregroundColor(.teal)
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
            if !stats.aws.instances.isEmpty {
                ForEach(stats.aws.instances.sorted(by: awsInstanceSort)) { inst in
                    HStack(spacing: 6) {
                        Circle().fill(awsStateColor(inst.state)).frame(width: 6, height: 6)
                        Text(inst.instanceId)
                            .font(.system(size: 8, design: .monospaced))
                            .frame(width: 92, alignment: .leading)
                            .lineLimit(1).truncationMode(.middle)
                        Text(inst.instanceType).font(.system(size: 8)).frame(width: 52, alignment: .leading)
                        Text(awsStateText(inst.state))
                            .font(.system(size: 8))
                            .foregroundColor(awsStateColor(inst.state))
                            .frame(width: 52, alignment: .leading)
                        Spacer()
                        if inst.isRunning {
                            if let h = inst.runningHours {
                                Text(String(format: "%.1f h", h))
                                    .font(.system(size: 8).monospacedDigit()).foregroundColor(.secondary)
                            }
                            if !inst.isEligibleFreeTier {
                                Text(String(format: Strings.awsNoLabel, 30.0))
                                    .font(.system(size: 7)).foregroundColor(.red)
                            }
                        } else {
                            Text(inst.publicIp ?? "—")
                                .font(.system(size: 8).monospacedDigit())
                                .foregroundColor(.secondary).lineLimit(1)
                        }
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

    // MARK: - AWS Sub-tabs (Overview / Instances)

    private var awsSubTabBar: some View {
        HStack(spacing: 4) {
            awsSubTabButton(Strings.awsSubTabOverview, tag: 0)
            awsSubTabButton(Strings.awsSubTabInstances, tag: 1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func awsSubTabButton(_ title: String, tag: Int) -> some View {
        let active = awsSubTab == tag
        return Button(action: { awsSubTab = tag }) {
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

    // MARK: - AWS Instances (two-pane)

    private var awsInstancesView: some View {
        VStack(spacing: 0) {
            if stats.aws.instances.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "server.rack").font(.title2).foregroundColor(.secondary)
                    Text(Strings.awsInstancesEmpty)
                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Spacer()
            } else {
                awsInstancesPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { ensureAWSSelection() }
        .onChange(of: stats.aws.instances) { _, _ in ensureAWSSelection() }
    }

    private var awsInstancesPane: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左：垂直滚动实例侧栏（ID 截断 + 状态圆点 + 类型/时长）
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(stats.aws.instances) { inst in
                        awsInstanceRow(inst)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(width: 150)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))

            Divider()

            // 右：选中实例详情 + 操作
            Group {
                if let sel = stats.aws.instances.first(where: { $0.instanceId == awsSelectedID }) {
                    awsInstanceDetail(sel)
                } else {
                    VStack(spacing: 6) {
                        Spacer()
                        Image(systemName: "info.circle").font(.title3).foregroundColor(.secondary)
                        Text(Strings.awsNoSelectionHint)
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func awsInstanceRow(_ inst: AWSInstance) -> some View {
        let selected = awsSelectedID == inst.instanceId
        return Button {
            awsSelectedID = inst.instanceId
            awsActionMessage = nil
            closeRuleEditor()
            refreshIngress(for: inst)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Circle().fill(awsStateColor(inst.state)).frame(width: 7, height: 7)
                    Text(inst.instanceId)
                        .font(.system(size: 9, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    if awsPending.contains(inst.instanceId) {
                        ProgressView().controlSize(.mini)
                            .scaleEffect(0.7).frame(width: 10, height: 10)
                    }
                }
                HStack(spacing: 4) {
                    Text(inst.instanceType).font(.system(size: 8)).foregroundColor(.secondary)
                    if let h = inst.runningHours {
                        Text(String(format: "%.1fh", h))
                            .font(.system(size: 8).monospacedDigit()).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 2)
                    if let name = inst.name, !name.isEmpty {
                        Text(name).font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func awsInstanceDetail(_ inst: AWSInstance) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(awsStateColor(inst.state)).frame(width: 8, height: 8)
                    Text(inst.instanceId)
                        .font(.system(size: 11, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer()
                    awsStateBadge(inst.state)
                }
                if let name = inst.name, !name.isEmpty {
                    Text(name).font(.caption).foregroundColor(.secondary)
                }
                awsInfoRow(Strings.awsInstTypeLabel, value: inst.instanceType)
                awsInfoRow(Strings.awsStateLabel, value: awsStateText(inst.state))
                if let launch = inst.launchTime {
                    awsInfoRow(Strings.awsLaunchLabel, value: Self.awsDateText(launch))
                }
                if let h = inst.runningHours {
                    awsInfoRow(Strings.awsUptimeLabel, value: String(format: "%.1f h", h))
                }
                if let ip = inst.publicIp {
                    awsInfoRow(Strings.awsPublicIPLabel, value: ip, selectable: true)
                }
                if inst.isRunning, let dns = inst.publicDns, !dns.isEmpty {
                    awsInfoRow(Strings.awsPublicDNSLabel, value: dns, selectable: true)
                }
                if let ip = inst.privateIp {
                    awsInfoRow(Strings.awsPrivateIPLabel, value: ip, selectable: true)
                }
                if let gid = inst.primarySecurityGroupId {
                    let gname = stats.aws.sgNames[gid] ?? inst.securityGroupNames.first ?? gid
                    awsInfoRow(Strings.awsSecurityGroupLabel, value: gname, selectable: true)
                    awsIngressRow(groupId: gid)
                    awsRulesSection(groupId: gid, instanceId: inst.instanceId)
                    if awsRuleEditorGroupId == gid {
                        awsRuleEditorCard(groupId: gid)
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    if inst.isStopped {
                        awsActionButton(Strings.awsStartAction, icon: "play.fill", color: .green,
                                        disabled: awsPending.contains(inst.instanceId)) {
                            beginAWSConfirm(.start, instanceId: inst.instanceId)
                        }
                    } else if inst.isRunning {
                        awsActionButton(Strings.awsStopAction, icon: "stop.fill", color: .orange,
                                        disabled: awsPending.contains(inst.instanceId)) {
                            beginAWSConfirm(.stop, instanceId: inst.instanceId)
                        }
                    }
                    if let gid = inst.primarySecurityGroupId,
                       (stats.aws.rdpIngress[gid] ?? .unknown) != .open {
                        awsActionButton(Strings.awsAddIngressAction, icon: "lock.open.fill", color: .blue,
                                        disabled: awsPending.contains(inst.instanceId)) {
                            beginAWSConfirm(.ingress, instanceId: inst.instanceId, groupId: gid)
                        }
                    }
                    Spacer()
                    if awsPending.contains(inst.instanceId) {
                        ProgressView().controlSize(.small)
                    }
                }

                if let msg = awsActionMessage {
                    Text(msg)
                        .font(.system(size: 8))
                        .foregroundColor(awsActionSuccess ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func awsIngressRow(groupId: String) -> some View {
        let check = stats.aws.rdpIngress[groupId] ?? .unknown
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 8)).foregroundColor(awsIngressColor(check)).frame(width: 14)
                Text(Strings.awsRDPIngressLabel)
                    .font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text(awsIngressText(check))
                    .font(.system(size: 9)).foregroundColor(awsIngressColor(check))
            }
            if let ip = stats.aws.myPublicIP {
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.system(size: 8)).foregroundColor(.secondary).frame(width: 14)
                    Text(Strings.awsMyIPLabel).font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(ip).font(.system(size: 9).monospacedDigit())
                }
            }
        }
    }

    // MARK: - SG 入站规则（查看 / 添加 / 编辑 / 删除）

    private func awsRulesSection(groupId: String, instanceId: String) -> some View {
        let rules = stats.aws.sgRules[groupId] ?? []
        let isEditor = awsRuleEditorGroupId == groupId
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 8)).foregroundColor(.secondary).frame(width: 14)
                Text(Strings.awsRulesHeader)
                    .font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                if isEditor {
                    awsActionButton(Strings.cancel, icon: "xmark", color: .secondary,
                                    disabled: false) { closeRuleEditor() }
                } else {
                    awsActionButton(Strings.awsAddRuleAction, icon: "plus", color: .blue,
                                    disabled: false) {
                        openRuleEditor(for: nil, groupId: groupId)
                    }
                }
            }
            if rules.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 8)).foregroundColor(.secondary).frame(width: 14)
                    Text(Strings.awsNoRules)
                        .font(.system(size: 8)).foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            } else {
                ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                    HStack(spacing: 4) {
                        Image(systemName: awsRuleIcon(rule))
                            .font(.system(size: 8)).foregroundColor(.secondary).frame(width: 12)
                        Text(awsRuleSummary(rule))
                            .font(.system(size: 8))
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Spacer(minLength: 2)
                        Button {
                            openRuleEditor(for: rule, groupId: groupId)
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 8)).foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        Button {
                            beginAWSConfirm(.removeRule(rule), instanceId: instanceId, groupId: groupId)
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 8)).foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func awsRuleEditorCard(groupId: String) -> some View {
        let editing = awsEditingRule != nil
        return VStack(alignment: .leading, spacing: 6) {
            Text(editing ? Strings.awsEditRuleTitle : Strings.awsAddRuleTitle)
                .font(.system(size: 9, weight: .semibold))
            Picker("", selection: $awsRuleProto) {
                Text("TCP").tag("tcp")
                Text("UDP").tag("udp")
                Text("ICMP").tag("icmp")
                Text(Strings.awsAllTraffic).tag("-1")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            if awsRuleProto != "-1" {
                HStack(spacing: 6) {
                    TextField(Strings.awsPortFrom, text: $awsRuleFromPort)
                        .textFieldStyle(.roundedBorder).font(.system(size: 10))
                        .frame(width: 60)
                    Text("–").foregroundColor(.secondary)
                    TextField(Strings.awsPortTo, text: $awsRuleToPort)
                        .textFieldStyle(.roundedBorder).font(.system(size: 10))
                        .frame(width: 60)
                }
            }
            HStack(spacing: 6) {
                TextField(Strings.awsSourceLabel, text: $awsRuleSource)
                    .textFieldStyle(.roundedBorder).font(.system(size: 10))
                if let ip = stats.aws.myPublicIP {
                    Button {
                        awsRuleSource = "\(ip)/32"
                    } label: {
                        Text(Strings.awsMyIPShort).font(.system(size: 9))
                    }
                    .controlSize(.mini)
                }
                Button {
                    awsRuleSource = "0.0.0.0/0"
                } label: {
                    Text("0.0.0.0/0").font(.system(size: 9))
                }
                .controlSize(.mini)
            }
            TextField(Strings.awsDescLabel, text: $awsRuleDesc)
                .textFieldStyle(.roundedBorder).font(.system(size: 10))
            HStack(spacing: 8) {
                Spacer()
                if awsRuleSaving {
                    ProgressView().controlSize(.mini)
                }
                Button(Strings.cancel) { closeRuleEditor() }
                    .controlSize(.small)
                Button(editing ? Strings.awsSaveRuleAction : Strings.awsAddRuleAction) {
                    saveRule(groupId: groupId)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(awsRuleSaving)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .cornerRadius(8)
    }

    private func awsRuleIcon(_ rule: AWSIngressRule) -> String {
        switch rule.source {
        case .cidr, .ipv6: return "network"
        case .group: return "rectangle.3.group"
        }
    }

    private func awsRuleSummary(_ rule: AWSIngressRule) -> String {
        var s: String
        if rule.proto == "-1" {
            s = rule.protocolDisplay
        } else {
            s = rule.protocolDisplay + " "
            if let f = rule.fromPort, let t = rule.toPort {
                s += f == t ? "\(f)" : "\(f)–\(t)"
            } else {
                s += "?"
            }
        }
        s += " · " + rule.sourceDisplay
        if let d = rule.description, !d.isEmpty { s += " · " + d }
        return s
    }

    private func awsStateBadge(_ state: String) -> some View {
        Text(awsStateText(state))
            .font(.system(size: 8))
            .foregroundColor(awsStateColor(state))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(awsStateColor(state).opacity(0.12))
            .cornerRadius(6)
    }

    private func awsInfoRow(_ label: String, value: String, selectable: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            Spacer(minLength: 6)
            if selectable {
                Text(value)
                    .font(.system(size: 9))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(.system(size: 9))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
            }
        }
    }

    private func awsActionButton(_ title: String, icon: String, color: Color, disabled: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(disabled ? 0.06 : 0.16))
            .cornerRadius(6)
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func awsStateColor(_ state: String) -> Color {
        switch state {
        case "running": return .green
        case "stopped", "terminated": return .gray
        default: return .orange
        }
    }

    private func awsStateText(_ state: String) -> String {
        switch state {
        case "running": return Strings.awsStateRunning
        case "stopped": return Strings.awsStateStopped
        case "stopping": return Strings.awsStateStopping
        case "pending": return Strings.awsStatePending
        case "shutting-down": return Strings.awsStateShuttingDown
        case "terminated": return Strings.awsStateTerminated
        default: return state.capitalized
        }
    }

    private func awsIngressText(_ c: AWSIngressCheck) -> String {
        switch c {
        case .open: return Strings.awsIngressOpen
        case .closed: return Strings.awsIngressClosed
        case .unknown: return Strings.awsIngressUnknown
        }
    }

    private func awsIngressColor(_ c: AWSIngressCheck) -> Color {
        switch c {
        case .open: return .green
        case .closed: return .red
        case .unknown: return .secondary
        }
    }

    private static func awsDateText(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - AWS Instances — selection & actions

    @MainActor
    private func awsInstanceSort(_ a: AWSInstance, _ b: AWSInstance) -> Bool {
        if a.isRunning != b.isRunning { return a.isRunning }
        return a.instanceId < b.instanceId
    }

    // MARK: - SG 入站规则 — 编辑器（新增 / 编辑）

    @MainActor
    private func openRuleEditor(for rule: AWSIngressRule?, groupId: String) {
        awsEditingRule = rule
        awsRuleEditorGroupId = groupId
        awsRuleProto = rule?.proto ?? "tcp"
        awsRuleFromPort = rule?.fromPort.map(String.init) ?? ""
        awsRuleToPort = rule?.toPort.map(String.init) ?? ""
        awsRuleDesc = rule?.description ?? ""
        switch rule?.source {
        case .cidr(let c), .ipv6(let c): awsRuleSource = c
        case .group(let gid, _): awsRuleSource = gid
        case nil: awsRuleSource = "0.0.0.0/0"
        }
        awsRuleSaving = false
    }

    @MainActor
    private func closeRuleEditor() {
        awsRuleEditorGroupId = nil
        awsEditingRule = nil
        awsRuleSaving = false
    }

    @MainActor
    private func saveRule(groupId: String) {
        let proto = awsRuleProto
        let fromText = awsRuleFromPort.trimmingCharacters(in: .whitespaces)
        let toText = awsRuleToPort.trimmingCharacters(in: .whitespaces)
        let src = awsRuleSource.trimmingCharacters(in: .whitespaces)
        guard !src.isEmpty else {
            awsActionSuccess = false
            awsActionMessage = Strings.awsRuleSourceRequired
            return
        }
        let from = Int(fromText)
        let to = Int(toText)
        if proto != "-1" && proto != "icmp" {
            guard from != nil, to != nil else {
                awsActionSuccess = false
                awsActionMessage = Strings.awsRulePortRequired
                return
            }
        }
        let source: AWSIngressRule.Source
        if src.lowercased().contains(":") {
            source = .ipv6(src)
        } else if src.hasPrefix("sg-") {
            source = .group(groupId: src, groupName: nil)
        } else {
            source = .cidr(src)
        }
        let desc = awsRuleDesc.trimmingCharacters(in: .whitespaces)
        let rule = AWSIngressRule(proto: proto, fromPort: from, toPort: to,
                                  source: source, description: desc.isEmpty ? nil : desc)
        let editing = awsEditingRule
        awsRuleSaving = true
        Task {
            let err = editing == nil
                ? await stats.aws.addIngressRule(rule, groupId: groupId)
                : await stats.aws.replaceIngressRule(editing!, with: rule, groupId: groupId)
            awsRuleSaving = false
            closeRuleEditor()
            awsActionSuccess = (err == nil)
            awsActionMessage = err ?? (editing == nil ? Strings.awsRuleAdded : Strings.awsRuleUpdated)
            if err == nil {
                Task { await stats.aws.checkRDPIngress(groupId: groupId) }
            }
        }
    }

    @MainActor
    private func ensureAWSSelection() {
        if let id = awsSelectedID,
           let sel = stats.aws.instances.first(where: { $0.instanceId == id }) {
            refreshIngress(for: sel)
            return
        }
        guard let first = stats.aws.instances.first else {
            awsSelectedID = nil
            return
        }
        awsSelectedID = first.instanceId
        refreshIngress(for: first)
    }

    @MainActor
    private func refreshIngress(for inst: AWSInstance) {
        guard let gid = inst.primarySecurityGroupId else { return }
        Task {
            await stats.aws.fetchMyPublicIP()
            // 先取回完整规则列表（供下方规则列表使用），RDP 检查复用缓存避免重复请求。
            await stats.aws.loadSecurityGroup(groupId: gid)
            await stats.aws.checkRDPIngress(groupId: gid)
        }
    }

    @MainActor
    private func beginAWSConfirm(_ kind: AWSConfirmRequest.Kind, instanceId: String, groupId: String? = nil) {
        awsConfirmRequest = AWSConfirmRequest(kind: kind, instanceId: instanceId, groupId: groupId)
        showAwsConfirm = true
    }

    private var awsConfirmButtonLabel: String {
        guard let req = awsConfirmRequest else { return Strings.cancel }
        switch req.kind {
        case .start: return Strings.awsStartAction
        case .stop: return Strings.awsStopAction
        case .ingress: return Strings.awsAddIngressAction
        case .removeRule: return Strings.awsRemoveRuleAction
        }
    }

    private func awsConfirmMessage(_ req: AWSConfirmRequest) -> String {
        switch req.kind {
        case .start: return String(format: Strings.awsStartConfirmMessage, req.instanceId)
        case .stop: return String(format: Strings.awsStopConfirmMessage, req.instanceId)
        case .ingress: return String(format: Strings.awsIngressConfirmMessage, req.instanceId)
        case .removeRule: return String(format: Strings.awsRemoveRuleConfirmMessage, req.instanceId)
        }
    }

    @MainActor
    private func performAWS(_ req: AWSConfirmRequest) {
        let id = req.instanceId
        guard !awsPending.contains(id) else { return }
        awsPending.insert(id)
        awsActionMessage = nil
        switch req.kind {
        case .start:
            Task { await runStartStop(true, id: id) }
        case .stop:
            Task { await runStartStop(false, id: id) }
        case .ingress:
            guard let gid = req.groupId else {
                awsPending.remove(id)
                awsActionSuccess = false
                awsActionMessage = Strings.awsNoSecurityGroup
                return
            }
            Task {
                let (check, msg) = await stats.aws.addMyIPRDPRule(groupId: gid)
                awsPending.remove(id)
                awsActionSuccess = check == .open
                awsActionMessage = msg
                if check == .open {
                    Task { await stats.aws.checkRDPIngress(groupId: gid) }
                }
            }
        case .removeRule(let rule):
            guard let gid = req.groupId else {
                awsPending.remove(id)
                awsActionSuccess = false
                awsActionMessage = Strings.awsNoSecurityGroup
                return
            }
            Task {
                let err = await stats.aws.removeIngressRule(rule, groupId: gid)
                awsPending.remove(id)
                awsActionSuccess = (err == nil)
                awsActionMessage = err ?? Strings.awsRuleRemoved
                if err == nil {
                    Task { await stats.aws.checkRDPIngress(groupId: gid) }
                }
            }
        }
    }

    @MainActor
    private func runStartStop(_ start: Bool, id: String) async {
        let err = start ? await stats.aws.startInstance(id) : await stats.aws.stopInstance(id)
        awsPending.remove(id)
        if let err = err {
            awsActionSuccess = false
            awsActionMessage = err
        } else {
            awsActionSuccess = true
            awsActionMessage = start ? Strings.awsStartSent : Strings.awsStopSent
            delayedAWSRefresh(instanceId: id, forStart: start)
        }
    }

    /// EC2 状态变更有延迟：操作后轮询刷新，让列表/详情（状态、公网 IP/DNS、
    /// 入站规则）自动反映新状态。Start 最多轮询 60 秒（每 5 秒一次）；Stop
    /// 轮询 3 次（每 3 秒一次），遇到实例离开过渡态即提前结束。
    @MainActor
    private func delayedAWSRefresh(instanceId: String, forStart: Bool) {
        let maxAttempts = forStart ? 12 : 3
        let interval: UInt64 = forStart ? 5_000_000_000 : 3_000_000_000
        Task {
            for attempt in 0..<maxAttempts {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                stats.aws.refresh()
                if let inst = stats.aws.instances.first(where: { $0.instanceId == instanceId }),
                   !inst.isTransitional {
                    return
                }
            }
        }
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
