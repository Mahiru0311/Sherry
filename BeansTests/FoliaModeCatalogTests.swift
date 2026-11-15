import XCTest
@testable import Sherry

// The port ships 5 modes; anything else (old saves, upstream names) falls
// back to .still explicitly — never a silent replacement, never a crash.
final class FoliaModeCatalogTests: XCTestCase {
    func testRegistryContainsAllDistinctPortedModes() {
        XCTAssertEqual(FoliaVisualizerMode.allCases.count, 5)
        XCTAssertEqual(Set(FoliaVisualizerMode.allCases.map(\.rawValue)).count, 5)
        XCTAssertEqual(FoliaVisualizerMode.ordered.first, .lumiere)
    }

    func testUnimplementedModesFallBackToStill() {
        XCTAssertEqual(FoliaPreferences.availableMode(rawValue: "classic"), .classic)
        XCTAssertEqual(FoliaPreferences.availableMode(rawValue: "sonnet"), .still)
        XCTAssertEqual(FoliaPreferences.availableMode(rawValue: "mod:example:lyrics"), .still)
        XCTAssertEqual(FoliaPreferences.availableMode(rawValue: "still"), .still)
    }
}
