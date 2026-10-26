/// The pulse chart's two scales (UX: Mac ▸ Home ▸ Pulse card; iPhone ▸ Home tab): In above the
/// line on its own scale, Out below it on another, so a quiet side isn't flattened by a busy one.
/// The plot runs from -1 to 1 with zero exactly in the middle: the busiest In bucket reaches the
/// top edge, the busiest Out bucket the bottom (or a little above it, leaving room for the refused
/// dots). Each half is labelled with its own peak, since a bar of 3 can stand as tall as one of 22.
///
/// The charts draw plot values; their hover, scrub and VoiceOver words use the real counts, and
/// `count(at:)` maps a plot value back to one.
public struct PulseScale: Sendable, Equatable {
    /// The busiest bucket's new memories, and its memories shared; 0 leaves that half empty.
    public let peakIn: Int
    public let peakOut: Int
    /// Whether any bucket has refused requests, whose dots sit under the Out bars.
    public let refused: Bool

    public init(peakIn: Int, peakOut: Int, refused: Bool) {
        self.peakIn = max(0, peakIn)
        self.peakOut = max(0, peakOut)
        self.refused = refused
    }

    /// The plot's y domain, the same above and below so the line is always in the middle.
    public static let domain: ClosedRange<Double> = -1...1

    /// Where `peakIn` reaches: the top edge.
    public static let top = 1.0
    /// Where `peakOut` reaches: the bottom edge, or above it when the dots need room.
    public var bottom: Double { refused ? -0.76 : -1 }
    /// Where the refused dots sit, between the deepest Out bar and the bottom edge.
    public static let refusedY = -0.88

    /// A count above the line as a plot value, 0...1.
    public func plot(in count: Int) -> Double {
        peakIn > 0 ? Double(max(0, count)) / Double(peakIn) * Self.top : 0
    }

    /// A count below the line as a plot value, `bottom`...0.
    public func plot(out count: Int) -> Double {
        peakOut > 0 ? Double(max(0, count)) / Double(peakOut) * bottom : 0
    }

    /// The real count a plot value stands for: In above the line, Out below it, rounded. Below
    /// the deepest Out bar (where the dots are) it's `peakOut`.
    public func count(at y: Double) -> Int {
        if y >= 0 {
            guard peakIn > 0 else { return 0 }
            return Int((min(y, Self.top) / Self.top * Double(peakIn)).rounded())
        }
        guard peakOut > 0 else { return 0 }
        return Int((max(y, bottom) / bottom * Double(peakOut)).rounded())
    }

    /// The edge labels' places, `peakIn` at the top and `peakOut` at the bottom; a side with
    /// nothing has none (never a "0").
    public var ticks: [Double] {
        var ticks: [Double] = []
        if peakIn > 0 { ticks.append(Self.top) }
        if peakOut > 0 { ticks.append(bottom) }
        return ticks
    }
}
