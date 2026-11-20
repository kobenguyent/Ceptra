import AppKit
import CeptraCore
import SwiftUI

/// Native macOS AppKit code editor built on an explicit TextKit 1 stack with:
/// - Per-tab scroll, cursor, and undo isolation (zero blank-viewport or cross-tab bleed on switch)
/// - Floating IntelliSense / auto-complete popup (CodeceptJS 4.x `I.*`, PageObjects, `steps.d.ts`, DSL, `@tags`, import paths, Gherkin)
/// - Symlink-like `⌘+Click` & `F12` navigation across imports, `require()`, config paths, `include` objects, and custom steps
/// - Sibling line-number gutter, high-contrast syntax highlighting, and Find & Replace (`⌘F`)
struct CodeEditorView: NSViewRepresentable {
    var documentID: String
    @Binding var text: String
    var language: String
    var fontSize: CGFloat = 13.0
    var workspace: CodeceptWorkspace?
    var completionIndex: WorkspaceCompletionIndex
    @Binding var jumpToLine: Int?
    var goToDefinitionTrigger: Int = 0
    var onNavigate: (NavigationTarget, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CeptraEditorContainerView {
        let container = CeptraEditorContainerView(
            documentID: documentID,
            text: text,
            language: language,
            fontSize: fontSize,
            delegate: context.coordinator
        )
        context.coordinator.container = container
        context.coordinator.currentDocumentID = documentID
        context.coordinator.lastGoToDefTrigger = goToDefinitionTrigger
        context.coordinator.wireCallbacks(for: container)
        context.coordinator.observe(container: container)
        return container
    }

    func updateNSView(_ container: CeptraEditorContainerView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        let textView = container.textView

        let documentChanged = coord.currentDocumentID != documentID
        let languageChanged = textView.editorLanguage != language
        let fontChanged = abs(textView.editorFontSize - fontSize) > 0.1

        textView.editorFontSize = fontSize
        textView.editorLanguage = language
        textView.tabWidth = 2
        textView.currentFileURL = URL(fileURLWithPath: documentID)

        if documentChanged {
            // 1. Persist outgoing tab's cursor & scroll offset only after initial layout has stabilized
            let outgoingID = coord.currentDocumentID
            if !outgoingID.isEmpty && container.hasCompletedInitialLayout {
                coord.savedStates[outgoingID] = TabViewState(
                    selectedRange: textView.selectedRange(),
                    scrollOrigin: container.scrollView.documentVisibleRect.origin
                )
            }

            // 2. Dismiss transient popups & hover highlights immediately
            coord.completionController.dismiss()
            textView.clearHoverLink()

            // 3. Swap document content cleanly with full layout & undo reset
            coord.currentDocumentID = documentID
            coord.isProgrammaticUpdate = true
            textView.string = text
            textView.restyleAllText()
            container.relayoutDocument()
            textView.undoManager?.removeAllActions()

            // 4. Restore incoming tab's cursor & scroll offset (or pin cleanly to top-left for freshly opened files)
            let maxLen = (text as NSString).length
            if let saved = coord.savedStates[documentID], jumpToLine == nil {
                let loc = min(max(0, saved.selectedRange.location), maxLen)
                let len = min(saved.selectedRange.length, max(0, maxLen - loc))
                textView.setSelectedRange(NSRange(location: loc, length: len))
                container.scrollToClampedOrigin(saved.scrollOrigin)
                if !container.hasCompletedInitialLayout {
                    container.pendingInitialScrollOrigin = saved.scrollOrigin
                }
            } else {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                container.scrollToClampedOrigin(.zero)
                if !container.hasCompletedInitialLayout {
                    container.pendingInitialScrollOrigin = .zero
                }
            }

            container.updateGutter()
            coord.isProgrammaticUpdate = false
        } else if textView.string != text {
            // External text mutation on the same tab (e.g. Insert Snippet)
            coord.isProgrammaticUpdate = true
            let savedSelection = textView.selectedRange()
            textView.string = text
            textView.restyleAllText()
            container.relayoutDocument()
            let maxLen = (text as NSString).length
            let safeLoc = min(savedSelection.location, maxLen)
            textView.setSelectedRange(NSRange(location: safeLoc, length: 0))
            container.updateGutter()
            coord.isProgrammaticUpdate = false
        } else if languageChanged || fontChanged {
            textView.restyleAllText()
            container.relayoutDocument()
            container.updateGutter()
        }

        if let targetLine = jumpToLine {
            container.scrollToLine(targetLine)
            DispatchQueue.main.async {
                self.jumpToLine = nil
            }
        }

        if coord.lastGoToDefTrigger != goToDefinitionTrigger {
            coord.lastGoToDefTrigger = goToDefinitionTrigger
            coord.triggerGoToDefinitionAtCaret()
        }
    }

    struct TabViewState {
        let selectedRange: NSRange
        let scrollOrigin: CGPoint
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var container: CeptraEditorContainerView?
        var currentDocumentID: String = ""
        var savedStates: [String: TabViewState] = [:]
        var isProgrammaticUpdate = false
        var lastGoToDefTrigger: Int = 0
        let completionController = CompletionPopupController()
        private var observers: [NSObjectProtocol] = []

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        deinit {
            completionController.dismiss()
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func wireCallbacks(for container: CeptraEditorContainerView) {
            let tv = container.textView

            completionController.onAccept = { [weak self] item, range in
                self?.acceptCompletion(item: item, replacementRange: range)
            }

            tv.onManualComplete = { [weak self] in
                self?.refreshCompletions(forceShow: true)
            }

            tv.onInterceptKeyDown = { [weak self] event in
                guard let self, self.completionController.isVisible else { return false }
                switch event.keyCode {
                case 125: // Down Arrow
                    self.completionController.moveSelection(delta: 1)
                    return true
                case 126: // Up Arrow
                    self.completionController.moveSelection(delta: -1)
                    return true
                case 36, 76, 48: // Return, Enter, Tab
                    return self.completionController.acceptCurrentSelection()
                case 53: // Escape
                    self.completionController.dismiss()
                    return true
                default:
                    return false
                }
            }

            tv.onResolveHoverLink = { [weak self] utf16Offset in
                guard let self, let workspace = self.parent.workspace else { return nil }
                return ImportNavigator.resolveTarget(
                    atUTF16Offset: utf16Offset,
                    in: tv.string,
                    sourceFileURL: URL(fileURLWithPath: self.currentDocumentID),
                    workspaceRoot: workspace.rootURL,
                    config: workspace.config
                )
            }

            tv.onNavigateSpan = { [weak self] span in
                guard let self else { return }
                self.completionController.dismiss()
                let currentLine = tv.currentLineNumber()
                self.parent.onNavigate(span.target, currentLine)
            }

            tv.onGoToDefinitionKey = { [weak self] in
                self?.triggerGoToDefinitionAtCaret()
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
                self?.completionController.dismiss()
            }
            let frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: container.textView,
                queue: .main
            ) { [weak self] _ in
                self?.container?.gutterView.needsDisplay = true
            }
            let resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.completionController.dismiss()
            }
            observers.append(contentsOf: [boundsObserver, frameObserver, resignObserver])
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
            refreshCompletions(forceShow: false)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            container?.gutterView.needsDisplay = true
            if !isProgrammaticUpdate && completionController.isVisible {
                refreshCompletions(forceShow: false)
            }
        }

        func triggerGoToDefinitionAtCaret() {
            guard let tv = container?.textView,
                  let workspace = parent.workspace else { return }
            let caret = tv.selectedRange().location
            if let span = ImportNavigator.resolveTarget(
                atUTF16Offset: caret,
                in: tv.string,
                sourceFileURL: URL(fileURLWithPath: currentDocumentID),
                workspaceRoot: workspace.rootURL,
                config: workspace.config
            ) {
                completionController.dismiss()
                parent.onNavigate(span.target, tv.currentLineNumber())
            }
        }

        func refreshCompletions(forceShow: Bool) {
            guard let tv = container?.textView else { return }
            let sel = tv.selectedRange()
            guard sel.length == 0 else {
                completionController.dismiss()
                return
            }

            let source = tv.string
            let offset = sel.location

            if !forceShow {
                guard shouldAutoTriggerCompletion(in: source, at: offset) else {
                    completionController.dismiss()
                    return
                }
            }

            guard let result = IntelliSenseEngine.completions(
                in: source,
                cursorUTF16Offset: offset,
                language: tv.editorLanguage,
                sourceFileURL: URL(fileURLWithPath: currentDocumentID),
                workspace: parent.workspace,
                index: parent.completionIndex
            ), !result.items.isEmpty else {
                completionController.dismiss()
                return
            }

            // Avoid popping up when the single item already matches the exact typed word
            if !forceShow, result.items.count == 1, result.replacementRange.length > 0 {
                let typed = (source as NSString).substring(with: result.replacementRange)
                if result.items[0].label == typed && result.items[0].insertText == typed {
                    completionController.dismiss()
                    return
                }
            }

            completionController.present(result: result, in: tv)
        }

        private func shouldAutoTriggerCompletion(in source: String, at utf16Offset: Int) -> Bool {
            let ns = source as NSString
            guard utf16Offset > 0, utf16Offset <= ns.length else { return false }
            let prevChar = ns.character(at: utf16Offset - 1)
            // Always trigger immediately on '.', '@', or '/' (import path)
            if prevChar == 46 || prevChar == 64 || prevChar == 47 { // '.', '@', '/'
                return true
            }
            // Otherwise trigger once at least 2 contiguous identifier chars have been typed
            func isIdent(_ c: unichar) -> Bool {
                (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 36
            }
            guard isIdent(prevChar) else { return false }
            var count = 0
            var idx = utf16Offset - 1
            while idx >= 0 && isIdent(ns.character(at: idx)) {
                count += 1
                idx -= 1
            }
            if count >= 2 { return true }
            // Also trigger on 1 char immediately after '.' or '@'
            if idx >= 0 && (ns.character(at: idx) == 46 || ns.character(at: idx) == 64) {
                return true
            }
            return false
        }

        private func acceptCompletion(item: CompletionItem, replacementRange: NSRange) {
            guard let tv = container?.textView else { return }
            let nsLen = (tv.string as NSString).length
            guard replacementRange.location <= nsLen,
                  NSMaxRange(replacementRange) <= nsLen else {
                completionController.dismiss()
                return
            }

            completionController.dismiss()
            tv.insertText(item.insertText, replacementRange: replacementRange)

            if item.cursorBackOffset > 0 {
                let insertedEnd = replacementRange.location + (item.insertText as NSString).length
                let targetCaret = max(replacementRange.location, insertedEnd - item.cursorBackOffset)
                let clamped = min(targetCaret, (tv.string as NSString).length)
                tv.setSelectedRange(NSRange(location: clamped, length: 0))
            }
        }
    }
}

// MARK: - Flipped Clip View (Keeps Document Origin Pinned at Top-Left y = 0)

private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - Container View (TextKit 1 + Sibling Gutter)

final class CeptraEditorContainerView: NSView {
    let scrollView: NSScrollView
    let textView: CeptraCodeTextView
    let gutterView: LineNumberGutterView
    private var gutterWidthConstraint: NSLayoutConstraint?

    var hasCompletedInitialLayout = false
    var pendingInitialScrollOrigin: CGPoint? = .zero
    var pendingInitialJumpLine: Int? = nil

    init(documentID: String, text: String, language: String, fontSize: CGFloat, delegate: NSTextViewDelegate) {
        self.scrollView = NSScrollView()
        let clipView = FlippedClipView()
        clipView.drawsBackground = true
        clipView.backgroundColor = NSColor(red: 0.075, green: 0.082, blue: 0.102, alpha: 1.0)
        self.scrollView.contentView = clipView

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
        textView.currentFileURL = URL(fileURLWithPath: documentID)
        textView.editorLanguage = language
        textView.editorFontSize = fontSize
        textView.configureDefaults()

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(red: 0.075, green: 0.082, blue: 0.102, alpha: 1.0)
        scrollView.borderType = .noBorder

        textView.string = text
        textView.restyleAllText()
        textView.setSelectedRange(NSRange(location: 0, length: 0))

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

        relayoutDocument()
        scrollToClampedOrigin(.zero)
        updateGutter()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layout() {
        super.layout()
        let clipSize = scrollView.contentView.bounds.size
        guard clipSize.width > 0 && clipSize.height > 0 else { return }

        if !hasCompletedInitialLayout {
            hasCompletedInitialLayout = true
            relayoutDocument()
            if let targetLine = pendingInitialJumpLine {
                pendingInitialJumpLine = nil
                pendingInitialScrollOrigin = nil
                scrollToLine(targetLine)
            } else if let targetOrigin = pendingInitialScrollOrigin {
                pendingInitialScrollOrigin = nil
                scrollToClampedOrigin(targetOrigin)
            }
            gutterView.needsDisplay = true
            return
        }

        // Keep textView origin pinned at (0, 0) and minimum size aligned to viewport width/height
        textView.minSize = clipSize
        if textView.frame.origin != .zero || textView.frame.width < clipSize.width || textView.frame.height < clipSize.height {
            textView.frame = NSRect(
                origin: .zero,
                size: NSSize(
                    width: max(textView.frame.width, clipSize.width),
                    height: max(textView.frame.height, clipSize.height)
                )
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        gutterView.needsDisplay = true
    }

    /// Forces TextKit to recompute the exact document frame immediately (crucial when switching from a
    /// long file to a short file so the scroll viewport clamps cleanly instead of staying blank below EOF).
    func relayoutDocument() {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let clipSize = scrollView.contentView.bounds.size
        let insets = textView.textContainerInset
        let targetWidth = max(clipSize.width, ceil(usedRect.width + insets.width * 2 + 40))
        let targetHeight = max(clipSize.height, ceil(usedRect.height + insets.height * 2 + 40))
        textView.minSize = clipSize
        textView.frame = NSRect(origin: .zero, size: NSSize(width: targetWidth, height: targetHeight))
        textView.needsDisplay = true
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.needsDisplay = true
    }

    func scrollToClampedOrigin(_ origin: CGPoint) {
        let clipView = scrollView.contentView
        let docSize = textView.frame.size
        let visibleSize = clipView.bounds.size
        let maxX = max(0, docSize.width - visibleSize.width)
        let maxY = max(0, docSize.height - visibleSize.height)
        let clamped = NSPoint(
            x: min(max(0, origin.x), maxX),
            y: min(max(0, origin.y), maxY)
        )
        clipView.scroll(to: clamped)
        scrollView.reflectScrolledClipView(clipView)
        gutterView.needsDisplay = true
    }

    func updateGutter() {
        let lineCount = max(1, textView.string.components(separatedBy: "\n").count)
        let digits = max(3, String(lineCount).count)
        gutterWidthConstraint?.constant = CGFloat(digits * 8 + 22)
        gutterView.needsDisplay = true
    }

    func scrollToLine(_ oneBasedLine: Int) {
        if scrollView.contentView.bounds.size.height <= 0 {
            pendingInitialJumpLine = oneBasedLine
            pendingInitialScrollOrigin = nil
            return
        }
        relayoutDocument()
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
        scrollView.reflectScrolledClipView(scrollView.contentView)
        gutterView.needsDisplay = true
    }
}

// MARK: - Line Number Gutter

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

        NSColor.white.withAlphaComponent(0.06).setFill()
        NSRect(x: bounds.width - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView else { return }

        let visibleRect = scrollView.documentVisibleRect
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

        if nsString.length == 0 || layoutManager.numberOfGlyphs == 0 || visibleGlyphRange.location >= layoutManager.numberOfGlyphs {
            let label = "1" as NSString
            let textSize = label.size(withAttributes: activeAttrs)
            label.draw(
                at: NSPoint(x: bounds.width - textSize.width - 10, y: textView.textContainerInset.height),
                withAttributes: activeAttrs
            )
            return
        }

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

// MARK: - Code TextView (Syntax Highlighting + IntelliSense Keys + ⌘-Click Import Navigation)

final class CeptraCodeTextView: NSTextView {
    var currentFileURL: URL?
    var editorLanguage: String = "javascript"
    var editorFontSize: CGFloat = 13.0
    var tabWidth: Int = 2

    var onInterceptKeyDown: ((NSEvent) -> Bool)?
    var onManualComplete: (() -> Void)?
    var onResolveHoverLink: ((Int) -> NavigableSpan?)?
    var onNavigateSpan: ((NavigableSpan) -> Void)?
    var onGoToDefinitionKey: (() -> Void)?

    private var hoveredSpan: NavigableSpan?
    private var lastMouseWindowPoint: NSPoint?

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    func currentLineNumber() -> Int {
        let ns = string as NSString
        let loc = min(selectedRange().location, ns.length)
        guard loc > 0 else { return 1 }
        return ns.substring(to: loc).components(separatedBy: "\n").count
    }

    override func keyDown(with event: NSEvent) {
        // Ctrl+Space -> trigger IntelliSense manually
        if event.modifierFlags.contains(.control) && event.keyCode == 49 {
            onManualComplete?()
            return
        }
        // F12 -> Go to Definition / Follow Import
        if event.keyCode == 111 {
            onGoToDefinitionKey?()
            return
        }
        if onInterceptKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func complete(_ sender: Any?) {
        onManualComplete?()
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if event.modifierFlags.contains(.command), let pt = lastMouseWindowPoint {
            updateHoverLink(atWindowPoint: pt, commandPressed: true)
        } else {
            clearHoverLink()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        lastMouseWindowPoint = event.locationInWindow
        let cmdDown = event.modifierFlags.contains(.command)
        if cmdDown {
            updateHoverLink(atWindowPoint: event.locationInWindow, commandPressed: true)
        } else if hoveredSpan != nil {
            clearHoverLink()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        lastMouseWindowPoint = nil
        clearHoverLink()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if let span = resolveSpan(atWindowPoint: event.locationInWindow) {
                clearHoverLink()
                onNavigateSpan?(span)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func resolveSpan(atWindowPoint windowPoint: NSPoint) -> NavigableSpan? {
        let localPoint = convert(windowPoint, from: nil)
        guard let layoutManager, let textContainer else { return nil }
        let containerPoint = NSPoint(
            x: localPoint.x - textContainerOrigin.x,
            y: localPoint.y - textContainerOrigin.y
        )
        var fraction: CGFloat = 0
        let glyphIdx = layoutManager.glyphIndex(for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let charIdx = layoutManager.characterIndexForGlyph(at: glyphIdx)
        guard charIdx < (string as NSString).length else { return nil }
        return onResolveHoverLink?(charIdx)
    }

    private func updateHoverLink(atWindowPoint windowPoint: NSPoint, commandPressed: Bool) {
        guard commandPressed, let span = resolveSpan(atWindowPoint: windowPoint) else {
            clearHoverLink()
            return
        }
        if hoveredSpan == span { return }
        clearHoverLink()
        hoveredSpan = span
        applyHoverHighlight(for: span)
        let symNote = span.target.isSymlink ? " (symlink)" : ""
        let lineNote = span.target.lineNumber.map { ":\($0)" } ?? ""
        toolTip = "⌘ Click to open \(span.target.displayLabel)\(lineNote)\(symNote)"
        NSCursor.pointingHand.set()
    }

    func clearHoverLink() {
        if let prev = hoveredSpan, let layoutManager {
            let fullLen = (string as NSString).length
            if prev.range.location <= fullLen && NSMaxRange(prev.range) <= fullLen {
                layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: prev.range)
                layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: prev.range)
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: prev.range)
            }
        }
        hoveredSpan = nil
        toolTip = nil
        NSCursor.iBeam.set()
    }

    private func applyHoverHighlight(for span: NavigableSpan) {
        guard let layoutManager else { return }
        let fullLen = (string as NSString).length
        guard span.range.location <= fullLen, NSMaxRange(span.range) <= fullLen else { return }
        let linkCyan = NSColor(red: 0.36, green: 0.86, blue: 0.98, alpha: 1.0)
        layoutManager.addTemporaryAttributes([
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: linkCyan,
            .foregroundColor: linkCyan
        ], forCharacterRange: span.range)
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
        } else if editorLanguage == "yaml" {
            apply(#"^\s*[A-Za-z0-9_.-]+\s*(?=:)"#, color: dslColor, options: [.anchorsMatchLines])
            apply(#"'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*""#, color: stringColor)
            apply(#"\b(?:true|false|null|yes|no)\b"#, color: keywordColor)
            apply(#"#[^\n]*"#, color: commentColor)
        } else if editorLanguage == "markdown" {
            apply(#"^#{1,6}\s+.*$"#, color: dslColor, useBold: true, options: [.anchorsMatchLines])
            apply(#"`[^`\n]+`"#, color: actorColor)
            apply(#"^\s*[-*+]\s+"#, color: keywordColor, options: [.anchorsMatchLines])
        } else if editorLanguage == "shell" {
            apply(#"\b(?:if|then|else|fi|for|in|do|done|case|esac|export|local|return|set|exit|echo|cd)\b"#, color: keywordColor)
            apply(#"'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*""#, color: stringColor)
            apply(#"\$[A-Za-z0-9_{}?@#*-]+"#, color: dslColor)
            apply(#"#[^\n]*"#, color: commentColor)
        } else if editorLanguage == "xml" {
            apply(#"</?[A-Za-z0-9_:-]+|/?>"#, color: dslColor)
            apply(#"\b[A-Za-z0-9_:-]+(?==)"#, color: actorColor)
            apply(#""[^"]*""#, color: stringColor)
            apply(#"<!--[\s\S]*?-->"#, color: commentColor)
        } else if editorLanguage == "plaintext" {
            apply(#"^\s*#.*$"#, color: commentColor, options: [.anchorsMatchLines])
            apply(#"^[A-Z0-9_]+(?==)"#, color: dslColor, options: [.anchorsMatchLines])
        } else {
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

// MARK: - Floating Native IntelliSense Completion Panel

final class CompletionPopupController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var panel: NSPanel?
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var currentResult: CompletionResult?
    var onAccept: ((CompletionItem, NSRange) -> Void)?

    var isVisible: Bool {
        panel?.isVisible == true && !(currentResult?.items.isEmpty ?? true)
    }

    override init() {
        super.init()
        setupPanel()
    }

    private func setupPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = true
        p.appearance = NSAppearance(named: .darkAqua)

        let container = NSView(frame: p.contentRect(forFrameRect: p.frame))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.105, green: 0.116, blue: 0.148, alpha: 0.98).cgColor
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        container.layer?.masksToBounds = true

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        col.width = 382
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .regular
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleSingleClick)
        tableView.doubleAction = #selector(handleDoubleClick)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])

        p.contentView = container
        self.panel = p
    }

    func present(result: CompletionResult, in textView: NSTextView) {
        guard let panel, let hostWindow = textView.window else { return }
        currentResult = result
        tableView.reloadData()

        if !result.items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }

        let visibleRows = min(result.items.count, 8)
        let popupHeight = CGFloat(visibleRows) * 27.0 + 10.0
        let popupWidth: CGFloat = 400

        // Compute screen position immediately below caret
        let caretRange = NSRange(location: result.replacementRange.location, length: 0)
        let screenRect = textView.firstRect(forCharacterRange: caretRange, actualRange: nil)
        var originX = screenRect.minX
        var originY = screenRect.minY - popupHeight - 4

        if let screenFrame = hostWindow.screen?.visibleFrame {
            if originX + popupWidth > screenFrame.maxX {
                originX = max(screenFrame.minX + 8, screenFrame.maxX - popupWidth - 8)
            }
            if originY < screenFrame.minY {
                // Flip above caret when near bottom of screen
                originY = screenRect.maxY + 4
            }
        }

        panel.setFrame(NSRect(x: originX, y: originY, width: popupWidth, height: popupHeight), display: true)
        if panel.parent !== hostWindow {
            hostWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func dismiss() {
        currentResult = nil
        guard let panel else { return }
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        panel.orderOut(nil)
    }

    func moveSelection(delta: Int) {
        guard let count = currentResult?.items.count, count > 0 else { return }
        let current = tableView.selectedRow
        let next = current < 0 ? 0 : (current + delta + count) % count
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @discardableResult
    func acceptCurrentSelection() -> Bool {
        guard let result = currentResult, !result.items.isEmpty else { return false }
        let row = max(0, min(tableView.selectedRow, result.items.count - 1))
        let item = result.items[row]
        onAccept?(item, result.replacementRange)
        return true
    }

    @objc private func handleSingleClick() {
        let row = tableView.clickedRow
        guard row >= 0, let result = currentResult, row < result.items.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, let result = currentResult, row < result.items.count else { return }
        onAccept?(result.items[row], result.replacementRange)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        currentResult?.items.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = currentResult?.items[row] else { return nil }

        let cell = NSView(frame: NSRect(x: 0, y: 0, width: 382, height: 26))

        let badge = NSTextField(labelWithString: item.kind.badgeLetter)
        badge.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        badge.alignment = .center
        badge.textColor = badgeColor(for: item.kind)
        badge.wantsLayer = true
        badge.layer?.backgroundColor = badgeColor(for: item.kind).withAlphaComponent(0.18).cgColor
        badge.layer?.cornerRadius = 4
        badge.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: item.label + item.signature)
        title.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
        title.textColor = NSColor(red: 0.93, green: 0.95, blue: 0.99, alpha: 1.0)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(labelWithString: item.detail)
        detail.font = NSFont.systemFont(ofSize: 10.5)
        detail.textColor = NSColor(red: 0.56, green: 0.61, blue: 0.70, alpha: 1.0)
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(badge)
        cell.addSubview(title)
        cell.addSubview(detail)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 18),
            badge.heightAnchor.constraint(equalToConstant: 18),

            title.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 140)
        ])

        return cell
    }

    private func badgeColor(for kind: CompletionKind) -> NSColor {
        switch kind {
        case .action: return NSColor(red: 0.24, green: 0.86, blue: 0.60, alpha: 1.0)
        case .method: return NSColor(red: 0.34, green: 0.82, blue: 0.96, alpha: 1.0)
        case .dsl: return NSColor(red: 0.44, green: 0.62, blue: 1.0, alpha: 1.0)
        case .keyword: return NSColor(red: 0.76, green: 0.56, blue: 0.98, alpha: 1.0)
        case .tag: return NSColor(red: 0.98, green: 0.50, blue: 0.72, alpha: 1.0)
        case .path: return NSColor(red: 0.98, green: 0.76, blue: 0.42, alpha: 1.0)
        case .symbol: return NSColor(red: 0.72, green: 0.78, blue: 0.88, alpha: 1.0)
        }
    }
}
