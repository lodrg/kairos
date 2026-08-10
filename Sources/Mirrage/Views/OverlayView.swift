import SwiftUI

enum FocusField: Hashable {
    case input
    case edit(UUID)
}

/// 一行要渲染的目标 + 它的嵌套深度（0 顶层 / 1 子目标，只允许这两级）
private struct GoalRowInfo: Identifiable {
    let goal: Goal
    let depth: Int
    var id: UUID { goal.id }
    func height(_ sizing: LayoutMetrics) -> CGFloat { depth == 0 ? sizing.rowHeight : sizing.subRowHeight }
}

/// GoalRowInfo 算出实际的 offsetFromBottom 之后的样子，喂给 ForEach
private struct PlacedRow: Identifiable {
    let info: GoalRowInfo
    let offset: CGFloat
    var id: UUID { info.id }
}

struct OverlayView: View {
    @ObservedObject var store: GoalStore
    @ObservedObject var model: OverlayModel
    @ObservedObject var settingsStore: SettingsStore
    @FocusState private var focusedField: FocusField?

    /// 切画布时的行进方向（+1 下一个 / -1 上一个），决定交叉淡入的偏移朝向
    @State private var switchDirection: Int = 1
    /// 画布名的临时提示：切换时淡入，停一下后淡出
    @State private var showCanvasName = false
    @State private var nameFlashTask: Task<Void, Never>?
    /// 全屏重选时长卡片里「自定义时长」输入框的草稿
    @State private var retimeCustomText = ""

    /// 时长预设，Off 恒在最前面，后面接配置里可编辑的分钟数列表
    private var durationOptions: [Int?] {
        [nil] + settingsStore.settings.durationPresetsMinutes
    }

    /// 配置面板里「输入栏位置」「文字大小」两个滑块解析出来的实际尺寸；
    /// 一个整体缩放系数而不是逐个常量独立可调，见 LayoutMetrics 的注释
    private var sizing: LayoutMetrics {
        LayoutMetrics(scale: settingsStore.settings.textScale, restingFraction: settingsStore.settings.inputRestingFraction)
    }

    /// 有没有全屏接管画面的东西开着（签到或配置面板或历史面板或重选时长或首启引导）
    private var isModalUp: Bool {
        model.pendingCheckInID != nil || model.showSettings || model.showHistory
            || model.retimingGoalID != nil || model.showOnboarding
    }

    private var l10n: L10n { L10n(language: settingsStore.settings.language) }

    var body: some View {
        ZStack {
            AuroraBackground(
                active: model.animatedIn,
                animated: settingsStore.settings.animatedBackground
            )
            .hueRotation(.degrees(store.activeCanvas.hueShift))
            .animation(Motion.canvasSwitch, value: store.activeCanvasID)
            // 签到 / 配置面板弹出时把目标区整块淡掉，而不是靠 scrim 盖住它——
            // 盖是盖不干净的：46pt 的大字即使被 0.9 的黑压着也还透得出来，
            // 跟卡片自己的标题叠在一起像渲染坏了。真正让它退场才干净，
            // 极光背景留着，视觉身份不丢。
            content
                .opacity(isModalUp ? 0 : 1)
                .animation(Motion.reveal, value: isModalUp)
            canvasNameFlash
                .opacity(isModalUp ? 0 : 1)
            settingsOverlay
            historyOverlay
            checkInOverlay
            retimePicker
            onboardingOverlay
        }
        .onChange(of: model.animatedIn) { _, isIn in
            if isIn {
                focusedField = .input
            }
        }
        .onChange(of: model.editingID) { _, editing in
            // 编辑结束（保存或 Esc 取消）后焦点必须交回输入栏，
            // 否则 @FocusState 还指向已经消失的 .edit(id)，键盘输入无处可去
            if editing == nil, model.animatedIn { focusedField = .input }
        }
        .onChange(of: model.pendingCheckInID) { _, pending in
            // 签到弹出时收走焦点，防止 D/K/S/X 之类的快捷键被打进还聚焦着的输入框；
            // 签到消失后焦点还给输入栏
            if pending != nil {
                focusedField = nil
            } else if model.animatedIn {
                focusedField = .input
            }
        }
        .onChange(of: model.showSettings) { _, showing in
            if showing {
                focusedField = nil
            } else if model.animatedIn {
                focusedField = .input
            }
        }
        // ⌘. 不在这里处理：已实测确认带 command 的组合键会被 AppKit 的 key-equivalent
        // 通道吃掉，根本不会到 onKeyPress。它跟 Esc 一样放在 AppDelegate 的
        // NSEvent 本地监听里（那条路在这个 App 里已经验证能用）。
        // 方向键左右 = 切换画布（下钻的进入/退回交给 Tab / Shift+Tab，见 handleTab）——
        // 只在输入框为空、不在编辑、没有签到弹出、也没在选时长时拦截；
        // 返回 .ignored 时正常交回给 TextField 移动光标，不影响输入
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard model.animatedIn, model.pendingCheckInID == nil, !model.isChoosingDuration,
                  model.inputText.isEmpty, model.editingID == nil,
                  store.canvases.count > 1 else { return .ignored }
            switchCanvas(by: press.key == .rightArrow ? 1 : -1)
            return .handled
        }
        // 选时长预设时，左右键改选哪个预设，不切画布——两者的 guard 互斥，谁都不会抢对方的键
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard model.isChoosingDuration else { return .ignored }
            let delta = press.key == .rightArrow ? 1 : -1
            model.draftMinutesIndex = max(0, min(durationOptions.count - 1, model.draftMinutesIndex + delta))
            return .handled
        }
        // 上下键移动选中行，同样只在输入框为空、不在编辑、没有签到弹出时拦截
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard model.animatedIn, model.pendingCheckInID == nil,
                  model.inputText.isEmpty, model.editingID == nil else { return .ignored }
            moveSelection(by: press.key == .downArrow ? 1 : -1)
            return .handled
        }
        // Tab 不在这里处理：onKeyPress 收不到 Shift+Tab（AppKit 焦点循环先吃掉）。
        // 它跟 Esc 一样放在 AppDelegate 的 NSEvent 本地监听里（那条路已验证能用），
        // 由 handleTabRequest 转发到 handleTab。
        // 签到卡片的按键不在这里处理：Enter 走卡片输入框的 onSubmit，Esc 走 AppDelegate
        // 本地监听——就两个键，不需要在 SwiftUI 层再拦一遍
    }

    private func switchCanvas(by delta: Int) {
        switchDirection = delta
        model.selectedID = nil
        model.inputParentID = nil
        withAnimation(Motion.canvasSwitch) { store.cycleCanvas(by: delta) }
        flashCanvasName()
    }

    private func flashCanvasName() {
        nameFlashTask?.cancel()
        withAnimation(Motion.fade) { showCanvasName = true }
        nameFlashTask = Task {
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.fade) { showCanvasName = false }
        }
    }

    private var canvasNameFlash: some View {
        Text(store.activeCanvas.name)
            .font(.system(size: 20, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.top, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(showCanvasName ? 1 : 0)
            .allowsHitTesting(false)
    }

    // MARK: - 配置面板

    /// 首启引导卡：一生一次（settings.onboardingSeen）。键名显示自定义后的实际键
    private var onboardingOverlay: some View {
        Group {
            if model.showOnboarding {
                let s = settingsStore.settings
                let showName = HotkeyName.name(keyCode: s.showHotkeyKeyCode, modifiers: s.showHotkeyModifiers)
                let hideName = HotkeyName.name(keyCode: s.hideHotkeyKeyCode, modifiers: s.hideHotkeyModifiers)
                OnboardingView(
                    l10n: l10n,
                    showKeyName: showName,
                    hideKeyName: hideName,
                    sameKey: showName == hideName
                )
                .transition(.opacity)
            }
        }
    }

    private var settingsOverlay: some View {
        Group {
            if model.showSettings {
                SettingsPanel(
                    settingsStore: settingsStore,
                    store: store,
                    model: model,
                    onClose: { model.showSettings = false },
                    onOpenHistory: {
                        model.showSettings = false
                        model.showHistory = true
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(Motion.reveal, value: model.showSettings)
    }

    // MARK: - 历史子面板（设置 → 历史）

    private var historyOverlay: some View {
        Group {
            if model.showHistory {
                HistoryPanel(store: store, l10n: l10n, onClose: { model.showHistory = false })
                    .transition(.opacity)
            }
        }
        .animation(Motion.reveal, value: model.showHistory)
    }

    // MARK: - 强制签到

    /// 全屏重选时长卡片。Esc 继续后的专用界面：大块预设 + 自定义输入，整屏呈现，
    /// 不再挤在输入栏底部那条小横条里。←/→ 和回车复用 isChoosingDuration 的既有键位；
    /// Esc / 点卡片外 = 取消（目标已按原时长继续）。
    /// 视觉与签到卡片同款：不套卡片框，直接浮在压暗的极光上——整屏大字极简
    private var retimePicker: some View {
        Group {
            if let id = model.retimingGoalID, let goal = store.goals.first(where: { $0.id == id }) {
                ZStack {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture(perform: cancelRetime)

                    VStack(spacing: 26) {
                        Text(l10n.retimeTitle)
                            .font(.system(size: 22, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))

                        Text(goal.text)
                            .font(.system(size: 50, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)

                        HStack(spacing: 14) {
                            ForEach(Array(durationOptions.enumerated()), id: \.offset) { index, minutes in
                                let active = index == model.draftMinutesIndex
                                Text(minutes.map { "\($0)m" } ?? l10n.durationOff)
                                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                                    .foregroundStyle(active ? .black.opacity(0.9) : .white.opacity(0.72))
                                    .frame(width: 88, height: 64)
                                    .background(active ? Palette.accent : Color.white.opacity(0.06),
                                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.draftMinutesIndex = index }
                            }
                        }

                        // 自定义时长：与签到卡片反馈输入框同款样式，点进去输入数字回车
                        HStack(spacing: 8) {
                            TextField(l10n.defaultMinutesPlaceholder, text: $retimeCustomText)
                                .font(.system(size: 18, weight: .regular, design: .rounded))
                                .textFieldStyle(.plain)
                                .foregroundStyle(.white)
                                .tint(Palette.accent)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 120)
                                .onSubmit(commitRetimeCustom)
                            Text("m")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        }

                        Text(l10n.retimeHint)
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .padding(.horizontal, 56)
                    .padding(.vertical, 40)
                    .frame(maxWidth: 720)
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.reveal, value: model.retimingGoalID)
    }

    /// 全屏重选时长：自定义输入回车——直接按输入值武装，1–180 钳制
    private func commitRetimeCustom() {
        guard let target = model.retimingGoalID else { return }
        let parsed = Int(retimeCustomText.trimmingCharacters(in: .whitespaces))
            ?? (durationOptions[model.draftMinutesIndex] ?? settingsStore.settings.defaultMinutes)
        store.setTimer(goalID: target, minutes: min(max(parsed, 1), 180))
        model.retimingGoalID = nil
        model.isChoosingDuration = false
        model.armingTargetID = nil
        focusedField = .input
    }

    /// 取消全屏重选：目标已按原时长继续，直接关掉选择界面
    private func cancelRetime() {
        model.retimingGoalID = nil
        model.isChoosingDuration = false
        model.armingTargetID = nil
        focusedField = .input
    }

    /// 签到卡片的两个动作；Enter（结束）走卡片输入框的 onSubmit，Esc（继续）走
    /// AppDelegate 的 continueCheckInWithTimePick——这里只管状态转换，不碰键盘
    enum CheckInAction { case done, keepGoing }

    /// 到期目标的签到卡片。scrim 吞掉点击而不是穿透——这是「强制」的一部分：
    /// 点卡片外面不能把它关掉，退路只有 Snooze 和菜单栏 Quit。
    /// 目标区已经在 body 里整块淡掉了，所以这层只需要压暗极光提高文字对比度，不用去盖内容。
    private var checkInOverlay: some View {
        Group {
            if let id = model.pendingCheckInID, let goal = store.goals.first(where: { $0.id == id }) {
                ZStack {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {}
                    CheckInView(
                        goal: goal,
                        l10n: l10n,
                        feedbackText: $model.checkInFeedback,
                        onSubmitFeedback: { resolveCheckIn(id: id, action: .done) }
                    )
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.reveal, value: model.pendingCheckInID)
    }

    func resolveCheckIn(id: UUID, action: CheckInAction) {
        guard let goal = store.goals.first(where: { $0.id == id }) else {
            model.pendingCheckInID = nil
            return
        }
        // 先清掉签到态再执行动作：卡片立即开始淡出
        model.pendingCheckInID = nil
        switch action {
        case .done:
            saveFeedback(goalID: id) // 反馈随完成一起存进 goals.json
            complete(goal)
        case .keepGoing:
            // 继续：按原时长重启计时。反馈草稿不清——下次到期弹卡片时输入还在
            if let minutes = goal.timer?.minutes {
                store.setTimer(goalID: id, minutes: minutes)
            }
        }
        focusedField = .input
    }

    /// Esc：继续这个目标——先按原时长重启计时，再弹**全屏**时长选择让用户重选
    /// （←/→ 选、回车确认；再按 Esc 或点外面取消，保持原时长）
    func continueCheckInWithTimePick() {
        guard let id = model.pendingCheckInID else { return }
        resolveCheckIn(id: id, action: .keepGoing)
        model.retimingGoalID = id
        model.isChoosingDuration = true
        model.armingTargetID = id
        retimeCustomText = ""
        // 默认选中 3 分钟（用户指定：这个页面的默认落在 3m）；
        // 预设里没有 3 才退回它原来的时长，再没有就用第一个
        if let idx = durationOptions.firstIndex(where: { $0 == 3 }) {
            model.draftMinutesIndex = idx
        } else if let minutes = store.goals.first(where: { $0.id == id })?.timer?.minutes,
                  let idx = durationOptions.firstIndex(where: { $0 == minutes }) {
            model.draftMinutesIndex = idx
        } else {
            model.draftMinutesIndex = 0
        }
    }

    /// 把反馈草稿存到目标上；继续（keepGoing）不清草稿——下次到期弹卡片时输入还在
    private func saveFeedback(goalID: UUID) {
        let text = model.checkInFeedback
        model.checkInFeedback = ""
        store.setFeedback(id: goalID, feedback: text)
    }

    /// 目标少时输入栏停在 `sizing.inputRestingFraction` 那个高度（配置面板可调）；
    /// 目标堆到要越过上缘时，列表区继续往下长、输入栏跟着下沉；沉到离底部还剩
    /// bottomInset 就停住，再多的目标从顶部渐隐让位。
    ///
    /// 高度全部由「行高常量 × 行数」累加算出，不测量任何子视图，
    /// 所以不存在「内容高度 → 布局 → 内容高度」的回路。子目标行更矮，
    /// 所以是累加每行各自的高度，不是简单的「行数 × 单一行高」。
    private var content: some View {
        GeometryReader { geo in
            let sizing = sizing
            let bottomInset: CGFloat = 56
            let restingHeight = max(0, geo.size.height * sizing.inputRestingFraction - sizing.inputBarHeight / 2)
            let maxHeight = max(sizing.rowHeight, geo.size.height - sizing.inputBarHeight - bottomInset)

            let (shown, overflowing) = trimToFit(visibleRows, maxHeight: maxHeight, sizing: sizing)
            let rowsHeight = shown.reduce(CGFloat(0)) { $0 + $1.height(sizing) }
            let listHeight = min(max(restingHeight, rowsHeight), maxHeight)
            let area = goalArea(shown: shown, sizing: sizing).frame(height: listHeight, alignment: .bottom)

            VStack(spacing: 0) {
                // mask 会把内容裁到遮罩自身的范围内，所以只在真的需要顶部渐隐时才上。
                // 之前无条件挂遮罩、且遮罩高度是「行数 × 行高」，勾掉一条时它瞬间少一行，
                // 而剩下的行还停在动画途中的旧位置，于是最上面那行的文字被切掉了顶部。
                if overflowing {
                    area.mask(topFade)
                } else {
                    area
                }

                inputBar
                    .frame(height: sizing.inputBarHeight)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: Metrics.contentWidth)
            .frame(width: geo.size.width, height: geo.size.height)
            // 输入栏下沉和回升都走这一条：不管是新建、勾选还是撤销引起的，位置变化一律慢慢挪
            .animation(Motion.layout, value: listHeight)
        }
    }

    /// 当前画布的全部目标，不筛完成状态——分组要看清父子关系，可见性筛选放到
    /// 分好组之后逐行做（见 visibleRows），这样父目标退场不会连带切掉还没完成的子目标
    private var canvasGoals: [Goal] {
        store.goals.filter { $0.canvasID == store.activeCanvasID }
    }

    /// 顶层目标 + 紧随其后的子目标，按创建顺序；子目标永远跟在自己的父目标后面，
    /// 不管它们在 store.goals 数组里实际的先后顺序（数组是按创建时间追加的）。
    /// 只两层：子目标不再有子目标（handleTab 挂靠只允许顶层目标 + 加载时归一化兜底）
    private var groupedRows: [GoalRowInfo] {
        let all = canvasGoals
        let topLevel = all.filter { $0.parentID == nil }
        var rows: [GoalRowInfo] = []
        for parent in topLevel {
            rows.append(GoalRowInfo(goal: parent, depth: 0))
            for child in all where child.parentID == parent.id {
                rows.append(GoalRowInfo(goal: child, depth: 1))
            }
        }
        return rows
    }

    /// 套完成状态 / 淡出可见性；这一步独立于分组，父目标退场不会带走还开着的子目标——
    /// 它们会以「没有可见父目标的缩进行」单独显示，不会消失
    private var visibleRows: [GoalRowInfo] {
        groupedRows.filter { info in
            if model.retiredIDs.contains(info.goal.id) { return false }
            if info.goal.isDone { return model.completingIDs.contains(info.goal.id) }
            return true
        }
    }

    /// suffix(fitCount) 泛化到不等高的行：从最新（数组末尾，紧贴输入栏）往回累加高度，
    /// 一旦下一行会超过 maxHeight 就停，取能装下的那一段
    private func trimToFit(_ rows: [GoalRowInfo], maxHeight: CGFloat, sizing: LayoutMetrics) -> (shown: [GoalRowInfo], overflowing: Bool) {
        guard !rows.isEmpty else { return ([], false) }
        var total: CGFloat = 0
        var cutIndex = rows.count
        for i in stride(from: rows.count - 1, through: 0, by: -1) {
            let h = rows[i].height(sizing)
            if total + h > maxHeight { break }
            total += h
            cutIndex = i
        }
        return (Array(rows[cutIndex...]), cutIndex > 0)
    }

    /// 行不靠 VStack 自然重排，而是按累加高度显式定位。
    /// 交给 VStack 重排的话，位置变化没有对应的可绑定值，只能靠外层 withAnimation 的
    /// 环境事务；而行自己的 .animation(_:value:) 会把环境动画挡掉，结果就是瞬间跳位。
    ///
    /// 这里不设固定高度：`offset` 不参与布局，高度交给外层的 listHeight 决定，
    /// 免得容器边界在动画途中裁掉还没走到位的行。
    ///
    /// `.id(activeCanvasID)` 让整块内容在切画布时被当成全新的子树，配合 `.transition`
    /// 做交叉淡入 + 顺方向位移；不做横向滑动是因为滑动要求所有画布常驻视图树，
    /// 而各画布 listHeight 不同，输入框位置会打架。
    private func goalArea(shown: [GoalRowInfo], sizing: LayoutMetrics) -> some View {
        Group {
            if shown.isEmpty {
                emptyHint
            } else {
                ZStack(alignment: .bottomLeading) {
                    // 高亮父目标：正在编辑的子目标的父，或输入栏正挂靠着的父（输入子目标时）
                    let highlightedParentID = model.editingID.flatMap { id in
                        store.goals.first(where: { $0.id == id })?.parentID
                    } ?? model.inputParentID
                    ForEach(layout(shown, sizing: sizing), id: \.id) { placed in
                        GoalRow(
                            goal: placed.info.goal,
                            depth: placed.info.depth,
                            offsetFromBottom: placed.offset,
                            sizing: sizing,
                            revealed: model.animatedIn,
                            isCompleting: model.completingIDs.contains(placed.info.goal.id),
                            isEditing: model.editingID == placed.info.goal.id,
                            isSelected: model.selectedID == placed.info.goal.id,
                            isParentHighlighted: placed.info.goal.id == highlightedParentID,
                            editText: $model.editText,
                            focusedField: $focusedField,
                            onToggle: { complete(placed.info.goal) },
                            onBeginEdit: { beginEdit(placed.info.goal) },
                            onCommitEdit: { commitEdit() }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id(store.activeCanvasID)
        .transition(canvasTransition)
    }

    /// 每行到列表底部的偏移 = 它下面（比它新）所有行的高度之和。纯函数，不量 geometry；
    /// CGFloat 和之前的 Int indexFromBottom 一样是可绑定值，.animation(_:value:) 照样生效
    private func layout(_ shown: [GoalRowInfo], sizing: LayoutMetrics) -> [PlacedRow] {
        var offset: CGFloat = 0
        var placed: [PlacedRow] = []
        for info in shown.reversed() {
            placed.append(PlacedRow(info: info, offset: offset))
            offset += info.height(sizing)
        }
        return placed.reversed()
    }

    private var canvasTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: CGFloat(switchDirection) * Motion.canvasSwitchTravel)),
            removal: .opacity.combined(with: .offset(x: CGFloat(-switchDirection) * Motion.canvasSwitchTravel))
        )
    }

    private var topFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.16),
                .init(color: .black, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var emptyHint: some View {
        Text(l10n.noGoalsYet)
            .font(.system(size: 26, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.16))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 26)
            .opacity(model.animatedIn ? 1 : 0)
            .animation(Motion.reveal, value: model.animatedIn)
    }

    /// 固定切两段：上面 26pt 是「正在选时长」的提示位，不管显不显示都占着；
    /// 下面 inputBarHeight-26 是真正的输入行，在这段里居中——这样输入行的竖直
    /// 位置永远不变，不会因为提示行的显隐而上下窜动。
    /// 不再显示「正在给谁加子目标」的文字——父目标高亮已经足够显式
    private var inputBar: some View {
        let sizing = sizing
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if model.isChoosingDuration {
                    durationPicker
                }
            }
            .frame(height: 26, alignment: .bottom)

            HStack(spacing: sizing.gutter) {
                Image(systemName: "plus")
                    .font(.system(size: sizing.boxSize * 0.6, weight: .light))
                    .foregroundStyle(.white.opacity(0.24))
                    .frame(width: sizing.boxSize, alignment: .center)

                TextField("", text: $model.inputText)
                    .font(.system(size: sizing.inputFont, weight: .medium, design: .rounded))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .input)
                    .onSubmit(handleInputSubmit)
                    .foregroundStyle(.white)
                    .tint(Palette.accent)
                    // 自己画 placeholder：TextField 内建的那个改不了透明度
                    .overlay(alignment: .leading) {
                        if model.inputText.isEmpty {
                            Text(l10n.newGoalPlaceholder)
                                .font(.system(size: sizing.inputFont, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.15))
                                .allowsHitTesting(false)
                        }
                    }

                armIndicator
            }
            .padding(.leading, model.inputParentID != nil ? sizing.subIndent : 0)
            .frame(height: sizing.inputBarHeight - 26, alignment: .center)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: sizing.inputBarHeight)
        .opacity(model.animatedIn ? 1 : 0)
        .animation(Motion.reveal, value: model.animatedIn)
        .animation(Motion.commit, value: model.inputParentID)
        .animation(Motion.commit, value: model.isChoosingDuration)
    }

    /// 时长预设一排小方块，当前选中高亮；左右键在 body 里的 onKeyPress 处理。
    /// 预设里等于「默认时长」的那块右上角有个小点——⌘+Enter 用的就是这个值，一眼可见；
    /// 配置里改默认值，小点实时跟着换位置
    private var durationPicker: some View {
        HStack(spacing: 8) {
            ForEach(Array(durationOptions.enumerated()), id: \.offset) { index, minutes in
                let active = index == model.draftMinutesIndex
                let isDefault = minutes == settingsStore.settings.defaultMinutes
                Text(minutes.map { "\($0)m" } ?? l10n.durationOff)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(active ? .black.opacity(0.85) : .white.opacity(0.4))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(active ? Palette.accent : Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if isDefault {
                            Circle()
                                .fill(Palette.accent)
                                .frame(width: 4, height: 4)
                                .padding(1.5)
                        }
                    }
                    .help(l10n.durationDefaultHint)
            }
        }
        .transition(.opacity)
    }

    /// 下一条新目标的**实际**武装时长：⌘T 手动选的（armedMinutes）优先；
    /// 没手动选且开了自动武装 = 跟随「默认时长」的当前值——
    /// 改默认时长，指示和武装立即跟着变，不缓存旧值
    private var effectiveArmedMinutes: Int? {
        if let m = model.armedMinutes { return m }
        if settingsStore.settings.autoArmNewGoals { return settingsStore.settings.defaultMinutes }
        return nil
    }

    /// 输入栏右侧那个「方便的开启按钮」：没武装时是暗淡的表盘图标，武装后亮起并显示分钟数。
    /// 点它或 ⌘T 都能开合时长选择——⌘T 走 SwiftUI 的 keyboardShortcut，不需要
    /// 像方向键那样操心是否会被聚焦中的 TextField 抢掉，这是更常规、有文档保证的机制
    private var armIndicator: some View {
        Button(action: toggleArming) {
            HStack(spacing: 5) {
                Image(systemName: effectiveArmedMinutes == nil ? "timer" : "timer.circle.fill")
                    .font(.system(size: 17))
                if let minutes = effectiveArmedMinutes {
                    Text("\(minutes)m")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                }
            }
            .foregroundStyle(effectiveArmedMinutes == nil ? .white.opacity(0.22) : Palette.accent)
        }
        .buttonStyle(.plain)
        // 不进 Tab 焦点循环：这个按钮被 Tab 选到会误触计时器，而且焦点一离开输入框就打不了字
        .focusable(false)
        .keyboardShortcut("t", modifiers: .command)
    }

    // MARK: - 动作

    /// 输入栏唯一的 Return 入口。选时长时第一次 Return 是「确认时长」，
    /// 不是「建目标」——靠这个分支就避免了去猜 onKeyPress 和 TextField 自带的
    /// onSubmit 谁先谁后这种没有文档保证的顺序问题，比截 Return 键本身简单得多
    private func handleInputSubmit() {
        guard model.pendingCheckInID == nil else { return }
        if model.isChoosingDuration {
            let minutes = durationOptions[model.draftMinutesIndex]
            if let target = model.armingTargetID {
                store.setTimer(goalID: target, minutes: minutes)
            } else {
                model.armedMinutes = minutes
            }
            model.isChoosingDuration = false
            model.retimingGoalID = nil
            return
        }
        let text = model.inputText
        // 输入框空 + 有选中：回车 = 勾掉选中的目标（和点方块一样：淡出，淡出中可撤销）
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let id = model.selectedID,
               let goal = store.goals.first(where: { $0.id == id }) {
                model.selectedID = nil
                complete(goal)
            }
            return
        }
        withAnimation(Motion.commit) {
            store.add(text, parentID: model.inputParentID, minutes: effectiveArmedMinutes)
        }
        model.inputText = ""
        focusedField = .input
        // inputParentID 故意不清——连续回车能逐条加子目标，直到 Shift+Tab / Esc 主动退回顶层。
        // armedMinutes 是否保留由「创建后是否保持武装」这个配置项决定，默认不保留
        if !settingsStore.settings.keepArmedAfterCreate {
            model.armedMinutes = nil
        }
    }

    /// ⌘+Enter：新建目标并**直接按「默认时长」武装**，跳过 ⌘T 的时长选择。
    /// 和普通回车同一个收尾：挂靠保留（连续加子目标）、输入清空；armedMinutes 不受影响
    func handleInputSubmitArmed() {
        guard model.pendingCheckInID == nil else { return }
        let text = model.inputText
        // 输入框空：跟普通回车一样——勾掉选中的目标
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let id = model.selectedID,
               let goal = store.goals.first(where: { $0.id == id }) {
                model.selectedID = nil
                complete(goal)
            }
            return
        }
        withAnimation(Motion.commit) {
            store.add(text, parentID: model.inputParentID, minutes: settingsStore.settings.defaultMinutes)
        }
        model.inputText = ""
        focusedField = .input
    }

    /// ⌘T / 点表盘图标：选中了目标（且没在打字）就武装那一条本身；否则武装下一条新建目标
    private func toggleArming() {
        guard model.pendingCheckInID == nil else { return }
        if model.isChoosingDuration {
            model.isChoosingDuration = false
            return
        }
        if let selected = model.selectedID, model.inputText.isEmpty {
            model.armingTargetID = selected
            let current = store.goals.first(where: { $0.id == selected })?.timer?.minutes
            model.draftMinutesIndex = durationOptions.firstIndex(of: current)
                ?? durationOptions.firstIndex(of: settingsStore.settings.defaultMinutes) ?? 0
        } else {
            model.armingTargetID = nil
            model.draftMinutesIndex = durationOptions.firstIndex(of: effectiveArmedMinutes)
                ?? durationOptions.firstIndex(of: settingsStore.settings.defaultMinutes) ?? 0
        }
        model.isChoosingDuration = true
    }

    private func beginEdit(_ goal: Goal) {
        // 已经在编辑别的目标时先落盘，否则那一条改了一半的内容会被静默丢掉
        if let current = model.editingID, current != goal.id {
            store.update(id: current, text: model.editText)
        }
        model.selectedID = goal.id
        model.editingID = goal.id
        model.editText = goal.text
        focusedField = .edit(goal.id)
    }

    private func commitEdit() {
        guard let id = model.editingID else { return }
        withAnimation(Motion.commit) { store.update(id: id, text: model.editText) }
        model.editingID = nil
    }

    private func complete(_ goal: Goal) {
        // 撤销完成（淡出中再点）：目标要回来了，选中光标不动
        if goal.isDone {
            model.completingIDs.remove(goal.id)
            model.retiredIDs.remove(goal.id)
            withAnimation(Motion.commit) { store.toggle(goal.id) }
            return
        }

        // 完成：选中光标别停在会被淡出退休的目标上——挤到**上一条**可见目标
        // （它原地不动，光标不会跳；没有上一条才用下一条）。撤销完成不动光标
        model.selectedID = fallbackSelectionID(after: goal.id)

        store.toggle(goal.id)
        model.completingIDs.insert(goal.id)

        let id = goal.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Motion.completion))
            // 期间被撤销就不再退场
            guard model.completingIDs.contains(id) else { return }
            model.completingIDs.remove(id)
            withAnimation(Motion.commit) { _ = model.retiredIDs.insert(id) }
        }
    }

    // MARK: - 键盘：选中 + 子目标

    /// 目标完成退场后选中光标的落点：优先**上一条**（列表顺序上更靠上、更旧的那条）——
    /// 它在行位移中原地不动，光标不会跳；没有上一条才落到下一条；都没有就清空。
    /// 注意要在目标 retire 之前调用——那时它还在 visibleRows 里，能算出它的位置
    private func fallbackSelectionID(after id: UUID) -> UUID? {
        let ids = visibleRows.map(\.goal.id)
        guard let idx = ids.firstIndex(of: id) else { return nil }
        if idx > 0 { return ids[idx - 1] }
        if idx + 1 < ids.count { return ids[idx + 1] }
        return nil
    }

    /// 上下键在当前可见行里移动选中项。可见行按「旧→新」排列（上面旧、下面新），
    /// 输入栏在列表下方——所以从输入栏按 ↑ 应该先碰到紧贴输入栏的那条（= 列表最后一条，
    /// 最新），再继续往上走；按 ↓ 则从最上面（最旧）那条开始。
    ///
    /// 挂靠状态（正在输入子目标）下不产生选中态：↑/↓ 移动的是「挂靠对象」本身——
    /// 在顶层目标之间切换，父目标高亮跟着走。这避免了「父目标高亮 + 选中条 + 回车
    /// 误勾掉别的目标」的三重混乱；挂靠中的回车本来就应该只负责创建子目标
    private func moveSelection(by delta: Int) {
        if let attachedID = model.inputParentID {
            let topLevelIDs = visibleRows.filter { $0.depth == 0 }.map(\.goal.id)
            guard let idx = topLevelIDs.firstIndex(of: attachedID) else { return }
            let next = max(0, min(topLevelIDs.count - 1, idx + delta))
            model.inputParentID = topLevelIDs[next]
            return
        }
        let ids = visibleRows.map(\.goal.id)
        guard !ids.isEmpty else { return }
        guard let current = model.selectedID, let idx = ids.firstIndex(of: current) else {
            model.selectedID = delta > 0 ? ids.first : ids.last
            return
        }
        let next = max(0, min(ids.count - 1, idx + delta))
        model.selectedID = ids[next]
    }
    /// AppDelegate 的 handleEscape 取消时长选择后，把焦点还给输入栏
    func returnFocusToInput() {
        focusedField = .input
    }

    /// AppDelegate 本地监听把 Tab/Shift+Tab 送到这里（onKeyPress 收不到 Shift+Tab——
    /// AppKit 焦点循环先吃掉）。守卫与原来一致：签到/配置面板/编辑中不处理。
    /// 这里吃掉 Tab 而不返回 .ignored 很关键：放行会掉进 AppKit 焦点循环，
    /// 把光标从输入框抢到旁边的表盘按钮上
    func handleTabRequest(shift: Bool) {
        guard model.animatedIn, model.pendingCheckInID == nil, !model.showSettings,
              model.editingID == nil else { return }
        handleTab(shift: shift)
    }

    /// Tab 覆盖两种输入，只允许两层（子目标不能当父）：
    /// 1. Shift+Tab = 退回顶层输入（清挂靠对象）
    /// 2. 输入框有字（或选中顶层目标）= 把待建的这条缩进为子目标，挂到那个顶层目标下面
    private func handleTab(shift: Bool) {
        if shift {
            model.inputParentID = nil
            return
        }
        // 有明确选中且是顶层目标：挂到那条——选中是用户明确指的对象
        if let selected = model.selectedID,
           let goal = store.goals.first(where: { $0.id == selected }),
           goal.parentID == nil {
            model.inputParentID = selected
            model.selectedID = nil
            return
        }
        // 没有可用选中、又已经在子目标模式里：只允许两层，没有更深的地方可去，不动
        guard model.inputParentID == nil else { return }
        if !model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let lastTopLevel = visibleRows.last(where: { $0.depth == 0 })?.goal.id {
            model.inputParentID = lastTopLevel
        }
    }
}
