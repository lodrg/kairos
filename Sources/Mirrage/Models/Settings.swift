import Foundation

/// 用户可调的配置；生命周期和目标数据不一样（改配置不该碰 goals.json），
/// 所以单独存到 settings.json，单独一个 store。
struct Settings: Codable, Equatable {
    // 倒计时签到
    var durationPresetsMinutes: [Int] = [3, 5, 15, 30, 60]
    var defaultMinutes = 15
    var autoArmNewGoals = false
    var keepArmedAfterCreate = false
    /// 打开后，单击 F10 能在签到未决时正常收起（相当于「关闭签到」，不等于任何动作）。
    /// 默认关——这是特意要「强制」的功能；Esc 永远是「继续」，不受这个开关影响
    var checkInEscDismisses = false

    // 外观
    /// 动态背景总开关：开着 = 极光流动 + 整屏呼吸；关掉 = 静态渐变（CPU 归零）。
    /// 早期版本拆成「极光」「呼吸」两个开关，用户觉得多余——合并成一个
    var animatedBackground = true

    // 布局；默认值必须精确匹配 Metrics 里原来硬编码的常量，见 LayoutMetrics 的注释
    var inputRestingFraction = 0.58
    var textScale = 1.0

    // 语言；默认英文，保持现有界面不变
    var language: AppLanguage = .en

    init() {}

    /// 显式声明键名：auroraEnabled 是旧版「极光背景」开关，结构体里已没有对应属性，
    /// 但旧 settings.json 里还留着它——迁移时用它的值兜底 animatedBackground
    private enum CodingKeys: String, CodingKey {
        case durationPresetsMinutes, defaultMinutes, autoArmNewGoals, keepArmedAfterCreate,
             checkInEscDismisses, inputRestingFraction, textScale, language,
             animatedBackground, auroraEnabled
    }

    /// 旧版 settings.json 里没有 language 字段——直接走合成解码会整个 decode 失败，
    /// 用户已有的全部配置会被静默重置成默认值。所有字段都用 decodeIfPresent 兜底。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        durationPresetsMinutes = try c.decodeIfPresent([Int].self, forKey: .durationPresetsMinutes) ?? [3, 5, 15, 30, 60]
        defaultMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultMinutes) ?? 15
        autoArmNewGoals = try c.decodeIfPresent(Bool.self, forKey: .autoArmNewGoals) ?? false
        keepArmedAfterCreate = try c.decodeIfPresent(Bool.self, forKey: .keepArmedAfterCreate) ?? false
        checkInEscDismisses = try c.decodeIfPresent(Bool.self, forKey: .checkInEscDismisses) ?? false
        animatedBackground = try c.decodeIfPresent(Bool.self, forKey: .animatedBackground)
            ?? (c.decodeIfPresent(Bool.self, forKey: .auroraEnabled) ?? true)
        inputRestingFraction = try c.decodeIfPresent(Double.self, forKey: .inputRestingFraction) ?? 0.58
        textScale = try c.decodeIfPresent(Double.self, forKey: .textScale) ?? 1.0
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .en
    }

    /// 手写 encode：CodingKeys 里保留了旧键 auroraEnabled（只为迁移解码用），
    /// 没有对应属性——合成 encode 会失败，这里显式只写现有字段
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(durationPresetsMinutes, forKey: .durationPresetsMinutes)
        try c.encode(defaultMinutes, forKey: .defaultMinutes)
        try c.encode(autoArmNewGoals, forKey: .autoArmNewGoals)
        try c.encode(keepArmedAfterCreate, forKey: .keepArmedAfterCreate)
        try c.encode(checkInEscDismisses, forKey: .checkInEscDismisses)
        try c.encode(inputRestingFraction, forKey: .inputRestingFraction)
        try c.encode(textScale, forKey: .textScale)
        try c.encode(language, forKey: .language)
        try c.encode(animatedBackground, forKey: .animatedBackground)
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
