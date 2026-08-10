import SwiftUI

/// 强制签到卡片：到期目标 + 反馈输入框 + 四个动作，键盘（字母/数字）和点击都能触发。
/// 没有关闭按钮——退路是 Snooze 和菜单栏 Quit，不是「点旁边空白处消失」。
///
/// 键盘分工：
/// - 反馈输入框没聚焦时，D/K/S/X 或 1/2/3/4 直接触发动作（AppDelegate 本地监听）
/// - 点击（或 Tab）聚焦输入框后，字母数字是文字输入，快捷键自动让位；
///   在输入框里按回车 = 提交反馈并结束
struct CheckInView: View {
    let goal: Goal
    let l10n: L10n
    @Binding var feedbackText: String
    @Binding var feedbackFocused: Bool
    let onSubmitFeedback: () -> Void
    let onEnd: () -> Void
    let onKeepGoing: () -> Void
    let onSnooze: () -> Void
    let onDrop: () -> Void

    @FocusState private var feedbackFieldFocused: Bool

    var body: some View {
        VStack(spacing: 26) {
            Text(l10n.timeIsUp)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))

            Text(goal.text)
                .font(.system(size: 50, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            if let count = goal.timer?.snoozeCount, count > 0 {
                Text(count == 1 ? l10n.snoozedOnce : l10n.snoozedCount(count))
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }

            // 反馈输入框：回车 = 提交反馈并结束
            TextField(l10n.feedbackPlaceholder, text: $feedbackText)
                .font(.system(size: 18, weight: .regular, design: .rounded))
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .tint(Palette.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
                .focused($feedbackFieldFocused)
                .onSubmit(onSubmitFeedback)
                .onChange(of: feedbackFieldFocused) { _, newValue in
                    feedbackFocused = newValue
                }

            Text(l10n.feedbackHint)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.3))

            HStack(spacing: 22) {
                action(l10n.end, key: "D/1", tint: Palette.done, perform: onEnd)
                action(l10n.keepGoing, key: "K/2", tint: Palette.accent, perform: onKeepGoing)
                action(l10n.snooze, key: "S/3", tint: .white.opacity(0.6), perform: onSnooze)
                action(l10n.drop, key: "X/4", tint: .white.opacity(0.45), perform: onDrop)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 40)
        .frame(maxWidth: 720)
    }

    private func action(_ label: String, key: String, tint: Color, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 11) {
                Text(key)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 30)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(label)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
        .buttonStyle(.plain)
    }
}
