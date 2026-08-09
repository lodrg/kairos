import Foundation
import SwiftUI

// MARK: - 数据模型

struct Canvas: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// 施加到极光背景的色相偏移（度），画布之间做微妙区分
    var hueShift: Double
}

/// 倒计时字段。武装/到期靠 GoalStore.setTimer / snoozeTimer 和 AppDelegate 里的
/// 周期扫描——不给每个目标挂 scheduledTimer，那种跨系统睡眠不能正确触发
struct GoalTimer: Codable, Equatable {
    var minutes: Int
    var startedAt: Date
    var snoozeCount: Int = 0
    var firesAt: Date { startedAt.addingTimeInterval(Double(minutes) * 60) }
}

struct Goal: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var isDone = false
    var createdAt = Date()
    /// 完成时间（勾选时记录，用于渐隐动画与恢复）
    var completedAt: Date?
    var canvasID: UUID
    /// nil = 顶层目标；非空 = 子目标（只允许一层），到后面阶段才接上产生它的交互
    var parentID: UUID? = nil
    var timer: GoalTimer? = nil
}

/// 磁盘格式 v2：画布 + 目标 + 当前画布，取代 v1 的裸数组 [Goal]
struct Library: Codable {
    var schemaVersion = 2
    var canvases: [Canvas]
    var goals: [Goal]
    var activeCanvasID: UUID
}

/// v1 磁盘格式：没有 canvasID / parentID / timer。
/// 迁移时按这个形状单独解码，不与 Goal 混在一起，Goal 里的 canvasID 就能保持非可选。
private struct LegacyGoalV1: Codable {
    var id: UUID
    var text: String
    var isDone: Bool
    var createdAt: Date
    var completedAt: Date?
}

// MARK: - 持久化

@MainActor
final class GoalStore: ObservableObject {
    @Published var goals: [Goal] = []
    @Published var canvases: [Canvas] = []
    @Published var activeCanvasID = UUID()

    private let fileURL: URL
    private let legacyBackupURL: URL

    var activeCanvas: Canvas {
        canvases.first { $0.id == activeCanvasID } ?? canvases[0]
    }

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("F8Goals", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("goals.json")
        legacyBackupURL = dir.appendingPathComponent("goals.v1.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            seedDefaultCanvases()
            return
        }
        if let library = try? JSONDecoder().decode(Library.self, from: data) {
            adopt(library)
            return
        }
        migrateFromV1(data)
    }

    private func seedDefaultCanvases() {
        canvases = [Canvas(name: "Personal", hueShift: 0), Canvas(name: "Work", hueShift: 150)]
        activeCanvasID = canvases[0].id
    }

    private func adopt(_ library: Library) {
        canvases = library.canvases.isEmpty ? [Canvas(name: "Personal", hueShift: 0)] : library.canvases
        goals = library.goals
        activeCanvasID = canvases.contains { $0.id == library.activeCanvasID } ? library.activeCanvasID : canvases[0].id
    }

    /// v1 落盘是裸数组 [Goal]，没有 canvasID 这个字段，不能直接当 Goal 解码。
    /// 迁移前把原文件另存为 goals.v1.json（不覆盖用户已有的 goals.json.bak），
    /// 已有目标全部归到默认画布。
    private func migrateFromV1(_ data: Data) {
        guard let legacy = try? JSONDecoder().decode([LegacyGoalV1].self, from: data) else {
            seedDefaultCanvases()
            return
        }
        seedDefaultCanvases()
        let home = canvases[0].id
        goals = legacy.map {
            Goal(id: $0.id, text: $0.text, isDone: $0.isDone, createdAt: $0.createdAt,
                 completedAt: $0.completedAt, canvasID: home)
        }
        if !FileManager.default.fileExists(atPath: legacyBackupURL.path) {
            try? data.write(to: legacyBackupURL, options: .atomic)
        }
        save()
    }

    func save() {
        let library = Library(canvases: canvases, goals: goals, activeCanvasID: activeCanvasID)
        guard let data = try? JSONEncoder().encode(library) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - 目标

    func add(_ text: String, parentID: UUID? = nil, minutes: Int? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let timer = minutes.map { GoalTimer(minutes: $0, startedAt: Date()) }
        goals.append(Goal(text: trimmed, canvasID: activeCanvasID, parentID: parentID, timer: timer))
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

    // MARK: - 倒计时

    /// minutes = nil 即拆掉计时器
    func setTimer(goalID: UUID, minutes: Int?) {
        guard let index = goals.firstIndex(where: { $0.id == goalID }) else { return }
        goals[index].timer = minutes.map { GoalTimer(minutes: $0, startedAt: Date()) }
        save()
    }

    /// 从现在起重新数 minutes 分钟，snoozeCount 累加——签到卡片的 Snooze 用这个
    func snoozeTimer(goalID: UUID, minutes: Int) {
        guard let index = goals.firstIndex(where: { $0.id == goalID }) else { return }
        let previousCount = goals[index].timer?.snoozeCount ?? 0
        goals[index].timer = GoalTimer(minutes: minutes, startedAt: Date(), snoozeCount: previousCount + 1)
        save()
    }

    // MARK: - 画布

    /// 环形切换；delta = 1 下一个，-1 上一个。只有一块画布时是无操作
    func cycleCanvas(by delta: Int) {
        guard canvases.count > 1, let index = canvases.firstIndex(where: { $0.id == activeCanvasID }) else { return }
        let next = (index + delta + canvases.count) % canvases.count
        activeCanvasID = canvases[next].id
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
    /// 正在播放完成动画的目标
    @Published var completingIDs: Set<UUID> = []
    /// 完成动画播完、已从列表让位的目标（数据仍留在 JSON）
    @Published var retiredIDs: Set<UUID> = []
    /// 上下键选中的目标；驱动行的选中标记，也是 Tab 拆子目标 / ⌘T 挂计时器的对象
    @Published var selectedID: UUID?
    /// 待建目标要挂在谁下面；nil = 新建顶层目标。创建后不清空——
    /// 这样连续回车能逐条加子目标，直到 Shift+Tab / Esc 主动退回顶层
    @Published var inputParentID: UUID?

    /// 到期后待处理的签到；绝不能被 resetTransient 清掉——收起动画完成时会调用它，
    /// 清了就等于让签到被「收起」悄悄取消掉，等于没做强制这件事
    @Published var pendingCheckInID: UUID?
    /// 正在展开时长预设选择（左右键选、回车确认）
    @Published var isChoosingDuration = false
    @Published var draftMinutesIndex = 0
    /// 确认时长后要挂的对象：nil = 挂到下一条新建目标；非空 = 直接改这条已有目标的计时器
    @Published var armingTargetID: UUID?
    /// 已确认、等着挂到下一条新建目标上的时长；创建后复位（默认不保持武装）
    @Published var armedMinutes: Int?

    /// 收起时清空。不清的话这些状态会随 App 生命周期只增不减，
    /// 而且下次呼出时上一轮勾选过的目标、选中态会带着中间状态重新出现。
    /// pendingCheckInID 故意不在这里清——见上面的注释。
    func resetTransient() {
        editingID = nil
        editText = ""
        inputText = ""
        completingIDs = []
        retiredIDs = []
        selectedID = nil
        inputParentID = nil
        isChoosingDuration = false
        armingTargetID = nil
        armedMinutes = nil
    }
}
