import Combine
import Foundation

/// 代理请求返回的完整响应。
struct AIProxyReply: Sendable {
    var statusCode: Int
    var contentType: String
    var body: Data
    var headers: [String: String]

    static func error(_ message: String, status: Int = 503) -> AIProxyReply {
        let payload: [String: Any] = [
            "error": [
                "message": message,
                "type": "router_error"
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]))
            ?? Data("{\"error\":{\"message\":\"router error\"}}".utf8)
        return AIProxyReply(
            statusCode: status,
            contentType: "application/json; charset=utf-8",
            body: data,
            headers: [:]
        )
    }
}

struct RouterPiPInfo {
    var modelName: String
    var tokensUsed: Int?
    var contextLimit: Int
}

private enum ProbeOutcome: Sendable {
    case healthy(Int)
    case cancelled
    case auth(String)
    case unsupported(String)
    case failure(String)
}

private enum ProxyAttempt: Sendable {
    case success(AIProxyReply, AIEndpoint, Int)
    case failure(AIEndpoint, String, Int, Int)
    case cancelled
}

/// 多端点 AI 路由：
/// - 并行探测所有端点，维护“可用 / 延迟 / 冷却”状态；
/// - 本地 `/v1/chat/completions` 请求按健康排名即时选择端点；
/// - 首选端点在前 100ms 内没有完成时，按 stagger 并发启动后续端点，先成功者胜出；
/// - 失败端点进入冷却，避免继续拖慢请求。
@MainActor
final class EndpointRouter: ObservableObject {
    @Published private(set) var configuration: RouterConfiguration
    @Published private(set) var health: [UUID: EndpointHealth] = [:]
    @Published private(set) var routeLog: [RouteLog] = []
    @Published private(set) var isProbing = false
    @Published private(set) var isRefreshingSubscriptions = false
    @Published private(set) var lastSelectedEndpoint: AIEndpoint?
    @Published private(set) var lastCompletionModel: String?
    @Published private(set) var lastCompletionTokens: Int?
    @Published private(set) var lastError: String?
    @Published private(set) var requestCount = 0
    @Published private(set) var successCount = 0
    @Published private(set) var failureCount = 0

    private let session: URLSession
    private var monitorTask: Task<Void, Never>?
    private var monitorGeneration = 0
    private var didBootstrap = false
    private let maximumLogCount = 200

    init() {
        configuration = RouterConfigurationStore.load().sanitized
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 90
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.httpAdditionalHeaders = ["User-Agent": "LocalAPIBridge-Router/1.0 (iOS)"]
        session = URLSession(configuration: sessionConfiguration)
        reconcileHealth()
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        if configuration.monitoringEnabled {
            startMonitoring()
        }
        Task { await self.refreshStaleSubscriptionsIfNeeded() }
    }

    func apply(_ newConfiguration: RouterConfiguration) {
        configuration = newConfiguration.sanitized
        RouterConfigurationStore.save(configuration)
        reconcileHealth()
        if configuration.monitoringEnabled {
            startMonitoring()
        } else {
            stopMonitoring()
            probeAllNow()
        }
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        var copy = configuration
        copy.monitoringEnabled = enabled
        apply(copy)
    }

    // MARK: - 端点维护

    func toggleEndpoint(id: UUID) {
        guard let index = configuration.endpoints.firstIndex(where: { $0.id == id }) else { return }
        configuration.endpoints[index].enabled.toggle()
        RouterConfigurationStore.save(configuration)
        reconcileHealth()
    }

    func upsertEndpoint(_ endpoint: AIEndpoint) {
        if let index = configuration.endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            configuration.endpoints[index] = endpoint
        } else {
            configuration.endpoints.append(endpoint)
        }
        configuration = configuration.sanitized
        RouterConfigurationStore.save(configuration)
        reconcileHealth()
        probeAllNow()
    }

    func deleteEndpoint(id: UUID) {
        configuration.endpoints.removeAll { $0.id == id }
        RouterConfigurationStore.save(configuration)
        reconcileHealth()
    }

    var manualEndpoints: [AIEndpoint] {
        configuration.endpoints.filter { $0.subscriptionID == nil }
    }

    func manualEndpointsJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manualEndpoints),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    /// 解析 JSON 文本并替换“手动端点”，订阅端点保持不变。
    func importManualEndpointsJSON(_ text: String) -> (count: Int, error: String?) {
        guard let data = text.data(using: .utf8) else {
            return (0, "文本编码无效")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return (0, "不是有效的 JSON")
        }
        let parsed = Self.endpoints(fromJSON: object, subscriptionID: nil)
        guard !parsed.isEmpty else {
            return (0, "没有解析到端点，请检查 base_url / url 字段")
        }
        configuration.endpoints.removeAll { $0.subscriptionID == nil }
        configuration.endpoints.append(contentsOf: parsed)
        configuration = configuration.sanitized
        RouterConfigurationStore.save(configuration)
        reconcileHealth()
        lastError = nil
        probeAllNow()
        return (parsed.count, nil)
    }

    // MARK: - 从 API 获取模型（批量添加端点）

    struct ModelDiscoveryResult: Sendable {
        var models: [String]
        var error: String?
        var suggestedName: String
    }

    /// 用 Base URL + API Key 直接拉取 `/models`，拿到可用模型 id 列表。
    func discoverModels(
        baseURL: String,
        apiKey: String,
        apiKeyHeader: String,
        apiKeyPrefix: String,
        modelsPath: String
    ) async -> ModelDiscoveryResult {
        await Self.fetchModelIDs(
            baseURL: baseURL,
            apiKey: apiKey,
            apiKeyHeader: apiKeyHeader,
            apiKeyPrefix: apiKeyPrefix,
            modelsPath: modelsPath,
            session: session
        )
    }

    /// 把选中的模型一次性写成端点（同一 Base URL 下同模型自动跳过重复）。
    @discardableResult
    func addEndpoints(
        baseURL: String,
        apiKey: String,
        apiKeyHeader: String,
        apiKeyPrefix: String,
        chatPath: String,
        healthPath: String,
        models: [String],
        namePrefix: String
    ) -> Int {
        let base = Self.normalizedBaseURL(baseURL)
        guard !base.isEmpty else { return 0 }
        let chat = chatPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let health = healthPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = apiKeyHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = namePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        var added = 0
        for raw in models {
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { continue }
            let exists = configuration.endpoints.contains {
                $0.trimmedBaseURL == base && $0.model == model
            }
            guard !exists else { continue }
            var endpoint = AIEndpoint()
            endpoint.name = prefix.isEmpty ? model : "\(prefix) · \(model)"
            endpoint.baseURL = base
            endpoint.apiKey = apiKey
            endpoint.model = model
            endpoint.apiKeyHeader = header
            endpoint.apiKeyPrefix = apiKeyPrefix
            endpoint.healthPath = health.isEmpty ? "/models" : health
            endpoint.chatPath = chat.isEmpty ? "/chat/completions" : chat
            configuration.endpoints.append(endpoint)
            added += 1
        }
        guard added > 0 else { return 0 }
        configuration = configuration.sanitized
        RouterConfigurationStore.save(configuration)
        reconcileHealth()
        lastError = nil
        probeAllNow()
        return added
    }

    // MARK: - 订阅

    var subscriptionURLsText: String {
        configuration.subscriptions.map { $0.urlString }.joined(separator: "\n")
    }

    func replaceSubscriptions(from text: String) {
        let urls = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var newSubscriptions: [EndpointSubscription] = []
        for url in urls {
            if let existing = configuration.subscriptions.first(where: { $0.urlString == url }) {
                newSubscriptions.append(existing)
            } else {
                newSubscriptions.append(EndpointSubscription(name: URL(string: url)?.host ?? url, urlString: url))
            }
        }
        configuration.subscriptions = newSubscriptions
        RouterConfigurationStore.save(configuration)
        Task { await self.refreshAllSubscriptions() }
    }

    func refreshAllSubscriptions() async {
        guard !configuration.subscriptions.isEmpty else { return }
        isRefreshingSubscriptions = true
        defer { isRefreshingSubscriptions = false }
        let subscriptions = configuration.subscriptions.filter { $0.enabled }
        for subscription in subscriptions {
            await refreshSubscription(id: subscription.id)
        }
    }

    func refreshSubscription(id: UUID) async {
        guard let index = configuration.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let urlString = configuration.subscriptions[index].urlString
        let result = await Self.fetchSubscription(urlString, session: session)
        guard let indexNow = configuration.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        if let data = result.data {
            let parsed = Self.parseSubscription(data, subscriptionID: id)
            if parsed.isEmpty {
                configuration.subscriptions[indexNow].lastError = "订阅内容为空或格式无法识别"
            } else {
                mergeSubscriptionEndpoints(subscriptionID: id, parsed: parsed)
                configuration.subscriptions[indexNow].lastFetched = Date()
                configuration.subscriptions[indexNow].lastError = nil
                RouterConfigurationStore.save(configuration)
                reconcileHealth()
                probeAllNow()
            }
        } else {
            configuration.subscriptions[indexNow].lastError = result.error ?? "订阅刷新失败"
        }
        RouterConfigurationStore.save(configuration)
    }

    private func refreshStaleSubscriptionsIfNeeded() async {
        let staleInterval: TimeInterval = 6 * 60 * 60
        let stale = configuration.subscriptions.filter { subscription in
            guard subscription.enabled else { return false }
            guard let lastFetched = subscription.lastFetched else { return true }
            return Date().timeIntervalSince(lastFetched) > staleInterval
        }
        guard !stale.isEmpty else { return }
        isRefreshingSubscriptions = true
        defer { isRefreshingSubscriptions = false }
        for subscription in stale {
            await refreshSubscription(id: subscription.id)
        }
    }

    private func mergeSubscriptionEndpoints(subscriptionID: UUID, parsed: [AIEndpoint]) {
        let old = configuration.endpoints.filter { $0.subscriptionID == subscriptionID }
        var newEndpoints = parsed
        for index in newEndpoints.indices {
            if let match = old.first(where: {
                $0.trimmedBaseURL == newEndpoints[index].trimmedBaseURL
                    && $0.model == newEndpoints[index].model
                    && $0.apiKey == newEndpoints[index].apiKey
            }) {
                newEndpoints[index].id = match.id
            }
        }
        configuration.endpoints.removeAll { $0.subscriptionID == subscriptionID }
        configuration.endpoints.append(contentsOf: newEndpoints)
        configuration = configuration.sanitized
    }

    // MARK: - 健康探测

    func probeAllNow() {
        Task { await self.probeAll() }
    }

    func probeAll() async {
        // 避免监控循环、保存设置、手动探测同时跑，互相覆盖健康值。
        guard !isProbing else { return }
        let endpoints = configuration.endpoints.filter { $0.enabled }
        guard !endpoints.isEmpty else {
            isProbing = false
            return
        }
        isProbing = true
        let timeout = configuration.probeTimeoutSeconds
        let session = self.session
        var outcomes: [(UUID, ProbeOutcome)] = []
        var index = 0
        let batchSize = 6
        while index < endpoints.count {
            let end = min(index + batchSize, endpoints.count)
            let batch = Array(endpoints[index..<end])
            await withTaskGroup(of: (UUID, ProbeOutcome).self) { group in
                for endpoint in batch {
                    group.addTask {
                        let outcome = await Self.probe(endpoint, timeout: timeout, session: session)
                        return (endpoint.id, outcome)
                    }
                }
                for await pair in group {
                    outcomes.append(pair)
                }
            }
            index = end
        }
        for (id, outcome) in outcomes {
            applyProbeOutcome(endpointID: id, outcome: outcome)
        }
        isProbing = false
    }

    private func applyProbeOutcome(endpointID: UUID, outcome: ProbeOutcome) {
        var item = health[endpointID] ?? .unknown(endpointID)
        item.lastChecked = Date()
        switch outcome {
        case .cancelled:
            // 被取消的探测不算失败，也不改任何健康状态。
            return
        case .healthy(let latency):
            let wasCooling = item.state == .cooling
            if !wasCooling {
                item.state = .healthy
            }
            // 探测延迟只做微调（15%），主要保留真实对话延迟——客户端是非流式的，
            // “答得快不快”取决于整段回答耗时，而不是 /models 的 RTT。
            if let previous = item.latencyMilliseconds {
                item.latencyMilliseconds = Int(Double(previous) * 0.85 + Double(latency) * 0.15)
            } else {
                item.latencyMilliseconds = latency
            }
            item.successCount += 1
            if !wasCooling {
                item.consecutiveFailures = 0
                item.lastError = nil
                item.cooldownUntil = nil
            }
            item.lastSuccess = Date()
        case .auth(let message):
            item.state = .cooling
            item.consecutiveFailures += 1
            item.failureCount += 1
            item.lastError = message
            item.cooldownUntil = Date().addingTimeInterval(600)
        case .unsupported(let message):
            // 很多免费中转站没有 /models；这不代表不能聊天，保持原状态。
            item.lastError = message
        case .failure(let message):
            item.failureCount += 1
            item.consecutiveFailures += 1
            item.lastError = message
            if item.consecutiveFailures >= 2 {
                item.state = .cooling
                item.cooldownUntil = Date().addingTimeInterval(min(300, 15 * Double(item.consecutiveFailures)))
            } else {
                item.state = .degraded
            }
        }
        health[endpointID] = item
    }

    // MARK: - 排名

    func rankedEndpoints() -> [AIEndpoint] {
        let now = Date()
        return configuration.endpoints.filter { $0.enabled }.sorted { lhs, rhs in
            let left = health[lhs.id] ?? .unknown(lhs.id)
            let right = health[rhs.id] ?? .unknown(rhs.id)
            let leftRank = Self.rank(left, now: now)
            let rightRank = Self.rank(right, now: now)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            let leftLatency = left.latencyMilliseconds ?? 9_999
            let rightLatency = right.latencyMilliseconds ?? 9_999
            if leftLatency != rightLatency {
                return leftLatency < rightLatency
            }
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.displayName < rhs.displayName
        }
    }

    func bestEndpoint() -> AIEndpoint? {
        rankedEndpoints().first
    }

    private static func rank(_ item: EndpointHealth, now: Date) -> Int {
        switch item.state {
        case .healthy:
            return 0
        case .unknown:
            return 1
        case .degraded:
            return 2
        case .cooling:
            if let until = item.cooldownUntil, until <= now {
                return 1
            }
            return 3
        case .disabled:
            return 4
        }
    }

    // MARK: - 代理聊天

    func proxyChat(body: Data, incomingHeaders: [String: String]) async -> AIProxyReply {
        let candidates = Array(rankedEndpoints().prefix(configuration.maxRaceEndpoints))
        guard !candidates.isEmpty else {
            return .error("没有启用的 AI 端点")
        }

        let hedgeMilliseconds = configuration.hedgeDelayMilliseconds
        let session = self.session
        var results: [ProxyAttempt] = []

        await withTaskGroup(of: ProxyAttempt.self) { group in
            for (index, endpoint) in candidates.enumerated() {
                group.addTask {
                    if index > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(hedgeMilliseconds * index) * 1_000_000)
                    }
                    if Task.isCancelled {
                        return .cancelled
                    }
                    return await Self.attempt(
                        endpoint: endpoint,
                        body: body,
                        incomingHeaders: incomingHeaders,
                        session: session
                    )
                }
            }
            for await result in group {
                results.append(result)
                if case .success = result {
                    group.cancelAll()
                    break
                }
            }
        }

        var lastMessage = "所有端点均失败"
        for result in results {
            switch result {
            case .success(let reply, let endpoint, let latency):
                recordSuccess(endpoint: endpoint, reply: reply, latency: latency)
                return reply
            case .failure(let endpoint, let message, let latency, let statusCode):
                recordFailure(endpoint: endpoint, message: message, latency: latency, statusCode: statusCode)
                lastMessage = "\(endpoint.displayName)：\(message)"
            case .cancelled:
                break
            }
        }
        return .error(lastMessage)
    }

    private func recordSuccess(endpoint: AIEndpoint, reply: AIProxyReply, latency: Int) {
        var item = health[endpoint.id] ?? .unknown(endpoint.id)
        item.state = .healthy
        if let previous = item.latencyMilliseconds {
            item.latencyMilliseconds = Int(Double(previous) * 0.7 + Double(latency) * 0.3)
        } else {
            item.latencyMilliseconds = latency
        }
        item.successCount += 1
        item.consecutiveFailures = 0
        item.lastChecked = Date()
        item.lastSuccess = Date()
        item.lastError = nil
        item.cooldownUntil = nil
        health[endpoint.id] = item

        lastSelectedEndpoint = endpoint
        let insights = ResponseInsights.extract(from: reply.body)
        lastCompletionModel = insights.model ?? endpoint.displayModel
        lastCompletionTokens = insights.tokensUsed
        requestCount += 1
        successCount += 1
        lastError = nil
        appendLog(
            RouteLog(
                endpointID: endpoint.id,
                endpointName: endpoint.displayName,
                model: lastCompletionModel ?? endpoint.displayModel,
                success: true,
                statusCode: reply.statusCode,
                latencyMilliseconds: latency,
                errorMessage: nil
            )
        )
    }

    private func recordFailure(endpoint: AIEndpoint, message: String, latency: Int, statusCode: Int) {
        var item = health[endpoint.id] ?? .unknown(endpoint.id)
        item.failureCount += 1
        item.consecutiveFailures += 1
        item.lastChecked = Date()
        item.lastError = message
        if statusCode == 401 || statusCode == 403 {
            item.state = .cooling
            item.cooldownUntil = Date().addingTimeInterval(600)
        } else if statusCode == 429 {
            item.state = .cooling
            item.cooldownUntil = Date().addingTimeInterval(60)
        } else {
            item.state = item.consecutiveFailures >= 2 ? .cooling : .degraded
            item.cooldownUntil = Date().addingTimeInterval(min(300, 10 * Double(item.consecutiveFailures)))
        }
        health[endpoint.id] = item
        requestCount += 1
        failureCount += 1
        lastError = message
        appendLog(
            RouteLog(
                endpointID: endpoint.id,
                endpointName: endpoint.displayName,
                model: endpoint.displayModel,
                success: false,
                statusCode: statusCode,
                latencyMilliseconds: latency,
                errorMessage: message
            )
        )
    }

    private func appendLog(_ log: RouteLog) {
        routeLog.insert(log, at: 0)
        if routeLog.count > maximumLogCount {
            routeLog.removeLast(routeLog.count - maximumLogCount)
        }
    }

    // MARK: - 对外状态

    /// 客户端只看到一个模型标识：`auto`（自动选路）。
    func modelsPayload() -> [String: Any] {
        let item: [String: Any] = [
            "id": RouterConfiguration.autoModelID,
            "object": "model",
            "created": 1_767_225_600,
            "owned_by": "localapibridge"
        ]
        return ["object": "list", "data": [item]]
    }

    func statusPayload() -> [String: Any] {
        let endpointItems: [[String: Any]] = configuration.endpoints.map { endpoint in
            let item = health[endpoint.id] ?? .unknown(endpoint.id)
            var payload: [String: Any] = [
                "id": endpoint.id.uuidString,
                "name": endpoint.displayName,
                "model": endpoint.displayModel,
                "base_url": endpoint.trimmedBaseURL,
                "enabled": endpoint.enabled,
                "priority": endpoint.priority,
                "state": item.state.rawValue,
                "latency_ms": item.latencyMilliseconds ?? -1,
                "success": item.successCount,
                "failure": item.failureCount,
                "last_error": item.lastError ?? "",
                "last_checked": Self.isoString(item.lastChecked),
                "cooldown_until": Self.isoString(item.cooldownUntil)
            ]
            if let subscriptionID = endpoint.subscriptionID {
                payload["subscription_id"] = subscriptionID.uuidString
            }
            return payload
        }
        let healthyCount = configuration.endpoints.filter {
            (health[$0.id]?.state ?? .unknown) == .healthy
        }.count
        var payload: [String: Any] = [
            "ok": true,
            "monitoring": configuration.monitoringEnabled,
            "probe_interval_seconds": configuration.probeIntervalSeconds,
            "probe_timeout_seconds": configuration.probeTimeoutSeconds,
            "hedge_delay_ms": configuration.hedgeDelayMilliseconds,
            "max_race_endpoints": configuration.maxRaceEndpoints,
            "endpoint_count": configuration.endpoints.count,
            "healthy_count": healthyCount,
            "request_count": requestCount,
            "success_count": successCount,
            "failure_count": failureCount,
            "endpoints": endpointItems
        ]
        if let best = bestEndpoint() {
            payload["best"] = [
                "id": best.id.uuidString,
                "name": best.displayName,
                "model": best.displayModel,
                "base_url": best.trimmedBaseURL,
                "latency_ms": health[best.id]?.latencyMilliseconds ?? -1
            ]
        }
        return payload
    }

    func bestEndpointPayload() -> [String: Any]? {
        guard let best = bestEndpoint() else { return nil }
        return [
            "id": best.id.uuidString,
            "name": best.displayName,
            "model": best.displayModel,
            "base_url": best.trimmedBaseURL,
            "chat_path": best.normalizedPath(best.chatPath, fallback: "/chat/completions"),
            "latency_ms": health[best.id]?.latencyMilliseconds ?? -1,
            "state": (health[best.id]?.state ?? .unknown).rawValue,
            "proxied_chat_endpoint": "http://127.0.0.1:8787/v1/chat/completions"
        ]
    }

    func pipInfo() -> RouterPiPInfo? {
        guard !configuration.endpoints.isEmpty else { return nil }
        let configuredName = configuration.displayModelName
        let modelName: String
        if !configuredName.isEmpty {
            modelName = configuredName
        } else if let lastCompletionModel, !lastCompletionModel.isEmpty {
            modelName = lastCompletionModel
        } else if let best = bestEndpoint() {
            modelName = best.displayModel
        } else {
            modelName = "未识别"
        }
        return RouterPiPInfo(
            modelName: modelName,
            tokensUsed: lastCompletionTokens,
            contextLimit: configuration.contextLimitTokens
        )
    }

    // MARK: - 健康状态辅助

    private func reconcileHealth() {
        let ids = Set(configuration.endpoints.map { $0.id })
        for key in health.keys where !ids.contains(key) {
            health.removeValue(forKey: key)
        }
        for endpoint in configuration.endpoints where health[endpoint.id] == nil {
            health[endpoint.id] = .unknown(endpoint.id)
        }
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorGeneration += 1
        let generation = monitorGeneration
        monitorTask = Task { [weak self] in
            guard let self else { return }
            await self.probeAll()
            while !Task.isCancelled {
                let interval = self.configuration.probeIntervalSeconds
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
                if Task.isCancelled { break }
                await self.probeAll()
            }
            if self.monitorGeneration == generation {
                self.monitorTask = nil
            }
        }
    }

    private func stopMonitoring() {
        monitorGeneration += 1
        monitorTask?.cancel()
        monitorTask = nil
    }

    // MARK: - 网络请求

    /// 把用户粘贴的各种形态统一成 Base URL：去掉尾部 `/`，并去掉误粘的
    /// `/chat/completions`、`/completions`、`/models` 后缀。
    nonisolated static func normalizedBaseURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        let suffixes = ["/chat/completions", "/completions", "/models"]
        for suffix in suffixes where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
            break
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    nonisolated static func fetchModelIDs(
        baseURL: String,
        apiKey: String,
        apiKeyHeader: String,
        apiKeyPrefix: String,
        modelsPath: String,
        session: URLSession
    ) async -> ModelDiscoveryResult {
        let base = Self.normalizedBaseURL(baseURL)
        let suggestedName = URL(string: base)?.host ?? ""
        guard let parsedBase = URL(string: base),
              let scheme = parsedBase.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              parsedBase.host != nil else {
            return ModelDiscoveryResult(
                models: [],
                error: "Base URL 无效，请填完整地址，例如 https://api.example.com/v1",
                suggestedName: suggestedName
            )
        }
        let rawPath = modelsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix: String
        if rawPath.isEmpty {
            suffix = "/models"
        } else if rawPath.hasPrefix("/") {
            suffix = rawPath
        } else {
            suffix = "/" + rawPath
        }
        guard var components = URLComponents(string: base) else {
            return ModelDiscoveryResult(models: [], error: "模型列表地址无效", suggestedName: suggestedName)
        }
        var basePath = components.path
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        components.path = basePath + suffix
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            return ModelDiscoveryResult(models: [], error: "模型列表地址无效", suggestedName: suggestedName)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let headerName = apiKeyHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            let name = headerName.isEmpty ? "Authorization" : headerName
            request.setValue(apiKeyPrefix + key, forHTTPHeaderField: name)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ModelDiscoveryResult(models: [], error: "非 HTTP 响应", suggestedName: suggestedName)
            }
            guard (200..<300).contains(http.statusCode) else {
                let preview = String(data: data.prefix(200), encoding: .utf8) ?? ""
                return ModelDiscoveryResult(
                    models: [],
                    error: "HTTP \(http.statusCode) \(preview)",
                    suggestedName: suggestedName
                )
            }
            let models = Self.parseModelIDs(data)
            if models.isEmpty {
                return ModelDiscoveryResult(
                    models: [],
                    error: "返回里没找到模型字段（支持 data[].id、models[].id 或字符串数组）",
                    suggestedName: suggestedName
                )
            }
            return ModelDiscoveryResult(models: models, error: nil, suggestedName: suggestedName)
        } catch {
            return ModelDiscoveryResult(models: [], error: error.localizedDescription, suggestedName: suggestedName)
        }
    }

    nonisolated static func parseModelIDs(_ data: Data) -> [String] {
        var ids: [String] = []
        let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let dictionary = object as? [String: Any] {
            if let list = dictionary["data"] as? [[String: Any]] {
                for item in list {
                    if let id = Self.stringValue(item, keys: ["id", "name", "model"]) {
                        ids.append(id)
                    }
                }
            } else if let list = dictionary["models"] as? [[String: Any]] {
                for item in list {
                    if let id = Self.stringValue(item, keys: ["id", "name", "model"]) {
                        ids.append(id)
                    }
                }
            } else if let list = dictionary["data"] as? [String] {
                ids.append(contentsOf: list)
            } else if let list = dictionary["models"] as? [String] {
                ids.append(contentsOf: list)
            } else if let nested = dictionary["data"] as? [String: Any] {
                if let list = nested["models"] as? [[String: Any]] {
                    for item in list {
                        if let id = Self.stringValue(item, keys: ["id", "name", "model"]) {
                            ids.append(id)
                        }
                    }
                }
            }
        } else if let list = object as? [[String: Any]] {
            for item in list {
                if let id = Self.stringValue(item, keys: ["id", "name", "model"]) {
                    ids.append(id)
                }
            }
        } else if let list = object as? [String] {
            ids.append(contentsOf: list)
        }

        var seen = Set<String>()
        var unique: [String] = []
        for raw in ids {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            unique.append(trimmed)
        }
        return unique.sorted()
    }

    private nonisolated static func probe(
        _ endpoint: AIEndpoint,
        timeout: TimeInterval,
        session: URLSession
    ) async -> ProbeOutcome {
        guard let url = endpoint.healthURL else {
            return .unsupported("未配置健康检查路径")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.applyAuth(to: &request, endpoint: endpoint, incomingHeaders: [:])
        for header in endpoint.extraHeaders {
            let key = header.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            request.setValue(header.value, forHTTPHeaderField: key)
        }

        let startedAt = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let latency = Int(Date().timeIntervalSince(startedAt) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return .failure("非 HTTP 响应")
            }
            switch http.statusCode {
            case 200..<300:
                return .healthy(latency)
            case 401, 403:
                return .auth("鉴权失败 HTTP \(http.statusCode)")
            case 404, 405:
                return .unsupported("健康检查路径不支持 HTTP \(http.statusCode)")
            default:
                return .failure("HTTP \(http.statusCode)")
            }
        } catch {
            if Task.isCancelled || (error as NSError).code == NSURLErrorCancelled {
                return .cancelled
            }
            return .failure(error.localizedDescription)
        }
    }

    private nonisolated static func attempt(
        endpoint: AIEndpoint,
        body: Data,
        incomingHeaders: [String: String],
        session: URLSession
    ) async -> ProxyAttempt {
        guard let url = endpoint.chatURL else {
            return .failure(endpoint, "chat URL 无效", 0, 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.applyAuth(to: &request, endpoint: endpoint, incomingHeaders: incomingHeaders)
        for header in endpoint.extraHeaders {
            let key = header.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            request.setValue(header.value, forHTTPHeaderField: key)
        }
        request.httpBody = Self.rewriteBody(body, model: endpoint.model)

        let startedAt = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let latency = Int(Date().timeIntervalSince(startedAt) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return .failure(endpoint, "非 HTTP 响应", latency, 0)
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "application/json; charset=utf-8"
            if (200..<300).contains(http.statusCode) {
                return .success(
                    AIProxyReply(
                        statusCode: http.statusCode,
                        contentType: contentType,
                        body: data,
                        headers: [:]
                    ),
                    endpoint,
                    latency
                )
            }
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? ""
            return .failure(endpoint, "HTTP \(http.statusCode) \(preview)", latency, http.statusCode)
        } catch {
            let latency = Int(Date().timeIntervalSince(startedAt) * 1000)
            return .failure(endpoint, error.localizedDescription, latency, 0)
        }
    }

    private nonisolated static func applyAuth(
        to request: inout URLRequest,
        endpoint: AIEndpoint,
        incomingHeaders: [String: String]
    ) {
        let key = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let headerName = endpoint.apiKeyHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, !headerName.isEmpty {
            request.setValue(endpoint.apiKeyPrefix + key, forHTTPHeaderField: headerName)
            return
        }
        if let authorization = incomingHeaders["authorization"], !authorization.isEmpty {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        } else if let apiKey = incomingHeaders["x-api-key"], !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
    }

    private nonisolated static func rewriteBody(_ body: Data, model: String) -> Data {
        guard !body.isEmpty else { return body }
        guard let raw = try? JSONSerialization.jsonObject(with: body),
              var object = raw as? [String: Any] else {
            return body
        }
        let requested = (object["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.isEmpty {
            object["model"] = target
        } else if requested.isEmpty || requested.caseInsensitiveCompare(RouterConfiguration.autoModelID) == .orderedSame {
            // 客户端选了“自动”但这个端点没固定模型：交给上游默认模型。
            object.removeValue(forKey: "model")
        }
        // 本地代理先统一走非流式，拿到完整 JSON 后一次性返回。
        object["stream"] = false
        return (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? body
    }

    private nonisolated static func fetchSubscription(
        _ urlString: String,
        session: URLSession
    ) async -> (data: Data?, error: String?) {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return (nil, "订阅地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (nil, "非 HTTP 响应")
            }
            guard (200..<300).contains(http.statusCode) else {
                return (nil, "订阅返回 HTTP \(http.statusCode)")
            }
            return (data, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    // MARK: - 订阅解析

    private nonisolated static func parseSubscription(_ data: Data, subscriptionID: UUID) -> [AIEndpoint] {
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            let parsed = endpoints(fromJSON: object, subscriptionID: subscriptionID)
            if !parsed.isEmpty {
                return parsed
            }
        }
        if let text = String(data: data, encoding: .utf8) {
            return endpoints(fromLines: text, subscriptionID: subscriptionID)
        }
        return []
    }

    private nonisolated static func endpoints(fromJSON object: Any, subscriptionID: UUID?) -> [AIEndpoint] {
        var dictionaries: [[String: Any]] = []
        if let array = object as? [[String: Any]] {
            dictionaries = array
        } else if let dictionary = object as? [String: Any] {
            if let array = dictionary["endpoints"] as? [[String: Any]] {
                dictionaries = array
            } else if let array = dictionary["data"] as? [[String: Any]] {
                dictionaries = array
            } else if dictionary["base_url"] != nil || dictionary["baseURL"] != nil || dictionary["url"] != nil {
                dictionaries = [dictionary]
            }
        }
        var result: [AIEndpoint] = []
        for dictionary in dictionaries {
            result.append(contentsOf: endpointList(from: dictionary, subscriptionID: subscriptionID))
        }
        return result
    }

    private nonisolated static func endpointList(
        from dictionary: [String: Any],
        subscriptionID: UUID?
    ) -> [AIEndpoint] {
        guard let base = stringValue(dictionary, keys: ["base_url", "baseURL", "url", "api_base", "endpoint"]) else {
            return []
        }
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedBase), url.scheme != nil, url.host != nil else {
            return []
        }
        let apiKey = stringValue(dictionary, keys: ["api_key", "apiKey", "key", "token", "auth_token"]) ?? ""
        let apiKeyHeader = stringValue(dictionary, keys: ["api_key_header", "auth_header", "key_header"]) ?? "Authorization"
        let apiKeyPrefix = stringValue(dictionary, keys: ["api_key_prefix", "auth_prefix", "key_prefix"]) ?? "Bearer "
        let healthPath = stringValue(dictionary, keys: ["health_path", "healthPath", "models_path"]) ?? "/models"
        let chatPath = stringValue(dictionary, keys: ["chat_path", "chatPath", "completions_path"]) ?? "/chat/completions"
        let name = stringValue(dictionary, keys: ["name", "title", "provider", "label"]) ?? (url.host ?? "端点")
        let priority = intValue(dictionary, keys: ["priority", "weight"]) ?? 100
        let enabled = boolValue(dictionary, keys: ["enabled", "active"]) ?? true

        var headers: [HeaderPair] = []
        if let headerDictionary = dictionary["headers"] as? [String: Any] {
            for (key, value) in headerDictionary {
                if let text = value as? String, !key.isEmpty {
                    headers.append(HeaderPair(key: key, value: text))
                }
            }
        } else if let headerArray = dictionary["headers"] as? [[String: Any]] {
            for item in headerArray {
                if let key = stringValue(item, keys: ["key", "name"]),
                   let value = stringValue(item, keys: ["value"]) {
                    headers.append(HeaderPair(key: key, value: value))
                }
            }
        }

        var models: [String] = []
        if let modelArray = dictionary["models"] as? [String] {
            models = modelArray
        } else if let modelArray = dictionary["models"] as? [[String: Any]] {
            models = modelArray.compactMap { stringValue($0, keys: ["id", "name", "model"]) }
        } else if let modelText = dictionary["models"] as? String {
            models = modelText.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let singleModel = stringValue(dictionary, keys: ["model", "model_name", "default_model"]) {
            models = [singleModel]
        }
        models = models.filter { !$0.isEmpty }
        if models.isEmpty {
            models = [""]
        }

        return models.map { model in
            AIEndpoint(
                name: name,
                baseURL: trimmedBase,
                apiKey: apiKey,
                model: model,
                apiKeyHeader: apiKeyHeader,
                apiKeyPrefix: apiKeyPrefix,
                healthPath: healthPath,
                chatPath: chatPath,
                extraHeaders: headers,
                enabled: enabled,
                priority: priority,
                subscriptionID: subscriptionID
            )
        }
    }

    private nonisolated static func endpoints(fromLines text: String, subscriptionID: UUID?) -> [AIEndpoint] {
        var result: [AIEndpoint] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let parts: [String]
            if line.contains("|") {
                parts = line.split(separator: "|", omittingEmptySubsequences: false).map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else {
                parts = line.split(separator: ",").map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            guard !parts.isEmpty else { continue }

            var name = ""
            var base = ""
            var key = ""
            var model = ""
            if parts.count >= 4 {
                name = parts[0]
                base = parts[1]
                key = parts[2]
                model = parts[3]
            } else if parts.count == 3 {
                base = parts[0]
                key = parts[1]
                model = parts[2]
            } else if parts.count == 2 {
                base = parts[0]
                key = parts[1]
            } else {
                base = parts[0]
            }
            guard let url = URL(string: base), url.scheme != nil, url.host != nil else {
                continue
            }
            result.append(
                AIEndpoint(
                    name: name.isEmpty ? (url.host ?? "端点") : name,
                    baseURL: base,
                    apiKey: key,
                    model: model,
                    subscriptionID: subscriptionID
                )
            )
        }
        return result
    }

    private nonisolated static func stringValue(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private nonisolated static func intValue(_ dictionary: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = dictionary[key] as? Int {
                return value
            }
            if let value = dictionary[key] as? NSNumber {
                return value.intValue
            }
            if let value = dictionary[key] as? String, let number = Int(value) {
                return number
            }
        }
        return nil
    }

    private nonisolated static func boolValue(_ dictionary: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dictionary[key] as? Bool {
                return value
            }
            if let value = dictionary[key] as? String {
                let lowered = value.lowercased()
                if lowered == "true" || lowered == "yes" || lowered == "1" {
                    return true
                }
                if lowered == "false" || lowered == "no" || lowered == "0" {
                    return false
                }
            }
        }
        return nil
    }

    private nonisolated static func isoString(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}