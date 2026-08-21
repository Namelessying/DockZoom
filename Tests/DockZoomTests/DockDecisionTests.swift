import XCTest
@testable import DockZoom

final class DockDecisionTests: XCTestCase {
    func testMissingSnapshotPassesThrough() {
        XCTAssertEqual(DockDecision.quickAction(for: nil), .none)
    }

    func testHiddenApplicationIsUnhiddenFirst() {
        let snapshot = DockWindowSnapshot(isActive: false, isHidden: true, visibleCount: 0, minimizedCount: 2)
        XCTAssertEqual(DockDecision.quickAction(for: snapshot), .unhideActivate)
    }

    func testActiveVisibleApplicationMinimizes() {
        let snapshot = DockWindowSnapshot(isActive: true, isHidden: false, visibleCount: 2, minimizedCount: 0)
        XCTAssertEqual(DockDecision.quickAction(for: snapshot), .minimize)
    }

    func testBackgroundVisibleApplicationActivates() {
        let snapshot = DockWindowSnapshot(isActive: false, isHidden: false, visibleCount: 1, minimizedCount: 0)
        XCTAssertEqual(DockDecision.quickAction(for: snapshot), .activate)
    }

    func testOnlyMinimizedWindowsRestore() {
        let snapshot = DockWindowSnapshot(isActive: true, isHidden: false, visibleCount: 0, minimizedCount: 2)
        XCTAssertEqual(DockDecision.quickAction(for: snapshot), .restore)
    }

    func testNoWindowsPassesThrough() {
        let snapshot = DockWindowSnapshot(isActive: true, isHidden: false, visibleCount: 0, minimizedCount: 0)
        XCTAssertEqual(DockDecision.quickAction(for: snapshot), .none)
    }

    func testWindowServerFilterRejectsTransparentAndDegenerateEntries() {
        XCTAssertTrue(DockDecision.isLikelyVisibleWindow(layer: 0, alpha: 1, width: 800, height: 600))
        XCTAssertFalse(DockDecision.isLikelyVisibleWindow(layer: 1, alpha: 1, width: 800, height: 600))
        XCTAssertFalse(DockDecision.isLikelyVisibleWindow(layer: 0, alpha: 0, width: 800, height: 600))
        XCTAssertFalse(DockDecision.isLikelyVisibleWindow(layer: 0, alpha: 1, width: 1, height: 600))
    }
}
