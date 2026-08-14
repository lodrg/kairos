import SwiftUI

/// 首启引导卡：只在第一次启动出现一次（settings.onboardingSeen 控制，看过永不再弹）。
/// 与签到卡同一设计语言：无卡片框、浮在压暗的极光上。
/// 只有两个键——回车 = 开始使用（留在覆盖层），Esc / 收起键 = 退出。
/// 按键由 AppDelegate 本地监听处理（见 installKeyMonitor 的 showOnboarding 分支）。
/// 隐身原则：没有任何常驻提示，这张卡是一生一次的；热键名显示的是用户自定义后的实际键
struct OnboardingView: View {
    let l10n: L10n
    let showKeyName: String
    let hideKeyName: String
    let sameKey: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            VStack(spacing: 30) {
                VStack(spacing: 10) {
                    Text("Kairos")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(l10n.onboardingTagline)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text(showHideLine)
                    Text(l10n.onboardingNew)
                    Text(l10n.onboardingDone)
                    Text(l10n.onboardingSettings)
                }
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.85))
                Text(l10n.onboardingFooter)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(56)
            .frame(maxWidth: 720)
        }
    }

    /// 同一个键：双击呼出 / 单击收起；分开：各按一次
    private var showHideLine: String {
        if sameKey {
            return String(format: l10n.onboardingShowHideSame, showKeyName, showKeyName)
        }
        return String(format: l10n.onboardingShowHideDiff, showKeyName, hideKeyName)
    }
}
