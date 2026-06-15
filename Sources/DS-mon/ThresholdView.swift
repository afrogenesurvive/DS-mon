import SwiftUI

// MARK: - 设置主视图（标签页布局）

struct ThresholdView: View {
    let stats: DeepSeekStats

    @State private var selectedTab: SettingsTab = .general

    // 通用
    @AppStorage(Strings.Keys.showMenuIcon) private var showMenuIcon: Bool = true
    @AppStorage(Strings.Keys.showIndicator) private var showIndicator: Bool = true
    @AppStorage(Strings.Keys.menuBarTextDisplay) private var menuBarTextDisplay: String = "balance"
    @AppStorage(Strings.Keys.appLanguage) private var appLanguage: String = "auto"

    // 提供商
    @State private var thresholdValue: Double = 20
    @State private var maxBalanceValue: Double = AppConfig.defaultMaxBalanceAmount
    @State private var apiKeyInput = ""
    @State private var saved = false
    @State private var saveFailed = false
    @State private var pricingOverrides: [String: ModelPricing] = [:]
    @State private var pricingResetMsg = false
    @State private var providerConfigs: [ProviderConfig] = ProviderManager.shared.providers
    @State private var selectedProviderId: String = ProviderManager.shared.activeProviderId
    @State private var currentProviderModels: [String] = []

    // 同步
    @State private var syncEnabled: Bool = SyncManager.shared.config.enabled
    @State private var syncMode: SyncConfig.SyncMode = SyncManager.shared.config.mode
    @State private var syncListenPort: UInt16 = SyncManager.shared.config.listenPort
    @State private var syncTargetAddress: String = SyncManager.shared.config.targetAddress
    @State private var syncInterval: Double = SyncManager.shared.config.syncInterval
    
    @State private var syncConnectionStatus: SyncConnectionStatus = SyncManager.shared.observableStatus
    @State private var lastSyncTime: Date? = SyncManager.shared.lastSyncTime
    
    private var syncStatusColor: Color {
        switch syncConnectionStatus {
        case .listening: return .green
        case .connected: return .green
        case .connecting: return .orange
        case .error: return .red
        case .idle: return .secondary
        }
    }
    
    private var syncStatusText: String {
        switch syncConnectionStatus {
        case .listening(let port): return "\(Strings.syncStatusListening) :\(port)"
        case .connected: return Strings.syncStatusConnected
        case .connecting: return Strings.syncStatusConnected + "..."
        case .error(let err): return "\(Strings.syncStatusError): \(err)"
        case .idle: return Strings.syncStatusDisconnected
        }
    }
    
    private func switchMode(to mode: SyncConfig.SyncMode) {
        syncMode = mode
        saveSyncConfig()
    }
    
    private func saveSyncConfig() {
        var c = SyncManager.shared.config
        c.mode = syncMode
        c.listenPort = syncListenPort
        c.targetAddress = syncTargetAddress
        c.syncInterval = syncInterval
        SyncManager.shared.config = c
        if syncEnabled {
            SyncManager.shared.start()
        }
    }

    // 服务
    @State private var proxyEnabled: Bool = UserDefaults.standard.bool(forKey: Strings.Keys.proxyEnabled)
    @State private var proxyPort: Int = {
        let p = UserDefaults.standard.integer(forKey: Strings.Keys.proxyPort)
        return p >= 1024 ? p : 18080
    }()
    @State private var proxyRunning: Bool = ProxyServer.shared.isRunning
    @State private var proxyError: String? = ProxyServer.shared.listenerError

    enum SettingsTab: String, CaseIterable {
        case general  = "通用"
        case provider = "提供商"
        case services = "服务"
        case about    = "关于"

        var icon: String {
            switch self {
            case .general:  return "switch.2"
            case .provider: return "building.2"
            case .services: return "network"
            case .about:    return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── 标签栏 ──
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        VStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 16))
                            Text(tab.rawValue)
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.12) : Color.clear)
                        .cornerRadius(8)
                        .contentShape(Rectangle())
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedTab == tab ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Divider().padding(.horizontal, 12)

            // ── 内容区 ──
            ScrollView {
                switch selectedTab {
                case .general:  generalView
                case .provider: providerView
                case .services: servicesView
                case .about:    aboutView
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 520, height: 480)
        .onAppear {
            thresholdValue = stats.threshold
            maxBalanceValue = UserDefaults.standard.double(forKey: Strings.Keys.maxBalanceAmount)
            if maxBalanceValue <= 0 { maxBalanceValue = AppConfig.defaultMaxBalanceAmount }
            providerConfigs = ProviderManager.shared.providers
            selectedProviderId = ProviderManager.shared.activeProviderId
            proxyError = ProxyServer.shared.listenerError
        }
    }

    // MARK: - 通用

    private var generalView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(Strings.menuBarDisplay, systemImage: "menubar.rectangle")
                .font(.body).bold()
                .padding(.top, 20)

            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $showMenuIcon) {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill").font(.caption)
                        Text(Strings.menuIconLabel)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: showMenuIcon) {
                    NotificationCenter.default.post(name: .showMenuIconDidChange, object: nil)
                }

                Toggle(isOn: $showIndicator) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.fill").font(.caption)
                        Text(Strings.indicatorLabel)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: showIndicator) {
                    NotificationCenter.default.post(name: .showIndicatorDidChange, object: nil)
                }

                HStack(spacing: 8) {
                    Image(systemName: "text.alignleft").font(.caption)
                    Text(Strings.textDisplayLabel)
                    
                    Button(action: {
                        if menuBarTextDisplay == "balance" {
                            menuBarTextDisplay = "none"
                        } else {
                            menuBarTextDisplay = "balance"
                        }
                        NotificationCenter.default.post(name: .menuBarTextDisplayDidChange, object: nil)
                    }) {
                        Text(Strings.balanceLabel)
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(menuBarTextDisplay == "balance" ? Color.accentColor : Color.gray.opacity(0.12))
                            .foregroundColor(menuBarTextDisplay == "balance" ? .white : .primary)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        if menuBarTextDisplay == "hitRate" {
                            menuBarTextDisplay = "none"
                        } else {
                            menuBarTextDisplay = "hitRate"
                        }
                        NotificationCenter.default.post(name: .menuBarTextDisplayDidChange, object: nil)
                    }) {
                        Text(Strings.hitRateLabel)
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(menuBarTextDisplay == "hitRate" ? Color.accentColor : Color.gray.opacity(0.12))
                            .foregroundColor(menuBarTextDisplay == "hitRate" ? .white : .primary)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            }

            Divider()

            Label(Strings.languageLabel, systemImage: "globe")
                .font(.body).bold()

            Picker(Strings.languageLabel, selection: $appLanguage) {
                ForEach(Language.allCases) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: appLanguage) {
                Strings.notifyLanguageChanged()
            }

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // MARK: - 提供商

    private var providerView: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧：提供商列表
            providerListView
                .frame(width: 140)

            Divider()

            // 右侧：选中提供商设置
            providerSettingsView
                .frame(maxWidth: .infinity)
        .onAppear {
            stats.refresh()
        }
        .task(id: selectedProviderId) {
            guard let provider = providerConfigs.first(where: { $0.id == selectedProviderId }),
                  provider.pricingOverrides.isEmpty else { return }
            let apiKey = ProviderManager.shared.apiKey(for: provider)
            guard !apiKey.isEmpty else { return }
            let urlStr = provider.baseURL + provider.apiPath + "/models"
            guard let url = URL(string: urlStr) else { return }
            var req = URLRequest(url: url)
            req.setValue("\(provider.authHeaderPrefix) \(apiKey)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 5
            do {
                let config = URLSessionConfiguration.default
                config.connectionProxyDictionary = [:]
                let (data, _) = try await URLSession(configuration: config).data(for: req)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                if let list = json["data"] as? [[String: Any]] {
                    currentProviderModels = list.compactMap { $0["id"] as? String }.sorted()
                } else if let list = json["models"] as? [[String: Any]] {
                    currentProviderModels = list.compactMap { $0["id"] as? String }.sorted()
                }
            } catch {
                currentProviderModels = []
            }
        }
        }
    }

    private var providerListView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.providerList)
                .font(.caption).fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.top, 20)
                .padding(.horizontal, 12)

            List(providerConfigs.filter { $0.isEnabled }, id: \.id, selection: $selectedProviderId) { provider in
                HStack(spacing: 6) {
                    Image(systemName: "cube.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                    Text(provider.name).font(.callout)
                    Spacer()
                    if provider.id == ProviderManager.shared.activeProviderId {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedProviderId = provider.id
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 120)

            Spacer()
        }
    }

    private var providerSettingsView: some View {
        guard let provider = providerConfigs.first(where: { $0.id == selectedProviderId }) else {
            return AnyView(
                VStack {
                    Spacer()
                    Text(Strings.selectProviderHint)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            )
        }
        return AnyView(providerSettingsContent(provider: provider))
    }

    @ViewBuilder
    private func providerSettingsContent(provider: ProviderConfig) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 标题 + 设为活跃按钮
                HStack(spacing: 6) {
                    Image(systemName: "cube.fill")
                        .foregroundColor(.accentColor)
                    Text(provider.name)
                        .font(.title3).bold()
                    Spacer()
                    if provider.id == ProviderManager.shared.activeProviderId {
                        Text(Strings.activeProviderBadge)
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green)
                            .cornerRadius(6)
                    } else {
                        Button(Strings.setActiveProvider) {
                            ProviderManager.shared.setActive(id: provider.id)
                            selectedProviderId = provider.id
                            // 重新载入平衡数据
                            stats.refresh()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 20)

                // API Key
                providerApiKeySection(provider: provider)
                Divider()

                // 默认模型
                defaultModelSection(provider: provider)
                Divider()

                // 模型覆写
                modelOverrideSection(provider: provider)
                Divider()

                // 开发平台
                developerPlatformSection(provider: provider)
                Divider()

                // 余额预警 / 免费开关（当提供商无余额 API 时显示免费开关）
                if provider.hasBalanceAPI {
                    thresholdSection
                } else {
                    freeToggleSection(provider: provider)
                    Divider()
                }

                // 模型定价
                providerPricingSection(provider: provider)
                Divider()

                // 删除提供商（内置提供商不可删除）
                if !ProviderConfig.builtIns.contains(where: { $0.id == provider.id }) {
                    Button(role: .destructive) {
                        deleteProvider(provider)
                    } label: {
                        Label(Strings.removeProvider, systemImage: "trash")
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
        }
    }
    // MARK: - 服务

    private var servicesView: some View {
        VStack(alignment: .leading, spacing: 0) {
            proxySection
            Divider().padding(.horizontal, 16)
            Divider().padding(.horizontal, 16)
            syncSection
            Spacer()
        }
    }

    // MARK: - 关于

    private var aboutView: some View {
        VStack(spacing: 24) {
            Spacer()

            // 图标
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable().frame(width: 64, height: 64)

            Text("DS-mon")
                .font(.title).bold()

            // 版本
            if let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(ver)")
                    .font(.body)
                    .foregroundColor(.secondary)
            }

            // 构建时间
            if let ts = Bundle.main.infoDictionary?["DSMonBuildTimestamp"] as? String {
                Text(ts)
                    .font(.caption2)
                    .foregroundColor(.secondary).opacity(0.6)
            }

            Divider()
                .frame(width: 200)

            VStack(spacing: 8) {
                Label(Strings.aboutDesc, systemImage: "eye")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Link(destination: URL(string: "https://github.com/cherno/DS-mon")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                            Text("GitHub")
                        }
                        .font(.caption)
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 余额预警

    private var thresholdSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge.fill")
                    .foregroundColor(.orange)
                Text(Strings.balanceAlert)
                    .font(.body).bold()
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("¥")
                        .foregroundColor(.secondary)
                    TextField("", value: $thresholdValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { stats.threshold = thresholdValue }
                    Stepper("", value: $thresholdValue, in: 1...500, step: 5)
                        .labelsHidden()
                        .onChange(of: thresholdValue) { _, newVal in
                            stats.threshold = newVal
                        }
                }

                Text(Strings.alertHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("¥")
                            .foregroundColor(.secondary)
                        TextField("", value: $maxBalanceValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(saveMaxBalance)
                        Stepper("", value: $maxBalanceValue, in: 10...10000, step: 10)
                            .labelsHidden()
                            .onChange(of: maxBalanceValue) { _, _ in saveMaxBalance() }
                    }
                    Text(Strings.maxBalanceHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - API Key (per provider)

    private func providerApiKeySection(provider: ProviderConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "key.fill")
                    .foregroundColor(.accentColor)
                Text("API Key")
                    .font(.body).bold()
            }

            HStack(spacing: 8) {
                let keyBinding = Binding<String>(
                    get: { ProviderManager.shared.apiKey(for: provider) },
                    set: { newValue in
                        _ = ProviderManager.shared.saveAPIKey(newValue, for: provider)
                        if provider.id == ProviderManager.shared.activeProviderId {
                            stats.refresh()
                        }
                    }
                )

                SecureField("sk-...", text: keyBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            Text(Strings.apiKeyHint(provider.name))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 模型定价 (per provider)

    private func providerPricingSection(provider: ProviderConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundColor(.orange)
                Text(Strings.pricingSection)
                    .font(.body).bold()
            }

            Text(Strings.pricingNote)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 显示该提供商的定价
            let providerPricing = provider.pricingOverrides
            if providerPricing.isEmpty {
                Text(Strings.pricingDefault)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(Array(providerPricing.keys.sorted()), id: \.self) { key in
                if let pricing = providerPricing[key] {
                    HStack {
                        Text(key)
                            .font(.caption)
                            .frame(width: 100, alignment: .leading)
                        Text(String(format: "H:¥%.3f", pricing.hitPrice))
                            .font(.caption)
                            .foregroundColor(.green)
                        Text(String(format: "M:¥%.3f", pricing.missPrice))
                            .font(.caption)
                            .foregroundColor(.orange)
                        Text(String(format: "O:¥%.3f", pricing.outPrice))
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
            }
        }
    }

    // MARK: - API Key

    // MARK: - 模型定价

    private var pricingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                    .foregroundColor(.purple)
                Text(Strings.pricingSection)
                    .font(.body).bold()
                Spacer()
                if pricingResetMsg {
                    Text(Strings.pricingResetDone)
                        .font(.caption)
                        .foregroundColor(.green)
                        .transition(.opacity)
                }
                Button(Strings.pricingReset) {
                    ModelPricing.resetCustom()
                    loadPricing()
                    withAnimation {
                        pricingResetMsg = true
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.orange)
                .task(id: pricingResetMsg) {
                    guard pricingResetMsg else { return }
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { pricingResetMsg = false }
                }
            }

            Text(Strings.pricingNote)
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(ModelPricing.displayedModels, id: \.self) { key in
                if let defaults = ModelPricing.default[key] {
                    let binding = Binding<ModelPricing>(
                        get: { pricingOverrides[key] ?? defaults },
                        set: { pricingOverrides[key] = $0; savePricing() }
                    )
                    pricingRow(modelKey: key, defaults: defaults, pricing: binding)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func pricingRow(modelKey: String, defaults: ModelPricing,
                            pricing: Binding<ModelPricing>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(pricing.wrappedValue.label)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if pricing.wrappedValue != defaults {
                    Text("⚡")
                        .font(.caption)
                }
            }

            HStack(spacing: 8) {
                priceField(label: Strings.pricingHit,
                           value: Binding(
                            get: { pricing.wrappedValue.hitPrice },
                            set: { pricing.wrappedValue.hitPrice = $0; savePricing() }
                           ))
                priceField(label: Strings.pricingMiss,
                           value: Binding(
                            get: { pricing.wrappedValue.missPrice },
                            set: { pricing.wrappedValue.missPrice = $0; savePricing() }
                           ))
                priceField(label: Strings.pricingOut,
                           value: Binding(
                            get: { pricing.wrappedValue.outPrice },
                            set: { pricing.wrappedValue.outPrice = $0; savePricing() }
                           ))
            }
        }
        .padding(.vertical, 4)
    }

    private func priceField(label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
            HStack(spacing: 2) {
                Text("¥")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("", value: value, format: .number.precision(.fractionLength(2...6)))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10).monospacedDigit())
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: - 本地代理

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .foregroundColor(.blue)
                Text(Strings.proxySection)
                    .font(.body).bold()
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(proxyRunning ? Color.green : Color.red).frame(width: 6, height: 6)
                    Text(proxyRunning ? Strings.proxyRunning : Strings.proxyStopped)
                        .font(.caption)
                        .foregroundColor(proxyRunning ? .green : .red)
                }
            }

            HStack {
                Toggle(isOn: $proxyEnabled) {
                    Text(Strings.proxyToggle)
                        .font(.callout)
                }
                .toggleStyle(.switch)
                .onChange(of: proxyEnabled) { _, newVal in
                    UserDefaults.standard.set(newVal, forKey: Strings.Keys.proxyEnabled)
                    if newVal {
                        try? ProxyServer.shared.start(port: UInt16(proxyPort))
                    } else {
                        ProxyServer.shared.stop()
                    }
                    proxyRunning = ProxyServer.shared.isRunning
                }

                Spacer()

                HStack(spacing: 4) {
                    Text(Strings.proxyPortLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("", value: $proxyPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            let p = max(AppConfig.minProxyPort, min(proxyPort, AppConfig.maxProxyPort))
                            proxyPort = p
                            UserDefaults.standard.set(p, forKey: Strings.Keys.proxyPort)
                            if proxyRunning { ProxyServer.shared.stop(); try? ProxyServer.shared.start(port: UInt16(p)) }
                        }
                }
            }

            Text(Strings.proxyToggleHint)
                .font(.caption)
                .foregroundColor(.secondary)

            if let err = proxyError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .padding(20)
    }

    // MARK: - 同步

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.teal)
                Text(Strings.syncSection)
                    .font(.body).bold()
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(syncStatusColor).frame(width: 6, height: 6)
                    Text(syncStatusText)
                        .font(.caption)
                        .foregroundColor(syncStatusColor)
                }
            }

            // 启用开关
            HStack {
                Toggle(isOn: $syncEnabled) {
                    Text(Strings.syncToggle)
                        .font(.callout)
                }
                .toggleStyle(.switch)
                .onChange(of: syncEnabled) { _, newVal in
                    var c = SyncManager.shared.config
                    c.enabled = newVal
                    SyncManager.shared.config = c
                    if newVal { SyncManager.shared.start() }
                    else { SyncManager.shared.stop() }
                }
                Spacer()
            }

            // 模式选择（禁用同步后可用）
            HStack(spacing: 16) {
                Button(action: { switchMode(to: .server) }) {
                    HStack(spacing: 4) {
                        Image(systemName: syncMode == .server ? "circle.fill" : "circle")
                            .font(.caption)
                        Text(Strings.syncModeServer)
                            .font(.callout)
                    }
                    .foregroundColor(syncMode == .server ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(syncEnabled)

                Button(action: { switchMode(to: .client) }) {
                    HStack(spacing: 4) {
                        Image(systemName: syncMode == .client ? "circle.fill" : "circle")
                            .font(.caption)
                        Text(Strings.syncModeClient)
                            .font(.callout)
                    }
                    .foregroundColor(syncMode == .client ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(syncEnabled)
            }

            // 服务器模式：端口
            if syncMode == .server {
                HStack(spacing: 8) {
                    Text(Strings.syncListenPortLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("18888", value: $syncListenPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .disabled(syncEnabled)
                        .onSubmit { saveSyncConfig() }
                }
                Text(Strings.syncPortHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 客户端模式：服务器地址
            if syncMode == .client {
                HStack(spacing: 8) {
                    Text(Strings.syncTargetLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("1.2.3.4:6000", text: $syncTargetAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .disabled(syncEnabled)
                        .onSubmit { saveSyncConfig() }
                }
                Text(Strings.syncAddressHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 同步间隔
            HStack(spacing: 8) {
                Text(Strings.syncIntervalLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("30", value: $syncInterval, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { saveSyncConfig() }
                Stepper("", value: $syncInterval, in: 5...300, step: 5)
                    .labelsHidden()
                    .onChange(of: syncInterval) { _, _ in saveSyncConfig() }
            }

            // 手动触发同步
            if syncEnabled && syncMode == .client {
                Button(action: {
                    SyncManager.shared.performSyncAndWait()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("立即同步")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            // 最后同步时间
            if let t = lastSyncTime {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("最后同步: ") + Text(t, style: .time) + Text(" ") + Text(t, style: .date)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .onReceive(SyncManager.shared.$observableStatus) { status in
            syncConnectionStatus = status
        }
        .onReceive(SyncManager.shared.$syncCount) { _ in
            lastSyncTime = SyncManager.shared.lastSyncTime
            stats.refresh()
        }
    }

    // MARK: - 默认模型

    private func defaultModelSection(provider: ProviderConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                Text(Strings.defaultModelSection)
                    .font(.body).bold()
            }

            Text(Strings.defaultModelHint)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text(Strings.defaultModelLabel)
                    .font(.callout)
                    .frame(width: 90, alignment: .leading)

                let models = provider.pricingOverrides.isEmpty ? currentProviderModels : provider.pricingOverrides.keys.sorted()
                let currentDefault = providerConfigs.first(where: { $0.id == provider.id })?.defaultModel ?? models.first ?? ""

                Picker(selection: Binding(
                    get: { currentDefault },
                    set: { newVal in
                        var configs = providerConfigs
                        if let idx = configs.firstIndex(where: { $0.id == provider.id }) {
                            configs[idx].defaultModel = newVal.isEmpty ? nil : newVal
                            providerConfigs = configs
                            ProviderConfig.saveAll(configs)
                            ProviderManager.shared.load()
                        }
                    }
                ), label: EmptyView()) {
                    ForEach(models, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 模型覆写

    private func modelOverrideSection(provider: ProviderConfig) -> some View {
        let overrideId = Binding<String?>(
            get: { providerConfigs.first(where: { $0.id == provider.id })?.modelOverrideProviderId },
            set: { newVal in
                if let idx = providerConfigs.firstIndex(where: { $0.id == provider.id }) {
                    providerConfigs[idx].modelOverrideProviderId = newVal
                    ProviderConfig.saveAll(providerConfigs)
                    ProviderManager.shared.load()
                }
            }
        )

        let availableProviders = providerConfigs.filter { $0.id != provider.id && $0.isEnabled }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.swap")
                    .foregroundColor(.purple)
                Text(Strings.modelOverrideSection)
                    .font(.body).bold()
            }

            Text(Strings.modelOverrideHint)
                .font(.caption)
                .foregroundColor(.secondary)

            if availableProviders.isEmpty {
                Text(Strings.modelOverrideNoProvider)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { overrideId.wrappedValue ?? "" },
                    set: { newVal in
                        overrideId.wrappedValue = newVal.isEmpty ? nil : newVal
                    }
                )) {
                    Text(Strings.modelOverrideNone).tag("")
                    ForEach(availableProviders) { p in
                        let model = p.defaultModel ?? p.pricingOverrides.keys.sorted().first ?? "?"
                        Text("\(p.name) (\(model))").tag(p.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 240)
            }
        }
    }

    // MARK: - 开发平台

    private func developerPlatformSection(provider: ProviderConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "link.circle.fill")
                    .foregroundColor(.blue)
                Text(Strings.developerPlatformSection)
                    .font(.body).bold()
            }

            Text(Strings.developerPlatformHint)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                TextField("https://...", text: Binding(
                    get: { providerConfigs.first(where: { $0.id == provider.id })?.developerPlatformURL ?? "" },
                    set: { newVal in
                        if let idx = providerConfigs.firstIndex(where: { $0.id == provider.id }) {
                            providerConfigs[idx].developerPlatformURL = newVal
                            ProviderConfig.saveAll(providerConfigs)
                            ProviderManager.shared.load()
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disableAutocorrection(true)
            }
        }
    }

    // MARK: - Helpers

    private func saveKey() {
        guard let provider = ProviderManager.shared.providers.first(where: { $0.id == selectedProviderId }) else { return }
        let ok = ProviderManager.shared.saveAPIKey(apiKeyInput, for: provider)
        if ok {
            saved = true
            saveFailed = false
            stats.refresh()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                saved = false
            }
        } else {
            saveFailed = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                saveFailed = false
            }
        }
    }

    private func loadStoredKey() {
        guard let provider = ProviderManager.shared.providers.first(where: { $0.id == selectedProviderId }) else { return }
        apiKeyInput = ProviderManager.shared.apiKey(for: provider)
    }

    private func loadPricing() {
        pricingOverrides = ModelPricing.loadCustom()
    }

    private func savePricing() {
        ModelPricing.saveCustom(pricingOverrides)
    }

    private func saveMaxBalance() {
        let val = max(10, min(maxBalanceValue, 10000))
        maxBalanceValue = val
        UserDefaults.standard.set(val, forKey: Strings.Keys.maxBalanceAmount)
    }

    // MARK: - Provider Operations

    @MainActor
    private func deleteProvider(_ provider: ProviderConfig) {
        providerConfigs.removeAll { $0.id == provider.id }
        ProviderConfig.saveAll(providerConfigs)
        ProviderManager.shared.load()
        // 如果删除的是当前选中的，切换到活跃提供商
        if selectedProviderId == provider.id {
            selectedProviderId = ProviderManager.shared.activeProviderId
        }
        // 刷新状态
        stats.refresh()
    }


    private func freeToggleSection(provider: ProviderConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "gift.fill")
                        .foregroundColor(.orange)
                    Text("免费模式")
                        .font(.body).bold()
                }
                Spacer()
                Toggle("免费模式", isOn: Binding(
                    get: { provider.tier == .free },
                    set: { isFree in
                        var configs = providerConfigs
                        if let idx = configs.firstIndex(where: { $0.id == provider.id }) {
                            configs[idx].tier = isFree ? .free : .premium
                            providerConfigs = configs
                            ProviderConfig.saveAll(configs)
                            ProviderManager.shared.load()
                            stats.refresh()
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            Text("开启后状态栏不显示余额，第三根柱子保持满格绿色")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}
