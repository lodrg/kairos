import Foundation

/// 用户可调的配置；生命周期和目标数据不一样（改配置不该碰 goals.json），
/// 所以单独存到 settings.json，单独一个 store。
struct Settings: Codable, Equatable {
    // 倒计时签到
    var durationPresetsMinutes: [Int] = [5, 15, 25, 45]
    var defaultMinutes = 25
    var snoozeMinutes = 5
    var autoArmNewGoals = false
    var keepArmedAfterCreate = false
    /// 打开后，Esc / 单击 F10 / 菜单栏都能在签到未决时正常收起（相当于「关闭签到」，
    /// 不等于 Done/Snooze 等任何动作）。默认关——这是特意要「强制」的功能
    var checkInEscDismisses = false

    // 外观
    var breathingEnabled = true
    var auroraEnabled = true

    // 布局；默认值必须精确匹配 Metrics 里原来硬编码的常量，见 LayoutMetrics 的注释
    var inputRestingFraction = 0.58
    var textScale = 1.0
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings = Settings() { didSet { save() } }

    private let fileURL: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("F8Goals", isDirectory: true)
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
