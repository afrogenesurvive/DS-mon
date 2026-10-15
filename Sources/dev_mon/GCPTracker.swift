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
    private(set) var errorMessage: String?
    private(set) var lastUpdate = "-"

    private var refreshTask: Task<Void, Never>?
    private var apiLoadTask: Task<Void, Never>?
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

    private var scope: String {
        if computeActionsEnabled || apiActionsEnabled || pubsubPublishEnabled {
            return "https://www.googleapis.com/auth/cloud-platform"
        }
        return "https://www.googleapis.com/auth/cloud-platform.read-only"
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
        guard isEnabled else {
            errorMessage = GCPError.invalidCredentials.localizedDescription
            return
        }
        isLoading = true
        errorMessage = nil
        let client = GCPClient(saJSON: saJSON, scope: scope)

        Task { [weak self] in
            guard let self else { return }
            var firstError: String?

            let projects = await self.fetchProjects(client)
            if let err = projects.error { firstError = firstError ?? err }
            let ids = projects.projects.map(\.id)

            let instances = await self.fetchInstances(client, ids)
            if let err = instances.error { firstError = firstError ?? err }

            let iam = await self.fetchIAM(client, ids)
            if let err = iam.error { firstError = firstError ?? err }

            let pubsub = await self.fetchPubSub(client, ids)
            if let err = pubsub.error { firstError = firstError ?? err }

            let apps = await self.fetchApps(client, ids)
            if let err = apps.error { firstError = firstError ?? err }

            self.errorMessage = firstError
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
                        query: [URLQueryItem(name: "pageSize", value: "200")])
                    let services = (json["services"] as? [[String: Any]] ?? []).compactMap { s -> GCPApiService? in
                        let name = s["name"] as? String ?? ""
                        let short = name.components(separatedBy: "/").last ?? ""
                        guard !short.isEmpty else { return nil }
                        let config = s["config"] as? [String: Any]
                        let state = config?["state"] as? String ?? "UNKNOWN"
                        return GCPApiService(id: short, name: short, state: state)
                    }.sorted { $0.id < $1.id }
                    result[id] = services
                } catch {
                    firstError = firstError ?? (error as? GCPError)?.localizedDescription ?? error.localizedDescription
                }
            }
            self.apiServices = result
            if let firstError { self.errorMessage = firstError }
            self.lastUpdate = Self.timeFormatter.string(from: Date())
            self.apiLoadTask = nil
        }
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
        return (result.sorted { $0.id < $1.id }, firstError)
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
                throw GCPError.accessDenied
            }
            throw GCPError.httpStatus(http.statusCode, body)
        }
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
