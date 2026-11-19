import Foundation
import SwiftUI

struct RouterView: View {
    @EnvironmentObject private var router: EndpointRouter
    @EnvironmentObject private var engine: PollingEngine

    @State private var endpointJSON = "[]"
    @State private var subscriptionText = ""
    @State private var probeInterval = 30.0
    @State private var probeTimeout = 2.0
    @State private var hedgeMilliseconds = 100
    @State private var maxRace = 3
    @State private var contextLimit = 128_000
    @State private var displayModel = ""
    @State private var monitoring = true
    @State private var exposeAllModels = true
    @State private var firstByteHedge = 600
    @State private var showEditor = false
    @State private var showModelImport = false
    @State private var editingEndpoint: AIEndpoint?
    @State private var showAdvanced = false
    @State private var loaded = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    var body: some View {
        NavigationStack {
            List {
                bestSection
                endpointsSection
                subscriptionsSection
                settingsSection
                logSection
                advancedSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("AI 路由")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        editingEndpoint = nil
                        showEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加端点")
                }
            }
            .onAppear {
                loadIfNeeded()
            }
            .onChange(of: showAdvanced) { expanded in
                if expanded {
                    endpointJSON = router.manualEndpointsJSON()
                }
            }
            .sheet(isPresented: $showEditor, onDismiss: {
                endpointJSON = router.manualEndpointsJSON()
                subscriptionText = router.subscriptionURLsText
            }) {
                NavigationStack {
                    EndpointEditorView(
                        endpoint: editingEndpoint ?? AIEndpoint(),
                        isNew: editingEndpoint == nil
                    )
                    .environmentObject(router)
                }
            }
            .sheet(isPresented: $showModelImport, onDismiss: {
                endpointJSON = router.manualEndpointsJSON()
                subscriptionText = router.subscriptionURLsText
            }) {
                NavigationStack {
                    ModelImportView()
                        .environmentObject(router)
                }
            }
            .alert(alertTitle, isPresented: $showAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
    }

    // MARK: - 当前最优

    private var bestSection: some View {
        Section {
            if let best = router.bestEndpoint() {
                let health = router.health[best.id] ?? .unknown(best.id)
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(color(for: health.state))
                        .frame(width: 9, height: 9)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(best.displayName)
                            .font(.headline)
                        Text("模型 \(best.displayModel) · \(latencyText(health)) · \(health.state.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let error = health.lastError, !error.isEmpty {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
            } else {
                Text("还没有可用端点：先在下面添加端点或订阅。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    router.probeAllNow()
                } label: {
                    Label(router.isProbing ? "探测中…" : "立即探测", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.bordered)
                .disabled(router.isProbing)

                Button {
                    Task { await router.refreshAllSubscriptions() }
                } label: {
                    Label(router.isRefreshingSubscriptions ? "刷新中…" : "刷新订阅", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(router.isRefreshingSubscriptions)
            }

            Text("本地 AI 入口（OpenAI 兼容）")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("http://127.0.0.1:\(engine.configuration.normalizedPort)/v1/chat/completions")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)

            if !router.rankedEndpoints().isEmpty {
                let names = router.rankedEndpoints().prefix(3).map {
                    "\($0.displayName)/\($0.displayModel)"
                }.joined(separator: " → ")
                Text("当前顺序：\(names)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("当前最优")
        } footer: {
            Text("路由会先选健康排名第一的端点；如果它在 \(router.configuration.hedgeDelayMilliseconds) ms 内没有返回，就并发启动后续端点。非流式请求先答完者胜出；流式请求（stream:true）先吐出第一行者胜出，并立刻取消其余上游。健康探测默认每 \(Int(router.configuration.probeIntervalSeconds)) 秒一次。")
        }
    }

    // MARK: - 端点

    private var endpointsSection: some View {
        Section {
            if router.configuration.endpoints.isEmpty {
                Text("还没有端点。点右上角 + 添加，或在下方“批量导入 JSON”里粘贴。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(router.configuration.endpoints) { endpoint in
                RouterEndpointRow(
                    endpoint: endpoint,
                    health: router.health[endpoint.id] ?? .unknown(endpoint.id),
                    onToggle: { router.toggleEndpoint(id: endpoint.id) },
                    onEdit: {
                        editingEndpoint = endpoint
                        showEditor = true
                    }
                )
            }
            .onDelete { offsets in
                let ids = offsets.map { router.configuration.endpoints[$0].id }
                for id in ids {
                    router.deleteEndpoint(id: id)
                }
            }

            Button {
                editingEndpoint = nil
                showEditor = true
            } label: {
                Label("添加端点", systemImage: "plus.circle")
            }

            Button {
                showModelImport = true
            } label: {
                Label("粘贴 API + Key，一键获取模型", systemImage: "square.stack.3d.up")
            }
        } header: {
            Text("端点（\(router.configuration.endpoints.count)）")
        } footer: {
            Text("Base URL 一般填到 /v1，例如 https://api.example.com/v1；聊天路径默认 /chat/completions，健康检查路径默认 /models。留空 API Key 时会把本地客户端传来的 Authorization 透传给上游。")
        }
    }

    // MARK: - 订阅

    private var subscriptionsSection: some View {
        Section {
            TextEditor(text: $subscriptionText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 72)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                router.replaceSubscriptions(from: subscriptionText)
                alertTitle = "已保存订阅"
                alertMessage = "正在后台刷新订阅；刷新完成后会自动探测端点。"
                showAlert = true
            } label: {
                Label("保存并刷新订阅", systemImage: "icloud.and.arrow.down")
            }

            ForEach(router.configuration.subscriptions) { subscription in
                VStack(alignment: .leading, spacing: 3) {
                    Text(subscription.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(subscription.urlString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let error = subscription.lastError, !error.isEmpty {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else if let fetched = subscription.lastFetched {
                        Text("上次刷新 \(fetched.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("订阅（每行一个 URL）")
        } footer: {
            Text("订阅返回 JSON 数组、{\"endpoints\": [...]} 或逐行文本。JSON 字段支持 name、base_url/url、api_key/key、model/models、headers、health_path、chat_path、priority。逐行格式：名称|BaseURL|Key|模型。")
        }
    }

    // MARK: - 路由参数

    private var settingsSection: some View {
        Section {
            Toggle("启用自动健康探测", isOn: $monitoring)

            Stepper(value: $probeInterval, in: 5...600, step: 5) {
                HStack {
                    Text("探测间隔")
                    Spacer()
                    Text("\(Int(probeInterval)) 秒")
                        .foregroundStyle(.secondary)
                }
            }

            Stepper(value: $probeTimeout, in: 0.5...10, step: 0.5) {
                HStack {
                    Text("单次探测超时")
                    Spacer()
                    Text(String(format: "%.1f 秒", probeTimeout))
                        .foregroundStyle(.secondary)
                }
            }

            Stepper(value: $hedgeMilliseconds, in: 20...1_000, step: 20) {
                HStack {
                    Text("并发兜底延迟")
                    Spacer()
                    Text("\(hedgeMilliseconds) ms")
                        .foregroundStyle(.secondary)
                }
            }

            Stepper(value: $firstByteHedge, in: 0...5_000, step: 100) {
                HStack {
                    Text("慢端点提前并发")
                    Spacer()
                    Text("\(firstByteHedge) ms")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("对外列出真实模型名", isOn: $exposeAllModels)

            Stepper(value: $maxRace, in: 1...5, step: 1) {
                HStack {
                    Text("最多并发端点")
                    Spacer()
                    Text("\(maxRace) 个")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("上下文上限")
                Spacer()
                TextField("128000", value: $contextLimit, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
            }

            TextField("画中画显示模型名称（留空则自动）", text: $displayModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                saveSettings()
            } label: {
                Label("保存路由参数", systemImage: "checkmark.circle")
            }
        } header: {
            Text("路由参数")
        } footer: {
            Text("选路本身是本地健康排名，0 网络等待；默认 0.1 秒内首端点没返回就并发下一个。若首选端点上次首字节超过上面的“慢端点提前并发”（默认 600ms），则直接同时并发，不再等。\n“对外列出真实模型名”会让 Cherry Studio / Open WebUI 这类客户端认出具体模型，从而允许图片上传和工具调用；只列 auto 时它们会当成未知模型。")
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section {
            if router.routeLog.isEmpty {
                Text("还没有代理请求")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(router.routeLog.prefix(20)) { log in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(log.success ? Color.green : Color.red)
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(log.endpointName)
                                .font(.caption.weight(.semibold))
                            Text("\(log.model) · HTTP \(log.statusCode) · \(log.latencyMilliseconds) ms")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(log.date.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("最近路由")
        } footer: {
            Text("成功次数 \(router.successCount) / 请求 \(router.requestCount)，失败 \(router.failureCount)。")
        }
    }

    // MARK: - 批量 JSON

    private var advancedSection: some View {
        Section {
            DisclosureGroup("批量导入手动端点 JSON", isExpanded: $showAdvanced) {
                TextEditor(text: $endpointJSON)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 160)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    let result = router.importManualEndpointsJSON(endpointJSON)
                    if let error = result.error {
                        alertTitle = "导入失败"
                        alertMessage = error
                    } else {
                        alertTitle = "已导入 \(result.count) 个端点"
                        alertMessage = "正在后台探测。"
                        endpointJSON = router.manualEndpointsJSON()
                    }
                    showAlert = true
                } label: {
                    Label("保存并探测", systemImage: "square.and.arrow.down")
                }
            }
        } header: {
            Text("高级")
        } footer: {
            Text("JSON 数组字段：name、base_url、api_key、model、headers、health_path、chat_path、priority、enabled。订阅端点与手动端点会分开管理。")
        }
    }

    // MARK: - 行为

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        endpointJSON = router.manualEndpointsJSON()
        subscriptionText = router.subscriptionURLsText
        probeInterval = router.configuration.probeIntervalSeconds
        probeTimeout = router.configuration.probeTimeoutSeconds
        hedgeMilliseconds = router.configuration.hedgeDelayMilliseconds
        maxRace = router.configuration.maxRaceEndpoints
        contextLimit = router.configuration.contextLimitTokens
        displayModel = router.configuration.displayModelName
        monitoring = router.configuration.monitoringEnabled
        exposeAllModels = router.configuration.exposeAllModels
        firstByteHedge = router.configuration.firstByteHedgeMilliseconds
    }

    private func saveSettings() {
        var config = router.configuration
        config.probeIntervalSeconds = probeInterval
        config.probeTimeoutSeconds = probeTimeout
        config.hedgeDelayMilliseconds = hedgeMilliseconds
        config.maxRaceEndpoints = maxRace
        config.contextLimitTokens = contextLimit
        config.displayModelName = displayModel
        config.monitoringEnabled = monitoring
        config.exposeAllModels = exposeAllModels
        config.firstByteHedgeMilliseconds = firstByteHedge
        router.apply(config)
        alertTitle = "已保存"
        alertMessage = "路由参数已生效，并已重新探测。"
        showAlert = true
    }

    private func latencyText(_ health: EndpointHealth) -> String {
        if let latency = health.latencyMilliseconds {
            return "\(latency) ms"
        }
        return "未测速"
    }

    private func color(for state: EndpointHealthState) -> Color {
        switch state {
        case .healthy: return .green
        case .unknown: return .gray
        case .degraded: return .orange
        case .cooling: return .red
        case .disabled: return .secondary
        }
    }
}

private struct RouterEndpointRow: View {
    let endpoint: AIEndpoint
    let health: EndpointHealth
    let onToggle: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(endpoint.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text("\(endpoint.displayModel) · \(latencyText) · \(health.state.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = health.lastError, !error.isEmpty {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { endpoint.enabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private var latencyText: String {
        if let latency = health.latencyMilliseconds {
            return "\(latency) ms"
        }
        return "未测速"
    }

    private var color: Color {
        switch health.state {
        case .healthy: return .green
        case .unknown: return .gray
        case .degraded: return .orange
        case .cooling: return .red
        case .disabled: return .secondary
        }
    }
}

private struct EndpointEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: EndpointRouter

    @State private var draft: AIEndpoint
    @State private var alertMessage = ""
    @State private var showAlert = false

    private let isNew: Bool

    init(endpoint: AIEndpoint, isNew: Bool) {
        _draft = State(initialValue: endpoint)
        self.isNew = isNew
    }

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("名称", text: $draft.name)
                TextField("Base URL，例如 https://api.example.com/v1", text: $draft.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("API Key（可留空）", text: $draft.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("模型，例如 gpt-4o-mini（留空则用客户端 model）", text: $draft.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                NavigationLink {
                    ModelImportView(
                        baseURL: draft.trimmedBaseURL,
                        apiKey: draft.apiKey,
                        onAdded: { dismiss() }
                    )
                    .environmentObject(router)
                } label: {
                    Label("获取模型并批量添加", systemImage: "square.stack.3d.up")
                }
            } footer: {
                Text("用上面的 Base URL 和 API Key 拉取模型列表，勾选后一次性生成多个端点。")
            }

            Section("路径与鉴权") {
                TextField("健康检查路径", text: $draft.healthPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("聊天路径", text: $draft.chatPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("鉴权请求头", text: $draft.apiKeyHeader)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("鉴权前缀", text: $draft.apiKeyPrefix)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Stepper(value: $draft.priority, in: 0...1_000, step: 10) {
                    HStack {
                        Text("优先级")
                        Spacer()
                        Text("\(draft.priority)")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("启用", isOn: $draft.enabled)
            } footer: {
                Text("优先级数字越小越优先；实际排序优先看健康状态和延迟。")
            }
        }
        .navigationTitle(isNew ? "添加端点" : "编辑端点")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") {
                    save()
                }
            }
        }
        .alert(alertMessage, isPresented: $showAlert) {
            Button("好", role: .cancel) {}
        }
    }

    private func save() {
        let base = draft.trimmedBaseURL
        guard let url = URL(string: base), url.scheme != nil, url.host != nil else {
            alertMessage = "Base URL 无效，请填完整地址。"
            showAlert = true
            return
        }
        draft.baseURL = base
        router.upsertEndpoint(draft)
        dismiss()
    }
}
// MARK: - 从 API 获取模型

private struct ModelImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: EndpointRouter

    @State private var baseURL: String
    @State private var apiKey: String
    @State private var apiKeyHeader = "Authorization"
    @State private var apiKeyPrefix = "Bearer "
    @State private var modelsPath = "/models"
    @State private var models: [String] = []
    @State private var selected: Set<String> = []
    @State private var isFetching = false
    @State private var errorMessage: String?

    /// 从“添加/编辑端点”里进来时，用它把外层 sheet 一起关掉。
    private let onAdded: (() -> Void)?

    init(baseURL: String = "", apiKey: String = "", onAdded: (() -> Void)? = nil) {
        _baseURL = State(initialValue: baseURL)
        _apiKey = State(initialValue: apiKey)
        self.onAdded = onAdded
    }

    var body: some View {
        Form {
            Section {
                TextField("Base URL，例如 https://api.example.com/v1", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("API")
            } footer: {
                Text("粘贴 Base URL（一般到 /v1）和密钥，点“获取模型”。粘成 .../chat/completions 也会自动修正。")
            }

            Section {
                Button {
                    Task { await fetchModels() }
                } label: {
                    HStack(spacing: 8) {
                        if isFetching {
                            ProgressView()
                        }
                        Text(isFetching ? "正在获取模型…" : "获取模型")
                    }
                }
                .disabled(isFetching || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                DisclosureGroup("鉴权与路径") {
                    TextField("鉴权请求头", text: $apiKeyHeader)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("鉴权前缀", text: $apiKeyPrefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("模型列表路径", text: $modelsPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            if let message = errorMessage {
                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if !models.isEmpty {
                Section {
                    HStack(spacing: 12) {
                        Button("全选") {
                            selected = Set(models)
                        }
                        Button("清空") {
                            selected.removeAll()
                        }
                        Spacer()
                        Text("\(selected.count)/\(models.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)

                    ForEach(models, id: \.self) { model in
                        Button {
                            toggle(model)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selected.contains(model) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(model) ? Color.accentColor : Color.secondary)
                                Text(model)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("模型（\(models.count)）")
                } footer: {
                    Text("每个模型会生成一个端点，全部参与自动探测和竞速选路。")
                }

                Section {
                    Button {
                        selected = Set(models)
                        addSelected()
                    } label: {
                        Label("一键全选并添加全部（\(models.count) 个）", systemImage: "plus.circle.fill")
                    }

                    Button {
                        addSelected()
                    } label: {
                        Label("只添加选中的 \(selected.count) 个", systemImage: "checkmark.circle")
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .navigationTitle("获取模型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("关闭") { dismiss() }
            }
        }
    }

    private func toggle(_ model: String) {
        if selected.contains(model) {
            selected.remove(model)
        } else {
            selected.insert(model)
        }
    }

    private func fetchModels() async {
        isFetching = true
        errorMessage = nil
        let result = await router.discoverModels(
            baseURL: baseURL,
            apiKey: apiKey,
            apiKeyHeader: apiKeyHeader,
            apiKeyPrefix: apiKeyPrefix,
            modelsPath: modelsPath
        )
        isFetching = false
        if let error = result.error {
            models = []
            selected = []
            errorMessage = error
            return
        }
        models = result.models
        selected = Set(result.models)
        if models.isEmpty {
            errorMessage = "没有取到模型，检查 Key 或模型列表路径"
        }
    }

    private func addSelected() {
        let list = models.filter { selected.contains($0) }
        guard !list.isEmpty else { return }
        let host = URL(string: EndpointRouter.normalizedBaseURL(baseURL))?.host ?? ""
        let added = router.addEndpoints(
            baseURL: baseURL,
            apiKey: apiKey,
            apiKeyHeader: apiKeyHeader,
            apiKeyPrefix: apiKeyPrefix,
            chatPath: "/chat/completions",
            healthPath: modelsPath.isEmpty ? "/models" : modelsPath,
            models: list,
            namePrefix: host
        )
        if added == 0 {
            errorMessage = "这些模型已经有端点了，换一个 API 或先删掉旧的。"
            return
        }
        if let onAdded {
            onAdded()
        } else {
            dismiss()
        }
    }
}
