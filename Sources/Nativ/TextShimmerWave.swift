import SwiftUI

/// A per-character shimmer *wave* on a single `Text`: a bright band travels
/// across the glyphs, each character easing from a dim base to a bright
/// highlight (color + subtle lift + depth) in sequence. Uses an
/// `AttributedString` with per-character attributes, so the font, shaping,
/// kerning, and truncation are identical to normal text (no per-glyph layout
/// breakage). The band wraps seamlessly (no dead moment between passes),
/// throttles to ~30 fps, and honors Reduce Motion. Animates only while `active`.
struct TextShimmerWave: View {
    let text: String
    var active: Bool
    var base: Color = .secondary
    var highlight: Color = .primary
    /// Seconds for the wave to travel the whole string once.
    var duration: Double = 1.1
    /// Reach of the band, in characters (its dim falloff).
    var spread: Double = 2.2
    /// Widens the fully-bright plateau (higher = longer white part).
    var whiteGain: Double = 1.7
    /// Vertical lift (points) of the brightest characters.
    var lift: Double = 1.5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if active {
            if reduceMotion {
                // No sweep — a static, gently-emphasized title.
                Text(text).foregroundStyle(highlight)
            } else {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                    Text(attributed(at: timeline.date.timeIntervalSinceReferenceDate))
                }
            }
        } else {
            Text(text).foregroundStyle(Color.primary)
        }
    }

    private func attributed(at time: TimeInterval) -> AttributedString {
        var attr = AttributedString(text)
        let count = text.count
        guard count > 0 else { return attr }

        // Head wraps over the string length so the band exits the right edge as
        // it re-enters the left — a continuous loop with no all-dim gap.
        let period = Double(count)
        let progress = time.truncatingRemainder(dividingBy: duration) / duration
        let head = progress * period

        var index = attr.startIndex
        var i = 0
        while index < attr.endIndex {
            let next = attr.index(afterCharacter: index)
            let linear = abs(head - Double(i))
            let distance = min(linear, period - linear)   // circular distance → seamless wrap
            let raw = max(0, 1 - distance / spread)
            let widened = min(1, raw * whiteGain)          // wider bright plateau
            let eased = widened * widened * (3 - 2 * widened)  // smoothstep
            // Color wave + a touch of opacity depth on the dim base.
            attr[index ..< next].foregroundColor = base
                .mix(with: highlight, by: eased)
                .opacity(0.85 + 0.15 * eased)
            attr[index ..< next].baselineOffset = eased * lift
            index = next
            i += 1
        }
        return attr
    }
}
