import CoreGraphics
import Foundation
import Testing

@testable import ColimaBar

@Suite struct SparklineTests {
    private let r = CGRect(x: 0, y: 0, width: 59, height: 30)

    @Test func noLineForFewerThanTwoSamples() {
        #expect(Sparkline.points([], in: r).isEmpty)
        #expect(Sparkline.points([42], in: r).isEmpty)
        #expect(Sparkline(values: []).path(in: r).isEmpty)
        #expect(Sparkline(values: [42], area: true).path(in: r).isEmpty)
    }

    @Test func scalesToZeroToHundred() {
        let pts = Sparkline.points([0, 50, 100], in: r)
        #expect(pts == [CGPoint(x: 0, y: 30), CGPoint(x: 1, y: 15), CGPoint(x: 2, y: 0)])
    }

    @Test func sixtySamplesSpanTheWidth() {
        let pts = Sparkline.points(Array(repeating: 25, count: 60), in: CGRect(x: 10, y: 5, width: 118, height: 40))
        #expect(pts.first == CGPoint(x: 10, y: 35))
        #expect(pts.last == CGPoint(x: 128, y: 35))
    }

    @Test func valuesAboveHundredRaiseTheTop() {
        let pts = Sparkline.points([0, 200], in: r)
        #expect(pts.map(\.y) == [30, 0])
    }

    @Test func areaClosesDownToTheBottom() {
        let line = Sparkline(values: [10, 20, 30]).path(in: r)
        let area = Sparkline(values: [10, 20, 30], area: true).path(in: r)
        #expect(line.boundingRect.maxY < 30)
        #expect(area.boundingRect.maxY == 30)
        #expect(area.boundingRect.minX == 0 && area.boundingRect.maxX == 2)
    }
}
