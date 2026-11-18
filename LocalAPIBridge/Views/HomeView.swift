import Foundation
import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var engine: PollingEngine
    @EnvironmentObject private var keeper: BackgroundKeeper
    @EnvironmentObject private var pip: PiPStatusController

    @State private var showHelp = false
    @State private var alertText = ""
    @State private var showAlert = false

    var body: some View {
        NavigationStack {
            List {
                serverSection
                pipSection
                pollingSection
                latestSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("本地 API 桥")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("API 说明")
                }
            }
            .sheet(isPresented: $showHelp) {
                NavigationStack {
                    APIHelpView(
                        port: engine.configuration.normalizedPort,
                        lanAddress: engine.lanBaseURL
                    )
                }
            }
            .alert(alertText, isPresented: $showAlert) {
                Button("好", role: .cancel) {}
            }
            .onAppear {
                engine.refreshAddresses()
            }
        }
    }

    // MARK: - 本地服务

    private var serverSection: some View {
        Section {
            HStack {
                Text("服务状态")
                Spacer()
                Text(engine.serverState.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(serverColor)
            }

            if engine.serverState.isRunning {
                if let lanURL = engine.lanBaseURL {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("局域网访问（电脑 / 同 Wi-Fi 设备）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(lanDashboardURL ?? (lanURL + "/"))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        Text(lanLatestURL ?? (lanURL + "/latest"))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)

                    HStack(spacing: 12) {
                        Button {
                            copy(lanLatestURL ?? (lanURL + "/latest"), message: "接口地址已复制")
                        } label: {
                            Label("复制地址", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            engine.restartServer()
                        } label: {
                            Label("重启服务", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }

                    VStack(spacing: 8) {
                        QRCodeView(text: lanDashboardURL ?? (lanURL + "/"))
                            .frame(width: 132, height: 132)
                            .padding(8)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Text(engine.configuration.accessToken.isEmpty
                             ? "用电脑浏览器扫码打开状态页"
                             : "扫码自动带上访问令牌")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } else {
                    Text("还没有检测到 Wi-Fi 地址。请确认已连接 Wi-Fi；本机仍可通过 127.0.0.1 访问。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("本地服务尚未就绪：\(engine.serverState.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        engine.restartServer()
                    } label: {
                        Label("重启本地服务", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("本机访问（同机 App 可直接调用）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(authenticatedURL(base: engine.localBaseURL, path: "/latest"))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)

            HStack {
                Text("后台保活")
                Spacer()
                Text(keeper.isActive ? "已开启" : "未开启")
                    .foregroundStyle(keeper.isActive ? Color.green : Color.secondary)
            }

            if let error = keeper.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("本地 API 服务")
        } footer: {
            Text("第三方 App 调用 http://127.0.0.1:\(engine.configuration.normalizedPort)/latest 即可拿到最新一次轮询结果；电脑在同一 Wi-Fi 下使用上面的局域网地址。设置访问令牌后，请使用带 ?token= 的完整地址，或在请求头里带 X-API-Key。首次监听时系统会询问本地网络权限，请选择允许。")
        }
    }

    private var lanLatestURL: String? {
        engine.lanBaseURL.map { authenticatedURL(base: $0, path: "/latest") }
    }

    private var lanDashboardURL: String? {
        engine.lanBaseURL.map { authenticatedURL(base: $0, path: "/") }
    }

    private func authenticatedURL(base: String, path: String) -> String {
        let token = engine.configuration.accessToken
        guard !token.isEmpty, var components = URLComponents(string: base + path) else {
            return base + path
        }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url?.absoluteString ?? (base + path)
    }

    private var serverColor: Color {
        switch engine.serverState {
        case .running(_):
            return .green
        case .starting, .waiting(_):
            return .orange
        case .failed(_):
            return .red
        case .stopped:
            return .gray
        }
    }


    // MARK: - 画中画

    private var pipSection: some View {
        Section {
            HStack {
                Text("画中画浮窗")
                Spacer()
                Text(pipStatusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(pipColor)
            }

            Text("切到其它 App 或回到桌面后，系统画中画会持续显示当前模型、上下文使用、时间和系统运行秒数，同时保持轮询与本地服务。锁屏时系统通常不显示浮窗。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                pip.startNow()
            } label: {
                Label("立即开启画中画", systemImage: "pip")
            }
            .buttonStyle(.bordered)
            .disabled(!pip.isEnabled)

            if let error = pip.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("画中画保活")
        } footer: {
            Text("在“设置 → 后台常驻”里打开开关。开启后切后台会自动出现浮窗；也可用上面的按钮手动开启。")
        }
    }

    private var pipStatusText: String {
        if !pip.isSupported {
            return "不支持"
        }
        if pip.isActive {
            return "画中画运行中"
        }
        if pip.isEnabled {
            return pip.isPossible ? "已就绪" : "等待就绪"
        }
        return "未开启"
    }

    private var pipColor: Color {
        if !pip.isSupported {
            return .red
        }
        if pip.isActive {
            return .green
        }
        if pip.isEnabled {
            return .blue
        }
        return .secondary
    }

    // MARK: - 轮询

    private var pollingSection: some View {
        Section {
            HStack {
                Text("轮询状态")
                Spacer()
                Text(engine.pollingStatusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(engine.isPolling ? Color.green : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("目标接口")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(engine.configuration.trimmedURLString)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text("\(engine.configuration.method.rawValue) · 每 \(Int(engine.configuration.normalizedInterval)) 秒 · 超时 \(Int(engine.configuration.normalizedTimeout)) 秒")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack {
                    Text("下一次轮询")
                    Spacer()
                    Text(engine.countdownText(at: context.date))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button {
                    engine.pollNow(trigger: "manual")
                } label: {
                    Label("立即轮询", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.isRefreshing)

                Button {
                    if engine.isPaused {
                        engine.resumePolling()
                    } else {
                        engine.pausePolling()
                    }
                } label: {
                    Label(engine.isPaused ? "继续" : "暂停", systemImage: engine.isPaused ? "play.circle" : "pause.circle")
                }
                .buttonStyle(.bordered)
            }

            HStack {
                Text("成功 / 失败")
                Spacer()
                Text("\(engine.successCount) / \(engine.failureCount)")
                    .foregroundStyle(.secondary)
            }

            if let error = engine.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("自动轮询")
        } footer: {
            Text("轮询在 App 运行期间自动进行；开启后台保活后，锁屏或切到后台也能继续。间隔可在设置里修改。")
        }
    }

    // MARK: - 最新结果

    private var latestSection: some View {
        Section {
            if let record = engine.latestRecord {
                HStack(spacing: 10) {
                    Circle()
                        .fill(record.success ? Color.green : Color.red)
                        .frame(width: 9, height: 9)
                    Text(record.statusText)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(record.timeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("耗时")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(record.durationMilliseconds) ms")
                }

                HStack {
                    Text("大小")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(record.byteCount) 字节")
                }

                if !record.bodyText.isEmpty {
                    Text(record.preview)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(6)
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    RecordDetailView(record: record)
                } label: {
                    Text("查看完整响应")
                }
            } else {
                Text("还没有轮询记录，点“立即轮询”试试。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("最新一次结果")
        }
    }

    private func copy(_ text: String, message: String) {
        UIPasteboard.general.string = text
        alertText = message
        showAlert = true
    }
}

private struct QRCodeView: View {
    let text: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .onAppear {
            image = NetworkInfo.qrCodeImage(from: text)
        }
        .onChange(of: text) { _ in
            image = NetworkInfo.qrCodeImage(from: text)
        }
    }
}