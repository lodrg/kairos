import SwiftUI

/// ⌘. 呼出的配置面板：盖住目标区，保持现有视觉语言，不开新窗口。
/// 布局原则：按重要度排序 + 卡片分组 + 两列并排吃满宽度——
/// 倒计时签到是核心（主题色强调卡放最前），热键其次，画布/外观/语言/工具依次排后。
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
        GeometryReader { geo in
            ZStack {
                // 目标区已经在 OverlayView 里整块淡掉了，这层只负责压暗极光让面板文字有对比度
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)

                // 自适应面板：屏幕放得下就用自然高度的 VStack（什么都不动）；
                // 放不下（小屏/低分辨率/缩放）时自动落到第二分支——整体带滚动、高度封顶，
                // 面板不再顶破屏幕。宽度也跟着屏幕收窄，不会横向溢出
                ViewThatFits(in: .vertical) {
                    panelContent(width: panelWidth(geo))
                    scrollablePanel(width: panelWidth(geo), available: geo.size.height)
                }
            }
        }
        .onAppear {
            presetsText = settingsStore.settings.durationPresetsMinutes.map(String.init).joined(separator: " ")
            defaultMinutesText = "\(settingsStore.settings.defaultMinutes)"
        }
    }

    /// 面板宽度：屏幕大就多用——默认 860（两张卡并排 + 签到卡内部双栏都需要宽度），
    /// 小屏/低分辨率时跟着收（留出两侧边距）
    private func panelWidth(_ geo: GeometryProxy) -> CGFloat {
        min(860, max(360, geo.size.width - 96))
    }

    /// 面板主体：自然高度的 VStack。用自然高度而不是固定高的 ScrollView：
    /// ScrollView 会吃满给它的高度，内容又是顶对齐的，于是面板整体偏上、
    /// 下面吊着一大块空白，看着就不像个居中的对话框。唯一可能无限长的是
    /// 画布列表，所以只在那一段内部加滚动（见 canvasCard）。
    /// 空间利用：签到卡内部双栏、短卡两两并排，屏幕宽就吃满；
    /// 屏幕窄到放不下两列时自动退回单列
    private func panelContent(width: CGFloat) -> some View {
        let wide = width >= 560
        return VStack(alignment: .leading, spacing: 18) {
            Text(l10n.settingsTitle)
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            // 重要度排序：核心（签到）→ 入口（热键）→ 数据（画布）→ 视觉 → 工具；
            // 短卡两两并排吃满宽度，长卡（签到/画布）独占一行
            checkInCard(wide: wide)
            if wide {
                grid2(hotkeyCard, languageCard)
            } else {
                hotkeyCard
                languageCard
            }
            canvasCard
            if wide {
                grid2(backgroundCard, appearanceCard(narrow: true))
            } else {
                backgroundCard
                appearanceCard(narrow: false)
            }
            linksCard

            Text(l10n.escToClose)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.28))
        }
        .padding(32)
        .frame(width: width, alignment: .leading)
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

    /// 屏幕放不下时的兜底：同一份内容包进 ScrollView，高度封顶在屏幕的 86%，
    /// 面板整体可滚动。ViewThatFits 只在自然高度真的放不下时才选到这里，
    /// 所以这里的内容高度必然超过封顶值，滚动是真实需要的。
    /// 用固定 height 而不是 maxHeight——SwiftUI 没有 frame(width:maxHeight:) 组合，
    /// 链两个 frame 在 ZStack 里会相互抢提案，行为不可靠
    private func scrollablePanel(width: CGFloat, available: CGFloat) -> some View {
        ScrollView(showsIndicators: false) {
            panelContent(width: width)
        }
        .frame(width: width, height: max(240, available * 0.86))
    }

    // MARK: - 卡片容器

    /// 分组卡片：每张卡一个浅底圆角容器，段落之间不再靠留白硬分。
    /// accent 卡给主题色描边 + 淡色底，用于核心功能（倒计时签到）的视觉强调——
    /// 重点就这一张，底色/描边都比普通卡更浓一点
    private func settingsCard<Content: View>(accent: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(accent ? Palette.accent.opacity(0.12) : Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(accent ? Palette.accent.opacity(0.5) : Color.white.opacity(0.07),
                                          lineWidth: accent ? 1.5 : 1)
                    )
            }
    }

    /// 两列等宽并排：短控件（开关、步进器、小卡片）不再一行一个浪费高度，
    /// 而是并排吃满卡片宽度
    private func grid2<L: View, R: View>(_ left: L, _ right: R) -> some View {
        HStack(alignment: .top, spacing: 12) {
            left.frame(maxWidth: .infinity, alignment: .leading)
            right.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 倒计时签到（核心，主题色强调卡）

    /// wide = 面板够宽：卡片内部双栏（左 = 预设/默认时长，右 = 两个开关），
    /// 吃满整张卡的宽度；窄屏退回上下排
    private func checkInCard(wide: Bool) -> some View {
        settingsCard(accent: true) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Image(systemName: "timer")
                            .font(.system(size: 13, weight: .semibold))
                        Text(l10n.countdownCheckIn)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .tracking(1.4)
                    }
                    .foregroundStyle(Palette.accent)
                    Text(l10n.countdownCheckInHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }

                if wide {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 14) {
                            presetsRow
                            defaultDurationBlock
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 14) {
                            SettingsToggle(label: l10n.autoArmNewGoals, isOn: $settingsStore.settings.autoArmNewGoals)
                            SettingsToggle(label: l10n.keepArmedAfterCreate, isOn: $settingsStore.settings.keepArmedAfterCreate)
                            SettingsToggle(label: l10n.showTimerBar, isOn: $settingsStore.settings.showTimerBar)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    presetsRow
                    defaultDurationBlock
                    grid2(
                        SettingsToggle(label: l10n.autoArmNewGoals, isOn: $settingsStore.settings.autoArmNewGoals),
                        SettingsToggle(label: l10n.keepArmedAfterCreate, isOn: $settingsStore.settings.keepArmedAfterCreate)
                    )
                    SettingsToggle(label: l10n.showTimerBar, isOn: $settingsStore.settings.showTimerBar)
                }
            }
        }
    }

    private var presetsRow: some View {
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
    }

    private var defaultDurationBlock: some View {
        // 默认时长：标签在上，常用预设点选 + 自定义输入在下——五个预设加一个输入框
        // 横排会挤，上下排开更透气；分隔线把「预设」和「自定义」两种方式分开
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.defaultDuration)
                .font(.system(size: 16, weight: .regular, design: .rounded))
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

    // MARK: - 热键（入口配置，排第二）

    /// 只有呼出键一个可录制项；收起永远是 Esc（走 AppDelegate 本地监听的分层退出），
    /// 不提供第二把钥匙。录制交互：点「录制…」→ 这一行变「按任意键… Esc 取消」→
    /// 本地监听把下一个键交给 handleHotkeyRecording 写进 settings（录完显式重注册）。
    /// 不合法键（普通字符键会吃字、App 已占用的组合）显示原因、继续录。
    /// 注册失败（被其他 App 占用）/ 媒体键 F 键单独红字提示——不再静默失败
    private var hotkeyCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(l10n.hotkeys)
                hotkeyRow(label: l10n.hotkeyShow)
                if model.showHotkeyConflicted {
                    Text(l10n.hotkeyConflict)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                }
                // 裸 F 键 + 系统把 F 键当媒体键：注册了也不会触发，红字指路
                if showKeyIsBareFKey && HotkeyName.functionKeysAreMedia() {
                    Text(l10n.hotkeyRejectMediaFKey)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                }
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
    }

    /// 当前呼出键是不是「裸 F 键」（无修饰）——媒体键提示只在这种情况出现
    private var showKeyIsBareFKey: Bool {
        let s = settingsStore.settings
        return s.showHotkeyModifiers == 0 && (HotkeyName.keyName(s.showHotkeyKeyCode)?.hasPrefix("F") ?? false)
    }

    private func hotkeyRow(label: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            if model.isRecordingHotkey {
                Text(l10n.hotkeyRecording)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.accent)
            } else {
                // 键帽式强调：当前呼出键一眼可见（它是 App 的入口）
                Text(hotkeyDisplayName())
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Palette.accent.opacity(0.12))
                            .strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1)
                    }
                Button(l10n.hotkeyRecord) {
                    model.isRecordingHotkey = true
                    model.hotkeyRejectMessage = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Palette.accent)
            }
        }
    }

    private func hotkeyDisplayName() -> String {
        let s = settingsStore.settings
        return HotkeyName.name(keyCode: s.showHotkeyKeyCode, modifiers: s.showHotkeyModifiers)
    }

    // MARK: - 画布

    private var canvasCard: some View {
        settingsCard {
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

    // MARK: - 背景（HSV 三项全可调）

    /// 背景独立成卡：动态背景开关 + 色相/饱和度/明度三个滑杆。
    /// 全在调色板源头做（HSV 缩放/偏移），不动布局/动效/画布逻辑
    private var backgroundCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(l10n.background)
                SettingsToggle(label: l10n.animatedBackground, isOn: $settingsStore.settings.animatedBackground)
                SettingsSlider(
                    label: l10n.hue,
                    value: $settingsStore.settings.backgroundHue,
                    range: 0...360
                ) { "\(Int($0.rounded()))°" }
                SettingsSlider(
                    label: l10n.saturation,
                    value: $settingsStore.settings.backgroundSaturation,
                    range: 0...2
                ) { "\(Int(($0 * 100).rounded()))%" }
                SettingsSlider(
                    label: l10n.brightness,
                    value: $settingsStore.settings.backgroundBrightness,
                    range: 0...2
                ) { "\(Int(($0 * 100).rounded()))%" }
            }
        }
    }

    // MARK: - 外观与布局（透明模式 + 布局步进器）

    /// 视觉相关放一张卡：透明模式开关 + 说明 + 两个比例步进器。
    /// narrow = 卡处于半宽（和背景卡并排）：步进器改上下堆叠，避免两列挤进半张卡。
    /// 一个整体缩放，不是逐项独立可调——独立调很容易调出字比行高还高的破样子，
    /// 而这里没法截图看出来提前拦住，见 LayoutMetrics 的注释
    private func appearanceCard(narrow: Bool) -> some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(l10n.appearanceLayout)
                SettingsToggle(label: l10n.transparentMode, isOn: $settingsStore.settings.transparentMode)
                Text(l10n.transparentModeHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
                if narrow {
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
                } else {
                    grid2(
                        SettingsPercentStepper(
                            label: l10n.inputBarPosition,
                            value: $settingsStore.settings.inputRestingFraction,
                            range: 0.35...0.75, step: 0.02
                        ),
                        SettingsPercentStepper(
                            label: l10n.textSize,
                            value: $settingsStore.settings.textScale,
                            range: 0.75...1.35, step: 0.05
                        )
                    )
                }
            }
        }
    }

    // MARK: - 语言

    /// 语言切换：分段控件，改完立刻全局生效（所有视图都观察 SettingsStore）
    private var languageCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(l10n.languageTitle)
                // 自定义分段控件：系统 .segmented 在暗色面板上未选中段对比度太低
                // （按系统外观渲染，灰字黑底），中文/English 经常"看不见"——换成本
                // App 自己的预设块语言：选中=主题色底白字，未选中=白8%底主题色字
                HStack(spacing: 8) {
                    languageChip(.en)
                    languageChip(.zh)
                }
            }
        }
    }

    private func languageChip(_ lang: AppLanguage) -> some View {
        let isOn = settingsStore.settings.language == lang
        return Button {
            settingsStore.settings.language = lang
        } label: {
            Text(lang.displayName)
                .font(.system(size: 14, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.white : Palette.accent)
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isOn ? Palette.accent : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 历史 + 帮助 + 更新（工具，三张小卡并排）

    /// 曾经的目标和签到反馈 → 历史子面板；重播首次引导 → 引导卡；
    /// 检查更新 → GitHub API 对比版本（轻量档，以后换 Sparkle）
    private var linksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                linkButton(
                    icon: "clock.arrow.circlepath",
                    title: l10n.history,
                    subtitle: l10n.viewHistory,
                    action: onOpenHistory
                )
                linkButton(
                    icon: "questionmark.circle",
                    title: l10n.helpSection,
                    subtitle: l10n.replayOnboarding
                ) {
                    model.showSettings = false
                    model.showOnboarding = true
                }
                linkButton(
                    icon: "arrow.down.circle",
                    title: l10n.checkForUpdates,
                    subtitle: String(format: l10n.currentVersionFormat, UpdateChecker.currentVersion),
                    action: checkForUpdates
                )
            }
            updateStatusRow
        }
    }

    /// 检查更新的结果：检查中 / 已最新 / 发现新版（点一下打开下载页）/ 失败
    @ViewBuilder
    private var updateStatusRow: some View {
        switch model.updateStatus {
        case .checking:
            Text(l10n.updateChecking)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
        case .upToDate:
            Text(l10n.updateUpToDate)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
        case .updateAvailable(let version):
            Button {
                NSWorkspace.shared.open(UpdateChecker.downloadPageURL(for: version))
            } label: {
                Text(String(format: l10n.updateAvailableFormat, version))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
        case .failed:
            Text(l10n.updateFailed)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
        case nil:
            EmptyView()
        }
    }

    private func checkForUpdates() {
        model.updateStatus = .checking
        Task { @MainActor in
            guard let latest = await UpdateChecker.latestVersion() else {
                model.updateStatus = .failed
                return
            }
            model.updateStatus = UpdateChecker.isNewer(latest, than: UpdateChecker.currentVersion)
                ? .updateAvailable(version: latest)
                : .upToDate
        }
    }

    private func linkButton(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .foregroundStyle(.white.opacity(0.85))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 共用小件

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
            .tracking(1.4)
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 16, weight: .regular, design: .rounded))
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
                .font(.system(size: 16, weight: .medium, design: .rounded))
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
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
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

// MARK: - 滑杆（连续值调节，HSV 色相/饱和度/明度用）

struct SettingsSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// 值的显示格式（比如「120°」「140%」）
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 56, alignment: .leading)
            Slider(value: $value, in: range)
                .tint(Palette.accent)
            Text(format(value))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
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
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                stepButton("minus") { value = max(range.lowerBound, value - step) }
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(minWidth: 40)
                stepButton("plus") { value = min(range.upperBound, value + step) }
            }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
