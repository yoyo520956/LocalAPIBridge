import Combine
import Foundation

/// 轮询核心：按固定间隔请求上游接口，把结果写进共享状态，供 UI 和本地 HTTP 服务使用。
@MainActor
final class PollingEngine: ObservableObject {
    @Published private(set) var configuration: PollConfiguration
    @Published private(set) var isPolling: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var latestRecord: PollRecord?
    @Published private(set) var history: [PollRecord] = []
    @Published private(set) var nextPollDate: Date?
    @Published private(set) var serverState: LocalServerState = .stopped
    @Published private(set) var addresses: [String] = []
    @Published private(set) var preferredLANAddress: String?
    @Published private(set) var lastError: String?
    @Published private(set) var pollCount: Int = 0
    @Published private(set) var successCount: Int = 0
    @Published private(set) var failureCount: Int = 0

    let store = BridgeStore()

    private let session: URLSession
    private var server: LocalHTTPServer?
    private var loopTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var loopGeneration = 0
    private var pendingTrigger: String?
    private var didBootstrap = false
    private let serviceName = "LocalAPIBridge"

    init() {
        configuration = ConfigurationStore.load()

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 120
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.httpAdditionalHeaders = ["User-Agent": "LocalAPIBridge/1.0 (iOS)"]
        session = URLSession(configuration: sessionConfiguration)
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        history = HistoryStore.load().filter { record in
            record.sourceURL.isEmpty || record.sourceURL == self.configuration.trimmedURLString
        }
        latestRecord = history.first

        let cachedLatest = LatestResponseStore.load()
        if latestRecord == nil,
           let cachedLatest,
           cachedLatest.url == configuration.trimmedURLString,
           cachedLatest.method == configuration.method.rawValue {
            let previewData = Data(cachedLatest.data.prefix(HistoryStore.maximumBodyCharacters))
            let cachedInsights = ResponseInsights.extract(from: cachedLatest.data)
            latestRecord = PollRecord(
                date: cachedLatest.date,
                success: true,
                statusCode: cachedLatest.statusCode,
                durationMilliseconds: cachedLatest.durationMilliseconds,
                contentType: cachedLatest.contentType,
                byteCount: cachedLatest.data.count,
                bodyText: String(data: previewData, encoding: .utf8) ?? "",
                errorMessage: nil,
                trigger: "cache",
                sourceURL: cachedLatest.url,
                modelName: cachedInsights.model,
                tokensUsed: cachedInsights.tokensUsed
            )
        }
        let stats = StatsStore.load()
        if stats.polls > 0 {
            pollCount = stats.polls
            successCount = stats.successes
            failureCount = stats.failures
        } else {
            pollCount = history.count
            successCount = history.filter { $0.success }.count
            failureCount = history.count - successCount
        }

        store.update { snapshot in
            snapshot.history = self.history
            snapshot.latestRecord = self.latestRecord
            snapshot.pollCount = self.pollCount
            snapshot.successCount = self.successCount
            snapshot.failureCount = self.failureCount
            snapshot.accessToken = self.configuration.accessToken
            snapshot.intervalSeconds = self.configuration.normalizedInterval
            snapshot.upstreamURL = self.configuration.trimmedURLString
            snapshot.upstreamMethod = self.configuration.method.rawValue
            snapshot.serverPort = self.configuration.normalizedPort
            snapshot.isPollingActive = self.configuration.enabled
            snapshot.startedAt = Date()
            if let cachedLatest,
               cachedLatest.url == self.configuration.trimmedURLString,
               cachedLatest.method == self.configuration.method.rawValue {
                snapshot.latestData = cachedLatest.data
                snapshot.latestContentType = cachedLatest.contentType
                snapshot.lastSuccessAt = cachedLatest.date
            }
        }

        if server == nil {
            server = makeServer()
        }
        serverState = .starting
        server?.start(port: configuration.normalizedPort, serviceName: serviceName)
        refreshAddresses()

        if configuration.enabled {
            startPollingLoop(immediate: true)
        } else {
            isPaused = true
            isPolling = false
        }
    }

    // MARK: - 配置

    func apply(_ newConfiguration: PollConfiguration) {
        let sanitized = newConfiguration.sanitized
        let oldConfiguration = configuration
        let oldPort = oldConfiguration.normalizedPort
        let endpointChanged = sanitized.trimmedURLString != oldConfiguration.trimmedURLString
            || sanitized.method != oldConfiguration.method
        let upstreamChanged = endpointChanged
            || headerSignature(sanitized.headers) != headerSignature(oldConfiguration.headers)
            || sanitized.body != oldConfiguration.body
        let intervalChanged = sanitized.normalizedInterval != oldConfiguration.normalizedInterval
        let enabledChanged = sanitized.enabled != oldConfiguration.enabled
        configuration = sanitized
        ConfigurationStore.save(sanitized)

        store.update { snapshot in
            snapshot.accessToken = sanitized.accessToken
            snapshot.intervalSeconds = sanitized.normalizedInterval
            snapshot.upstreamURL = sanitized.trimmedURLString
            snapshot.upstreamMethod = sanitized.method.rawValue
            snapshot.serverPort = sanitized.normalizedPort
        }

        if upstreamChanged {
            // 换了上游 / 请求头 / 请求体，就不能继续把旧结果当成本接口的数据返回。
            pollTask?.cancel()
            pollTask = nil
            latestRecord = nil
            lastError = nil
            LatestResponseStore.clear()
            if endpointChanged {
                history = []
                HistoryStore.clear()
            }
            store.update { snapshot in
                snapshot.latestData = nil
                snapshot.latestContentType = "application/octet-stream"
                snapshot.lastSuccessAt = nil
                snapshot.latestRecord = nil
                snapshot.lastError = nil
                if endpointChanged {
                    snapshot.history = []
                }
            }
        }

        var shouldRestartServer = sanitized.normalizedPort != oldPort
        if case .failed(_) = serverState {
            shouldRestartServer = true
        }
        if shouldRestartServer {
            serverState = .starting
            server?.restart(port: sanitized.normalizedPort, serviceName: serviceName)
        }

        if sanitized.enabled {
            if endpointChanged || upstreamChanged || enabledChanged {
                startPollingLoop(immediate: true)
            } else if intervalChanged {
                startPollingLoop(immediate: false)
            } else if !isPaused, loopTask == nil {
                startPollingLoop(immediate: true)
            }
        } else {
            pausePolling()
        }
        refreshAddresses()
    }

    private func headerSignature(_ headers: [HeaderPair]) -> [String: String] {
        var result: [String: String] = [:]
        for header in headers {
            let key = header.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            result[key] = header.value
        }
        return result
    }

    // MARK: - 轮询循环

    private func startPollingLoop(immediate: Bool) {
        loopGeneration += 1
        let generation = loopGeneration
        loopTask?.cancel()
        isPaused = false
        isPolling = true
        store.update { $0.isPollingActive = true }

        loopTask = Task { [weak self] in
            guard let self else { return }

            if immediate {
                self.pollNow(trigger: "start")
            }

            while !Task.isCancelled {
                let wait = self.configuration.normalizedInterval
                let next = Date().addingTimeInterval(wait)
                self.nextPollDate = next
                self.store.update { $0.nextPollDate = next }

                do {
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                } catch {
                    break
                }
                if Task.isCancelled { break }

                self.nextPollDate = nil
                self.store.update { $0.nextPollDate = nil }
                self.pollNow(trigger: "timer")
            }

            if self.loopGeneration == generation {
                self.isPolling = false
                self.loopTask = nil
            }
        }
    }

    func pausePolling() {
        loopGeneration += 1
        loopTask?.cancel()
        loopTask = nil
        isPolling = false
        isPaused = true
        nextPollDate = nil
        store.update { snapshot in
            snapshot.isPollingActive = false
            snapshot.nextPollDate = nil
        }
    }

    func resumePolling() {
        guard configuration.enabled else { return }
        startPollingLoop(immediate: true)
    }

    func pollNow(trigger: String = "manual") {
        pollTask = Task { await self.performPoll(trigger: trigger) }
    }

    private func performPoll(trigger: String) async {
        if isRefreshing {
            if pendingTrigger == nil {
                pendingTrigger = trigger
            }
            return
        }
        guard let url = configuration.validatedURL else {
            lastError = "URL 无效：请在设置里填写完整的 http(s) 地址"
            store.update { $0.lastError = "URL 无效：请在设置里填写完整的 http(s) 地址" }
            return
        }
        isRefreshing = true
        let upstreamURL = configuration.trimmedURLString
        let upstreamMethod = configuration.method.rawValue
        defer {
            isRefreshing = false
            if let nextTrigger = pendingTrigger {
                pendingTrigger = nil
                self.pollTask = Task { await self.performPoll(trigger: nextTrigger) }
            }
        }

        let startedAt = Date()
        var request = URLRequest(url: url)
        request.httpMethod = configuration.method.rawValue
        request.timeoutInterval = configuration.normalizedTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        for header in configuration.headers {
            let key = header.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            request.setValue(header.value, forHTTPHeaderField: key)
        }
        if configuration.method == .post, !configuration.body.isEmpty {
            request.httpBody = Data(configuration.body.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        do {
            let (data, response) = try await session.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0
            let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            let success = (200..<300).contains(statusCode)
            let duration = Int(Date().timeIntervalSince(startedAt) * 1000)
            let bodyText: String
            if let text = String(data: data, encoding: .utf8) {
                bodyText = String(text.prefix(HistoryStore.maximumBodyCharacters))
            } else {
                bodyText = "（二进制数据，\(data.count) 字节）"
            }
            let insights = ResponseInsights.extract(from: data)
            let record = PollRecord(
                success: success,
                statusCode: statusCode,
                durationMilliseconds: duration,
                contentType: contentType,
                byteCount: data.count,
                bodyText: bodyText,
                errorMessage: success ? nil : "上游返回 HTTP \(statusCode)",
                trigger: trigger,
                sourceURL: upstreamURL,
                modelName: insights.model,
                tokensUsed: insights.tokensUsed
            )
            apply(
                record: record,
                data: data,
                contentType: contentType,
                sourceURL: upstreamURL,
                sourceMethod: upstreamMethod
            )
        } catch {
            if Task.isCancelled || isCancellation(error) {
                return
            }
            let duration = Int(Date().timeIntervalSince(startedAt) * 1000)
            let record = PollRecord(
                success: false,
                statusCode: 0,
                durationMilliseconds: duration,
                contentType: "",
                byteCount: 0,
                bodyText: "",
                errorMessage: friendlyError(error),
                trigger: trigger,
                sourceURL: upstreamURL
            )
            apply(
                record: record,
                data: nil,
                contentType: nil,
                sourceURL: upstreamURL,
                sourceMethod: upstreamMethod
            )
        }
    }

    private func apply(
        record: PollRecord,
        data: Data?,
        contentType: String?,
        sourceURL: String,
        sourceMethod: String
    ) {
        // 请求期间用户可能已经改了上游；这时旧结果不能冒充新接口的数据。
        guard sourceURL == configuration.trimmedURLString,
              sourceMethod == configuration.method.rawValue else {
            return
        }
        latestRecord = record
        history.insert(record, at: 0)
        if history.count > HistoryStore.maximumCount {
            history.removeLast(history.count - HistoryStore.maximumCount)
        }
        pollCount += 1
        if record.success {
            successCount += 1
            lastError = nil
        } else {
            failureCount += 1
            lastError = record.errorMessage
        }
        StatsStore.save(polls: pollCount, successes: successCount, failures: failureCount)

        store.update { snapshot in
            if record.success, let data {
                snapshot.latestData = data
                snapshot.latestContentType = contentType ?? "application/octet-stream"
                snapshot.lastSuccessAt = record.date
            }
            snapshot.latestRecord = record
            snapshot.history = self.history
            snapshot.pollCount = self.pollCount
            snapshot.successCount = self.successCount
            snapshot.failureCount = self.failureCount
            snapshot.lastError = record.errorMessage
            snapshot.updatedAt = record.date
        }
        if record.success, let data {
            LatestResponseStore.save(
                data: data,
                contentType: contentType ?? "application/octet-stream",
                date: record.date,
                statusCode: record.statusCode,
                durationMilliseconds: record.durationMilliseconds,
                url: sourceURL,
                method: sourceMethod
            )
        }
        HistoryStore.save(history)
    }

    private func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func friendlyError(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorTimedOut:
            return "请求超时"
        case NSURLErrorCannotFindHost:
            return "找不到域名，请检查接口地址"
        case NSURLErrorCannotConnectToHost:
            return "无法连接到服务器"
        case NSURLErrorNotConnectedToInternet:
            return "设备当前没有网络"
        case NSURLErrorNetworkConnectionLost:
            return "网络连接中断"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "HTTPS 证书校验失败"
        case NSURLErrorUnsupportedURL:
            return "不支持的 URL"
        default:
            return nsError.localizedDescription
        }
    }

    // MARK: - 本地服务

    private func makeServer() -> LocalHTTPServer {
        LocalHTTPServer(
            store: store,
            onRefreshRequest: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.pollNow(trigger: "local-api")
                }
            },
            onStateChange: { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    self.handleServerState(state)
                }
            }
        )
    }

    private func handleServerState(_ state: LocalServerState) {
        serverState = state
        store.update { snapshot in
            switch state {
            case .running(let port):
                snapshot.serverRunning = true
                snapshot.serverPort = port
            case .waiting(_):
                snapshot.serverRunning = false
            case .failed(_):
                snapshot.serverRunning = false
            case .stopped, .starting:
                snapshot.serverRunning = false
            }
        }
    }

    func restartServer() {
        if server == nil {
            server = makeServer()
        }
        serverState = .starting
        server?.restart(port: configuration.normalizedPort, serviceName: serviceName)
    }

    func stopServer() {
        server?.stop()
        serverState = .stopped
    }

    /// 从后台回到前台时调用：确保端口仍被监听。
    func ensureServerRunning() {
        guard didBootstrap else { return }
        switch serverState {
        case .failed(_), .stopped:
            restartServer()
        default:
            break
        }
    }

    func refreshAddresses() {
        addresses = NetworkInfo.ipv4Addresses().map { $0.address }
        preferredLANAddress = NetworkInfo.preferredLANAddress()
    }

    /// 画中画浮窗显示的数据：优先取最近一次成功记录里的模型/token 信息。
    func pipStatusData() -> PiPStatusData {
        let successfulRecord = latestRecord?.success == true
            ? latestRecord
            : history.first(where: { $0.success })

        let configuredName = configuration.displayModelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName: String
        if !configuredName.isEmpty {
            modelName = configuredName
        } else if let recordName = successfulRecord?.modelName, !recordName.isEmpty {
            modelName = recordName
        } else {
            modelName = "未识别"
        }

        return PiPStatusData(
            modelName: modelName,
            contextUsed: successfulRecord?.tokensUsed,
            contextLimit: configuration.normalizedContextLimit,
            serverRunning: serverState.isRunning,
            polling: isPolling && !isPaused && configuration.enabled,
            pollCount: pollCount,
            successCount: successCount
        )
    }

    // MARK: - 展示辅助

    var lanBaseURL: String? {
        guard let address = preferredLANAddress else { return nil }
        return "http://\(address):\(configuration.normalizedPort)"
    }

    var localBaseURL: String {
        "http://127.0.0.1:\(configuration.normalizedPort)"
    }

    var pollingStatusText: String {
        if isPaused { return "已暂停" }
        return isPolling ? "运行中" : "未运行"
    }

    func countdownText(at date: Date) -> String {
        if isPaused {
            return "已暂停"
        }
        guard configuration.enabled else {
            return "自动轮询未启用"
        }
        guard let next = nextPollDate else {
            return isPolling ? "请求进行中" : "未运行"
        }
        let seconds = max(0, Int(next.timeIntervalSince(date).rounded(.up)))
        if seconds <= 0 {
            return "即将轮询"
        }
        if seconds < 60 {
            return "\(seconds) 秒后"
        }
        return "\(seconds / 60) 分 \(seconds % 60) 秒后"
    }
}