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
}
