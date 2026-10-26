import Testing
@testable import FunesProtocol

// The pulse's separate scales (UX: Mac ▸ Home ▸ Pulse card; iPhone ▸ Home tab).
@Suite struct PulseScaleTests {
    @Test func zeroIsInTheMiddle() {
        for scale in [PulseScale(peakIn: 3, peakOut: 22, refused: false), PulseScale(peakIn: 40, peakOut: 1, refused: true),
                      PulseScale(peakIn: 0, peakOut: 5, refused: false), PulseScale(peakIn: 0, peakOut: 0, refused: false)] {
            #expect(PulseScale.domain.lowerBound == -PulseScale.domain.upperBound)
            #expect(scale.plot(in: 0) == 0 && scale.plot(out: 0) == 0)
        }
    }

    @Test func eachPeakFillsItsHalf() {
        let scale = PulseScale(peakIn: 3, peakOut: 22, refused: false)
        #expect(scale.plot(in: 3) == 1)
        #expect(scale.plot(out: 22) == -1)
        // 3 in stands as tall as 22 out: hence the labels.
        #expect(scale.plot(in: 3) == -scale.plot(out: 22))
        #expect(scale.ticks == [1, -1])
    }

    @Test func refusedDotsFitUnderTheOutBars() {
        let scale = PulseScale(peakIn: 4, peakOut: 10, refused: true)
        #expect(scale.plot(out: 10) == scale.bottom)
        #expect(PulseScale.refusedY < scale.bottom)
        #expect(PulseScale.refusedY > PulseScale.domain.lowerBound)
        #expect(scale.plot(in: 4) == PulseScale.top)
    }

    @Test func plotValuesMapBackToCounts() {
        for refused in [false, true] {
            let scale = PulseScale(peakIn: 7, peakOut: 22, refused: refused)
            for n in 0...7 { #expect(scale.count(at: scale.plot(in: n)) == n) }
            for n in 1...22 { #expect(scale.count(at: scale.plot(out: n)) == n) }
            if refused { #expect(scale.count(at: PulseScale.refusedY) == 22) }
            #expect(scale.count(at: 5) == 7)
        }
    }

    @Test func anEmptySideIsEmptyAndUnlabelled() {
        let noOut = PulseScale(peakIn: 6, peakOut: 0, refused: false)
        #expect(noOut.plot(out: 3) == 0)
        #expect(noOut.count(at: -0.5) == 0)
        #expect(noOut.ticks == [PulseScale.top])
        let noIn = PulseScale(peakIn: 0, peakOut: 9, refused: true)
        #expect(noIn.plot(in: 2) == 0)
        #expect(noIn.ticks == [noIn.bottom])
        #expect(PulseScale(peakIn: 0, peakOut: 0, refused: false).ticks.isEmpty)
    }

    @Test func oneTallDayTakesTheWholeHalf() {
        let scale = PulseScale(peakIn: 120, peakOut: 2, refused: false)
        #expect(scale.plot(in: 120) == 1)
        #expect(scale.plot(in: 1) > 0)
        #expect(scale.plot(out: 2) == -1)
        #expect(scale.plot(out: 1) == -0.5)
    }
}
