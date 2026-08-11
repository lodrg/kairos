import SwiftUI

/// 强制签到卡片：到期目标 + 多行反馈输入框。键盘动作：
/// - ⌘+回车 = 保存反馈并结束目标（AppDelegate 本地监听处理，见 installKeyMonitor）
/// - 回车 = 换行（多行反馈）
/// - Esc = 继续这个目标并重新选时长（AppDelegate 本地监听处理，见 handleEscape）
/// 输入框自动聚焦。没有关闭按钮——退路是 Esc（继续）和菜单栏 Quit，不是「点旁边空白处消失」。
struct CheckInView: View {
    let goal: Goal
    let l10n: L10n
    @Binding var feedbackText: String
    /// 输入法组合态：placeholder 靠它躲开拼音组合期（跟主输入栏同一套机制）
    let isComposing: Bool

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

            // 多行反馈输入框：回车换行、⌘+回车结束。TextEditor 没有内建
            // placeholder，自绘一个淡的；isComposing 时隐藏避免叠拼音
            ZStack(alignment: .topLeading) {
                if feedbackText.isEmpty && !isComposing {
                    Text(l10n.feedbackPlaceholder)
                        .font(.system(size: 18, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $feedbackText)
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .frame(height: 84)
                    .padding(6)
                    .focused($feedbackFieldFocused)
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
            .onAppear {
                // 卡片弹出就聚焦输入框：打字即记录，不用先点。
                // 延迟一拍让弹出/激活先落地，焦点才拿得到
                DispatchQueue.main.async { feedbackFieldFocused = true }
            }

            Text(l10n.feedbackHint)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 40)
        .frame(maxWidth: 720)
    }
}
