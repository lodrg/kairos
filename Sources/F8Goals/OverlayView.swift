import SwiftUI

enum FocusField: Hashable {
    case input
    case edit(UUID)
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
    }

    private func switchCanvas(by delta: Int) {
        switchDirection = delta
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
    /// 高度全部由「行数 × 常量行高」算出，不测量任何子视图，
    /// 所以不存在「内容高度 → 布局 → 内容高度」的回路。
    private var content: some View {
        GeometryReader { geo in
            let bottomInset: CGFloat = 56
            let restingHeight = max(0, geo.size.height * Metrics.inputRestingFraction - Metrics.inputBarHeight / 2)
            let maxHeight = max(Metrics.rowHeight, geo.size.height - Metrics.inputBarHeight - bottomInset)
            let fitCount = max(1, Int(maxHeight / Metrics.rowHeight))

            let all = visibleGoals
            let shown = Array(all.suffix(fitCount))
            let overflowing = all.count > shown.count
            let listHeight = min(max(restingHeight, CGFloat(shown.count) * Metrics.rowHeight), maxHeight)
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

    /// 当前画布里未完成的目标 + 正在淡出的目标。按插入顺序，最新的贴着输入栏。
    /// 不按完成状态重排——重排会打乱行的身份，导致入场动画被重置、画面闪一下。
    private var visibleGoals: [Goal] {
        store.goals.filter { goal in
            guard goal.canvasID == store.activeCanvasID else { return false }
            if model.retiredIDs.contains(goal.id) { return false }
            if goal.isDone { return model.completingIDs.contains(goal.id) }
            return true
        }
    }

    /// 行不靠 VStack 自然重排，而是按「第几行 × 常量行高」显式定位。
    /// 交给 VStack 重排的话，位置变化没有对应的可绑定值，只能靠外层 withAnimation 的
    /// 环境事务；而行自己的 .animation(_:value:) 会把环境动画挡掉，结果就是瞬间跳位。
    ///
    /// 这里不设固定高度：`offset` 不参与布局，高度交给外层的 listHeight 决定，
    /// 免得容器边界在动画途中裁掉还没走到位的行。
    ///
    /// `.id(activeCanvasID)` 让整块内容在切画布时被当成全新的子树，配合 `.transition`
    /// 做交叉淡入 + 顺方向位移；不做横向滑动是因为滑动要求所有画布常驻视图树，
    /// 而各画布 listHeight 不同，输入框位置会打架。
    private func goalArea(shown: [Goal]) -> some View {
        Group {
            if shown.isEmpty {
                emptyHint
            } else {
                ZStack(alignment: .bottomLeading) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, goal in
                        GoalRow(
                            goal: goal,
                            indexFromBottom: shown.count - 1 - index,
                            revealed: model.animatedIn,
                            isCompleting: model.completingIDs.contains(goal.id),
                            isEditing: model.editingID == goal.id,
                            editText: $model.editText,
                            focusedField: $focusedField,
                            onToggle: { complete(goal) },
                            onBeginEdit: { beginEdit(goal) },
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

    private var inputBar: some View {
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
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(model.animatedIn ? 1 : 0)
        .animation(Motion.reveal, value: model.animatedIn)
    }

    // MARK: - 动作

    private func createGoal() {
        let text = model.inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(Motion.commit) { store.add(text) }
        model.inputText = ""
        focusedField = .input
    }

    private func beginEdit(_ goal: Goal) {
        // 已经在编辑别的目标时先落盘，否则那一条改了一半的内容会被静默丢掉
        if let current = model.editingID, current != goal.id {
            store.update(id: current, text: model.editText)
        }
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
}

// MARK: - 目标行

/// 入场、退场只有透明度变化；位置由 indexFromBottom 显式算出，自己动画。
/// 行内不存动画状态、不量 geometry——原来每行各自 @State + GeometryReader
/// 抓一次布局，抓到的是还没稳定的值，而且永不重算。
struct GoalRow: View {
    let goal: Goal
    /// 从下往上数第几行（0 = 紧贴输入栏那行）。别的目标消失后这个值会变，位置随之动画
    let indexFromBottom: Int
    let revealed: Bool
    let isCompleting: Bool
    let isEditing: Bool
    @Binding var editText: String
    var focusedField: FocusState<FocusField?>.Binding
    let onToggle: () -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void

    var body: some View {
        HStack(spacing: Metrics.gutter) {
            CheckBox(isDone: goal.isDone, action: onToggle)

            if isEditing {
                TextField("", text: $editText)
                    .font(.system(size: Metrics.goalFont, weight: .medium, design: .rounded))
                    .textFieldStyle(.plain)
                    .focused(focusedField, equals: .edit(goal.id))
                    .onSubmit(onCommitEdit)
                    .foregroundStyle(.white)
                    .tint(Palette.accent)
            } else {
                Text(goal.text)
                    .font(.system(size: Metrics.goalFont, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onBeginEdit)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: Metrics.rowHeight)
        .offset(y: -CGFloat(indexFromBottom) * Metrics.rowHeight)
        .opacity(isCompleting ? 0 : (revealed ? 1 : 0))
        .animation(Motion.layout, value: indexFromBottom)
        .animation(Motion.reveal, value: revealed)
        .animation(Motion.retire, value: isCompleting)
        // 新建的目标淡入，而不是直接冒出来
        .transition(.opacity)
    }
}

// MARK: - 勾选方块

struct CheckBox: View {
    let isDone: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isDone ? Palette.done : Color.white.opacity(0.05))
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isDone ? .clear : .white.opacity(0.4), lineWidth: 2)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: Metrics.boxSize * 0.52, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.75))
                }
            }
            .frame(width: Metrics.boxSize, height: Metrics.boxSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.fade, value: isDone)
    }
}
