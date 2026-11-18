import CoreFoundation
import Foundation

/// 一次轮询的结果。历史记录会精简响应体后持久化。
struct PollRecord: Identifiable, Codable {
    var id: UUID
    var date: Date
    var success: Bool
    var statusCode: Int
    var durationMilliseconds: Int
    var contentType: String
    var byteCount: Int
    var bodyText: String
    var errorMessage: String?
    var trigger: String
    var sourceURL: String
    var modelName: String?
    var tokensUsed: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case success
        case statusCode
        case durationMilliseconds
        case contentType
        case byteCount
        case bodyText
        case errorMessage
        case trigger
        case sourceURL
        case modelName
        case tokensUsed
    }

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        success: Bool,
        statusCode: Int,
        durationMilliseconds: Int,
        contentType: String,
        byteCount: Int,
        bodyText: String,
        errorMessage: String? = nil,
        trigger: String = "timer",
        sourceURL: String = "",
        modelName: String? = nil,
        tokensUsed: Int? = nil
    ) {
        self.id = id
        self.date = date
        self.success = success
        self.statusCode = statusCode
        self.durationMilliseconds = durationMilliseconds
        self.contentType = contentType
        self.byteCount = byteCount
        self.bodyText = bodyText
        self.errorMessage = errorMessage
        self.trigger = trigger
        self.sourceURL = sourceURL
        self.modelName = modelName
        self.tokensUsed = tokensUsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? false
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode) ?? 0
        durationMilliseconds = try container.decodeIfPresent(Int.self, forKey: .durationMilliseconds) ?? 0
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType) ?? ""
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        bodyText = try container.decodeIfPresent(String.self, forKey: .bodyText) ?? ""
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger) ?? "timer"
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        tokensUsed = try container.decodeIfPresent(Int.self, forKey: .tokensUsed)
    }

    var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    var statusText: String {
        if success {
            return "HTTP \(statusCode)"
        }
        if statusCode == 0 {
            return "请求失败"
        }
        return "HTTP \(statusCode)"
    }

    var preview: String {
        let singleLine = bodyText
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return errorMessage ?? "（空响应）"
        }
        return String(trimmed.prefix(160))
    }
}

/// 从上游 JSON 里尽力提取“模型名”和“token/上下文使用量”。
/// 兼容常见的 OpenAI 风格 `model` + `usage.total_tokens`，也兼容部分
/// `context_tokens` / `tokens_used` / `input_tokens` / `output_tokens` 字段。
enum ResponseInsights {
    static func extract(from data: Data) -> (model: String?, tokensUsed: Int?) {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return (nil, nil)
        }

        var model: String?
        var totalTokens: Int?
        var promptTokens: Int?
        var completionTokens: Int?

        func walk(_ value: Any, depth: Int) {
            guard depth <= 8 else { return }

            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    let lower = key.lowercased()

                    if model == nil,
                       lower == "model" || lower == "model_name" || lower == "model_id",
                       let text = child as? String,
                       !text.isEmpty {
                        model = text
                    }

                    if let number = child as? NSNumber, !isBoolean(number) {
                        switch lower {
                        case "total_tokens", "total_tokens_used", "context_tokens", "tokens_used", "context_used":
                            if totalTokens == nil { totalTokens = number.intValue }
                        case "prompt_tokens", "input_tokens":
                            if promptTokens == nil { promptTokens = number.intValue }
                        case "completion_tokens", "output_tokens":
                            if completionTokens == nil { completionTokens = number.intValue }
                        default:
                            break
                        }
                    }

                    walk(child, depth: depth + 1)
                }
            } else if let array = value as? [Any] {
                for child in array {
                    walk(child, depth: depth + 1)
                }
            }
        }

        walk(object, depth: 0)
        if totalTokens == nil, let promptTokens {
            totalTokens = promptTokens + (completionTokens ?? 0)
        }
        return (model, totalTokens)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
