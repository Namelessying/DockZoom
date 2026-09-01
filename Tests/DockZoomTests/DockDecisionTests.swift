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

    func testBackgroundAXLessApplicationActivatesInsteadOfHiding() {
        let snapshot = DockExecutionSnapshot(
            isActive: false,
            isHidden: false,
            axVisibleCount: 0,
            axMinimizedCount: 0,
            cgVisibleCount: 1
        )
        XCTAssertEqual(DockDecision.executionAction(for: snapshot), .activate)
    }

    func testActiveAXLessApplicationUsesReversibleHideFallback() {
        let snapshot = DockExecutionSnapshot(
            isActive: true,
            isHidden: false,
            axVisibleCount: 0,
            axMinimizedCount: 0,
            cgVisibleCount: 1
        )
        XCTAssertEqual(DockDecision.executionAction(for: snapshot), .hideFallback)
    }

    func testHiddenAXLessApplicationUnhidesBeforeActivation() {
        let snapshot = DockExecutionSnapshot(
            isActive: false,
            isHidden: true,
            axVisibleCount: 0,
            axMinimizedCount: 0,
            cgVisibleCount: 0
        )
        XCTAssertEqual(DockDecision.executionAction(for: snapshot), .unhideActivate)
    }

    func testActiveApplicationWithAXWindowsMinimizes() {
        let snapshot = DockExecutionSnapshot(
            isActive: true,
            isHidden: false,
            axVisibleCount: 2,
            axMinimizedCount: 0,
            cgVisibleCount: 2
        )
        XCTAssertEqual(DockDecision.executionAction(for: snapshot), .minimize)
    }

    func testApplicationWithOnlyMinimizedAXWindowsRestores() {
        let snapshot = DockExecutionSnapshot(
            isActive: false,
            isHidden: false,
            axVisibleCount: 0,
            axMinimizedCount: 2,
            cgVisibleCount: 0
        )
        XCTAssertEqual(DockDecision.executionAction(for: snapshot), .restore)
    }
}
