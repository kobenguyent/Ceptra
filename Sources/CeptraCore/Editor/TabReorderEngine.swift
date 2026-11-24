import Foundation

/// Layout geometry for a single tab slot along the horizontal tab rail.
public struct TabSlotFrame: Equatable, Sendable {
    public let index: Int
    public let minX: Double
    public let width: Double

    public init(index: Int, minX: Double, width: Double) {
        self.index = index
        self.minX = minX
        self.width = max(0, width)
    }

    public var maxX: Double { minX + width }
    public var midX: Double { minX + width * 0.5 }
}

/// Batch close actions supported by the editor tab bar context menu, overflow menu, and File menu.
public enum TabBatchCloseAction: Equatable, Sendable {
    case single(id: String)
    case others(keepingID: String)
    case toRight(ofID: String)
    case toLeft(ofID: String)
    case savedOnly
    case all
}

/// Deterministic outcome of closing one or more editor tabs.
public struct TabBatchCloseResult<T> {
    public let remaining: [T]
    public let closed: [T]
    public let nextActiveID: String?

    public init(remaining: [T], closed: [T], nextActiveID: String?) {
        self.remaining = remaining
        self.closed = closed
        self.nextActiveID = nextActiveID
    }
}

/// Pure, oscillation-free geometry and mutation engine for horizontal drag-to-reorder tab bars.
public enum TabReorderEngine {
    /// Computes deterministic horizontal slot frames for an ordered list of tab widths.
    public static func slotFrames(
        widths: [Double],
        spacing: Double,
        leadingPadding: Double = 0
    ) -> [TabSlotFrame] {
        var result: [TabSlotFrame] = []
        result.reserveCapacity(widths.count)
        var cursor = leadingPadding
        let safeSpacing = max(0, spacing)

        for (index, rawWidth) in widths.enumerated() {
            let width = max(0, rawWidth)
            result.append(TabSlotFrame(index: index, minX: cursor, width: width))
            cursor += width + safeSpacing
        }
        return result
    }

    /// Clamps a raw horizontal drag translation to the tab rail boundaries with optional soft rubber-banding.
    public static func clampedTranslation(
        rawTranslation: Double,
        originIndex: Int,
        widths: [Double],
        spacing: Double,
        maxOverscroll: Double = 8.0
    ) -> Double {
        guard widths.count > 1, widths.indices.contains(originIndex) else {
            return 0
        }

        let slots = slotFrames(widths: widths, spacing: spacing)
        guard let firstSlot = slots.first, let lastSlot = slots.last else {
            return 0
        }
        let originSlot = slots[originIndex]
        let minTranslation = firstSlot.minX - originSlot.minX
        let maxTranslation = (lastSlot.maxX - originSlot.width) - originSlot.minX
        let overscrollCap = max(0, maxOverscroll)

        if rawTranslation < minTranslation {
            let excess = minTranslation - rawTranslation
            return minTranslation - min(overscrollCap, excess * 0.25)
        }
        if rawTranslation > maxTranslation {
            let excess = rawTranslation - maxTranslation
            return maxTranslation + min(overscrollCap, excess * 0.25)
        }
        return rawTranslation
    }

    /// Computes the next target slot index for a dragged tab using leading/trailing edge crossover
    /// against neighbor midpoints in the current preview order.
    ///
    /// Because swapping left requires `visualMinX < leftNeighbor.midX - h` and the reverse right swap
    /// requires `visualMaxX > newRightNeighbor.midX + h`, the deadband after any swap is strictly
    /// `spacing + 2 * h > 0` for all positive tab widths—preventing oscillation across arbitrary width ratios.
    public static func targetIndex(
        forOriginIndex originIndex: Int,
        currentTargetIndex: Int,
        translationX: Double,
        widths: [Double],
        spacing: Double,
        hysteresis: Double = 4.0
    ) -> Int {
        guard widths.count > 1, widths.indices.contains(originIndex) else {
            return originIndex
        }

        let originalSlots = slotFrames(widths: widths, spacing: spacing)
        let originSlot = originalSlots[originIndex]
        let visualMinX = originSlot.minX + translationX
        let visualMaxX = visualMinX + originSlot.width

        var target = min(max(currentTargetIndex, 0), widths.count - 1)
        let safeHysteresis = max(0, hysteresis)

        // Step left while the dragged tab's leading edge crosses its left neighbor's midpoint.
        while target > 0 {
            let previewSlots = previewSlotFrames(
                widths: widths,
                originIndex: originIndex,
                targetIndex: target,
                spacing: spacing
            )
            let leftNeighbor = previewSlots[target - 1]
            let margin = min(safeHysteresis, leftNeighbor.width * 0.2)
            if visualMinX < leftNeighbor.midX - margin {
                target -= 1
            } else {
                break
            }
        }

        // Step right while the dragged tab's trailing edge crosses its right neighbor's midpoint.
        while target < widths.count - 1 {
            let previewSlots = previewSlotFrames(
                widths: widths,
                originIndex: originIndex,
                targetIndex: target,
                spacing: spacing
            )
            let rightNeighbor = previewSlots[target + 1]
            let margin = min(safeHysteresis, rightNeighbor.width * 0.2)
            if visualMaxX > rightNeighbor.midX + margin {
                target += 1
            } else {
                break
            }
        }

        return target
    }

    /// Computes the horizontal visual offset for a non-dragged sibling tab during a live drag preview.
    public static func displacement(
        forOriginalIndex index: Int,
        originIndex: Int,
        targetIndex: Int,
        draggedWidth: Double,
        spacing: Double
    ) -> Double {
        guard index != originIndex, originIndex != targetIndex else {
            return 0
        }
        let step = max(0, draggedWidth) + max(0, spacing)
        if targetIndex < originIndex {
            return (targetIndex ..< originIndex).contains(index) ? step : 0
        } else {
            return ((originIndex + 1) ... targetIndex).contains(index) ? -step : 0
        }
    }

    /// Computes the exact resting `minX` for the dragged tab once placed at `targetIndex`.
    public static func targetSlotMinX(
        originIndex: Int,
        targetIndex: Int,
        widths: [Double],
        spacing: Double,
        leadingPadding: Double = 0
    ) -> Double {
        guard !widths.isEmpty, widths.indices.contains(originIndex) else {
            return leadingPadding
        }
        let clampedTarget = min(max(targetIndex, 0), widths.count - 1)
        let previewSlots = previewSlotFrames(
            widths: widths,
            originIndex: originIndex,
            targetIndex: clampedTarget,
            spacing: spacing,
            leadingPadding: leadingPadding
        )
        return previewSlots[clampedTarget].minX
    }

    /// Moves an element in place from `fromIndex` to `toIndex`, clamping `toIndex` into valid bounds.
    /// Returns `true` if the array order changed.
    @discardableResult
    public static func move<T>(_ items: inout [T], fromIndex: Int, toIndex: Int) -> Bool {
        guard items.indices.contains(fromIndex) else { return false }
        let clampedTarget = min(max(toIndex, 0), items.count - 1)
        guard fromIndex != clampedTarget else { return false }
        let item = items.remove(at: fromIndex)
        items.insert(item, at: clampedTarget)
        return true
    }

    /// Computes the remaining tabs, closed tabs, and deterministic next active tab ID for any tab close action.
    public static func applyClose<T>(
        _ items: [T],
        activeID: String?,
        action: TabBatchCloseAction,
        id: (T) -> String,
        isDirty: (T) -> Bool = { _ in false }
    ) -> TabBatchCloseResult<T> {
        guard !items.isEmpty else {
            return TabBatchCloseResult(remaining: [], closed: [], nextActiveID: nil)
        }

        switch action {
        case .single(let targetID):
            guard let idx = items.firstIndex(where: { id($0) == targetID }) else {
                return TabBatchCloseResult(remaining: items, closed: [], nextActiveID: activeID)
            }
            var remaining = items
            let removed = remaining.remove(at: idx)
            let nextActive: String?
            if activeID == targetID {
                nextActive = remaining.isEmpty ? nil : id(remaining[max(0, idx - 1)])
            } else {
                nextActive = activeID
            }
            return TabBatchCloseResult(remaining: remaining, closed: [removed], nextActiveID: nextActive)

        case .others(let keepingID):
            guard let keepIdx = items.firstIndex(where: { id($0) == keepingID }) else {
                return TabBatchCloseResult(remaining: items, closed: [], nextActiveID: activeID)
            }
            let kept = items[keepIdx]
            let closed = items.enumerated().compactMap { $0.offset == keepIdx ? nil : $0.element }
            return TabBatchCloseResult(remaining: [kept], closed: closed, nextActiveID: keepingID)

        case .toRight(let anchorID):
            guard let anchorIdx = items.firstIndex(where: { id($0) == anchorID }) else {
                return TabBatchCloseResult(remaining: items, closed: [], nextActiveID: activeID)
            }
            guard anchorIdx < items.count - 1 else {
                return TabBatchCloseResult(remaining: items, closed: [], nextActiveID: activeID)
            }
            let remaining = Array(items[...anchorIdx])
            let closed = Array(items[(anchorIdx + 1)...])
            let activeStillPresent = activeID.map { aid in remaining.contains(where: { id($0) == aid }) } ?? false
            let nextActive = activeStillPresent ? activeID : anchorID
            return TabBatchCloseResult(remaining: remaining, closed: closed, nextActiveID: nextActive)

        case .toLeft(let anchorID):
            guard let anchorIdx = items.firstIndex(where: { id($0) == anchorID }) else {
                return TabBatchCloseResult(remaining: items, closed: [], nextActiveID: activeID)
            }
            guard anchorIdx > 0 else {
                return TabBatchCloseResult(remaining: items, closed: [], nextActiveID: activeID)
            }
            let closed = Array(items[..<anchorIdx])
            let remaining = Array(items[anchorIdx...])
            let activeStillPresent = activeID.map { aid in remaining.contains(where: { id($0) == aid }) } ?? false
            let nextActive = activeStillPresent ? activeID : anchorID
            return TabBatchCloseResult(remaining: remaining, closed: closed, nextActiveID: nextActive)

        case .savedOnly:
            var remaining: [T] = []
            var closed: [T] = []
            let oldActiveIdx = activeID.flatMap { aid in items.firstIndex(where: { id($0) == aid }) }
            var nearestSurvivingAtOrBeforeActive: String? = nil

            for (idx, item) in items.enumerated() {
                if isDirty(item) {
                    remaining.append(item)
                    if let oldActiveIdx, idx <= oldActiveIdx {
                        nearestSurvivingAtOrBeforeActive = id(item)
                    }
                } else {
                    closed.append(item)
                }
            }
            let activeStillPresent = activeID.map { aid in remaining.contains(where: { id($0) == aid }) } ?? false
            let nextActive: String?
            if activeStillPresent {
                nextActive = activeID
            } else {
                nextActive = nearestSurvivingAtOrBeforeActive ?? remaining.first.map(id)
            }
            return TabBatchCloseResult(remaining: remaining, closed: closed, nextActiveID: nextActive)

        case .all:
            return TabBatchCloseResult(remaining: [], closed: items, nextActiveID: nil)
        }
    }

    /// Computes minimal parent directory hints for tabs whose filenames collide (e.g. `tests/web/login_test.ts`
    /// and `tests/api/login_test.ts` yield `"web"` and `"api"`). Unique filenames receive `nil`.
    public static func disambiguatingParentHints(names: [String], relativePaths: [String]) -> [String?] {
        guard names.count == relativePaths.count else {
            return Array(repeating: nil, count: names.count)
        }
        var groupedIndices: [String: [Int]] = [:]
        for (idx, name) in names.enumerated() {
            groupedIndices[name.lowercased(), default: []].append(idx)
        }

        var hints: [String?] = Array(repeating: nil, count: names.count)
        for (_, indices) in groupedIndices where indices.count > 1 {
            let parentComponents: [[String]] = indices.map { idx in
                let raw = relativePaths[idx].replacingOccurrences(of: "\\", with: "/")
                var comps = raw.split(separator: "/").map(String.init)
                if !comps.isEmpty { comps.removeLast() }
                return comps
            }
            let maxDepth = parentComponents.map(\.count).max() ?? 0
            guard maxDepth > 0 else { continue }

            var chosenDepth = maxDepth
            for depth in 1...maxDepth {
                let candidates = parentComponents.map { comps -> String in
                    if comps.isEmpty { return "" }
                    return comps.suffix(depth).joined(separator: "/")
                }
                if Set(candidates).count == candidates.count {
                    chosenDepth = depth
                    break
                }
            }

            for (offset, idx) in indices.enumerated() {
                let comps = parentComponents[offset]
                let hint = comps.suffix(chosenDepth).joined(separator: "/")
                hints[idx] = hint.isEmpty ? nil : hint
            }
        }
        return hints
    }

    private static func previewSlotFrames(
        widths: [Double],
        originIndex: Int,
        targetIndex: Int,
        spacing: Double,
        leadingPadding: Double = 0
    ) -> [TabSlotFrame] {
        var previewWidths = widths
        move(&previewWidths, fromIndex: originIndex, toIndex: targetIndex)
        return slotFrames(widths: previewWidths, spacing: spacing, leadingPadding: leadingPadding)
    }
}
