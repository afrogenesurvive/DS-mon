import SwiftUI
import AppKit
import Security

struct ServicesSettingsView: View {
    let stats: DeepSeekStats

    @State private var proxyEnabled: Bool = UserDefaults.standard.bool(forKey: Strings.Keys.proxyEnabled)
    @State private var proxyPort: Int = {
        let p = UserDefaults.standard.integer(forKey: Strings.Keys.proxyPort)
        return p >= 1024 ? p : 18080
    }()
    @State private var proxyRunning: Bool = ProxyServer.shared.isRunning
    @State private var proxyError: String? = ProxyServer.shared.listenerError

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            proxySection
            Divider().padding(.horizontal, 16)
            GitHubSettingsView(stats: stats)
            Divider().padding(.horizontal, 16)
            AWSSettingsView(stats: stats)
            Divider().padding(.horizontal, 16)
            SyncSettingsView(stats: stats)
            Spacer()
        }
    }

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
                    Text(Strings.proxyToggle).font(.callout)
                }
                .toggleStyle(.switch)
                .onChange(of: proxyEnabled) { _, newVal in
                    UserDefaults.standard.set(newVal, forKey: Strings.Keys.proxyEnabled)
                    if newVal { try? ProxyServer.shared.start(port: UInt16(proxyPort)) }
                    else { ProxyServer.shared.stop() }
                    proxyRunning = ProxyServer.shared.isRunning
                }
                Spacer()

                HStack(spacing: 4) {
                    Text(Strings.proxyPortLabel).font(.caption).foregroundColor(.secondary)
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

            Text(Strings.proxyToggleHint).font(.caption).foregroundColor(.secondary)

            if let err = proxyError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundColor(.red)
                    Text(err).font(.caption).foregroundColor(.red)
                }
            }
        }
        .padding(20)
        .onAppear { proxyError = ProxyServer.shared.listenerError }
    }
}

// MARK: - ☁️ Cloud Settings Views

private struct GitHubSettingsView: View {
    let stats: DeepSeekStats

    @State private var githubEnabled: Bool = UserDefaults.standard.bool(forKey: Strings.Keys.githubEnabled)
    @State private var githubToken: String = SecureStore.retrieve(key: Strings.Keys.githubToken) ?? ""
    @State private var showGithubToken: Bool = false
    @State private var githubUsername: String = UserDefaults.standard.string(forKey: Strings.Keys.githubUsername) ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "logo.github")
                    .foregroundColor(.black)
                Text(Strings.githubSection)
                    .font(.body).bold()
                Spacer()
            }

            Toggle(isOn: $githubEnabled) {
                Text(Strings.githubToggle).font(.callout)
            }
            .toggleStyle(.switch)
            .onChange(of: githubEnabled) { _, newVal in
                UserDefaults.standard.set(newVal, forKey: Strings.Keys.githubEnabled)
                if newVal { stats.gitHub.startAutoRefresh(); stats.gitHub.refresh() }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(Strings.githubTokenLabel).font(.caption).foregroundColor(.secondary)
                    Group {
                        if showGithubToken {
                            TextField("ghp_...", text: $githubToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        } else {
                            SecureField("ghp_...", text: $githubToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    .onChange(of: githubToken) { _, newVal in
                        SecureStore.save(key: Strings.Keys.githubToken, value: newVal)
                        if githubEnabled { stats.gitHub.refresh() }
                    }
                    Button {
                        showGithubToken.toggle()
                    } label: {
                        Image(systemName: showGithubToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.bordered)
                    .help(Strings.githubTokenRevealHint)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(githubToken, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .disabled(githubToken.isEmpty)
                    .help(Strings.githubTokenCopyHint)
                }
                Text(Strings.githubTokenHint).font(.caption2).foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(Strings.githubUserLabel).font(.caption).foregroundColor(.secondary)
                TextField("username", text: $githubUsername)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: githubUsername) { _, newVal in
                        UserDefaults.standard.set(newVal, forKey: Strings.Keys.githubUsername)
                        if githubEnabled { stats.gitHub.refresh() }
                    }
            }
        }
        .padding(20)
    }
}

private struct AWSSettingsView: View {
    let stats: DeepSeekStats

    @State private var awsEnabled: Bool = UserDefaults.standard.bool(forKey: Strings.Keys.awsEnabled)
    @State private var awsAccessKey: String = SecureStore.retrieve(key: Strings.Keys.awsAccessKey) ?? ""
    @State private var awsSecretKey: String = SecureStore.retrieve(key: Strings.Keys.awsSecretKey) ?? ""
    @State private var showAwsSecret: Bool = false
    @State private var awsRegion: String = UserDefaults.standard.string(forKey: Strings.Keys.awsRegion) ?? "us-east-1"
    @State private var awsMaxCredits: String = {
        let v = UserDefaults.standard.double(forKey: Strings.Keys.awsMaxCredits)
        return v > 0 ? String(format: "%.2f", v) : ""
    }()

    private let regions = ["us-east-1", "us-east-2", "us-west-1", "us-west-2",
                           "eu-west-1", "eu-central-1", "ap-northeast-1", "ap-southeast-1"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "cloud.fill")
                    .foregroundColor(.orange)
                Text(Strings.awsSection)
                    .font(.body).bold()
                Spacer()
            }

            Toggle(isOn: $awsEnabled) {
                Text(Strings.awsToggle).font(.callout)
            }
            .toggleStyle(.switch)
            .onChange(of: awsEnabled) { _, newVal in
                UserDefaults.standard.set(newVal, forKey: Strings.Keys.awsEnabled)
                if newVal { stats.aws.startAutoRefresh(); stats.aws.refresh() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(Strings.awsAccessKeyLabel).font(.caption).foregroundColor(.secondary)
                TextField("AKIA...", text: $awsAccessKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: awsAccessKey) { _, newVal in
                        SecureStore.save(key: Strings.Keys.awsAccessKey, value: newVal)
                        if awsEnabled { stats.aws.refresh() }
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(Strings.awsSecretKeyLabel).font(.caption).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Group {
                        if showAwsSecret {
                            TextField("...", text: $awsSecretKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        } else {
                            SecureField("...", text: $awsSecretKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    .onChange(of: awsSecretKey) { _, newVal in
                        SecureStore.save(key: Strings.Keys.awsSecretKey, value: newVal)
                        if awsEnabled { stats.aws.refresh() }
                    }
                    Button {
                        showAwsSecret.toggle()
                    } label: {
                        Image(systemName: showAwsSecret ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.bordered)
                    .help(Strings.revealHint)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(Strings.awsRegionLabel).font(.caption).foregroundColor(.secondary)
                Picker("", selection: $awsRegion) {
                    ForEach(regions, id: \.self) { region in
                        Text(region).tag(region)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: awsRegion) { _, newVal in
                    UserDefaults.standard.set(newVal, forKey: Strings.Keys.awsRegion)
                    if awsEnabled { stats.aws.refresh() }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(Strings.awsMaxCreditsLabel).font(.caption).foregroundColor(.secondary)
                TextField("0.00", text: $awsMaxCredits)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: awsMaxCredits) { _, newVal in
                        let value = Double(newVal.replacingOccurrences(of: ",", with: "")) ?? 0
                        stats.aws.maxCredits = value
                        if awsEnabled { stats.aws.refresh() }
                    }
                Text(Strings.awsMaxCreditsHint).font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(20)
    }
}

private struct SyncSettingsView: View {
    let stats: DeepSeekStats

    @State private var syncEnabled: Bool = SyncManager.shared.config.enabled
    @State private var syncMode: SyncConfig.SyncMode = SyncManager.shared.config.mode
    @State private var syncListenPort: UInt16 = SyncManager.shared.config.listenPort
    @State private var syncTargetAddress: String = SyncManager.shared.config.targetAddress
    @State private var syncInterval: Double = SyncManager.shared.config.syncInterval
    @State private var syncPushToken: String = SecureStore.retrieve(key: Strings.Keys.syncPushToken) ?? ""
    @State private var showPushToken: Bool = false
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
        if syncEnabled { SyncManager.shared.start() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(.teal)
                Text(Strings.syncSection).font(.body).bold()
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(syncStatusColor).frame(width: 6, height: 6)
                    Text(syncStatusText).font(.caption).foregroundColor(syncStatusColor)
                }
            }

            HStack {
                Toggle(isOn: $syncEnabled) { Text(Strings.syncToggle).font(.callout) }
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
                        Image(systemName: syncMode == .server ? "circle.fill" : "circle").font(.caption)
                        Text(Strings.syncModeServer).font(.callout)
                    }
                    .foregroundColor(syncMode == .server ? .accentColor : .secondary)
                }
                .buttonStyle(.plain).disabled(syncEnabled)

                Button(action: { switchMode(to: .client) }) {
                    HStack(spacing: 4) {
                        Image(systemName: syncMode == .client ? "circle.fill" : "circle").font(.caption)
                        Text(Strings.syncModeClient).font(.callout)
                    }
                    .foregroundColor(syncMode == .client ? .accentColor : .secondary)
                }
                .buttonStyle(.plain).disabled(syncEnabled)
            }

            if syncMode == .server {
                HStack(spacing: 8) {
                    Text(Strings.syncListenPortLabel).font(.caption).foregroundColor(.secondary)
                    TextField("18888", value: $syncListenPort, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
                        .disabled(syncEnabled).onSubmit { saveSyncConfig() }
                }
                Text(Strings.syncPortHint).font(.caption).foregroundColor(.secondary)
            }

            if syncMode == .client {
                HStack(spacing: 8) {
                    Text(Strings.syncTargetLabel).font(.caption).foregroundColor(.secondary)
                    TextField("1.2.3.4:6000", text: $syncTargetAddress)
                        .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                        .disabled(syncEnabled).onSubmit { saveSyncConfig() }
                }
                Text(Strings.syncAddressHint).font(.caption).foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Text(Strings.syncPushTokenLabel).font(.caption).foregroundColor(.secondary)
                Group {
                    if showPushToken {
                        TextField("", text: $syncPushToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    } else {
                        SecureField("", text: $syncPushToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .disabled(syncEnabled)
                .onChange(of: syncPushToken) { _, newVal in
                    SecureStore.save(key: Strings.Keys.syncPushToken, value: newVal)
                }
                Button {
                    showPushToken.toggle()
                } label: {
                    Image(systemName: showPushToken ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
                .disabled(syncEnabled)
                .help(Strings.syncPushTokenRevealHint)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(syncPushToken, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(syncEnabled || syncPushToken.isEmpty)
                .help(Strings.syncPushTokenCopyHint)
                Button {
                    let generated = generatePushToken()
                    syncPushToken = generated
                    SecureStore.save(key: Strings.Keys.syncPushToken, value: generated)
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .disabled(syncEnabled)
                .help(Strings.syncPushTokenGenerateHint)
            }
            Text(Strings.syncPushTokenHint).font(.caption2).foregroundColor(.secondary)

            HStack(spacing: 8) {
                Text(Strings.syncIntervalLabel).font(.caption).foregroundColor(.secondary)
                TextField("30", value: $syncInterval, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 60).multilineTextAlignment(.trailing)
                    .onSubmit { saveSyncConfig() }
                Stepper("", value: $syncInterval, in: 5...300, step: 5)
                    .labelsHidden()
                    .onChange(of: syncInterval) { _, _ in saveSyncConfig() }
            }

            if syncEnabled && syncMode == .client {
                Button(action: { SyncManager.shared.performSyncAndWait() }) {
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
                    Image(systemName: "clock").font(.caption2).foregroundColor(.secondary)
                    Text("最后同步: ") + Text(t, style: .time) + Text(" ") + Text(t, style: .date)
                }
                .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(20)
        .onReceive(SyncManager.shared.$observableStatus) { status in syncConnectionStatus = status }
        .onReceive(SyncManager.shared.$syncCount) { _ in
            lastSyncTime = SyncManager.shared.lastSyncTime
            stats.refresh()
        }
    }
}

// MARK: - 工具

/// 生成 256-bit 随机推送令牌（64 个十六进制字符，对应 `openssl rand -hex 32`）
private func generatePushToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return "" }
    return bytes.map { String(format: "%02x", $0) }.joined()
}
