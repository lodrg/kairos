import SwiftUI

/// 极光背景：MeshGradient 控制点被多组慢速正弦扰动，形成缓慢流动的色块。
/// 叠一层固定噪点消除大面积渐变的色带（banding），再压一层暗角把视线收到中间。
struct AuroraBackground: View {
    /// 覆盖层是否可见。不可见时必须停掉 TimelineView——
    /// 这些窗口在 App 启动后就常驻内存（每屏一块），不暂停就是常年空转。
    let active: Bool
    /// 动态背景总开关：开着 = 极光流动 + 整屏呼吸；关掉 = 静态渐变，CPU 归零。
    /// 早期拆成「极光」「呼吸」两个开关，用户觉得多余——合并成一个
    var animated = true
    /// 背景色相偏移（度，0 = 原色）：调色板整体转色相
    var hueShift: Double = 0
    /// 背景饱和度缩放（1.0 = 原色；0 = 全灰，2 = 更浓）
    var saturationScale: Double = 1.0
    /// 背景**颜色**明度缩放（HSV 明度，1.0 = 原色）：色相与饱和度不变，只改明暗。
    /// 注意这不是 .brightness() 那种整体加白/加黑——那个会把颜色洗淡，
    /// 这个才是「颜色本身的亮度」（靛蓝变浅靛蓝/深靛蓝，还是靛蓝）
    var brightnessScale: Double = 1.0

    @State private var grain: Image?

    var body: some View {
        // 调色板在源头按 HSV 缩放/偏移一次，渲染和动画逻辑完全不动
        let colors = Palette.aurora.map {
            $0.adjustingHSV(hueShift: hueShift, saturationScale: saturationScale, brightnessScale: brightnessScale)
        }
        ZStack {
            // 时间线只在「动态背景」开着时才跑：关掉时退回纯静态渐变，CPU 归零。
            // 帧率 10fps：漂移正弦周期 20-30s、呼吸 7s，全是慢变化——15fps 是 2-4 倍
            // 冗余，10fps 肉眼无差，CPU 少 1/3
            TimelineView(.animation(minimumInterval: 1.0 / 10.0,
                                    paused: !active || !animated)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate

                // 这个 ZStack 是必须的：TimelineView 的内容闭包如果直接返回两个并列视图，
                // 得到的是隐式 TupleView，而 TimelineView 不像 ZStack 那样给多子视图做层叠
                // 铺满布局——结果就是背景只盖住屏幕的一部分，目标文字却照样画在全屏范围上。
                // 这个 bug 从 Stage 0 把辉光挪进 TimelineView 做呼吸那次就存在，
                // 编译、CPU、逻辑测试全都发现不了，只有真的看一眼才看得出来。
                ZStack {
                    if animated {
                        MeshGradient(
                            width: 3,
                            height: 3,
                            points: meshPoints(t),
                            colors: colors,
                            smoothsColors: true
                        )
                        breathingLayers(t)
                    } else {
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
            }

            RadialGradient(
                colors: [.clear, Color.black.opacity(0.45)],
                center: .center,
                startRadius: 340,
                endRadius: 1180
            )

            if let grain {
                grain
                    .resizable(resizingMode: .tile)
                    .blendMode(.overlay)
                    .opacity(0.05)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .onAppear { if grain == nil { grain = Grain.make() } }
    }

    /// 呼吸两层：辉光 0↔0.55 + 全屏变暗 0.05↔0.45，7s 周期同相——
    /// 辉光亮时背景最亮、辉光灭时背景最暗。随动态背景总开关一起开关
    @ViewBuilder
    private func breathingLayers(_ t: Double) -> some View {
        RadialGradient(
            colors: [Color(red: 0.55, green: 0.72, blue: 1.0)
                .opacity(glowOpacity(t)), .clear],
            center: .init(x: 0.5, y: 0.30),
            startRadius: 0,
            endRadius: 860
        )
        Color.black
            .opacity(dimOpacity(t))
    }

    /// 辉光 0↔0.55，周期 7s
    private func glowOpacity(_ t: Double) -> Double {
        max(0, 0.275 + 0.275 * sin(t * (2 * .pi / 7.0)))
    }

    /// 全屏变暗 0.05↔0.45，周期 7s、与辉光同相（辉光亮时背景最亮、灭时最暗）
    private func dimOpacity(_ t: Double) -> Double {
        0.25 + 0.20 * sin(t * (2 * .pi / 7.0))
    }

    /// 四角钉死在角上，边中点只沿自己那条边滑动，中心点自由游走。
    /// 边界点一旦离开边界，网格填不满矩形就会露出硬边。
    /// 漂移幅度从 0.05-0.07 提到 0.16-0.22、速度从 0.09-0.14 提到 0.20-0.30：
    /// 之前幅度太小，加上极暗的配色，色块位置变化完全不可感知
    private func meshPoints(_ t: Double) -> [SIMD2<Float>] {
        func drift(_ phase: Double, _ speed: Double, _ amplitude: Double) -> Float {
            Float(sin(t * speed + phase) * amplitude)
        }
        return [
            SIMD2(0, 0),
            SIMD2(0.5 + drift(0.0, 0.28, 0.16), 0),
            SIMD2(1, 0),

            SIMD2(0, 0.5 + drift(1.3, 0.22, 0.18)),
            SIMD2(0.5 + drift(2.1, 0.30, 0.20), 0.5 + drift(3.4, 0.24, 0.22)),
            SIMD2(1, 0.5 + drift(4.2, 0.20, 0.18)),

            SIMD2(0, 1),
            SIMD2(0.5 + drift(5.0, 0.26, 0.16), 1),
            SIMD2(1, 1)
        ]
    }
}

private enum Grain {
    static func make() -> Image {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side)
        for i in pixels.indices {
            pixels[i] = UInt8.random(in: 104...152) // 以中灰 128 为轴，overlay 混合下才是加噪而非提亮
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: side,
                height: side,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return Image(systemName: "circle").renderingMode(.template) }

        return Image(decorative: cgImage, scale: 2)
    }
}

private extension Color {
    /// HSV 三项调整：色相平移（h + shift mod 360）、饱和度缩放、明度缩放，全部 0–1 钳制。
    /// 在调色板源头做——这是「颜色本身的属性」调整；.saturation()/.brightness() 那种
    /// 修饰符是逐像素整体变换，会把颜色洗淡/发闷
    func adjustingHSV(hueShift: Double, saturationScale: Double, brightnessScale: Double) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let newH = (Double(h) * 360 + hueShift).truncatingRemainder(dividingBy: 360) / 360
        let newS = max(0, min(1, Double(s) * saturationScale))
        let newV = max(0, min(1, Double(v) * brightnessScale))
        return Color(hue: newH, saturation: newS, brightness: newV, opacity: Double(a))
    }
}
