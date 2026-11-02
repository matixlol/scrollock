import SwiftUI

/// Native copy of the extension's duration slider (extension/timer.js): a
/// capsule track with tick dots and a draggable "N min" pill, 5–60 in steps of 5.
struct DurationSlider: View {
  @Binding var minutes: Int

  static let range = 5...60
  static let step = 5
  private let pillWidth: CGFloat = 88
  private let height: CGFloat = 48
  @State private var grabOffset: CGFloat?

  private var fraction: CGFloat {
    CGFloat(minutes - Self.range.lowerBound) / CGFloat(Self.range.upperBound - Self.range.lowerBound)
  }

  var body: some View {
    VStack(spacing: 8) {
      GeometryReader { geometry in
        let travel = geometry.size.width - pillWidth - 4
        ZStack(alignment: .leading) {
          Capsule().fill(Color(.systemFill))
          HStack(spacing: 0) {
            ForEach(0..<12) { index in
              if index > 0 { Spacer(minLength: 0) }
              Circle().fill(Color(.secondaryLabel)).frame(width: 4, height: 4)
            }
          }
          .padding(.horizontal, 44)
          Text("\(minutes) min")
            .font(.body.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.black)
            .frame(width: pillWidth, height: height - 4)
            .background(Capsule().fill(.white).shadow(color: .black.opacity(0.13), radius: 1.5, y: 1))
            .offset(x: 2 + travel * fraction)
        }
        .contentShape(Capsule())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              // Grabbing the pill keeps it under the finger; tapping the track jumps there.
              if grabOffset == nil {
                let center = 2 + travel * fraction + pillWidth / 2
                grabOffset = abs(value.startLocation.x - center) <= pillWidth / 2 ? value.startLocation.x - center : 0
              }
              let position = min(max((value.location.x - (grabOffset ?? 0) - pillWidth / 2 - 2) / travel, 0), 1)
              let steps = (Self.range.upperBound - Self.range.lowerBound) / Self.step
              let next = Self.range.lowerBound + Int((position * CGFloat(steps)).rounded()) * Self.step
              if next != minutes { minutes = next }
            }
            .onEnded { _ in grabOffset = nil }
        )
      }
      .frame(height: height)
      HStack {
        Text("\(Self.range.lowerBound) min")
        Spacer()
        Text("\(Self.range.upperBound) min")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .animation(.snappy(duration: 0.15), value: minutes)
    .sensoryFeedback(.selection, trigger: minutes)
    .accessibilityElement()
    .accessibilityLabel("Duration")
    .accessibilityValue("\(minutes) minutes")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: minutes = min(Self.range.upperBound, minutes + Self.step)
      case .decrement: minutes = max(Self.range.lowerBound, minutes - Self.step)
      @unknown default: break
      }
    }
  }
}

#Preview {
  @Previewable @State var minutes = 5
  DurationSlider(minutes: $minutes).padding()
}
