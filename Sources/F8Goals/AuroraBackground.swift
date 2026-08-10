import SwiftUI

/// 极光背景：MeshGradient 控制点被多组慢速正弦扰动，形成缓慢流动的色块。
/// 叠一层固定噪点消除大面积渐变的色带（banding），再压一层暗角把视线收到中间。
struct AuroraBackground: View {
    /// 覆盖层是否可见。不可见时必须停掉 TimelineView——
    /// 这些窗口在 App 启动后就常驻内存（每屏一块），不暂停就是常年空转。
    let active: Bool
    /// 关掉只影响辉光是否呼吸，网格照样流动
    var breathingEnabled = true
    /// 关掉整个网格动画，退回一张静态渐变——连 TimelineView 都不起，CPU 归零
    var meshEnabled = true

    @State private var grain: Image?

    var body: some View {
        ZStack {
            if meshEnabled {
                TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !active)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate

                    // 这个 ZStack 是必须的：TimelineView 的内容闭包如果直接返回两个并列视图，
                    // 得到的是隐式 TupleView，而 TimelineView 不像 ZStack 那样给多子视图做层叠
                    // 铺满布局——结果就是背景只盖住屏幕的一部分，目标文字却照样画在全屏范围上。
                    // 这个 bug 从 Stage 0 把辉光挪进 TimelineView 做呼吸那次就存在，
                    // 编译、CPU、逻辑测试全都发现不了，只有真的看一眼才看得出来。
                    ZStack {
                        MeshGradient(
                            width: 3,
                            height: 3,
                            points: meshPoints(t),
                            colors: Palette.aurora,
                            smoothsColors: true
                        )

                        // 呼吸辉光：0↔0.45，7s 周期。之前摆幅 0↔0.26 在暗背景下
                        // 肉眼仍难分辨；再大一点，一明一灭才真的看得出来
                        RadialGradient(
                            colors: [Color(red: 0.55, green: 0.72, blue: 1.0)
                                .opacity(breathingEnabled ? glowOpacity(t) : 0.08), .clear],
                            center: .init(x: 0.5, y: 0.30),
                            startRadius: 0,
                            endRadius: 860
                        )

                        // 整屏呼吸变暗：全屏黑 0.12↔0.38 与辉光同相——辉光亮时背景最亮、
                        // 辉光灭时背景最暗。单靠辉光只有局部亮度变化，加上这一层，
                        // 整块背景都在一明一灭，呼吸感才明确
                        Color.black
                            .opacity(breathingEnabled ? dimOpacity(t) : 0.25)
                    }
                }
            } else {
                LinearGradient(colors: Palette.aurora, startPoint: .topLeading, endPoint: .bottomTrailing)
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

    /// 辉光 0↔0.45，周期 7s
    private func glowOpacity(_ t: Double) -> Double {
        max(0, 0.225 + 0.225 * sin(t * (2 * .pi / 7.0)))
    }

    /// 全屏变暗 0.12↔0.38，周期 7s、与辉光同相（辉光亮时背景最亮、灭时最暗）
    private func dimOpacity(_ t: Double) -> Double {
        0.25 + 0.13 * sin(t * (2 * .pi / 7.0))
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
