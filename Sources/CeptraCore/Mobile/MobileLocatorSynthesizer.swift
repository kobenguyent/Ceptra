import CoreGraphics
import Foundation

public enum MobileLocatorReliability: String, Codable, Equatable, Hashable, Sendable {
    case recommended = "BEST"
    case good = "ALT"
    case fallback = "TEXT"
}

public struct MobileLocatorCandidate: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { "\(strategy):\(locator)" }
    public let strategy: String
    public let locator: String
    public let reliability: MobileLocatorReliability
    public let tapSnippet: String
    public let assertSnippet: String

    public init(
        strategy: String,
        locator: String,
        reliability: MobileLocatorReliability,
        tapSnippet: String,
        assertSnippet: String
    ) {
        self.strategy = strategy
        self.locator = locator
        self.reliability = reliability
        self.tapSnippet = tapSnippet
        self.assertSnippet = assertSnippet
    }
}

public struct MobileAspectFitLayout: Equatable, Sendable {
    public let scale: Double
    public let scaledSize: CGSize
    public let originOffset: CGPoint
    public let deviceLogicalSize: CGSize

    public init(scale: Double, scaledSize: CGSize, originOffset: CGPoint, deviceLogicalSize: CGSize) {
        self.scale = scale
        self.scaledSize = scaledSize
        self.originOffset = originOffset
        self.deviceLogicalSize = deviceLogicalSize
    }
}

/// Pure, zero-dependency engine for `@codeceptjs/mobilewright` locator synthesis,
/// password `secret()` masking, multi-resolution aspect-fit layout math, and hit-testing.
public enum MobileLocatorSynthesizer {
    /// Computes the highest-priority resilient `@codeceptjs/mobilewright` locator for `node`.
    /// Never emits XPath or CSS selectors (which throw `UnsupportedLocatorError` in Mobilewright).
    public static func recommendedLocator(
        for node: MobileAccessibilityNode,
        platform: MobilePlatform
    ) -> String {
        if let testId = cleaned(node.testId), !isHostFilesystemPath(testId) {
            return "~\(testId)"
        }
        if let identifier = cleaned(node.identifier), !isHostFilesystemPath(identifier) {
            if platform == .android, let shortId = stripAndroidPackagePrefix(identifier) {
                return "#\(shortId)"
            }
            return "~\(identifier)"
        }
        if let label = cleaned(node.label), !isHostFilesystemPath(label) {
            return "~\(label)"
        }
        if let placeholder = cleaned(node.placeholder), node.isTextField {
            return placeholder
        }
        if let text = cleaned(node.text), !isHostFilesystemPath(text) {
            return text
        }
        let role = node.normalizedRole
        if role != "other" {
            return "{ role: '\(escapeJSString(role))' }"
        }
        return "~\(node.type)"
    }

    /// Returns all ranked `@codeceptjs/mobilewright` locator strategies for `node`
    /// (Accessibility ID / Test ID, Android Resource ID, Role + Name, Visible Text)
    /// so the inspector can display a state-of-the-art Appium-style "Find By" table.
    /// Never emits CSS or XPath selectors.
    public static func locatorCandidates(
        for node: MobileAccessibilityNode,
        platform: MobilePlatform
    ) -> [MobileLocatorCandidate] {
        var candidates: [MobileLocatorCandidate] = []
        var seenLocators: Set<String> = []

        func appendCandidate(strategy: String, locator: String, reliability: MobileLocatorReliability) {
            guard !locator.isEmpty, !seenLocators.contains(locator) else { return }
            seenLocators.insert(locator)
            let arg = formatLocatorArgument(locator)
            let tapSnippet: String
            if node.isTextField {
                let sampleVal = node.isLikelyPasswordField ? "secret('10203040')" : "'bob@example.com'"
                tapSnippet = "I.fillField(\(arg), \(sampleVal));"
            } else {
                tapSnippet = "I.tap(\(arg));"
            }
            let assertSnippet: String
            if let text = cleaned(node.text), locator != text {
                assertSnippet = "I.see('\(escapeJSString(text))', \(arg));"
            } else {
                assertSnippet = "I.seeElement(\(arg));"
            }
            candidates.append(MobileLocatorCandidate(
                strategy: strategy,
                locator: locator,
                reliability: reliability,
                tapSnippet: tapSnippet,
                assertSnippet: assertSnippet
            ))
        }

        if let testId = cleaned(node.testId), !isHostFilesystemPath(testId) {
            appendCandidate(strategy: "Test ID (~)", locator: "~\(testId)", reliability: .recommended)
        }
        if let identifier = cleaned(node.identifier), !isHostFilesystemPath(identifier) {
            if platform == .android, let shortId = stripAndroidPackagePrefix(identifier) {
                appendCandidate(
                    strategy: "Resource ID (#)",
                    locator: "#\(shortId)",
                    reliability: candidates.isEmpty ? .recommended : .good
                )
            } else {
                appendCandidate(
                    strategy: "Accessibility ID (~)",
                    locator: "~\(identifier)",
                    reliability: candidates.isEmpty ? .recommended : .good
                )
            }
        }
        if let label = cleaned(node.label), !isHostFilesystemPath(label) {
            appendCandidate(
                strategy: "Accessibility Label (~)",
                locator: "~\(label)",
                reliability: candidates.isEmpty ? .recommended : .good
            )
        }
        let role = node.normalizedRole
        if role != "other" && role != "window" {
            if let name = cleaned(node.label) ?? cleaned(node.text) ?? cleaned(node.placeholder) {
                appendCandidate(
                    strategy: "Role + Name",
                    locator: "{ role: '\(escapeJSString(role))', name: '\(escapeJSString(name))' }",
                    reliability: candidates.isEmpty ? .recommended : .good
                )
            } else {
                appendCandidate(
                    strategy: "Role",
                    locator: "{ role: '\(escapeJSString(role))' }",
                    reliability: .fallback
                )
            }
        }
        if let text = cleaned(node.text) {
            appendCandidate(strategy: "Visible Text", locator: text, reliability: .fallback)
        }
        if let placeholder = cleaned(node.placeholder), node.isTextField {
            appendCandidate(strategy: "Placeholder", locator: placeholder, reliability: .fallback)
        }
        if candidates.isEmpty {
            appendCandidate(strategy: "Element Type", locator: "~\(node.type)", reliability: .fallback)
        }
        return candidates
    }

    /// Synthesizes an idiomatic `@codeceptjs/mobilewright` CodeceptJS step line.
    /// Automatically wraps values entered into password/secure fields in `secret('...')` (Threat T-03).
    public static func synthesizeStepCode(
        action: MobileQuickActionKind,
        node: MobileAccessibilityNode? = nil,
        typedValue: String? = nil,
        orientation: MobileDeviceOrientation = .portrait,
        platform: MobilePlatform = .ios,
        coordinate: CGPoint? = nil
    ) -> String {
        switch action {
        case .goBack:
            return "I.goBack();"
        case .pressHome:
            return "I.pressButton('HOME');"
        case .setOrientation:
            return "I.setOrientation('\(orientation.rawValue)');"
        case .swipeUp:
            return "I.swipeUp();"
        case .swipeDown:
            return "I.swipeDown();"
        case .swipeLeft:
            return "I.swipeLeft();"
        case .swipeRight:
            return "I.swipeRight();"
        case .tapXY:
            let pt = coordinate ?? CGPoint(x: node?.bounds.centerX ?? 0, y: node?.bounds.centerY ?? 0)
            return "I.tapXY(\(Int(pt.x.rounded())), \(Int(pt.y.rounded())));"
        case .tap:
            if let node {
                let loc = formatLocatorArgument(recommendedLocator(for: node, platform: platform))
                return "I.tap(\(loc));"
            }
            if let pt = coordinate {
                return "I.tapXY(\(Int(pt.x.rounded())), \(Int(pt.y.rounded())));"
            }
            return "I.tap('');"
        case .longPress:
            guard let node else { return "I.longPress('', 1);" }
            let loc = formatLocatorArgument(recommendedLocator(for: node, platform: platform))
            return "I.longPress(\(loc), 1);"
        case .fillField:
            guard let node else { return "I.fillField('', '');" }
            let fieldLocator: String
            if let label = cleaned(node.label) {
                fieldLocator = "'\(escapeJSString(label))'"
            } else if let placeholder = cleaned(node.placeholder) {
                fieldLocator = "'\(escapeJSString(placeholder))'"
            } else {
                fieldLocator = formatLocatorArgument(recommendedLocator(for: node, platform: platform))
            }
            let rawVal = typedValue ?? (node.isLikelyPasswordField ? "10203040" : "sample@example.com")
            let escapedVal = escapeJSString(rawVal)
            if node.isLikelyPasswordField {
                return "I.fillField(\(fieldLocator), secret('\(escapedVal)'));"
            }
            return "I.fillField(\(fieldLocator), '\(escapedVal)');"
        case .see:
            guard let node else { return "I.see('');" }
            if let text = cleaned(node.text) ?? cleaned(node.value) {
                let loc = recommendedLocator(for: node, platform: platform)
                if loc != text {
                    return "I.see('\(escapeJSString(text))', \(formatLocatorArgument(loc)));"
                }
                return "I.see('\(escapeJSString(text))');"
            }
            let loc = formatLocatorArgument(recommendedLocator(for: node, platform: platform))
            return "I.seeElement(\(loc));"
        case .seeElement:
            guard let node else { return "I.seeElement('');" }
            let loc = formatLocatorArgument(recommendedLocator(for: node, platform: platform))
            return "I.seeElement(\(loc));"
        }
    }

    /// Classifies a finger/mouse drag vector in device logical coordinates into an idiomatic
    /// CodeceptJS Mobilewright swipe action (`.swipeUp`, `.swipeDown`, `.swipeLeft`, `.swipeRight`).
    public static func classifySwipeDirection(from start: CGPoint, to end: CGPoint) -> MobileQuickActionKind {
        let dx = Double(end.x - start.x)
        let dy = Double(end.y - start.y)
        if abs(dy) >= abs(dx) {
            return dy < 0 ? .swipeUp : .swipeDown
        } else {
            return dx < 0 ? .swipeLeft : .swipeRight
        }
    }

    /// Computes a balanced aspect-fit layout inside `stageSize` with guaranteed 4-edge padding
    /// across any phone or tablet resolution (`iPhone SE`, `iPhone 17 Pro`, `Pixel 8`, `iPad Pro`).
    public static func computeAspectFit(
        stageSize: CGSize,
        deviceLogicalSize: CGSize,
        padding: Double = 16.0
    ) -> MobileAspectFitLayout {
        let safeDeviceW = max(1.0, Double(deviceLogicalSize.width))
        let safeDeviceH = max(1.0, Double(deviceLogicalSize.height))
        let safePad = max(0.0, padding)

        let availW = max(80.0, Double(stageSize.width) - safePad * 2.0)
        let availH = max(80.0, Double(stageSize.height) - safePad * 2.0)

        let scale = min(availW / safeDeviceW, availH / safeDeviceH)
        let scaledW = safeDeviceW * scale
        let scaledH = safeDeviceH * scale
        let originX = (Double(stageSize.width) - scaledW) / 2.0
        let originY = (Double(stageSize.height) - scaledH) / 2.0

        return MobileAspectFitLayout(
            scale: scale,
            scaledSize: CGSize(width: scaledW, height: scaledH),
            originOffset: CGPoint(x: originX, y: originY),
            deviceLogicalSize: CGSize(width: safeDeviceW, height: safeDeviceH)
        )
    }

    /// Maps a user tap/hover point inside the scaled device canvas (0...scaledSize)
    /// back into native device logical coordinates (`0...deviceLogicalSize`).
    public static func mapCanvasPointToDevicePoint(
        _ canvasPoint: CGPoint,
        layout: MobileAspectFitLayout
    ) -> CGPoint {
        guard layout.scale > 0 else { return .zero }
        let dx = min(max(0, Double(canvasPoint.x) / layout.scale), Double(layout.deviceLogicalSize.width))
        let dy = min(max(0, Double(canvasPoint.y) / layout.scale), Double(layout.deviceLogicalSize.height))
        return CGPoint(x: dx, y: dy)
    }

    /// Maps a native accessibility node's `bounds` into scaled display coordinates
    /// inside the phone canvas (`0...scaledSize`).
    public static func mapNodeBoundsToCanvasRect(
        _ bounds: MobileNodeBounds,
        layout: MobileAspectFitLayout
    ) -> CGRect {
        CGRect(
            x: bounds.x * layout.scale,
            y: bounds.y * layout.scale,
            width: bounds.width * layout.scale,
            height: bounds.height * layout.scale
        )
    }

    /// Finds the deepest (smallest-area) visible accessibility node containing `(x, y)` in device coordinates.
    /// Prefers interactive/content controls over full-screen `window` or structural containers.
    public static func hitTestNode(
        atDevicePoint point: CGPoint,
        in roots: [MobileAccessibilityNode]
    ) -> MobileAccessibilityNode? {
        let all = roots.flatMap { $0.flattened() }
        let hits = all.filter { node in
            node.isVisible
                && node.bounds.width > 0
                && node.bounds.height > 0
                && node.bounds.contains(x: Double(point.x), y: Double(point.y))
        }
        guard !hits.isEmpty else { return nil }
        let nonWindowHits = hits.filter { $0.normalizedRole != "window" }
        let pool = nonWindowHits.isEmpty ? hits : nonWindowHits
        return pool.min { lhs, rhs in
            let lhsInteractive = lhs.normalizedRole != "other" && lhs.normalizedRole != "window"
            let rhsInteractive = rhs.normalizedRole != "other" && rhs.normalizedRole != "window"
            if abs(lhs.bounds.area - rhs.bounds.area) > 1.0 {
                return lhs.bounds.area < rhs.bounds.area
            }
            return lhsInteractive && !rhsInteractive
        }
    }

    /// Generates a clean `helpers.Mobilewright` config snippet for `codecept.conf.js`.
    public static func generateHelperConfigSnippet(
        platform: MobilePlatform,
        appId: String,
        deviceName: String?,
        deviceId: String?
    ) -> String {
        var lines: [String] = [
            "Mobilewright: {",
            "  require: '@codeceptjs/mobilewright',",
            "  platform: '\(platform.rawValue)',"
        ]
        if !appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("  app: '\(escapeJSString(appId))',")
        }
        if let deviceName, !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("  deviceName: '\(escapeJSString(deviceName))',")
        }
        if let deviceId, !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("  deviceId: '\(escapeJSString(deviceId))',")
        }
        if platform == .android {
            lines.append("  animations: 'off',")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    // MARK: - Private Helpers

    private static func cleaned(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isHostFilesystemPath(_ raw: String) -> Bool {
        raw.hasPrefix("/Users/") || raw.hasPrefix("/private/") || raw.hasPrefix("/Library/") || raw.hasPrefix("/var/")
    }

    private static func stripAndroidPackagePrefix(_ identifier: String) -> String? {
        guard let range = identifier.range(of: ":id/") else { return nil }
        let tail = String(identifier[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }

    private static func formatLocatorArgument(_ locator: String) -> String {
        if locator.hasPrefix("{") && locator.hasSuffix("}") {
            return locator
        }
        return "'\(escapeJSString(locator))'"
    }

    public static func escapeJSString(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
