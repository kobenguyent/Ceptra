import AppKit
import CoreGraphics
import Foundation

public struct RenderedCodeSnapshot: Sendable {
    public let pngData: Data
    public let logicalSize: CGSize
    public let pixelSize: CGSize
    public let scale: Int

    public init(pngData: Data, logicalSize: CGSize, pixelSize: CGSize, scale: Int) {
        self.pngData = pngData
        self.logicalSize = logicalSize
        self.pixelSize = pixelSize
        self.scale = scale
    }
}

/// High-DPI zero-dependency CoreGraphics + AppKit renderer for Ray.so / Carbon-style
/// syntax-highlighted code block screenshots.
public enum CodeSnapshotRenderer {
    private struct ThemePalette {
        let cardBG: NSColor
        let headerOverlay: NSColor
        let borderLight: NSColor
        let borderOuter: NSColor
        let titleText: NSColor
        let badgeBG: NSColor
        let badgeText: NSColor
        let lineNumberText: NSColor
        let plain: NSColor
        let keyword: NSColor
        let dsl: NSColor
        let actor: NSColor
        let typeName: NSColor
        let property: NSColor
        let string: NSColor
        let number: NSColor
        let tag: NSColor
        let comment: NSColor
        let isDark: Bool
    }

    private struct BackdropGradient {
        let stops: [(CGFloat, NSColor)]
        let glowPrimary: NSColor
        let glowSecondary: NSColor
        let watermarkColor: NSColor
    }

    /// Renders `extraction` with `style` into a crisp Retina PNG (`2×` or `3×`).
    public static func render(
        extraction: CodeSnapshotExtraction,
        language: String,
        title: String,
        style: CodeSnapshotStyle
    ) -> RenderedCodeSnapshot? {
        let palette = themePalette(for: style.theme)
        let fontSize = CGFloat(style.fontSize)
        let scale = max(1, min(3, style.scale))
        let scaleFloat = CGFloat(scale)

        let regularFont = NSFont(name: "SFMono-Regular", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let boldFont = NSFont(name: "SFMono-Semibold", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let lineHeight = ceil(fontSize * 1.62)

        let codeLines = extraction.code.components(separatedBy: "\n")
        let lineCount = max(1, codeLines.count)
        let maxLineNum = extraction.startLineNumber + lineCount - 1
        let lineNumDigits = max(2, String(maxLineNum).count)

        let lineNumFont = NSFont(name: "SFMono-Regular", size: max(10, fontSize - 1.5))
            ?? NSFont.monospacedSystemFont(ofSize: max(10, fontSize - 1.5), weight: .regular)
        let sampleNumWidth = ceil((String(repeating: "8", count: lineNumDigits) as NSString)
            .size(withAttributes: [.font: lineNumFont]).width)

        let gutterWidth: CGFloat = style.showLineNumbers ? (sampleNumWidth + 20) : 0
        let cardInnerPadX: CGFloat = 24
        let cardInnerPadTop: CGFloat = (style.windowChrome == .none) ? 18 : 15
        let cardInnerPadBottom: CGFloat = 22
        let headerHeight: CGFloat = (style.windowChrome == .none) ? 0 : 42

        // Measure widest code line for natural auto-sizing
        let measureAttrs: [NSAttributedString.Key: Any] = [.font: regularFont]
        var maxCodeLineWidth: CGFloat = 220
        for line in codeLines {
            let w = ceil((line as NSString).size(withAttributes: measureAttrs).width)
            if w > maxCodeLineWidth { maxCodeLineWidth = w }
        }

        let minCardWidth: CGFloat = 440
        let maxCardWidth: CGFloat = 980
        let idealCardWidth = cardInnerPadX * 2 + gutterWidth + maxCodeLineWidth + 14
        let cardWidth = min(maxCardWidth, max(minCardWidth, ceil(idealCardWidth)))
        let codeAreaWidth = max(200, cardWidth - cardInnerPadX * 2 - gutterWidth)

        // Build full attributed code string with syntax highlighting
        let attributedCode = buildHighlightedAttributedString(
            code: extraction.code,
            language: language,
            regularFont: regularFont,
            boldFont: boldFont,
            lineHeight: lineHeight,
            palette: palette
        )

        // Lay out lines via TextKit to support clean line wrapping when a line exceeds maxCardWidth
        let textStorage = NSTextStorage(attributedString: attributedCode)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: codeAreaWidth, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let codeBlockHeight = max(lineHeight, ceil(usedRect.height))

        let cardHeight = headerHeight + cardInnerPadTop + codeBlockHeight + cardInnerPadBottom

        let padX: CGFloat = (style.background == .transparent)
            ? 36
            : CGFloat(style.padding.horizontalPoints)
        let padY: CGFloat = (style.background == .transparent)
            ? 38
            : CGFloat(style.padding.verticalPoints)
        let extraBottomForWatermark: CGFloat = (style.showWatermark && style.background != .transparent && padY < 34) ? 10 : 0

        let canvasWidth = ceil(cardWidth + padX * 2)
        let canvasHeight = ceil(cardHeight + padY * 2 + extraBottomForWatermark)

        let pixelWidth = max(1, Int((canvasWidth * scaleFloat).rounded()))
        let pixelHeight = max(1, Int((canvasHeight * scaleFloat).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = NSSize(width: canvasWidth, height: canvasHeight)

        guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        let cg = nsCtx.cgContext
        cg.setAllowsAntialiasing(true)
        cg.setShouldAntialias(true)
        cg.setAllowsFontSmoothing(true)
        cg.setShouldSmoothFonts(true)

        let canvasRect = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)

        // 1. Backdrop Gradient + Subtle Ambient Glow Orbs
        if style.background != .transparent {
            drawBackdrop(in: cg, rect: canvasRect, preset: style.background)
        } else {
            cg.clear(canvasRect)
        }

        // Flip to top-left origin for effortless layout math (card, header, text, line numbers)
        let cardRect = CGRect(
            x: padX,
            y: padY + extraBottomForWatermark,
            width: cardWidth,
            height: cardHeight
        )
        let cardRadius: CGFloat = 14

        // 2. Realistic Multi-Layer Elevation Drop Shadow (in native bottom-left Quartz coords)
        drawCardShadows(in: cg, cardRect: cardRect, cornerRadius: cardRadius, isDarkCard: palette.isDark)

        // 3. Frosted Glass Code Window Fill + Top Sheen
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)
        cg.saveGState()
        cg.addPath(cardPath)
        cg.clip()

        cg.setFillColor(palette.cardBG.cgColor)
        cg.fill(cardRect)

        // Subtle glass top sheen
        if let sheenGrad = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor.white.withAlphaComponent(palette.isDark ? 0.055 : 0.35).cgColor,
                NSColor.white.withAlphaComponent(0.0).cgColor
            ] as CFArray,
            locations: [0.0, 1.0]
        ) {
            cg.drawLinearGradient(
                sheenGrad,
                start: CGPoint(x: cardRect.midX, y: cardRect.maxY),
                end: CGPoint(x: cardRect.midX, y: cardRect.maxY - min(120, cardHeight * 0.45)),
                options: []
            )
        }

        // 4. Header Bar (Traffic Lights + Filename Title + Language Badge)
        if style.windowChrome != .none {
            let headerRect = CGRect(
                x: cardRect.minX,
                y: cardRect.maxY - headerHeight,
                width: cardRect.width,
                height: headerHeight
            )
            cg.setFillColor(palette.headerOverlay.cgColor)
            cg.fill(headerRect)

            // Header bottom hairline
            cg.setFillColor(palette.borderLight.withAlphaComponent(palette.isDark ? 0.08 : 0.07).cgColor)
            cg.fill(CGRect(x: headerRect.minX, y: headerRect.minY, width: headerRect.width, height: 1))

            if style.windowChrome == .macOS {
                drawTrafficLights(in: cg, headerRect: headerRect)
            }

            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if style.showTitle && !trimmedTitle.isEmpty {
                let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: titleFont,
                    .foregroundColor: palette.titleText
                ]
                let maxTitleW = cardWidth - (style.windowChrome == .macOS ? 190 : 120)
                let displayTitle = truncateMiddle(trimmedTitle, maxWidth: max(80, maxTitleW), attributes: titleAttrs)
                let titleSize = (displayTitle as NSString).size(withAttributes: titleAttrs)
                let titlePoint = NSPoint(
                    x: headerRect.midX - titleSize.width * 0.5,
                    y: headerRect.midY - titleSize.height * 0.5
                )
                (displayTitle as NSString).draw(at: titlePoint, withAttributes: titleAttrs)
            }

            if style.showLanguageBadge {
                let badgeLabel = CodeSnapshotEngine.languageBadge(for: language, fileName: title)
                let badgeFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)
                let badgeAttrs: [NSAttributedString.Key: Any] = [
                    .font: badgeFont,
                    .foregroundColor: palette.badgeText
                ]
                let textSize = (badgeLabel as NSString).size(withAttributes: badgeAttrs)
                let pillW = textSize.width + 12
                let pillH = textSize.height + 5
                let pillRect = CGRect(
                    x: headerRect.maxX - 16 - pillW,
                    y: headerRect.midY - pillH * 0.5,
                    width: pillW,
                    height: pillH
                )
                let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
                cg.setFillColor(palette.badgeBG.cgColor)
                cg.addPath(pillPath)
                cg.fillPath()

                (badgeLabel as NSString).draw(
                    at: NSPoint(x: pillRect.minX + 6, y: pillRect.minY + (pillH - textSize.height) * 0.5),
                    withAttributes: badgeAttrs
                )
            }
        }

        // 5. Render Syntax-Highlighted Code & Line Numbers (in flipped top-down coordinates inside card)
        let codeOriginX = cardRect.minX + cardInnerPadX + gutterWidth
        let codeTopYFromTop = (canvasHeight - cardRect.maxY) + headerHeight + cardInnerPadTop

        cg.saveGState()
        cg.translateBy(x: 0, y: canvasHeight)
        cg.scaleBy(x: 1, y: -1)
        let flippedCtx = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.current = flippedCtx

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: NSPoint(x: codeOriginX, y: codeTopYFromTop))
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: NSPoint(x: codeOriginX, y: codeTopYFromTop))

        if style.showLineNumbers {
            let lineIndex = LineIndexTable(text: extraction.code)
            let numAttrs: [NSAttributedString.Key: Any] = [
                .font: lineNumFont,
                .foregroundColor: palette.lineNumberText
            ]
            let gutterRightX = cardRect.minX + cardInnerPadX + sampleNumWidth
            let nsCodeLen = (extraction.code as NSString).length
            let defaultDescender = abs(regularFont.descender)

            for idx in 0..<lineIndex.lineCount {
                let displayNum = extraction.startLineNumber + idx
                let charOffset = lineIndex.lineStarts[idx]
                let fragRect: NSRect
                var baselineFromBottom: CGFloat = defaultDescender
                if layoutManager.numberOfGlyphs == 0 {
                    fragRect = NSRect(x: 0, y: CGFloat(idx) * lineHeight, width: codeAreaWidth, height: lineHeight)
                } else if charOffset >= nsCodeLen {
                    if layoutManager.extraLineFragmentRect.height > 0 {
                        fragRect = layoutManager.extraLineFragmentRect
                    } else {
                        fragRect = NSRect(x: 0, y: usedRect.height - lineHeight, width: codeAreaWidth, height: lineHeight)
                    }
                } else {
                    let glyphIdx = layoutManager.glyphIndexForCharacter(at: charOffset)
                    if glyphIdx < layoutManager.numberOfGlyphs {
                        fragRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                        baselineFromBottom = layoutManager.typesetter.baselineOffset(in: layoutManager, glyphIndex: glyphIdx)
                    } else {
                        fragRect = NSRect(x: 0, y: CGFloat(idx) * lineHeight, width: codeAreaWidth, height: lineHeight)
                    }
                }

                let numStr = "\(displayNum)" as NSString
                let numSize = numStr.size(withAttributes: numAttrs)
                let codeBaselineY = codeTopYFromTop + fragRect.maxY - baselineFromBottom
                let drawY = codeBaselineY - lineNumFont.ascender
                numStr.draw(at: NSPoint(x: gutterRightX - numSize.width, y: drawY), withAttributes: numAttrs)
            }
        }

        NSGraphicsContext.current = nsCtx
        cg.restoreGState()
        cg.restoreGState() // End card clip

        // 6. Specular Inner Rim & Crisp Outer Border
        let innerBorderRect = cardRect.insetBy(dx: 0.5, dy: 0.5)
        let innerBorderPath = CGPath(roundedRect: innerBorderRect, cornerWidth: cardRadius - 0.5, cornerHeight: cardRadius - 0.5, transform: nil)
        cg.setStrokeColor(palette.borderLight.cgColor)
        cg.setLineWidth(1.0)
        cg.addPath(innerBorderPath)
        cg.strokePath()

        let outerBorderPath = CGPath(roundedRect: cardRect, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)
        cg.setStrokeColor(palette.borderOuter.cgColor)
        cg.setLineWidth(0.75)
        cg.addPath(outerBorderPath)
        cg.strokePath()

        // 7. Optional Subtle Ceptra Watermark
        if style.showWatermark {
            let wmColor = style.background == .transparent
                ? (palette.isDark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.45))
                : backdropGradient(for: style.background).watermarkColor
            let wmFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            let wmAttrs: [NSAttributedString.Key: Any] = [
                .font: wmFont,
                .foregroundColor: wmColor
            ]
            let wmText = "Ceptra" as NSString
            let wmSize = wmText.size(withAttributes: wmAttrs)
            let wmX = cardRect.maxX - wmSize.width - 2
            let wmY = max(8, (cardRect.minY - wmSize.height) * 0.5)
            wmText.draw(at: NSPoint(x: wmX, y: wmY), withAttributes: wmAttrs)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }

        return RenderedCodeSnapshot(
            pngData: pngData,
            logicalSize: CGSize(width: canvasWidth, height: canvasHeight),
            pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
            scale: scale
        )
    }

    /// Copies the rendered PNG snapshot to the macOS clipboard with crisp PNG + NSImage representations.
    @discardableResult
    public static func copyToPasteboard(_ rendered: RenderedCodeSnapshot) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(rendered.pngData, forType: .png)
        if let image = NSImage(data: rendered.pngData), let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        return pb.writeObjects([item])
    }

    // MARK: - Drawing Primitives

    private static func drawBackdrop(in cg: CGContext, rect: CGRect, preset: CodeSnapshotBackground) {
        let gradientSpec = backdropGradient(for: preset)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let colors = gradientSpec.stops.map { $0.1.cgColor } as CFArray
        let locations = gradientSpec.stops.map(\.0)
        if let linear = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
            cg.drawLinearGradient(
                linear,
                start: CGPoint(x: rect.minX, y: rect.maxY),
                end: CGPoint(x: rect.maxX, y: rect.minY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // Soft upper-left & lower-right mesh bloom orbs for studio depth
        let maxDim = max(rect.width, rect.height)
        if let primaryGlow = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                gradientSpec.glowPrimary.cgColor,
                gradientSpec.glowPrimary.withAlphaComponent(0.0).cgColor
            ] as CFArray,
            locations: [0.0, 1.0]
        ) {
            let c1 = CGPoint(x: rect.minX + rect.width * 0.20, y: rect.maxY - rect.height * 0.16)
            cg.drawRadialGradient(primaryGlow, startCenter: c1, startRadius: 0, endCenter: c1, endRadius: maxDim * 0.58, options: [])
        }
        if let secondaryGlow = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                gradientSpec.glowSecondary.cgColor,
                gradientSpec.glowSecondary.withAlphaComponent(0.0).cgColor
            ] as CFArray,
            locations: [0.0, 1.0]
        ) {
            let c2 = CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.minY + rect.height * 0.18)
            cg.drawRadialGradient(secondaryGlow, startCenter: c2, startRadius: 0, endCenter: c2, endRadius: maxDim * 0.55, options: [])
        }
    }

    private static func drawCardShadows(in cg: CGContext, cardRect: CGRect, cornerRadius: CGFloat, isDarkCard: Bool) {
        let path = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // Deep ambient shadow
        cg.saveGState()
        cg.setShadow(
            offset: CGSize(width: 0, height: -20),
            blur: 44,
            color: NSColor.black.withAlphaComponent(isDarkCard ? 0.52 : 0.28).cgColor
        )
        cg.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
        cg.addPath(path)
        cg.fillPath()
        cg.restoreGState()

        // Tight grounding shadow
        cg.saveGState()
        cg.setShadow(
            offset: CGSize(width: 0, height: -5),
            blur: 12,
            color: NSColor.black.withAlphaComponent(isDarkCard ? 0.34 : 0.16).cgColor
        )
        cg.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        cg.addPath(path)
        cg.fillPath()
        cg.restoreGState()
    }

    private static func drawTrafficLights(in cg: CGContext, headerRect: CGRect) {
        let dots: [(NSColor, NSColor)] = [
            (NSColor(srgbRed: 1.000, green: 0.373, blue: 0.337, alpha: 1.0), NSColor(srgbRed: 0.878, green: 0.267, blue: 0.243, alpha: 0.7)),
            (NSColor(srgbRed: 1.000, green: 0.741, blue: 0.180, alpha: 1.0), NSColor(srgbRed: 0.871, green: 0.624, blue: 0.133, alpha: 0.7)),
            (NSColor(srgbRed: 0.153, green: 0.788, blue: 0.247, alpha: 1.0), NSColor(srgbRed: 0.106, green: 0.667, blue: 0.176, alpha: 0.7))
        ]
        let diameter: CGFloat = 12
        let spacing: CGFloat = 20
        let startX = headerRect.minX + 18
        let y = headerRect.midY - diameter * 0.5

        for (idx, pair) in dots.enumerated() {
            let r = CGRect(x: startX + CGFloat(idx) * spacing, y: y, width: diameter, height: diameter)
            cg.setFillColor(pair.0.cgColor)
            cg.fillEllipse(in: r)
            cg.setStrokeColor(pair.1.cgColor)
            cg.setLineWidth(0.75)
            cg.strokeEllipse(in: r.insetBy(dx: 0.375, dy: 0.375))
        }
    }

    private static func buildHighlightedAttributedString(
        code: String,
        language: String,
        regularFont: NSFont,
        boldFont: NSFont,
        lineHeight: CGFloat,
        palette: ThemePalette
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byWordWrapping

        let attributed = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: regularFont,
                .foregroundColor: palette.plain,
                .paragraphStyle: paragraph
            ]
        )

        let spans = CodeSnapshotEngine.tokenize(code: code, language: language)
        for span in spans {
            let color: NSColor
            switch span.kind {
            case .plain: color = palette.plain
            case .keyword: color = palette.keyword
            case .dsl: color = palette.dsl
            case .actor: color = palette.actor
            case .typeName: color = palette.typeName
            case .property: color = palette.property
            case .string: color = palette.string
            case .number: color = palette.number
            case .tag: color = palette.tag
            case .comment: color = palette.comment
            }
            attributed.addAttribute(.foregroundColor, value: color, range: span.range)
            if span.isBold {
                attributed.addAttribute(.font, value: boldFont, range: span.range)
            }
        }
        return attributed
    }

    private static func truncateMiddle(
        _ value: String,
        maxWidth: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> String {
        if (value as NSString).size(withAttributes: attributes).width <= maxWidth {
            return value
        }
        let chars = Array(value)
        guard chars.count > 8 else { return value }
        var left = chars.count / 2
        var right = chars.count / 2
        while left > 2 && right < chars.count - 2 {
            left -= 1
            right += 1
            let candidate = String(chars[0..<left]) + "…" + String(chars[right..<chars.count])
            if (candidate as NSString).size(withAttributes: attributes).width <= maxWidth {
                return candidate
            }
        }
        return String(chars.prefix(6)) + "…"
    }

    // MARK: - Curated Palettes

    private static func backdropGradient(for preset: CodeSnapshotBackground) -> BackdropGradient {
        switch preset {
        case .candy:
            return BackdropGradient(
                stops: [
                    (0.0, NSColor(srgbRed: 0.996, green: 0.443, blue: 0.659, alpha: 1.0)),
                    (0.52, NSColor(srgbRed: 0.569, green: 0.369, blue: 0.965, alpha: 1.0)),
                    (1.0, NSColor(srgbRed: 0.220, green: 0.490, blue: 0.980, alpha: 1.0))
                ],
                glowPrimary: NSColor(srgbRed: 1.0, green: 0.72, blue: 0.85, alpha: 0.32),
                glowSecondary: NSColor(srgbRed: 0.25, green: 0.85, blue: 1.0, alpha: 0.28),
                watermarkColor: NSColor.white.withAlphaComponent(0.76)
            )
        case .midnight:
            return BackdropGradient(
                stops: [
                    (0.0, NSColor(srgbRed: 0.094, green: 0.125, blue: 0.239, alpha: 1.0)),
                    (0.5, NSColor(srgbRed: 0.145, green: 0.169, blue: 0.322, alpha: 1.0)),
                    (1.0, NSColor(srgbRed: 0.235, green: 0.173, blue: 0.412, alpha: 1.0))
                ],
                glowPrimary: NSColor(srgbRed: 0.36, green: 0.56, blue: 1.0, alpha: 0.24),
                glowSecondary: NSColor(srgbRed: 0.64, green: 0.35, blue: 0.96, alpha: 0.22),
                watermarkColor: NSColor.white.withAlphaComponent(0.58)
            )
        case .breeze:
            return BackdropGradient(
                stops: [
                    (0.0, NSColor(srgbRed: 0.059, green: 0.780, blue: 0.875, alpha: 1.0)),
                    (0.52, NSColor(srgbRed: 0.192, green: 0.510, blue: 0.965, alpha: 1.0)),
                    (1.0, NSColor(srgbRed: 0.365, green: 0.325, blue: 0.922, alpha: 1.0))
                ],
                glowPrimary: NSColor(srgbRed: 0.68, green: 0.98, blue: 1.0, alpha: 0.30),
                glowSecondary: NSColor(srgbRed: 0.54, green: 0.46, blue: 1.0, alpha: 0.26),
                watermarkColor: NSColor.white.withAlphaComponent(0.78)
            )
        case .sunset:
            return BackdropGradient(
                stops: [
                    (0.0, NSColor(srgbRed: 0.996, green: 0.514, blue: 0.220, alpha: 1.0)),
                    (0.50, NSColor(srgbRed: 0.929, green: 0.278, blue: 0.584, alpha: 1.0)),
                    (1.0, NSColor(srgbRed: 0.494, green: 0.267, blue: 0.878, alpha: 1.0))
                ],
                glowPrimary: NSColor(srgbRed: 1.0, green: 0.84, blue: 0.48, alpha: 0.32),
                glowSecondary: NSColor(srgbRed: 0.82, green: 0.42, blue: 1.0, alpha: 0.26),
                watermarkColor: NSColor.white.withAlphaComponent(0.78)
            )
        case .emerald:
            return BackdropGradient(
                stops: [
                    (0.0, NSColor(srgbRed: 0.075, green: 0.788, blue: 0.576, alpha: 1.0)),
                    (0.52, NSColor(srgbRed: 0.055, green: 0.580, blue: 0.580, alpha: 1.0)),
                    (1.0, NSColor(srgbRed: 0.047, green: 0.349, blue: 0.592, alpha: 1.0))
                ],
                glowPrimary: NSColor(srgbRed: 0.56, green: 1.0, blue: 0.82, alpha: 0.28),
                glowSecondary: NSColor(srgbRed: 0.22, green: 0.72, blue: 0.98, alpha: 0.24),
                watermarkColor: NSColor.white.withAlphaComponent(0.75)
            )
        case .amber:
            return BackdropGradient(
                stops: [
                    (0.0, NSColor(srgbRed: 0.984, green: 0.729, blue: 0.184, alpha: 1.0)),
                    (0.52, NSColor(srgbRed: 0.941, green: 0.412, blue: 0.145, alpha: 1.0)),
                    (1.0, NSColor(srgbRed: 0.745, green: 0.133, blue: 0.310, alpha: 1.0))
                ],
                glowPrimary: NSColor(srgbRed: 1.0, green: 0.92, blue: 0.55, alpha: 0.32),
                glowSecondary: NSColor(srgbRed: 1.0, green: 0.38, blue: 0.52, alpha: 0.24),
                watermarkColor: NSColor.white.withAlphaComponent(0.78)
            )
        case .monochrome:
            return BackdropGradient(
                stops: [
                    (0.0, NSColor(srgbRed: 0.200, green: 0.212, blue: 0.243, alpha: 1.0)),
                    (0.55, NSColor(srgbRed: 0.125, green: 0.133, blue: 0.157, alpha: 1.0)),
                    (1.0, NSColor(srgbRed: 0.067, green: 0.071, blue: 0.086, alpha: 1.0))
                ],
                glowPrimary: NSColor.white.withAlphaComponent(0.09),
                glowSecondary: NSColor(srgbRed: 0.45, green: 0.52, blue: 0.65, alpha: 0.08),
                watermarkColor: NSColor.white.withAlphaComponent(0.48)
            )
        case .transparent:
            return BackdropGradient(
                stops: [(0.0, .clear), (1.0, .clear)],
                glowPrimary: .clear,
                glowSecondary: .clear,
                watermarkColor: NSColor.white.withAlphaComponent(0.55)
            )
        }
    }

    private static func themePalette(for theme: CodeSnapshotTheme) -> ThemePalette {
        switch theme {
        case .obsidian:
            return ThemePalette(
                cardBG: NSColor(srgbRed: 0.067, green: 0.082, blue: 0.118, alpha: 0.94),
                headerOverlay: NSColor.white.withAlphaComponent(0.025),
                borderLight: NSColor.white.withAlphaComponent(0.16),
                borderOuter: NSColor.black.withAlphaComponent(0.38),
                titleText: NSColor(srgbRed: 0.78, green: 0.82, blue: 0.90, alpha: 0.86),
                badgeBG: NSColor.white.withAlphaComponent(0.08),
                badgeText: NSColor(srgbRed: 0.72, green: 0.80, blue: 0.94, alpha: 0.88),
                lineNumberText: NSColor(srgbRed: 0.46, green: 0.52, blue: 0.64, alpha: 0.62),
                plain: NSColor(srgbRed: 0.91, green: 0.93, blue: 0.97, alpha: 1.0),
                keyword: NSColor(srgbRed: 0.76, green: 0.56, blue: 0.98, alpha: 1.0),
                dsl: NSColor(srgbRed: 0.34, green: 0.82, blue: 0.98, alpha: 1.0),
                actor: NSColor(srgbRed: 0.26, green: 0.88, blue: 0.64, alpha: 1.0),
                typeName: NSColor(srgbRed: 0.97, green: 0.78, blue: 0.42, alpha: 1.0),
                property: NSColor(srgbRed: 0.62, green: 0.78, blue: 1.0, alpha: 1.0),
                string: NSColor(srgbRed: 0.46, green: 0.92, blue: 0.72, alpha: 1.0),
                number: NSColor(srgbRed: 0.98, green: 0.58, blue: 0.48, alpha: 1.0),
                tag: NSColor(srgbRed: 0.97, green: 0.75, blue: 0.32, alpha: 1.0),
                comment: NSColor(srgbRed: 0.44, green: 0.50, blue: 0.60, alpha: 1.0),
                isDark: true
            )
        case .dracula:
            return ThemePalette(
                cardBG: NSColor(srgbRed: 0.145, green: 0.153, blue: 0.208, alpha: 0.95),
                headerOverlay: NSColor.white.withAlphaComponent(0.03),
                borderLight: NSColor.white.withAlphaComponent(0.15),
                borderOuter: NSColor.black.withAlphaComponent(0.40),
                titleText: NSColor(srgbRed: 0.84, green: 0.84, blue: 0.90, alpha: 0.82),
                badgeBG: NSColor(srgbRed: 0.74, green: 0.58, blue: 0.98, alpha: 0.16),
                badgeText: NSColor(srgbRed: 0.74, green: 0.58, blue: 0.98, alpha: 0.95),
                lineNumberText: NSColor(srgbRed: 0.38, green: 0.45, blue: 0.64, alpha: 0.72),
                plain: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.95, alpha: 1.0),
                keyword: NSColor(srgbRed: 1.00, green: 0.47, blue: 0.78, alpha: 1.0),
                dsl: NSColor(srgbRed: 0.55, green: 0.91, blue: 0.99, alpha: 1.0),
                actor: NSColor(srgbRed: 0.31, green: 0.98, blue: 0.48, alpha: 1.0),
                typeName: NSColor(srgbRed: 0.74, green: 0.58, blue: 0.98, alpha: 1.0),
                property: NSColor(srgbRed: 0.55, green: 0.91, blue: 0.99, alpha: 1.0),
                string: NSColor(srgbRed: 0.95, green: 0.98, blue: 0.55, alpha: 1.0),
                number: NSColor(srgbRed: 0.74, green: 0.58, blue: 0.98, alpha: 1.0),
                tag: NSColor(srgbRed: 1.00, green: 0.72, blue: 0.42, alpha: 1.0),
                comment: NSColor(srgbRed: 0.38, green: 0.45, blue: 0.64, alpha: 1.0),
                isDark: true
            )
        case .catppuccin:
            return ThemePalette(
                cardBG: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.180, alpha: 0.95),
                headerOverlay: NSColor.white.withAlphaComponent(0.025),
                borderLight: NSColor.white.withAlphaComponent(0.14),
                borderOuter: NSColor.black.withAlphaComponent(0.40),
                titleText: NSColor(srgbRed: 0.80, green: 0.84, blue: 0.96, alpha: 0.85),
                badgeBG: NSColor(srgbRed: 0.54, green: 0.71, blue: 0.98, alpha: 0.15),
                badgeText: NSColor(srgbRed: 0.54, green: 0.71, blue: 0.98, alpha: 0.95),
                lineNumberText: NSColor(srgbRed: 0.42, green: 0.44, blue: 0.53, alpha: 0.72),
                plain: NSColor(srgbRed: 0.80, green: 0.84, blue: 0.96, alpha: 1.0),
                keyword: NSColor(srgbRed: 0.80, green: 0.65, blue: 0.97, alpha: 1.0),
                dsl: NSColor(srgbRed: 0.54, green: 0.71, blue: 0.98, alpha: 1.0),
                actor: NSColor(srgbRed: 0.58, green: 0.89, blue: 0.84, alpha: 1.0),
                typeName: NSColor(srgbRed: 0.98, green: 0.89, blue: 0.69, alpha: 1.0),
                property: NSColor(srgbRed: 0.71, green: 0.75, blue: 0.99, alpha: 1.0),
                string: NSColor(srgbRed: 0.65, green: 0.89, blue: 0.63, alpha: 1.0),
                number: NSColor(srgbRed: 0.98, green: 0.70, blue: 0.53, alpha: 1.0),
                tag: NSColor(srgbRed: 0.95, green: 0.55, blue: 0.66, alpha: 1.0),
                comment: NSColor(srgbRed: 0.42, green: 0.44, blue: 0.53, alpha: 1.0),
                isDark: true
            )
        case .tokyoNight:
            return ThemePalette(
                cardBG: NSColor(srgbRed: 0.102, green: 0.106, blue: 0.149, alpha: 0.95),
                headerOverlay: NSColor.white.withAlphaComponent(0.025),
                borderLight: NSColor.white.withAlphaComponent(0.15),
                borderOuter: NSColor.black.withAlphaComponent(0.42),
                titleText: NSColor(srgbRed: 0.66, green: 0.70, blue: 0.84, alpha: 0.86),
                badgeBG: NSColor(srgbRed: 0.48, green: 0.64, blue: 0.97, alpha: 0.16),
                badgeText: NSColor(srgbRed: 0.48, green: 0.64, blue: 0.97, alpha: 0.95),
                lineNumberText: NSColor(srgbRed: 0.34, green: 0.37, blue: 0.54, alpha: 0.72),
                plain: NSColor(srgbRed: 0.75, green: 0.79, blue: 0.96, alpha: 1.0),
                keyword: NSColor(srgbRed: 0.73, green: 0.60, blue: 0.97, alpha: 1.0),
                dsl: NSColor(srgbRed: 0.48, green: 0.64, blue: 0.97, alpha: 1.0),
                actor: NSColor(srgbRed: 0.49, green: 0.81, blue: 1.00, alpha: 1.0),
                typeName: NSColor(srgbRed: 0.16, green: 0.76, blue: 0.87, alpha: 1.0),
                property: NSColor(srgbRed: 0.45, green: 0.85, blue: 0.79, alpha: 1.0),
                string: NSColor(srgbRed: 0.62, green: 0.81, blue: 0.42, alpha: 1.0),
                number: NSColor(srgbRed: 1.00, green: 0.62, blue: 0.39, alpha: 1.0),
                tag: NSColor(srgbRed: 0.88, green: 0.69, blue: 0.41, alpha: 1.0),
                comment: NSColor(srgbRed: 0.34, green: 0.37, blue: 0.54, alpha: 1.0),
                isDark: true
            )
        case .paperLight:
            return ThemePalette(
                cardBG: NSColor(srgbRed: 0.992, green: 0.994, blue: 0.998, alpha: 0.97),
                headerOverlay: NSColor.black.withAlphaComponent(0.025),
                borderLight: NSColor.white.withAlphaComponent(0.75),
                borderOuter: NSColor.black.withAlphaComponent(0.14),
                titleText: NSColor(srgbRed: 0.28, green: 0.33, blue: 0.41, alpha: 0.88),
                badgeBG: NSColor(srgbRed: 0.15, green: 0.39, blue: 0.92, alpha: 0.10),
                badgeText: NSColor(srgbRed: 0.15, green: 0.39, blue: 0.92, alpha: 0.92),
                lineNumberText: NSColor(srgbRed: 0.55, green: 0.60, blue: 0.68, alpha: 0.78),
                plain: NSColor(srgbRed: 0.10, green: 0.12, blue: 0.17, alpha: 1.0),
                keyword: NSColor(srgbRed: 0.51, green: 0.21, blue: 0.89, alpha: 1.0),
                dsl: NSColor(srgbRed: 0.11, green: 0.36, blue: 0.88, alpha: 1.0),
                actor: NSColor(srgbRed: 0.01, green: 0.50, blue: 0.72, alpha: 1.0),
                typeName: NSColor(srgbRed: 0.68, green: 0.36, blue: 0.02, alpha: 1.0),
                property: NSColor(srgbRed: 0.14, green: 0.44, blue: 0.74, alpha: 1.0),
                string: NSColor(srgbRed: 0.02, green: 0.47, blue: 0.34, alpha: 1.0),
                number: NSColor(srgbRed: 0.83, green: 0.38, blue: 0.04, alpha: 1.0),
                tag: NSColor(srgbRed: 0.76, green: 0.25, blue: 0.05, alpha: 1.0),
                comment: NSColor(srgbRed: 0.52, green: 0.57, blue: 0.65, alpha: 1.0),
                isDark: false
            )
        }
    }
}
