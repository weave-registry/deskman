import Testing
import DeskmanDomain

// A 1440×900 display whose menu bar takes the top 25 points.
// Top-left origin, y down (ADR-2610101046 §5).
private let visible = Rect(x: 0, y: 25, width: 1440, height: 875)

@Suite struct LayoutTests {
    @Test func halvesSplitTheVisibleArea() {
        #expect(Layout.leftHalf.frame(in: visible) == Rect(x: 0, y: 25, width: 720, height: 875))
        #expect(Layout.rightHalf.frame(in: visible) == Rect(x: 720, y: 25, width: 720, height: 875))
        #expect(Layout.topHalf.frame(in: visible) == Rect(x: 0, y: 25, width: 1440, height: 437.5))
        #expect(Layout.bottomHalf.frame(in: visible) == Rect(x: 0, y: 462.5, width: 1440, height: 437.5))
    }

    @Test func quartersSitInTheirCorners() {
        #expect(Layout.topLeft.frame(in: visible) == Rect(x: 0, y: 25, width: 720, height: 437.5))
        #expect(Layout.bottomRight.frame(in: visible) == Rect(x: 720, y: 462.5, width: 720, height: 437.5))
    }

    @Test func thirdsTileTheWidthExactly() {
        let l = Layout.leftThird.frame(in: visible)
        let c = Layout.centerThird.frame(in: visible)
        let r = Layout.rightThird.frame(in: visible)
        #expect(l.maxX == c.minX)
        #expect(c.maxX == r.minX)
        #expect(r.maxX == visible.maxX)
        #expect(l.width + c.width + r.width == visible.width)
    }

    @Test func maximizeFillsAndCenterIsInside() {
        #expect(Layout.maximize.frame(in: visible) == visible)
        let c = Layout.center.frame(in: visible)
        #expect(visible.contains(c))
        #expect(c.midX == visible.midX)
        #expect(c.midY == visible.midY)
    }

    @Test(arguments: Layout.allCases)
    func everyLayoutStaysOnTheDisplay(layout: Layout) {
        #expect(visible.contains(layout.frame(in: visible)))
    }
}

@Suite struct GridTilerTests {
    @Test func oneWindowGetsTheWholeArea() {
        #expect(GridTiler.frames(count: 1, in: visible) == [visible])
    }

    @Test func zeroWindowsGetNothing() {
        #expect(GridTiler.frames(count: 0, in: visible).isEmpty)
    }

    @Test func threeWindowsUseTwoColumnsAndTheLastRowSpans() {
        let f = GridTiler.frames(count: 3, in: visible)
        #expect(f.count == 3)
        #expect(f[0].width == 720)
        #expect(f[2].width == 1440)
    }

    // Property: for any count, tiles never overlap and their areas add up to the whole.
    @Test(arguments: 1...12)
    func tilesCoverTheAreaWithoutOverlap(count: Int) {
        let f = GridTiler.frames(count: count, in: visible)
        #expect(f.count == count)
        for (i, a) in f.enumerated() {
            #expect(visible.contains(a))
            for b in f[(i + 1)...] {
                #expect((a.intersection(b)?.area ?? 0) < 0.001)
            }
        }
        let total = f.reduce(0) { $0 + $1.area }
        #expect(abs(total - visible.area) < 0.001)
    }
}

@Suite struct CoordinateSpaceTests {
    // AppKit: origin bottom-left of the primary display, y up.
    // The hexagon: origin top-left, y down.
    @Test func appKitFrameFlipsToTopLeft() {
        let appKitVisible = Rect(x: 0, y: 0, width: 1440, height: 875) // dock-less, below the menu bar
        let topLeft = CoordinateSpace.topLeft(fromAppKit: appKitVisible, primaryDisplayHeight: 900)
        #expect(topLeft == visible)
    }

    @Test func aDisplayAboveThePrimaryHasNegativeY() {
        let above = Rect(x: 0, y: 900, width: 1920, height: 1080)
        let topLeft = CoordinateSpace.topLeft(fromAppKit: above, primaryDisplayHeight: 900)
        #expect(topLeft == Rect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    @Test func flippingTwiceIsIdentity() {
        let r = Rect(x: 12, y: 340, width: 800, height: 600)
        let back = CoordinateSpace.appKit(
            fromTopLeft: CoordinateSpace.topLeft(fromAppKit: r, primaryDisplayHeight: 1117),
            primaryDisplayHeight: 1117)
        #expect(back == r)
    }
}

@Suite struct DisplayTests {
    let main = Display(index: 0, visibleFrame: visible)
    let side = Display(index: 1, visibleFrame: Rect(x: 1440, y: 0, width: 1920, height: 1080))

    @Test func theDisplayWithTheLargestOverlapWins() {
        let straddling = Rect(x: 1300, y: 100, width: 600, height: 400) // 140 on main, 460 on side
        #expect(Displays.containing(straddling, in: [main, side]) == side)
    }

    @Test func aWindowOffEveryDisplayFallsBackToTheFirst() {
        let lost = Rect(x: -5000, y: -5000, width: 100, height: 100)
        #expect(Displays.containing(lost, in: [main, side]) == main)
    }

    @Test func nextWrapsAround() {
        #expect(Displays.next(after: main, in: [main, side]) == side)
        #expect(Displays.next(after: side, in: [main, side]) == main)
    }
}
