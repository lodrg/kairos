import Foundation
import SwiftUI

// MARK: - 数据模型

struct Canvas: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// 施加到极光背景的色相偏移（度），画布之间做微妙区分
    var hueShift: Double
}

/// 倒计时字段。武装/到期靠 GoalStore.setTimer 和 AppDelegate 里的周期扫描——
/// 不给每个目标挂 scheduledTimer，那种跨系统睡眠不能正确触发
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
    /// 开始时间：首次武装计时时记录（重复延长不清掉——开始时间是最初那次）。
    /// 没计时过的目标显示时回退 createdAt
    var startedAt: Date? = nil
    var timer: GoalTimer? = nil
    /// 倒计时签到结束时用户写的反馈（可选；结束时保存，随目标留存在 goals.json）
    var feedback: String? = nil
}

/// 磁盘格式 v2：画布 + 目标 + 当前画布，取代 v1 的裸数组 [Goal]
struct Library: Codable {
    var schemaVersion = 2
    var canvases: [Canvas]
    var goals: [Goal]
    var activeCanvasID: UUID
}

/// v1 磁盘格式：没有 canvasID / timer。迁移时按这个形状单独解码，
/// 不与 Goal 混在一起，Goal 里的 canvasID 就能保持非可选。
private struct LegacyGoalV1: Codable {
    var id: UUID
    var text: String
    var isDone: Bool
    var createdAt: Date
    var completedAt: Date?
}

// MARK: - 持久化

/// 数据目录：~/Library/Application Support/Kairos。
/// 改名自 Mirrage（原名 F8Goals）——首次启动时若旧目录还在则整体搬过来，一次性。
/// 迁移链：F8Goals → Mirrage → Kairos，逐级检查，先到先搬。两个 store 的 init 都会调用（幂等）
enum AppData {
    static var directory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let newDir = base.appendingPathComponent("Kairos", isDirectory: true)
        let mirrageDir = base.appendingPathComponent("Mirrage", isDirectory: true)
        let f8Dir = base.appendingPathComponent("F8Goals", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: newDir.path) {
            if fm.fileExists(atPath: mirrageDir.path) {
                try? fm.moveItem(at: mirrageDir, to: newDir)
            } else if fm.fileExists(atPath: f8Dir.path) {
                try? fm.moveItem(at: f8Dir, to: newDir)
            }
        }
        return newDir
    }
}

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
        let dir = AppData.directory
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
        // 旧版（v1.0 之前）有子目标（parentID）字段——Goal 里已移除该属性，解码时
        // JSON 里的 parentID 键被自动忽略，所有目标自然摊平成一层，无需迁移代码
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

    func add(_ text: String, minutes: Int? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let timer = minutes.map { GoalTimer(minutes: $0, startedAt: Date()) }
        goals.append(Goal(text: trimmed, canvasID: activeCanvasID, timer: timer))
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

    /// 编辑目标文本。清空文本时删除目标（编辑「清空+回车 = 删除」的底层实现；
    /// UI 层走 animatedDelete 播完淡出动画后也落到这里）
    func update(id: UUID, text: String) {
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete(id)
        } else {
            goals[index].text = trimmed
        }
        save()
    }

    /// 删除目标（UI 层走 animatedDelete 播完淡出动画后调到这里）
    func delete(_ id: UUID) {
        goals.removeAll { $0.id == id }
        save()
    }

    // MARK: - 倒计时

    /// minutes = nil 即拆掉计时器
    func setTimer(goalID: UUID, minutes: Int?) {
        guard let index = goals.firstIndex(where: { $0.id == goalID }) else { return }
        goals[index].timer = minutes.map { GoalTimer(minutes: $0, startedAt: Date()) }
        // 首次武装 = 目标的开始时间；重复延长不清掉最初那次
        if minutes != nil, goals[index].startedAt == nil {
            goals[index].startedAt = Date()
        }
        save()
    }

    /// 保存签到反馈；空文本 = 清掉已有反馈。反馈随目标留在 goals.json，历史面板从这里读
    func setFeedback(id: UUID, feedback: String) {
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        goals[index].feedback = trimmed.isEmpty ? nil : trimmed
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

    /// 按顺序从 Palette.canvasHues 取色，跟色相选择器共用同一份色板
    @discardableResult
    func addCanvas(name: String) -> Canvas {
        let hue = Palette.canvasHues[canvases.count % Palette.canvasHues.count]
        let canvas = Canvas(name: name, hueShift: hue)
        canvases.append(canvas)
        save()
        return canvas
    }

    func renameCanvas(_ id: UUID, to name: String) {
        guard let index = canvases.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        canvases[index].name = trimmed
        save()
    }

    func setCanvasHue(_ id: UUID, hue: Double) {
        guard let index = canvases.firstIndex(where: { $0.id == id }) else { return }
        canvases[index].hueShift = hue
        save()
    }

    /// 删掉画布连同它下面的目标；不允许删到 0 个
    func deleteCanvas(_ id: UUID) {
        guard canvases.count > 1, let index = canvases.firstIndex(where: { $0.id == id }) else { return }
        canvases.remove(at: index)
        goals.removeAll { $0.canvasID == id }
        if activeCanvasID == id {
            activeCanvasID = canvases[min(index, canvases.count - 1)].id
        }
        save()
    }
}

// MARK: - 覆盖层状态（呼出动画 / 输入 / 编辑）

/// 检查更新的结果状态
enum UpdateStatus: Equatable {
    case checking
    case upToDate
    case updateAvailable(version: String)
    case failed
}

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
    /// 上下键选中的目标；驱动行的选中标记，也是 ⌘T 挂计时器的对象
    @Published var selectedID: UUID?

    /// 到期后待处理的签到；绝不能被 resetTransient 清掉——收起动画完成时会调用它，
    /// 清了就等于让签到被「收起」悄悄取消掉，等于没做强制这件事
    @Published var pendingCheckInID: UUID?
    /// Esc 继续后正在全屏重选时长的目标；非 nil 时显示全屏时长选择（不再用输入栏底部那条
    /// 小横条）。普通 ⌘T 武装还是走输入栏小横条（retimingGoalID == nil）
    @Published var retimingGoalID: UUID?
    /// 签到卡片上反馈输入框的草稿；继续（keepGoing）后保留，下次到期弹卡片时还在
    @Published var checkInFeedback = ""
    /// 设置里的「历史」子面板
    @Published var showHistory = false
    /// 正在展开时长预设选择（左右键选、回车确认）
    @Published var isChoosingDuration = false
    @Published var draftMinutesIndex = 0
    /// 确认时长后要挂的对象：nil = 挂到下一条新建目标；非空 = 直接改这条已有目标的计时器
    @Published var armingTargetID: UUID?
    /// 已确认、等着挂到下一条新建目标上的时长；创建后复位（默认不保持武装）
    @Published var armedMinutes: Int?
    /// ⌘. 呼出的配置面板
    @Published var showSettings = false
    /// 面板里正在录制呼出键；true 时本地监听把下一个键交给热键录制（Esc 取消）
    @Published var isRecordingHotkey = false
    /// 录制被拒的原因（占用/与输入冲突），面板里短暂显示
    @Published var hotkeyRejectMessage: String?
    /// 当前呼出键注册失败（被其他 App 占用）——设置面板和首启引导据此显示冲突警告
    @Published var showHotkeyConflicted = false
    /// 正在播删除淡出动画的目标（淡出中点击可取消删除，播完从 store 移除）
    @Published var deletingIDs: Set<UUID> = []
    /// 检查更新的结果状态（纯 UI 瞬态，不落盘）
    @Published var updateStatus: UpdateStatus?
    /// 首启引导卡（只出现一次，settings.onboardingSeen 控制）
    @Published var showOnboarding = false
    /// 输入法组合态：拼音上屏前 binding 是空的，自绘 placeholder 靠这个标志躲开组合期。
    /// 由 AppDelegate 的本地监听在每次按键时从 field editor 的 hasMarkedText 刷新
    @Published var isComposing = false

    /// 收起时清空。不清的话这些状态会随 App 生命周期只增不减，
    /// 而且下次呼出时上一轮勾选过的目标、选中态会带着中间状态重新出现。
    /// pendingCheckInID 故意不在这里清——见上面的注释。
    /// deletingIDs 在这里清 = 收起（Esc）会取消还没播完的删除淡出：
    /// 删除的 Task 靠 `deletingIDs.contains` 做守卫，被清掉就放弃删除，
    /// 目标下次呼出时完好回来——等于给了删除一个「淡出中按 Esc 反悔」的退路
    func resetTransient() {
        editingID = nil
        editText = ""
        inputText = ""
        completingIDs = []
        retiredIDs = []
        selectedID = nil
        deletingIDs = []
        isChoosingDuration = false
        armingTargetID = nil
        armedMinutes = nil
        showSettings = false
        isRecordingHotkey = false
        hotkeyRejectMessage = nil
        updateStatus = nil
        showOnboarding = false
        showHistory = false
        checkInFeedback = ""
        retimingGoalID = nil
        isChoosingDuration = false
        isComposing = false
    }
}
