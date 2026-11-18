import SwiftUI

struct APIHelpView: View {
    let port: Int
    var lanAddress: String? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                endpoint("GET /", "浏览器状态页，每 5 秒自动刷新")
                endpoint("GET /healthz", "健康检查，返回 {\"ok\":true}")
                endpoint("GET /status", "服务、轮询、上游和最新结果的完整状态")
                endpoint("GET /latest", "最新一次成功轮询的原始响应，保持上游的 Content-Type")
                endpoint("GET /raw", "与 /latest 相同的别名")
                endpoint("GET /latest?pretty=1", "把 JSON 美化后返回，方便调试")
                endpoint("GET /json", "带元信息的 JSON 包装，上游内容放在 body 字段")
                endpoint("GET /history?limit=20", "最近轮询记录，limit 最大 200")
                endpoint("POST /refresh", "立即触发一次轮询，返回 202")
            } header: {
                Text("接口列表")
            } footer: {
                Text("所有接口都附带 CORS 头，可被局域网内的网页直接调用。")
            }

            Section("访问地址") {
                addressRow("本机 App", "http://127.0.0.1:\(port)/latest")
                addressRow("局域网电脑", (lanAddress ?? "http://<iPhone 的 IP>:\(port)") + "/latest")
                addressRow("状态页", (lanAddress ?? "http://<iPhone 的 IP>:\(port)") + "/")
            }

            Section("示例") {
                code("curl http://127.0.0.1:\(port)/latest")
                code("curl -X POST http://127.0.0.1:\(port)/refresh")
                code("curl \"http://192.168.1.23:\(port)/latest?pretty=1\"")
                code("curl -H \"X-API-Key: 你的令牌\" http://192.168.1.23:\(port)/status")
            }

            Section("说明") {
                Text("有缓存数据时 /latest 返回 200；从未成功轮询过返回 503。上游最近一次失败时会继续返回上一次成功的数据，响应头 X-Bridge-Last-Success 与 X-Bridge-Age-Seconds 会标明状态和数据的“年龄”。")
                Text("iPhone 上的第三方 App 若要用 http://127.0.0.1 访问，需要在它自己的 Info.plist 里开启 App Transport Security 的本地网络例外，例如 NSAllowsLocalNetworking = YES；Safari 和多数调试工具不受此限制。")
                Text("电脑和手机必须在同一个 Wi-Fi / 局域网，且路由器未开启 AP 隔离。iOS 首次监听端口时会弹窗请求“本地网络”权限。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("API 说明")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") {
                    dismiss()
                }
            }
        }
    }

    private func endpoint(_ path: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(path)
                .font(.system(.footnote, design: .monospaced))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func addressRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
    }
}
