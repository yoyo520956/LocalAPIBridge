import Foundation

/// 轮询引擎与本地 HTTP 服务之间共享的一份线程安全状态。
/// 引擎在主线程写入，HTTP 服务在自己的队列里读取。
final class BridgeStore: @unchecked Sendable {
    struct Snapshot {
        var latestData: Data?
        var latestContentType: String
        var latestRecord: PollRecord?
        var lastSuccessAt: Date?
        var history: [PollRecord]
        var pollCount: Int
        var successCount: Int
        var failureCount: Int
        var lastError: String?
        var isPollingActive: Bool
        var intervalSeconds: Double
        var nextPollDate: Date?
        var accessToken: String
        var upstreamURL: String
        var upstreamMethod: String
        var serverRunning: Bool
        var serverPort: Int
        var startedAt: Date?
        var updatedAt: Date?

        init() {
            latestData = nil
            latestContentType = "application/octet-stream"
            latestRecord = nil
            lastSuccessAt = nil
            history = []
            pollCount = 0
            successCount = 0
            failureCount = 0
            lastError = nil
            isPollingActive = false
            intervalSeconds = 60
            nextPollDate = nil
            accessToken = ""
            upstreamURL = ""
            upstreamMethod = "GET"
            serverRunning = false
            serverPort = 8787
            startedAt = nil
            updatedAt = nil
        }
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()

    func read() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// 注意：闭包内不要再次调用 read()/update()，NSLock 不可重入。
    func update(_ block: (inout Snapshot) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        block(&snapshot)
    }
}

extension BridgeStore.Snapshot {
    /// 只用于状态页展示的主机名。
    var upstreamHost: String {
        guard let host = URL(string: upstreamURL)?.host, !host.isEmpty else {
            return upstreamURL
        }
        return host
    }
}
