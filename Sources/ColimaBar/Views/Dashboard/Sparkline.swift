import SwiftUI

/// A line chart of the last 60 samples, drawn as a plain path. Swift Charts
/// and Canvas each cost about 130 MB of graphics memory per open dashboard.
/// A Shape costs almost nothing.
struct Sparkline: Shape {
    let values: [Double]
    /// True fills the area under the line, down to 0.
    var area = false

    /// Sample i sits at x = i / 59 of the width, as with the old chart.
    static let slots = 60

    /// The line's points in `r`. The y axis runs from 0 to the larger of 100
    /// and the largest value. Fewer than 2 values draw no line, so this
    /// returns no points for them.
    static func points(_ values: [Double], in r: CGRect) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let top = max(100, values.max() ?? 0)
        let step = r.width / CGFloat(slots - 1)
        return values.enumerated().map { i, v in
            CGPoint(x: r.minX + CGFloat(i) * step, y: r.maxY - r.height * CGFloat(v / top))
        }
    }

    func path(in r: CGRect) -> Path {
        let pts = Self.points(values, in: r)
        var p = Path()
        guard let first = pts.first, let last = pts.last else { return p }
        p.addLines(pts)
        if area {
            p.addLine(to: CGPoint(x: last.x, y: r.maxY))
            p.addLine(to: CGPoint(x: first.x, y: r.maxY))
            p.closeSubpath()
        }
        return p
    }
}
