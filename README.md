# Local API Bridge · iPhone 本地 API 轮询服务

一个用 **Swift + SwiftUI + Network.framework** 写的原生 iOS App：

- 在 iPhone 上按设定间隔**自动轮询**一个免费 HTTP API；
- 把最新结果缓存在本机；
- 在 iPhone 上开一个**本地 HTTP 服务**（默认 `8787` 端口），
  - 同机其他 App 可用 `http://127.0.0.1:8787/latest` 调用；
  - 同一 Wi-Fi 下的电脑可用 `http://<iPhone 的 IP>:8787/latest` 调用；
- 提供网页状态页、二维码、Bonjour 广播、访问令牌、历史记录；
- 可选**静音音频**或**原生画中画（PiP）**后台保活，让 App 在锁屏 / 切后台后继续轮询和提供服务；
- 画中画浮窗实时显示**当前模型、上下文 token 使用、时间、系统运行秒数**。

> 这个仓库里的代码是在没有 Xcode 的环境里写的，尚未经过真机编译。请在 Mac 上用 Xcode 打开后先 Build 一次；如果遇到编译报错，把报错发回来即可继续修。

---

## 1. 它解决什么问题

很多免费 API 有频率限制、需要 Key、或者只能在某个网络里访问。这个 App 把 iPhone 当成一台小小的“API 缓存代理”：

```
免费 API  ──(自动轮询)──►  iPhone App  ──(本地 HTTP)──►  同机 App / 局域网电脑
                              │
                              └── 最新响应 + 状态页 + 历史记录
```

调用方不需要知道上游 API 的地址、Key 或频率限制，只需要访问 iPhone 的 `/latest`。

---

## 2. 功能一览

| 功能 | 说明 |
|---|---|
| 自动轮询 | GET/POST、自定义请求头、请求体、超时、2–3600 秒间隔 |
| 本地 HTTP 服务 | `NWListener` 实现，监听 `0.0.0.0:8787`（端口可改） |
| 局域网访问 | 自动显示 Wi-Fi IP，附带二维码直达状态页 |
| 同机调用 | `http://127.0.0.1:8787/latest` |
| Bonjour | 广播 `_http._tcp` 服务，服务名为 `LocalAPIBridge` |
| 最新结果 | `/latest` 原样返回上游响应，保留 Content-Type |
| JSON 包装 | `/json` 附带时间、状态码、耗时等元信息 |
| 历史记录 | `/history`、App 内记录列表、失败筛选、详情复制；切换上游地址会清空旧接口记录 |
| 手动触发 | `POST /refresh` 或 App 内“立即轮询” |
| 访问令牌 | 可选 `X-API-Key` / `Bearer` / `?token=` 鉴权 |
| 后台保活 | 静音音频 + `UIBackgroundModes=audio`，可选开关 |
| 画中画保活 | 原生 PiP 浮窗，显示模型 / 上下文 / 时间 / 系统运行秒数 |
| 模型与上下文 | 自动读取上游 JSON 的 `model`、`usage.total_tokens` 等字段 |
| 屏幕常亮 | 可选，调试或需要长时间前台运行时使用 |
| 示例接口 | Open-Meteo、Hitokoto、汇率、GitHub Zen、ipify |
| AI 多端点 | 多个自定义 AI API，按健康状态/延迟自动排序 |
| 订阅导入 | 一个 URL 批量导入端点，6 小时自动刷新 |
| 200ms 兜底 | 首选 200ms 未完成时并发启动后续端点，先成功者胜出 |
| 本地 AI 入口 | `POST /v1/chat/completions`（OpenAI 兼容，非流式） |

---

## 3. 构建与安装（必须有一台 Mac）

### 环境要求

- macOS，**Xcode 15 或更新**（建议 Xcode 16/17；工程使用 iOS 16.0 部署目标）；
- 一台 iOS 16 及以上的 iPhone（在 iOS 26 上也可用）；
- Apple ID（免费账号即可，签名 7 天有效；付费开发者账号 1 年）。

### 步骤

1. 把整个目录拷贝到 Mac，双击 `LocalAPIBridge.xcodeproj`。
2. 左侧选中 **LocalAPIBridge** target → **Signing & Capabilities**：
   - 勾选 **Automatically manage signing**；
   - 选择自己的 **Team**；
   - 把 **Bundle Identifier** 改成唯一值，例如 `com.你的名字.localapibridge`。
3. 用数据线连接 iPhone，在 Xcode 顶部选择这台设备，点击 **Run**（⌘R）。
4. 首次运行如果提示“不受信任的开发者”，到 iPhone 的
   **设置 → 通用 → VPN 与设备管理** 里信任你的开发者证书。
5. 首次启动 App 时，系统会弹窗请求 **本地网络** 权限，请选择 **允许**。
6. 让 iPhone 和电脑连接 **同一个 Wi-Fi**。

> 如果只想在模拟器里看 UI：选择任意 iPhone Simulator 直接 Run。模拟器的 `127.0.0.1` 指的是 Mac 自己，局域网地址不可用。

### 不想本地构建？

仓库 [yoyo520956/LocalAPIBridge](https://github.com/yoyo520956/LocalAPIBridge) 配了 GitHub Actions：推送代码后自动在 macOS runner 上构建 **未签名 IPA**，并发布到 Releases。详见第 13 节。

### 命令行构建（可选）

```bash
xcodebuild \
  -project LocalAPIBridge.xcodeproj \
  -scheme LocalAPIBridge \
  -configuration Debug \
  -destination 'platform=iOS,id=<你的 iPhone UDID>' \
  DEVELOPMENT_TEAM=<你的 Team ID> \
  CODE_SIGN_STYLE=Automatic \
  build
```

---

## 4. 使用流程

1. 打开 App → **设置** → “快速填充”里选一个免费示例（默认是北京天气），或者填自己的接口地址。
2. 设置轮询间隔（默认 60 秒），需要时填写请求头 / POST 请求体。
3. 点 **保存并应用**，App 会立即轮询一次，然后按间隔自动轮询。
4. 回到 **概览**：
   - 看到“服务状态：运行中 · 端口 8787”；
   - 看到局域网地址和二维码；
   - 点“立即轮询”可手动刷新。
5. 电脑浏览器打开 `http://<iPhone IP>:8787/`，或直接扫二维码，可看到状态页和最新 JSON。
6. 想让 App 在锁屏后继续工作：**设置 → 后台常驻 → 静音音频后台保活**。

### 默认访问地址

| 场景 | 地址 |
|---|---|
| iPhone 本机其他 App | `http://127.0.0.1:8787/latest` |
| 同 Wi-Fi 电脑 | `http://<iPhone 的 Wi-Fi IP>:8787/latest` |
| 状态页 | `http://<iPhone 的 Wi-Fi IP>:8787/` |
| 健康检查 | `http://<iPhone 的 Wi-Fi IP>:8787/healthz` |

> 端口、访问令牌都在“设置 → 本地服务”里修改，保存后会自动重启监听。
>
> ⚠️ 默认**不设访问令牌**，同一 Wi-Fi 内任何设备都能读取 `/latest`。在公共网络或多人网络里，请务必设置令牌（设置页会提供“生成随机令牌”）。

---

## 5. HTTP API 文档

所有接口都返回 CORS 头（`Access-Control-Allow-Origin: *`），允许局域网网页直接调用。

### 5.1 接口列表

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/` | HTML 状态页，每 5 秒自动刷新，含“立即轮询”按钮 |
| GET | `/healthz` | 健康检查，返回 `{"ok":true}` |
| GET | `/status` | 服务、轮询、上游、最新结果的完整 JSON |
| GET | `/latest` | 最近一次**成功**轮询的原始响应体，保留上游 Content-Type |
| GET | `/raw` | `/latest` 的别名 |
| GET | `/latest?pretty=1` | 若响应是 JSON，则美化后返回 |
| GET | `/json` | 包装后的 JSON：元信息 + `body` 字段 |
| GET | `/history?limit=20` | 最近 N 条轮询记录，`limit` 最大 200 |
| POST | `/refresh` | 立即触发一次轮询，返回 `202 Accepted` |
| OPTIONS | 任意 | CORS 预检，返回 204 |

### 5.2 `/latest` 响应头

| 响应头 | 含义 |
|---|---|
| `Content-Type` | 上游返回的类型原样透传 |
| `X-Bridge-Last-Fetched` | 最近一次成功时间（ISO 8601） |
| `X-Bridge-Last-Attempt` | 最近一次尝试时间 |
| `X-Bridge-Last-Status` | 最近一次上游 HTTP 状态码 |
| `X-Bridge-Last-Success` | 最近一次尝试是否成功（`true` / `false`） |
| `X-Bridge-Age-Seconds` | 当前数据距最近成功时间的秒数 |

行为约定：

- **有缓存数据**：`/latest` 返回 `200`，即使最近一次尝试失败也继续返回上一次成功的数据（响应头会标注 `false` 和 age）；
- **冷启动**：最近一次成功响应会保存到磁盘（最大 2 MB，只对同一上游地址与方法生效），所以重启 App 后 `/latest` 仍能立即返回上一次结果，不必等第一次轮询；
- **从未成功过**：返回 `503`；
- **上游 4xx/5xx**：记录为失败，但不会覆盖上一次成功的数据。

### 5.3 鉴权

在“设置 → 本地服务 → 访问令牌”里设置非空值后，**所有接口**都需要携带令牌，三种方式任选：

```bash
# 请求头
curl -H "X-API-Key: 你的令牌" http://127.0.0.1:8787/latest

# Bearer
curl -H "Authorization: Bearer 你的令牌" http://127.0.0.1:8787/status

# 查询参数
curl "http://192.168.1.23:8787/latest?token=你的令牌"
```

状态页支持 `http://<IP>:8787/?token=你的令牌`，页面里的“立即轮询”会自动带上令牌。

### 5.4 示例

```bash
# 取最新数据
curl http://127.0.0.1:8787/latest

# 美化 JSON
curl "http://127.0.0.1:8787/latest?pretty=1"

# 查看状态
curl http://127.0.0.1:8787/status

# 触发一次轮询
curl -X POST http://127.0.0.1:8787/refresh

# 最近 5 条记录
curl "http://127.0.0.1:8787/history?limit=5"
```

Python：

```python
import requests
data = requests.get("http://127.0.0.1:8787/latest", timeout=5).json()
print(data)
```

Swift（另一个 App 内调用）：

```swift
let url = URL(string: "http://127.0.0.1:8787/latest")!
let (data, _) = try await URLSession.shared.data(from: url)
print(String(decoding: data, as: UTF8.self))
```

> 第三方 App 访问 `http://` 本地地址时，iOS 的 ATS 默认会拦截。对方 App 需要在它的 `Info.plist` 中加入本地网络例外，例如：
>
> ```xml
> <key>NSAppTransportSecurity</key>
> <dict>
>     <key>NSAllowsLocalNetworking</key>
>     <true/>
> </dict>
> ```
>
> 如果对方连局域网 IP 也要访问，可改用它自己的 `NSAllowsArbitraryLoads` 或 `NSExceptionDomains`。Safari 和 curl 不受 ATS 限制。

---

## 6. AI 多端点路由（重点）

原来的“单 URL 轮询并缓存”仍然保留；新的 **AI 路由** 面向“很多免费 AI API / 订阅，自动挑最快可用”的场景。

### 6.1 三步：粘贴 API → 获取模型 → 一键全选添加

1. 「AI 路由」页 → 端点区点 **“粘贴 API + Key，一键获取模型”**（或右上角 `+` 里也有同样入口）；
2. 填 **Base URL**（一般到 `/v1`，例如 `https://api.example.com/v1`）和 **API Key**，点 **获取模型**；
3. 拉回模型列表后，点 **全选** 或 **一键全选并添加全部（N 个）**，每个模型立刻变成一个端点。

- 鉴权默认 `Authorization: Bearer <key>`，可在“鉴权与路径”里改成 `X-API-Key` 等；
- Base URL 粘成 `.../chat/completions`、`.../models` 会自动修正回 Base；
- 模型列表支持 `data[].id`、`models[].id`、`data: ["a","b"]` 与字符串数组几种常见格式；
- 同一个 Base URL 下已经存在的模型会自动跳过，不会重复添加；
- 添加完立即开始后台探测，**不需要再手动点任何按钮**。

### 6.2 手动添加 / 编辑端点

AI 路由 tab → 右上角 `+`：

| 字段 | 说明 |
|---|---|
| 名称 | 自定义显示名 |
| Base URL | 一般填到 `/v1`，例如 `https://api.example.com/v1` |
| API Key | 上游密钥；留空则透传本地客户端带来的 `Authorization` |
| 模型 | 留空则让上游用默认模型（客户端发 `auto` 时不会把 `auto` 当真模型发上去） |
| 健康检查路径 | 默认 `/models`；留空则不做主动探测 |
| 聊天路径 | 默认 `/chat/completions` |
| 鉴权头 / 前缀 | 默认 `Authorization` / `Bearer `，可改成 `X-API-Key` 等 |
| 优先级 | 同健康状态、同延迟时的排序 |

端点可以单独启用/停用；批量导入在页面底部“高级 → 批量导入手动端点 JSON”，字段为 `name`、`base_url`、`api_key`、`model`、`headers`、`health_path`、`chat_path`、`priority`、`enabled`。

### 6.3 订阅导入

AI 路由页“订阅”区，**每行一个 URL**，保存后自动刷新；启动时超过 6 小时的订阅会自动重新拉取。

订阅内容支持：

- JSON 数组：`[{"name":"free1","base_url":"https://.../v1","api_key":"sk-...","model":"gpt-4o-mini"}]`
- JSON 对象：`{"endpoints":[...]}` 或 `{"data":[...]}`
- 逐行文本：`名称|BaseURL|Key|模型`，或 `BaseURL|Key|模型`
- 每项还支持 `headers`、`health_path`、`chat_path`、`priority`、`enabled`、`api_key_header`、`api_key_prefix`

订阅端点与手动端点分开管理；刷新时按 `BaseURL + model + api_key` 复用原有端点 ID，避免健康状态被重置。**订阅刷新出来的端点，和“获取模型”添加的端点，一样全部参与自动轮询与竞速。**

### 6.4 自动探测与“0.1 秒锁定”

- 后台并行探测所有启用端点，默认每 30 秒一轮，单次超时 2 秒，每批最多 6 个并发；
- 维护每个端点的状态：**可用 / 未探测 / 降级 / 冷却**，并记录最近延迟、成功/失败次数、最近错误；
- 选路排名：可用（按延迟从低到高）→ 未探测 → 降级 → 冷却；
- `/v1/chat/completions` 到来时**直接取排名第一**，不逐个探测，所以“锁定端点”本身是 0 网络等待；
- 首选端点 **0.1 秒（默认 hedge 延迟，可调 20–1000ms）** 内没有返回，就并发启动第 2 个；再过 100ms 启动第 3 个，**先成功者返回**，其余取消；
- 真实请求失败 / 429 / 5xx 也会更新健康状态并进入冷却（5–300 秒；401/403 冷却 10 分钟），下一次请求自动绕开；
- 注意：0.1 秒指**选路 + 兜底启动**的时间，不是模型完整回答的时间；免费 API 出字速度仍取决于上游；
- 竞速会向上游发重复请求（最多 `maxRaceEndpoints` 个，默认 3）。额度紧张时把“最多并发端点”设为 2，或把“并发兜底延迟”调到 300ms 以上，只保留快速失败切换。

### 6.5 本地 AI 入口（OpenAI 兼容）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/v1/chat/completions` | 代理到当前最优端点；统一 `stream=false`，返回完整 JSON |
| GET | `/v1/models` | **只返回一个模型 `auto`**，真实模型由路由在后台自动挑 |
| GET | `/router/status` | 所有端点健康状态、延迟、排名、统计 |
| GET | `/router/best` | 当前最优端点信息（不返回 API Key） |
| POST | `/router/refresh` | 立即重新探测所有端点 |

> 客户端里模型列表会只显示一个 **auto（自动）**；点刷新也还是这一个。这是故意的：你加了多少个模型、多少个订阅都不用改客户端，路由自己换。

示例：

```bash
curl -X POST "http://127.0.0.1:8787/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"你好"}],"stream":false}'

curl "http://127.0.0.1:8787/v1/models"
curl "http://127.0.0.1:8787/router/status"
curl "http://127.0.0.1:8787/router/best"
```

说明：

- `model` 填 `auto` 即可；端点自己配了模型时以端点为准，端点没配则用上游默认模型；
- 上游 Key 优先用端点里配置的；为空时把本地请求的 `Authorization` 透传给上游；
- 目前**不支持 SSE 流式透传**，会把 `stream` 强制为 `false`，返回完整 JSON；需要流式的客户端请先关流式；
- 暂不支持 chunked 请求体；OpenAI SDK / curl 默认的 JSON 请求没问题；
- 返回的是上游原始响应体，Content-Type 原样带回；
- 如果所有端点都失败，返回 JSON 错误（503），并带最后一次失败信息。

### 6.6 画中画显示

配置了 AI 多端点后，画中画浮窗的“模型 / 上下文”优先使用 AI 路由的当前最优端点与最近一次代理响应里的 token 用量；没配置端点时回退到原来的单接口轮询记录。

---

## 7. 后台保活：音频 / 画中画 / 屏幕常亮

iOS 不允许普通 App 永久在后台运行。本 App 提供三种延长存活的手段：

| 手段 | 效果 | 代价 |
|---|---|---|
| **静音音频后台保活**（默认关闭） | 只要系统不杀 App，锁屏/切后台后继续轮询和监听 | 耗电；不符合 App Store 对后台音频的用途审核 |
| **画中画保活**（默认关闭） | 系统画中画浮窗持续显示运行信息，App 保持活跃 | 耗电；用视频通话 PiP 做非通话用途，上架审核有风险 |
| **屏幕保持常亮**（默认关闭） | 前台长期运行，最稳定 | 屏幕一直亮着，耗电且烧屏风险 |

### 7.1 静音音频

- App 声明 `UIBackgroundModes = audio`，循环播放一段 1 秒的静音 WAV；
- 锁屏、切到其他 App、甚至长时间待机，本地端口和轮询都继续工作；
- 从多任务界面**上滑杀掉 App**，服务立即停止——这是 iOS 的机制，无法绕过；
- 低电量模式、系统内存紧张、长时间不活动时，系统仍可能终止 App；
- 被终止后重新打开 App，服务与轮询会自动恢复。

### 7.2 画中画（PiP）保活

设置 → 后台常驻 → **画中画保活（显示运行信息）**。

- 使用 iOS 原生画中画（`AVPictureInPictureVideoCallViewController`），不是录屏或网页模拟；
- 切到其它 App / 回到桌面时自动出现浮窗；锁屏时 iPhone 通常不显示 PiP 浮窗，但音频会话仍尽量维持后台运行；也可以在前台点“立即开启画中画”；
- 浮窗内容每秒刷新：
  - **模型**：优先读取上游 JSON 的 `model` / `model_name` / `model_id`；读不到时用设置里填写的“显示模型名称”；
  - **上下文**：读取 `usage.total_tokens`、`prompt_tokens + completion_tokens`、`context_tokens`、`tokens_used` 等字段，并按“上下文上限（tokens）”计算百分比；这是**最近一次成功响应的 token 用量**，不是整个会话的累计上下文；
  - **时间**：当前时间 `HH:mm:ss`；
  - **系统运行**：`ProcessInfo.systemUptime`，单位秒（设备本次开机以来的秒数）；
  - 底部还有本 App 运行秒数和累计轮询/成功次数；
- 画中画本身会占用音频会话，App 还会循环播放静音音频，因此比单纯音频保活更“重”，耗电也更高；
- 被系统或用户杀掉后同样会停止；
- **注意**：把视频通话 PiP 用于非视频通话用途，上架 App Store 很可能被拒；个人自用 / 侧载没问题。

**上架 App Store 的风险**：静音音频和画中画保活通常都会被审核质疑。个人自用、侧载、TestFlight 内部测试没有问题。

如果不想用音频或 PiP 保活，也可以打开“屏幕保持常亮”，把 App 放在前台当小型服务器用。

---

## 8. 工程结构

```
LocalAPIBridge/
├── App/
│   └── LocalAPIBridgeApp.swift        # @main 入口，注入环境对象
├── Models/
│   ├── PollConfiguration.swift        # 轮询配置 + 校验 + 编解码
│   ├── APIPreset.swift                # 免费接口示例
│   ├── PollRecord.swift               # 一次轮询结果（可持久化）
│   └── AIEndpoint.swift               # AI 端点 / 订阅 / 健康 / 路由配置
├── Services/
│   ├── BridgeStore.swift              # 引擎 ↔ HTTP 服务的线程安全共享状态
│   ├── Persistence.swift              # UserDefaults 配置 + 历史 JSON 文件
│   ├── NetworkInfo.swift              # getifaddrs 取 IPv4 + 二维码
│   ├── SilentAudio.swift              # 生成/复用静音 WAV
│   ├── BackgroundKeeper.swift         # 静音音频 / 屏幕常亮
│   ├── PiPStatusController.swift      # 原生画中画 + 运行信息浮窗
│   ├── PollingEngine.swift            # 单接口轮询、服务生命周期
│   ├── EndpointRouter.swift           # 多端点健康探测 / 排名 / 竞速代理
│   └── LocalHTTPServer.swift          # NWListener + HTTP 路由 + AI 代理
├── Views/
│   ├── ContentView.swift              # TabView + 画中画锚点
│   ├── HomeView.swift                 # 概览、地址、二维码、最新结果
│   ├── RouterView.swift               # AI 多端点 / 订阅 / 路由参数 / 日志
│   ├── HistoryView.swift              # 记录列表与详情
│   ├── SettingsView.swift             # 全部配置
│   └── APIHelpView.swift              # App 内 API 说明
├── Assets.xcassets/                   # App 图标
└── Info.plist                         # 后台音频、本地网络、Bonjour、ATS
```

数据流：

```
SwiftUI Views
     │ 读取 @Published / 调用方法
     ▼
PollingEngine (@MainActor) ── URLSession ──► 免费 API
     │ 写入
     ▼
BridgeStore（NSLock 保护的快照）
     ▲ 读取
LocalHTTPServer（NWListener + 自定义队列）◄── 本机 App / 局域网电脑
```

### 关键设计

- **一次请求一次连接**：响应后立即 `Connection: close`，实现简单、客户端兼容性好；浏览器/curl 都会自动重连。
- **只读缓存**：HTTP 服务不直接访问上游，只读 `BridgeStore`，避免并发请求和频率问题。
- **手动刷新异步化**：`POST /refresh` 只投递任务并返回 202，不阻塞 HTTP 线程。
- **端口变更先等 0.4 秒**：等旧 listener 释放端口后再绑定，减少“Address already in use”。
- **历史写盘节流**：最多每 20 秒写一次，避免频繁写闪存。
- **画中画浮窗**：`PiPStatusController` 用 `AVPictureInPictureVideoCallViewController` 承载一个自定义 UIViewController，每 1 秒把模型、上下文 token、时间、系统运行秒数写入标签页；同一音频会话里循环播放静音 WAV，确保后台执行。

---

## 9. 安全建议

- 在公共 Wi-Fi 或宿舍/办公室网络里，**务必设置访问令牌**；本地服务没有 HTTPS。
- 不要在路由器上把 8787 端口映射到公网；这个 App 只适合局域网。
- App 本身不收集、不上传数据；所有请求只发生在本机与目标上游之间。
- 访问令牌保存在 `UserDefaults`，不是 Keychain；不要复用重要密码。
- 上游 API 的 Key 若放在请求头里，会以明文保存在本机配置中，请自行评估。

---

## 10. 常见问题

**电脑打不开 `http://IP:8787`**

1. iPhone 和电脑是否在同一 Wi-Fi（不是手机热点/访客网络的不同子网）？
2. 路由器是否开启了“AP 隔离/客户端隔离”？开启后设备之间不能互访。
3. iPhone 上是否允许了“本地网络”权限？（设置 → 隐私与安全性 → 本地网络 → 找到本 App）
4. 服务状态是否显示“运行中”？端口是否被其他 App 占用（换个端口再试）？
5. 电脑防火墙是否拦截了局域网访问？
6. 先用 `curl http://127.0.0.1:8787/healthz` 在 iPhone 本机验证，再查网络。

**iPhone 上别的 App 调用 `127.0.0.1:8787` 失败**

- 本 App 必须正在运行（前台，或已开启后台保活）；
- 对方 App 的 ATS 是否允许本地 HTTP（见 5.4 的 `NSAllowsLocalNetworking`）；
- 如果设置了访问令牌，请求要带上 `X-API-Key`。

**显示“等待网络：...”**

通常是本地网络权限未授权或被系统拒绝。到系统设置里打开本 App 的“本地网络”权限，然后回到 App 点“重启服务”。

**显示“启动失败：Address already in use”**

端口被占用。到设置里改成 `8788` 或其他 1024–65535 的端口，保存后会自动重启。

**锁屏一会儿服务就停了**

- 确认“静音音频后台保活”已开启，且首页“后台保活”显示“已开启”；
- 低电量模式会限制后台活动；
- 系统在内存紧张时仍可能杀掉 App，重新打开即可恢复。

**上游接口返回 403 / 429**

免费 API 常有频率限制或需要 `User-Agent`。把轮询间隔调大（如 300 秒），或在请求头里加 `User-Agent` / `Accept`；部分接口需要 Key，请按该接口文档添加请求头。

**换端口后二维码/地址没变**

地址由“当前配置端口”生成；保存后请回到概览页，必要时点“重启服务”。

---

## 11. 辅助脚本（可选）

这些脚本只用于生成/检查工程，不影响 App 运行：

```bash
# 重新生成 Xcode 工程（修改了源文件列表后运行）
python3 tools/generate_project.py

# 校验 pbxproj 结构
python3 tools/validate_pbxproj.py

# 检查 Swift 文件括号/字符串是否平衡（不是编译器）
python3 tools/check_swift_structure.py

# 重新生成 1024×1024 App 图标
python3 tools/make_icon.py
```

---

## 12. 已知限制

- 这是 **HTTP** 服务，不是 HTTPS；局域网内明文传输。
- 不支持 WebSocket、HTTP/2、chunked 请求体、长连接复用。
- 只保留最近 100 条记录；每条响应体最多保存 6000 字符（最新完整响应保存在内存中，并最多缓存 2 MB 到磁盘）。
- AI 代理暂不支持 SSE 流式透传，会强制 `stream=false` 并返回完整 JSON；也不支持 chunked 请求体。
- 多端点竞速默认会同时请求最多 3 个端点；如果不希望重复请求，把“最多并发端点”改成 1。
- 累计轮询次数会持久化保存，历史列表只展示最近 100 条。
- 上游响应完全原样缓存；如果上游是二进制，`/latest` 会原样返回，但历史记录里只显示大小。
- 后台保活不是“永不掉线”，iOS 始终保留终止 App 的权力。
- 画中画的模型/token 只能从常见 JSON 字段推断（`model`、`usage.total_tokens`、`prompt_tokens` 等）；字段名不同或经过加密/压缩时可能读不到，此时用设置里的模型名称和上下文上限显示，百分比会是 0。
- 画中画用 `AVPictureInPictureVideoCallViewController` 实现，本质上是“视频通话画中画”的用途；系统版本、低电量模式或 App Store 审核都可能限制它。
- GitHub Actions 产出的是**未签名 IPA**，必须自己用 AltStore / Sideloadly / 爱思助手重签；签名过期后需要重新签。
- 工程里的 Bundle Identifier 本地是占位值 `com.example.LocalAPIBridge`，签名前必须改成自己的；GitHub workflow 构建时覆盖为 `com.yoyo520956.localapibridge`。

---

## 13. GitHub Actions 自动打包（未签名 IPA）

仓库：<https://github.com/yoyo520956/LocalAPIBridge>

`.github/workflows/build-ipa.yml` 会在 `main` 分支推送时（也可手动 `workflow_dispatch`）执行：

1. `macos-15` runner 上 `xcodebuild` 编译（`CODE_SIGNING_ALLOWED=NO`）；
2. 运行 `python3 tools/make_icon.py` 生成图标；
3. 把 `LocalAPIBridge.app` 打成 `Payload/` 结构的 `LocalAPIBridge-unsigned.ipa`；
4. 上传 workflow artifact，并发布到 Release `v1.0.0`。

当前这一版构建已在 GitHub Actions 的 macOS runner 上成功完成（对应提交 `a9ca798`，包含“粘贴 API + Key → 获取模型 → 一键全选添加”、`/v1/models` 只暴露单个 `auto`、0.1 秒并发兜底、8 MB 请求体上限）。产出的 IPA 内含 arm64 Mach-O（2.2 MB 可执行文件）、`UIBackgroundModes=audio`、`NSLocalNetworkUsageDescription`、`NSBonjourServices`、Bundle ID `com.yoyo520956.localapibridge`、最低 iOS 16.0，已校验二进制里确实带有新界面字符串（例如“一键全选并添加全部”），并已通过 Release 下载校验。

### 13.1 下载

Release 页面：<https://github.com/yoyo520956/LocalAPIBridge/releases/tag/v1.0.0>

原始地址（GitHub）：

```
https://github.com/yoyo520956/LocalAPIBridge/releases/download/v1.0.0/LocalAPIBridge-unsigned.ipa
```

中国大陆加速（把原地址拼在加速前缀后面）：

```
https://ghproxy.net/https://github.com/yoyo520956/LocalAPIBridge/releases/download/v1.0.0/LocalAPIBridge-unsigned.ipa
https://gh-proxy.com/https://github.com/yoyo520956/LocalAPIBridge/releases/download/v1.0.0/LocalAPIBridge-unsigned.ipa
https://ghfast.top/https://github.com/yoyo520956/LocalAPIBridge/releases/download/v1.0.0/LocalAPIBridge-unsigned.ipa
```

SHA256：

```
83a8c360d01c5f63ae67c4449ec073be1029241b21f1d4ad2ab311df47cd3066
```

文件大小：`924267` 字节（约 903 KB）。

> 加速站点是第三方公益服务，可能限速或失效；失效时换一个前缀，或直接走 Release 页面的 “Download” 按钮。也可以把仓库导入自己的 Gitee/私有镜像后用镜像下载。
>
> **注意缓存**：Release 资产文件名固定为 `LocalAPIBridge-unsigned.ipa`，覆盖上传后部分加速节点仍会返回旧包。下载后请务必核对上面的大小和 SHA256。历史上出现过 696944 字节（最早的无 AI 路由版）和 886022 字节（0.2 秒版）两个旧包；只要大小不是 `924267` 就不是这一版。拿到旧包时在加速链接末尾加查询参数强制回源，例如 `...LocalAPIBridge-unsigned.ipa?v=20261119`，或换一个加速前缀。

### 13.2 为什么是“未签名”IPA？

签名必须使用 **你自己的 Apple ID / 开发者证书**。GitHub runner 上没有你的证书和描述文件，也不能代替你在设备上完成 Apple ID 双因素登录，所以只能产出未签名包。

安装方式（任选）：

- **AltStore / Sidekick**：导入 `LocalAPIBridge-unsigned.ipa`，用你的 Apple ID 重签安装；
- **Sideloadly**：拖入 IPA，填 Apple ID 后 Start；
- **爱思助手**：工具箱 → IPA 签名 → 导入 IPA → 使用 Apple ID 签名；
- 有付费开发者账号时，也可以下载 IPA 后用 `codesign` + 自己的描述文件重签。

免费 Apple ID 签名 7 天过期，到期后重新签名即可（App 内数据通常会保留；卸载重装会清空）。

如果希望 GitHub 直接产出已签名 IPA，需要把证书/描述文件作为 Actions Secrets 注入，并在 workflow 中增加导入证书、`xcodebuild -exportArchive` 的步骤。这需要你先在 Apple Developer 后台创建 App ID、证书和 Provisioning Profile；没有这些材料无法自动签名。

---

## 14. 许可

仅供个人学习与自用。使用任何第三方免费 API 时请遵守其服务条款与频率限制。