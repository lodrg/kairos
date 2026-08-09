import SwiftUI

/// 极光背景：MeshGradient 控制点被多组慢速正弦扰动，形成缓慢流动的色块。
/// 叠一层固定噪点消除大面积渐变的色带（banding），再压一层暗角把视线收到中间。
struct AuroraBackground: View {
    /// 覆盖层是否可见。不可见时必须停掉 TimelineView——
    /// 这些窗口在 App 启动后就常驻内存（每屏一块），不暂停就是常年空转。
    let active: Bool

    @State private var grain: Image?

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !active)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate

                MeshGradient(
                    width: 3,
                    height: 3,
                    points: meshPoints(t),
                    colors: Palette.aurora,
                    smoothsColors: true
                )

                // 呼吸：辉光透明度沿 7s 周期的慢正弦轻微起伏，默认态下唯一的动。
                // 复用同一个 t，不额外起时钟；隐藏时随 TimelineView 一起暂停。
                RadialGradient(
                    colors: [Color.white.opacity(breatheOpacity(t)), .clear],
                    center: .init(x: 0.5, y: 0.32),
                    startRadius: 0,
                    endRadius: 820
                )
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

    /// 0.030 ↔ 0.060，周期 7s。幅度压得很轻——这是默认态下唯一的动，不能抢戏
    private func breatheOpacity(_ t: Double) -> Double {
        0.045 + 0.015 * sin(t * (2 * .pi / 7.0))
    }

    /// 四角钉死在角上，边中点只沿自己那条边滑动，中心点自由游走。
    /// 边界点一旦离开边界，网格填不满矩形就会露出硬边。
    private func meshPoints(_ t: Double) -> [SIMD2<Float>] {
        func drift(_ phase: Double, _ speed: Double, _ amplitude: Double) -> Float {
            Float(sin(t * speed + phase) * amplitude)
        }
        return [
            SIMD2(0, 0),
            SIMD2(0.5 + drift(0.0, 0.13, 0.05), 0),
            SIMD2(1, 0),

            SIMD2(0, 0.5 + drift(1.3, 0.10, 0.055)),
            SIMD2(0.5 + drift(2.1, 0.14, 0.07), 0.5 + drift(3.4, 0.11, 0.065)),
            SIMD2(1, 0.5 + drift(4.2, 0.09, 0.055)),

            SIMD2(0, 1),
            SIMD2(0.5 + drift(5.0, 0.12, 0.05), 1),
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
