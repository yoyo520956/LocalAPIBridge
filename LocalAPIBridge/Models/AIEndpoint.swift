import Foundation

/// 一个可轮询 / 可被代理的 AI API 端点。
struct AIEndpoint: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var name: String
    var baseURL: String
    var apiKey: String
    var model: String
    var apiKeyHeader: String
    var apiKeyPrefix: String
    var healthPath: String
    var chatPath: String
    var extraHeaders: [HeaderPair]
    var enabled: Bool
    var priority: Int
    var subscriptionID: UUID?

    init(
        id: UUID = UUID(),
        name: String = "",
        baseURL: String = "",
        apiKey: String = "",
        model: String = "",
        apiKeyHeader: String = "Authorization",
        apiKeyPrefix: String = "Bearer ",
        healthPath: String = "/models",
        chatPath: String = "/chat/completions",
        extraHeaders: [HeaderPair] = [],
        enabled: Bool = true,
        priority: Int = 100,
        subscriptionID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.apiKeyHeader = apiKeyHeader
        self.apiKeyPrefix = apiKeyPrefix
        self.healthPath = healthPath
        self.chatPath = chatPath
        self.extraHeaders = extraHeaders
        self.enabled = enabled
        self.priority = priority
        self.subscriptionID = subscriptionID
    }

    var trimmedBaseURL: String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return URL(string: trimmedBaseURL)?.host ?? "未命名端点"
    }

    var displayModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "auto" : trimmed
    }

    func normalizedPath(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    var chatURL: URL? {
        URL(string: trimmedBaseURL + normalizedPath(chatPath, fallback: "/chat/completions"))
    }

    var healthURL: URL? {
        let trimmed = healthPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmedBaseURL + normalizedPath(trimmed, fallback: "/models"))
    }
}

/// 一个订阅地址，内容可以是 JSON 端点列表，也可以是逐行文本。
struct EndpointSubscription: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var urlString: String
    var enabled: Bool
    var lastFetched: Date?
    var lastError: String?

    init(
        id: UUID = UUID(),
        name: String = "",
        urlString: String = "",
        enabled: Bool = true,
        lastFetched: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.enabled = enabled
        self.lastFetched = lastFetched
        self.lastError = lastError
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return URL(string: urlString)?.host ?? urlString
    }
}

enum EndpointHealthState: String, Codable, Equatable, Sendable {
    case unknown
    case healthy
    case degraded
    case cooling
    case disabled

    var title: String {
        switch self {
        case .unknown: return "未探测"
        case .healthy: return "可用"
        case .degraded: return "降级"
        case .cooling: return "冷却中"
        case .disabled: return "已停用"
        }
    }
}

struct EndpointHealth: Identifiable {
    var endpointID: UUID
    var state: EndpointHealthState
    var latencyMilliseconds: Int?
    var consecutiveFailures: Int
    var successCount: Int
    var failureCount: Int
    var lastChecked: Date?
    var lastSuccess: Date?
    var lastError: String?
    var cooldownUntil: Date?

    var id: UUID { endpointID }

    static func unknown(_ endpointID: UUID) -> EndpointHealth {
        EndpointHealth(
            endpointID: endpointID,
            state: .unknown,
            latencyMilliseconds: nil,
            consecutiveFailures: 0,
            successCount: 0,
            failureCount: 0,
            lastChecked: nil,
            lastSuccess: nil,
            lastError: nil,
            cooldownUntil: nil
        )
    }
}

struct RouteLog: Identifiable, Codable, Equatable {
    var id: UUID
    var date: Date
    var endpointID: UUID
    var endpointName: String
    var model: String
    var success: Bool
    var statusCode: Int
    var latencyMilliseconds: Int
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        endpointID: UUID,
        endpointName: String,
        model: String,
        success: Bool,
        statusCode: Int,
        latencyMilliseconds: Int,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.date = date
        self.endpointID = endpointID
        self.endpointName = endpointName
        self.model = model
        self.success = success
        self.statusCode = statusCode
        self.latencyMilliseconds = latencyMilliseconds
        self.errorMessage = errorMessage
    }
}

struct RouterConfiguration: Codable, Equatable {
    var endpoints: [AIEndpoint]
    var subscriptions: [EndpointSubscription]
    var probeIntervalSeconds: Double
    var probeTimeoutSeconds: Double
    var hedgeDelayMilliseconds: Int
    var maxRaceEndpoints: Int
    var contextLimitTokens: Int
    var displayModelName: String
    var monitoringEnabled: Bool

    init() {
        endpoints = []
        subscriptions = []
        probeIntervalSeconds = 30
        probeTimeoutSeconds = 2
        hedgeDelayMilliseconds = 200
        maxRaceEndpoints = 3
        contextLimitTokens = 128_000
        displayModelName = ""
        monitoringEnabled = true
    }

    var sanitized: RouterConfiguration {
        var copy = self
        copy.probeIntervalSeconds = probeIntervalSeconds.isFinite
            ? min(max(probeIntervalSeconds, 5), 3_600)
            : 30
        copy.probeTimeoutSeconds = probeTimeoutSeconds.isFinite
            ? min(max(probeTimeoutSeconds, 0.5), 30)
            : 2
        copy.hedgeDelayMilliseconds = min(max(hedgeDelayMilliseconds, 50), 2_000)
        copy.maxRaceEndpoints = min(max(maxRaceEndpoints, 1), 5)
        copy.contextLimitTokens = min(max(contextLimitTokens, 100), 10_000_000)
        copy.displayModelName = displayModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.endpoints = endpoints.map { endpoint in
            var item = endpoint
            item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            item.baseURL = item.trimmedBaseURL
            item.apiKey = item.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            item.model = item.model.trimmingCharacters(in: .whitespacesAndNewlines)
            item.apiKeyHeader = item.apiKeyHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.apiKeyHeader.isEmpty {
                item.apiKeyHeader = "Authorization"
            }
            item.extraHeaders = item.extraHeaders.compactMap { header in
                let key = header.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }
                return HeaderPair(id: header.id, key: key, value: header.value)
            }
            item.priority = min(max(item.priority, 0), 10_000)
            return item
        }
        copy.subscriptions = subscriptions.map { subscription in
            var item = subscription
            item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            item.urlString = item.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            return item
        }
        return copy
    }
}