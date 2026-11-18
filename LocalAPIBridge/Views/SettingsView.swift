import Foundation
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var engine: PollingEngine
    @EnvironmentObject private var keeper: BackgroundKeeper
    @EnvironmentObject private var pip: PiPStatusController

    @AppStorage("localapibridge.keepAlive") private var keepAlive = false
    @AppStorage("localapibridge.screenAlwaysOn") private var screenAlwaysOn = false
    @AppStorage("localapibridge.pipKeepAlive") private var pipKeepAlive = false

    @State private var draft = PollConfiguration()
    @State private var portText = "8787"
    @State private var presetID = ""
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                presetSection
                taskSection
                headersSection
                bodySection
                serverSection
                backgroundSection
                pipSection
                actionSection
                aboutSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("设置")
            .onAppear {
                loadIfNeeded()
            }
            .alert(alertTitle, isPresented: $showAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
    }

    // MARK: - 快速填充

    private var presetSection: some View {
        Section {
            Picker("示例接口", selection: $presetID) {
                Text("选择后自动填充").tag("")
                ForEach(APIPreset.all) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            .onChange(of: presetID) { newValue in
                applyPreset(id: newValue)
            }
        } header: {
            Text("快速填充")
        } footer: {
            Text("这些都是免费、通常无需 Key 的公开接口，可用来快速验证轮询与本地服务是否正常。")
        }
    }

    // MARK: - 轮询任务

    private var taskSection: some View {
        Section {
            TextField("接口地址", text: $draft.urlString)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))

            Picker("请求方法", selection: $draft.method) {
                ForEach(HTTPMethodOption.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.segmented)

            Stepper(value: $draft.intervalSeconds, in: 2...3600, step: 5) {
                HStack {
                    Text("轮询间隔")
                    Spacer()
                    Text("\(Int(draft.intervalSeconds)) 秒")
                        .foregroundStyle(.secondary)
                }
            }

            Stepper(value: $draft.timeoutSeconds, in: 3...120, step: 1) {
                HStack {
                    Text("超时时间")
                    Spacer()
                    Text("\(Int(draft.timeoutSeconds)) 秒")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("启用自动轮询", isOn: $draft.enabled)
        } header: {
            Text("轮询任务")
        } footer: {
            Text("间隔建议不低于 10 秒，避免给免费接口造成压力。进入后台后是否继续，取决于下面的“后台常驻”。")
        }
    }

    // MARK: - 请求头

    private var headersSection: some View {
        Section {
            if draft.headers.isEmpty {
                Text("没有自定义请求头")
                    .foregroundStyle(.secondary)
            }

            ForEach($draft.headers) { $header in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("名称，例如 Accept", text: $header.key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                    TextField("值，例如 application/json", text: $header.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .onDelete { offsets in
                draft.headers.remove(atOffsets: offsets)
            }

            Button {
                draft.headers.append(HeaderPair())
            } label: {
                Label("添加请求头", systemImage: "plus.circle")
            }
        } header: {
            Text("请求头")
        }
    }

    // MARK: - 请求体

    private var bodySection: some View {
        Section {
            TextEditor(text: $draft.body)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 90)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("请求体（仅 POST 时发送）")
        }
    }

    // MARK: - 本地服务

    private var serverSection: some View {
        Section {
            HStack {
                Text("服务端口")
                Spacer()
                TextField("8787", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }

            TextField("访问令牌（可留空）", text: $draft.accessToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))

            Button {
                let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                draft.accessToken = String(raw.prefix(24))
            } label: {
                Label("生成随机令牌", systemImage: "key")
            }

            HStack {
                Text("当前运行地址")
                Spacer()
                Text("http://127.0.0.1:\(engine.configuration.normalizedPort)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("本地服务")
        } footer: {
            Text("端口范围 1024–65535，修改后保存会自动重启服务。设置访问令牌后，所有接口都需要带 X-API-Key 请求头或 ?token= 参数；同一 Wi-Fi 下建议开启，避免别人随意读取。")
        }
    }

    // MARK: - 后台常驻

    private var backgroundSection: some View {
        Section {
            Toggle("静音音频后台保活", isOn: $keepAlive)
                .onChange(of: keepAlive) { newValue in
                    if newValue {
                        if !keeper.start() {
                            keepAlive = false
                        }
                    } else {
                        keeper.stop()
                    }
                }

            Toggle("屏幕保持常亮", isOn: $screenAlwaysOn)
                .onChange(of: screenAlwaysOn) { newValue in
                    keeper.setScreenAlwaysOn(newValue)
                }

            HStack {
                Text("保活状态")
                Spacer()
                Text(keeper.isActive ? "运行中" : "未开启")
                    .foregroundStyle(keeper.isActive ? Color.green : Color.secondary)
            }

            if let error = keeper.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("后台常驻")
        } footer: {
            Text("iOS 会在 App 进入后台后暂停进程。开启静音音频后，只要系统没有终止本 App，轮询和本地服务就会继续；代价是耗电增加。该做法不符合 App Store 对后台音频用途的审核要求，适合个人自用或侧载；从 App 切换器关闭本 App 后服务立即停止。")
        }
    }


    // MARK: - 画中画

    private var pipSection: some View {
        Section {
            Toggle("画中画保活（显示运行信息）", isOn: $pipKeepAlive)
                .onChange(of: pipKeepAlive) { newValue in
                    pip.setEnabled(newValue)
                }

            TextField("显示模型名称（留空则自动识别）", text: $draft.displayModelName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack {
                Text("上下文上限（tokens）")
                Spacer()
                TextField("128000", value: $draft.contextLimitTokens, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
            }

            HStack {
                Text("画中画状态")
                Spacer()
                Text(pip.isActive ? "运行中" : (pip.isEnabled ? "已开启" : "未开启"))
                    .foregroundStyle(pip.isActive ? Color.green : Color.secondary)
            }

            Button {
                pip.startNow()
            } label: {
                Label("立即开启画中画", systemImage: "pip")
            }
            .disabled(!pip.isEnabled)

            if let error = pip.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("画中画浮窗")
        } footer: {
            Text("iOS 16+。开启后切到后台会自动出现画中画，浮窗显示模型、上下文使用、时间、系统运行秒数；画中画期间 App 保持运行。模型和 token 会尽量从上游 JSON 的 model / usage.total_tokens 等字段自动读取，读不到时用上面的模型名称和上限显示。")
        }
    }

    // MARK: - 操作

    private var actionSection: some View {
        Section {
            Button {
                save()
            } label: {
                Text("保存并应用")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button(role: .destructive) {
                reset()
            } label: {
                Text("恢复默认设置")
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            HStack {
                Text("版本")
                Spacer()
                Text("1.0")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("本机接口")
                Spacer()
                Text("http://127.0.0.1:\(engine.configuration.normalizedPort)/latest")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("关于")
        } footer: {
            Text("Local API Bridge · iPhone 本地轮询 + 局域网 API 服务。所有请求都从本机发出，不经过第三方服务器。")
        }
    }

    // MARK: - 行为

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        draft = engine.configuration
        portText = String(engine.configuration.serverPort)
    }

    private func applyPreset(id: String) {
        guard !id.isEmpty, let preset = APIPreset.all.first(where: { $0.id == id }) else { return }
        draft = preset.applying(to: draft)
        portText = String(draft.serverPort)
        presetID = ""
    }

    private func save() {
        var config = draft
        let trimmedPort = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedPort = Int(trimmedPort) else {
            presentAlert(title: "端口无效", message: "请输入 1024 到 65535 之间的数字。")
            return
        }
        guard parsedPort >= 1024, parsedPort <= 65_535 else {
            presentAlert(title: "端口无效", message: "端口需要在 1024 到 65535 之间。")
            return
        }
        config.serverPort = parsedPort

        let sanitized = config.sanitized
        guard sanitized.validatedURL != nil else {
            presentAlert(title: "地址无效", message: "请填写完整的 http:// 或 https:// 接口地址。")
            return
        }

        draft = sanitized
        portText = String(sanitized.serverPort)
        engine.apply(sanitized)
        presentAlert(title: "已保存", message: "配置已生效。如果修改了端口，本地服务会自动重启。")
    }

    private func reset() {
        draft = PollConfiguration()
        portText = String(draft.serverPort)
        engine.apply(draft)
        presentAlert(title: "已恢复默认", message: "默认示例接口已写入并开始轮询。")
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}
