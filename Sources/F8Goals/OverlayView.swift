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
    var height: CGFloat { depth == 0 ? Metrics.rowHeight : Metrics.subRowHeight }
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
    @FocusState private var focusedField: FocusField?

    /// 切画布时的行进方向（+1 下一个 / -1 上一个），决定交叉淡入的偏移朝向
    @State private var switchDirection: Int = 1
    /// 画布名的临时提示：切换时淡入，停一下后淡出
    @State private var showCanvasName = false
    @State private var nameFlashTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            AuroraBackground(active: model.animatedIn)
                .hueRotation(.degrees(store.activeCanvas.hueShift))
                .animation(Motion.canvasSwitch, value: store.activeCanvasID)
            content
            canvasNameFlash
        }
        .onChange(of: model.animatedIn) { _, isIn in
            if isIn { focusedField = .input }
        }
        .onChange(of: model.editingID) { _, editing in
            // 编辑结束（保存或 Esc 取消）后焦点必须交回输入栏，
            // 否则 @FocusState 还指向已经消失的 .edit(id)，键盘输入无处可去
            if editing == nil, model.animatedIn { focusedField = .input }
        }
        // 方向键切画布，但只在输入框为空、且不在编辑任何目标时拦截——
        // 已验证：即使 onKeyPress 挂在这个远离 TextField 的外层容器上，方向键事件依然会
        // 冒泡到这里；返回 .ignored 时正常交回给 TextField 移动光标，不影响输入
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard model.animatedIn, model.inputText.isEmpty, model.editingID == nil,
                  store.canvases.count > 1 else { return .ignored }
            switchCanvas(by: press.key == .rightArrow ? 1 : -1)
            return .handled
        }
        // 上下键移动选中行，同样只在输入框为空、不在编辑时拦截
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard model.animatedIn, model.inputText.isEmpty, model.editingID == nil else { return .ignored }
            moveSelection(by: press.key == .downArrow ? 1 : -1)
            return .handled
        }
        // Tab 双向覆盖两种输入：输入框有字时缩进待建的这条；选中已有目标时把它拆成几条。
        // 已验证 Shift+Tab 到这里是同一个 .tab，只是 modifiers 带 .shift，不是别的键
        .onKeyPress(keys: [.tab]) { press in
            guard model.animatedIn, model.editingID == nil else { return .ignored }
            return handleTab(shift: press.modifiers.contains(.shift)) ? .handled : .ignored
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

    /// 目标少时输入栏停在 `Metrics.inputRestingFraction` 那个高度；目标堆到要越过上缘时，
    /// 列表区继续往下长、输入栏跟着下沉；沉到离底部还剩 bottomInset 就停住，
    /// 再多的目标从顶部渐隐让位。
    ///
    /// 高度全部由「行高常量 × 行数」累加算出，不测量任何子视图，
    /// 所以不存在「内容高度 → 布局 → 内容高度」的回路。子目标行更矮，
    /// 所以是累加每行各自的高度，不是简单的「行数 × 单一行高」。
    private var content: some View {
        GeometryReader { geo in
            let bottomInset: CGFloat = 56
            let restingHeight = max(0, geo.size.height * Metrics.inputRestingFraction - Metrics.inputBarHeight / 2)
            let maxHeight = max(Metrics.rowHeight, geo.size.height - Metrics.inputBarHeight - bottomInset)

            let (shown, overflowing) = trimToFit(visibleRows, maxHeight: maxHeight)
            let rowsHeight = shown.reduce(CGFloat(0)) { $0 + $1.height }
            let listHeight = min(max(restingHeight, rowsHeight), maxHeight)
            let area = goalArea(shown: shown).frame(height: listHeight, alignment: .bottom)

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
                    .frame(height: Metrics.inputBarHeight)

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
    private func trimToFit(_ rows: [GoalRowInfo], maxHeight: CGFloat) -> (shown: [GoalRowInfo], overflowing: Bool) {
        guard !rows.isEmpty else { return ([], false) }
        var total: CGFloat = 0
        var cutIndex = rows.count
        for i in stride(from: rows.count - 1, through: 0, by: -1) {
            let h = rows[i].height
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
    private func goalArea(shown: [GoalRowInfo]) -> some View {
        Group {
            if shown.isEmpty {
                emptyHint
            } else {
                ZStack(alignment: .bottomLeading) {
                    ForEach(layout(shown), id: \.id) { placed in
                        GoalRow(
                            goal: placed.info.goal,
                            depth: placed.info.depth,
                            offsetFromBottom: placed.offset,
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
    private func layout(_ shown: [GoalRowInfo]) -> [PlacedRow] {
        var offset: CGFloat = 0
        var placed: [PlacedRow] = []
        for info in shown.reversed() {
            placed.append(PlacedRow(info: info, offset: offset))
            offset += info.height
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
        Text("No goals yet")
            .font(.system(size: 26, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.16))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 26)
            .opacity(model.animatedIn ? 1 : 0)
            .animation(Motion.reveal, value: model.animatedIn)
    }

    /// 固定切两段：上面 26pt 是「正在给谁加子目标」的提示位，不管显不显示都占着；
    /// 下面 inputBarHeight-26 是真正的输入行，在这段里居中——这样输入行的竖直位置
    /// 永远不变，不会因为提示行的显隐而上下窜动
    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(parentContextLabel)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.32))
                .lineLimit(1)
                .frame(height: 26, alignment: .bottom)
                .padding(.leading, Metrics.subIndent)
                .opacity(model.inputParentID != nil ? 1 : 0)

            HStack(spacing: Metrics.gutter) {
                Image(systemName: "plus")
                    .font(.system(size: Metrics.boxSize * 0.6, weight: .light))
                    .foregroundStyle(.white.opacity(0.24))
                    .frame(width: Metrics.boxSize, alignment: .center)

                TextField("", text: $model.inputText)
                    .font(.system(size: Metrics.inputFont, weight: .medium, design: .rounded))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .input)
                    .onSubmit(createGoal)
                    .foregroundStyle(.white)
                    .tint(Palette.accent)
                    // 自己画 placeholder：TextField 内建的那个改不了透明度
                    .overlay(alignment: .leading) {
                        if model.inputText.isEmpty {
                            Text("New goal")
                                .font(.system(size: Metrics.inputFont, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.15))
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(.leading, model.inputParentID != nil ? Metrics.subIndent : 0)
            .frame(height: Metrics.inputBarHeight - 26, alignment: .center)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Metrics.inputBarHeight)
        .opacity(model.animatedIn ? 1 : 0)
        .animation(Motion.reveal, value: model.animatedIn)
        .animation(Motion.commit, value: model.inputParentID)
    }

    private var parentContextLabel: String {
        guard let id = model.inputParentID else { return "" }
        return store.goals.first(where: { $0.id == id })?.text ?? ""
    }

    // MARK: - 动作

    private func createGoal() {
        let text = model.inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(Motion.commit) { store.add(text, parentID: model.inputParentID) }
        model.inputText = ""
        focusedField = .input
        // inputParentID 故意不清——连续回车能逐条加子目标，直到 Shift+Tab / Esc 主动退回顶层
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

    /// 上下键在当前可见行里移动选中项；没有选中时，向下从紧贴输入栏的那行开始，
    /// 向上从最旧的那行开始。到头不环绕——目标列表有明确的首尾，不是画布那种环
    private func moveSelection(by delta: Int) {
        let ids = visibleRows.map(\.goal.id)
        guard !ids.isEmpty else { return }
        guard let current = model.selectedID, let idx = ids.firstIndex(of: current) else {
            model.selectedID = delta > 0 ? ids.last : ids.first
            return
        }
        let next = max(0, min(ids.count - 1, idx + delta))
        model.selectedID = ids[next]
    }

    /// Tab 双向覆盖两种输入：输入框有字时缩进待建的这条；选中已有目标时把它拆成几条。
    /// 选中优先于「最后一条顶层目标」，因为选中是用户明确指的对象
    private func handleTab(shift: Bool) -> Bool {
        if shift {
            guard model.inputParentID != nil else { return false }
            model.inputParentID = nil
            return true
        }
        if let selected = model.selectedID {
            model.inputParentID = selected
            model.selectedID = nil
            return true
        }
        if !model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let lastTopLevel = visibleRows.last(where: { $0.depth == 0 })?.goal.id {
            model.inputParentID = lastTopLevel
            return true
        }
        return false
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
    let revealed: Bool
    let isCompleting: Bool
    let isEditing: Bool
    let isSelected: Bool
    @Binding var editText: String
    var focusedField: FocusState<FocusField?>.Binding
    let onToggle: () -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void

    private var rowHeight: CGFloat { depth == 0 ? Metrics.rowHeight : Metrics.subRowHeight }
    private var boxSize: CGFloat { depth == 0 ? Metrics.boxSize : Metrics.subBoxSize }
    private var font: CGFloat { depth == 0 ? Metrics.goalFont : Metrics.subGoalFont }

    var body: some View {
        HStack(spacing: Metrics.gutter) {
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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.leading, depth == 0 ? 0 : Metrics.subIndent)
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
        .animation(Motion.fade, value: isDone)
    }
}
