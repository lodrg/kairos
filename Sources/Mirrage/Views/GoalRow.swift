import SwiftUI

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
    /// 高亮父目标：正在编辑的子目标的父，或输入栏正挂靠着的父（输入子目标时）
    let isParentHighlighted: Bool
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
                    // 选中行文字更亮——键盘操作时当前行的存在感要能一眼确认，
                    // 跟左侧竖线双信号，比单靠一根细线稳
                    .foregroundStyle(isParentHighlighted
                        ? Palette.accent.opacity(0.9)
                        : .white.opacity(depth == 0 ? (isSelected ? 1.0 : 0.92) : (isSelected ? 0.85 : 0.72)))
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
        // 选中标记：左边距里一道细竖线，不是描边框——避免整行套一个明显的框体。
        // 父目标高亮复用同一条竖线（编辑子目标 / 输入子目标时亮起）
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Palette.accent.opacity(isParentHighlighted ? 0.5 : 0.6))
                .frame(width: 3, height: rowHeight * 0.4)
                .padding(.leading, 6)
                .opacity(isSelected || isParentHighlighted ? 1 : 0)
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
            let urgent = remaining > 0 && remaining < 60
            let expired = remaining <= 0
            HStack(spacing: 5) {
                Image(systemName: "timer")
                    .font(.system(size: compact ? 10 : 13, weight: .medium))
                Text(format(remaining))
                    .font(.system(size: compact ? 11 : 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            // 三态：正常=低调白字；最后一分钟=主题色+淡色描边（提醒来了）；
            // 已到期=实心主题色底黑字（透明模式下签到不弹，这个就是最醒目的信号）
            .foregroundStyle(expired ? .black.opacity(0.85) : (urgent ? Palette.accent : .white.opacity(0.6)))
            .padding(.horizontal, 10)
            .padding(.vertical, compact ? 3 : 5)
            .background {
                Capsule().fill(expired ? Palette.accent : (urgent ? Palette.accent.opacity(0.14) : Color.white.opacity(0.07)))
            }
            .overlay {
                if urgent {
                    Capsule().strokeBorder(Palette.accent.opacity(0.45), lineWidth: 1)
                }
            }
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
