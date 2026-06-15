import SwiftUI

struct ThresholdView: View {
    let stats: DeepSeekStats

    @State private var selectedTab: SettingsTab = .general

    @AppStorage(Strings.Keys.showMenuIcon) private var showMenuIcon: Bool = true
    @AppStorage(Strings.Keys.showIndicator) private var showIndicator: Bool = true
    @AppStorage(Strings.Keys.menuBarTextDisplay) private var menuBarTextDisplay: String = "balance"
    @AppStorage(Strings.Keys.appLanguage) private var appLanguage: String = "auto"

    @State private var thresholdValue: Double = 20
    @State private var maxBalanceValue: Double = AppConfig.defaultMaxBalanceAmount
    @State private var apiKeyInput = ""
    @State private var saved = false
    @State private var saveFailed = false

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

    @State private var proxyEnabled: Bool = UserDefaults.standard.bool(forKey: Strings.Keys.proxyEnabled)
    @State private var proxyPort: Int = {
        let p = UserDefaults.standard.integer(forKey: Strings.Keys.proxyPort)
        return p >= 1024 ? p : 18080
    }()
    @State private var proxyRunning: Bool = ProxyServer.shared.isRunning
    @State private var proxyError: String? = ProxyServer.shared.listenerError

    enum SettingsTab: String, CaseIterable {
        case general  = "通用"
        case services = "服务"
        case about    = "关于"

        var icon: String {
            switch self {
            case .general:  return "switch.2"
            case .services: return "network"
            case .about:    return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
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

            ScrollView {
                switch selectedTab {
                case .general:  generalView
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
            apiKeyInput = ProviderManager.shared.apiKey(for: ProviderManager.shared.activeProvider!)
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

            Divider()

            // API Key
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "key.fill")
                        .foregroundColor(.accentColor)
                    Text("DeepSeek API Key")
                        .font(.body).bold()
                }

                HStack(spacing: 8) {
                    SecureField("sk-...", text: Binding(
                        get: { ProviderManager.shared.apiKey(for: ProviderManager.shared.activeProvider!) },
                        set: { newValue in
                            _ = ProviderManager.shared.saveAPIKey(newValue, for: ProviderManager.shared.activeProvider!)
                            stats.refresh()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                    if saved {
                        Text(Strings.savedHint)
                            .font(.caption)
                            .foregroundColor(.green)
                    } else if saveFailed {
                        Text(Strings.saveFailedHint)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Text(Strings.apiKeyHint("DeepSeek"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            thresholdSection

            Spacer()
        }
        .padding(.horizontal, 24)
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

            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable().frame(width: 64, height: 64)

            Text("DS-mon")
                .font(.title).bold()

            if let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(ver)")
                    .font(.body)
                    .foregroundColor(.secondary)
            }

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

    private func saveMaxBalance() {
        let val = max(10, min(maxBalanceValue, 10000))
        maxBalanceValue = val
        UserDefaults.standard.set(val, forKey: Strings.Keys.maxBalanceAmount)
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
}
