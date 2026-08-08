import SwiftUI

enum FocusField: Hashable {
    case input
    case edit(UUID)
}

struct OverlayView: View {
    @ObservedObject var store: GoalStore
    @ObservedObject var model: OverlayModel
    @FocusState private var focusedField: FocusField?

    private let accent = Color(red: 0.45, green: 0.65, blue: 1.0)
    private let doneGreen = Color(red: 0.30, green: 0.85, blue: 0.60)
    /// 目标列表与输入栏之间的间距
    private let inputGap: CGFloat = 36

    @State private var windowHeight: CGFloat = 900
    /// 输入栏上方的内容（目标列表或空状态）高度
    @State private var aboveInputHeight: CGFloat = 0
    /// 输入栏本体高度（不含与列表的间距）
    @State private var inputBarHeight: CGFloat = 70
    /// 输入栏中线位置（overlay 坐标系），文字生长动画的起点
    @State private var inputMidY: CGFloat = 600

    var body: some View {
        ZStack {
            background
            mainContent
        }
        .coordinateSpace(name: "overlay")
        .background(GeometryReader { geo in
            Color.clear.onAppear { windowHeight = geo.size.height }
        })
        .onChange(of: model.animatedIn) { newValue in
            if newValue { focusedField = .input }
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.028, green: 0.045, blue: 0.11),
                    Color(red: 0.075, green: 0.05, blue: 0.22),
                    Color(red: 0.11, green: 0.045, blue: 0.19),
                    Color(red: 0.028, green: 0.045, blue: 0.11)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.white.opacity(0.05), .clear],
                center: .top, startRadius: 0, endRadius: 700
            )
        }
        .ignoresSafeArea()
    }

    /// 显示用列表: 已勾选的排最上面（淡出），未勾选旧的在上下面的新的在下
    private var visibleGoals: [Goal] {
        store.goals
            .filter { goal in
                if model.hiddenDoneIDs.contains(goal.id) { return false }
                if goal.isDone {
                    let elapsed = Date().timeIntervalSince(goal.completedAt ?? .distantPast)
                    return elapsed < 2.2 // 只保留淡出窗口内的已勾选目标
                }
                return true
            }
            .sorted { a, b in
                if a.isDone != b.isDone { return a.isDone }
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.id.uuidString < b.id.uuidString
            }
    }

    /// 输入栏保持在屏幕正中: 上方内容变高时顶距自动缩小；
    /// 顶距触底后输入栏随内容往下移（上半屏被填满后）
    private var topSpace: CGFloat {
        max(40, windowHeight / 2 - aboveInputHeight - inputGap - inputBarHeight / 2)
    }

    private var bottomSpace: CGFloat {
        max(48, windowHeight - topSpace - aboveInputHeight - inputGap - inputBarHeight)
    }

    private var mainContent: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: topSpace)

                    Group {
                        if visibleGoals.isEmpty {
                            EmptyStateView(animatedIn: model.animatedIn)
                        } else {
                            goalList
                        }
                    }
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { aboveInputHeight = geo.size.height }
                            .onChange(of: geo.size.height) { aboveInputHeight = $0 }
                    })

                    InputBarView(
                        animatedIn: model.animatedIn,
                        inputText: $model.inputText,
                        focusedField: $focusedField,
                        accent: accent,
                        onSubmit: { createGoal() }
                    )
                    .background(GeometryReader { geo in
                        Color.clear.onAppear {
                            let f = geo.frame(in: .named("overlay"))
                            inputMidY = f.midY
                            inputBarHeight = f.height
                        }
                    })
                    .padding(.top, inputGap)
                    .id("input")

                    Color.clear.frame(height: bottomSpace)
                }
                // X 轴: 内容收进居中的内容列（两侧留白），不再贴屏幕左缘
                .frame(maxWidth: 1400)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: store.goals.count) { _ in
                // 列表变长后把输入栏保持在可见位置
                withAnimation { proxy.scrollTo("input", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var goalList: some View {
        LazyVStack(spacing: 4) {
            ForEach(Array(visibleGoals.enumerated()), id: \.element.id) { index, goal in
                GoalRow(
                    goal: goal,
                    staggerIndex: visibleGoals.count - 1 - index, // 新的(下面)先出现
                    inputMidY: inputMidY,
                    store: store,
                    model: model,
                    focusedField: $focusedField,
                    accent: accent,
                    doneGreen: doneGreen
                )
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - 动作

    private func createGoal() {
        let text = model.inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            store.add(text)
        }
        model.inputText = ""
        focusedField = .input
    }
}

// MARK: - 目标行（从输入栏位置向上生长到自己的位置）

struct GoalRow: View {
    let goal: Goal
    let staggerIndex: Int
    let inputMidY: CGFloat
    @ObservedObject var store: GoalStore
    @ObservedObject var model: OverlayModel
    var focusedField: FocusState<FocusField?>.Binding
    let accent: Color
    let doneGreen: Color

    /// 文字动效: 从输入栏的文字位置出发，向上生长到列表位置
    @State private var entered = false
    @State private var entranceOffset: CGFloat = 80

    var body: some View {
        HStack(spacing: 32) {
            CheckBox(isDone: goal.isDone, accent: doneGreen) {
                toggleGoal()
            }

            if model.editingID == goal.id {
                TextField("", text: $model.editText)
                    .font(.system(size: 56, weight: .medium, design: .rounded))
                    .textFieldStyle(.plain)
                    .focused(focusedField, equals: .edit(goal.id))
                    .onSubmit(commitEdit)
                    .foregroundStyle(.white)
                    .tint(accent)
            } else {
                Text(goal.text)
                    .font(.system(size: 56, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .contentShape(Rectangle())
                    .onTapGesture { startEdit() }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .opacity(goal.isDone && model.fadingDoneIDs.contains(goal.id) ? 0 : 1)
        .background(GeometryReader { geo in
            Color.clear.onAppear {
                let f = geo.frame(in: .named("overlay"))
                entranceOffset = inputMidY - f.midY // 起点 = 输入栏位置
            }
        })
        .offset(y: entered ? 0 : entranceOffset)
        .scaleEffect(entered ? 1.0 : 0.4, anchor: .bottom)
        .opacity(entered ? 1 : 0)
        .onAppear {
            if model.animatedIn { animateIn() } // 新建目标时立即播放
        }
        .onChange(of: model.animatedIn) { newValue in
            if newValue {
                animateIn() // 每次呼出重新播放文字生长
            } else {
                entered = false // 收起时静默复位
            }
        }
    }

    private func animateIn() {
        withAnimation(.easeOut(duration: 0.55).delay(Double(staggerIndex) * 0.07)) {
            entered = true
        }
    }

    private func toggleGoal() {
        if goal.isDone {
            withAnimation(.easeInOut(duration: 0.4)) {
                store.toggle(goal.id)
                model.fadingDoneIDs.remove(goal.id)
                model.hiddenDoneIDs.remove(goal.id)
            }
        } else {
            withAnimation(.easeInOut(duration: 0.6)) {
                store.toggle(goal.id)
            }
            withAnimation(.easeIn(duration: 2.0)) {
                _ = model.fadingDoneIDs.insert(goal.id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak model] in
                guard let model, model.fadingDoneIDs.contains(goal.id) else { return }
                withAnimation(.easeIn(duration: 0.2)) {
                    _ = model.hiddenDoneIDs.insert(goal.id)
                }
            }
        }
    }

    private func startEdit() {
        model.editingID = goal.id
        model.editText = goal.text
        focusedField.wrappedValue = .edit(goal.id)
    }

    private func commitEdit() {
        guard let id = model.editingID else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            store.update(id: id, text: model.editText)
        }
        model.editingID = nil
        focusedField.wrappedValue = .input
    }
}

// MARK: - 空状态（文字生长）

struct EmptyStateView: View {
    let animatedIn: Bool
    @State private var entered = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "target")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.22))
            Text("还没有目标")
                .font(.system(size: 52, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.32))
            Text("直接打字，回车创建第一个目标")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.25))
        }
        .padding(.bottom, 40)
        .scaleEffect(entered ? 1.0 : 0.6)
        .opacity(entered ? 1 : 0)
        .onAppear { if animatedIn { enter() } }
        .onChange(of: animatedIn) { newValue in
            if newValue { enter() } else { entered = false }
        }
    }

    private func enter() {
        withAnimation(.easeOut(duration: 0.55).delay(0.1)) { entered = true }
    }
}

// MARK: - 输入栏（淡入 + 轻微生长）

struct InputBarView: View {
    let animatedIn: Bool
    @Binding var inputText: String
    var focusedField: FocusState<FocusField?>.Binding
    let accent: Color
    let onSubmit: () -> Void

    @State private var entered = false

    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(accent)
            TextField("输入新目标，回车创建", text: $inputText)
                .font(.system(size: 52, weight: .medium, design: .rounded))
                .textFieldStyle(.plain)
                .focused(focusedField, equals: .input)
                .onSubmit(onSubmit)
                .foregroundStyle(.white)
                .tint(accent)
        }
        .scaleEffect(entered ? 1.0 : 0.85)
        .opacity(entered ? 1 : 0)
        .onAppear { if animatedIn { enter() } }
        .onChange(of: animatedIn) { newValue in
            if newValue { enter() } else { entered = false }
        }
    }

    private func enter() {
        withAnimation(.easeOut(duration: 0.45).delay(0.12)) { entered = true }
    }
}

// MARK: - 大号勾选方块

struct CheckBox: View {
    let isDone: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isDone ? accent : Color.white.opacity(0.07))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isDone ? Color.clear : Color.white.opacity(0.55), lineWidth: 3)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.8))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDone)
    }
}
