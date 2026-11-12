#if os(iOS)
import FirepickCore
import SwiftUI

@MainActor
public struct DanmakuOverlay: View {
    private let comments: [DanmakuComment]
    private let currentTime: Double
    private let isPlaying: Bool
    private let isEnabled: Bool

    @State private var anchorTime: Double = 0
    @State private var anchorDate = Date()

    public init(
        comments: [DanmakuComment],
        currentTime: Double,
        isPlaying: Bool,
        isEnabled: Bool = true
    ) {
        self.comments = comments
        self.currentTime = currentTime
        self.isPlaying = isPlaying
        self.isEnabled = isEnabled
    }

    public var body: some View {
        if isEnabled, !comments.isEmpty {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) {
                timeline in
                Canvas(rendersAsynchronously: true) { context, size in
                    let time = displayTime(at: timeline.date)
                    for item in activeComments(at: time) {
                        draw(item, time: time, in: &context, size: size)
                    }
                }
            }
            .allowsHitTesting(false)
            .onChange(of: currentTime) { _, value in
                anchorTime = value
                anchorDate = .now
            }
            .onAppear {
                anchorTime = currentTime
                anchorDate = .now
            }
        }
    }

    private func displayTime(at date: Date) -> Double {
        guard isPlaying else { return anchorTime }
        return anchorTime + max(0, date.timeIntervalSince(anchorDate))
    }

    private func activeComments(at time: Double) -> ArraySlice<DanmakuComment> {
        guard !comments.isEmpty else { return comments[0...] }
        var low = 0
        var high = comments.count
        let minimum = time - 8
        while low < high {
            let middle = (low + high) / 2
            if comments[middle].time < minimum {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let start = low
        high = comments.count
        while low < high {
            let middle = (low + high) / 2
            if comments[middle].time <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let end = min(comments.count, low)
        guard start < end else { return comments[0..<0] }
        let candidates = comments[start..<end]
        let visible = candidates.filter { item in
            time < item.time + duration(for: item)
        }
        return visible.count > 120 ? visible.suffix(120) : visible[...]
    }

    private func duration(for item: DanmakuComment) -> Double {
        switch item.mode {
        case .scrolling, .reverse: 8
        case .top, .bottom: 5
        }
    }

    private func draw(
        _ item: DanmakuComment,
        time: Double,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let elapsed = max(0, time - item.time)
        let duration = duration(for: item)
        let progress = min(1, elapsed / duration)
        let font = Font.system(
            size: item.fontSize,
            weight: .bold,
            design: .rounded
        )
        let text = Text(item.text)
            .font(font)
            .foregroundStyle(color(item.color))
        let resolved = context.resolve(text)
        let measured = resolved.measure(in: CGSize(width: 1_000, height: 100))
        let lane = stableLane(item.id)
        let centerY: CGFloat
        let centerX: CGFloat

        switch item.mode {
        case .scrolling:
            let travel = size.width + measured.width + 24
            centerX = size.width + measured.width / 2 - travel * progress
            centerY = 26 + CGFloat(lane % 8) * (item.fontSize + 13)
        case .reverse:
            let travel = size.width + measured.width + 24
            centerX = -measured.width / 2 + travel * progress
            centerY = 26 + CGFloat(lane % 8) * (item.fontSize + 13)
        case .top:
            centerX = size.width / 2
            centerY = 24 + CGFloat(lane % 4) * 38
        case .bottom:
            centerX = size.width / 2
            centerY = size.height - 72 - CGFloat(lane % 4) * 38
        }

        var colored = context
        colored.addFilter(.shadow(color: .black.opacity(0.9), radius: 2, x: 1, y: 1))
        colored.draw(resolved, at: CGPoint(x: centerX, y: centerY), anchor: .center)
    }

    private func stableLane(_ value: String) -> Int {
        value.unicodeScalars.reduce(0) {
            ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF
        }
    }

    private func color(_ value: String) -> Color {
        let cleaned = value.replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let number = UInt32(cleaned, radix: 16) else {
            return .white
        }
        return Color(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}
#endif
