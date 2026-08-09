import SwiftUI

/// 强制签到卡片：到期目标 + 四个动作，键盘（字母或数字）和点击都能触发。
/// 没有关闭按钮——退路是 Snooze 和菜单栏 Quit，不是「点旁边空白处消失」。
struct CheckInView: View {
    let goal: Goal
    let onDone: () -> Void
    let onKeepGoing: () -> Void
    let onSnooze: () -> Void
    let onDrop: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Text("Time's up")
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))

            Text(goal.text)
                .font(.system(size: 42, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            if let count = goal.timer?.snoozeCount, count > 0 {
                Text(count == 1 ? "Snoozed once" : "Snoozed \(count) times")
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.28))
            }

            HStack(spacing: 16) {
                action("Done", key: "D", tint: Palette.done, perform: onDone)
                action("Keep going", key: "K", tint: Palette.accent, perform: onKeepGoing)
                action("Snooze", key: "S", tint: .white.opacity(0.55), perform: onSnooze)
                action("Drop", key: "X", tint: .white.opacity(0.4), perform: onDrop)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 44)
        .frame(maxWidth: 640)
    }

    private func action(_ label: String, key: String, tint: Color, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 9) {
                Text(key)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(label)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
    }
}
