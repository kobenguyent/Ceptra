import AppKit
import SwiftUI
import CeptraCore

enum CeptraTheme {
    // Surface palette (Minimalist Obsidian Studio)
    static let canvasBG = Color(red: 0.075, green: 0.082, blue: 0.102)
    static let sidebarBG = Color(red: 0.094, green: 0.102, blue: 0.128)
    static let panelBG = Color(red: 0.112, green: 0.122, blue: 0.152)
    static let elevatedBG = Color(red: 0.145, green: 0.158, blue: 0.195)
    static let border = Color.white.opacity(0.085)
    static let subtleBorder = Color.white.opacity(0.05)

    // Apple Liquid Glass specular rims & tints
    static let glassTopHighlight = Color.white.opacity(0.20)
    static let glassMidHighlight = Color.white.opacity(0.06)
    static let glassBottomEdge = Color.white.opacity(0.02)
    static let glassHoverOverlay = Color.white.opacity(0.055)
    static let glassActiveOverlay = Color.white.opacity(0.09)

    static var specularRimGradient: LinearGradient {
        LinearGradient(
            colors: [glassTopHighlight, glassMidHighlight, glassBottomEdge],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func accentSpecularRim(_ tint: Color) -> LinearGradient {
        LinearGradient(
            colors: [tint.opacity(0.55), tint.opacity(0.22), tint.opacity(0.10)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // Typography colors
    static let textPrimary = Color(red: 0.94, green: 0.95, blue: 0.98)
    static let textSecondary = Color(red: 0.62, green: 0.66, blue: 0.74)
    static let textMuted = Color(red: 0.44, green: 0.48, blue: 0.56)

    // Accents
    static let accent = Color(red: 0.42, green: 0.58, blue: 1.00)        // Crisp electric indigo
    static let accentWarm = Color(red: 0.98, green: 0.72, blue: 0.30)    // Warm amber
    static let success = Color(red: 0.24, green: 0.84, blue: 0.58)       // Emerald
    static let failure = Color(red: 0.96, green: 0.39, blue: 0.44)       // Coral red
    static let warning = Color(red: 0.96, green: 0.76, blue: 0.28)       // Gold
    static let violet = Color(red: 0.70, green: 0.54, blue: 0.98)        // Violet (Gherkin / Tags)
    static let cyan = Color(red: 0.30, green: 0.82, blue: 0.92)          // Network / Navigation

    static func color(for status: ExecutionStatus) -> Color {
        switch status {
        case .idle: return textMuted
        case .running: return accent
        case .passed: return success
        case .failed: return failure
        case .skipped: return warning
        case .cancelled: return textSecondary
        }
    }

    static func symbol(for status: ExecutionStatus) -> String {
        switch status {
        case .idle: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    static func color(for category: StepCategory) -> Color {
        switch category {
        case .navigation: return cyan
        case .interaction: return accent
        case .assertion: return success
        case .network: return accentWarm
        case .wait: return warning
        case .control: return violet
        case .gherkin: return violet
        case .custom: return textSecondary
        }
    }
}

struct CeptraBadge: View {
    let text: String
    var color: Color = CeptraTheme.accent
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.28), lineWidth: 0.75))
    }
}

struct StatusDotView: View {
    let status: ExecutionStatus
    var size: CGFloat = 9

    var body: some View {
        Group {
            if status == .running {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: size + 4, height: size + 4)
            } else {
                Image(systemName: CeptraTheme.symbol(for: status))
                    .font(.system(size: size + 2, weight: .semibold))
                    .foregroundStyle(CeptraTheme.color(for: status))
            }
        }
    }
}

/// Renders the bespoke Ceptra geometric prism-play icon programmatically for Dock & About branding.
enum CeptraAppIconRenderer {
    static func makeNSImage(pixelSize: Int = 512) -> NSImage? {
        let size = NSSize(width: pixelSize, height: pixelSize)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
        let s = CGFloat(pixelSize)
        let margin = s * 0.08
        let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
        let radius = rect.width * 0.225

        let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()

        let colors = [
            CGColor(red: 0.09, green: 0.11, blue: 0.17, alpha: 1.0),
            CGColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1.0)
        ] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
        }

        // Subtle radial glow behind prism
        let glowColors = [
            CGColor(red: 0.36, green: 0.56, blue: 1.0, alpha: 0.35),
            CGColor(red: 0.36, green: 0.56, blue: 1.0, alpha: 0.0)
        ] as CFArray
        if let radial = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0, 1]) {
            ctx.drawRadialGradient(
                radial,
                startCenter: CGPoint(x: s * 0.5, y: s * 0.54),
                startRadius: s * 0.04,
                endCenter: CGPoint(x: s * 0.5, y: s * 0.54),
                endRadius: s * 0.44,
                options: []
            )
        }

        // Minimalist C-arc + execution play chevron
        let center = CGPoint(x: s * 0.5, y: s * 0.5)
        let ringRadius = s * 0.255
        ctx.setLineCap(.round)
        ctx.setLineWidth(s * 0.062)
        ctx.setStrokeColor(CGColor(red: 0.44, green: 0.62, blue: 1.0, alpha: 1.0))
        ctx.addArc(
            center: center,
            radius: ringRadius,
            startAngle: CGFloat.pi * 0.24,
            endAngle: CGFloat.pi * 1.76,
            clockwise: false
        )
        ctx.strokePath()

        // Emerald verification triangle (play / pass glyph)
        let tri = CGMutablePath()
        tri.move(to: CGPoint(x: s * 0.45, y: s * 0.39))
        tri.addLine(to: CGPoint(x: s * 0.65, y: s * 0.50))
        tri.addLine(to: CGPoint(x: s * 0.45, y: s * 0.61))
        tri.closeSubpath()
        ctx.addPath(tri)
        ctx.setFillColor(CGColor(red: 0.24, green: 0.86, blue: 0.60, alpha: 1.0))
        ctx.fillPath()

        ctx.restoreGState()

        // Crisp rim highlight
        ctx.addPath(squircle)
        ctx.setLineWidth(s * 0.012)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
        ctx.strokePath()

        return image
    }
}

// MARK: - Apple Liquid Glass Motion & Surface Primitives

enum CeptraMotion {
    static let micro: Animation = .smooth(duration: 0.16, extraBounce: 0.0)
    static let snappy: Animation = .snappy(duration: 0.24, extraBounce: 0.0)
    static let panel: Animation = .smooth(duration: 0.30, extraBounce: 0.0)
    static let smooth: Animation = .smooth(duration: 0.34, extraBounce: 0.0)
    static let gentle: Animation = .smooth(duration: 0.42, extraBounce: 0.0)

    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.14) : animation
    }
}

/// Resize divider handle for custom animated split panes.
/// Pairs pure SwiftUI Liquid Glass visuals with a zero-constraint, layer-free AppKit tracking overlay
/// (`mouseDown` + `NSWindow.trackEvents` + native `NSCursor` rects) for 100% reliable 120Hz dragging,
/// instant double-click reset, boundary-aware directional resize cursors, and zero conflict with adjacent
/// `NSTextView` / `ScrollView` controls.
struct CeptraSplitResizeHandle: View {
    static let hitThickness: CGFloat = 7

    enum Axis {
        case horizontal // Vertical divider line, drags left/right
        case vertical   // Horizontal divider line, drags up/down
    }

    enum CursorDirection: Equatable {
        case both
        case onlyLeadingOrUp
        case onlyTrailingOrDown
    }

    let axis: Axis
    var cursorDirection: CursorDirection = .both
    let onDragStart: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnd: () -> Void
    var onDoubleClick: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { isHovering || isDragging }

    var body: some View {
        ZStack {
            Color.clear

            // Crisp 1pt resting seam -> glowing 2pt accent hairline on hover/drag
            Rectangle()
                .fill(
                    isDragging
                        ? CeptraTheme.accent.opacity(0.90)
                        : (isHovering ? CeptraTheme.accent.opacity(0.60) : CeptraTheme.border)
                )
                .frame(
                    width: axis == .horizontal ? (isActive ? 2 : 1) : nil,
                    height: axis == .vertical ? (isActive ? 2 : 1) : nil
                )
                .frame(
                    maxWidth: axis == .vertical ? .infinity : nil,
                    maxHeight: axis == .horizontal ? .infinity : nil
                )

            // Minimalist centered glass grip pill on hover/drag
            Capsule()
                .fill(
                    isDragging
                        ? CeptraTheme.accent
                        : CeptraTheme.textPrimary.opacity(0.75)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(isDragging ? 0.45 : 0.25), lineWidth: 0.5)
                )
                .shadow(
                    color: CeptraTheme.accent.opacity(isDragging ? 0.55 : 0.28),
                    radius: isDragging ? 5 : 2.5
                )
                .frame(
                    width: axis == .horizontal ? 3 : 26,
                    height: axis == .horizontal ? 24 : 3
                )
                .scaleEffect(isActive ? 1.0 : 0.72)
                .opacity(isActive ? 1.0 : 0.0)
        }
        .frame(
            width: axis == .horizontal ? Self.hitThickness : nil,
            height: axis == .vertical ? Self.hitThickness : nil
        )
        .frame(
            maxWidth: axis == .vertical ? .infinity : nil,
            maxHeight: axis == .horizontal ? .infinity : nil
        )
        .contentShape(Rectangle())
        .overlay {
            CeptraSplitHandleTrackingRepresentable(
                axis: axis,
                cursorDirection: cursorDirection,
                onHoverChanged: { hovering in
                    isHovering = hovering
                },
                onDraggingChanged: { dragging in
                    isDragging = dragging
                },
                onDragStart: onDragStart,
                onDragChanged: onDragChanged,
                onDragEnd: onDragEnd,
                onDoubleClick: onDoubleClick
            )
        }
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovering)
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isDragging)
    }
}

private struct CeptraSplitHandleTrackingRepresentable: NSViewRepresentable {
    let axis: CeptraSplitResizeHandle.Axis
    let cursorDirection: CeptraSplitResizeHandle.CursorDirection
    let onHoverChanged: (Bool) -> Void
    let onDraggingChanged: (Bool) -> Void
    let onDragStart: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnd: () -> Void
    let onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> SplitHandleTrackingNSView {
        SplitHandleTrackingNSView(
            axis: axis,
            cursorDirection: cursorDirection,
            onHoverChanged: onHoverChanged,
            onDraggingChanged: onDraggingChanged,
            onDragStart: onDragStart,
            onDragChanged: onDragChanged,
            onDragEnd: onDragEnd,
            onDoubleClick: onDoubleClick
        )
    }

    func updateNSView(_ nsView: SplitHandleTrackingNSView, context: Context) {
        let needsCursorInvalidation = nsView.axis != axis || nsView.cursorDirection != cursorDirection
        nsView.axis = axis
        nsView.cursorDirection = cursorDirection
        nsView.onHoverChanged = onHoverChanged
        nsView.onDraggingChanged = onDraggingChanged
        nsView.onDragStart = onDragStart
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnd = onDragEnd
        nsView.onDoubleClick = onDoubleClick
        if needsCursorInvalidation {
            if nsView.isDragging {
                nsView.activeCursor.set()
            } else {
                nsView.window?.invalidateCursorRects(for: nsView)
            }
        }
    }

    final class SplitHandleTrackingNSView: NSView {
        var axis: CeptraSplitResizeHandle.Axis
        var cursorDirection: CeptraSplitResizeHandle.CursorDirection
        var onHoverChanged: (Bool) -> Void
        var onDraggingChanged: (Bool) -> Void
        var onDragStart: () -> Void
        var onDragChanged: (CGFloat) -> Void
        var onDragEnd: () -> Void
        var onDoubleClick: (() -> Void)?
        private(set) var isDragging = false

        init(
            axis: CeptraSplitResizeHandle.Axis,
            cursorDirection: CeptraSplitResizeHandle.CursorDirection,
            onHoverChanged: @escaping (Bool) -> Void,
            onDraggingChanged: @escaping (Bool) -> Void,
            onDragStart: @escaping () -> Void,
            onDragChanged: @escaping (CGFloat) -> Void,
            onDragEnd: @escaping () -> Void,
            onDoubleClick: (() -> Void)?
        ) {
            self.axis = axis
            self.cursorDirection = cursorDirection
            self.onHoverChanged = onHoverChanged
            self.onDraggingChanged = onDraggingChanged
            self.onDragStart = onDragStart
            self.onDragChanged = onDragChanged
            self.onDragEnd = onDragEnd
            self.onDoubleClick = onDoubleClick
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) not supported")
        }

        // Layer-free, transparent overlay managed directly by SwiftUI bounds
        override var isOpaque: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        var activeCursor: NSCursor {
            if #available(macOS 15.0, *) {
                switch (axis, cursorDirection) {
                case (.horizontal, .both): return .columnResize(directions: .all)
                case (.horizontal, .onlyLeadingOrUp): return .columnResize(directions: .left)
                case (.horizontal, .onlyTrailingOrDown): return .columnResize(directions: .right)
                case (.vertical, .both): return .rowResize(directions: .all)
                case (.vertical, .onlyLeadingOrUp): return .rowResize(directions: .up)
                case (.vertical, .onlyTrailingOrDown): return .rowResize(directions: .down)
                }
            }
            switch (axis, cursorDirection) {
            case (.horizontal, .both): return .resizeLeftRight
            case (.horizontal, .onlyLeadingOrUp): return .resizeLeft
            case (.horizontal, .onlyTrailingOrDown): return .resizeRight
            case (.vertical, .both): return .resizeUpDown
            case (.vertical, .onlyLeadingOrUp): return .resizeUp
            case (.vertical, .onlyTrailingOrDown): return .resizeDown
            }
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: activeCursor)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.owner === self {
                removeTrackingArea(area)
            }
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                )
            )
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChanged(true)
        }

        override func mouseExited(with event: NSEvent) {
            if !isDragging {
                onHoverChanged(false)
            }
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick?()
                return
            }
            guard let window else { return }

            let startMouse = NSEvent.mouseLocation
            isDragging = true
            onDraggingChanged(true)
            onHoverChanged(true)
            onDragStart()
            activeCursor.push()

            defer {
                NSCursor.pop()
                isDragging = false
                onDraggingChanged(false)
                let pt = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                onHoverChanged(bounds.contains(pt))
                onDragEnd()
                window.invalidateCursorRects(for: self)
            }

            window.trackEvents(
                matching: [.leftMouseDragged, .leftMouseUp],
                timeout: NSEvent.foreverDuration,
                mode: .eventTracking
            ) { [weak self] trackedEvent, stop in
                guard let self, let trackedEvent else {
                    stop.pointee = true
                    return
                }
                if trackedEvent.type == .leftMouseUp {
                    stop.pointee = true
                    return
                }
                self.activeCursor.set()
                let now = NSEvent.mouseLocation
                // AppKit screen Y increases upward; invert so downward drags yield positive deltas.
                let delta = self.axis == .horizontal
                    ? (now.x - startMouse.x)
                    : (startMouse.y - now.y)
                self.onDragChanged(delta)
            }
        }
    }
}

struct CeptraGlassSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = 10
    var tint: Color = CeptraTheme.panelBG
    var tintOpacity: Double = 0.58
    var accentBorder: Color? = nil
    var isHovered: Bool = false
    var isActive: Bool = false
    var elevatedShadow: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(tint.opacity(tintOpacity))
                    if isActive {
                        shape.fill(CeptraTheme.glassActiveOverlay)
                    } else if isHovered {
                        shape.fill(CeptraTheme.glassHoverOverlay)
                    }
                }
            }
            .overlay {
                if let accentBorder {
                    shape.strokeBorder(CeptraTheme.accentSpecularRim(accentBorder), lineWidth: 0.9)
                } else {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered || isActive ? 0.26 : 0.16),
                                Color.white.opacity(isHovered || isActive ? 0.09 : 0.05),
                                Color.white.opacity(0.025)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
                }
            }
            .shadow(
                color: .black.opacity(elevatedShadow ? 0.28 : (isHovered ? 0.18 : 0.10)),
                radius: elevatedShadow ? 14 : (isHovered ? 8 : 4),
                y: elevatedShadow ? 6 : 2
            )
    }
}

struct CeptraGlassBarModifier: ViewModifier {
    var tint: Color = CeptraTheme.sidebarBG
    var tintOpacity: Double = 0.72
    var topHairline: Bool = false
    var bottomHairline: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(tint.opacity(tintOpacity))
                }
            }
            .overlay(alignment: .top) {
                if topHairline {
                    Rectangle()
                        .fill(Color.white.opacity(0.09))
                        .frame(height: 0.5)
                }
            }
            .overlay(alignment: .bottom) {
                if bottomHairline {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 0.5)
                }
            }
    }
}

struct CeptraGlassButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    var tint: Color = CeptraTheme.panelBG
    var tintOpacity: Double = 0.58
    var accentBorder: Color? = nil
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(
            configuration: configuration,
            cornerRadius: cornerRadius,
            tint: tint,
            tintOpacity: tintOpacity,
            accentBorder: accentBorder,
            isActive: isActive
        )
    }

    private struct GlassButtonBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let tint: Color
        let tintOpacity: Double
        let accentBorder: Color?
        let isActive: Bool

        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .modifier(
                    CeptraGlassSurfaceModifier(
                        cornerRadius: cornerRadius,
                        tint: tint,
                        tintOpacity: tintOpacity,
                        accentBorder: accentBorder,
                        isHovered: isHovered,
                        isActive: isActive || configuration.isPressed
                    )
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1.0)
                .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
                .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
                .onHover { hovering in
                    isHovered = hovering
                }
        }
    }
}

struct CeptraTactilePressStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        TactilePressBody(configuration: configuration, pressedScale: pressedScale)
    }

    private struct TactilePressBody: View {
        let configuration: Configuration
        let pressedScale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1.0)
                .brightness(configuration.isPressed ? -0.04 : 0)
                .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }
}

/// Unified Apple Liquid Glass dropdown pill trigger.
/// Pair with `CeptraGlassDropdown` so the custom glass pill, hover glow, and animated
/// trailing chevron render natively on macOS without `NSPopUpButton` stripping custom views.
struct CeptraMenuPillLabel<Leading: View>: View {
    let title: String
    var subtitle: String? = nil
    var titleFont: Font = .system(size: 12.5, weight: .semibold)
    var titleColor: Color = CeptraTheme.textPrimary
    var maxTitleWidth: CGFloat? = nil
    var accentBorder: Color? = nil
    var tint: Color = CeptraTheme.panelBG
    var tintOpacity: Double = 0.56
    var horizontalPadding: CGFloat = 10
    var verticalPadding: CGFloat = 5
    var cornerRadius: CGFloat = 8
    var showChevron: Bool = true
    var isOpen: Bool = false
    @ViewBuilder let leading: () -> Leading

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            leading()

            Text(title)
                .font(titleFont)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maxTitleWidth, alignment: .leading)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .lineLimit(1)
            }

            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(isOpen || isHovered ? CeptraTheme.textSecondary : CeptraTheme.textMuted)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .offset(y: !isOpen && isHovered && !reduceMotion ? 0.5 : 0)
                    .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: isOpen)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .modifier(
            CeptraGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                tint: tint,
                tintOpacity: tintOpacity,
                accentBorder: accentBorder,
                isHovered: isHovered,
                isActive: isOpen
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isOpen)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct CeptraDropdownDismissKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var ceptraDropdownDismiss: () -> Void {
        get { self[CeptraDropdownDismissKey.self] }
        set { self[CeptraDropdownDismissKey.self] = newValue }
    }
}

/// True Apple Liquid Glass dropdown menu for macOS.
/// Uses a real SwiftUI `Button` trigger (preserving full glass pill styling & animated chevron)
/// and a native translucent `.popover` surface with smooth hover-highlighted glass rows.
struct CeptraGlassDropdown<Trigger: View, MenuContent: View>: View {
    var arrowEdge: Edge = .bottom
    var minWidth: CGFloat = 230
    var maxWidth: CGFloat = 320
    var maxHeight: CGFloat = 380
    @ViewBuilder let trigger: (_ isOpen: Bool) -> Trigger
    @ViewBuilder let content: () -> MenuContent

    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                isOpen.toggle()
            }
        } label: {
            trigger(isOpen)
        }
        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.975))
        .popover(isPresented: $isOpen, arrowEdge: arrowEdge) {
            ViewThatFits(in: .vertical) {
                menuStack
                ScrollView(.vertical, showsIndicators: true) {
                    menuStack
                }
                .frame(maxHeight: maxHeight)
            }
            .frame(minWidth: minWidth, maxWidth: maxWidth)
            .background(CeptraTheme.panelBG.opacity(0.42))
            .presentationBackground(.ultraThinMaterial)
            .environment(\.ceptraDropdownDismiss) {
                withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                    isOpen = false
                }
            }
        }
    }

    private var menuStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            content()
        }
        .padding(6)
    }
}

struct CeptraDropdownItem: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var iconColor: Color? = nil
    var shortcut: String? = nil
    var isSelected: Bool = false
    var isMonospaced: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.ceptraDropdownDismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(
                            iconColor ?? (isSelected ? CeptraTheme.accent : (isHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary))
                        )
                        .frame(width: 16, alignment: .center)
                }

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(title)
                        .font(
                            isMonospaced
                                ? .system(size: 11.5, weight: isSelected ? .semibold : .regular, design: .monospaced)
                                : .system(size: 12, weight: isSelected ? .semibold : .medium)
                        )
                        .foregroundStyle(isHovered || isSelected ? CeptraTheme.textPrimary : CeptraTheme.textPrimary.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(isHovered ? CeptraTheme.textSecondary : CeptraTheme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 10)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CeptraTheme.accent)
                } else if let shortcut, !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.white.opacity(isHovered ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, subtitle == nil ? 6 : 6.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.09))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.65)
                        )
                } else if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(CeptraTheme.accent.opacity(0.12))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.985))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct CeptraDropdownSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(CeptraTheme.textMuted)
            .padding(.horizontal, 9)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

struct CeptraDropdownDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.09))
            .frame(height: 0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }
}

/// Native AppKit titlebar interaction layer for `.windowStyle(.hiddenTitleBar)` toolbars.
/// Restores standard macOS titlebar window dragging and double-click-to-zoom/fill
/// (respecting `AppleActionOnDoubleClick`) on empty toolbar space without intercepting buttons,
/// and dynamically reports the exact leading traffic-light reserve (collapsing cleanly in Full Screen).
struct CeptraWindowTitlebarDragArea: NSViewRepresentable {
    var onLeadingReserveChanged: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = WindowTitlebarDragNSView()
        view.onLeadingReserveChanged = onLeadingReserveChanged
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let dragView = nsView as? WindowTitlebarDragNSView {
            dragView.onLeadingReserveChanged = onLeadingReserveChanged
        }
    }

    private final class WindowTitlebarDragNSView: NSView {
        var onLeadingReserveChanged: ((CGFloat) -> Void)?
        private var didStartDrag = false
        private var lastReportedReserve: CGFloat = -1
        private var windowObservers: [NSObjectProtocol] = []

        override var mouseDownCanMoveWindow: Bool { true }

        override var isOpaque: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        deinit {
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            windowObservers.removeAll()

            guard let window else { return }
            let center = NotificationCenter.default
            for name in [
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didResizeNotification
            ] {
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.reportLeadingReserveIfNeeded()
                    }
                }
                windowObservers.append(token)
            }
            reportLeadingReserveIfNeeded()
        }

        override func layout() {
            super.layout()
            reportLeadingReserveIfNeeded()
        }

        private func reportLeadingReserveIfNeeded() {
            guard let window else { return }
            let reserve: CGFloat
            if window.styleMask.contains(.fullScreen) {
                reserve = 10
            } else if let zoomBtn = window.standardWindowButton(.zoomButton),
                      !zoomBtn.isHidden,
                      let superview = zoomBtn.superview {
                let rectInSelf = convert(zoomBtn.frame, from: superview)
                reserve = max(68, ceil(rectInSelf.maxX) + 10)
            } else {
                reserve = 74
            }

            guard abs(lastReportedReserve - reserve) > 0.5 else { return }
            lastReportedReserve = reserve
            let callback = onLeadingReserveChanged
            DispatchQueue.main.async {
                callback?(reserve)
            }
        }

        override func mouseDown(with event: NSEvent) {
            didStartDrag = false
            if event.clickCount == 2 {
                performTitlebarDoubleClick()
                return
            }
            super.mouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard !didStartDrag, let window else {
                super.mouseDragged(with: event)
                return
            }
            didStartDrag = true
            window.performDrag(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            didStartDrag = false
            super.mouseUp(with: event)
        }

        private func performTitlebarDoubleClick() {
            guard let window else { return }
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            switch action {
            case "Minimize":
                window.performMiniaturize(nil)
            case "None":
                break
            default:
                window.zoom(nil)
            }
        }
    }
}

/// Reusable Apple Liquid Glass segmented control with a smooth `@Namespace` sliding pill.
struct CeptraGlassSegmentedControl<Option: Identifiable & Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    var label: (Option) -> String
    var symbol: ((Option) -> String?)? = nil
    var badgeCount: ((Option) -> Int?)? = nil
    var horizontalPadding: CGFloat = 10
    var verticalPadding: CGFloat = 5
    var fontSize: CGFloat = 11.5

    @Namespace private var pillNamespace
    @State private var hoveredOption: Option?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = selection == option
                let isHovered = hoveredOption == option
                Button {
                    withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                        selection = option
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let icon = symbol?(option) {
                            Image(systemName: icon)
                                .font(.system(size: fontSize - 0.5, weight: isSelected ? .semibold : .regular))
                        }
                        Text(label(option))
                            .font(.system(size: fontSize, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        if let count = badgeCount?(option) {
                            Text("\(count)")
                                .font(.system(size: max(9.5, fontSize - 1.5), weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    (isSelected ? CeptraTheme.accent : CeptraTheme.textMuted).opacity(isSelected ? 0.22 : 0.14),
                                    in: Capsule()
                                )
                                .foregroundStyle(isSelected ? CeptraTheme.accent : CeptraTheme.textSecondary)
                        }
                    }
                    .foregroundStyle(isSelected ? CeptraTheme.textPrimary : (isHovered ? CeptraTheme.textPrimary.opacity(0.88) : CeptraTheme.textSecondary))
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                .fill(CeptraTheme.elevatedBG.opacity(0.92))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                        .strokeBorder(CeptraTheme.specularRimGradient, lineWidth: 0.75)
                                )
                                .shadow(color: .black.opacity(0.22), radius: 4, y: 1.5)
                                .matchedGeometryEffect(id: "active-glass-pill", in: pillNamespace)
                        } else if isHovered {
                            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                .fill(Color.white.opacity(0.045))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .onHover { hovering in
                    withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                        hoveredOption = hovering ? option : (hoveredOption == option ? nil : hoveredOption)
                    }
                }
            }
        }
        .padding(3)
        .ceptraGlassSurface(cornerRadius: 9, tint: CeptraTheme.panelBG, tintOpacity: 0.55)
        .fixedSize(horizontal: true, vertical: false)
    }
}

extension View {
    func ceptraGlassSurface(
        cornerRadius: CGFloat = 10,
        tint: Color = CeptraTheme.panelBG,
        tintOpacity: Double = 0.58,
        accentBorder: Color? = nil,
        isHovered: Bool = false,
        isActive: Bool = false,
        elevatedShadow: Bool = false
    ) -> some View {
        modifier(
            CeptraGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                tint: tint,
                tintOpacity: tintOpacity,
                accentBorder: accentBorder,
                isHovered: isHovered,
                isActive: isActive,
                elevatedShadow: elevatedShadow
            )
        )
    }

    func ceptraGlassBar(
        tint: Color = CeptraTheme.sidebarBG,
        tintOpacity: Double = 0.72,
        topHairline: Bool = false,
        bottomHairline: Bool = false
    ) -> some View {
        modifier(
            CeptraGlassBarModifier(
                tint: tint,
                tintOpacity: tintOpacity,
                topHairline: topHairline,
                bottomHairline: bottomHairline
            )
        )
    }
}
