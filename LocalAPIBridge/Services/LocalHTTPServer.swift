import Foundation
import Network

/// 本地 HTTP 服务的运行状态。
enum LocalServerState: Equatable {
    case stopped
    case starting
    case waiting(String)
    case running(port: Int)
    case failed(String)

    var title: String {
        switch self {
        case .stopped:
            return "未启动"
        case .starting:
            return "正在启动…"
        case .waiting(let message):
            return "等待网络：\(message)"
        case .running(let port):
            return "运行中 · 端口 \(port)"
        case .failed(let message):
            return "启动失败：\(message)"
        }
    }

    var isRunning: Bool {
        switch self {
        case .running(_):
            return true
        default:
            return false
        }
    }
}

/// 一个简单的 HTTP 响应。
struct HTTPReply {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json(status: Int = 200, payload: [String: Any]) -> HTTPReply {
        var data = Data()
        if JSONSerialization.isValidJSONObject(payload),
           let encoded = try? JSONSerialization.data(
               withJSONObject: payload,
               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
           ) {
            data = encoded
        } else {
            data = Data("{\"ok\":false,\"error\":\"JSON 序列化失败\"}".utf8)
        }
        return HTTPReply(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    static func html(status: Int = 200, content: String) -> HTTPReply {
        HTTPReply(status: status, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(content.utf8))
    }

    static func data(
        status: Int = 200,
        contentType: String,
        body: Data,
        headers: [String: String] = [:]
    ) -> HTTPReply {
        var merged = headers
        merged["Content-Type"] = contentType
        return HTTPReply(status: status, headers: merged, body: body)
    }

    static func empty(status: Int) -> HTTPReply {
        HTTPReply(status: status, headers: [:], body: Data())
    }

    func serialized() -> Data {
        var allHeaders = headers
        if status != 204, status != 304 {
            allHeaders["Content-Length"] = String(body.count)
        }
        allHeaders["Connection"] = "close"
        allHeaders["Server"] = "LocalAPIBridge/1.0"
        allHeaders["Access-Control-Allow-Origin"] = "*"
        allHeaders["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        allHeaders["Access-Control-Allow-Headers"] = "Content-Type, Authorization, X-API-Key"
        allHeaders["Access-Control-Expose-Headers"] = "X-Bridge-Last-Fetched, X-Bridge-Last-Attempt, X-Bridge-Last-Status, X-Bridge-Last-Success, X-Bridge-Age-Seconds"
        allHeaders["Access-Control-Allow-Private-Network"] = "true"
        allHeaders["Access-Control-Max-Age"] = "86400"
        allHeaders["Cache-Control"] = "no-store"

        var text = "HTTP/1.1 \(status) \(HTTPReply.reason(for: status))\r\n"
        for (name, value) in allHeaders {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"

        var result = Data(text.utf8)
        result.append(body)
        return result
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}

/// 基于 Network.framework 的极简 HTTP/1.1 服务：
/// 只支持一次请求-响应，响应后关闭连接，够本地和局域网调用使用。
final class LocalHTTPServer {
    private(set) var state: LocalServerState = .stopped

    private let queue = DispatchQueue(label: "com.localapibridge.httpserver", qos: .userInitiated)
    private let store: BridgeStore
    private let onRefreshRequest: () -> Void
    private let onStateChange: (LocalServerState) -> Void

    private var listener: NWListener?
    private var serviceName = "LocalAPIBridge"
    /// AI 多端点路由；由 PollingEngine 在启动时注入。
    var router: EndpointRouter?

    init(
        store: BridgeStore,
        onRefreshRequest: @escaping () -> Void,
        onStateChange: @escaping (LocalServerState) -> Void
    ) {
        self.store = store
        self.onRefreshRequest = onRefreshRequest
        self.onStateChange = onStateChange
    }

    func start(port: Int, serviceName: String) {
        let safePort = min(max(port, 1024), 65_535)
        queue.async { [weak self] in
            guard let self else { return }
            self.serviceName = serviceName
            self.listener?.cancel()
            self.listener = nil
            self.updateState(.starting)

            guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(safePort)) else {
                self.updateState(.failed("端口无效"))
                return
            }

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            do {
                let newListener = try NWListener(using: parameters, on: endpointPort)
                newListener.service = NWListener.Service(
                    name: serviceName,
                    type: "_http._tcp",
                    domain: nil,
                    txtRecord: nil
                )
                newListener.stateUpdateHandler = { [weak self, weak newListener] newState in
                    guard let self, let newListener, self.listener === newListener else { return }
                    switch newState {
                    case .ready:
                        self.updateState(.running(port: safePort))
                    case .waiting(let error):
                        self.updateState(.waiting(error.localizedDescription))
                    case .failed(let error):
                        self.updateState(.failed(error.localizedDescription))
                        newListener.cancel()
                        self.listener = nil
                    case .cancelled:
                        self.updateState(.stopped)
                    default:
                        break
                    }
                }
                newListener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener = newListener
                newListener.start(queue: self.queue)
            } catch {
                self.updateState(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.updateState(.stopped)
        }
    }

    func restart(port: Int, serviceName: String) {
        let safePort = min(max(port, 1024), 65_535)
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
        }
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.start(port: safePort, serviceName: serviceName)
        }
    }

    private func updateState(_ newState: LocalServerState) {
        state = newState
        onStateChange(newState)
    }

    // MARK: - 连接处理

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // 兜底看门狗：客户端连上却迟迟不发完整请求时释放连接。
        // 对正常请求，send 完成后的 cancel 会先一步生效。
        // 只兜底“连上但一直不发完整请求”的客户端：用 weak 捕获，
        // 正常结束的连接可以立刻释放，不会被这个定时闭包强留。
        queue.asyncAfter(deadline: .now() + 3_600) { [weak connection] in
            connection?.cancel()
        }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            if let separatorRange = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = accumulated.subdata(in: 0..<separatorRange.lowerBound)
                if self.headerIsChunked(headerData) {
                    let rawBody = accumulated.subdata(in: separatorRange.upperBound..<accumulated.count)
                    if let decoded = self.decodeChunkedBody(rawBody) {
                        self.respond(headerData: headerData, bodyData: decoded, on: connection)
                        return
                    }
                    if accumulated.count > 8_388_608 {
                        self.send(
                            HTTPReply.json(status: 413, payload: ["ok": false, "error": "请求体过大"]),
                            on: connection
                        )
                        return
                    }
                    if isComplete || error != nil {
                        self.send(
                            HTTPReply.json(status: 400, payload: ["ok": false, "error": "chunked 请求体不完整"]),
                            on: connection
                        )
                        return
                    }
                    self.receive(on: connection, buffer: accumulated)
                    return
                }
                let receivedBodyLength = accumulated.count - separatorRange.upperBound
                let expectedBodyLength = contentLength(in: headerData)
                if receivedBodyLength >= expectedBodyLength {
                    let bodyData = accumulated.subdata(
                        in: separatorRange.upperBound..<accumulated.count
                    )
                    self.respond(headerData: headerData, bodyData: bodyData, on: connection)
                    return
                }
                if accumulated.count > 8_388_608 {
                    self.send(
                        HTTPReply.json(status: 413, payload: ["ok": false, "error": "请求体过大"]),
                        on: connection
                    )
                    return
                }
                if isComplete || error != nil {
                    self.send(
                        HTTPReply.json(status: 400, payload: ["ok": false, "error": "请求体不完整"]),
                        on: connection
                    )
                    return
                }
                self.receive(on: connection, buffer: accumulated)
                return
            }

            if accumulated.count > 65_536 || isComplete || error != nil {
                self.send(
                    HTTPReply.json(status: 431, payload: ["ok": false, "error": "请求头过大或连接已断开"]),
                    on: connection
                )
                return
            }

            self.receive(on: connection, buffer: accumulated)
        }
    }

    /// 只用于等 POST 请求体读完；路由本身不读取请求体。
    private func contentLength(in headerData: Data) -> Int {
        guard let text = String(data: headerData, encoding: .utf8) else { return 0 }
        for line in text.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = String(line.dropFirst("content-length:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return max(0, Int(value) ?? 0)
            }
        }
        return 0
    }

    private func headerIsChunked(_ headerData: Data) -> Bool {
        guard let text = String(data: headerData, encoding: .utf8) else { return false }
        return text.lowercased().contains("transfer-encoding: chunked")
    }

    /// 解码 `Transfer-Encoding: chunked` 的请求体；数据不完整时返回 nil。
    private func decodeChunkedBody(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var result = Data()
        var index = data.startIndex
        while true {
            guard let lineEnd = data.range(of: Data("\r\n".utf8), in: index..<data.endIndex) else {
                return nil
            }
            let sizeLine = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
            let hexPart = sizeLine.split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(hexPart.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                return nil
            }
            var cursor = lineEnd.upperBound
            if size == 0 {
                return result
            }
            guard let chunkEnd = data.index(cursor, offsetBy: size, limitedBy: data.endIndex) else {
                return nil
            }
            guard let nextStart = data.index(chunkEnd, offsetBy: 2, limitedBy: data.endIndex) else {
                return nil
            }
            result.append(data[cursor..<chunkEnd])
            index = nextStart
            cursor = nextStart
        }
    }

    private func respond(headerData: Data, bodyData: Data, on connection: NWConnection) {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            send(.json(status: 400, payload: ["ok": false, "error": "无法解析请求头"]), on: connection)
            return
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            send(.json(status: 400, payload: ["ok": false, "error": "空请求"]), on: connection)
            return
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            send(.json(status: 400, payload: ["ok": false, "error": "请求行格式错误"]), on: connection)
            return
        }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colonIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = String(line[line.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                headers[name] = value
            }
        }

        // 异步路由（AI 代理 / 路由状态）需要先做与同步路由相同的鉴权。
        if method == "HEAD" {
            send(.empty(status: 200), on: connection)
            return
        }

        if method != "OPTIONS", let failure = authorizationFailure(headers: headers, target: target) {
            send(failure, on: connection)
            return
        }

        let parsed = parseTarget(target)
        var path = parsed.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path.isEmpty {
            path = "/"
        }

        // 不同客户端粘贴 Base URL 的方式差别很大：有的带 /v1，有的不带，
        // 有的自己又补一次 /v1。这里统一归一化，免得用户"填了地址却用不了"。
        path = Self.normalizedAPIPath(path)

        if method == "POST", path == "/v1/chat/completions" {
            handleChatProxy(bodyData: bodyData, headers: headers, on: connection)
            return
        }
        if method == "GET", path.hasPrefix("/v1/models/") {
            let modelID = String(path.dropFirst("/v1/models/".count))
            handleModelDetail(modelID: modelID, on: connection)
            return
        }
        if method == "GET", path == "/v1/models" {
            handleRouterQuery(kind: .models, on: connection)
            return
        }
        if method == "GET", path == "/router/status" {
            handleRouterQuery(kind: .status, on: connection)
            return
        }
        if method == "GET", path == "/router/best" {
            handleRouterQuery(kind: .best, on: connection)
            return
        }
        if method == "POST", path == "/router/refresh" {
            Task { @MainActor in
                self.router?.probeAllNow()
            }
            send(.json(status: 202, payload: ["ok": true, "queued": true]), on: connection)
            return
        }

        send(route(method: method, target: target, headers: headers), on: connection)
    }

    private enum RouterQueryKind {
        case models
        case status
        case best
    }

    private func handleChatProxy(
        bodyData: Data,
        headers: [String: String],
        on connection: NWConnection
    ) {
        guard let router else {
            send(.json(status: 503, payload: ["ok": false, "error": "AI 路由尚未启动"]), on: connection)
            return
        }
        // 有些客户端只在请求头里声明要 SSE（body 里 stream 仍是 false），
        // 以前会被当成非流式处理，于是客户端一直等不到流。
        let acceptsEventStream = (headers["accept"] ?? "").lowercased().contains("text/event-stream")
        if Self.wantsStreaming(bodyData) || acceptsEventStream {
            handleStreamingChat(router: router, bodyData: bodyData, headers: headers, on: connection)
            return
        }
        Task { @MainActor in
            let reply = await router.proxyChat(body: bodyData, incomingHeaders: headers)
            let httpReply = HTTPReply.data(
                status: reply.statusCode,
                contentType: reply.contentType,
                body: reply.body,
                headers: reply.headers
            )
            self.send(httpReply, on: connection)
        }
    }

    private static func wantsStreaming(_ body: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return false
        }
        if let value = object["stream"] as? Bool {
            return value
        }
        if let value = object["stream"] as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
        }
        return false
    }

    private func handleStreamingChat(
        router: EndpointRouter,
        bodyData: Data,
        headers: [String: String],
        on connection: NWConnection
    ) {
        let state = StreamSendState()
        // 客户端关掉页面/退出 App 时 TCP 会 FIN：这里专门收一个字节来判断对端是否已走，
        // 走了就立刻停掉上游，别继续烧额度。
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, _ in
            if isComplete {
                state.clientGone = true
                connection.cancel()
            }
        }

        Task { @MainActor in
            let stream = router.streamChat(body: bodyData, incomingHeaders: headers)
            for await event in stream {
                if state.clientGone { break }
                if case .cancelled = connection.state { break }
                if case .failed = connection.state { break }
                switch event {
                case .head(let contentType):
                    if !state.headSent {
                        state.headSent = true
                        self.sendStreamHead(contentType: contentType, on: connection)
                    }
                case .chunk(let data):
                    if !state.headSent {
                        state.headSent = true
                        self.sendStreamHead(contentType: "text/event-stream; charset=utf-8", on: connection)
                    }
                    self.sendStreamChunk(data, on: connection, state: state)
                case .finished:
                    if state.headSent {
                        self.finishStream(on: connection)
                    } else {
                        self.send(
                            .json(status: 502, payload: ["ok": false, "error": "上游没有返回数据"]),
                            on: connection
                        )
                    }
                case .failed(let message, let status):
                    if state.headSent {
                        self.sendStreamError(message, on: connection, state: state)
                        self.finishStream(on: connection)
                    } else {
                        self.send(
                            .json(status: status > 0 ? status : 502, payload: ["ok": false, "error": message]),
                            on: connection
                        )
                    }
                }
            }
        }
    }

    private final class StreamSendState {
        var headSent = false
        var clientGone = false
    }

    private func sendStreamHead(contentType: String, on connection: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Cache-Control: no-cache, no-transform\r\n"
        head += "Connection: close\r\n"
        head += "Transfer-Encoding: chunked\r\n"
        head += "X-Accel-Buffering: no\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: *\r\n"
        head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        head += "Access-Control-Expose-Headers: *\r\n"
        head += "\r\n"
        connection.send(
            content: Data(head.utf8),
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { _ in }
        )
    }

    private func sendStreamChunk(_ data: Data, on connection: NWConnection, state: StreamSendState) {
        guard !data.isEmpty else { return }
        var frame = Data(String(data.count, radix: 16).utf8)
        frame.append(Data("\r\n".utf8))
        frame.append(data)
        frame.append(Data("\r\n".utf8))
        connection.send(
            content: frame,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { error in
                if error != nil {
                    state.clientGone = true
                }
            }
        )
    }

    private func sendStreamError(_ message: String, on connection: NWConnection, state: StreamSendState) {
        let payload: [String: Any] = ["error": ["message": message, "type": "router_error"]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        sendStreamChunk(Data("event: error\ndata: \(text)\n\n".utf8), on: connection, state: state)
    }

    private func finishStream(on connection: NWConnection) {
        connection.send(
            content: Data("0\r\n\r\n".utf8),
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { error in
                guard error == nil else {
                    connection.cancel()
                    return
                }
                connection.send(
                    content: nil,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
            }
        )
    }

    private func handleModelDetail(modelID: String, on connection: NWConnection) {
        guard let router else {
            send(.json(status: 503, payload: ["ok": false, "error": "AI 路由尚未启动"]), on: connection)
            return
        }
        Task { @MainActor in
            if let payload = router.modelDetailPayload(id: modelID) {
                self.send(.json(payload: payload), on: connection)
            } else {
                self.send(
                    .json(status: 404, payload: ["ok": false, "error": "模型不存在"]),
                    on: connection
                )
            }
        }
    }

    private func handleRouterQuery(kind: RouterQueryKind, on connection: NWConnection) {
        guard let router else {
            send(.json(status: 503, payload: ["ok": false, "error": "AI 路由尚未启动"]), on: connection)
            return
        }
        Task { @MainActor in
            let reply: HTTPReply
            switch kind {
            case .models:
                reply = .json(payload: router.modelsPayload())
            case .status:
                reply = .json(payload: router.statusPayload())
            case .best:
                if let payload = router.bestEndpointPayload() {
                    reply = .json(payload: payload)
                } else {
                    reply = .json(status: 404, payload: ["ok": false, "error": "没有启用的 AI 端点"])
                }
            }
            self.send(reply, on: connection)
        }
    }

    /// 与 route 内部的 token 校验保持一致；通过返回 nil。
    private func authorizationFailure(headers: [String: String], target: String) -> HTTPReply? {
        let snapshot = store.read()
        guard !snapshot.accessToken.isEmpty else { return nil }
        let parsed = parseTarget(target)
        var provided = headers["x-api-key"] ?? parsed.query["token"]
        if let authorization = headers["authorization"], authorization.lowercased().hasPrefix("bearer ") {
            provided = String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard provided == snapshot.accessToken else {
            return .json(status: 401, payload: [
                "ok": false,
                "error": "访问令牌缺失或不正确",
                "hint": "使用请求头 X-API-Key: <token> 或查询参数 ?token=<token>"
            ])
        }
        return nil
    }

    private func send(_ reply: HTTPReply, on connection: NWConnection) {
        let data = reply.serialized()
        connection.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { error in
                if error != nil {
                    connection.cancel()
                    return
                }
                // 先发一个 finalMessage，确保数据交给传输层后再关闭，避免大响应被 cancel 截断。
                connection.send(
                    content: nil,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
            }
        )
    }

    // MARK: - 路由

    private func route(method: String, target: String, headers: [String: String]) -> HTTPReply {
        let snapshot = store.read()
        let parsed = parseTarget(target)
        var path = parsed.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path.isEmpty {
            path = "/"
        }
        let query = parsed.query

        if method == "OPTIONS" {
            return .empty(status: 204)
        }

        if !snapshot.accessToken.isEmpty {
            var provided = headers["x-api-key"] ?? query["token"]
            if let authorization = headers["authorization"], authorization.lowercased().hasPrefix("bearer ") {
                provided = String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if provided != snapshot.accessToken {
                return .json(status: 401, payload: [
                    "ok": false,
                    "error": "访问令牌缺失或不正确",
                    "hint": "使用请求头 X-API-Key: <token> 或查询参数 ?token=<token>"
                ])
            }
        }

        switch (method, path.lowercased()) {
        case ("GET", "/"):
            return .html(content: dashboardHTML(snapshot: snapshot))
        case ("GET", "/healthz"):
            return .json(payload: ["ok": true])
        case ("GET", "/status"):
            return .json(payload: statusPayload(snapshot))
        case ("GET", "/latest"), ("GET", "/raw"):
            return latestReply(snapshot: snapshot, pretty: query["pretty"] == "1")
        case ("GET", "/json"):
            return wrapperReply(snapshot: snapshot)
        case ("GET", "/history"):
            let requested = Int(query["limit"] ?? "") ?? 20
            let limit = min(max(requested, 1), 200)
            let records = snapshot.history.prefix(limit).map(recordPayload)
            return .json(payload: ["ok": true, "count": records.count, "records": records])
        case ("POST", "/refresh"):
            onRefreshRequest()
            return .json(status: 202, payload: ["ok": true, "queued": true, "message": "已触发一次轮询"])
        case ("GET", "/favicon.ico"):
            return .empty(status: 204)
        default:
            return .json(status: 404, payload: [
                "ok": false,
                "error": "接口不存在",
                "routes": availableRoutes
            ])
        }
    }

    private var availableRoutes: [String] {
        [
            "GET /",
            "GET /healthz",
            "GET /status",
            "GET /latest",
            "GET /latest?pretty=1",
            "GET /raw",
            "GET /json",
            "GET /history?limit=20",
            "POST /refresh",
            "POST /v1/chat/completions",
            "GET /v1/models",
            "GET /router/status",
            "GET /router/best",
            "POST /router/refresh"
        ]
    }

    /// 把 `/v1/v1/...`、`/models`、`/chat/completions` 统一成标准路径。
    private static func normalizedAPIPath(_ raw: String) -> String {
        var value = raw.lowercased()
        while value.hasPrefix("/v1/v1/") {
            value = String(value.dropFirst(3))
        }
        if value == "/models" {
            return "/v1/models"
        }
        if value == "/chat/completions" {
            return "/v1/chat/completions"
        }
        return value
    }

    private func parseTarget(_ target: String) -> (path: String, query: [String: String]) {
        var path = target
        var queryString = ""

        if target.hasPrefix("http://") || target.hasPrefix("https://"),
           let components = URLComponents(string: target) {
            path = components.path.isEmpty ? "/" : components.path
            queryString = components.query ?? ""
        } else if let questionIndex = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<questionIndex])
            queryString = String(target[target.index(after: questionIndex)...])
        }

        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = pieces.first else { continue }
            let rawKey = String(first)
            let key = rawKey.removingPercentEncoding ?? rawKey
            var value = ""
            if pieces.count > 1 {
                let rawValue = String(pieces[1])
                value = rawValue.removingPercentEncoding ?? rawValue
            }
            query[key] = value
        }

        if path.isEmpty {
            path = "/"
        }
        return (path, query)
    }

    // MARK: - 各接口响应

    private func latestReply(snapshot: BridgeStore.Snapshot, pretty: Bool) -> HTTPReply {
        guard let data = snapshot.latestData else {
            return .json(status: 503, payload: [
                "ok": false,
                "error": "还没有成功获取过数据",
                "hint": "等待首次轮询完成，或 POST /refresh 触发一次"
            ])
        }

        var headers: [String: String] = [:]
        var contentType = snapshot.latestContentType.isEmpty
            ? "application/octet-stream"
            : snapshot.latestContentType
        headers["X-Bridge-Last-Fetched"] = isoString(snapshot.lastSuccessAt)
        headers["X-Bridge-Last-Attempt"] = isoString(snapshot.latestRecord?.date)
        if let record = snapshot.latestRecord {
            headers["X-Bridge-Last-Status"] = String(record.statusCode)
            headers["X-Bridge-Last-Success"] = record.success ? "true" : "false"
        }
        if let lastSuccess = snapshot.lastSuccessAt {
            headers["X-Bridge-Age-Seconds"] = String(max(0, Int(Date().timeIntervalSince(lastSuccess))))
        }

        var body = data
        if pretty, let prettyData = prettyJSONData(data) {
            body = prettyData
            contentType = "application/json; charset=utf-8"
        }
        return .data(status: 200, contentType: contentType, body: body, headers: headers)
    }

    private func wrapperReply(snapshot: BridgeStore.Snapshot) -> HTTPReply {
        guard let data = snapshot.latestData, let record = snapshot.latestRecord else {
            return .json(status: 503, payload: ["ok": false, "error": "还没有可用的数据"])
        }

        var payload: [String: Any] = [
            "ok": record.success,
            "status": record.statusCode,
            "fetchedAt": isoString(record.date),
            "lastSuccessAt": isoString(snapshot.lastSuccessAt),
            "durationMilliseconds": record.durationMilliseconds,
            "contentType": snapshot.latestContentType,
            "bytes": data.count,
            "stale": !record.success,
            "lastError": record.errorMessage ?? ""
        ]

        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            payload["body"] = object
            payload["bodyIsJSON"] = true
        } else if let text = String(data: data, encoding: .utf8) {
            payload["body"] = text
            payload["bodyIsJSON"] = false
        } else {
            payload["body"] = data.base64EncodedString()
            payload["bodyIsJSON"] = false
            payload["bodyIsBase64"] = true
        }

        return .json(payload: payload)
    }

    private func statusPayload(_ snapshot: BridgeStore.Snapshot) -> [String: Any] {
        let serverInfo: [String: Any] = [
            "running": snapshot.serverRunning,
            "state": state.title,
            "port": snapshot.serverPort,
            "addresses": NetworkInfo.ipv4Addresses().map { $0.address },
            "localURL": "http://127.0.0.1:\(snapshot.serverPort)",
            "bonjour": "_http._tcp"
        ]
        let pollingInfo: [String: Any] = [
            "active": snapshot.isPollingActive,
            "intervalSeconds": Int(snapshot.intervalSeconds),
            "nextPollAt": isoString(snapshot.nextPollDate),
            "pollCount": snapshot.pollCount,
            "successCount": snapshot.successCount,
            "failureCount": snapshot.failureCount,
            "lastError": snapshot.lastError ?? ""
        ]
        let upstreamInfo: [String: Any] = [
            "url": snapshot.upstreamURL,
            "method": snapshot.upstreamMethod
        ]

        var payload: [String: Any] = [
            "ok": true,
            "app": "LocalAPIBridge",
            "version": "1.0",
            "server": serverInfo,
            "polling": pollingInfo,
            "upstream": upstreamInfo,
            "startedAt": isoString(snapshot.startedAt)
        ]

        if let record = snapshot.latestRecord {
            let latest: [String: Any] = [
                "success": record.success,
                "statusCode": record.statusCode,
                "time": isoString(record.date),
                "durationMilliseconds": record.durationMilliseconds,
                "contentType": record.contentType,
                "bytes": record.byteCount,
                "error": record.errorMessage ?? "",
                "model": record.modelName ?? "",
                "tokensUsed": record.tokensUsed ?? -1,
                "ageSeconds": snapshot.lastSuccessAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
            ]
            payload["latest"] = latest
        }
        if let lastSuccess = snapshot.lastSuccessAt {
            payload["lastSuccessAt"] = isoString(lastSuccess)
        }
        return payload
    }

    private func recordPayload(_ record: PollRecord) -> [String: Any] {
        [
            "id": record.id.uuidString,
            "time": isoString(record.date),
            "success": record.success,
            "statusCode": record.statusCode,
            "durationMilliseconds": record.durationMilliseconds,
            "contentType": record.contentType,
            "bytes": record.byteCount,
            "trigger": record.trigger,
            "sourceURL": record.sourceURL,
            "model": record.modelName ?? "",
            "tokensUsed": record.tokensUsed ?? -1,
            "error": record.errorMessage ?? "",
            "bodyPreview": String(record.bodyText.prefix(2_000))
        ]
    }

    // MARK: - 状态页

    private func dashboardHTML(snapshot: BridgeStore.Snapshot) -> String {
        let record = snapshot.latestRecord
        let isSuccess = record?.success ?? false
        let statusText: String
        if let record {
            statusText = record.statusCode == 0 ? "请求失败" : "HTTP \(record.statusCode)"
        } else {
            statusText = "等待首次轮询"
        }
        let statusColor = isSuccess ? "#2e9e5b" : "#d9534f"
        let fetchTime = record.map { isoString($0.date) } ?? "—"
        let lastSuccess = isoString(snapshot.lastSuccessAt)
        let lastSuccessText = lastSuccess.isEmpty ? "—" : lastSuccess
        let bodyText: String
        if let latestData = snapshot.latestData {
            if latestData.count > 200_000 {
                let prefix = Data(latestData.prefix(200_000))
                bodyText = prettyBody(prefix) + "\n\n…（仅展示前 200 KB，完整响应请访问 /latest）"
            } else {
                bodyText = prettyBody(latestData)
            }
        } else {
            bodyText = "还没有成功获取过数据。点击“立即轮询”或等待下一次自动轮询。"
        }
        let addresses = NetworkInfo.ipv4Addresses().map { $0.address }
        let addressText = addresses.isEmpty ? "未检测到局域网 IPv4 地址" : addresses.joined(separator: "、")
        let errorText = snapshot.lastError ?? ""
        let errorRow = errorText.isEmpty ? "" : "<p class=\"err\">最近错误：\(escapeHTML(errorText))</p>"
        let endpointText = availableRoutes
            .map { "<code>\(escapeHTML($0))</code>" }
            .joined(separator: " ")

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="refresh" content="5">
        <title>Local API Bridge</title>
        <style>
        :root { color-scheme: dark; }
        * { box-sizing: border-box; }
        body {
            margin: 0; padding: 32px 20px 64px;
            font-family: -apple-system, "SF Pro Text", "PingFang SC", "Segoe UI", sans-serif;
            background: radial-gradient(circle at 20% 0%, #16233d 0%, #0b0f18 55%, #07090d 100%);
            color: #e8edf6; min-height: 100vh;
        }
        main { max-width: 920px; margin: 0 auto; }
        h1 { font-size: 26px; margin: 0 0 6px; letter-spacing: .5px; }
        h2 { font-size: 16px; margin: 32px 0 10px; color: #9fb0c8; font-weight: 600; }
        .sub { color: #7f8ca3; margin: 0 0 24px; font-size: 13px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; }
        .card {
            background: rgba(255,255,255,.045); border: 1px solid rgba(255,255,255,.08);
            border-radius: 14px; padding: 16px; display: flex; flex-direction: column; gap: 6px;
        }
        .card strong { font-size: 20px; font-weight: 600; }
        .label { color: #8b98ad; font-size: 12px; letter-spacing: .4px; }
        .muted { color: #7c889c; font-size: 12px; }
        .err { color: #ff9186; font-size: 13px; margin-top: 16px; }
        pre {
            background: #0d1119; border: 1px solid rgba(255,255,255,.08); border-radius: 12px;
            padding: 16px; overflow: auto; font-size: 12.5px; line-height: 1.55;
            color: #c7d4e8; max-height: 520px;
        }
        code { color: #8fd3ff; background: rgba(143,211,255,.08); padding: 2px 6px; border-radius: 5px; font-size: 12px; }
        .endpoints { display: flex; flex-wrap: wrap; gap: 8px; }
        button {
            background: #2f6fed; color: #fff; border: none; border-radius: 9px;
            padding: 9px 16px; font-size: 14px; cursor: pointer;
        }
        button:active { opacity: .8; }
        .link { color: #9fb0c8; margin-left: 12px; font-size: 13px; }
        </style>
        </head>
        <body>
        <main>
        <h1>Local API Bridge</h1>
        <p class="sub">iPhone 本地轮询服务 · 端口 \(snapshot.serverPort) · 每 \(Int(snapshot.intervalSeconds)) 秒自动轮询</p>
        <div class="grid">
            <div class="card"><span class="label">上游状态</span><strong style="color: \(statusColor)">\(statusText)</strong><span class="muted">最近一次：\(fetchTime)</span></div>
            <div class="card"><span class="label">最近成功</span><strong>\(lastSuccessText)</strong><span class="muted">成功 \(snapshot.successCount) / 共 \(snapshot.pollCount) 次</span></div>
            <div class="card"><span class="label">局域网地址</span><strong style="font-size: 15px">\(escapeHTML(addressText))</strong><span class="muted">上游：\(escapeHTML(snapshot.upstreamHost))</span></div>
        </div>
        \(errorRow)
        <p><button onclick="triggerRefresh()">立即轮询</button><a class="link" href="javascript:location.reload()">刷新页面</a></p>
        <h2>最新响应</h2>
        <pre>\(escapeHTML(bodyText))</pre>
        <h2>可用接口</h2>
        <p class="endpoints">\(endpointText)</p>
        </main>
        <script>
        const token = new URLSearchParams(location.search).get('token') || '';
        async function triggerRefresh() {
            await fetch('/refresh?token=' + encodeURIComponent(token), { method: 'POST' });
            location.reload();
        }
        </script>
        </body>
        </html>
        """
    }

    // MARK: - 小工具

    private func isoString(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func prettyJSONData(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )
    }

    private func prettyBody(_ data: Data) -> String {
        if let pretty = prettyJSONData(data), let text = String(data: pretty, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .utf8) ?? "（\(data.count) 字节二进制数据）"
    }

    private func escapeHTML(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        return result
    }
}