import Foundation

/// 用户可调的配置；生命周期和目标数据不一样（改配置不该碰 goals.json），
/// 所以单独存到 settings.json，单独一个 store。
struct Settings: Codable, Equatable {
    // 倒计时签到
    var durationPresetsMinutes: [Int] = [3, 5, 15, 30, 60]
    var defaultMinutes = 15
    var autoArmNewGoals = false
    var keepArmedAfterCreate = false
    /// 底部计时光带：覆盖层可见且当前画布有活跃计时时，屏幕底部一条从满到空的
    /// 细光带显示最早到期计时器的剩余时间——提醒时间在流动，但不打断任何操作
    var showTimerBar = true
    // 旧版有「呼出键/收起键可直接关闭签到」开关（checkInEscDismisses）——呼出键不再承担
    // 收起职责后这个开关失去意义，已删除；签到只有两个键：回车=结束、Esc=继续（强制本身）

    // 外观
    /// 动态背景总开关：开着 = 极光流动 + 整屏呼吸；关掉 = 静态渐变（CPU 归零）。
    /// 早期版本拆成「极光」「呼吸」两个开关，用户觉得多余——合并成一个
    var animatedBackground = true
    /// 背景色相偏移（0–360°，默认 0 = 原色）：把极光调色板整体转色相。
    /// 纯色彩修饰，不碰布局/动效/画布逻辑（画布的 hueShift 单独叠加）
    var backgroundHue = 0.0
    /// 背景饱和度（0–2，1.0 = 原色；0 = 全灰，2 = 更浓）：调色板源头缩放
    var backgroundSaturation = 1.0
    /// 背景明度（0–2，1.0 = 原色；0 = 全黑，2 = 提亮）：HSV 明度缩放，
    /// 色相/饱和度不变——不是 .brightness() 那种整体加白加黑
    var backgroundBrightness = 1.0

    // 布局；默认值必须精确匹配 Metrics 里原来硬编码的常量，见 LayoutMetrics 的注释
    var inputRestingFraction = 0.618
    var textScale = 1.0

    // 语言；默认英文，保持现有界面不变
    var language: AppLanguage = .en

    // 热键（kVK keyCode + Carbon 修饰键掩码；0 = 无修饰）
    /// 呼出键。默认 **⌘⇧S**（S + Command+Shift）——带修饰键的组合极少被全局占用，
    /// 而且不是 F 键：不依赖「将 F1、F2 等键用作标准功能键」设置（裸 F 键在
    /// 系统默认下是媒体键，F10=静音，按键到不了 App）。隐藏时按一下呼出、
    /// 可见时再按一下收起（双击保护见 AppDelegate）。
    /// 修饰键掩码直接写字面量：Carbon 的 cmdKey=0x0100 | shiftKey=0x0200 =
    /// 0x0300（这个文件只 import Foundation，引用不了 Carbon 常量）
    var showHotkeyKeyCode = 1
    var showHotkeyModifiers = 0x0300

    // 首启引导：看过一次就再不弹（隐身优先——任何常驻提示都会暴露这是个热键 App）
    var onboardingSeen = false

    // 透明模式（AI 协作）：覆盖层保持占屏可见，但对其他进程的截图/点击/键盘全部
    // 透明——sharingType=.none 让 AI 的截图/录屏里没有它（物理屏照常显示），
    // ignoresMouseEvents 让点击穿透到下面的 App；签到也不自动弹出（防打断 AI）
    var transparentMode = false

    init() {}

    /// 显式声明键名：auroraEnabled 是旧版「极光背景」开关，结构体里已没有对应属性，
    /// 但旧 settings.json 里还留着它——迁移时用它的值兜底 animatedBackground。
    /// hideHotkey* 是旧版「收起键」字段，已被删除（收起永远走 Esc）——JSON 里残留的
    /// 旧键由 JSONDecoder 自动忽略，不需要在这里声明
    private enum CodingKeys: String, CodingKey {
        case durationPresetsMinutes, defaultMinutes, autoArmNewGoals, keepArmedAfterCreate,
             showTimerBar,
             inputRestingFraction, textScale, language,
             animatedBackground, backgroundHue, backgroundSaturation, backgroundBrightness, auroraEnabled,
             showHotkeyKeyCode, showHotkeyModifiers,
             onboardingSeen, transparentMode
    }

    /// 旧版 settings.json 里没有 language 字段——直接走合成解码会整个 decode 失败，
    /// 用户已有的全部配置会被静默重置成默认值。所有字段都用 decodeIfPresent 兜底。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        durationPresetsMinutes = try c.decodeIfPresent([Int].self, forKey: .durationPresetsMinutes) ?? [3, 5, 15, 30, 60]
        defaultMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultMinutes) ?? 15
        autoArmNewGoals = try c.decodeIfPresent(Bool.self, forKey: .autoArmNewGoals) ?? false
        keepArmedAfterCreate = try c.decodeIfPresent(Bool.self, forKey: .keepArmedAfterCreate) ?? false
        showTimerBar = try c.decodeIfPresent(Bool.self, forKey: .showTimerBar) ?? true
        animatedBackground = try c.decodeIfPresent(Bool.self, forKey: .animatedBackground)
            ?? (c.decodeIfPresent(Bool.self, forKey: .auroraEnabled) ?? true)
        backgroundHue = try c.decodeIfPresent(Double.self, forKey: .backgroundHue) ?? 0.0
        backgroundSaturation = try c.decodeIfPresent(Double.self, forKey: .backgroundSaturation) ?? 1.0
        backgroundBrightness = try c.decodeIfPresent(Double.self, forKey: .backgroundBrightness) ?? 1.0
        inputRestingFraction = try c.decodeIfPresent(Double.self, forKey: .inputRestingFraction) ?? 0.618
        textScale = try c.decodeIfPresent(Double.self, forKey: .textScale) ?? 1.0
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .en
        showHotkeyKeyCode = try c.decodeIfPresent(Int.self, forKey: .showHotkeyKeyCode) ?? 1
        showHotkeyModifiers = try c.decodeIfPresent(Int.self, forKey: .showHotkeyModifiers) ?? 0x0300
        onboardingSeen = try c.decodeIfPresent(Bool.self, forKey: .onboardingSeen) ?? false
        transparentMode = try c.decodeIfPresent(Bool.self, forKey: .transparentMode) ?? false
    }

    /// 手写 encode：CodingKeys 里保留了旧键 auroraEnabled（只为迁移解码用），
    /// 没有对应属性——合成 encode 会失败，这里显式只写现有字段
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(durationPresetsMinutes, forKey: .durationPresetsMinutes)
        try c.encode(defaultMinutes, forKey: .defaultMinutes)
        try c.encode(autoArmNewGoals, forKey: .autoArmNewGoals)
        try c.encode(keepArmedAfterCreate, forKey: .keepArmedAfterCreate)
        try c.encode(showTimerBar, forKey: .showTimerBar)
        try c.encode(inputRestingFraction, forKey: .inputRestingFraction)
        try c.encode(textScale, forKey: .textScale)
        try c.encode(language, forKey: .language)
        try c.encode(animatedBackground, forKey: .animatedBackground)
        try c.encode(backgroundHue, forKey: .backgroundHue)
        try c.encode(backgroundSaturation, forKey: .backgroundSaturation)
        try c.encode(backgroundBrightness, forKey: .backgroundBrightness)
        try c.encode(showHotkeyKeyCode, forKey: .showHotkeyKeyCode)
        try c.encode(showHotkeyModifiers, forKey: .showHotkeyModifiers)
        try c.encode(onboardingSeen, forKey: .onboardingSeen)
        try c.encode(transparentMode, forKey: .transparentMode)
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings = Settings() { didSet { save() } }

    private let fileURL: URL

    init() {
        let dir = AppData.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("settings.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data) else { return }
        settings = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
