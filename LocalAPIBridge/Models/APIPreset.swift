import Foundation

/// 内置的免费接口示例，方便第一次使用时快速验证。
struct APIPreset: Identifiable {
    let id: String
    let title: String
    let detail: String
    let urlString: String
    let method: HTTPMethodOption
    let intervalSeconds: Double

    func applying(to base: PollConfiguration) -> PollConfiguration {
        var config = base
        config.name = title
        config.urlString = urlString
        config.method = method
        config.intervalSeconds = intervalSeconds
        config.headers = [HeaderPair(key: "Accept", value: "application/json")]
        config.body = ""
        return config
    }

    static let all: [APIPreset] = [
        APIPreset(
            id: "open-meteo",
            title: "北京实时天气",
            detail: "Open-Meteo · 免费、无需 Key",
            urlString: "https://api.open-meteo.com/v1/forecast?latitude=39.9042&longitude=116.4074&current=temperature_2m,relative_humidity_2m,wind_speed_10m",
            method: .get,
            intervalSeconds: 60
        ),
        APIPreset(
            id: "hitokoto",
            title: "一言 · 随机句子",
            detail: "Hitokoto · 免费、无需 Key",
            urlString: "https://v1.hitokoto.cn/?encode=json",
            method: .get,
            intervalSeconds: 30
        ),
        APIPreset(
            id: "exchange-rate",
            title: "美元汇率",
            detail: "open.er-api.com · 免费、无需 Key",
            urlString: "https://open.er-api.com/v6/latest/USD",
            method: .get,
            intervalSeconds: 300
        ),
        APIPreset(
            id: "github-zen",
            title: "GitHub Zen",
            detail: "GitHub · 纯文本",
            urlString: "https://api.github.com/zen",
            method: .get,
            intervalSeconds: 120
        ),
        APIPreset(
            id: "ipify",
            title: "公网 IP",
            detail: "ipify · 免费、无需 Key",
            urlString: "https://api.ipify.org?format=json",
            method: .get,
            intervalSeconds: 300
        )
    ]
}
