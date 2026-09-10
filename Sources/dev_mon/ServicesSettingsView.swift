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
            CloudflareSettingsView(stats: stats)
            Divider().padding(.horizontal, 16)
            NetlifySettingsView(stats: stats)
            Divider().padding(.horizontal, 16)
            LocalDBsSettingsView(stats: stats)
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
                BrandTabIcon(assetName: "github", symbol: "chevron.left.forwardslash.chevron.right", size: 18)
                    .foregroundColor(.primary)
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

            Text(Strings.awsPermHint)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}

// MARK: - ☁️ Cloudflare Settings

private struct CloudflareSettingsView: View {
    let stats: DeepSeekStats

    @State private var cfEnabled: Bool = UserDefaults.standard.bool(forKey: Strings.Keys.cloudflareEnabled)
    @State private var cfToken: String = SecureStore.retrieve(key: Strings.Keys.cloudflareApiToken) ?? ""
    @State private var showCfToken = false
    @State private var isVerifying = false
    @State private var cfDownAlert: Bool = (UserDefaults.standard.object(forKey: Strings.Keys.tunnelDownNotificationEnabled) as? Bool) ?? true

    private var cf: CloudflareTunnelManager { stats.cloudflare }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "cloud.bolt.fill")
                    .foregroundColor(.orange)
                Text(Strings.cloudflareSection)
                    .font(.body).bold()
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(cf.daemonRunning ? Color.green : Color.red).frame(width: 6, height: 6)
                    Text(daemonStatusText).font(.caption).foregroundColor(cf.daemonRunning ? .green : .red)
                }
            }

            Toggle(isOn: $cfEnabled) {
                Text(Strings.cloudflareToggle).font(.callout)
            }
            .toggleStyle(.switch)
            .onChange(of: cfEnabled) { _, newVal in
                cf.enabled = newVal
                if newVal { cf.startAutoRefresh(); cf.refresh() }
            }

            Toggle(isOn: $cfDownAlert) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Strings.tunnelDownNotifyLabel).font(.callout)
                    Text(Strings.tunnelDownNotifyHint).font(.caption2).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: cfDownAlert) { _, newVal in
                UserDefaults.standard.set(newVal, forKey: Strings.Keys.tunnelDownNotificationEnabled)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(Strings.cloudflareTokenLabel).font(.caption).foregroundColor(.secondary)
                    Group {
                        if showCfToken {
                            TextField("", text: $cfToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        } else {
                            SecureField("", text: $cfToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    .onChange(of: cfToken) { _, newVal in
                        SecureStore.save(key: Strings.Keys.cloudflareApiToken, value: newVal)
                        if cfEnabled { cf.refresh() }
                    }
                    Button {
                        showCfToken.toggle()
                    } label: {
                        Image(systemName: showCfToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.bordered)
                    .help(Strings.revealHint)
                }
                Text(Strings.cloudflareTokenHint).font(.caption2).foregroundColor(.secondary)

                Button {
                    isVerifying = true
                    Task {
                        await cf.verifyAndDiscover()
                        isVerifying = false
                    }
                } label: {
                    Text(isVerifying ? Strings.cloudflareVerifyBusy : Strings.cloudflareVerifyAction)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(isVerifying || cfToken.isEmpty)

                if let err = cf.errorMessage {
                    Text(err).font(.caption2).foregroundColor(.red)
                }
            }

            if !cf.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(Strings.cloudflareAccountLabel).font(.caption).foregroundColor(.secondary)
                        Picker("", selection: accountBinding) {
                            ForEach(cf.accounts) { a in
                                Text(a.name).tag(a.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                    if !cf.zones.isEmpty {
                        HStack(spacing: 8) {
                            Text(Strings.cloudflareZoneLabel).font(.caption).foregroundColor(.secondary)
                            Picker("", selection: zoneBinding) {
                                ForEach(cf.zones) { z in
                                    Text(z.name).tag(z.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 220, alignment: .leading)
                        }
                    }
                    if !cf.tunnels.isEmpty {
                        HStack(spacing: 8) {
                            Text(Strings.cloudflareTunnelLabel).font(.caption).foregroundColor(.secondary)
                            Picker("", selection: tunnelBinding) {
                                ForEach(cf.tunnels) { t in
                                    Text(t.name.isEmpty ? t.id : t.name).tag(t.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 220, alignment: .leading)
                        }
                    }
                }
            }

            Text(Strings.cloudflareDaemonNote)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .onAppear {
            Task { await cf.probeDaemon() }
        }
    }

    private var daemonStatusText: String {
        switch cf.daemonState {
        case .running: return Strings.cloudflareDaemonRunning
        case .installed: return Strings.cloudflareDaemonInstalled
        case .notInstalled: return Strings.cloudflareDaemonNotInstalled
        }
    }

    private var accountBinding: Binding<String> {
        Binding(get: { cf.accountID ?? "" },
                set: { id in
                    guard !id.isEmpty else { return }
                    Task { await cf.changeAccount(id) }
                })
    }

    private var zoneBinding: Binding<String> {
        Binding(get: { cf.zoneID ?? "" },
                set: { id in
                    guard !id.isEmpty else { return }
                    cf.changeZone(id)
                })
    }

    private var tunnelBinding: Binding<String> {
        Binding(get: { cf.tunnelID ?? "" },
                set: { id in
                    guard !id.isEmpty else { return }
                    Task { await cf.changeTunnel(id) }
                })
    }
}

// MARK: - Netlify Settings

private struct NetlifySettingsView: View {
    let stats: DeepSeekStats

    @State private var nfEnabled: Bool = UserDefaults.standard.bool(forKey: Strings.Keys.netlifyEnabled)
    @State private var nfToken: String = SecureStore.retrieve(key: Strings.Keys.netlifyApiToken) ?? ""
    @State private var showNfToken = false
    @State private var isVerifying = false
    @State private var nfDeployAlert: Bool = (UserDefaults.standard.object(forKey: Strings.Keys.netlifyDeployNotifyEnabled) as? Bool) ?? true

    private var nf: NetlifyManager { stats.netlify }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                BrandTabIcon(assetName: "netlify", symbol: "diamond", size: 18)
                    .foregroundColor(.primary)
                Text(Strings.netlifySection)
                    .font(.body).bold()
                Spacer()
            }

            Toggle(isOn: $nfEnabled) {
                Text(Strings.netlifyToggle).font(.callout)
            }
            .toggleStyle(.switch)
            .onChange(of: nfEnabled) { _, newVal in
                nf.enabled = newVal
                if newVal { nf.startAutoRefresh(); nf.refresh() }
            }

            Toggle(isOn: $nfDeployAlert) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Strings.netlifyDeployNotifyLabel).font(.callout)
                    Text(Strings.netlifyDeployNotifyHint).font(.caption2).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: nfDeployAlert) { _, newVal in
                UserDefaults.standard.set(newVal, forKey: Strings.Keys.netlifyDeployNotifyEnabled)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(Strings.netlifyTokenLabel).font(.caption).foregroundColor(.secondary)
                    Group {
                        if showNfToken {
                            TextField("", text: $nfToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        } else {
                            SecureField("", text: $nfToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    .onChange(of: nfToken) { _, newVal in
                        SecureStore.save(key: Strings.Keys.netlifyApiToken, value: newVal)
                        if nfEnabled { nf.refresh() }
                    }
                    Button {
                        showNfToken.toggle()
                    } label: {
                        Image(systemName: showNfToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.bordered)
                    .help(Strings.revealHint)
                }
                Text(Strings.netlifyTokenHint).font(.caption2).foregroundColor(.secondary)

                Button {
                    isVerifying = true
                    Task {
                        await nf.verifyAndDiscover()
                        isVerifying = false
                    }
                } label: {
                    Text(isVerifying ? Strings.netlifyVerifyBusy : Strings.netlifyVerifyAction)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(isVerifying || nfToken.isEmpty)

                if let err = nf.errorMessage {
                    Text(err).font(.caption2).foregroundColor(.red)
                }
            }

            if !nf.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(Strings.netlifyAccountLabel).font(.caption).foregroundColor(.secondary)
                        Picker("", selection: accountBinding) {
                            ForEach(nf.accounts) { a in
                                Text(a.name.isEmpty ? a.slug : a.name).tag(a.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                }
            }

            Text(Strings.netlifySettingsNote)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private var accountBinding: Binding<String> {
        Binding(get: { nf.accountID ?? "" },
                set: { id in
                    guard !id.isEmpty else { return }
                    Task { await nf.changeAccount(id) }
                })
    }
}

// MARK: - Local DBs Settings

private struct LocalDBsSettingsView: View {
    let stats: DeepSeekStats

    @State private var dbEnabled: Bool = UserDefaults.standard.bool(forKey: Strings.Keys.localDBsEnabled)
    @State private var dbNotify: Bool = (UserDefaults.standard.object(forKey: Strings.Keys.localDBsNotifyEnabled) as? Bool) ?? true
    @State private var mysqlUser: String = UserDefaults.standard.string(forKey: Strings.Keys.localDBsMySQLUser) ?? ""
    @State private var mysqlPassword: String = SecureStore.retrieve(key: Strings.Keys.localDBsMySQLPassword) ?? ""
    @State private var neo4jUser: String = UserDefaults.standard.string(forKey: Strings.Keys.localDBsNeo4jUser) ?? ""
    @State private var neo4jPassword: String = SecureStore.retrieve(key: Strings.Keys.localDBsNeo4jPassword) ?? ""
    @State private var showMySQLPw = false
    @State private var showNeo4jPw = false
    @State private var isChecking = false

    private var dbm: LocalDBManager { stats.localDBs }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "cylinder.split.1x2")
                    .foregroundColor(.teal)
                Text(Strings.localDBsSection).font(.body).bold()
                Spacer()
            }

            Toggle(isOn: $dbEnabled) {
                Text(Strings.localDBsToggle).font(.callout)
            }
            .toggleStyle(.switch)
            .onChange(of: dbEnabled) { _, newVal in
                dbm.enabled = newVal
                if newVal { dbm.startAutoRefresh(); dbm.refresh() }
            }

            Toggle(isOn: $dbNotify) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Strings.localDBsNotifyLabel).font(.callout)
                    Text(Strings.localDBsNotifyHint).font(.caption2).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: dbNotify) { _, newVal in
                UserDefaults.standard.set(newVal, forKey: Strings.Keys.localDBsNotifyEnabled)
            }

            Text(Strings.localDBsMySQLUserLabel).font(.caption).foregroundColor(.secondary)
            TextField("", text: $mysqlUser)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .onChange(of: mysqlUser) { _, newVal in dbm.setMySQLUser(newVal) }
            HStack(spacing: 8) {
                Group {
                    if showMySQLPw {
                        TextField(Strings.localDBsPasswordLabel, text: $mysqlPassword)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    } else {
                        SecureField(Strings.localDBsPasswordLabel, text: $mysqlPassword)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .onChange(of: mysqlPassword) { _, newVal in dbm.setMySQLPassword(newVal) }
                Button {
                    showMySQLPw.toggle()
                } label: {
                    Image(systemName: showMySQLPw ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
                .help(Strings.revealHint)
            }

            Text(Strings.localDBsNeo4jUserLabel).font(.caption).foregroundColor(.secondary)
            TextField("", text: $neo4jUser)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .onChange(of: neo4jUser) { _, newVal in dbm.setNeo4jUser(newVal) }
            HStack(spacing: 8) {
                Group {
                    if showNeo4jPw {
                        TextField(Strings.localDBsPasswordLabel, text: $neo4jPassword)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    } else {
                        SecureField(Strings.localDBsPasswordLabel, text: $neo4jPassword)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .onChange(of: neo4jPassword) { _, newVal in dbm.setNeo4jPassword(newVal) }
                Button {
                    showNeo4jPw.toggle()
                } label: {
                    Image(systemName: showNeo4jPw ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
                .help(Strings.revealHint)
            }

            Button {
                isChecking = true
                Task {
                    await dbm.checkNow()
                    isChecking = false
                }
            } label: {
                Text(isChecking ? Strings.localDBsCheckBusy : Strings.localDBsCheckAction)
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .disabled(isChecking || !dbEnabled)

            if dbEnabled, let msg = dbm.actionMessage {
                Text(msg).font(.caption2).foregroundColor(dbm.actionSuccess ? .green : .orange)
            }

            Text(Strings.localDBsSettingsNote)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
