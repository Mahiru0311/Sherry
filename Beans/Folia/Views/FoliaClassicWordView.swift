import SwiftUI

struct FoliaClassicWordView: View {
    let word: FoliaWord
    let time: Double
    let state: FoliaClassicWordState
    let geometry: FoliaClassicWordGeometry
    let intensity: FoliaClassicIntensity
    let fontSize: Double
    let base: Color
    let accent: Color
    let rotationEnabled: Bool
    let reduceMotion: Bool

    private var opacity: Double {
        switch state { case .waiting: return 0; case .active: return 1; case .passed: return intensity == .chaotic ? 0.9 : 0.82 }
    }
    private var scale: Double {
        guard !reduceMotion else { return 1 }
        switch state { case .waiting: return 0.4; case .active: return geometry.scale * 1.6; case .passed: return geometry.scale }
    }
    private var rotation: Double {
        guard !reduceMotion, rotationEnabled else { return 0 }
        switch state {
        case .waiting: return geometry.rotation + 20
        case .active: return geometry.rotation
        case .passed: return geometry.rotation + geometry.passedRotation
        }
    }
    /// 2.2.3：五处叠加的 .animation 合并为这一处：等待/已过统一用
    /// spring(0.30/0.85)，进行中保持逐词插值弹簧（逐字扫掠的驱动）。
    private var animation: Animation? {
        guard !reduceMotion else { return nil }
        switch state {
        case .waiting: return .spring(response: 0.30, dampingFraction: 0.85)
        case .active: return .interpolatingSpring(mass: 1, stiffness: 260, damping: 16, initialVelocity: 0)
        case .passed: return .spring(response: 0.30, dampingFraction: 0.85)
        }
    }

    var body: some View {
        Text(word.text).font(.system(size: fontSize, weight: .bold)).fixedSize()
            .foregroundStyle(state == .active ? accent : base)
            .background {
                if !reduceMotion { FoliaClassicGlowView(word: word, time: time, fontSize: fontSize, color: accent) }
            }
            .blur(radius: state == .waiting && !reduceMotion ? 8 : 0)
            .opacity(opacity)
            .scaleEffect(scale)
            .offset(x: reduceMotion ? 0 : geometry.x + (state == .waiting ? sin(geometry.y) * 40 : 0),
                    y: reduceMotion ? 0 : geometry.y + (state == .waiting ? cos(geometry.x) * 24 : 0))
            .rotationEffect(.degrees(rotation))
            // 2.2.3：上面五处叠加的 .animation 合并为这一处；5s 线性旋转淡出已删。
            .animation(animation, value: state)
            .accessibilityHidden(state == .waiting)
    }
}
