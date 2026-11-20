import AppKit
import SwiftUI

/// Native macOS AppKit code editor built on an explicit TextKit 1 stack with
/// a sibling line-number gutter, CodeceptJS 4.x / JS / TS / Gherkin syntax highlighting,
/// Find & Replace (`⌘F`), soft-tab indentation, and jump-to-line support.
struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    var language: String
    var fontSize: CGFloat = 13.0
    @Binding var jumpToLine: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CeptraEditorContainerView {
        let container = CeptraEditorContainerView(
            text: text,
            language: language,
            fontSize: fontSize,
            delegate: context.coordinator
        )
        context.coordinator.container = container
        context.coordinator.observe(container: container)
        return container
    }

    func updateNSView(_ container: CeptraEditorContainerView, context: Context) {
        context.coordinator.parent = self
        let textView = container.textView

        let languageChanged = textView.editorLanguage != language
        let fontChanged = abs(textView.editorFontSize - fontSize) > 0.1
        textView.editorFontSize = fontSize
        textView.editorLanguage = language
        textView.tabWidth = 2

        if textView.string != text {
            context.coordinator.isProgrammaticUpdate = true
            let savedSelection = textView.selectedRange()
            textView.string = text
            textView.restyleAllText()
            let maxLen = (text as NSString).length
            let safeLoc = min(savedSelection.location, maxLen)
            textView.setSelectedRange(NSRange(location: safeLoc, length: 0))
            container.updateGutter()
            context.coordinator.isProgrammaticUpdate = false
        } else if languageChanged || fontChanged {
            textView.restyleAllText()
            container.updateGutter()
        }

        if let targetLine = jumpToLine {
            container.scrollToLine(targetLine)
            DispatchQueue.main.async {
                self.jumpToLine = nil
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var container: CeptraEditorContainerView?
        var isProgrammaticUpdate = false
        private var observers: [NSObjectProtocol] = []

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func observe(container: CeptraEditorContainerView) {
            container.scrollView.contentView.postsBoundsChangedNotifications = true
            let boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: container.scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.container?.gutterView.needsDisplay = true
            }
            let frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: container.textView,
                queue: .main
            ) { [weak self] _ in
                self?.container?.gutterView.needsDisplay = true
            }
            observers.append(contentsOf: [boundsObserver, frameObserver])
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate,
                  let codeView = notification.object as? CeptraCodeTextView else { return }
            codeView.restyleAllText()
            container?.updateGutter()
            let updated = codeView.string
            if parent.text != updated {
                parent.text = updated
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            container?.gutterView.needsDisplay = true
        }
    }
}

final class CeptraEditorContainerView: NSView {
    let scrollView: NSScrollView
    let textView: CeptraCodeTextView
    let gutterView: LineNumberGutterView
    private var gutterWidthConstraint: NSLayoutConstraint?

    init(text: String, language: String, fontSize: CGFloat, delegate: NSTextViewDelegate) {
        self.scrollView = NSScrollView()

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        self.textView = CeptraCodeTextView(frame: .zero, textContainer: textContainer)
        self.gutterView = LineNumberGutterView(textView: textView, scrollView: scrollView)

        super.init(frame: .zero)

        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.075, green: 0.082, blue: 0.102, alpha: 1.0).cgColor

        textView.delegate = delegate
        textView.editorLanguage = language
        textView.editorFontSize = fontSize
        textView.configureDefaults()
        textView.string = text
        textView.restyleAllText()

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(red: 0.075, green: 0.082, blue: 0.102, alpha: 1.0)
        scrollView.borderType = .noBorder

        gutterView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(gutterView)
        addSubview(scrollView)

        let widthConstraint = gutterView.widthAnchor.constraint(equalToConstant: 48)
        gutterWidthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            gutterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutterView.topAnchor.constraint(equalTo: topAnchor),
            gutterView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,

            scrollView.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        updateGutter()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func updateGutter() {
        let lineCount = max(1, textView.string.components(separatedBy: "\n").count)
        let digits = max(3, String(lineCount).count)
        gutterWidthConstraint?.constant = CGFloat(digits * 8 + 22)
        gutterView.needsDisplay = true
    }

    func scrollToLine(_ oneBasedLine: Int) {
        let ns = textView.string as NSString
        var currentLine = 1
        var index = 0
        let length = ns.length

        while currentLine < oneBasedLine && index < length {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(lineRange)
            currentLine += 1
        }

        let targetRange = ns.lineRange(for: NSRange(location: min(index, length), length: 0))
        textView.setSelectedRange(NSRange(location: targetRange.location, length: 0))
        textView.scrollRangeToVisible(targetRange)
        gutterView.needsDisplay = true
    }
}

final class LineNumberGutterView: NSView {
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor(red: 0.088, green: 0.096, blue: 0.120, alpha: 1.0).setFill()
        dirtyRect.fill()

        // Right separator hairline
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSRect(x: bounds.width - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView else { return }

        let visibleRect = scrollView.contentView.bounds
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let nsString = textView.string as NSString

        let selectedLocation = textView.selectedRange().location
        var activeLineNumber = 1
        if selectedLocation > 0 && selectedLocation <= nsString.length {
            let prefix = nsString.substring(to: selectedLocation)
            activeLineNumber = prefix.components(separatedBy: "\n").count
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(red: 0.42, green: 0.46, blue: 0.55, alpha: 1.0)
        ]
        let activeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(red: 0.78, green: 0.85, blue: 0.98, alpha: 1.0)
        ]

        var lineNumber = 1
        var charIndex = 0
        let firstVisibleChar = layoutManager.characterIndexForGlyph(at: visibleGlyphRange.location)
        while charIndex < firstVisibleChar && charIndex < nsString.length {
            let range = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
            charIndex = NSMaxRange(range)
            lineNumber += 1
        }

        var glyphIndex = visibleGlyphRange.location
        let maxGlyph = NSMaxRange(visibleGlyphRange)
        let insetTop = textView.textContainerInset.height

        while glyphIndex < maxGlyph {
            let charIdx = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineCharRange = nsString.lineRange(for: NSRange(location: charIdx, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineCharRange, actualCharacterRange: nil)

            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            lineRect.origin.y += insetTop - visibleRect.origin.y

            let label = "\(lineNumber)" as NSString
            let attrs = (lineNumber == activeLineNumber) ? activeAttrs : normalAttrs
            let textSize = label.size(withAttributes: attrs)
            let drawPoint = NSPoint(
                x: bounds.width - textSize.width - 10,
                y: lineRect.origin.y + (lineRect.height - textSize.height) * 0.5
            )
            label.draw(at: drawPoint, withAttributes: attrs)

            lineNumber += 1
            glyphIndex = max(NSMaxRange(lineGlyphRange), glyphIndex + 1)
        }
    }
}

final class CeptraCodeTextView: NSTextView {
    var editorLanguage: String = "javascript"
    var editorFontSize: CGFloat = 13.0
    var tabWidth: Int = 2

    func configureDefaults() {
        isEditable = true
        isSelectable = true
        isRichText = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        smartInsertDeleteEnabled = false
        isHorizontallyResizable = true
        isVerticallyResizable = true
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 12, height: 12)
        backgroundColor = NSColor(red: 0.075, green: 0.082, blue: 0.102, alpha: 1.0)
        insertionPointColor = NSColor(red: 0.44, green: 0.62, blue: 1.0, alpha: 1.0)
        selectedTextAttributes = [
            .backgroundColor: NSColor(red: 0.25, green: 0.38, blue: 0.68, alpha: 0.42)
        ]
    }

    override func insertTab(_ sender: Any?) {
        insertText(String(repeating: " ", count: tabWidth), replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let loc = selectedRange().location
        let lineRange = ns.lineRange(for: NSRange(location: min(loc, ns.length), length: 0))
        let lineText = ns.substring(with: lineRange)
        let indent = String(lineText.prefix(while: { $0 == " " || $0 == "\t" }))
        let extra = lineText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("{")
            ? String(repeating: " ", count: tabWidth)
            : ""
        insertText("\n" + indent + extra, replacementRange: selectedRange())
    }

    func restyleAllText() {
        guard let storage = textStorage else { return }
        let fullText = storage.string
        let fullRange = NSRange(location: 0, length: (fullText as NSString).length)
        let font = NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.32

        let baseColor = NSColor(red: 0.89, green: 0.91, blue: 0.96, alpha: 1.0)
        let keywordColor = NSColor(red: 0.76, green: 0.56, blue: 0.98, alpha: 1.0)
        let dslColor = NSColor(red: 0.34, green: 0.82, blue: 0.96, alpha: 1.0)
        let actorColor = NSColor(red: 0.26, green: 0.86, blue: 0.62, alpha: 1.0)
        let stringColor = NSColor(red: 0.98, green: 0.76, blue: 0.42, alpha: 1.0)
        let numberColor = NSColor(red: 0.96, green: 0.56, blue: 0.48, alpha: 1.0)
        let tagColor = NSColor(red: 0.98, green: 0.50, blue: 0.72, alpha: 1.0)
        let commentColor = NSColor(red: 0.45, green: 0.50, blue: 0.58, alpha: 1.0)

        storage.beginEditing()
        storage.setAttributes([
            .font: font,
            .foregroundColor: baseColor,
            .paragraphStyle: paragraph
        ], range: fullRange)

        func apply(_ pattern: String, color: NSColor, useBold: Bool = false, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in regex.matches(in: fullText, range: fullRange) {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
                if useBold {
                    storage.addAttribute(.font, value: boldFont, range: match.range)
                }
            }
        }

        if editorLanguage == "gherkin" {
            apply(#"^\s*(?:Feature|Background|Scenario Outline|Scenario Template|Scenario|Examples):"#, color: dslColor, useBold: true, options: [.anchorsMatchLines])
            apply(#"^\s*(?:Given|When|Then|And|But)\b"#, color: actorColor, useBold: true, options: [.anchorsMatchLines])
            apply(#"@[A-Za-z0-9_:-]+"#, color: tagColor, useBold: true)
            apply(#""(?:\\.|[^"\\])*""#, color: stringColor)
            apply(#"^\s*#.*$"#, color: commentColor, options: [.anchorsMatchLines])
        } else if editorLanguage == "json" {
            apply(#""[^"]+"\s*(?=:)"#, color: dslColor)
            apply(#":\s*"(?:\\.|[^"\\])*""#, color: stringColor)
            apply(#"\b(?:true|false|null)\b"#, color: keywordColor)
            apply(#"\b\d+(?:\.\d+)?\b"#, color: numberColor)
        } else {
            // JS / TS + CodeceptJS 4.x DSL
            apply(#"\b(?:import|export|from|const|let|var|async|await|return|if|else|for|while|try|catch|finally|throw|new|class|extends|default|function|type|interface|true|false|null|undefined)\b"#, color: keywordColor)
            apply(#"\b(?:Feature|Scenario|xScenario|BeforeSuite|AfterSuite|Before|After|Data|DataTable|within|session|tryTo|retryTo|locate|secret|inject|pause|eachElement)\b"#, color: dslColor, useBold: true)
            apply(#"\bI(?:\.retry\([^)]*\))?\.[A-Za-z_$][\w$]*"#, color: actorColor)
            apply(#"\b\d+(?:_\d+)*(?:\.\d+)?\b"#, color: numberColor)
            apply(#"'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*"|`(?:\\.|[^`\\])*`"#, color: stringColor)
            apply(#"@[A-Za-z0-9_:-]+"#, color: tagColor, useBold: true)
            apply(#"//[^\n]*"#, color: commentColor)
            apply(#"/\*[\s\S]*?\*/"#, color: commentColor)
        }

        storage.endEditing()
        typingAttributes = [
            .font: font,
            .foregroundColor: baseColor,
            .paragraphStyle: paragraph
        ]
    }
}
