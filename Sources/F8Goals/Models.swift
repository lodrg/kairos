import Foundation
import SwiftUI

// MARK: - 数据模型

struct Goal: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var isDone = false
    var createdAt = Date()
    /// 完成时间（勾选时记录，用于渐隐动画与恢复）
    var completedAt: Date?
}

// MARK: - 持久化

@MainActor
final class GoalStore: ObservableObject {
    @Published var goals: [Goal] = []

    private let fileURL: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("F8Goals", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("goals.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              var decoded = try? JSONDecoder().decode([Goal].self, from: data) else { return }
        // 旧数据迁移: 已勾选但无完成时间 → 视为很久前完成（不再显示，仅留档）
        for i in decoded.indices where decoded[i].isDone && decoded[i].completedAt == nil {
            decoded[i].completedAt = .distantPast
        }
        goals = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(goals) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        goals.append(Goal(text: trimmed)) // 新的在下面（紧贴输入栏上方）
        save()
    }

    func toggle(_ id: UUID) {
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
        if goals[index].isDone {
            goals[index].isDone = false
            goals[index].completedAt = nil
        } else {
            goals[index].isDone = true
            goals[index].completedAt = Date()
        }
        save()
    }

    /// 编辑目标；清空文本回车 = 删除
    func update(id: UUID, text: String) {
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            goals.remove(at: index)
        } else {
            goals[index].text = trimmed
        }
        save()
    }
}

// MARK: - 覆盖层状态（呼出动画 / 输入 / 编辑）

@MainActor
final class OverlayModel: ObservableObject {
    @Published var animatedIn = false
    @Published var inputText = ""
    @Published var editingID: UUID?
    @Published var editText = ""
    /// 已勾选、正在上浮渐隐的目标
    @Published var fadingDoneIDs: Set<UUID> = []
    /// 渐隐完成、从列表移除的目标（数据仍留在 JSON）
    @Published var hiddenDoneIDs: Set<UUID> = []
}
