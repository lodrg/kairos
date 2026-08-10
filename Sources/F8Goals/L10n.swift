import Foundation

/// 界面语言。当前只支持英文 / 中文，默认英文（保持现有界面不变）。
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case en
    case zh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .en: return "English"
        case .zh: return "中文"
        }
    }
}

/// 全部用户可见文案的单一来源。语言切换即时生效——所有视图都持有
/// SettingsStore（ObservedObject），改 language 会触发整棵 UI 重绘。
struct L10n {
    let language: AppLanguage
    private var zh: Bool { language == .zh }

    // MARK: 主界面

    var noGoalsYet: String { zh ? "还没有目标" : "No goals yet" }
    var newGoalPlaceholder: String { zh ? "新目标，回车创建" : "New goal" }
    var durationOff: String { zh ? "关" : "Off" }

    // MARK: 签到卡片

    var timeIsUp: String { zh ? "时间到" : "Time's up" }
    var retimeTitle: String { zh ? "重新选择时长" : "Pick a new duration" }
    var retimeHint: String { zh ? "←/→ 选择 · 回车确认 · Esc 取消（保持原时长）" : "←/→ to pick · Return to confirm · Esc to cancel (keep the current)" }
    /// 反馈输入框占位符 + 提示都围绕「输入 → 回车结束 / Esc 继续」两个动作
    var feedbackPlaceholder: String { zh ? "记录完成后的反馈…" : "Write your reflection…" }
    var feedbackHint: String { zh ? "回车 = 记录并结束 · Esc = 继续并重新计时" : "Return to save & end · Esc to continue & retime" }

    // MARK: 历史面板

    var history: String { zh ? "历史" : "HISTORY" }
    var viewHistory: String { zh ? "查看曾经的目标与反馈" : "View past goals & reflections" }
    var historyTitle: String { zh ? "历史目标与反馈" : "History" }
    var historyEmpty: String { zh ? "还没有已完成的目标" : "No completed goals yet" }
    var back: String { zh ? "返回" : "Back" }

    // MARK: 设置面板

    var settingsTitle: String { zh ? "设置" : "Settings" }
    var escToClose: String { zh ? "Esc 关闭" : "Esc to close" }
    var countdownCheckIn: String { zh ? "倒计时签到" : "COUNTDOWN CHECK-IN" }
    var presetsMinutes: String { zh ? "预设时长（分钟）" : "Presets (minutes)" }
    var defaultDuration: String { zh ? "默认时长" : "Default duration" }
    /// 默认时长自定义输入框的占位提示
    var defaultMinutesPlaceholder: String { zh ? "自定义" : "Custom" }
    /// 时长选择里「默认时长」角标的悬停提示
    var durationDefaultHint: String { zh ? "默认时长 —— ⌘+Enter 新建目标时直接用它武装" : "Default duration — ⌘+Enter arms new goals with it" }
    var autoArmNewGoals: String { zh ? "新目标自动武装" : "Auto-arm new goals" }
    var keepArmedAfterCreate: String { zh ? "创建后保持武装" : "Keep armed after creating" }
    var escDismissCheckIn: String { zh ? "F10 关闭签到（Esc 为继续）" : "F10 dismisses check-in (Esc = continue)" }
    var canvases: String { zh ? "画布" : "CANVASES" }
    var addCanvas: String { zh ? "添加画布" : "Add canvas" }
    var appearance: String { zh ? "外观" : "APPEARANCE" }
    var breathingBackground: String { zh ? "呼吸背景" : "Breathing background" }
    var auroraBackground: String { zh ? "极光背景" : "Aurora background" }
    var layout: String { zh ? "布局" : "LAYOUT" }
    var inputBarPosition: String { zh ? "输入栏位置" : "Input bar position" }
    var textSize: String { zh ? "文字大小" : "Text size" }
    var languageTitle: String { zh ? "语言" : "LANGUAGE" }

    // MARK: 菜单栏

    var menuToggle: String { zh ? "显示 / 隐藏（双击 F10）" : "Show / Hide  (double-tap F10)" }
    var menuSettings: String { zh ? "设置…（⌘. 覆盖层打开时）" : "Settings…  (⌘. while open)" }
    var menuQuit: String { zh ? "退出 F8Goals" : "Quit F8Goals" }
}
