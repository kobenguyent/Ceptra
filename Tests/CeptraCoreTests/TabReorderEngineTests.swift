import XCTest
@testable import CeptraCore

final class TabReorderEngineTests: XCTestCase {
    func testSlotFramesComputesExactContiguousPositions() {
        let slots = TabReorderEngine.slotFrames(
            widths: [120, 125, 135, 110],
            spacing: 3,
            leadingPadding: 4
        )

        XCTAssertEqual(slots.count, 4)
        XCTAssertEqual(slots[0], TabSlotFrame(index: 0, minX: 4, width: 120))
        XCTAssertEqual(slots[1], TabSlotFrame(index: 1, minX: 127, width: 125))
        XCTAssertEqual(slots[2], TabSlotFrame(index: 2, minX: 255, width: 135))
        XCTAssertEqual(slots[3], TabSlotFrame(index: 3, minX: 393, width: 110))
    }

    func testMoveReordersValidIndicesAndClampsOutOfRangeTargets() {
        var tabs = ["a", "b", "c", "d"]

        XCTAssertTrue(TabReorderEngine.move(&tabs, fromIndex: 3, toIndex: 1))
        XCTAssertEqual(tabs, ["a", "d", "b", "c"])

        XCTAssertTrue(TabReorderEngine.move(&tabs, fromIndex: 0, toIndex: 99))
        XCTAssertEqual(tabs, ["d", "b", "c", "a"])

        XCTAssertTrue(TabReorderEngine.move(&tabs, fromIndex: 2, toIndex: -5))
        XCTAssertEqual(tabs, ["c", "d", "b", "a"])

        // No-op when same index or invalid source index
        XCTAssertFalse(TabReorderEngine.move(&tabs, fromIndex: 1, toIndex: 1))
        XCTAssertFalse(TabReorderEngine.move(&tabs, fromIndex: -1, toIndex: 2))
        XCTAssertFalse(TabReorderEngine.move(&tabs, fromIndex: 10, toIndex: 0))
        XCTAssertEqual(tabs, ["c", "d", "b", "a"])
    }

    func testDraggingLeftCrossesNeighborMidpointAndDoesNotOscillate() {
        let widths = [120.0, 125.0, 135.0, 110.0]
        let spacing = 3.0
        // Origin slot 3 starts at 389 (0..120, 123..248, 251..386, 389..499).
        // Slot 2 midpoint is 251 + 67.5 = 318.5. With hysteresis 4, swap triggers when visualMinX < 314.5.
        let beforeSwap = TabReorderEngine.targetIndex(
            forOriginIndex: 3,
            currentTargetIndex: 3,
            translationX: -70, // visualMinX = 319 > 314.5
            widths: widths,
            spacing: spacing
        )
        XCTAssertEqual(beforeSwap, 3)

        let afterSwap = TabReorderEngine.targetIndex(
            forOriginIndex: 3,
            currentTargetIndex: 3,
            translationX: -76, // visualMinX = 313 < 314.5
            widths: widths,
            spacing: spacing
        )
        XCTAssertEqual(afterSwap, 2)

        // Immediately re-evaluating at the exact same translation must remain stable (no oscillation)
        let stabilized = TabReorderEngine.targetIndex(
            forOriginIndex: 3,
            currentTargetIndex: afterSwap,
            translationX: -76,
            widths: widths,
            spacing: spacing
        )
        XCTAssertEqual(stabilized, 2)
    }

    func testExtremeVariableWidthTabsNeverOscillateInEitherDirection() {
        // 60pt narrow tab next to 280pt wide tab
        let widths = [60.0, 280.0]
        let spacing = 3.0

        // Drag wide tab (slot 1: 63..343) left across narrow tab (slot 0: 0..60, midX = 30)
        // Swap triggers when visualMinX < 30 - 4 = 26 -> translationX < -37
        let wideDraggedLeft = TabReorderEngine.targetIndex(
            forOriginIndex: 1,
            currentTargetIndex: 1,
            translationX: -38,
            widths: widths,
            spacing: spacing
        )
        XCTAssertEqual(wideDraggedLeft, 0)

        // Re-evaluating at same translation AND slight +/- 2pt jitter must NOT snap back to 1
        for jitter in [-40.0, -38.0, -36.0] {
            let stable = TabReorderEngine.targetIndex(
                forOriginIndex: 1,
                currentTargetIndex: 0,
                translationX: jitter,
                widths: widths,
                spacing: spacing
            )
            XCTAssertEqual(stable, 0, "Wide tab oscillated at translation \(jitter)")
        }

        // Now drag narrow tab (slot 0: 0..60) right across wide tab (slot 1: 63..343, midX = 203)
        // Swap triggers when visualMaxX > 203 + 4 = 207 -> 60 + translationX > 207 -> translationX > 147
        let narrowDraggedRight = TabReorderEngine.targetIndex(
            forOriginIndex: 0,
            currentTargetIndex: 0,
            translationX: 148,
            widths: widths,
            spacing: spacing
        )
        XCTAssertEqual(narrowDraggedRight, 1)

        // Must stay at 1 without oscillating back to 0
        for jitter in [146.0, 148.0, 150.0] {
            let stable = TabReorderEngine.targetIndex(
                forOriginIndex: 0,
                currentTargetIndex: 1,
                translationX: jitter,
                widths: widths,
                spacing: spacing
            )
            XCTAssertEqual(stable, 1, "Narrow tab oscillated at translation \(jitter)")
        }
    }

    func testFastDragJumpsMultipleTabsInSingleUpdate() {
        let widths = [100.0, 100.0, 100.0, 100.0]
        let spacing = 3.0

        // Flick slot 0 all the way past slot 3 in one jump
        let targetRight = TabReorderEngine.targetIndex(
            forOriginIndex: 0,
            currentTargetIndex: 0,
            translationX: 320,
            widths: widths,
            spacing: spacing
        )
        XCTAssertEqual(targetRight, 3)

        // Flick slot 3 all the way past slot 0 in one jump
        let targetLeft = TabReorderEngine.targetIndex(
            forOriginIndex: 3,
            currentTargetIndex: 3,
            translationX: -320,
            widths: widths,
            spacing: spacing
        )
        XCTAssertEqual(targetLeft, 0)
    }

    func testSiblingDisplacementsMatchPreviewSlotShift() {
        let draggedWidth = 110.0
        let spacing = 3.0

        // Dragging index 3 -> target 1 shifts indices 1 and 2 right by +(110 + 3) = +113
        XCTAssertEqual(
            TabReorderEngine.displacement(forOriginalIndex: 0, originIndex: 3, targetIndex: 1, draggedWidth: draggedWidth, spacing: spacing),
            0
        )
        XCTAssertEqual(
            TabReorderEngine.displacement(forOriginalIndex: 1, originIndex: 3, targetIndex: 1, draggedWidth: draggedWidth, spacing: spacing),
            113
        )
        XCTAssertEqual(
            TabReorderEngine.displacement(forOriginalIndex: 2, originIndex: 3, targetIndex: 1, draggedWidth: draggedWidth, spacing: spacing),
            113
        )
        XCTAssertEqual(
            TabReorderEngine.displacement(forOriginalIndex: 3, originIndex: 3, targetIndex: 1, draggedWidth: draggedWidth, spacing: spacing),
            0
        )

        // Dragging index 0 -> target 2 shifts indices 1 and 2 left by -(110 + 3) = -113
        XCTAssertEqual(
            TabReorderEngine.displacement(forOriginalIndex: 1, originIndex: 0, targetIndex: 2, draggedWidth: draggedWidth, spacing: spacing),
            -113
        )
        XCTAssertEqual(
            TabReorderEngine.displacement(forOriginalIndex: 2, originIndex: 0, targetIndex: 2, draggedWidth: draggedWidth, spacing: spacing),
            -113
        )
        XCTAssertEqual(
            TabReorderEngine.displacement(forOriginalIndex: 3, originIndex: 0, targetIndex: 2, draggedWidth: draggedWidth, spacing: spacing),
            0
        )
    }

    func testClampedTranslationAppliesSoftRubberBandAtRailEdges() {
        let widths = [100.0, 120.0, 80.0]
        let spacing = 3.0
        // Slots: [0..100], [103..223], [226..306]. Total width = 306.
        // Origin 0: minT = 0, maxT = (306 - 100) - 0 = 206.
        XCTAssertEqual(
            TabReorderEngine.clampedTranslation(rawTranslation: 50, originIndex: 0, widths: widths, spacing: spacing, maxOverscroll: 8),
            50
        )
        // Far past left edge clamps at -8
        XCTAssertEqual(
            TabReorderEngine.clampedTranslation(rawTranslation: -200, originIndex: 0, widths: widths, spacing: spacing, maxOverscroll: 8),
            -8
        )
        // Slightly past left edge rubber-bands at 0.25x
        XCTAssertEqual(
            TabReorderEngine.clampedTranslation(rawTranslation: -12, originIndex: 0, widths: widths, spacing: spacing, maxOverscroll: 8),
            -3
        )
        // Far past right edge clamps at 206 + 8 = 214
        XCTAssertEqual(
            TabReorderEngine.clampedTranslation(rawTranslation: 500, originIndex: 0, widths: widths, spacing: spacing, maxOverscroll: 8),
            214
        )
    }

    func testTargetSlotMinXMatchesPostMoveLayout() {
        let widths = [120.0, 125.0, 135.0, 110.0]
        let spacing = 3.0
        let padding = 4.0

        // Moving slot 3 (width 110) to index 1 yields [120, 110, 125, 135]
        // Slot 1 minX = 4 + 120 + 3 = 127
        let targetMinX = TabReorderEngine.targetSlotMinX(
            originIndex: 3,
            targetIndex: 1,
            widths: widths,
            spacing: spacing,
            leadingPadding: padding
        )
        XCTAssertEqual(targetMinX, 127.0)
    }

    func testBatchCloseActionsMaintainExpectedTabsClosedListAndActiveTab() {
        struct MockTab: Equatable {
            let id: String
            let dirty: Bool
        }

        let tabs = [
            MockTab(id: "a", dirty: false),
            MockTab(id: "b", dirty: true),
            MockTab(id: "c", dirty: false),
            MockTab(id: "d", dirty: true),
            MockTab(id: "e", dirty: false)
        ]

        // 1. Close single active tab selects previous neighbor
        let singleActive = TabReorderEngine.applyClose(tabs, activeID: "c", action: .single(id: "c"), id: \.id, isDirty: \.dirty)
        XCTAssertEqual(singleActive.remaining.map(\.id), ["a", "b", "d", "e"])
        XCTAssertEqual(singleActive.closed.map(\.id), ["c"])
        XCTAssertEqual(singleActive.nextActiveID, "b")

        // 2. Close single inactive tab keeps current active tab
        let singleInactive = TabReorderEngine.applyClose(tabs, activeID: "d", action: .single(id: "a"), id: \.id, isDirty: \.dirty)
        XCTAssertEqual(singleInactive.remaining.map(\.id), ["b", "c", "d", "e"])
        XCTAssertEqual(singleInactive.closed.map(\.id), ["a"])
        XCTAssertEqual(singleInactive.nextActiveID, "d")

        // 3. Close Others keeps only anchor and activates it
        let others = TabReorderEngine.applyClose(tabs, activeID: "a", action: .others(keepingID: "c"), id: \.id, isDirty: \.dirty)
        XCTAssertEqual(others.remaining.map(\.id), ["c"])
        XCTAssertEqual(others.closed.map(\.id), ["a", "b", "d", "e"])
        XCTAssertEqual(others.nextActiveID, "c")

        // 4. Close Tabs to the Right preserves active if left of anchor, or focuses anchor if active was closed
        let rightKeepActive = TabReorderEngine.applyClose(tabs, activeID: "b", action: .toRight(ofID: "c"), id: \.id, isDirty: \.dirty)
        XCTAssertEqual(rightKeepActive.remaining.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(rightKeepActive.closed.map(\.id), ["d", "e"])
        XCTAssertEqual(rightKeepActive.nextActiveID, "b")

        let rightClosedActive = TabReorderEngine.applyClose(tabs, activeID: "e", action: .toRight(ofID: "c"), id: \.id, isDirty: \.dirty)
        XCTAssertEqual(rightClosedActive.remaining.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(rightClosedActive.nextActiveID, "c")

        // No-op when anchor is already rightmost
        let rightNoOp = TabReorderEngine.applyClose(tabs, activeID: "b", action: .toRight(ofID: "e"), id: \.id, isDirty: \.dirty)
        XCTAssertEqual(rightNoOp.remaining.map(\.id), ["a", "b", "c", "d", "e"])
        XCTAssertTrue(rightNoOp.closed.isEmpty)
        XCTAssertEqual(rightNoOp.nextActiveID, "b")

        // 5. Close Tabs to the Left preserves active if right of anchor, or focuses anchor if active was closed
        let leftKeepActive = TabReorderEngine.applyClose(tabs, activeID: "d", action: .toLeft(ofID: "c"), id: \.id, isDirty: \.dirty)
        XCTAssertEqual(leftKeepActive.remaining.map(\.id), ["c", "d", "e"])
        XCTAssertEqual(leftKeepActive.closed.map(\.id), ["a", "b"])
        XCTAssertEqual(leftKeepActive.nextActiveID, "d")

        let leftClosedActive = TabReorderEngine.applyClose(tabs, activeID: "a", action: .toLeft(ofID: "c"), id: \.id, isDirty: \.dirty)
        XCTAssertEqual(leftClosedActive.remaining.map(\.id), ["c", "d", "e"])
        XCTAssertEqual(leftClosedActive.nextActiveID, "c")

        // No-op when anchor is already leftmost
        let leftNoOp = TabReorderEngine.applyClose(tabs, activeID: "d", action: .toLeft(ofID: "a"), id: \.id, isDirty: \.dirty)
        XCTAssertTrue(leftNoOp.closed.isEmpty)

        // 6. Close Saved Only keeps dirty tabs and selects nearest surviving tab when active was clean
        let savedOnly = TabReorderEngine.applyClose(tabs, activeID: "c", action: .savedOnly, id: \.id, isDirty: \.dirty)
        XCTAssertEqual(savedOnly.remaining.map(\.id), ["b", "d"])
        XCTAssertEqual(savedOnly.closed.map(\.id), ["a", "c", "e"])
        XCTAssertEqual(savedOnly.nextActiveID, "b")

        let savedOnlyKeepDirtyActive = TabReorderEngine.applyClose(tabs, activeID: "d", action: .savedOnly, id: \.id, isDirty: \.dirty)
        XCTAssertEqual(savedOnlyKeepDirtyActive.nextActiveID, "d")

        // 7. Close All clears everything
        let allClosed = TabReorderEngine.applyClose(tabs, activeID: "b", action: .all, id: \.id, isDirty: \.dirty)
        XCTAssertTrue(allClosed.remaining.isEmpty)
        XCTAssertEqual(allClosed.closed.map(\.id), ["a", "b", "c", "d", "e"])
        XCTAssertNil(allClosed.nextActiveID)
    }

    func testDisambiguatingParentHintsResolvesDuplicateFilenamesMinimalDepth() {
        let hints = TabReorderEngine.disambiguatingParentHints(
            names: ["login_test.ts", "login_test.ts", "home_page.ts", "config.ts", "config.ts"],
            relativePaths: [
                "tests/web/login_test.ts",
                "tests/api/login_test.ts",
                "pages/home_page.ts",
                "packages/web/src/config.ts",
                "packages/mobile/src/config.ts"
            ]
        )

        XCTAssertEqual(hints, ["web", "api", nil, "web/src", "mobile/src"])
    }
}
