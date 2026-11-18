import Foundation

/// 上游接口使用的 HTTP 方法。
enum HTTPMethodOption: String, CaseIterable, Codable, Identifiable, Hashable {
    case get = "GET"
    case post = "POST"

    var id: String { rawValue }
}

/// 一条自定义请求头。
struct HeaderPair: Identifiable, Codable, Hashable {
    var id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

/// 轮询与本地服务的完整配置。
struct PollConfiguration: Codable, Equatable {
    var name: String
    var urlString: String
    var method: HTTPMethodOption
    var headers: [HeaderPair]
    var body: String
    var intervalSeconds: Double
    var timeoutSeconds: Double
    var serverPort: Int
    var accessToken: String
    var enabled: Bool
    var displayModelName: String
    var contextLimitTokens: Int

    enum CodingKeys: String, CodingKey {
        case name
        case urlString
        case method
        case headers
        case body
        case intervalSeconds
        case timeoutSeconds
        case serverPort
        case accessToken
        case enabled
        case displayModelName
        case contextLimitTokens
    }

    init() {
        name = "我的免费 API"
        urlString = "https://api.open-meteo.com/v1/forecast?latitude=39.9042&longitude=116.4074&current=temperature_2m,relative_humidity_2m,wind_speed_10m"
        method = .get
        headers = [HeaderPair(key: "Accept", value: "application/json")]
        body = ""
        intervalSeconds = 60
        timeoutSeconds = 15
        serverPort = 8787
        accessToken = ""
        enabled = true
        displayModelName = ""
        contextLimitTokens = 128_000
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "我的免费 API"
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString)
            ?? "https://api.open-meteo.com/v1/forecast?latitude=39.9042&longitude=116.4074&current=temperature_2m,relative_humidity_2m,wind_speed_10m"
        method = try container.decodeIfPresent(HTTPMethodOption.self, forKey: .method) ?? .get
        headers = try container.decodeIfPresent([HeaderPair].self, forKey: .headers)
            ?? [HeaderPair(key: "Accept", value: "application/json")]
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        intervalSeconds = try container.decodeIfPresent(Double.self, forKey: .intervalSeconds) ?? 60
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 15
        serverPort = try container.decodeIfPresent(Int.self, forKey: .serverPort) ?? 8787
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        displayModelName = try container.decodeIfPresent(String.self, forKey: .displayModelName) ?? ""
        contextLimitTokens = try container.decodeIfPresent(Int.self, forKey: .contextLimitTokens) ?? 128_000
    }

    var trimmedURLString: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 只有完整的 http/https 地址才算有效。
    var validatedURL: URL? {
        guard let url = URL(string: trimmedURLString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    var normalizedInterval: Double {
        guard intervalSeconds.isFinite else { return 60 }
        return min(max(intervalSeconds, 2), 86_400)
    }

    var normalizedTimeout: Double {
        guard timeoutSeconds.isFinite else { return 15 }
        return min(max(timeoutSeconds, 3), 120)
    }

    var normalizedPort: Int {
        min(max(serverPort, 1024), 65_535)
    }

    var normalizedContextLimit: Int {
        min(max(contextLimitTokens, 100), 10_000_000)
    }

    /// 清洗后的配置：范围收敛、去掉空请求头、令牌去空格。
    var sanitized: PollConfiguration {
        var copy = self
        copy.intervalSeconds = normalizedInterval
        copy.timeoutSeconds = normalizedTimeout
        copy.serverPort = normalizedPort
        copy.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.displayModelName = displayModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.contextLimitTokens = normalizedContextLimit
        copy.urlString = trimmedURLString
        copy.headers = headers.map { header in
            HeaderPair(
                id: header.id,
                key: header.key.trimmingCharacters(in: .whitespacesAndNewlines),
                value: header.value
            )
        }
        return copy
    }

    var displayHost: String {
        if let host = URL(string: trimmedURLString)?.host, !host.isEmpty {
            return host
        }
        return trimmedURLString
    }
}
