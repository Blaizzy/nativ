import SwiftUI

/// A per-character shimmer *wave* on a single `Text`: a bright band travels
/// across the glyphs, each character easing from a dim base to a bright
/// highlight (with a subtle lift) in sequence. Uses an `AttributedString` with
/// per-character color + baseline offset — so the font, shaping, kerning, and
/// truncation are identical to normal text (no per-glyph layout breakage).
/// Animates only while `active`; otherwise it's plain primary text.
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

    var body: some View {
        if active {
            TimelineView(.animation) { timeline in
                Text(attributed(at: timeline.date.timeIntervalSinceReferenceDate))
            }
        } else {
            Text(text).foregroundStyle(Color.primary)
        }
    }

    private func attributed(at time: TimeInterval) -> AttributedString {
        var attr = AttributedString(text)
        let count = text.count
        guard count > 0 else { return attr }

        let travel = Double(count) + spread * 2
        let progress = time.truncatingRemainder(dividingBy: duration) / duration
        let head = progress * travel - spread  // sweeps -spread … count+spread, looping

        var index = attr.startIndex
        var i = 0
        while index < attr.endIndex {
            let next = attr.index(afterCharacter: index)
            let distance = abs(head - Double(i))
            let raw = max(0, 1 - distance / spread)      // triangular reach 0…1
            let widened = min(1, raw * whiteGain)        // clip the top → wider bright plateau
            let eased = widened * widened * (3 - 2 * widened)  // smoothstep
            attr[index ..< next].foregroundColor = base.mix(with: highlight, by: eased)
            attr[index ..< next].baselineOffset = eased * lift
            index = next
            i += 1
        }
        return attr
    }
}
