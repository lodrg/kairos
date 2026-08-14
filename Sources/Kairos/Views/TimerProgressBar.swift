import SwiftUI

/// 常驻底部计时光带的内容视图：**覆盖层收起时**显示在屏幕底部（每屏一条浮动小窗口），
/// 所有画布中最快到期、还没到期的活跃计时器的剩余时间从满到空。
/// 覆盖层唤起（animatedIn）时内容清空——覆盖层自己会盖住整屏，光带只在非唤起状态出现。
struct TimerBarView: View {
    @ObservedObject var store: GoalStore
    @ObservedObject var model: OverlayModel
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        Group {
            // 非唤起 + 有活跃计时器才显示；设置里可关。
            // 光带贴住窗口底部 = 屏幕工作区底缘——光源像在屏幕外，光向上漫进来
            if settingsStore.settings.showTimerBar, !model.animatedIn, let bar = activeTimer {
                TimerProgressBar(minutes: bar.minutes, firesAt: bar.firesAt, revealed: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 所有画布中最快到期、还没到期的活跃计时器——覆盖层收起时没有「当前画布」概念，
    /// 取全局最早到期那条
    private var activeTimer: (minutes: Int, firesAt: Date)? {
        let now = Date()
        guard let goal = store.goals
            .filter({ !$0.isDone && ($0.timer?.firesAt ?? .distantPast) > now })
            .min(by: { ($0.timer?.firesAt ?? .distantFuture) < ($1.timer?.firesAt ?? .distantFuture) }),
            let timer = goal.timer else { return nil }
        return (timer.minutes, timer.firesAt)
    }
}

/// 底部计时光带本体：像「屏幕外有光源照进来」——光从屏幕底缘向上漫进屏幕：
/// 底缘一条亮线是光源本体，上面光晕层层向上渐隐、横向两端柔和散开。
/// 点亮段的颜色**单向流动**：蓝→紫→青多色渐变沿光带朝尖端（右）持续流过去；
/// 最后 10% 整体转暖橙。从满到空地消耗（点亮段长度 = 剩余时间比例）。
/// 流动用 20fps 高刷新率驱动、**不加渐变动画**——锯齿相位回绕处图案完全一致
/// （无缝），不会出现「一段突然窜过去」的插值闪跳；单向所以方向感明确。
/// revealed=false 时暂停。纯装饰：不占任何交互。
struct TimerProgressBar: View {
    /// 计时器总时长（分钟）
    let minutes: Int
    let firesAt: Date
    /// 是否可见（驱动 TimelineView 启停 + 透明度）
    let revealed: Bool

    /// 光晕向上漫进屏幕的高度
    private let bloomHeight: CGFloat = 72
    /// 颜色流动一个循环的秒数（图案沿光带平移一整组）
    private let flowCycle: Double = 24
    /// 流动刷新率：高到足以让单向流动看起来连续
    private let flowTick: Double = 1.0 / 20.0

    var body: some View {
        TimelineView(.animation(minimumInterval: flowTick, paused: !revealed)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let remaining = firesAt.timeIntervalSince(timeline.date)
            let total = Double(max(minutes, 1)) * 60
            let fraction = max(0, min(1, remaining / total))
            // 基础色相：正常 = 蓝紫；最后 10% = 暖橙系
            let hueBase = fraction <= 0.1 ? 0.08 : 0.60
            // 单向流动相位：单调增长的锯齿（回绕处图案完全相同 = 无缝），
            // 20fps 每步微小，视觉连续；不给渐变挂动画——挂了会在回绕时被插值成闪跳
            let shift = (t.truncatingRemainder(dividingBy: flowCycle)) / flowCycle
            let gradient = LinearGradient(
                colors: flowColors(base: hueBase),
                startPoint: UnitPoint(x: -1 + shift * 2, y: 0.5),
                endPoint: UnitPoint(x: 1 + shift * 2, y: 0.5)
            )
            GeometryReader { geo in
                let litWidth = geo.size.width * fraction
                ZStack(alignment: .bottomLeading) {
                    // 外层软光（淡、大范围）
                    Rectangle()
                        .fill(gradient)
                        .mask(verticalFade([.white.opacity(0.7), .white.opacity(0.25), .clear]))
                        .mask(horizontalSoftEdges)
                        .frame(width: litWidth, height: bloomHeight)
                    // 主光（亮、贴着底缘）
                    Rectangle()
                        .fill(gradient)
                        .mask(verticalFade([.white, .white.opacity(0.5), .white.opacity(0.15), .clear]))
                        .mask(horizontalSoftEdges)
                        .frame(width: litWidth, height: bloomHeight)
                    // 底缘亮线：光源本体（屏幕外光源的发光口）
                    Capsule()
                        .fill(gradient)
                        .frame(width: litWidth, height: 3)
                        .shadow(color: flowColors(base: hueBase)[0].opacity(0.9), radius: 6)
                }
            }
        }
        .frame(height: bloomHeight)
        .opacity(revealed ? 0.95 : 0)
        .animation(Motion.reveal, value: revealed)
        .allowsHitTesting(false)
    }

    /// 流动的渐变颜色：三色一组（围绕基础色相：主色、偏紫、偏青）重复排布，
    /// 渐变端点平移时无缝循环
    private func flowColors(base hueBase: Double) -> [Color] {
        let hues = [
            hueBase,
            (hueBase + 0.12).truncatingRemainder(dividingBy: 1),
            (hueBase - 0.10 + 1).truncatingRemainder(dividingBy: 1)
        ]
        let colors = hues.map { Color(hue: $0, saturation: 0.72, brightness: 1.0) }
        return colors + colors // 重复一组，平移才无缝
    }

    /// 竖直渐隐：底缘亮、向上淡
    private func verticalFade(_ stops: [Color]) -> LinearGradient {
        LinearGradient(colors: stops, startPoint: .bottom, endPoint: .top)
    }

    /// 横向软边：点亮段两端的光线柔和散开，不是硬切
    private var horizontalSoftEdges: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.04),
                .init(color: .black, location: 0.96),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
