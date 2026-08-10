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

    /// 时长预设，Off 恒在最前面，后面接配置里可编辑的分钟数列表
    private var durationOptions: [Int?] {
        [nil] + settingsStore.settings.durationPresetsMinutes
    }

    /// 配置面板里「输入栏位置」「文字大小」两个滑块解析出来的实际尺寸；
    /// 一个整体缩放系数而不是逐个常量独立可调，见 LayoutMetrics 的注释
    private var sizing: LayoutMetrics {
        LayoutMetrics(scale: settingsStore.settings.textScale, restingFraction: settingsStore.settings.inputRestingFraction)
    }

    /// 有没有全屏接管画面的东西开着（签到或配置面板）
    private var isModalUp: Bool {
        model.pendingCheckInID != nil || model.showSettings
    }

    private var l10n: L10n { L10n(language: settingsStore.settings.language) }

    var body: some View {
        ZStack {
            AuroraBackground(
                active: model.animatedIn,
                breathingEnabled: settingsStore.settings.breathingEnabled,
                meshEnabled: settingsStore.settings.auroraEnabled
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
            checkInOverlay
        }
        .onChange(of: model.animatedIn) { _, isIn in
            if isIn {
                focusedField = .input
                // 自动武装：呼出时如果配置了「新目标自动武装」且当前没有别的武装状态，直接挂上默认时长
                if settingsStore.settings.autoArmNewGoals, model.armedMinutes == nil {
                    model.armedMinutes = settingsStore.settings.defaultMinutes
                }
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
        // 方向键切画布，但只在输入框为空、不在编辑、没有签到弹出、也没在选时长时拦截——
        // 已验证：即使 onKeyPress 挂在这个远离 TextField 的外层容器上，方向键事件依然会
        // 冒泡到这里；返回 .ignored 时正常交回给 TextField 移动光标，不影响输入
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
        // Tab 一律吃掉，绝不返回 .ignored——放行的话会掉进 AppKit 的焦点循环，
        // 把光标从输入框抢到旁边的表盘按钮上，于是既打不了字、按空格还会误触计时器。
        // 已实测：Button 默认可聚焦 + 返回 .ignored，Tab 之后 firstResponder 就变成
        // KeyViewProxy 而不再是输入框。配置面板开着时例外，放行让表单里的 Tab 正常跳字段。
        .onKeyPress(keys: [.tab]) { press in
            guard model.animatedIn, model.pendingCheckInID == nil, !model.showSettings else { return .ignored }
            if model.editingID == nil {
                handleTab(shift: press.modifiers.contains(.shift))
            }
            return .handled
        }
        // 签到卡片的四个动作：字母和数字任选一种，签到没弹出时完全不拦截任何键
        .onKeyPress { press in
            guard let id = model.pendingCheckInID else { return .ignored }
            switch press.characters.lowercased() {
            case "d", "1": resolveCheckIn(id: id, action: .done)
            case "k", "2": resolveCheckIn(id: id, action: .keepGoing)
            case "s", "3": resolveCheckIn(id: id, action: .snooze)
            case "x", "4": resolveCheckIn(id: id, action: .drop)
            default: return .ignored
            }
            return .handled
        }
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

    private var settingsOverlay: some View {
        Group {
            if model.showSettings {
                SettingsPanel(settingsStore: settingsStore, store: store, onClose: { model.showSettings = false })
                    .transition(.opacity)
            }
        }
        .animation(Motion.reveal, value: model.showSettings)
    }

    // MARK: - 强制签到

    enum CheckInAction { case done, keepGoing, snooze, drop }

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
                        onDone: { resolveCheckIn(id: id, action: .done) },
                        onKeepGoing: { resolveCheckIn(id: id, action: .keepGoing) },
                        onSnooze: { resolveCheckIn(id: id, action: .snooze) },
                        onDrop: { resolveCheckIn(id: id, action: .drop) }
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
        // 先清掉签到态再执行动作：卡片立即开始淡出，且 complete(goal) 不会因为
        // 「签到还未决」被挡住（它本身没设这个 guard，但顺序对了就不用纠结这件事）
        model.pendingCheckInID = nil
        switch action {
        case .done:
            complete(goal)
        case .keepGoing:
            if let minutes = goal.timer?.minutes {
                store.setTimer(goalID: id, minutes: minutes)
            }
        case .snooze:
            store.snoozeTimer(goalID: id, minutes: settingsStore.settings.snoozeMinutes)
        case .drop:
            store.update(id: id, text: "")
        }
        focusedField = .input
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
    /// 不管它们在 store.goals 数组里实际的先后顺序（数组是按创建时间追加的）
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

    /// 固定切两段：上面 26pt 是「正在给谁加子目标 / 正在选时长」的提示位，不管显不显示
    /// 都占着；下面 inputBarHeight-26 是真正的输入行，在这段里居中——这样输入行的竖直
    /// 位置永远不变，不会因为提示行的显隐而上下窜动
    private var inputBar: some View {
        let sizing = sizing
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if model.isChoosingDuration {
                    durationPicker
                } else {
                    Text(parentContextLabel)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.32))
                        .lineLimit(1)
                        .padding(.leading, sizing.subIndent)
                        .opacity(model.inputParentID != nil ? 1 : 0)
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

    private var parentContextLabel: String {
        guard let id = model.inputParentID else { return "" }
        return store.goals.first(where: { $0.id == id })?.text ?? ""
    }

    /// 时长预设一排小方块，当前选中高亮；左右键在 body 里的 onKeyPress 处理
    private var durationPicker: some View {
        HStack(spacing: 8) {
            ForEach(Array(durationOptions.enumerated()), id: \.offset) { index, minutes in
                let active = index == model.draftMinutesIndex
                Text(minutes.map { "\($0)m" } ?? l10n.durationOff)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(active ? .black.opacity(0.85) : .white.opacity(0.4))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(active ? Palette.accent : Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .transition(.opacity)
    }

    /// 输入栏右侧那个「方便的开启按钮」：没武装时是暗淡的表盘图标，武装后亮起并显示分钟数。
    /// 点它或 ⌘T 都能开合时长选择——⌘T 走 SwiftUI 的 keyboardShortcut，不需要
    /// 像方向键那样操心是否会被聚焦中的 TextField 抢掉，这是更常规、有文档保证的机制
    private var armIndicator: some View {
        Button(action: toggleArming) {
            HStack(spacing: 5) {
                Image(systemName: model.armedMinutes == nil ? "timer" : "timer.circle.fill")
                    .font(.system(size: 17))
                if let minutes = model.armedMinutes {
                    Text("\(minutes)m")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                }
            }
            .foregroundStyle(model.armedMinutes == nil ? .white.opacity(0.22) : Palette.accent)
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
            return
        }
        let text = model.inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(Motion.commit) {
            store.add(text, parentID: model.inputParentID, minutes: model.armedMinutes)
        }
        model.inputText = ""
        focusedField = .input
        // inputParentID 故意不清——连续回车能逐条加子目标，直到 Shift+Tab / Esc 主动退回顶层。
        // armedMinutes 是否保留由「创建后是否保持武装」这个配置项决定，默认不保留
        if !settingsStore.settings.keepArmedAfterCreate {
            model.armedMinutes = nil
        }
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
            model.draftMinutesIndex = durationOptions.firstIndex(of: model.armedMinutes)
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
        model.selectedID = goal.id
        if goal.isDone {
            model.completingIDs.remove(goal.id)
            model.retiredIDs.remove(goal.id)
            withAnimation(Motion.commit) { store.toggle(goal.id) }
            return
        }

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

    /// 上下键在当前可见行里移动选中项。可见行按「旧→新」排列（上面旧、下面新），
    /// 输入栏在列表下方——所以从输入栏按 ↑ 应该先碰到紧贴输入栏的那条（= 列表最后一条，
    /// 最新），再继续往上走；按 ↓ 则从最上面（最旧）那条开始。之前把方向搞反了。
    private func moveSelection(by delta: Int) {
        let ids = visibleRows.map(\.goal.id)
        guard !ids.isEmpty else { return }
        guard let current = model.selectedID, let idx = ids.firstIndex(of: current) else {
            model.selectedID = delta > 0 ? ids.first : ids.last
            return
        }
        let next = max(0, min(ids.count - 1, idx + delta))
        model.selectedID = ids[next]
    }

    /// Tab 双向覆盖两种输入：输入框有字时缩进待建的这条；选中已有目标时把它拆成几条。
    /// Shift+Tab 退回顶层。已验证 Shift+Tab 到这里是同一个 .tab，只是 modifiers 带 .shift。
    /// 选中优先于「最后一条顶层目标」，因为选中是用户明确指的对象
    private func handleTab(shift: Bool) {
        if shift {
            model.inputParentID = nil
            return
        }
        // 有明确选中就挂到那条，哪怕当前已经在给别的目标加子目标——选中是用户明确指的对象
        if let selected = model.selectedID {
            model.inputParentID = selected
            model.selectedID = nil
            return
        }
        // 没有选中、又已经在子目标模式里：只允许一层嵌套，没有更深的地方可去，不动。
        // 之前这里会悄悄换成「最后一条顶层目标」，等于偷偷改了父目标
        guard model.inputParentID == nil else { return }
        if !model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let lastTopLevel = visibleRows.last(where: { $0.depth == 0 })?.goal.id {
            model.inputParentID = lastTopLevel
        }
    }
}

// MARK: - 目标行

/// 入场、退场只有透明度变化；位置由 offsetFromBottom 显式算出，自己动画。
/// 行内不存动画状态、不量 geometry——原来每行各自 @State + GeometryReader
/// 抓一次布局，抓到的是还没稳定的值，而且永不重算。
struct GoalRow: View {
    let goal: Goal
    /// 0 顶层 / 1 子目标
    let depth: Int
    /// 到列表底部的距离（累加高度算出）。别的行消失/出现后这个值会变，位置随之动画
    let offsetFromBottom: CGFloat
    let sizing: LayoutMetrics
    let revealed: Bool
    let isCompleting: Bool
    let isEditing: Bool
    let isSelected: Bool
    @Binding var editText: String
    var focusedField: FocusState<FocusField?>.Binding
    let onToggle: () -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void

    private var rowHeight: CGFloat { depth == 0 ? sizing.rowHeight : sizing.subRowHeight }
    private var boxSize: CGFloat { depth == 0 ? sizing.boxSize : sizing.subBoxSize }
    private var font: CGFloat { depth == 0 ? sizing.goalFont : sizing.subGoalFont }

    var body: some View {
        HStack(spacing: sizing.gutter) {
            CheckBox(isDone: goal.isDone, size: boxSize, action: onToggle)

            if isEditing {
                TextField("", text: $editText)
                    .font(.system(size: font, weight: .medium, design: .rounded))
                    .textFieldStyle(.plain)
                    .focused(focusedField, equals: .edit(goal.id))
                    .onSubmit(onCommitEdit)
                    .foregroundStyle(.white)
                    .tint(Palette.accent)
            } else {
                Text(goal.text)
                    .font(.system(size: font, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(depth == 0 ? 0.92 : 0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onBeginEdit)
            }

            // 挂了倒计时的目标：右侧一个小徽章，显示剩余时间，每秒跳动
            if let timer = goal.timer {
                CountdownBadge(firesAt: timer.firesAt, revealed: revealed, compact: depth == 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.leading, depth == 0 ? 0 : sizing.subIndent)
        .frame(height: rowHeight)
        // 选中标记：左边距里一道细竖线，不是描边框——避免整行套一个明显的框体
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Palette.accent.opacity(0.6))
                .frame(width: 3, height: rowHeight * 0.4)
                .padding(.leading, 6)
                .opacity(isSelected ? 1 : 0)
        }
        .offset(y: -offsetFromBottom)
        .opacity(isCompleting ? 0 : (revealed ? 1 : 0))
        .animation(Motion.layout, value: offsetFromBottom)
        .animation(Motion.reveal, value: revealed)
        .animation(Motion.retire, value: isCompleting)
        .animation(Motion.fade, value: isSelected)
        // 新建的目标淡入，而不是直接冒出来
        .transition(.opacity)
    }
}

// MARK: - 倒计时徽章

/// 挂在带计时器目标行右侧的小徽章：timer 图标 + 剩余 mm:ss，每秒跳动。
/// 用 TimelineView(.animation(minimumInterval: 1))——覆盖层不可见时（revealed=false）
/// 随暂停条件一起停，不为每个目标各挂一个 Timer。
struct CountdownBadge: View {
    let firesAt: Date
    let revealed: Bool
    /// 子目标行的更小一号
    var compact = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0, paused: !revealed)) { timeline in
            let remaining = firesAt.timeIntervalSince(timeline.date)
            HStack(spacing: 5) {
                Image(systemName: "timer")
                    .font(.system(size: compact ? 10 : 13, weight: .medium))
                Text(format(remaining))
                    .font(.system(size: compact ? 11 : 15, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(remaining > 0 ? Color.white.opacity(0.55) : Palette.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, compact ? 3 : 5)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .contentShape(Capsule())
            .allowsHitTesting(false)
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 勾选方块

struct CheckBox: View {
    let isDone: Bool
    var size: CGFloat = Metrics.boxSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                    .fill(isDone ? Palette.done : Color.white.opacity(0.05))
                RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                    .strokeBorder(isDone ? .clear : .white.opacity(0.4), lineWidth: 2)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.52, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.75))
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 同理不进 Tab 焦点循环：键盘操作走上下键选中，方块是给鼠标点的
        .focusable(false)
        .animation(Motion.fade, value: isDone)
    }
}
