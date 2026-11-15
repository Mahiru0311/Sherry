import XCTest
@testable import Sherry

final class FoliaClassicMotionTests: XCTestCase {
    func testWordLookaheadEndpointsAndBackwardSeek() {
        let word = FoliaWord(id: "word", text: "hello", startTime: 2, endTime: 3)
        XCTAssertEqual(FoliaClassicMotion.state(word: word, time: 1.84), .waiting)
        XCTAssertEqual(FoliaClassicMotion.state(word: word, time: 1.85), .active)
        XCTAssertEqual(FoliaClassicMotion.state(word: word, time: 3), .active)
        XCTAssertEqual(FoliaClassicMotion.state(word: word, time: 3.01), .passed)
        XCTAssertEqual(FoliaClassicMotion.state(word: word, time: 1), .waiting)
        XCTAssertEqual(FoliaClassicMotion.state(word: word, time: .nan), .waiting)
    }

    func testGeometryUsesTheUpstreamSeedFormula() {
        // Port contract (spread 36, scale 1.15 + random * 0.35): the values
        // below are the formulas' own output for seed 12.5 / index 2,
        // verified by an independent reimplementation — the old expectations
        // (spread 20, scale 1.1 + random * 0.2) never matched this port.
        let geometry = FoliaClassicMotion.geometry(seed: 12.5, index: 2, intensity: .normal, rotationEnabled: true)
        XCTAssertEqual(geometry.x, 12.586995213539922, accuracy: 0.000001)
        XCTAssertEqual(geometry.y, -25.446505768566567, accuracy: 0.000001)
        XCTAssertEqual(geometry.scale, 1.2178353563560904, accuracy: 0.000001)
        XCTAssertEqual(geometry, FoliaClassicMotion.geometry(seed: 12.5, index: 2, intensity: .normal, rotationEnabled: true))
        let disabled = FoliaClassicMotion.geometry(seed: 12.5, index: 2, intensity: .normal, rotationEnabled: false)
        XCTAssertEqual(disabled.x, geometry.x)
        XCTAssertEqual(disabled.rotation, 0)
        XCTAssertEqual(disabled.passedRotation, 0)
    }

    func testMeasuredSpacingIncludesScaleOverflowAndOffsets() {
        let first = FoliaClassicWordGeometry(x: 10, y: 0, rotation: 0, scale: 1.2, passedRotation: 0, legacyMargin: 12.8, alignment: nil)
        let next = FoliaClassicWordGeometry(x: -5, y: 0, rotation: 0, scale: 1.1, passedRotation: 0, legacyMargin: 12.8, alignment: nil)
        XCTAssertEqual(FoliaClassicMotion.margin(width: 100, nextWidth: 80, geometry: first, next: next,
                                                 fontSize: 40, intensity: .normal, spacing: 0.7, legacy: false, interlude: false), 50.8)
        XCTAssertEqual(FoliaClassicMotion.margin(width: 100, nextWidth: 80, geometry: first, next: next,
                                                 fontSize: 40, intensity: .normal, spacing: 0.7, legacy: true, interlude: false), 12.8)
    }

    func testBreathingKeyframesAndDisabledMotion() {
        // Port contract (duration 6s, distance 20, heights [0,-1,0,0.45,0],
        // cubic-bezier easeInOut): trough values carry the 20-iteration
        // bisection residue of the easing solver (4.5000064, not 4.5).
        // The old expectations (distance 14, duration 7) never matched.
        let peak = FoliaClassicMotion.breathing(elapsed: 1.75, intensity: .normal, multiplier: 1)
        XCTAssertEqual(peak.y, -18.87738661575995, accuracy: 0.000001)
        XCTAssertEqual(peak.scale, 1.01415803996182, accuracy: 0.000001)
        let trough = FoliaClassicMotion.breathing(elapsed: 5.25, intensity: .normal, multiplier: 1)
        XCTAssertEqual(trough.y, 4.500006437301636, accuracy: 0.000001)
        XCTAssertEqual(trough.scale, 0.995999994277954, accuracy: 0.000001)
        let disabled = FoliaClassicMotion.breathing(elapsed: 1.75, intensity: .normal, multiplier: 0)
        XCTAssertEqual(disabled.y, 0)
        XCTAssertEqual(disabled.scale, 1)
        XCTAssertEqual(FoliaClassicMotion.clamp(.nan, fallback: 0.7), 0.7)
    }

    func testSubtitleFiltersInstrumentalMarkers() {
        XCTAssertFalse(FoliaClassicMotion.hasReadableText("...... // ●● —"))
        XCTAssertTrue(FoliaClassicMotion.hasReadableText("译文"))
        XCTAssertTrue(FoliaClassicMotion.hasReadableText("Verse 2"))
    }
}
