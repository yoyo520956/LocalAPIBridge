import Foundation

/// 配置持久化（UserDefaults）。
enum ConfigurationStore {
    private static let storageKey = "localapibridge.configuration.v1"

    static func load() -> PollConfiguration {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return PollConfiguration()
        }
        return (try? JSONDecoder().decode(PollConfiguration.self, from: data)) ?? PollConfiguration()
    }

    static func save(_ configuration: PollConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

/// 轮询历史持久化（Application Support 下的 JSON 文件）。
enum HistoryStore {
    static let maximumCount = 100
    static let maximumBodyCharacters = 6_000
    /// 最多每 20 秒落盘一次，避免频繁写闪存。
    private static let minimumSaveInterval: TimeInterval = 20
    private static let saveLock = NSLock()
    private static var lastSaveTime = Date.distantPast

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base.appendingPathComponent("localapibridge-history.json")
    }

    static func load() -> [PollRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PollRecord].self, from: data)) ?? []
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 编码和磁盘写入都放到后台队列，并限制写盘频率。
    static func save(_ records: [PollRecord]) {
        saveLock.lock()
        let now = Date()
        if now.timeIntervalSince(lastSaveTime) < minimumSaveInterval {
            saveLock.unlock()
            return
        }
        lastSaveTime = now
        saveLock.unlock()

        let trimmed = Array(records.prefix(maximumCount))
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(trimmed) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
/// 累计轮询次数统计（历史记录只有最近 100 条，累计值需要用 UserDefaults 单独保存）。
enum StatsStore {
    private static let pollsKey = "localapibridge.stats.polls"
    private static let successesKey = "localapibridge.stats.successes"
    private static let failuresKey = "localapibridge.stats.failures"

    static func load() -> (polls: Int, successes: Int, failures: Int) {
        let defaults = UserDefaults.standard
        return (
            defaults.integer(forKey: pollsKey),
            defaults.integer(forKey: successesKey),
            defaults.integer(forKey: failuresKey)
        )
    }

    static func save(polls: Int, successes: Int, failures: Int) {
        let defaults = UserDefaults.standard
        defaults.set(polls, forKey: pollsKey)
        defaults.set(successes, forKey: successesKey)
        defaults.set(failures, forKey: failuresKey)
    }
}

/// 最近一次成功响应（用于 App 重启后立刻提供 /latest，不必等第一次轮询）。
struct LatestResponseSnapshot {
    let data: Data
    let contentType: String
    let date: Date
    let statusCode: Int
    let durationMilliseconds: Int
    let url: String
    let method: String
}

enum LatestResponseStore {
    private static let maximumBytes = 2_000_000
    private static let minimumSaveInterval: TimeInterval = 15
    private static let lock = NSLock()
    private static var lastSaveTime = Date.distantPast

    private struct Metadata: Codable {
        var contentType: String
        var date: Date
        var statusCode: Int?
        var durationMilliseconds: Int?
        var url: String?
        var method: String?
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    private static var dataURL: URL {
        directory.appendingPathComponent("localapibridge-latest.bin")
    }

    private static var metadataURL: URL {
        directory.appendingPathComponent("localapibridge-latest.json")
    }

    static func load() -> LatestResponseSnapshot? {
        guard let data = try? Data(contentsOf: dataURL),
              let metadataData = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataData) else {
            return nil
        }
        return LatestResponseSnapshot(
            data: data,
            contentType: metadata.contentType,
            date: metadata.date,
            statusCode: metadata.statusCode ?? 200,
            durationMilliseconds: metadata.durationMilliseconds ?? 0,
            url: metadata.url ?? "",
            method: metadata.method ?? ""
        )
    }

    static func save(
        data: Data,
        contentType: String,
        date: Date,
        statusCode: Int,
        durationMilliseconds: Int,
        url: String,
        method: String
    ) {
        guard data.count <= maximumBytes else { return }

        lock.lock()
        let now = Date()
        if now.timeIntervalSince(lastSaveTime) < minimumSaveInterval {
            lock.unlock()
            return
        }
        lastSaveTime = now
        lock.unlock()

        let metadata = Metadata(
            contentType: contentType,
            date: date,
            statusCode: statusCode,
            durationMilliseconds: durationMilliseconds,
            url: url,
            method: method
        )
        DispatchQueue.global(qos: .utility).async {
            guard let metadataData = try? JSONEncoder().encode(metadata) else { return }
            try? data.write(to: dataURL, options: .atomic)
            try? metadataData.write(to: metadataURL, options: .atomic)
        }
    }

    static func clear() {
        lock.lock()
        lastSaveTime = Date.distantPast
        lock.unlock()
        try? FileManager.default.removeItem(at: dataURL)
        try? FileManager.default.removeItem(at: metadataURL)
    }
}

/// AI 多端点路由配置持久化。
enum RouterConfigurationStore {
    private static let storageKey = "localapibridge.router.v1"

    static func load() -> RouterConfiguration {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return RouterConfiguration()
        }
        return (try? JSONDecoder().decode(RouterConfiguration.self, from: data)) ?? RouterConfiguration()
    }

    static func save(_ configuration: RouterConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
