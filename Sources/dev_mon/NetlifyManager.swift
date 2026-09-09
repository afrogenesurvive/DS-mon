import Foundation

// MARK: - Netlify — Data Models

/// Netlify 账户（UI 里的 team）。PAT 可见的所有账户。
struct NetlifyAccount: Identifiable, Equatable, Sendable {
    let id: String
    let slug: String
    let name: String
}

/// Netlify 站点（UI 里的 "project"）。`id` == UI "Project ID" == API `site_id`。
struct NetlifySite: Identifiable, Equatable, Sendable {
    let id: String
    let name: String              // slug (xxx.netlify.app 前缀)
    let customDomain: String?
    let url: String?
    let adminURL: String?
    let sslURL: String?
    let state: String?
    let createdAt: Date?
    let publishedDeployID: String?
    // 构建配置（git 链接站点才有）
    let buildProvider: String?
    let repoURL: String?
    let repoBranch: String?
    let buildCommand: String?
    let publishDir: String?
    let functionsDir: String?

    var idOrDomain: String { id }   // API 允许用 id 或域名；这里统一用 id
    var displayName: String { customDomain ?? (name.isEmpty ? id : name) }
    var isGitLinked: Bool { !(buildProvider ?? "").isEmpty && !(repoURL ?? "").isEmpty }
}

/// Netlify 部署。站点是"项目"、"部署"是不可变快照。
/// state 常用值：enqueued / building / uploading / processing / ready / error。
struct NetlifyDeploy: Identifiable, Equatable, Sendable {
    let id: String
    let siteID: String?
    let state: String
    let context: String?          // production / branch-deploy / deploy-preview
    let branch: String?
    let title: String?            // 部署消息
    let commitRef: String?
    let commitURL: String?
    let deployTime: Int?          // 秒
    let createdAt: Date?
    let publishedAt: Date?
    let errorMessage: String?
    let locked: Bool
    let draft: Bool
    // 链接
    let url: String?              // 部署永久链接 <id>--<site>
    let deployURL: String?
    let adminURL: String?

    var isTransitional: Bool {
        ["new", "enqueued", "preparing", "prepared", "building", "uploading", "uploaded", "processing"]
            .contains(state)
    }
    /// 已成功构建的部署（含线上 current 与已下线的 old）。
    var isBuilt: Bool { ["ready", "current", "old"].contains(state) }
    var isReady: Bool { state == "ready" || state == "current" }
    var isError: Bool { state == "error" }
    var isTerminal: Bool { isBuilt || isError }
}

/// 站点的构建钩子（用于无 git 权限地触发部署）。
struct NetlifyBuildHook: Identifiable, Equatable, Sendable {
    let id: String
    let siteID: String?
    let branch: String?
    let url: String?
}

// MARK: - Netlify Error

enum NetlifyError: LocalizedError {
    case notConfigured
    case invalidToken
    case accessDenied
    case notFound(String)
    case networkError(String)
    case parseFailed
    case noAccount
    case noSite
    case deployFailed(String)
    case zipFailed(String)

    var errorDescription: String? {
        let isZH = Self.checkZH()
        switch self {
        case .notConfigured:
            return isZH ? "尚未配置（Settings → Services → Netlify）" : "Not configured (Settings → Services → Netlify)"
        case .invalidToken:
            return isZH ? "Netlify API 令牌无效或已过期" : "Invalid or expired Netlify API token"
        case .accessDenied:
            return isZH ? "权限不足（令牌无权访问该账户/站点）" : "Insufficient permissions (token can't access this account/site)"
        case .notFound(let s):
            return isZH ? "未找到: \(s)" : "Not found: \(s)"
        case .networkError(let m):
            return isZH ? "网络错误: \(m)" : "Network error: \(m)"
        case .parseFailed:
            return isZH ? "解析响应失败" : "Failed to parse response"
        case .noAccount:
            return isZH ? "令牌无权读取任何账户（team）" : "Token can't read any account/team"
        case .noSite:
            return isZH ? "账户下没有站点" : "No sites in this account"
        case .deployFailed(let m):
            return isZH ? "部署失败: \(m)" : "Deploy failed: \(m)"
        case .zipFailed(let m):
            return isZH ? "打包失败: \(m)" : "Failed to create archive: \(m)"
        }
    }

    private static func checkZH() -> Bool {
        let saved = UserDefaults.standard.string(forKey: Strings.Keys.appLanguage) ?? "auto"
        if saved == "auto" {
            let locale = Locale.preferredLanguages.first ?? "en"
            return locale.hasPrefix("zh-Hans") || locale == "zh-CN" || locale == "zh"
        }
        return saved == "zh-Hans"
    }
}

// MARK: - Netlify Manager

/// 管理 Netlify 站点与部署（REST API，Bearer PAT）。
///
/// 与 CloudflareTunnelManager 同构：@Observable 单例持有者（DeepSeekStats）、
/// 自己的定时刷新、SecureStore 令牌、UserDefaults 选择持久化、动作横幅与告警。
@MainActor
@Observable
final class NetlifyManager {
    private static let apiBase = "https://api.netlify.com/api/v1"
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 部署轮询间隔（watch 一个活跃部署时用较快节奏）。
    private static let watchPollInterval: UInt64 = 12_000_000_000   // 12s
    /// 部署终端告警冷却。
    private static let alertCooldown: TimeInterval = 180

    private var refreshTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var watchDeployID: String?
    private var lastNotifyFiredAt: Date?
    /// 用户主动操作后短暂抑制告警，避免把用户触发的部署误报为事件。
    private var suppressAlertUntil: Date?

    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastUpdate = "-"
    private(set) var isWorking = false
    /// 最近一次用户操作的结果（横幅）
    private(set) var actionMessage: String?
    private(set) var actionSuccess = true

    // API 数据
    private(set) var accounts: [NetlifyAccount] = []
    private(set) var sites: [NetlifySite] = []
    private(set) var deploys: [NetlifyDeploy] = []
    private(set) var buildHooks: [NetlifyBuildHook] = []

    // MARK: Settings (persisted)

    var isEnabled: Bool {
        enabled && !apiToken.isEmpty
    }
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Strings.Keys.netlifyEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.netlifyEnabled) }
    }
    var apiToken: String {
        SecureStore.retrieve(key: Strings.Keys.netlifyApiToken) ?? ""
    }
    var accountID: String? {
        get { UserDefaults.standard.string(forKey: Strings.Keys.netlifyAccountId) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.netlifyAccountId) }
    }
    var accountName: String? {
        get { UserDefaults.standard.string(forKey: Strings.Keys.netlifyAccountName) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.netlifyAccountName) }
    }
    var selectedSiteID: String? {
        get { UserDefaults.standard.string(forKey: Strings.Keys.netlifySelectedSiteId) }
        set { UserDefaults.standard.set(newValue, forKey: Strings.Keys.netlifySelectedSiteId) }
    }

    var selectedAccount: NetlifyAccount? {
        guard let id = accountID else { return nil }
        return accounts.first { $0.id == id }
    }
    var selectedSite: NetlifySite? {
        guard let id = selectedSiteID else { return nil }
        return sites.first { $0.id == id }
    }

    private var deployNotifyEnabled: Bool {
        (UserDefaults.standard.object(forKey: Strings.Keys.netlifyDeployNotifyEnabled) as? Bool) ?? true
    }

    init() {
        if isEnabled {
            startAutoRefresh()
            refresh()
        }
    }

    deinit {
        Task { @MainActor [weak self] in
            self?.refreshTask?.cancel()
            self?.watchTask?.cancel()
        }
    }

    // MARK: - Refresh loop

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppConfig.cloudRefreshInterval))
                guard !Task.isCancelled, let self else { return }
                if self.isEnabled { self.refresh() }
            }
        }
    }

    /// 主入口：账户 → 站点 → 选中站点的部署/构建钩子。
    func refresh() {
        guard isEnabled else {
            errorMessage = NetlifyError.notConfigured.localizedDescription
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        Task {
            if accounts.isEmpty { await discoverAccounts() }
            guard errorMessage == nil else { finishRefresh(); return }
            await loadSites()
            guard errorMessage == nil else { finishRefresh(); return }
            if let site = selectedSite {
                await loadDeploys(siteID: site.id)
                if buildHooks.isEmpty { await loadBuildHooks(siteID: site.id) }
            }
            finishRefresh()
        }
    }

    private func finishRefresh() {
        isLoading = false
        if errorMessage == nil {
            lastUpdate = Self.timeFormatter.string(from: Date())
        }
    }

    /// 设置里「验证并发现」：校验令牌 → 账户 → 站点。
    func verifyAndDiscover() async {
        guard !apiToken.isEmpty else {
            errorMessage = NetlifyError.invalidToken.localizedDescription
            return
        }
        isLoading = true
        errorMessage = nil
        await discoverAccounts()
        guard errorMessage == nil else { finishRefresh(); return }
        await loadSites()
        if let site = selectedSite {
            await loadDeploys(siteID: site.id)
            await loadBuildHooks(siteID: site.id)
        }
        finishRefresh()
    }

    // MARK: - Discover / load

    private func discoverAccounts() async {
        accounts = []
        do {
            let arr = try await apiArray("GET", "/accounts")
            accounts = arr.compactMap { dict in
                guard let id = dict["id"] as? String else { return nil }
                let slug = (dict["slug"] as? String) ?? id
                return NetlifyAccount(id: id, slug: slug, name: (dict["name"] as? String) ?? slug)
            }
            if accounts.isEmpty { throw NetlifyError.noAccount }
            // 保持之前选择；否则选第一个。
            if accountID == nil || !accounts.contains(where: { $0.id == accountID }) {
                accountID = accounts[0].id
                accountName = accounts[0].name
            } else if accountName == nil {
                accountName = accounts.first { $0.id == accountID }?.name
            }
        } catch let e as NetlifyError {
            errorMessage = e.localizedDescription
        } catch {
            errorMessage = NetlifyError.networkError(error.localizedDescription).localizedDescription
        }
    }

    private func loadSites() async {
        guard let slug = selectedAccount?.slug else {
            errorMessage = NetlifyError.noAccount.localizedDescription
            return
        }
        do {
            let arr = try await apiArray("GET", "/\(slug)/sites",
                                         query: [URLQueryItem(name: "per_page", value: "100")])
            sites = arr.compactMap(Self.parseSite)
            if sites.isEmpty { throw NetlifyError.noSite }
            // 保持之前选中的站点；否则选第一个。
            if selectedSiteID == nil || !sites.contains(where: { $0.id == selectedSiteID }) {
                selectedSiteID = sites[0].id
            }
        } catch let e as NetlifyError {
            errorMessage = e.localizedDescription
        } catch {
            errorMessage = NetlifyError.networkError(error.localizedDescription).localizedDescription
        }
    }

    func selectSite(_ id: String) async {
        guard selectedSiteID != id else { return }
        selectedSiteID = id
        deploys = []
        buildHooks = []
        if let site = selectedSite {
            await loadDeploys(siteID: site.id)
            await loadBuildHooks(siteID: site.id)
        }
    }

    func changeAccount(_ id: String) async {
        accountID = id
        accountName = accounts.first { $0.id == id }?.name
        selectedSiteID = nil
        sites = []
        deploys = []
        buildHooks = []
        await loadSites()
        if let site = selectedSite {
            await loadDeploys(siteID: site.id)
            await loadBuildHooks(siteID: site.id)
        }
    }

    private func loadDeploys(siteID: String) async {
        do {
            let arr = try await apiArray("GET", "/sites/\(siteID)/deploys",
                                         query: [URLQueryItem(name: "per_page", value: "20")])
            deploys = arr.compactMap(Self.parseDeploy)
            // 若当前有活跃部署且未在 watch，则启动 watch。
            if let active = deploys.first(where: { $0.isTransitional }) {
                startWatchingDeploy(active.id, initial: active)
            }
        } catch let e as NetlifyError {
            errorMessage = e.localizedDescription
        } catch {
            errorMessage = NetlifyError.networkError(error.localizedDescription).localizedDescription
        }
    }

    private func loadBuildHooks(siteID: String) async {
        do {
            let arr = try await apiArray("GET", "/sites/\(siteID)/build_hooks")
            buildHooks = arr.compactMap { dict in
                guard let id = dict["id"] as? String else { return nil }
                return NetlifyBuildHook(
                    id: id,
                    siteID: dict["site_id"] as? String,
                    branch: dict["branch"] as? String,
                    url: dict["url"] as? String
                )
            }
        } catch {
            // 构建钩子读取失败不应阻塞站点/部署展示。
        }
    }

    // MARK: - Deploy watch + notifications

    /// 轮询某个部署直到终端状态；状态翻转时发通知。由 loadDeploys / 各动作启动。
    func startWatchingDeploy(_ deployID: String, initial: NetlifyDeploy? = nil) {
        guard watchDeployID != deployID else { return }
        watchDeployID = deployID
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            var previous = initial
            while !Task.isCancelled {
                try? await Task.sleep(for: .nanoseconds(Self.watchPollInterval))
                guard !Task.isCancelled, let self, self.isEnabled else { return }
                let updated = await self.fetchDeploy(deployID)
                guard let updated else { return }
                if let idx = self.deploys.firstIndex(where: { $0.id == deployID }) {
                    self.deploys[idx] = updated
                } else {
                    self.deploys.insert(updated, at: 0)
                    if self.deploys.count > 20 { self.deploys.removeLast(self.deploys.count - 20) }
                }
                if updated.isTerminal {
                    self.notifyDeployTerminal(updated, previous: previous)
                    if updated.isReady { await self.loadSites() }
                    self.watchDeployID = nil
                    return
                }
                previous = updated
            }
        }
    }

    /// 拉取单个部署详情（watch 轮询用；失败返回 nil 不打断刷新）。
    private func fetchDeploy(_ deployID: String) async -> NetlifyDeploy? {
        do {
            let dict = try await apiDict("GET", "/deploys/\(deployID)")
            return Self.parseDeploy(dict)
        } catch {
            return nil
        }
    }

    private func notifyDeployTerminal(_ deploy: NetlifyDeploy, previous: NetlifyDeploy?) {
        guard deployNotifyEnabled, Date() > (suppressAlertUntil ?? .distantPast) else { return }
        if let t = lastNotifyFiredAt, Date().timeIntervalSince(t) < Self.alertCooldown { return }
        lastNotifyFiredAt = Date()
        let siteName = deploy.siteID == nil ? "" : selectedSite?.displayName ?? ""
        let subject = siteName.isEmpty ? (deploy.branch ?? "") : siteName
        if deploy.isError {
            AppAlertCenter.fire(.netlifyDeployFailed,
                                title: Strings.netlifyDeployFailedTitle,
                                body: String(format: Strings.netlifyDeployFailedBody, subject))
        } else if deploy.isReady, let prev = previous, prev.isReady == false {
            // 只有从非 ready → ready 才算新成功；restore 通知由 rollback 单独发。
            AppAlertCenter.fire(.netlifyDeployReady,
                                title: Strings.netlifyDeployReadyTitle,
                                body: String(format: Strings.netlifyDeployReadyBody, subject))
        }
    }

    // MARK: - Deploy actions

    /// 触发选中站点的生产部署（用构建钩子）。clearCache 时重建缓存。
    func triggerDeploy(site: NetlifySite, clearCache: Bool, title: String?) async {
        guard let hook = await ensureBuildHook(siteID: site.id, branch: site.repoBranch) else { return }
        isWorking = true
        actionMessage = nil
        suppressAlertUntil = Date().addingTimeInterval(30)
        do {
            var comps = URLComponents(string: hook.url ?? "")
            var q: [URLQueryItem] = []
            if clearCache { q.append(URLQueryItem(name: "clear_cache", value: "true")) }
            if let title, !title.isEmpty {
                q.append(URLQueryItem(name: "trigger_title", value: title))
            }
            if !q.isEmpty { comps?.queryItems = q }
            guard let url = comps?.url else { throw NetlifyError.parseFailed }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = AppConfig.cloudRequestTimeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("{}".utf8)
            let (_, resp) = try await AppConfig.directURLSession.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                throw NetlifyError.deployFailed("HTTP \(http.statusCode)")
            }
            actionSuccess = true
            actionMessage = clearCache ? Strings.netlifyTriggerClearSent : Strings.netlifyTriggerSent
            await loadDeploys(siteID: site.id)
        } catch let e as NetlifyError {
            actionSuccess = false
            actionMessage = e.localizedDescription
        } catch {
            actionSuccess = false
            actionMessage = NetlifyError.networkError(error.localizedDescription).localizedDescription
        }
        isWorking = false
    }

    /// 回滚/重启到旧部署（restore 使其成为线上版本）。
    func rollbackToDeploy(_ deploy: NetlifyDeploy, siteID: String) async {
        isWorking = true
        actionMessage = nil
        suppressAlertUntil = Date().addingTimeInterval(30)
        defer { isWorking = false }
        do {
            _ = try await apiDict("POST", "/sites/\(siteID)/deploys/\(deploy.id)/restore")
            actionSuccess = true
            actionMessage = Strings.netlifyRolledBack
            await loadDeploys(siteID: siteID)
            await loadSites()
            fireRolledBack(deploy)
        } catch let e as NetlifyError {
            actionSuccess = false
            actionMessage = e.localizedDescription
        } catch {
            actionSuccess = false
            actionMessage = NetlifyError.networkError(error.localizedDescription).localizedDescription
        }
    }

    /// 锁定 / 解锁部署（锁住当前线上部署可停止自动发布；解锁恢复自动发布）。
    func setDeployLocked(_ deploy: NetlifyDeploy, locked: Bool, siteID: String) async {
        isWorking = true
        actionMessage = nil
        defer { isWorking = false }
        do {
            _ = try await apiDict("POST", "/deploys/\(deploy.id)/\(locked ? "lock" : "unlock")")
            actionSuccess = true
            actionMessage = locked ? Strings.netlifyLocked : Strings.netlifyUnlocked
            await loadDeploys(siteID: siteID)
        } catch let e as NetlifyError {
            actionSuccess = false
            actionMessage = e.localizedDescription
        } catch {
            actionSuccess = false
            actionMessage = NetlifyError.networkError(error.localizedDescription).localizedDescription
        }
    }

    private func fireRolledBack(_ deploy: NetlifyDeploy) {
        guard deployNotifyEnabled, Date() > (suppressAlertUntil ?? .distantPast) else { return }
        if let t = lastNotifyFiredAt, Date().timeIntervalSince(t) < Self.alertCooldown { return }
        lastNotifyFiredAt = Date()
        AppAlertCenter.fire(.netlifyDeployRolledBack,
                            title: Strings.netlifyDeployRolledBackTitle,
                            body: Strings.netlifyDeployRolledBackBody)
    }

    // MARK: - Build hooks

    /// 返回站点现有的构建钩子；没有则自动创建一个（默认用站点的生产分支）。
    private func ensureBuildHook(siteID: String, branch: String?) async -> NetlifyBuildHook? {
        if buildHooks.isEmpty { await loadBuildHooks(siteID: siteID) }
        if let first = buildHooks.first { return first }
        do {
            var body: [String: Any] = [:]
            if let branch, !branch.isEmpty { body["branch"] = branch }
            let dict = try await apiDict("POST", "/sites/\(siteID)/build_hooks", jsonBody: body)
            guard let id = dict["id"] as? String else { throw NetlifyError.parseFailed }
            let hook = NetlifyBuildHook(id: id,
                                        siteID: dict["site_id"] as? String ?? siteID,
                                        branch: dict["branch"] as? String,
                                        url: dict["url"] as? String)
            buildHooks.insert(hook, at: 0)
            return hook
        } catch let e as NetlifyError {
            actionSuccess = false
            actionMessage = e.localizedDescription
            return nil
        } catch {
            actionSuccess = false
            actionMessage = NetlifyError.networkError(error.localizedDescription).localizedDescription
            return nil
        }
    }

    // MARK: - Create site + local deploy

    /// 在选中账户创建空白站点（可选自定义子域名）。
    func createSite(name: String) async -> NetlifySite? {
        guard let slug = selectedAccount?.slug else {
            actionMessage = NetlifyError.noAccount.localizedDescription
            actionSuccess = false
            return nil
        }
        isWorking = true
        actionMessage = nil
        defer { isWorking = false }
        do {
            let dict = try await apiDict("POST", "/\(slug)/sites", jsonBody: ["name": name])
            guard let site = Self.parseSite(dict) else { throw NetlifyError.parseFailed }
            sites.insert(site, at: 0)
            selectedSiteID = site.id
            deploys = []
            buildHooks = []
            actionSuccess = true
            actionMessage = Strings.netlifySiteCreated
            return site
        } catch let e as NetlifyError {
            actionSuccess = false
            actionMessage = e.localizedDescription
            return nil
        } catch {
            actionSuccess = false
            actionMessage = NetlifyError.networkError(error.localizedDescription).localizedDescription
            return nil
        }
    }

    /// 把本地文件夹打成 zip 后推送为新部署（create + deploy 的可靠路径）。
    /// 需要在站点已存在（新站点先 createSite）时调用。
    func deployLocalFolder(siteID: String, folderURL: URL, siteNameForTitle: String) async -> NetlifyDeploy? {
        let zipURL = Self.makeZipURL()
        isWorking = true
        actionMessage = nil
        suppressAlertUntil = Date().addingTimeInterval(30)
        // 1) 打包（后台执行，避免阻塞主线程）
        let zipResult = await Task.detached(priority: .userInitiated) {
            Self.createZip(from: folderURL, to: zipURL)
        }.value
        guard zipResult == 0 else {
            actionSuccess = false
            actionMessage = NetlifyError.zipFailed("exit \(zipResult)").localizedDescription
            isWorking = false
            try? FileManager.default.removeItem(at: zipURL)
            return nil
        }
        // 2) 上传
        defer {
            isWorking = false
            try? FileManager.default.removeItem(at: zipURL)
        }
        do {
            let data = try Data(contentsOf: zipURL)
            let dict = try await self.zipUpload(siteID: siteID, data: data,
                                                title: String(format: Strings.netlifyZipDeployTitle, siteNameForTitle))
            guard let deploy = Self.parseDeploy(dict) else { throw NetlifyError.parseFailed }
            if let idx = deploys.firstIndex(where: { $0.id == deploy.id }) {
                deploys[idx] = deploy
            } else {
                deploys.insert(deploy, at: 0)
                if deploys.count > 20 { deploys.removeLast(deploys.count - 20) }
            }
            actionSuccess = true
            actionMessage = Strings.netlifyDeployUploaded
            if deploy.isTransitional { startWatchingDeploy(deploy.id, initial: deploy) }
            return deploy
        } catch let e as NetlifyError {
            actionSuccess = false
            actionMessage = e.localizedDescription
            return nil
        } catch {
            actionSuccess = false
            actionMessage = NetlifyError.networkError(error.localizedDescription).localizedDescription
            return nil
        }
    }

    private func zipUpload(siteID: String, data: Data, title: String) async throws -> [String: Any] {
        guard let token = apiToken.isEmpty ? nil : apiToken else { throw NetlifyError.invalidToken }
        var comps = URLComponents(string: Self.apiBase + "/sites/\(siteID)/deploys")
        comps?.queryItems = [URLQueryItem(name: "title", value: title)]
        guard let url = comps?.url else { throw NetlifyError.parseFailed }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (respData, resp): (Data, URLResponse)
        do {
            (respData, resp) = try await AppConfig.directURLSession.data(for: req)
        } catch {
            throw NetlifyError.networkError(error.localizedDescription)
        }
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 401 { throw NetlifyError.invalidToken }
            if http.statusCode == 403 { throw NetlifyError.accessDenied }
            if http.statusCode >= 400 {
                let msg = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any]
                let detail = (msg?["message"] as? String) ?? "HTTP \(http.statusCode)"
                throw NetlifyError.deployFailed(detail)
            }
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any] else {
            throw NetlifyError.parseFailed
        }
        return obj
    }

    // MARK: - Parsing

    private static func parseSite(_ dict: [String: Any]) -> NetlifySite? {
        guard let id = dict["id"] as? String else { return nil }
        let bs = dict["build_settings"] as? [String: Any]
        return NetlifySite(
            id: id,
            name: (dict["name"] as? String) ?? id,
            customDomain: dict["custom_domain"] as? String,
            url: dict["url"] as? String,
            adminURL: dict["admin_url"] as? String,
            sslURL: dict["ssl_url"] as? String,
            state: dict["state"] as? String,
            createdAt: parseDate(dict["created_at"]),
            publishedDeployID: (dict["published_deploy"] as? [String: Any])?["id"] as? String,
            buildProvider: bs?["provider"] as? String,
            repoURL: bs?["repo_url"] as? String,
            repoBranch: bs?["repo_branch"] as? String,
            buildCommand: bs?["cmd"] as? String,
            publishDir: bs?["dir"] as? String,
            functionsDir: bs?["functions_dir"] as? String
        )
    }

    private static func parseDeploy(_ dict: [String: Any]) -> NetlifyDeploy? {
        guard let id = dict["id"] as? String else { return nil }
        return NetlifyDeploy(
            id: id,
            siteID: dict["site_id"] as? String,
            state: (dict["state"] as? String) ?? "unknown",
            context: dict["context"] as? String,
            branch: dict["branch"] as? String,
            title: dict["title"] as? String,
            commitRef: dict["commit_ref"] as? String,
            commitURL: dict["commit_url"] as? String,
            deployTime: dict["deploy_time"] as? Int,
            createdAt: parseDate(dict["created_at"]),
            publishedAt: parseDate(dict["published_at"]),
            errorMessage: dict["error_message"] as? String,
            locked: (dict["locked"] as? Bool) ?? false,
            draft: (dict["draft"] as? Bool) ?? false,
            url: dict["url"] as? String,
            deployURL: dict["deploy_url"] as? String,
            adminURL: dict["admin_url"] as? String
        )
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        if let d = isoFormatter.date(from: s) { return d }
        if let d = isoFractionalFormatter.date(from: s) { return d }
        return nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Zip helper (ditto)

    private static func makeZipURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        let name = "devmon-netlify-\(UUID().uuidString.prefix(8)).zip"
        return dir.appendingPathComponent(String(name))
    }

    /// 用 /usr/bin/ditto 把文件夹内容打包为 zip（保留目录结构；归档根为文件夹名）。
    /// 返回进程退出码（0 = 成功）。
    nonisolated private static func createZip(from folderURL: URL, to zipURL: URL) -> Int32 {
        let r = ProcessRunner.run(
            launchPath: "/usr/bin/ditto",
            args: ["-c", "-k", "--keepParent", folderURL.path, zipURL.path],
            timeout: 120
        )
        return r.status
    }

    // MARK: - Netlify API plumbing

    private func apiDict(_ method: String, _ path: String,
                         query: [URLQueryItem] = [], jsonBody: Any? = nil) async throws -> [String: Any] {
        let obj = try await apiAny(method, path, query: query, jsonBody: jsonBody)
        guard let dict = obj as? [String: Any] else { throw NetlifyError.parseFailed }
        return dict
    }

    private func apiArray(_ method: String, _ path: String,
                          query: [URLQueryItem] = [], jsonBody: Any? = nil) async throws -> [[String: Any]] {
        let obj = try await apiAny(method, path, query: query, jsonBody: jsonBody)
        guard let arr = obj as? [[String: Any]] else { throw NetlifyError.parseFailed }
        return arr
    }

    /// 执行一次 Netlify API 调用，返回顶层 JSON（字典或数组）。失败抛 NetlifyError。
    private func apiAny(_ method: String, _ path: String,
                        query: [URLQueryItem] = [], jsonBody: Any? = nil) async throws -> Any {
        guard let token = apiToken.isEmpty ? nil : apiToken else {
            throw NetlifyError.invalidToken
        }
        var comps = URLComponents(string: Self.apiBase + path)
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else { throw NetlifyError.parseFailed }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = AppConfig.cloudRequestTimeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body = jsonBody {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await AppConfig.directURLSession.data(for: req)
        } catch {
            throw NetlifyError.networkError(error.localizedDescription)
        }
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 401 { throw NetlifyError.invalidToken }
            if http.statusCode == 403 { throw NetlifyError.accessDenied }
            if http.statusCode == 404 { throw NetlifyError.notFound(path) }
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) else {
            throw NetlifyError.parseFailed
        }
        return obj
    }
}
