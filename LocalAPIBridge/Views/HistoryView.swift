import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var engine: PollingEngine
    @State private var onlyFailures = false

    private var records: [PollRecord] {
        onlyFailures ? engine.history.filter { !$0.success } : engine.history
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("只看失败", isOn: $onlyFailures)
                    HStack {
                        Text("已保存记录")
                        Spacer()
                        Text("\(engine.history.count) / \(HistoryStore.maximumCount)")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if records.isEmpty {
                        Text(onlyFailures ? "没有失败记录" : "暂无记录")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(records) { record in
                            NavigationLink {
                                RecordDetailView(record: record)
                            } label: {
                                RecordRow(record: record)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("轮询记录")
        }
    }
}

struct RecordRow: View {
    let record: PollRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(record.success ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.statusText)
                    .font(.subheadline.weight(.semibold))
                Text(record.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(record.timeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(record.durationMilliseconds) ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct RecordDetailView: View {
    let record: PollRecord
    @State private var copied = false

    var body: some View {
        List {
            Section("概况") {
                infoRow("时间", record.timeText)
                infoRow("状态", record.statusText)
                infoRow("耗时", "\(record.durationMilliseconds) ms")
                infoRow("大小", "\(record.byteCount) 字节")
                infoRow("触发方式", triggerText)
                if !record.sourceURL.isEmpty {
                    infoRow("上游地址", record.sourceURL)
                }
                if let model = record.modelName, !model.isEmpty {
                    infoRow("模型", model)
                }
                if let tokens = record.tokensUsed {
                    infoRow("Token 用量", "\(tokens)")
                }
                if !record.contentType.isEmpty {
                    infoRow("Content-Type", record.contentType)
                }
            }

            if let error = record.errorMessage, !error.isEmpty {
                Section("错误") {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("响应内容（最多保留 6000 字符）") {
                Text(record.bodyText.isEmpty ? "（无内容）" : record.bodyText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("轮询详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("复制") {
                    UIPasteboard.general.string = record.bodyText
                    copied = true
                }
            }
        }
        .alert("已复制响应内容（最多 6000 字符）", isPresented: $copied) {
            Button("好", role: .cancel) {}
        }
    }

    private var triggerText: String {
        switch record.trigger {
        case "timer": return "自动轮询"
        case "manual": return "手动刷新"
        case "local-api": return "本地 API 触发"
        case "start": return "启动时"
        case "cache": return "冷启动缓存"
        default: return record.trigger
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}