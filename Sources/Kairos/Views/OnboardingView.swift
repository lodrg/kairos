import SwiftUI

/// 首启引导卡：只在第一次启动出现一次（settings.onboardingSeen 控制，看过永不再弹）。
/// 与签到卡同一设计语言：无卡片框、浮在压暗的极光上。
/// 只有两个键——回车 = 开始使用（留在覆盖层），Esc = 退出并收起。
/// 按键由 AppDelegate 本地监听处理（见 installKeyMonitor 的 showOnboarding 分支）。
/// 隐身原则：没有任何常驻提示，这张卡是一生一次的；热键名显示的是用户自定义后的实际键。
/// 内容按主题两列分组：目标（新建/完成/编辑删除）+ 计时与画布（武装/签到/切画布/设置）。
/// 呼出键注册失败（被别的 App 占用）时卡上直接提示换键——用户第一眼就知道要重录
struct OnboardingView: View {
    let l10n: L10n
    let showKeyName: String
    let conflicted: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                // 小屏兜底：屏幕放不下时整卡可滚动，避免顶破屏幕
                ViewThatFits(in: .vertical) {
                    content
                        .padding(56)
                        .frame(maxWidth: 760)
                    ScrollView(showsIndicators: false) {
                        content
                            .padding(36)
                            .frame(maxWidth: 760)
                    }
                    .frame(maxWidth: 760, maxHeight: geo.size.height * 0.9)
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Text("Kairos")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
                Text(l10n.onboardingTagline)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }

            // 呼出键：全卡最醒目的一行，主题色描边胶囊
            Text(showHideLine)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Palette.accent.opacity(0.12))
                        .strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1)
                }
            if conflicted {
                Text(l10n.onboardingHotkeyConflict)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                    .multilineTextAlignment(.center)
            }

            // 两列主题：目标 | 计时与画布
            HStack(alignment: .top, spacing: 56) {
                tipsColumn(header: l10n.onboardingSectionGoals, lines: [
                    l10n.onboardingNew,
                    l10n.onboardingDone,
                    l10n.onboardingEditDelete,
                    l10n.onboardingDeleteSelected
                ])
                tipsColumn(header: l10n.onboardingSectionTiming, lines: [
                    l10n.onboardingArmPick,
                    l10n.onboardingArmDefault,
                    l10n.onboardingCheckIn,
                    l10n.onboardingCanvas,
                    l10n.onboardingSettings
                ])
            }
            .frame(maxWidth: 640, alignment: .top)

            Text(l10n.onboardingFooter)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func tipsColumn(header: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(header)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.accent.opacity(0.85))
                .tracking(1.4)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    /// 呼出键名 + Esc 收起
    private var showHideLine: String {
        String(format: l10n.onboardingShowHide, showKeyName)
    }
}
