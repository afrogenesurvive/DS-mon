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

// MARK: - Cloudflare 操作确认（Start / Stop / 删除路由）

private struct CFConfirmRequest: Identifiable {
    enum Kind {
        case start
        case stop
        case restart
        case removeHostname(String)
        case removeRoute(String)
    }
    let kind: Kind
    var id: String {
        switch kind {
        case .start: return "cf-start"
        case .stop: return "cf-stop"
        case .restart: return "cf-restart"
        case .removeHostname(let h): return "cf-h-" + h
        case .removeRoute(let n): return "cf-r-" + n
        }
    }
}

// MARK: - Netlify 操作确认（Trigger / Clear cache / Rollback / Lock / Unlock）

private struct NetlifyConfirmRequest: Identifiable {
    enum Kind {
        case trigger
        case triggerClearCache
        case rollback(NetlifyDeploy)
        case lock(NetlifyDeploy)
        case unlock(NetlifyDeploy)
    }
    let kind: Kind
    let siteID: String
    var id: String {
        switch kind {
        case .trigger: return "nf-trigger"
        case .triggerClearCache: return "nf-trigger-cc"
        case .rollback(let d): return "nf-rb-" + d.id
        case .lock(let d): return "nf-lock-" + d.id
        case .unlock(let d): return "nf-unlock-" + d.id
        }
    }
}

// MARK: - 可搜索选择器（搜索框 + ✕ 清除 + 过滤结果列表）

/// 替换原生「不可搜索」的 menu Picker：搜索框（含 ✕ 清除）+ 过滤结果列表。
private struct SearchableSelector<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let selectedID: Item.ID?
    @Binding var searchText: String
    let placeholder: String
    let noMatchesText: String
    let match: (Item, String) -> Bool
    let onSelect: (Item) -> Void
    let row: (Item) -> Row
    var maxListHeight: CGFloat = 128
    /// 结果列表是否展开（与搜索状态无关，均可折叠）
    @State private var listExpanded = true

    init(items: [Item],
         selectedID: Item.ID?,
         searchText: Binding<String>,
         placeholder: String,
         noMatchesText: String,
         match: @escaping (Item, String) -> Bool,
         onSelect: @escaping (Item) -> Void,
         maxListHeight: CGFloat = 128,
         @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.selectedID = selectedID
        self._searchText = searchText
        self.placeholder = placeholder
        self.noMatchesText = noMatchesText
        self.match = match
        self.onSelect = onSelect
        self.maxListHeight = maxListHeight
        self.row = row
    }

    private var filtered: [Item] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { match($0, q) }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                TextField(placeholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .lineLimit(1)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .modifier(HoverTooltip(text: Strings.searchClearTooltip, position: .above))
                }
                if !listExpanded {
                    Text("\(filtered.count)")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { listExpanded.toggle() }
                } label: {
                    Image(systemName: listExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .modifier(HoverTooltip(text: listExpanded ? Strings.searchListCollapse : Strings.searchListExpand,
                                       position: .above))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .onChange(of: searchText) { _, newValue in
                // 输入即自动展开以显示过滤结果；展开后仍可随时收起
                if !newValue.isEmpty, !listExpanded { listExpanded = true }
            }

            if listExpanded {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if filtered.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 8)).foregroundColor(.secondary)
                                Text(noMatchesText)
                                    .font(.system(size: 9)).foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                        } else {
                            ForEach(filtered) { item in
                                let isSelected = selectedID.map { $0 == item.id } ?? false
                                VStack(spacing: 0) {
                                    Button {
                                        onSelect(item)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 8))
                                                .foregroundColor(isSelected ? Color.blue : Color.secondary.opacity(0.45))
                                            row(item)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    if item.id != filtered.last?.id {
                                        Divider().padding(.leading, 22)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: maxListHeight)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - SwiftUI 弹出内容

struct StatsPopoverView: View {
    let stats: DeepSeekStats

    /// 版本号：优先读 Info.plist，fallback 到硬编码（SPM debug 模式）
    private var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    @State private var selectedTab: Int = 0
    /// 弹窗缩放倍数（拖拽右下角把手调整；持久化保存）
    @State private var uiScale: CGFloat = AppConfig.savedPopoverScale()
    /// 拖拽把手起始倍数（nil = 未在拖拽中）
    @State private var scaleDragStart: CGFloat?
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

    // Cloudflare 页状态
    @State private var cloudflareSubTab = 0       // 0 = Overview, 1 = Public Hostnames, 2 = Private IP
    @State private var cfConfirmRequest: CFConfirmRequest?
    @State private var showCFConfirm = false
    @State private var showAddHostname = false
    @State private var cfHostname = ""
    @State private var cfService = "http://localhost:8080"
    @State private var showAddRoute = false
    @State private var cfNetwork = ""
    @State private var cfComment = ""

    // Netlify 页状态（站点选择 / 确认 / 复制反馈 / 本地部署）
    @State private var netlifyConfirmRequest: NetlifyConfirmRequest?
    @State private var showNetlifyConfirm = false
    @State private var netlifyCopiedValue: String?
    @State private var netlifyCopyResetTask: Task<Void, Never>?
    @State private var showNetlifyNewSite = false
    @State private var netlifySiteName = ""
    @State private var netlifyFolderURL: URL?
    @State private var netlifyCreating = false

    // GitHub 页状态（Actions / 仓库 子页签 + 复制反馈）
    @State private var gitHubSubTab = 0          // 0 = Actions, 1 = Repositories
    @State private var ghSelectedRepoID: String?
    @State private var ghCopiedValue: String?
    @State private var ghCopyResetTask: Task<Void, Never>?
    /// GitHub 详情区段折叠状态（repoID|commits/branches/releases → 是否展开）
    @State private var ghSectionExpanded: [String: Bool] = [:]

    // 选择器搜索框文本（GitHub 仓库 / Netlify 站点 / AWS 实例）
    @State private var ghSearchText = ""
    @State private var netlifySearchText = ""
    @State private var awsInstanceSearchText = ""
    /// Netlify 部署历史是否展开
    @State private var netlifyDeploysExpanded = true

    // 通知中心 UI（popover 横幅 + 「通知」页）
    @State private var recentAlerts: [AppAlert] = []
    @State private var currentBanner: AppAlert?
    @State private var bannerDismissTask: Task<Void, Never>?
    // Cloudflare 复制反馈（短暂显示勾选）
    @State private var cfCopiedValue: String?
    @State private var cfCopyResetTask: Task<Void, Never>?

    // 折叠区段状态（DeepSeek 页）
    @State private var showAccountSection = true    // 余额/充值/提示行
    @State private var showUsageStatsSection = true // 用量统计
    @State private var showUsageListSection = true  // 请求列表/图表
    @State private var showSourceUsageSection = true // 来源用量（图表/列表）

    var body: some View {
        popoverContent
            .scaleEffect(uiScale, anchor: .topLeading)
            .frame(width: AppConfig.popoverWidth * uiScale,
                   height: AppConfig.popoverHeight * uiScale,
                   alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) { resizeGrip }
            .overlay(alignment: .top) { alertBannerOverlay }
            .frame(width: AppConfig.popoverWidth * uiScale,
                   height: AppConfig.popoverHeight * uiScale)
            .clipped()
    }

    /// 右下角拖拽把手：按宽度变化等比缩放整个弹窗（UI/字体/图标一起放大）。
    private var resizeGrip: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = scaleDragStart ?? uiScale
                        scaleDragStart = start
                        let next = AppConfig.clampedPopoverScale(
                            start + value.translation.width / AppConfig.popoverWidth
                        )
                        if abs(next - uiScale) > 0.001 {
                            uiScale = next
                            AppConfig.setSavedPopoverScale(next)
                            postPopoverResize()
                        }
                    }
                    .onEnded { _ in
                        scaleDragStart = nil
                    }
            )
            .modifier(HoverTooltip(text: Strings.resizePopoverHint, position: .above))
    }

    /// 通知 StatusBarController 把窗口调整到当前 uiScale 对应的大小。
    private func postPopoverResize() {
        NotificationCenter.default.post(name: .popoverResizeRequested,
                                        object: NSNumber(value: Double(uiScale)))
    }

    /// 弹窗主体：固定 334×550 布局，由外层按 uiScale 整体缩放。
    private var popoverContent: some View {
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
            } else if selectedTab == 4 {
                cloudflareTabContent
                    .alert(Strings.cloudflareConfirmTitle, isPresented: $showCFConfirm, presenting: cfConfirmRequest) { req in
                        Button(Strings.cancel, role: .cancel) {}
                        Button(cfConfirmButtonLabel(req)) { performCF(req) }
                    } message: { req in
                        Text(cfConfirmMessage(req))
                    }
            } else if selectedTab == 6 {
                netlifyTabContent
                    .alert(Strings.netlifyConfirmTitle, isPresented: $showNetlifyConfirm, presenting: netlifyConfirmRequest) { req in
                        Button(Strings.cancel, role: .cancel) {}
                        Button(netlifyConfirmButtonLabel(req)) { performNetlify(req) }
                    } message: { req in
                        Text(netlifyConfirmMessage(req))
                    }
            } else if selectedTab == 7 {
                localDBsTabContent
            } else if selectedTab == 5 {
                ScrollView { alertsTabContent.padding(14) }
            } else if selectedTab == 2 {
                // GitHub 页自行管理布局：页内子页签（Actions / 仓库）+ 独立滚动
                gitHubTabContent
            } else {
                ScrollView { licenseTabContent }
            }
            Divider().padding(.horizontal, 14)
            actionBar
        }
        .padding(.vertical, 16)
        .frame(width: AppConfig.popoverWidth)
        .frame(maxHeight: 550)
        .scrollIndicators(.hidden)
        .onAppear {
            loadUsage(); loadSourceUsage(); loadSourceOptions(); postPopoverResize()
            recentAlerts = AppAlertCenter.recent
        }
        .onReceive(NotificationCenter.default.publisher(for: .usageRecorded)) { _ in
            loadUsage(); loadSourceUsage(); loadSourceOptions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appAlertDidFire)) { note in
            guard let alert = note.object as? AppAlert else { return }
            recentAlerts = AppAlertCenter.recent
            showBanner(alert)
        }
        .onReceive(NotificationCenter.default.publisher(for: .appAlertDidUpdate)) { _ in
            recentAlerts = AppAlertCenter.recent
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
                        iconColor: stats.pricingWindowIconColor,
                        label: Strings.pricingWindowLabel,
                        value: stats.pricingWindowDetailText,
                        valueColor: stats.pricingWindowTextColor)
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
    @State private var sourceRepos: [String: [String]] = [:]
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
                sourceRepos = await store.reposBySource(since: since, sourceIP: src, providerId: pid)
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
                    aggregateSortableHeader("Source", key: "source", width: 76, align: .leading)
                    aggregateSortableHeader("pid", key: "pid", width: 38, align: .leading)
                    aggregateSortableHeader("Req", key: "req", width: 22, align: .trailing)
                    aggregateSortableHeader("Tokens", key: "tokens", width: 30, align: .trailing)
                    aggregateSortableHeader("Cost", key: "cost", width: 42, align: .trailing)
                    aggregateSortableHeader(Strings.lastSeenLabel, key: "last", width: 48, align: .trailing)
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
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(sourceDisplayName(item))
                                        .font(.system(size: 8.5))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    if let repos = sourceRepos[item.sourceIP], !repos.isEmpty {
                                        Text(repos.joined(separator: " · "))
                                            .font(.system(size: 6.5))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .help(repos.joined(separator: "\n"))
                                    }
                                }
                                .frame(width: 76, alignment: .leading)
                                Text(item.providerIds.isEmpty ? "—" : item.providerIds)
                                    .font(.system(size: 8.5))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: 38, alignment: .leading)
                                    .foregroundColor(.secondary)
                                Text("\(item.requestCount)")
                                    .font(.system(size: 8.5).monospacedDigit())
                                    .frame(width: 22, alignment: .trailing)
                                Text(Strings.tokensShort(item.totalTokens))
                                    .font(.system(size: 8.5).monospacedDigit())
                                    .frame(width: 30, alignment: .trailing)
                                Text(Strings.costShort(item.totalCost))
                                    .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                                    .frame(width: 42, alignment: .trailing)
                                Text(Self.sourceTimeFormatter.string(from: item.lastTimestamp))
                                    .font(.system(size: 7).monospacedDigit())
                                    .frame(width: 48, alignment: .trailing)
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
            tabButton(symbol: "brain.head.profile", tag: 0, tooltip: Strings.usageTabTooltip)
            tabButton(symbol: "key.fill", tag: 1, tooltip: Strings.licenseTabTooltip)
            tabButton(assetName: "github", symbol: "chevron.left.forwardslash.chevron.right", tag: 2, tooltip: Strings.githubTabTooltip)
            tabButton(assetName: "aws", symbol: "cloud.fill", tag: 3, tooltip: Strings.awsTabTooltip)
            tabButton(assetName: "cloudflare", symbol: "cloud.bolt.fill", tag: 4, tooltip: Strings.cloudflareTabTooltip)
            tabButton(assetName: "netlify", symbol: "diamond.fill", tag: 6, tooltip: Strings.netlifyTabTooltip)
            tabButton(symbol: "cylinder.split.1x2", tag: 7, tooltip: Strings.localDBsTabTooltip)
            alertsTabButton
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func tabButton(assetName: String? = nil, symbol: String, tag: Int, tooltip: String) -> some View {
        let active = selectedTab == tag
        return Button(action: { selectedTab = tag }) {
            BrandTabIcon(assetName: assetName, symbol: symbol, size: 13)
                .foregroundColor(active ? .white : .secondary)
                .frame(width: 30, height: 24)
                .background(active ? Color.blue : Color.clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
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
            githubSubTabBar
            Divider().padding(.horizontal, 14)
            if gitHubSubTab == 0 {
                gitHubActionsContent
            } else {
                gitHubReposContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var githubSubTabBar: some View {
        HStack(spacing: 4) {
            githubSubTabButton(Strings.githubSubTabActions, tag: 0)
            githubSubTabButton(Strings.githubSubTabRepos, tag: 1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func githubSubTabButton(_ title: String, tag: Int) -> some View {
        let active = gitHubSubTab == tag
        return Button(action: { gitHubSubTab = tag }) {
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

    // GitHub 页 - Actions 子页（免费额度用量）
    private var gitHubActionsContent: some View {
        Group {
            if stats.gitHub.isLoading {
                VStack(spacing: 12) {
                    Spacer(minLength: 40)
                    HStack { Spacer(); ProgressView().scaleEffect(1.2); Spacer() }
                    Spacer(minLength: 40)
                }
            } else if let err = stats.gitHub.errorMessage {
                VStack(spacing: 8) {
                    Spacer(minLength: 40)
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundColor(.orange)
                    Text(err).font(.caption).foregroundColor(.orange).multilineTextAlignment(.center)
                    Text("Settings -> Services to configure")
                        .font(.caption2).foregroundColor(.secondary)
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 14)
            } else {
                ScrollView {
                    gitHubDataView
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: GitHub — Repositories（仓库列表 + 详情）

    private var gitHubReposContent: some View {
        Group {
            if !stats.gitHub.isEnabled {
                ghCenteredMessage(icon: "key.slash", text: Strings.githubNotConfigured)
            } else if stats.gitHub.reposLoading && stats.gitHub.repos.isEmpty {
                VStack(spacing: 12) {
                    Spacer(minLength: 40)
                    HStack { Spacer(); ProgressView().scaleEffect(1.2); Spacer() }
                    Spacer(minLength: 40)
                }
            } else if stats.gitHub.repos.isEmpty, let err = stats.gitHub.reposError {
                ghCenteredError(err)
            } else if stats.gitHub.repos.isEmpty {
                ghCenteredMessage(icon: "tray", text: Strings.githubNoRepos)
            } else {
                githubReposListView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            stats.gitHub.refreshRepos()
            ensureGHRepoSelection()
        }
        .onChange(of: stats.gitHub.repos) { _, _ in ensureGHRepoSelection() }
        .onChange(of: ghSelectedRepoID) { _, newValue in
            guard let id = newValue else { return }
            stats.gitHub.loadRepoDetail(fullName: id)
        }
    }

    private func ghCenteredMessage(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 40)
            Image(systemName: icon).font(.title2).foregroundColor(.secondary)
            Text(text).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ghCenteredError(_ err: String) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 40)
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundColor(.orange)
            Text(err).font(.caption).foregroundColor(.orange).multilineTextAlignment(.center)
            Text("Settings -> Services to configure").font(.caption2).foregroundColor(.secondary)
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var githubReposListView: some View {
        VStack(spacing: 0) {
            SearchableSelector(
                items: stats.gitHub.repos,
                selectedID: ghSelectedRepoID,
                searchText: $ghSearchText,
                placeholder: Strings.githubSearchPlaceholder,
                noMatchesText: Strings.searchNoMatches,
                match: { repo, q in
                    repo.name.localizedCaseInsensitiveContains(q)
                        || repo.fullName.localizedCaseInsensitiveContains(q)
                        || (repo.desc ?? "").localizedCaseInsensitiveContains(q)
                },
                onSelect: { repo in
                    ghSelectedRepoID = repo.id
                }
            ) { repo in
                HStack(spacing: 6) {
                    Image(systemName: repo.isPrivate ? "lock.fill" : "globe")
                        .font(.system(size: 8))
                        .foregroundColor(repo.isPrivate ? .orange : .green)
                        .frame(width: 10)
                    Text(repo.name)
                        .font(.system(size: 10))
                        .lineLimit(1).truncationMode(.tail)
                }
            }

            Divider().padding(.horizontal, 14)

            if let repo = selectedGHRepo {
                ScrollView {
                    githubRepoDetailView(repo)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack {
                    Spacer()
                    Text(Strings.githubNoSelectionHint)
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedGHRepo: GitHubRepo? {
        guard let id = ghSelectedRepoID else { return nil }
        return stats.gitHub.repos.first { $0.id == id }
    }

    private func ensureGHRepoSelection() {
        guard !stats.gitHub.repos.isEmpty else { ghSelectedRepoID = nil; return }
        if ghSelectedRepoID == nil
            || !stats.gitHub.repos.contains(where: { $0.id == ghSelectedRepoID }) {
            ghSelectedRepoID = stats.gitHub.repos[0].id
        }
    }

    private func githubRepoDetailView(_ repo: GitHubRepo) -> some View {
        let showing = stats.gitHub.repoDetailFor == repo.id
        let loading = showing && stats.gitHub.repoDetailLoading
        let det = showing ? stats.gitHub.repoDetail : nil

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: repo.isPrivate ? "lock.fill" : "globe")
                    .font(.system(size: 9))
                    .foregroundColor(repo.isPrivate ? .orange : .green)
                Text(repo.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                githubOpenIcon(URL(string: repo.htmlURL), size: 9)
                githubCopyButton(repo.fullName, size: 9)
            }
            if let d = repo.desc, !d.isEmpty {
                Text(d).font(.caption2).foregroundColor(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(Strings.githubVisibilityLabel).font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text(repo.isPrivate ? Strings.githubPrivateLabel : Strings.githubPublicLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(repo.isPrivate ? .orange : .green)
            }
            HStack(spacing: 6) {
                Text(Strings.githubCreatedLabel).font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text(Self.ghDateText(repo.createdAt))
                    .font(.system(size: 9))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
            }
            Divider().padding(.vertical, 2)

            if loading {
                HStack(spacing: 8) {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text(Strings.githubDetailLoading).font(.caption2).foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.vertical, 14)
            } else if let det {
                let repoKey = repo.id
                ghCollapsibleSection(title: Strings.githubCommitsSection,
                                     icon: "clock.arrow.circlepath",
                                     expanded: ghSectionBinding(repoKey, kind: "commits")) {
                    if det.commits.isEmpty {
                        ghEmptyLine(Strings.githubNoCommits)
                    } else {
                        ForEach(det.commits) { c in ghCommitRow(c) }
                    }
                }
                ghCollapsibleSection(title: Strings.githubBranchesSection,
                                     icon: "arrow.branch",
                                     expanded: ghSectionBinding(repoKey, kind: "branches"),
                                     count: det.branches.count) {
                    if det.branches.isEmpty {
                        ghEmptyLine(Strings.githubNoBranches)
                    } else {
                        ForEach(det.branches.prefix(20)) { b in ghBranchRow(b, repo: repo) }
                        if det.branches.count > 20 {
                            ghEmptyLine(String(format: Strings.githubMoreBranches, det.branches.count - 20))
                        }
                    }
                }
                ghCollapsibleSection(title: Strings.githubReleasesSection,
                                     icon: "tag",
                                     expanded: ghSectionBinding(repoKey, kind: "releases")) {
                    if det.releases.isEmpty {
                        ghEmptyLine(Strings.githubNoReleases)
                    } else {
                        ForEach(det.releases) { rel in ghReleaseRow(rel) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - GitHub 详情折叠区段（提交 / 分支 / 发布）

    private func ghSectionBinding(_ repoID: String, kind: String) -> Binding<Bool> {
        let key = "\(repoID)|\(kind)"
        return Binding(
            get: { ghSectionExpanded[key, default: true] },
            set: { ghSectionExpanded[key] = $0 }
        )
    }

    @ViewBuilder
    private func ghCollapsibleSection<Content: View>(title: String, icon: String,
                                                     expanded: Binding<Bool>,
                                                     count: Int? = nil,
                                                     @ViewBuilder content: () -> Content) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 8)).foregroundColor(.teal).frame(width: 14)
                Text(title).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                if let count { Text("\(count)").font(.system(size: 8)).foregroundColor(.secondary) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)

        if expanded.wrappedValue {
            content()
        }
    }

    private func ghEmptyLine(_ text: String) -> some View {
        HStack {
            Text(text).font(.caption2).foregroundColor(.secondary).padding(.leading, 20)
            Spacer()
        }
        .padding(.vertical, 1)
    }

    private func ghCommitRow(_ c: GitHubCommit) -> some View {
        HStack(spacing: 6) {
            Text(c.shortSha)
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(c.message)
                .font(.system(size: 8))
                .lineLimit(1).truncationMode(.tail)
            if let d = c.date {
                Text(Self.ghRelativeDate(d))
                    .font(.system(size: 7)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            githubOpenIcon(URL(string: c.htmlURL))
            githubCopyButton(c.sha)
        }
    }

    private func ghBranchRow(_ b: GitHubBranch, repo: GitHubRepo) -> some View {
        HStack(spacing: 6) {
            Text(b.name)
                .font(.system(size: 8, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            githubOpenIcon(URL(string: repo.htmlURL + "/tree/" + b.name))
            githubCopyButton(b.name)
        }
    }

    private func ghReleaseRow(_ rel: GitHubRelease) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tag.fill").font(.system(size: 6)).foregroundColor(.purple)
            Text(rel.name)
                .font(.system(size: 8))
                .lineLimit(1).truncationMode(.middle)
            if let d = rel.published {
                Text(Self.ghRelativeDate(d))
                    .font(.system(size: 7)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            githubOpenIcon(URL(string: rel.htmlURL))
            githubCopyButton(rel.tag)
        }
    }

    private func githubOpenIcon(_ url: URL?, size: CGFloat = 8) -> some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: size)).foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .modifier(HoverTooltip(text: Strings.githubOpenAction, position: .below))
    }

    private func githubCopyButton(_ value: String, size: CGFloat = 8) -> some View {
        let copied = ghCopiedValue == value
        return Button(action: { githubCopyValue(value) }) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: size))
                .foregroundColor(copied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .modifier(HoverTooltip(text: copied ? Strings.githubCopied : Strings.githubCopyAction,
                               position: .below))
    }

    private func githubCopyValue(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        ghCopiedValue = value
        ghCopyResetTask?.cancel()
        ghCopyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            ghCopiedValue = nil
        }
    }

    private static func ghDateText(_ d: Date?) -> String {
        d?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }

    private static func ghRelativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
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

    // MARK: - AWS Instances (dropdown + full-width detail)

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
                SearchableSelector(
                    items: stats.aws.instances.sorted(by: awsInstanceSort),
                    selectedID: awsSelectedID,
                    searchText: $awsInstanceSearchText,
                    placeholder: Strings.awsSearchPlaceholder,
                    noMatchesText: Strings.searchNoMatches,
                    match: { inst, q in
                        inst.instanceId.localizedCaseInsensitiveContains(q)
                            || (inst.name ?? "").localizedCaseInsensitiveContains(q)
                            || inst.instanceType.localizedCaseInsensitiveContains(q)
                            || awsStateText(inst.state).localizedCaseInsensitiveContains(q)
                            || (inst.publicIp ?? "").localizedCaseInsensitiveContains(q)
                            || (inst.privateIp ?? "").localizedCaseInsensitiveContains(q)
                    },
                    onSelect: { inst in
                        awsSelectedID = inst.instanceId
                    }
                ) { inst in
                    HStack(spacing: 6) {
                        Circle().fill(awsStateColor(inst.state)).frame(width: 6, height: 6)
                        Text(inst.instanceId)
                            .font(.system(size: 9, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        if let name = inst.name, !name.isEmpty {
                            Text(name).font(.system(size: 9)).foregroundColor(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Text(inst.instanceType)
                            .font(.system(size: 8)).foregroundColor(.secondary)
                    }
                }
                .onChange(of: awsSelectedID) { _, newValue in
                    guard let id = newValue,
                          let inst = stats.aws.instances.first(where: { $0.instanceId == id })
                    else { return }
                    awsActionMessage = nil
                    closeRuleEditor()
                    refreshIngress(for: inst)
                }

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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { ensureAWSSelection() }
        .onChange(of: stats.aws.instances) { _, _ in ensureAWSSelection() }
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
                    awsInfoRow(Strings.awsPublicIPLabel, value: ip, selectable: true, copy: ip)
                }
                if inst.isRunning, let dns = inst.publicDns, !dns.isEmpty {
                    awsInfoRow(Strings.awsPublicDNSLabel, value: dns, selectable: true, copy: dns)
                }
                if let ip = inst.privateIp {
                    awsInfoRow(Strings.awsPrivateIPLabel, value: ip, selectable: true, copy: ip)
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

                // 主操作行：Start/Stop + 运行中可用「打开 RDP」发起连接
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
                        awsActionButton(Strings.awsOpenRDPAction, icon: "display", color: .blue,
                                        disabled: awsPending.contains(inst.instanceId)) {
                            openRDPConnection(for: inst)
                        }
                    }
                    Spacer()
                    if awsPending.contains(inst.instanceId) {
                        ProgressView().controlSize(.small)
                    }
                }

                // 防火墙行：仅在 RDP 尚未对你的 IP 开放时显示
                if let gid = inst.primarySecurityGroupId,
                   (stats.aws.rdpIngress[gid] ?? .unknown) != .open {
                    awsActionButton(Strings.awsAddIngressAction, icon: "lock.open.fill", color: .blue,
                                    disabled: awsPending.contains(inst.instanceId)) {
                        beginAWSConfirm(.ingress, instanceId: inst.instanceId, groupId: gid)
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
                    Text("–").foregroundColor(.secondary)
                    TextField(Strings.awsPortTo, text: $awsRuleToPort)
                        .textFieldStyle(.roundedBorder).font(.system(size: 10))
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

    private func awsInfoRow(_ label: String, value: String, selectable: Bool = false, copy: String? = nil) -> some View {
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
            if let c = copy {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c, forType: .string)
                    awsActionSuccess = true
                    awsActionMessage = Strings.awsCopiedMessage
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .modifier(HoverTooltip(text: Strings.awsCopyAction, position: .below))
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
        awsActionMessage = nil
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
        awsActionMessage = nil
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

    /// 「打开 RDP」：把实例的公网 DNS/IP 复制到剪贴板，并尝试用 rdp:// 拉起远程桌面客户端
    /// （优先使用已安装的 Microsoft “Windows App”）。
    @MainActor
    private func openRDPConnection(for inst: AWSInstance) {
        let target: String?
        if let dns = inst.publicDns, !dns.isEmpty {
            target = dns
        } else if let ip = inst.publicIp, !ip.isEmpty {
            target = ip
        } else {
            target = nil
        }
        guard let target else {
            awsActionSuccess = false
            awsActionMessage = Strings.awsRDPNoAddress
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(target, forType: .string)

        guard let url = URL(string: "rdp://full%20address=s:\(target):3389") else {
            awsActionSuccess = false
            awsActionMessage = Strings.awsRDPOpenFailed
            return
        }
        let opened = launchRDPClient(url: url)
        awsActionSuccess = opened
        awsActionMessage = opened ? Strings.awsRDPConnectMessage : Strings.awsRDPOpenFailed
    }

    /// 优先用 Microsoft “Windows App”（com.microsoft.windowsapp）打开 rdp:// 地址；
    /// 找不到时回退到系统已注册的 rdp:// 处理器。返回是否成功发起打开。
    @MainActor
    private func launchRDPClient(url: URL) -> Bool {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.windowsapp") {
            NSWorkspace.shared.open([url], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
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
            for _ in 0..<maxAttempts {
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

    // MARK: - Cloudflare Tab

    private var cloudflareSubTabBar: some View {
        HStack(spacing: 4) {
            cfSubTabButton(Strings.cloudflareSubTabOverview, tag: 0)
            cfSubTabButton(Strings.cloudflareSubTabHostnames, tag: 1)
            cfSubTabButton(Strings.cloudflareSubTabRoutes, tag: 2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func cfSubTabButton(_ title: String, tag: Int) -> some View {
        let active = cloudflareSubTab == tag
        return Button(action: { cloudflareSubTab = tag }) {
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

    private var cloudflareTabContent: some View {
        VStack(spacing: 0) {
            if stats.cloudflare.isLoading {
                Spacer(minLength: 40)
                HStack { Spacer(); ProgressView().scaleEffect(1.2); Spacer() }
                Spacer(minLength: 40)
            } else if !stats.cloudflare.isEnabled {
                cloudflareUnconfiguredState
            } else if let err = stats.cloudflare.errorMessage {
                Spacer(minLength: 40)
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundColor(.orange)
                    Text(err).font(.caption).foregroundColor(.orange).multilineTextAlignment(.center)
                    Text(Strings.cloudflareConfigHint)
                        .font(.caption2).foregroundColor(.secondary)
                    // 出错时也能直接从 popover 重试验证（无需回 Settings）。
                    cfActionButton(Strings.cloudflareVerifyAction, "checkmark.seal.fill", color: .blue,
                                   disabled: false) {
                        Task { await stats.cloudflare.verifyAndDiscover() }
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 40)
            } else {
                cloudflareSubTabBar
                Divider().padding(.horizontal, 14)
                if cloudflareSubTab == 0 {
                    ScrollView { cloudflareOverviewView.padding(14) }
                } else if cloudflareSubTab == 1 {
                    ScrollView { cloudflareHostnamesView.padding(14) }
                } else {
                    ScrollView { cloudflareRoutesView.padding(14) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cloudflareUnconfiguredState: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "cloud.bolt.fill").font(.title2).foregroundColor(.secondary)
                Text(Strings.cloudflareConfigHint)
                    .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    private var cloudflareOverviewView: some View {
        VStack(alignment: .leading, spacing: 10) {
            let cf = stats.cloudflare
            // 本机服务状态
            HStack(spacing: 6) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 8))
                    .foregroundColor(cf.daemonRunning ? .green : .red)
                    .frame(width: 14)
                Text(Strings.cloudflareDaemonRow).font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text(cfDaemonStatusText)
                    .font(.system(size: 9))
                    .foregroundColor(cf.daemonRunning ? .green : .red)
            }

            // Start / Stop / Restart
            HStack(spacing: 6) {
                cfActionButton(Strings.cloudflareStartAction, "play.fill", color: .green,
                               disabled: cf.daemonRunning) {
                    cfConfirmRequest = CFConfirmRequest(kind: .start)
                    showCFConfirm = true
                }
                cfActionButton(Strings.cloudflareStopAction, "stop.fill", color: .red,
                               disabled: !cf.daemonRunning) {
                    cfConfirmRequest = CFConfirmRequest(kind: .stop)
                    showCFConfirm = true
                }
                cfActionButton(Strings.cloudflareRestartAction, "arrow.clockwise", color: .orange,
                               disabled: !cf.daemonRunning) {
                    cfConfirmRequest = CFConfirmRequest(kind: .restart)
                    showCFConfirm = true
                }
                Spacer()
            }

            if let t = cf.selectedTunnel {
                Divider().padding(.vertical, 2)
                HStack(spacing: 6) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 8)).foregroundColor(.blue).frame(width: 14)
                    Text(t.name.isEmpty ? t.id : t.name)
                        .font(.system(size: 9, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(cfHealthText(t))
                        .font(.system(size: 9))
                        .foregroundColor(cfHealthColor(t))
                }
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 8)).foregroundColor(.secondary).frame(width: 14)
                    Text(Strings.cloudflareConnectors).font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: Strings.cloudflareConnectorsFormat, t.connectorCount))
                        .font(.system(size: 9).monospacedDigit())
                }
                // 服务进程已运行但隧道未连上（token 失效/缺失、网络等）——给出可操作的提示。
                if cf.daemonRunning && !t.isHealthy {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8)).foregroundColor(.orange).frame(width: 14)
                        Text(Strings.cloudflareRunningNotConnected)
                            .font(.system(size: 8)).foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 8)).foregroundColor(.secondary).frame(width: 14)
                    Text(Strings.cloudflareLastUpdate).font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text(cf.lastUpdate)
                        .font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary)
                }
            } else if cf.tunnels.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 8)).foregroundColor(.secondary).frame(width: 14)
                    Text(Strings.cloudflareNoSelection).font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                }
            }

            if let msg = cf.actionMessage {
                HStack(spacing: 6) {
                    Image(systemName: cf.actionSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(cf.actionSuccess ? .green : .red)
                        .frame(width: 14)
                    Text(msg).font(.system(size: 8)).foregroundColor(cf.actionSuccess ? .secondary : .red)
                    Spacer()
                }
            }
        }
    }

    private var cloudflareHostnamesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Strings.cloudflareSubTabHostnames)
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Button {
                    showAddHostname.toggle()
                    if !showAddHostname { cfHostname = "" }
                } label: {
                    Image(systemName: showAddHostname ? "xmark" : "plus")
                        .font(.system(size: 9)).foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }

            if showAddHostname {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(Strings.cloudflareHostnameField, text: $cfHostname)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 9))
                    TextField(Strings.cloudflareServiceField, text: $cfService)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 9))
                    HStack {
                        Spacer()
                        Button(action: addCFHostname) {
                            Text(Strings.cloudflareAddAction)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 3)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(cfHostname.trimmingCharacters(in: .whitespaces).isEmpty
                                  || cfService.trimmingCharacters(in: .whitespaces).isEmpty
                                  || stats.cloudflare.isWorking)
                    }
                }
            }

            if stats.cloudflare.ingress.isEmpty {
                HStack {
                    Spacer()
                    Text(Strings.cloudflareHostnamesEmpty)
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ForEach(stats.cloudflare.ingress) { rule in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.hostname)
                                .font(.system(size: 9, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                            Text(rule.service)
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        cfCopyButton(rule.hostname)
                        Button {
                            cfConfirmRequest = CFConfirmRequest(kind: .removeHostname(rule.hostname))
                            showCFConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 9)).foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(stats.cloudflare.isWorking)
                    }
                    if rule.hostname != stats.cloudflare.ingress.last?.hostname {
                        Divider().padding(.leading, 8)
                    }
                }
            }
        }
    }

    private var cloudflareRoutesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Strings.cloudflareSubTabRoutes)
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Button {
                    showAddRoute.toggle()
                    if !showAddRoute { cfNetwork = "" }
                } label: {
                    Image(systemName: showAddRoute ? "xmark" : "plus")
                        .font(.system(size: 9)).foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }

            if showAddRoute {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(Strings.cloudflareNetworkField, text: $cfNetwork)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 9))
                    TextField(Strings.cloudflareCommentField, text: $cfComment)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 9))
                    HStack {
                        Spacer()
                        Button(action: addCFRoute) {
                            Text(Strings.cloudflareAddAction)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 3)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(cfNetwork.trimmingCharacters(in: .whitespaces).isEmpty
                                  || stats.cloudflare.isWorking)
                    }
                }
            }

            if stats.cloudflare.ipRoutes.isEmpty {
                HStack {
                    Spacer()
                    Text(Strings.cloudflareRoutesEmpty)
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ForEach(stats.cloudflare.ipRoutes) { route in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(route.network)
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                            if let c = route.comment, !c.isEmpty {
                                Text(c)
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer()
                        cfCopyButton(route.network)
                        Button {
                            cfConfirmRequest = CFConfirmRequest(kind: .removeRoute(route.network))
                            showCFConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 9)).foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(stats.cloudflare.isWorking)
                    }
                    if route.network != stats.cloudflare.ipRoutes.last?.network {
                        Divider().padding(.leading, 8)
                    }
                }
            }
        }
    }

    private func cfActionButton(_ title: String, _ icon: String, color: Color,
                                disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 8))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(disabled ? Color.secondary : color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(disabled ? Color.gray.opacity(0.12) : color.opacity(0.15))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .disabled(disabled || stats.cloudflare.isWorking)
    }

    private var cfDaemonStatusText: String {
        switch stats.cloudflare.daemonState {
        case .running: return Strings.cloudflareDaemonRunning
        case .installed: return Strings.cloudflareDaemonInstalled
        case .notInstalled: return Strings.cloudflareDaemonNotInstalled
        }
    }

    private func cfHealthText(_ t: CloudflareTunnel) -> String {
        switch t.status {
        case "healthy": return Strings.cloudflareTunnelHealthy
        case "degraded": return Strings.cloudflareTunnelDegraded
        case "down": return Strings.cloudflareTunnelDown
        default: return Strings.cloudflareTunnelInactive
        }
    }

    private func cfHealthColor(_ t: CloudflareTunnel) -> Color {
        switch t.status {
        case "healthy": return .green
        case "degraded": return .orange
        case "down": return .red
        default: return .secondary
        }
    }

    private func cfConfirmButtonLabel(_ req: CFConfirmRequest) -> String {
        switch req.kind {
        case .start: return Strings.cloudflareStartAction
        case .stop: return Strings.cloudflareStopAction
        case .restart: return Strings.cloudflareRestartAction
        case .removeHostname, .removeRoute: return Strings.cloudflareRemoveAction
        }
    }

    private func cfConfirmMessage(_ req: CFConfirmRequest) -> String {
        switch req.kind {
        case .start: return Strings.cloudflareStartConfirm
        case .stop: return Strings.cloudflareStopConfirm
        case .restart: return Strings.cloudflareRestartConfirm
        case .removeHostname(let h): return String(format: Strings.cloudflareRemoveHostnameConfirm, h)
        case .removeRoute(let n): return String(format: Strings.cloudflareRemoveRouteConfirm, n)
        }
    }

    private func performCF(_ req: CFConfirmRequest) {
        Task {
            switch req.kind {
            case .start: await stats.cloudflare.startTunnel()
            case .stop: await stats.cloudflare.stopTunnel()
            case .restart: await stats.cloudflare.restartTunnel()
            case .removeHostname(let h): await stats.cloudflare.removePublicHostname(hostname: h)
            case .removeRoute(let n): await stats.cloudflare.removeIPRoute(network: n)
            }
        }
    }

    private func addCFHostname() {
        let h = cfHostname.trimmingCharacters(in: .whitespaces)
        let s = cfService.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, !s.isEmpty else { return }
        cfHostname = ""
        showAddHostname = false
        Task { await stats.cloudflare.addPublicHostname(hostname: h, service: s) }
    }

    private func addCFRoute() {
        let n = cfNetwork.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        cfNetwork = ""
        showAddRoute = false
        Task { await stats.cloudflare.addIPRoute(network: n, comment: cfComment.trimmingCharacters(in: .whitespaces)) }
        cfComment = ""
    }

    // MARK: - Netlify Tab

    private var netlifyTabContent: some View {
        VStack(spacing: 0) {
            if !stats.netlify.isEnabled {
                netlifyUnconfiguredState
            } else if let err = stats.netlify.errorMessage, stats.netlify.sites.isEmpty {
                netlifyErrorState(err)
            } else if stats.netlify.sites.isEmpty {
                if stats.netlify.isLoading {
                    netlifyLoadingState
                } else {
                    netlifyNoSitesState
                }
            } else {
                netlifyProjectsView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var netlifyLoadingState: some View {
        VStack {
            Spacer(minLength: 40)
            HStack { Spacer(); ProgressView().scaleEffect(1.2); Spacer() }
            Spacer(minLength: 40)
        }
    }

    private var netlifyUnconfiguredState: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "icloud.and.arrow.up.fill").font(.title2).foregroundColor(.secondary)
                Text(Strings.netlifyConfigHint)
                    .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    private func netlifyErrorState(_ err: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundColor(.orange)
            Text(err).font(.caption).foregroundColor(.orange).multilineTextAlignment(.center)
            Text(Strings.netlifyConfigHint)
                .font(.caption2).foregroundColor(.secondary)
            netlifyActionButton(Strings.netlifyVerifyAction, "checkmark.seal.fill", color: .blue,
                                disabled: false) {
                Task { await stats.netlify.verifyAndDiscover() }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var netlifyNoSitesState: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "server.rack").font(.title2).foregroundColor(.secondary)
                Text(Strings.netlifySitesEmpty)
                    .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    // MARK: Netlify — Projects (dropdown + full-width detail)

    private var netlifyProjectsView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 8)).foregroundColor(.secondary).frame(width: 14)
                Text(stats.netlify.selectedAccount?.name ?? (stats.netlify.accountName ?? "-"))
                    .font(.system(size: 9)).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if stats.netlify.isWorking {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    toggleNetlifyNewSite()
                } label: {
                    Image(systemName: showNetlifyNewSite ? "xmark" : "plus")
                        .font(.system(size: 9)).foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .modifier(HoverTooltip(text: Strings.netlifyNewSiteAction, position: .below))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)

            if showNetlifyNewSite {
                netlifyNewSitePanel
            }

            SearchableSelector(
                items: stats.netlify.sites,
                selectedID: stats.netlify.selectedSiteID,
                searchText: $netlifySearchText,
                placeholder: Strings.netlifySearchPlaceholder,
                noMatchesText: Strings.searchNoMatches,
                match: { site, q in
                    site.name.localizedCaseInsensitiveContains(q)
                        || (site.customDomain ?? "").localizedCaseInsensitiveContains(q)
                        || site.displayName.localizedCaseInsensitiveContains(q)
                },
                onSelect: { site in
                    Task { await stats.netlify.selectSite(site.id) }
                }
            ) { site in
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 8)).foregroundColor(.teal).frame(width: 10)
                    Text(site.displayName)
                        .font(.system(size: 10))
                        .lineLimit(1).truncationMode(.tail)
                }
            }

            Divider().padding(.horizontal, 14)

            if let sel = stats.netlify.selectedSite {
                netlifySiteDetail(sel)
            } else if stats.netlify.isLoading {
                netlifyLoadingState
            } else {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "info.circle").font(.title3).foregroundColor(.secondary)
                    Text(Strings.netlifyNoSelectionHint)
                        .font(.caption).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { ensureNetlifySelection() }
        .onChange(of: stats.netlify.sites) { _, _ in ensureNetlifySelection() }
        .onChange(of: stats.netlify.selectedSiteID) { _, _ in
            netlifyDeploysExpanded = true
        }
    }

    @MainActor
    private func ensureNetlifySelection() {
        guard !stats.netlify.sites.isEmpty else { return }
        if stats.netlify.selectedSite == nil {
            Task { await stats.netlify.selectSite(stats.netlify.sites[0].id) }
        }
    }

    private func netlifySiteDetail(_ site: NetlifySite) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // 头部：站点名 + Live / 已锁定徽标
                HStack(spacing: 6) {
                    Circle()
                        .fill(site.publishedDeployID != nil ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(site.name)
                        .font(.system(size: 11, design: .monospaced).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .textSelection(.enabled)
                    Spacer()
                    if site.publishedDeployID != nil {
                        Text(Strings.netlifyLiveBadge)
                            .font(.system(size: 8))
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.12))
                            .cornerRadius(6)
                    }
                }

                // 动作行
                HStack(spacing: 6) {
                    netlifyActionButton(Strings.netlifyTriggerAction, "arrow.up.circle.fill", color: .green,
                                        disabled: stats.netlify.isWorking) {
                        beginNetlifyConfirm(.trigger, site: site)
                    }
                    netlifyActionButton(Strings.netlifyTriggerClearAction, "flame.fill", color: .orange,
                                        disabled: stats.netlify.isWorking) {
                        beginNetlifyConfirm(.triggerClearCache, site: site)
                    }
                    netlifyActionButton(Strings.netlifyDeployFolderAction, "folder.badge.gearshape", color: .blue,
                                        disabled: stats.netlify.isWorking) {
                        netlifyDeployFolder(for: site)
                    }
                    Spacer()
                }
                HStack(spacing: 6) {
                    netlifyActionButton(Strings.netlifyOpenSiteAction, "safari", color: .teal,
                                        disabled: false) {
                        if let url = netlifySiteURL(site) { NSWorkspace.shared.open(url) }
                    }
                    netlifyActionButton(Strings.netlifyOpenAdminAction, "arrow.up.right.square", color: .teal,
                                        disabled: false) {
                        if let url = netlifyAdminURL(site) { NSWorkspace.shared.open(url) }
                    }
                    Spacer()
                }

                // 站点信息行（均可复制 / 打开）
                netlifyInfoRow(Strings.netlifyProjectIDLabel, value: site.id, copy: site.id)
                if let d = site.customDomain, !d.isEmpty {
                    netlifyInfoRow(Strings.netlifyCustomDomainLabel, value: d, copy: d)
                }
                if let u = site.url, !u.isEmpty {
                    netlifyInfoRow(Strings.netlifyMainURLLabel, value: u, copy: u,
                                   openURL: netlifySiteURL(site))
                }
                if let a = site.adminURL, !a.isEmpty {
                    netlifyInfoRow(Strings.netlifyAdminLabel, value: a, copy: a,
                                   openURL: netlifyAdminURL(site))
                }
                if let pid = site.publishedDeployID {
                    netlifyInfoRow(Strings.netlifyPublishedDeployLabel, value: pid, copy: pid)
                }

                // 构建设置
                if site.isGitLinked {
                    Divider().padding(.vertical, 2)
                    Text(Strings.netlifyBuildHeader)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                    if let r = site.repoURL, !r.isEmpty {
                        netlifyInfoRow(Strings.netlifyRepoLabel, value: r, copy: r)
                    }
                    if let b = site.repoBranch, !b.isEmpty {
                        netlifyInfoRow(Strings.netlifyBranchLabel, value: b, copy: b)
                    }
                    if let c = site.buildCommand, !c.isEmpty {
                        netlifyInfoRow(Strings.netlifyBuildCmdLabel, value: c, copy: c)
                    }
                    if let d = site.publishDir, !d.isEmpty {
                        netlifyInfoRow(Strings.netlifyPublishDirLabel, value: d, copy: d)
                    }
                }

                Divider().padding(.vertical, 2)

                // 部署历史（可折叠；显示最近 10 条）
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { netlifyDeploysExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(Strings.netlifyDeploysHeader)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.primary)
                        Spacer()
                        if stats.netlify.isWorking {
                            ProgressView().controlSize(.mini)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(netlifyDeploysExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)

                if netlifyDeploysExpanded {
                    netlifyDeploysSection(site)
                }

                if let msg = stats.netlify.actionMessage {
                    HStack(spacing: 6) {
                        Image(systemName: stats.netlify.actionSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundColor(stats.netlify.actionSuccess ? .green : .red)
                            .frame(width: 14)
                        Text(msg).font(.system(size: 8))
                            .foregroundColor(stats.netlify.actionSuccess ? .secondary : .red)
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func netlifyInfoRow(_ label: String, value: String,
                                copy: String? = nil, openURL: URL? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 9))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .textSelection(.enabled)
            if let url = openURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 8)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .modifier(HoverTooltip(text: Strings.netlifyOpenSiteAction, position: .below))
            }
            if let c = copy, !c.isEmpty {
                netlifyCopyButton(c)
            }
        }
    }

    private func netlifyDeploysSection(_ site: NetlifySite) -> some View {
        let list = stats.netlify.deploys
        let shown = Array(list.prefix(10))
        return VStack(alignment: .leading, spacing: 0) {
            if shown.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 8)).foregroundColor(.secondary).frame(width: 14)
                    Text(Strings.netlifyDeploysEmpty)
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(shown) { dep in
                    netlifyDeployRow(dep, site: site)
                    if dep.id != shown.last?.id {
                        Divider().padding(.leading, 8)
                    }
                }
            }
        }
    }

    private func netlifyDeployRow(_ dep: NetlifyDeploy, site: NetlifySite) -> some View {
        let isPublished = dep.id == site.publishedDeployID
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(netlifyStateColor(dep.state)).frame(width: 6, height: 6)
                if let ctx = netlifyContextText(dep.context), !ctx.isEmpty {
                    Text(ctx)
                        .font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
                }
                Text(netlifyDeployTitle(dep))
                    .font(.system(size: 9))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                if let t = dep.createdAt {
                    Text(Self.netlifyDateText(t))
                        .font(.system(size: 7).monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text(netlifyStateText(dep.state))
                    .font(.system(size: 8))
                    .foregroundColor(netlifyStateColor(dep.state))
                if isPublished {
                    Text(Strings.netlifyLiveBadge)
                        .font(.system(size: 8)).foregroundColor(.green)
                }
                if dep.locked {
                    Text(Strings.netlifyLockedBadge)
                        .font(.system(size: 8)).foregroundColor(.orange)
                }
                Spacer()
                if let permalink = dep.url ?? dep.deployURL, !permalink.isEmpty {
                    netlifyCopyButton(permalink)
                }
                if let a = dep.adminURL, let url = URL(string: a) {
                    netlifyOpenIcon(url, tooltip: Strings.netlifyOpenAdminAction)
                }
                if dep.isBuilt && !isPublished {
                    netlifyRowActionIcon("arrow.uturn.backward", color: .blue,
                                         tooltip: Strings.netlifyRollbackAction) {
                        beginNetlifyConfirm(.rollback(dep), site: site)
                    }
                }
                if isPublished || dep.locked {
                    if dep.locked {
                        netlifyRowActionIcon("lock.open", color: .orange,
                                             tooltip: Strings.netlifyUnlockAction) {
                            beginNetlifyConfirm(.unlock(dep), site: site)
                        }
                    } else {
                        netlifyRowActionIcon("lock", color: .orange,
                                             tooltip: Strings.netlifyLockAction) {
                            beginNetlifyConfirm(.lock(dep), site: site)
                        }
                    }
                }
            }
            if dep.isError, let msg = dep.errorMessage, !msg.isEmpty {
                Text(msg)
                    .font(.system(size: 7))
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: Netlify — helpers (rows / colors / copy / confirm)

    private func netlifyDeployTitle(_ dep: NetlifyDeploy) -> String {
        if let t = dep.title, !t.isEmpty { return t }
        if let b = dep.branch, !b.isEmpty { return b }
        return Self.netlifyDeployShort(dep.id)
    }

    private func netlifyContextText(_ context: String?) -> String? {
        switch context {
        case "production": return Strings.netlifyContextProduction
        case "branch-deploy": return Strings.netlifyContextBranch
        case "deploy-preview": return Strings.netlifyContextPreview
        case let c? where !c.isEmpty: return c.capitalized
        default: return nil
        }
    }

    private func netlifyStateColor(_ state: String) -> Color {
        switch state {
        case "ready", "current": return .green
        case "error": return .red
        case "old": return .secondary
        case "building", "uploading", "processing", "enqueued", "new", "preparing", "prepared": return .orange
        default: return .secondary
        }
    }

    private func netlifyStateText(_ state: String) -> String {
        switch state {
        case "ready": return Strings.netlifyStateReady
        case "current": return Strings.netlifyStateCurrent
        case "old": return Strings.netlifyStateOld
        case "error": return Strings.netlifyStateError
        case "building": return Strings.netlifyStateBuilding
        case "uploading": return Strings.netlifyStateUploading
        case "processing": return Strings.netlifyStateProcessing
        case "enqueued", "new": return Strings.netlifyStateEnqueued
        default: return state.capitalized
        }
    }

    private func netlifyActionButton(_ title: String, _ icon: String, color: Color,
                                     disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 8))
                Text(title).font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(disabled ? Color.secondary : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(disabled ? Color.gray.opacity(0.12) : color.opacity(0.15))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .disabled(disabled || stats.netlify.isWorking)
    }

    private func netlifyRowActionIcon(_ symbol: String, color: Color, tooltip: String,
                                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8)).foregroundColor(color)
        }
        .buttonStyle(.plain)
        .modifier(HoverTooltip(text: tooltip, position: .below))
        .disabled(stats.netlify.isWorking)
    }

    private func netlifyOpenIcon(_ url: URL, tooltip: String) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 8)).foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .modifier(HoverTooltip(text: tooltip, position: .below))
        .disabled(stats.netlify.isWorking)
    }

    private func netlifyCopyValue(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        netlifyCopiedValue = value
        netlifyCopyResetTask?.cancel()
        netlifyCopyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            netlifyCopiedValue = nil
        }
    }

    private func netlifyCopyButton(_ value: String) -> some View {
        let copied = netlifyCopiedValue == value
        return Button(action: { netlifyCopyValue(value) }) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9))
                .foregroundColor(copied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .modifier(HoverTooltip(text: copied ? Strings.netlifyCopied : Strings.netlifyCopyAction,
                               position: .below))
        .disabled(stats.netlify.isWorking)
    }

    private func netlifySiteURL(_ site: NetlifySite) -> URL? {
        if let u = site.url, let url = URL(string: u) { return url }
        return URL(string: "https://\(site.name).netlify.app")
    }

    private func netlifyAdminURL(_ site: NetlifySite) -> URL? {
        if let a = site.adminURL, let url = URL(string: a) { return url }
        return URL(string: "https://app.netlify.com/sites/\(site.name)")
    }

    private static func netlifyDeployShort(_ id: String) -> String {
        String(id.prefix(8))
    }

    private static func netlifyDateText(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Netlify — 新建站点（从本地目录）

    private var netlifyNewSitePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Strings.netlifyNewSiteSheetTitle)
                .font(.system(size: 10, weight: .semibold))
            TextField(Strings.netlifySiteNameField, text: $netlifySiteName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 9))
            HStack(spacing: 6) {
                Text(netlifyFolderURL?.path ?? "—")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(action: chooseNetlifyFolder) {
                    Text(Strings.netlifyChooseFolderAction).font(.system(size: 9))
                }
                .controlSize(.small)
            }
            Text(Strings.netlifyFolderHint)
                .font(.system(size: 8)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Strings.netlifyDeployTargetNote)
                .font(.system(size: 8)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                if netlifyCreating {
                    ProgressView().controlSize(.mini)
                }
                Button(Strings.cancel) { closeNetlifyNewSite() }
                    .controlSize(.small)
                Button(action: createNetlifySiteFlow) {
                    Text(Strings.netlifyCreateAndDeploy).font(.system(size: 9))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(netlifyCreating)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .cornerRadius(8)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    @MainActor
    private func toggleNetlifyNewSite() {
        showNetlifyNewSite.toggle()
        if !showNetlifyNewSite {
            netlifySiteName = ""
            netlifyFolderURL = nil
        }
    }

    @MainActor
    private func closeNetlifyNewSite() {
        showNetlifyNewSite = false
        netlifySiteName = ""
        netlifyFolderURL = nil
        netlifyCreating = false
    }

    @MainActor
    private func chooseNetlifyFolder() {
        let panel = NSOpenPanel()
        panel.title = Strings.netlifyDeployFolderAction
        panel.message = Strings.netlifyFolderHint
        panel.prompt = Strings.netlifyChooseFolderAction
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                netlifyFolderURL = url
            }
        }
    }

    @MainActor
    private func createNetlifySiteFlow() {
        guard !netlifyCreating else { return }
        let raw = netlifySiteName.trimmingCharacters(in: .whitespaces)
        let folder = netlifyFolderURL
        let name: String
        if !raw.isEmpty {
            name = Self.sanitizeSiteName(raw)
        } else if let folder {
            name = Self.sanitizeSiteName(folder.lastPathComponent)
        } else {
            name = "site-\(Int(Date().timeIntervalSince1970) % 100_000)"
        }
        guard !name.isEmpty else { return }
        netlifyCreating = true
        Task {
            let site = await stats.netlify.createSite(name: name)
            if let site, let folder {
                _ = await stats.netlify.deployLocalFolder(siteID: site.id, folderURL: folder,
                                                          siteNameForTitle: site.name)
            }
            netlifyCreating = false
            closeNetlifyNewSite()
        }
    }

    /// 把本地文件夹部署到「当前选中的站点」（已存在站点）。
    @MainActor
    private func netlifyDeployFolder(for site: NetlifySite) {
        let panel = NSOpenPanel()
        panel.title = Strings.netlifyDeployFolderAction
        panel.message = Strings.netlifyFolderHint
        panel.prompt = Strings.netlifyChooseFolderAction
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                _ = await stats.netlify.deployLocalFolder(siteID: site.id, folderURL: url,
                                                          siteNameForTitle: site.name)
            }
        }
    }

    /// Netlify 站点名只能是小写字母/数字/连字符。
    @MainActor private static func sanitizeSiteName(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(60))
    }

    // MARK: Netlify — confirm & dispatch

    @MainActor
    private func beginNetlifyConfirm(_ kind: NetlifyConfirmRequest.Kind, site: NetlifySite) {
        netlifyConfirmRequest = NetlifyConfirmRequest(kind: kind, siteID: site.id)
        showNetlifyConfirm = true
    }

    private func netlifyConfirmButtonLabel(_ req: NetlifyConfirmRequest) -> String {
        switch req.kind {
        case .trigger: return Strings.netlifyTriggerAction
        case .triggerClearCache: return Strings.netlifyTriggerClearAction
        case .rollback: return Strings.netlifyRollbackAction
        case .lock: return Strings.netlifyLockAction
        case .unlock: return Strings.netlifyUnlockAction
        }
    }

    private func netlifyConfirmMessage(_ req: NetlifyConfirmRequest) -> String {
        let name = stats.netlify.selectedSite?.displayName ?? req.siteID
        switch req.kind {
        case .trigger: return String(format: Strings.netlifyTriggerConfirm, name)
        case .triggerClearCache: return String(format: Strings.netlifyTriggerClearConfirm, name)
        case .rollback(let d): return String(format: Strings.netlifyRollbackConfirm, name, Self.netlifyDeployShort(d.id))
        case .lock(let d): return String(format: Strings.netlifyLockConfirm, Self.netlifyDeployShort(d.id))
        case .unlock(let d): return String(format: Strings.netlifyUnlockConfirm, Self.netlifyDeployShort(d.id))
        }
    }

    @MainActor
    private func performNetlify(_ req: NetlifyConfirmRequest) {
        guard let site = stats.netlify.selectedSite ?? stats.netlify.sites.first(where: { $0.id == req.siteID })
        else { return }
        Task {
            switch req.kind {
            case .trigger: await stats.netlify.triggerDeploy(site: site, clearCache: false, title: nil)
            case .triggerClearCache: await stats.netlify.triggerDeploy(site: site, clearCache: true, title: nil)
            case .rollback(let d): await stats.netlify.rollbackToDeploy(d, siteID: site.id)
            case .lock(let d): await stats.netlify.setDeployLocked(d, locked: true, siteID: site.id)
            case .unlock(let d): await stats.netlify.setDeployLocked(d, locked: false, siteID: site.id)
            }
        }
    }

    // MARK: - Local Databases Tab

    private var localDBsTabContent: some View {
        VStack(spacing: 0) {
            if !stats.localDBs.isEnabled {
                localDBsUnconfiguredState
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "cylinder.split.1x2")
                        .font(.system(size: 10)).foregroundColor(.teal)
                    Text(Strings.localDBsSection)
                        .font(.system(size: 10, weight: .semibold))
                    Spacer()
                    if stats.localDBs.isLoading {
                        ProgressView().controlSize(.mini)
                    }
                    Text(String(format: "%@ %@", Strings.netlifyLastUpdate, stats.localDBs.lastUpdate))
                        .font(.system(size: 8)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                Divider().padding(.horizontal, 14)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(stats.localDBs.services) { state in
                            localDBRow(state)
                            Divider().padding(.horizontal, 14)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var localDBsUnconfiguredState: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "cylinder.split.1x2").font(.title2).foregroundColor(.secondary)
                Text(Strings.localDBsConfigHint)
                    .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    private func localDBRow(_ state: LocalDBServiceState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                dbMonogram(state.id)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Strings.localDBName(state.id.rawValue))
                        .font(.system(size: 11, weight: .semibold))
                    HStack(spacing: 4) {
                        Circle().fill(dbStatusColor(state)).frame(width: 6, height: 6)
                        Text(dbStatusText(state)).font(.system(size: 9)).foregroundColor(dbStatusColor(state))
                        if let uptime = state.uptimeSeconds {
                            Text("· \(Strings.dbUptime(uptime))")
                                .font(.system(size: 9)).foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()
                if state.working {
                    ProgressView().controlSize(.mini)
                } else {
                    localDBActionButton(Strings.dbActionStart, "play.fill", color: .green,
                                        disabled: state.running) { stats.localDBs.start(state.id) }
                    localDBActionButton(Strings.dbActionStop, "stop.fill", color: .red,
                                        disabled: !state.running) { stats.localDBs.stop(state.id) }
                }
                localDBActionButton(Strings.dbDbsAction,
                                    state.databasesExpanded ? "chevron.up" : "chevron.down",
                                    color: .teal, disabled: false) {
                    stats.localDBs.toggleDatabases(state.id)
                }
            }
            if let err = state.error {
                Text(err)
                    .font(.system(size: 8)).foregroundColor(.orange)
                    .lineLimit(3)
            }
            if state.databasesExpanded {
                databasesList(state)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func databasesList(_ state: LocalDBServiceState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.databasesLoading {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("…").font(.caption2).foregroundColor(.secondary)
                }
            } else if state.databases.isEmpty {
                Text(Strings.dbDatabasesEmpty)
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                ForEach(state.databases, id: \.self) { name in
                    HStack(spacing: 5) {
                        Image(systemName: "cylinder").font(.system(size: 7)).foregroundColor(.teal)
                        Text(name)
                            .font(.system(size: 9, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }
            if state.databasesSource == .disk {
                Text(Strings.dbFromDisk).font(.system(size: 7)).foregroundColor(.secondary)
            }
        }
        .padding(.leading, 22)
        .padding(.top, 2)
    }

    private func dbStatusText(_ state: LocalDBServiceState) -> String {
        state.running ? Strings.dbStatusRunning : Strings.dbStatusStopped
    }

    private func dbStatusColor(_ state: LocalDBServiceState) -> Color {
        state.running ? .green : .red
    }

    private func dbMonogram(_ id: LocalDBID) -> some View {
        let brand = dbBrand(id)
        return Text(dbShortName(id))
            .font(.system(size: 7, weight: .bold))
            .foregroundColor(brand.0)
            .frame(width: 17, height: 17)
            .background(brand.1)
            .clipShape(Circle())
    }

    private func dbBrand(_ id: LocalDBID) -> (Color, Color) {
        switch id {
        case .mongodb: return (.white, Color(red: 0.32, green: 0.55, blue: 0.18))
        case .mysql: return (.white, Color(red: 0.10, green: 0.52, blue: 0.75))
        case .neo4j: return (.white, Color(red: 0.45, green: 0.30, blue: 0.72))
        }
    }

    private func dbShortName(_ id: LocalDBID) -> String {
        switch id {
        case .mongodb: return "Mo"
        case .mysql: return "My"
        case .neo4j: return "N4"
        }
    }

    private func localDBActionButton(_ title: String, _ icon: String, color: Color,
                                     disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 7))
                Text(title).font(.system(size: 8, weight: .medium))
            }
            .foregroundColor(disabled ? Color.secondary : color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(disabled ? Color.gray.opacity(0.12) : color.opacity(0.15))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            iconButton(icon: "arrow.clockwise", label: Strings.refresh, color: .blue) {
                stats.refresh()
                stats.gitHub.refresh()
                stats.aws.refresh()
                stats.cloudflare.refresh()
                stats.netlify.refresh()
                stats.localDBs.refresh()
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
                stats.cloudflare.refresh()
                stats.netlify.refresh()
                stats.localDBs.refresh()
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

    // MARK: - 通知中心（popover 横幅 + 「通知」页）

    private static let alertTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var alertBannerOverlay: some View {
        Group {
            if let a = currentBanner {
                HStack(spacing: 6) {
                    Image(systemName: alertIcon(a.kind))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(alertColor(a.kind))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        Text(a.body)
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button(action: dismissBanner) {
                        Image(systemName: "xmark").font(.system(size: 8)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func showBanner(_ alert: AppAlert) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { currentBanner = alert }
        bannerDismissTask?.cancel()
        bannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { currentBanner = nil }
        }
    }

    private func dismissBanner() {
        bannerDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { currentBanner = nil }
    }

    private var alertsTabButton: some View {
        let active = selectedTab == 5
        let unread = recentAlerts.filter { $0.isUnread }.count
        return Button(action: {
            selectedTab = 5
            AppAlertCenter.markAllRead()
            recentAlerts = AppAlertCenter.recent
        }) {
            Image(systemName: "bell.fill")
                .font(.system(size: 13))
                .foregroundColor(active ? .white : .secondary)
                .frame(width: 30, height: 24)
                .background(active ? Color.blue : Color.clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .modifier(HoverTooltip(text: Strings.alertsTabTooltip, position: .below))
    }

    private var alertsTabContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 10)).foregroundColor(.orange)
                Text(Strings.alertsTabTitle).font(.system(size: 10, weight: .semibold))
                Spacer()
                if !recentAlerts.isEmpty {
                    Button {
                        AppAlertCenter.removeAll()
                        recentAlerts = AppAlertCenter.recent
                    } label: {
                        Label(Strings.alertsClearAll, systemImage: "trash")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if recentAlerts.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bell.slash").font(.system(size: 16)).foregroundColor(.secondary)
                    Text(Strings.alertsEmpty).font(.system(size: 9)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(recentAlerts) { alert in
                        alertRow(alert)
                        if alert.id != recentAlerts.last?.id {
                            Divider().padding(.leading, 8)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func alertRow(_ alert: AppAlert) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: alertIcon(alert.kind))
                .font(.system(size: 9))
                .foregroundColor(alertColor(alert.kind))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(alert.title).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                    if alert.isUnread {
                        Circle().fill(Color.blue).frame(width: 5, height: 5)
                    }
                }
                Text(alert.body)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.alertTimeFormatter.string(from: alert.date))
                    .font(.system(size: 7).monospacedDigit())
                    .foregroundColor(.secondary)
                Button {
                    AppAlertCenter.remove(alert.id)
                    recentAlerts = AppAlertCenter.recent
                } label: {
                    Image(systemName: "xmark").font(.system(size: 7)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func alertIcon(_ kind: AppAlertKind) -> String {
        switch kind {
        case .peakStart: return "sun.max.fill"
        case .peakEnd: return "moon.zzz.fill"
        case .peakSoon: return "sun.max.trianglebadge.exclamationmark"
        case .tunnelDown: return "cloud.bolt.rain.fill"
        case .tunnelRestored: return "checkmark.circle.fill"
        case .dbDown: return "xmark.octagon.fill"
        case .dbRestored: return "checkmark.seal.fill"
        case .netlifyDeployReady: return "checkmark.circle.fill"
        case .netlifyDeployFailed: return "exclamationmark.triangle.fill"
        case .netlifyDeployRolledBack: return "arrow.uturn.backward.circle.fill"
        case .lowBalance: return "exclamationmark.circle.fill"
        case .balanceWarning: return "exclamationmark.triangle.fill"
        }
    }

    private func alertColor(_ kind: AppAlertKind) -> Color {
        switch kind {
        case .peakStart, .peakSoon, .balanceWarning: return .orange
        case .peakEnd, .tunnelRestored, .netlifyDeployReady, .netlifyDeployRolledBack, .dbRestored: return .green
        case .tunnelDown, .lowBalance, .netlifyDeployFailed, .dbDown: return .red
        }
    }

    // MARK: - Cloudflare 复制

    private func copyCFValue(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        cfCopiedValue = value
        cfCopyResetTask?.cancel()
        cfCopyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            cfCopiedValue = nil
        }
    }

    private func cfCopyButton(_ value: String) -> some View {
        let copied = cfCopiedValue == value
        return Button(action: { copyCFValue(value) }) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9))
                .foregroundColor(copied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .modifier(HoverTooltip(text: copied ? Strings.cloudflareCopied : Strings.cloudflareCopyAction,
                               position: .below))
        .disabled(stats.cloudflare.isWorking)
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
