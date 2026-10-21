import SwiftUI

/// A slider drawn over a gradient track, used for brightness, warmth and hue.
/// `value` is updated continuously while dragging; `onEnd` fires on release.
struct GradientSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let colors: [Color]
    var onEnd: () -> Void = {}

    private let thumb: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - thumb, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 8)
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: thumb, height: thumb)
                    .offset(x: CGFloat(min(max(fraction, 0), 1)) * usable)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let f = min(max(Double((drag.location.x - thumb / 2) / usable), 0), 1)
                        value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in onEnd() }
            )
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(value))"))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
            onEnd()
        }
    }
}

extension Color {
    init(rgb: Int) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    /// Hue ramp used by colour sliders.
    static let rainbow: [Color] = (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) }
}
