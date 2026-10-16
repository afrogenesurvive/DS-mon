import Foundation

// MARK: - GCP Usage Tracker

/// Polls Google Cloud REST APIs to inventory the user's (pasted) projects:
/// Projects, enabled APIs, Compute instances, IAM service accounts + user-managed
/// keys, Pub/Sub topics/subscriptions, and apps (Cloud Run + App Engine).
///
/// Auth: service-account JSON → RS256 JWT → OAuth2 token (see GCPAuth/GCPClient).
/// Read-only by default; widens scope to `cloud-platform` only when an action
/// toggle (compute / API enable / pubsub publish) is enabled.
@MainActor
@Observable
final class GCPTracker {

    enum Pane: String, CaseIterable, Sendable {
        case overview, projects, apis, compute, iam, pubsub, apps
    }

    // MARK: - State

    private(set) var projects: [GCPProject] = []
    private(set) var apiServices: [String: [GCPApiService]] = [:]      // projectID → services
    private(set) var instances: [GCPInstance] = []
    private(set) var serviceAccounts: [GCPServiceAccount] = []
    private(set) var userManagedKeys: [GCPUserManagedKey] = []
    private(set) var policyBindings: [GCPIamBinding] = []
    private(set) var topics: [GCPTopic] = []
    private(set) var subscriptions: [GCPSubscription] = []
    private(set) var runServices: [GCPCloudRunService] = []
    private(set) var appEngineServices: [GCPAppEngineService] = []
    private(set) var alwaysFree = GCPAlwaysFreeStatus.empty

    private(set) var isLoading = false
    private(set) var lastUpdate = "-"

    // 每个面板各自的首个错误（API 未启用 / 权限不足时显示在对应面板的空态里）。
    private(set) var projectsError: String?
    private(set) var computeError: String?
    private(set) var iamError: String?
    private(set) var pubsubError: String?
    private(set) var appsError: String?
    private(set) var apisError: String?

    // 按 API 的指标（Cloud Monitoring，按需加载）
    private(set) var apiMetrics: [GCPApiMetric] = []
    private(set) var metricsError: String?
    /// 指标时间范围（默认 24h，最长 30 天）
    private(set) var metricRange: GCPMetricRange = .day

    private var refreshTask: Task<Void, Never>?
    private var apiLoadTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    /// OAuth2 令牌缓存（MainActor；刷新于到期前 60 秒）
    private var cachedToken: GCPAuth.Token?

    // Alert dedupe (per-run)
    private var warnedAlwaysFree = false
    private var notifiedOldKeys: Set<String> = []

    // MARK: - Settings

    var isEnabled: Bool { !saJSON.isEmpty && !projectIDs.isEmpty }

    var saJSON: String {
        SecureStore.retrieve(key: Strings.Keys.gcpServiceAccountJSON) ?? ""
    }

    var projectIDs: [String] {
        let raw = UserDefaults.standard.string(forKey: Strings.Keys.gcpProjectIds) ?? ""
        var seen = Set<String>()
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    var computeActionsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Strings.Keys.gcpComputeActionsEnabled)
    }
    var apiActionsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Strings.Keys.gcpApiActionsEnabled)
    }
    var pubsubPublishEnabled: Bool {
        UserDefaults.standard.bool(forKey: Strings.Keys.gcpPubsubPublishEnabled)
    }

    /// OAuth 作用域固定为 `cloud-platform`：只读由服务账号的 IAM 角色强制，
    /// 而非 OAuth 作用域——Cloud Resource Manager 等 API 只接受完整作用域，
    /// `cloud-platform.read-only` 会报 "insufficient authentication scopes"。
    private var scope: String {
        "https://www.googleapis.com/auth/cloud-platform"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        if isEnabled {
            startAutoRefresh()
            refresh()
        }
    }

    deinit {
        Task { @MainActor [weak self] in
            self?.refreshTask?.cancel()
            self?.apiLoadTask?.cancel()
            self?.metricsTask?.cancel()
        }
    }

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppConfig.cloudRefreshInterval))
                guard !Task.isCancelled, let self else { return }
                if self.isEnabled {
                    self.refresh()
                }
            }
        }
    }

    // MARK: - Refresh

    func refresh() {
        guard isEnabled else { return }
        isLoading = true
        projectsError = nil
        computeError = nil
        iamError = nil
        pubsubError = nil
        appsError = nil
        apisError = nil
        let client = GCPClient(saJSON: saJSON, scope: scope)

        Task { [weak self] in
            guard let self else { return }

            let projects = await self.fetchProjects(client)
            let ids = projects.projects.map(\.id)
            let instances = await self.fetchInstances(client, ids)
            let iam = await self.fetchIAM(client, ids)
            let pubsub = await self.fetchPubSub(client, ids)
            let apps = await self.fetchApps(client, ids)

            self.projectsError = projects.error
            self.computeError = instances.error
            self.iamError = iam.error
            self.pubsubError = pubsub.error
            self.appsError = apps.error
            self.isLoading = false
            self.lastUpdate = Self.timeFormatter.string(from: Date())
            self.evaluateAlerts()
        }
    }

    /// APIs are fetched on demand (Service Usage read quota is tight).
    func loadAPIs(force: Bool = false) {
        guard isEnabled else { return }
        if !force, !apiServices.isEmpty { return }
        guard apiLoadTask == nil else { return }
        let client = GCPClient(saJSON: saJSON, scope: scope)
        apiLoadTask = Task { [weak self] in
            guard let self else { return }
            let ids = self.projectIDs
            var result: [String: [GCPApiService]] = [:]
            var firstError: String?
            for id in ids {
                do {
                    let json = try await getJSON(client,
                        "https://serviceusage.googleapis.com/v1/projects/\(id)/services",
                        query: [
                            URLQueryItem(name: "filter", value: "state:ENABLED"),
                            URLQueryItem(name: "pageSize", value: "200"),
                        ])
                    let services = (json["services"] as? [[String: Any]] ?? []).compactMap { s -> GCPApiService? in
                        let name = s["name"] as? String ?? ""
                        let short = name.components(separatedBy: "/").last ?? ""
                        guard !short.isEmpty else { return nil }
                        // state 在 service 对象的顶层（config 里没有 state 字段）。
                        let state = s["state"] as? String ?? "UNKNOWN"
                        return GCPApiService(id: short, name: short, state: state)
                    }.sorted { $0.id < $1.id }
                    result[id] = services
                } catch {
                    firstError = firstError ?? (error as? GCPError)?.localizedDescription ?? error.localizedDescription
                }
            }
            self.apiServices = result
            self.apisError = firstError
            self.lastUpdate = Self.timeFormatter.string(from: Date())
            self.apiLoadTask = nil
        }
    }

    /// 设置指标时间范围并重新加载。
    func setMetricRange(_ range: GCPMetricRange) {
        metricRange = range
        loadAPIMetrics()
    }

    /// 按 API 的指标（请求量 / 5xx 错误 / 平均延迟，Cloud Monitoring）。按需加载（APIs 面板）。
    func loadAPIMetrics() {
        guard isEnabled else { return }
        metricsTask?.cancel()
        let range = metricRange
        let client = GCPClient(saJSON: saJSON, scope: scope)
        metricsTask = Task { [weak self] in
            guard let self else { return }
            var firstError: String?
            var merged: [String: (requests: Double, errors: Double, latency: Double)] = [:]
            for id in self.projectIDs {
                do {
                    let requests = try await self.monitoringValues(
                        client, project: id,
                        metricType: "serviceruntime.googleapis.com/api/request_count",
                        aligner: "ALIGN_SUM", isDistribution: false,
                        rangeSeconds: range.seconds, alignmentSeconds: range.alignmentSeconds)
                    let errors = try await self.monitoringValues(
                        client, project: id,
                        metricType: "serviceruntime.googleapis.com/api/request_count",
                        extraFilter: "5xx", aligner: "ALIGN_SUM", isDistribution: false,
                        rangeSeconds: range.seconds, alignmentSeconds: range.alignmentSeconds)
                    let latency = try await self.monitoringValues(
                        client, project: id,
                        metricType: "serviceruntime.googleapis.com/api/request_latencies",
                        aligner: "ALIGN_SUM", isDistribution: true,
                        rangeSeconds: range.seconds, alignmentSeconds: range.alignmentSeconds)
                    let services = Set(requests.keys).union(errors.keys).union(latency.keys)
                    for svc in services {
                        var cur = merged[svc] ?? (0, 0, 0)
                        cur.requests += requests[svc] ?? 0
                        cur.errors += errors[svc] ?? 0
                        cur.latency += latency[svc] ?? 0
                        merged[svc] = cur
                    }
                } catch {
                    firstError = firstError ?? self.localized(error)
                }
            }
            guard !Task.isCancelled else { return }
            self.apiMetrics = merged.map {
                GCPApiMetric(service: $0.key,
                             requests: Int64($0.value.requests),
                             errors: Int64($0.value.errors),
                             avgLatencyMs: $0.value.latency * 1000)
            }.sorted { $0.service < $1.service }
            self.metricsError = firstError
            self.metricsTask = nil
        }
    }

    /// 拉取单个 Monitoring 指标，按 `resource.labels.service` 分组，返回 service → 值。
    private func monitoringValues(_ client: GCPClient, project: String,
                                  metricType: String,
                                  extraFilter: String = "",
                                  aligner: String,
                                  isDistribution: Bool,
                                  rangeSeconds: TimeInterval,
                                  alignmentSeconds: Int) async throws -> [String: Double] {
        var filter = #"metric.type=""# + metricType + #"""#
        if !extraFilter.isEmpty {
            filter += #" AND metric.labels.response_code_class=""# + extraFilter + #"""#
        }
        let now = Date()
        let start = now.addingTimeInterval(-rangeSeconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let json = try await getJSON(client,
            "https://monitoring.googleapis.com/v3/projects/\(project)/timeSeries",
            query: [
                URLQueryItem(name: "filter", value: filter),
                URLQueryItem(name: "interval.startTime", value: formatter.string(from: start)),
                URLQueryItem(name: "interval.endTime", value: formatter.string(from: now)),
                URLQueryItem(name: "aggregation.alignmentPeriod", value: "\(alignmentSeconds)s"),
                URLQueryItem(name: "aggregation.perSeriesAligner", value: aligner),
                // `groupByFields` is ignored unless a cross-series reducer is set;
                // REDUCE_SUM merges every method/credential series into one per service.
                URLQueryItem(name: "aggregation.crossSeriesReducer", value: "REDUCE_SUM"),
                URLQueryItem(name: "aggregation.groupByFields", value: "resource.labels.service"),
            ])
        var result: [String: Double] = [:]
        for ts in (json["timeSeries"] as? [[String: Any]] ?? []) {
            let resource = ts["resource"] as? [String: Any]
            let labels = resource?["labels"] as? [String: Any]
            guard let service = labels?["service"] as? String, !service.isEmpty else { continue }
            var total: Double = 0
            for point in (ts["points"] as? [[String: Any]] ?? []) {
                let value = point["value"] as? [String: Any]
                if isDistribution {
                    if let mean = value?["mean"] as? Double { total += mean }
                    else if let meanStr = value?["mean"] as? String, let m = Double(meanStr) { total += m }
                } else {
                    if let v = value?["int64Value"] as? String { total += Double(Int64(v) ?? 0) }
                    else if let v = value?["int64Value"] as? Int64 { total += Double(v) }
                    else if let v = value?["int64Value"] as? Double { total += v }
                }
            }
            result[service, default: 0] += total
        }
        return result
    }

    // MARK: - Fetchers

    private func fetchProjects(_ client: GCPClient) async -> (projects: [GCPProject], error: String?) {
        var result: [GCPProject] = []
        var firstError: String?
        for id in projectIDs {
            do {
                let json = try await getJSON(client, "https://cloudresourcemanager.googleapis.com/v1/projects/\(id)")
                result.append(GCPProject(
                    id: json["projectId"] as? String ?? id,
                    number: json["projectNumber"] as? String ?? "",
                    name: json["name"] as? String ?? id,
                    state: json["lifecycleState"] as? String ?? ""
                ))
            } catch {
                firstError = firstError ?? localized(error)
            }
        }
        self.projects = result.sorted { $0.id < $1.id }
        return (self.projects, firstError)
    }

    private func fetchInstances(_ client: GCPClient, _ ids: [String]) async -> (instances: [GCPInstance], error: String?) {
        var result: [GCPInstance] = []
        var firstError: String?
        for id in ids {
            do {
                let json = try await getJSON(client,
                    "https://compute.googleapis.com/compute/v1/projects/\(id)/aggregated/instances")
                result.append(contentsOf: Self.parseInstances(json, project: id))
            } catch {
                firstError = firstError ?? localized(error)
            }
        }
        self.instances = result.sorted { $0.id < $1.id }
        self.alwaysFree = Self.computeAlwaysFree(result)
        return (self.instances, firstError)
    }

    private func fetchIAM(_ client: GCPClient, _ ids: [String]) async -> (accounts: [GCPServiceAccount], error: String?) {
        var accounts: [GCPServiceAccount] = []
        var keys: [GCPUserManagedKey] = []
        var bindings: [GCPIamBinding] = []
        var firstError: String?
        for id in ids {
            do {
                let saJSON = try await getJSON(client,
                    "https://iam.googleapis.com/v1/projects/\(id)/serviceAccounts",
                    query: [URLQueryItem(name: "pageSize", value: "100")])
                let list = (saJSON["accounts"] as? [[String: Any]] ?? []).compactMap { a -> GCPServiceAccount? in
                    guard let email = a["email"] as? String else { return nil }
                    return GCPServiceAccount(email: email, displayName: a["displayName"] as? String ?? "")
                }
                accounts.append(contentsOf: list)

                // User-managed keys per service account (read-only).
                for account in list {
                    do {
                        let keyJSON = try await getJSON(client,
                            "https://iam.googleapis.com/v1/projects/\(id)/serviceAccounts/\(account.email)/keys",
                            query: [URLQueryItem(name: "keyTypes", value: "USER_MANAGED")])
                        let found = (keyJSON["keys"] as? [[String: Any]] ?? []).compactMap { k -> GCPUserManagedKey? in
                            guard let name = k["name"] as? String else { return nil }
                            return GCPUserManagedKey(
                                id: name.components(separatedBy: "/").last ?? name,
                                name: name,
                                validAfterTime: k["validAfterTime"] as? String ?? "",
                                validBeforeTime: k["validBeforeTime"] as? String ?? "",
                                keyType: k["keyType"] as? String ?? ""
                            )
                        }
                        keys.append(contentsOf: found)
                    } catch {
                        // 403 here just means the SA has no listing permission — not fatal.
                    }
                }
            } catch {
                firstError = firstError ?? localized(error)
            }
            // IAM policy bindings (getIamPolicy on the project).
            do {
                let policy = try await postJSON(client,
                    "https://cloudresourcemanager.googleapis.com/v1/projects/\(id):getIamPolicy",
                    body: ["options": ["requestedPolicyVersion": 3]])
                let found = (policy["bindings"] as? [[String: Any]] ?? []).compactMap { b -> GCPIamBinding? in
                    guard let role = b["role"] as? String else { return nil }
                    return GCPIamBinding(role: role, members: b["members"] as? [String] ?? [])
                }
                bindings.append(contentsOf: found)
            } catch {
                // Optional — keep going.
            }
        }
        self.serviceAccounts = accounts.sorted { $0.email < $1.email }
        self.userManagedKeys = keys.sorted { $0.id < $1.id }
        self.policyBindings = bindings.sorted { $0.role < $1.role }
        return (self.serviceAccounts, firstError)
    }

    private func fetchPubSub(_ client: GCPClient, _ ids: [String]) async -> (topics: [GCPTopic], error: String?) {
        var foundTopics: [GCPTopic] = []
        var foundSubs: [GCPSubscription] = []
        var firstError: String?
        for id in ids {
            do {
                let t = try await getJSON(client, "https://pubsub.googleapis.com/v1/projects/\(id)/topics",
                                          query: [URLQueryItem(name: "pageSize", value: "200")])
                foundTopics.append(contentsOf: (t["topics"] as? [[String: Any]] ?? []).compactMap { o in
                    guard let name = o["name"] as? String else { return nil }
                    return GCPTopic(name: name)
                })
            } catch {
                firstError = firstError ?? localized(error)
            }
            do {
                let s = try await getJSON(client, "https://pubsub.googleapis.com/v1/projects/\(id)/subscriptions",
                                          query: [URLQueryItem(name: "pageSize", value: "200")])
                foundSubs.append(contentsOf: (s["subscriptions"] as? [[String: Any]] ?? []).compactMap { o in
                    guard let name = o["name"] as? String else { return nil }
                    return GCPSubscription(name: name, topic: o["topic"] as? String ?? "")
                })
            } catch {
                firstError = firstError ?? localized(error)
            }
        }
        self.topics = foundTopics.sorted { $0.name < $1.name }
        self.subscriptions = foundSubs.sorted { $0.name < $1.name }
        return (self.topics, firstError)
    }

    private func fetchApps(_ client: GCPClient, _ ids: [String]) async -> (services: [GCPCloudRunService], error: String?) {
        var run: [GCPCloudRunService] = []
        var appEngine: [GCPAppEngineService] = []
        for id in ids {
            // Cloud Run across a bounded set of locations.
            do {
                let locJSON = try await getJSON(client,
                    "https://run.googleapis.com/v1/projects/\(id)/locations",
                    query: [URLQueryItem(name: "pageSize", value: "20")])
                let locs = ((locJSON["locations"] as? [[String: Any]]) ?? []).compactMap { $0["locationId"] as? String }
                for loc in locs.prefix(10) {
                    do {
                        let svc = try await getJSON(client,
                            "https://run.googleapis.com/v1/projects/\(id)/locations/\(loc)/services")
                        for item in (svc["items"] as? [[String: Any]] ?? []) {
                            let meta = item["metadata"] as? [String: Any]
                            let status = item["status"] as? [String: Any]
                            guard let name = meta?["name"] as? String, !name.isEmpty else { continue }
                            run.append(GCPCloudRunService(
                                name: name,
                                region: loc,
                                url: status?["url"] as? String ?? "",
                                latestRevision: status?["latestCreatedRevisionName"] as? String ?? ""
                            ))
                        }
                    } catch {}
                }
            } catch {}

            // App Engine services + versions.
            do {
                let svc = try await getJSON(client, "https://appengine.googleapis.com/v1/apps/\(id)/services",
                                            query: [URLQueryItem(name: "pageSize", value: "100")])
                var services: [GCPAppEngineService] = []
                for s in (svc["services"] as? [[String: Any]] ?? []) {
                    guard let sid = s["id"] as? String else { continue }
                    var versions: [String] = []
                    do {
                        let v = try await getJSON(client,
                            "https://appengine.googleapis.com/v1/apps/\(id)/services/\(sid)/versions",
                            query: [URLQueryItem(name: "pageSize", value: "100")])
                        versions = (v["versions"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                    } catch {}
                    services.append(GCPAppEngineService(name: sid, versions: versions))
                }
                appEngine.append(contentsOf: services)
            } catch {
                // 404 = no App Engine app in this project — expected, not an error.
            }
        }
        self.runServices = run.sorted { $0.name < $1.name }
        self.appEngineServices = appEngine.sorted { $0.name < $1.name }
        return (self.runServices, nil)
    }

    // MARK: - Actions

    @discardableResult
    func startInstance(_ project: String, zone: String, name: String) async -> String? {
        await computeAction(project, zone: zone, name: name, verb: "start")
    }

    @discardableResult
    func stopInstance(_ project: String, zone: String, name: String) async -> String? {
        await computeAction(project, zone: zone, name: name, verb: "stop")
    }

    @discardableResult
    func resetInstance(_ project: String, zone: String, name: String) async -> String? {
        await computeAction(project, zone: zone, name: name, verb: "reset")
    }

    private func computeAction(_ project: String, zone: String, name: String, verb: String) async -> String? {
        let client = GCPClient(saJSON: saJSON, scope: scope)
        do {
            _ = try await postJSON(client,
                "https://compute.googleapis.com/compute/v1/projects/\(project)/zones/\(zone)/instances/\(name)/\(verb)",
                body: [:])
            ActionLog.record(.gcp, action: "instance.\(verb)", target: "\(project)/\(name)",
                             success: true, message: nil)
            refresh()
            return nil
        } catch {
            let message = localized(error)
            ActionLog.record(.gcp, action: "instance.\(verb)", target: "\(project)/\(name)",
                             success: false, message: message)
            return message
        }
    }

    @discardableResult
    func publish(_ project: String, topic: String, message: String) async -> String? {
        let client = GCPClient(saJSON: saJSON, scope: scope)
        let payload = Data(message.utf8).base64EncodedString()
        do {
            _ = try await postJSON(client,
                "https://pubsub.googleapis.com/v1/projects/\(project)/topics/\(topic):publish",
                body: ["messages": [["data": payload]]])
            ActionLog.record(.gcp, action: "topic.publish", target: "\(project)/\(topic)",
                             success: true, message: nil)
            return nil
        } catch {
            let message = localized(error)
            ActionLog.record(.gcp, action: "topic.publish", target: "\(project)/\(topic)",
                             success: false, message: message)
            return message
        }
    }

    @discardableResult
    func setAPIAction(_ project: String, service: String, enable: Bool) async -> String? {
        let client = GCPClient(saJSON: saJSON, scope: scope)
        let verb = enable ? "enable" : "disable"
        do {
            _ = try await postJSON(client,
                "https://serviceusage.googleapis.com/v1/projects/\(project)/services/\(service):\(verb)",
                body: [:])
            ActionLog.record(.gcp, action: "service.\(verb)", target: "\(project)/\(service)",
                             success: true, message: nil)
            loadAPIs(force: true)
            return nil
        } catch {
            let message = localized(error)
            ActionLog.record(.gcp, action: "service.\(verb)", target: "\(project)/\(service)",
                             success: false, message: message)
            return message
        }
    }

    // MARK: - Alerts

    private func evaluateAlerts() {
        // Always-free compute warning.
        if alwaysFree.isWarning {
            if !warnedAlwaysFree {
                warnedAlwaysFree = true
                guard UserDefaults.standard.bool(forKey: Strings.Keys.gcpAlwaysFreeNotifyEnabled) else { return }
                AppAlertCenter.fire(.gcpAlwaysFreeWarning,
                                    title: Strings.gcpAlwaysFreeTitle,
                                    body: Strings.gcpAlwaysFreeBody)
            }
        } else {
            warnedAlwaysFree = false
        }

        // User-managed key rotation (>= 90 days old).
        guard UserDefaults.standard.bool(forKey: Strings.Keys.gcpKeyRotationNotifyEnabled) else { return }
        for key in userManagedKeys where key.keyType == "USER_MANAGED" {
            guard let age = key.ageDays, age >= 90 else { continue }
            if notifiedOldKeys.insert(key.name).inserted {
                AppAlertCenter.fire(.gcpKeyRotation,
                                    title: Strings.gcpKeyRotationTitle,
                                    body: String(format: Strings.gcpKeyRotationBody, key.id, age),
                                    subject: key.name)
            }
        }
    }

    // MARK: - HTTP helpers

    private func getJSON(_ client: GCPClient, _ urlString: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        var (data, http) = try await client.get(urlString, query: query, token: try await token(for: client))
        if http.statusCode == 401 {
            cachedToken = nil
            (data, http) = try await client.get(urlString, query: query, token: try await token(for: client))
        }
        try Self.checkStatus(http, data: data)
        return try Self.parseJSON(data)
    }

    private func postJSON(_ client: GCPClient, _ urlString: String, body: [String: Any]) async throws -> [String: Any] {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var (data, http) = try await client.post(urlString, body: bodyData, token: try await token(for: client))
        if http.statusCode == 401 {
            cachedToken = nil
            (data, http) = try await client.post(urlString, body: bodyData, token: try await token(for: client))
        }
        try Self.checkStatus(http, data: data)
        return try Self.parseJSON(data)
    }

    private func token(for client: GCPClient) async throws -> String {
        if let cachedToken, Date() < cachedToken.expiresAt.addingTimeInterval(-60) {
            return cachedToken.accessToken
        }
        let t = try await client.fetchToken()
        cachedToken = t
        return t.accessToken
    }

    private static func checkStatus(_ http: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 || http.statusCode == 403 {
                throw GCPError.accessDenied(Self.errorReason(data, fallback: body))
            }
            throw GCPError.httpStatus(http.statusCode, body)
        }
    }

    /// 从 Google 的 403/401 JSON 里抽出真正缺失的权限（error.message）。
    private static func errorReason(_ data: Data, fallback: String) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String, !message.isEmpty else {
            return fallback
        }
        return message.count > 300 ? String(message.prefix(300)) : message
    }

    private static func parseJSON(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GCPError.parseFailed
        }
        return json
    }

    // MARK: - Helpers

    private func localized(_ error: Error) -> String {
        if let gcp = error as? GCPError { return gcp.localizedDescription }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return GCPError.networkError("Timeout").localizedDescription
            case .notConnectedToInternet, .networkConnectionLost:
                return GCPError.networkError("No network").localizedDescription
            default: break
            }
        }
        return GCPError.networkError(error.localizedDescription).localizedDescription
    }

    private static func parseInstances(_ json: [String: Any], project: String) -> [GCPInstance] {
        var result: [GCPInstance] = []
        let items = json["items"] as? [String: Any] ?? [:]
        for (zoneKey, value) in items {
            guard let zoneObj = value as? [String: Any],
                  let list = zoneObj["instances"] as? [[String: Any]] else { continue }
            for inst in list {
                guard let name = inst["name"] as? String, !name.isEmpty else { continue }
                let status = inst["status"] as? String ?? "UNKNOWN"
                let machineType = (inst["machineType"] as? String)?.components(separatedBy: "/").last ?? ""
                let zone = (inst["zone"] as? String)?.components(separatedBy: "/").last ?? zoneKey
                var publicIP: String?
                var privateIP: String?
                for ni in (inst["networkInterfaces"] as? [[String: Any]] ?? []) {
                    if let ip = ni["networkIP"] as? String { privateIP = ip }
                    for ac in (ni["accessConfigs"] as? [[String: Any]] ?? []) {
                        if let nat = ac["natIP"] as? String { publicIP = nat }
                    }
                }
                result.append(GCPInstance(id: name, project: project, zone: zone, machineType: machineType,
                                          status: status, publicIP: publicIP, privateIP: privateIP))
            }
        }
        return result
    }

    private static func region(of zone: String) -> String {
        let parts = zone.components(separatedBy: "-")
        return parts.dropLast().joined(separator: "-")
    }

    private static func computeAlwaysFree(_ instances: [GCPInstance]) -> GCPAlwaysFreeStatus {
        let eligible = instances.filter {
            $0.machineType == GCPAlwaysFreeStatus.freeMachineType
                && GCPAlwaysFreeStatus.freeRegions.contains(region(of: $0.zone))
        }
        let runningEligible = eligible.filter { $0.isRunning }.count
        let nonEligibleRunning = instances.filter { $0.isRunning && !eligible.contains($0) }.count
        return GCPAlwaysFreeStatus(
            runningInstances: runningEligible,
            limitInstances: 1,
            eligibleCount: eligible.count,
            nonEligibleCount: nonEligibleRunning
        )
    }
}
