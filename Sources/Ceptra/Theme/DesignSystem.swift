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
        }
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
