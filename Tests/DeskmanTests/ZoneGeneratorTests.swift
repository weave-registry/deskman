import Testing
import DeskmanDomain

// ADR-2610101523: Deskman draws its own zones.

private let ultrawide = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 5120, height: 1380))
private let laptop = Display(index: 0, visibleFrame: Rect(x: 0, y: 30, width: 1512, height: 915))
private let upright = Display(index: 0, visibleFrame: Rect(x: 0, y: 0, width: 1080, height: 1920))
private let normal = Display(index: 0, visibleFrame: Rect(x: 0, y: 25, width: 1440, height: 875))

private func frames(_ count: Int, _ weights: [Double] = [], on d: Display, within area: Rect? = nil) -> [Rect] {
    ZoneGenerator.layout(count: count, weights: weights, on: d, within: area).zones.map { $0.frame(in: d) }
}

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.5 }

@Suite struct ZoneGeneratorTests {
    @Test func oneWindowFillsAnOrdinaryDisplay() {
        #expect(frames(1, on: normal) == [normal.visibleFrame])
    }

    @Test func oneWindowOnAnUltrawideGetsTheCenterHalf() {
        let f = frames(1, on: ultrawide)
        #expect(f.count == 1)
        #expect(near(f[0].x, 1280) && near(f[0].width, 2560) && near(f[0].height, 1380))
    }

    @Test func twoEquallyActiveWindowsSplitInHalves() {
        let f = frames(2, [5, 5], on: normal)
        #expect(f.count == 2)
        #expect(near(f[0].width, 720) && near(f[1].width, 720))
    }

    @Test func aDominantWindowGetsTwoThirds() {
        // 2400 pt: two thirds leave the side 800, over the 700 minimum.
        let wide = Display(index: 0, visibleFrame: Rect(x: 0, y: 25, width: 2400, height: 1055))
        #expect(near(frames(2, [10, 0], on: wide)[0].width, 1600))
    }

    @Test func theSideWindowKeepsItsMinimumWidth() {
        // Two thirds of 1440 would leave the side 480 pt; it keeps the 700 minimum.
        #expect(near(frames(2, [10, 0], on: normal)[0].width, 740))
    }

    @Test func fiveOnAnUltrawideIsACenterAndTwoStackedSides() {
        let f = frames(5, on: ultrawide)
        #expect(f.count == 5)
        #expect(near(f[0].x, 1280) && near(f[0].width, 2560))      // main, center half
        let left = f.dropFirst().filter { $0.x < 100 }, right = f.dropFirst().filter { $0.x > 3800 }
        #expect(left.count == 2 && right.count == 2)
        #expect(left.allSatisfy { near($0.height, 690) && near($0.width, 1280) })
    }

    @Test func theMainColumnGrowsWithActivity() {
        let calm = frames(3, [1, 1, 1], on: ultrawide)[0].width
        let busy = frames(3, [20, 1, 1], on: ultrawide)[0].width
        #expect(near(calm, 2048))          // 40% when the main window is no more active than the rest
        #expect(busy > 2900 && busy <= 3072)
    }

    @Test func aColumnHoldsOnlyAsManyAsFitTall() {
        // Two at most per column, however tall (2026-10-12): 1 main + 2 left + 2 right.
        #expect(frames(9, on: ultrawide).count == 5)
    }

    @Test func aLaptopGetsAMainAndOneStackedSide() {
        let f = frames(3, on: laptop)
        #expect(f.count == 3)
        #expect(near(f[0].x, 0) && near(f[0].width, 756) && near(f[0].height, 915))
        #expect(f.dropFirst().allSatisfy { near($0.x, 756) && near($0.height, 457.5) })
    }

    @Test func anUprightDisplayGetsRows() {
        // 1080 pt across: two side by side would be 540 each, under the 700 minimum. Two rows; the third goes out of the way.
        let f = frames(3, on: upright)
        #expect(f.count == 2)
        #expect(f.allSatisfy { near($0.width, 1080) && near($0.height, 960) })
        #expect(near(f[0].y, 0) && near(f[1].y, 960))
    }

    @Test func zonesStayInsideTheAreaTheyAreGiven() {
        let free = Rect(x: 1700, y: 30, width: 3420, height: 1380)
        let f = frames(3, on: ultrawide, within: free)
        #expect(f.allSatisfy { $0.x >= 1700 - 0.5 && $0.maxX <= 5120.5 })
    }

    @Test func theFreeAreaIsTheWidestStripPlacedWindowsLeave() {
        let v = ultrawide.visibleFrame
        let pinned = [Rect(x: 0, y: 30, width: 1700, height: 1380), Rect(x: 4500, y: 200, width: 620, height: 400)]
        let free = ZoneGenerator.freeArea(in: v, avoiding: pinned)
        #expect(near(free.x, 1700) && near(free.maxX, 4500) && near(free.height, 1380))
    }

    @Test func nothingPlacedLeavesTheWholeDisplayFree() {
        #expect(ZoneGenerator.freeArea(in: ultrawide.visibleFrame, avoiding: []) == ultrawide.visibleFrame)
    }

    /// The independent oracle: whatever the display and count, zones never overlap,
    /// stay inside, and are big enough to work in.
    @Test func everyLayoutIsUsableOnEveryDisplay() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<600 {
            let w = Double.random(in: 1000...6000, using: &rng), h = Double.random(in: 800...2200, using: &rng)
            let d = Display(index: 0, visibleFrame: Rect(x: 0, y: 25, width: w, height: h))
            let n = Int.random(in: 1...12, using: &rng)
            let weights = (0..<n).map { _ in Double.random(in: 0...30, using: &rng) }
            let f = frames(n, weights, on: d)
            #expect(!f.isEmpty && f.count <= n)
            for (i, a) in f.enumerated() {
                #expect(a.width >= ZonePlanner.minimumWidth - 0.5 && a.height >= ZonePlanner.minimumHeight - 0.5,
                        "zone \(i) is \(a) on \(w)×\(h) for \(n)")
                #expect(a.x >= -0.5 && a.maxX <= w + 0.5 && a.y >= 24.5 && a.maxY <= h + 25.5)
                for b in f[(i + 1)...] {
                    let ox = min(a.maxX, b.maxX) - max(a.x, b.x), oy = min(a.maxY, b.maxY) - max(a.y, b.y)
                    #expect(!(ox > 0.5 && oy > 0.5), "\(a) overlaps \(b) on \(w)×\(h) for \(n)")
                }
            }
        }
    }
}

// The user, 2026-10-12, again: "should never try and squeeze 3 windows in a column but you still are".
// The rule lived in the model layout code only; with windows kept in place, the strip left over was arranged
// by ZoneGenerator, which stacked as many as fit tall: three in 1410 pt.
@Suite struct NeverThreeStackedTests {
    @Test func noColumnEverHoldsMoreThanTwo() {
        let shapes = [Rect(x: 0, y: 30, width: 5120, height: 1410), Rect(x: 0, y: 30, width: 1512, height: 915),
                      Rect(x: 0, y: 0, width: 1080, height: 1920), Rect(x: 1700, y: 30, width: 1700, height: 1410),
                      Rect(x: 0, y: 30, width: 900, height: 1410), Rect(x: 0, y: 30, width: 2560, height: 1410)]
        for v in shapes {
            let d = Display(index: 0, visibleFrame: v)
            // The whole display, and a tall strip of it, as the room kept windows leave.
            for (n, within) in (1...12).flatMap({ n in [(n, Rect?.none), (n, Rect(x: v.x, y: v.y, width: min(v.width, 1269), height: v.height))] }) {
                let zones = ZoneGenerator.layout(count: n, weights: [], on: d, within: within).zones.map { $0.frame(in: d) }
                // As the person sees it, on any shape: windows on top of each other share an x-span.
                // (The first version swapped axes for a tall area and passed three stacked, 2026-10-12.)
                for z in zones {
                    let together = zones.filter { o in o.x < z.maxX - 1 && z.x < o.maxX - 1 }
                    #expect(together.count <= ZonePlanner.maxStack, "\(n) windows on \(Int(v.width))×\(Int(v.height)): \(together.count) stacked")
                }
            }
        }
    }
}

