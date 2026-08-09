import SwiftUI

// MARK: - 动效词汇表

/// 全局唯一的动效来源。SwiftUI 和 AppKit 共用这里的时长，
/// 否则窗口淡入和内容动画是两个时钟，快慢对不上就会显出割裂感。
///
/// 一切以淡入淡出为主：不做位移、缩放、模糊、错峰。
enum Motion {
    enum Duration {
        static let reveal: TimeInterval = 0.34
        static let dismiss: TimeInterval = 0.26
    }

    /// 呼出：内容整体淡入
    static let reveal = Animation.easeOut(duration: Duration.reveal)
    /// 收起
    static let dismiss = Animation.easeOut(duration: Duration.dismiss)
    /// 状态切换（勾选、聚焦等）
    static let fade = Animation.easeInOut(duration: 0.26)
    /// 新建、保存编辑等引起内容增减的操作
    static let commit = Animation.easeOut(duration: 0.26)
    /// 位置变化：输入栏下沉 / 回升。比内容淡入淡出慢一截，慢慢挪回去才不显得跳
    static let layout = Animation.easeInOut(duration: 0.55)

    /// 勾选后淡出到消失的时长。退场定时器用的是同一个常量，
    /// 分成两个数就会出现「已经看不见但行还占着位置」的错位。
    static let completion: TimeInterval = 0.55
    static let retire = Animation.easeInOut(duration: completion)

    /// 切画布：交叉淡入淡出 + 顺方向小位移，不做整条横向滑动——
    /// 滑动要求所有画布常驻视图树，且各画布目标数不同、listHeight 不同，输入框位置会打架
    static let canvasSwitch = Animation.easeInOut(duration: 0.32)
    static let canvasSwitchTravel: CGFloat = 40
}


// MARK: - 配色

enum Palette {
    /// 极光背景的控制点基色（左上 → 右下）
    static let aurora: [Color] = [
        Color(red: 0.024, green: 0.035, blue: 0.094),
        Color(red: 0.086, green: 0.067, blue: 0.243),
        Color(red: 0.043, green: 0.106, blue: 0.259),
        Color(red: 0.145, green: 0.055, blue: 0.227),
        Color(red: 0.196, green: 0.086, blue: 0.310),
        Color(red: 0.031, green: 0.078, blue: 0.196),
        Color(red: 0.016, green: 0.027, blue: 0.078),
        Color(red: 0.063, green: 0.043, blue: 0.169),
        Color(red: 0.020, green: 0.051, blue: 0.141)
    ]

    static let accent = Color(red: 0.51, green: 0.68, blue: 1.0)
    static let done = Color(red: 0.36, green: 0.90, blue: 0.66)

    /// 新建画布按顺序从这里取色相；配置面板里的色相选择器也用同一份，
    /// 保证「自动分配的颜色」和「手动可选的颜色」是同一个集合
    static let canvasHues: [Double] = [0, 150, 260, 45, 200, 320, 100, 280]
}

// MARK: - 尺寸

/// 行高和输入栏高度是写死的常量，不靠 GeometryReader 量。
/// 量出来再回填 @State 会让「内容高度 → 布局 → 内容高度」形成回路，是抖动的根源。
enum Metrics {
    static let rowHeight: CGFloat = 78
    /// 子目标行更矮更小——只允许一层嵌套，46pt 字再缩进一级就没法读了
    static let subRowHeight: CGFloat = 56
    /// 输入栏加高到能常驻一条「正在给谁加子目标」的提示行（不显示时占位但透明，
    /// 不能让输入栏的实际高度随内容变化，否则又是一处「内容决定布局」）
    static let inputBarHeight: CGFloat = 122
    /// 输入栏静止时中线落在屏幕高度的这个比例处。0.5 是正中，略大于 0.5 更稳
    static let inputRestingFraction: CGFloat = 0.58
    static let goalFont: CGFloat = 46
    static let subGoalFont: CGFloat = 32
    static let inputFont: CGFloat = 42
    static let contentWidth: CGFloat = 940
    static let boxSize: CGFloat = 38
    static let subBoxSize: CGFloat = 28
    static let gutter: CGFloat = 28
    /// 子目标缩进量 = 父目标的方块宽 + 间距，让子目标的方块对齐到父目标文字的起始位置
    static let subIndent: CGFloat = boxSize + gutter
}

/// `Metrics` 的可配置版本：配置面板里的「输入栏位置」「文字大小」两个滑块解析出来的实际值。
/// 只有一个整体缩放系数，不是每个常量各自独立可调——独立调的话用户很容易调出
/// 字比行高还高、方块和文字不成比例的破样子，我又没法截图看出来提前拦住。
/// `contentWidth` 不跟着缩放：缩放管的是竖直方向的行高/字号，不是横向排版宽度。
struct LayoutMetrics {
    let rowHeight: CGFloat
    let subRowHeight: CGFloat
    let inputBarHeight: CGFloat
    let inputRestingFraction: CGFloat
    let goalFont: CGFloat
    let subGoalFont: CGFloat
    let inputFont: CGFloat
    let boxSize: CGFloat
    let subBoxSize: CGFloat
    let gutter: CGFloat
    let subIndent: CGFloat

    /// scale=1.0、restingFraction=0.58 时数值和 `Metrics` 里硬编码的完全一致——
    /// 配置面板的默认值必须精确对应旧常量，否则 Stage 5 一上线所有人的布局都会跳一下
    init(scale: Double, restingFraction: Double) {
        let s = CGFloat(max(0.75, min(1.35, scale)))
        rowHeight = Metrics.rowHeight * s
        subRowHeight = Metrics.subRowHeight * s
        // 26pt 的「正在给谁加子目标」提示槽不跟着缩放，只有下面的实际输入行缩放
        inputBarHeight = 26 + 96 * s
        inputRestingFraction = CGFloat(max(0.35, min(0.75, restingFraction)))
        goalFont = Metrics.goalFont * s
        subGoalFont = Metrics.subGoalFont * s
        inputFont = Metrics.inputFont * s
        boxSize = Metrics.boxSize * s
        subBoxSize = Metrics.subBoxSize * s
        gutter = Metrics.gutter * s
        subIndent = boxSize + gutter
    }
}
