import SwiftUI

/// ⌘. 呼出的配置面板：盖住目标区，保持现有视觉语言，不开新窗口。
/// 倒计时签到那一段放最前面并做视觉强调——这是本版最重要的配置项。
struct SettingsPanel: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var store: GoalStore
    @ObservedObject var model: OverlayModel
    let onClose: () -> Void
    let onOpenHistory: () -> Void

    @State private var presetsText = ""
    @State private var newCanvasName = ""
    @State private var defaultMinutesText = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case presets, newCanvas, defaultMinutes }

    private var l10n: L10n { L10n(language: settingsStore.settings.language) }

    var body: some View {
        ZStack {
            // 目标区已经在 OverlayView 里整块淡掉了，这层只负责压暗极光让面板文字有对比度
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            // 用自然高度的 VStack 而不是固定高的 ScrollView：ScrollView 会吃满给它的高度，
            // 内容又是顶对齐的，于是面板整体偏上、下面吊着一大块空白，看着就不像个居中的对话框。
            // 唯一可能无限长的是画布列表，所以只在那一段内部加滚动（见 canvasSection）。
            VStack(alignment: .leading, spacing: 30) {
                Text(l10n.settingsTitle)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))

                countdownSection
                canvasSection
                appearanceSection
                hotkeySection
                layoutSection
                languageSection
                historySection
                helpSection

                Text(l10n.escToClose)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.28))
            }
            .padding(38)
            .frame(width: 520, alignment: .leading)
            // 配置面板需要读起来是一块独立的表面：14 个控件浮在背景上没有任何边界，
            // 就是一堆散落的文字而不是一个设置界面。这跟输入栏「不要明显框体」不冲突——
            // 那说的是主界面里的输入提示，不是一个表单容器。
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .stroke(.white.opacity(0.09), lineWidth: 1)
            }
            .onTapGesture {}
        }
        .onAppear {
            presetsText = settingsStore.settings.durationPresetsMinutes.map(String.init).joined(separator: " ")
            defaultMinutesText = "\(settingsStore.settings.defaultMinutes)"
        }
    }

    // MARK: - 倒计时签到（重点强调）

    private var countdownSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(l10n.countdownCheckIn)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.accent.opacity(0.9))
                .tracking(1.4)

            settingsRow(l10n.presetsMinutes) {
                TextField("3 5 15 30 60", text: $presetsText)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .tint(Palette.accent)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 150)
                    .focused($focusedField, equals: .presets)
                    .onSubmit(commitPresets)
            }

            // 默认时长：标签在上，常用预设点选 + 自定义输入在下——五个预设加一个输入框
            // 横排会挤，上下排开更透气；分隔线把「预设」和「自定义」两种方式分开
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n.defaultDuration)
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 8) {
                    ForEach(settingsStore.settings.durationPresetsMinutes, id: \.self) { minutes in
                        let active = settingsStore.settings.defaultMinutes == minutes
                        Button {
                            setDefault(minutes: minutes)
                        } label: {
                            Text("\(minutes)m")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(active ? .black.opacity(0.85) : .white.opacity(0.5))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(active ? Palette.accent : Color.white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 1, height: 20)
                        .padding(.horizontal, 4)
                    // 自定义输入：直接敲数字回车，1–180 分钟
                    TextField(l10n.defaultMinutesPlaceholder, text: $defaultMinutesText)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .tint(Palette.accent)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        .focused($focusedField, equals: .defaultMinutes)
                        .onSubmit(commitDefaultMinutes)
                    Text("m")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            SettingsToggle(label: l10n.autoArmNewGoals, isOn: $settingsStore.settings.autoArmNewGoals)
            SettingsToggle(label: l10n.keepArmedAfterCreate, isOn: $settingsStore.settings.keepArmedAfterCreate)
            SettingsToggle(label: l10n.escDismissCheckIn, isOn: $settingsStore.settings.checkInEscDismisses)
        }
    }

    private func commitPresets() {
        let numbers = presetsText
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { Int($0) }
            .filter { $0 > 0 }
        if !numbers.isEmpty {
            settingsStore.settings.durationPresetsMinutes = Array(Set(numbers)).sorted()
        }
        // 解析不出有效数字就还原成当前值，不留一个空列表——那样武装面板就没有可选的时长了
        presetsText = settingsStore.settings.durationPresetsMinutes.map(String.init).joined(separator: " ")
    }

    /// 点常用预设块：直接设为默认时长，输入框同步
    private func setDefault(minutes: Int) {
        settingsStore.settings.defaultMinutes = minutes
        defaultMinutesText = "\(minutes)"
    }

    /// 自定义输入回车：解析 1–180，越界钳制；解析不了就还原当前值
    private func commitDefaultMinutes() {
        let parsed = Int(defaultMinutesText.trimmingCharacters(in: .whitespaces))
            ?? settingsStore.settings.defaultMinutes
        let clamped = min(max(parsed, 1), 180)
        settingsStore.settings.defaultMinutes = clamped
        defaultMinutesText = "\(clamped)"
    }

    // MARK: - 画布

    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(l10n.canvases)

            // 画布数量是用户可以一直加的，是这个面板里唯一可能顶破屏幕的一段。
            // 只有真的多到装不下才套 ScrollView 并给一个确定高度——
            // ScrollView 配 maxHeight: nil 不是「按内容收缩」而是「不受约束」，它会贪心地
            // 吃满可用高度，把整个面板撑到满屏，这正是外层要避免的那个毛病。
            if store.canvases.count > 5 {
                ScrollView(showsIndicators: false) { canvasRows }
                    .frame(height: 150)
            } else {
                canvasRows
            }

            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 16)
                TextField("", text: $newCanvasName)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .tint(Palette.accent)
                    .focused($focusedField, equals: .newCanvas)
                    .onSubmit(addCanvas)
                    // 自己画 placeholder：内建那个在这套暗色里几乎看不见，
                    // 只剩一个 + 号的话根本不知道这行能打字
                    .overlay(alignment: .leading) {
                        if newCanvasName.isEmpty {
                            Text(l10n.addCanvas)
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.3))
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }

    private var canvasRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(store.canvases) { canvas in
                CanvasRow(canvas: canvas, canDelete: store.canvases.count > 1, store: store)
            }
        }
    }

    private func addCanvas() {
        let trimmed = newCanvasName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addCanvas(name: trimmed)
        newCanvasName = ""
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(l10n.appearance)
            SettingsToggle(label: l10n.animatedBackground, isOn: $settingsStore.settings.animatedBackground)
            SettingsToggle(label: l10n.transparentMode, isOn: $settingsStore.settings.transparentMode)
            Text(l10n.transparentModeHint)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    // MARK: - 热键

    /// 录制交互：点「录制…」→ 这一行变「按任意键… Esc 取消」→ 本地监听把下一个键
    /// 交给 handleHotkeyRecording 写进 settings（didSet 自动 save + 订阅重注册热键）。
    /// 不合法键（普通字符键会吃字、App 已占用的组合）显示原因、继续录
    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(l10n.hotkeys)
            hotkeyRow(label: l10n.hotkeyShow, target: .show)
            hotkeyRow(label: l10n.hotkeyHide, target: .hide)
            if let msg = model.hotkeyRejectMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
            }
            Text(l10n.hotkeyHint)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private func hotkeyRow(label: String, target: HotkeyTarget) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            if model.recordingHotkey == target {
                Text(l10n.hotkeyRecording)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.accent)
            } else {
                Text(hotkeyDisplayName(target))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                Button(l10n.hotkeyRecord) {
                    model.recordingHotkey = target
                    model.hotkeyRejectMessage = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Palette.accent)
            }
        }
    }

    private func hotkeyDisplayName(_ target: HotkeyTarget) -> String {
        let s = settingsStore.settings
        return HotkeyName.name(
            keyCode: target == .show ? s.showHotkeyKeyCode : s.hideHotkeyKeyCode,
            modifiers: target == .show ? s.showHotkeyModifiers : s.hideHotkeyModifiers
        )
    }

    // MARK: - 布局

    /// 一个整体缩放，不是逐项独立可调——独立调很容易调出字比行高还高的破样子，
    /// 而这里没法截图看出来提前拦住，见 LayoutMetrics 的注释
    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(l10n.layout)
            SettingsPercentStepper(
                label: l10n.inputBarPosition,
                value: $settingsStore.settings.inputRestingFraction,
                range: 0.35...0.75, step: 0.02
            )
            SettingsPercentStepper(
                label: l10n.textSize,
                value: $settingsStore.settings.textScale,
                range: 0.75...1.35, step: 0.05
            )
        }
    }

    // MARK: - 语言

    /// 语言切换：分段控件，改完立刻全局生效（所有视图都观察 SettingsStore）
    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(l10n.languageTitle)
            Picker("", selection: $settingsStore.settings.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
        }
    }

    // MARK: - 历史

    /// 曾经的目标和签到反馈：跳到独立的历史子面板（数据就是 goals.json 里已勾选的目标）
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(l10n.history)
            Button(action: onOpenHistory) {
                HStack(spacing: 9) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14))
                    Text(l10n.viewHistory)
                        .font(.system(size: 17, weight: .regular, design: .rounded))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 帮助

    /// 「重播引导」：就是设置里的一个普通按钮——点一下面板关闭、立刻摆出引导卡。
    /// onboardingSeen 保持已看过，退出引导后下次启动不会再自动弹
    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(l10n.helpSection)
            Button {
                model.showSettings = false
                model.showOnboarding = true
            } label: {
                Text(l10n.replayOnboarding)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            Text(l10n.replayOnboardingHint)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    // MARK: - 共用小件

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
            .tracking(1.4)
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            content()
        }
    }
}

// MARK: - 画布行：色相选择 + 改名 + 删除

private struct CanvasRow: View {
    let canvas: Canvas
    let canDelete: Bool
    @ObservedObject var store: GoalStore

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                ForEach(Palette.canvasHues, id: \.self) { hue in
                    Circle()
                        .fill(Color(hue: hue / 360, saturation: 0.55, brightness: 0.85))
                        .frame(width: 14, height: 14)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(canvas.hueShift == hue ? 0.85 : 0), lineWidth: 2)
                        }
                        .onTapGesture { store.setCanvasHue(canvas.id, hue: hue) }
                }
            }

            TextField("", text: $name)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .textFieldStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .tint(Palette.accent)
                .focused($focused)
                .onSubmit { store.renameCanvas(canvas.id, to: name) }

            Spacer(minLength: 0)

            if canDelete {
                Button(action: { store.deleteCanvas(canvas.id) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.28))
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { name = canvas.name }
    }
}

// MARK: - 开关：小圆点滑动的胶囊，不是描边框

struct SettingsToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button(action: { isOn.toggle() }) {
            HStack {
                Text(label)
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isOn ? Palette.accent : Color.white.opacity(0.14))
                    .frame(width: 38, height: 22)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white.opacity(0.92))
                            .frame(width: 16, height: 16)
                            .padding(3)
                    }
            }
        }
        .buttonStyle(.plain)
        .animation(Motion.fade, value: isOn)
    }
}

// MARK: - 百分比步进器（给 0.0...1.0 范围的比例/缩放系数用）

struct SettingsPercentStepper: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            HStack(spacing: 14) {
                stepButton("minus") { value = max(range.lowerBound, value - step) }
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(minWidth: 44)
                stepButton("plus") { value = min(range.upperBound, value + step) }
            }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
