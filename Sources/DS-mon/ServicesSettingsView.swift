import SwiftUI

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

private struct SyncSettingsView: View {
    let stats: DeepSeekStats

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
