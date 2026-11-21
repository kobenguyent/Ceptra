import AppKit
import CeptraCore
import SwiftUI

/// Native macOS AppKit code editor built on an explicit TextKit 1 stack with:
/// - Per-tab scroll, cursor, fold, and undo isolation (zero blank-viewport or cross-tab bleed on switch)
/// - Crisp line numbers + non-destructive code folding (collapse/expand blocks, arrays, comments, Gherkin, YAML, Markdown)
/// - Floating IntelliSense / auto-complete popup (CodeceptJS 4.x `I.*`, PageObjects, `steps.d.ts`, DSL, `@tags`, import paths, Gherkin)
/// - Symlink-like `⌘+Click` & `F12` navigation across imports, `require()`, config paths, `include` objects, and custom steps
/// - Sibling line-number & fold gutter, high-contrast syntax highlighting, and Find & Replace (`⌘F`)
struct CodeEditorView: NSViewRepresentable {
    var documentID: String
    @Binding var text: String
    var language: String
    var fontSize: CGFloat = 13.0
    var workspace: CodeceptWorkspace?
    var completionIndex: WorkspaceCompletionIndex
    @Binding var jumpToLine: Int?
    var goToDefinitionTrigger: Int = 0
    var foldActionTrigger: Int = 0
    var foldAction: EditorFoldAction? = nil
    var onNavigate: (NavigationTarget, Int) -> Void
    var breakpointsByLine: [Int: DebugBreakpoint] = [:]
    var pausedLine: Int? = nil
    var onToggleBreakpoint: ((Int) -> Void)? = nil
    var onEditBreakpoint: ((DebugBreakpoint) -> Void)? = nil
    var onRemoveBreakpoint: ((UUID) -> Void)? = nil

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
        context.coordinator.lastFoldActionTrigger = foldActionTrigger
        context.coordinator.lastPausedLine = pausedLine
        context.coordinator.wireCallbacks(for: container)
        context.coordinator.observe(container: container)
        container.setDebugState(
            documentFilePath: documentID,
            breakpointsByLine: breakpointsByLine,
            pausedLine: pausedLine
        )
        if let pausedLine {
            container.scrollToLine(pausedLine)
        }
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
        container.lineLayoutDelegate.fontSize = fontSize
        textView.editorLanguage = language
        textView.tabWidth = 2
        textView.currentFileURL = URL(fileURLWithPath: documentID)

        if documentChanged {
            // 1. Persist outgoing tab's cursor, scroll offset, and collapsed fold regions
            let outgoingID = coord.currentDocumentID
            if !outgoingID.isEmpty && container.hasCompletedInitialLayout {
                coord.savedStates[outgoingID] = TabViewState(
                    selectedRange: textView.selectedRange(),
                    scrollOrigin: container.scrollView.documentVisibleRect.origin,
                    collapsedStartLines: container.collapsedStartLines
                )
            }

            // 2. Dismiss transient popups & hover highlights immediately
            coord.completionController.dismiss()
            textView.clearHoverLink()

            // 3. Swap document content cleanly with full fold, layout & undo reset
            coord.currentDocumentID = documentID
            coord.isProgrammaticUpdate = true
            let incomingCollapsed = coord.savedStates[documentID]?.collapsedStartLines ?? []
            container.clearFoldsWithoutRelayout()
            textView.string = text
            textView.restyleAllText()
            container.refreshFolds(restoringCollapsedStartLines: incomingCollapsed)
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
            let prevCollapsed = container.collapsedStartLines
            container.clearFoldsWithoutRelayout()
            textView.string = text
            textView.restyleAllText()
            container.refreshFolds(restoringCollapsedStartLines: prevCollapsed)
            container.relayoutDocument()
            let maxLen = (text as NSString).length
            let safeLoc = min(savedSelection.location, maxLen)
            textView.setSelectedRange(NSRange(location: safeLoc, length: 0))
            container.updateGutter()
            coord.isProgrammaticUpdate = false
        } else if languageChanged || fontChanged {
            let prevCollapsed = container.collapsedStartLines
            textView.restyleAllText()
            container.refreshFolds(restoringCollapsedStartLines: prevCollapsed)
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

        if coord.lastFoldActionTrigger != foldActionTrigger {
            coord.lastFoldActionTrigger = foldActionTrigger
            if let action = foldAction {
                container.performFoldAction(action)
            }
        }

        container.setDebugState(
            documentFilePath: documentID,
            breakpointsByLine: breakpointsByLine,
            pausedLine: pausedLine
        )
        if coord.lastPausedLine != pausedLine || (documentChanged && pausedLine != nil) {
            coord.lastPausedLine = pausedLine
            if let targetPausedLine = pausedLine {
                container.scrollToLine(targetPausedLine)
            }
        }
    }

    struct TabViewState {
        let selectedRange: NSRange
        let scrollOrigin: CGPoint
        let collapsedStartLines: Set<Int>
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var container: CeptraEditorContainerView?
        var currentDocumentID: String = ""
        var savedStates: [String: TabViewState] = [:]
        var isProgrammaticUpdate = false
        var lastGoToDefTrigger: Int = 0
        var lastFoldActionTrigger: Int = 0
        var lastPausedLine: Int? = nil
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

            tv.onFoldShortcut = { [weak container] action in
                container?.performFoldAction(action)
            }

            tv.onExpandFoldedLine = { [weak container] startLine in
                container?.setFolded(false, atStartLine: startLine)
            }

            container.gutterView.onToggleFold = { [weak container] startLine in
                container?.toggleFold(atStartLine: startLine)
            }

            container.gutterView.onSelectLine = { [weak container] lineNumber in
                container?.selectEntireLine(lineNumber)
            }

            container.gutterView.onToggleBreakpoint = { [weak self] lineNumber in
                self?.parent.onToggleBreakpoint?(lineNumber)
            }

            container.gutterView.onEditBreakpoint = { [weak self] breakpoint in
                self?.parent.onEditBreakpoint?(breakpoint)
            }

            container.gutterView.onRemoveBreakpoint = { [weak self] id in
                self?.parent.onRemoveBreakpoint?(id)
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

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if !isProgrammaticUpdate, let container {
                let overlapping = CodeFoldingEngine.collapsedStartLinesIntersecting(
                    characterRange: affectedCharRange,
                    regions: container.foldableRegions,
                    collapsedStartLines: container.collapsedStartLines
                )
                if !overlapping.isEmpty {
                    container.unfold(startLines: overlapping)
                }
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate,
                  let codeView = notification.object as? CeptraCodeTextView else { return }
            codeView.restyleAllText()
            if let container {
                let prevCollapsed = container.collapsedStartLines
                container.refreshFolds(restoringCollapsedStartLines: prevCollapsed)
                container.relayoutDocument()
                container.updateGutter()
            }

            let updated = codeView.string
            if parent.text != updated {
                parent.text = updated
            }
            refreshCompletions(forceShow: false)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            container?.gutterView.needsDisplay = true
            container?.textView.needsDisplay = true
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

// MARK: - Unified TextKit 1 Layout Delegate (Centered Line Metrics + Non-Destructive Code Folding)

/// Combines two TextKit 1 layout behaviors on a single `NSLayoutManagerDelegate`:
/// 1. Vertically centers every visible line inside an integer-height line fragment box (`1.42x` line height)
/// 2. Suppresses glyphs & control characters inside folded ranges without mutating `NSTextStorage`
final class CeptraCenteredLineLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    var fontSize: CGFloat = 13.0
    var lineHeightMultiple: CGFloat = 1.42
    /// Sorted, disjoint UTF-16 character ranges hidden when folded.
    var hiddenRanges: [NSRange] = []

    static func metrics(fontSize: CGFloat, lineHeightMultiple: CGFloat = 1.42, in layoutManager: NSLayoutManager) -> (lineHeight: CGFloat, baseline: CGFloat) {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let naturalH = layoutManager.defaultLineHeight(for: font)
        let naturalBase = layoutManager.defaultBaselineOffset(for: font)
        let targetH = round(naturalH * lineHeightMultiple)
        let halfExtra = round(max(0, targetH - naturalH) * 0.5)
        return (targetH, naturalBase + halfExtra)
    }

    func isCharacterHidden(_ charIndex: Int) -> Bool {
        guard !hiddenRanges.isEmpty else { return false }
        var low = 0
        var high = hiddenRanges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let r = hiddenRanges[mid]
            if charIndex < r.location {
                high = mid - 1
            } else if charIndex >= NSMaxRange(r) {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard !hiddenRanges.isEmpty else { return 0 }
        let count = glyphRange.length
        guard count > 0 else { return 0 }

        var anyHidden = false
        for i in 0..<count {
            if isCharacterHidden(charIndexes[i]) {
                anyHidden = true
                break
            }
        }
        guard anyHidden else { return 0 }

        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
        var newProps = Array(UnsafeBufferPointer(start: props, count: count))
        for i in 0..<count {
            if isCharacterHidden(charIndexes[i]) {
                newGlyphs[i] = CGGlyph(NSNullGlyph)
                newProps[i] = .null
            }
        }
        layoutManager.setGlyphs(
            newGlyphs,
            properties: newProps,
            characterIndexes: charIndexes,
            font: aFont,
            forGlyphRange: glyphRange
        )
        return count
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        if isCharacterHidden(charIndex) {
            return .zeroAdvancement
        }
        return action
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        let m = Self.metrics(fontSize: fontSize, lineHeightMultiple: lineHeightMultiple, in: layoutManager)
        lineFragmentRect.pointee.size.height = m.lineHeight
        lineFragmentUsedRect.pointee.size.height = m.lineHeight
        baselineOffset.pointee = m.baseline
        return true
    }
}

final class CeptraEditorContainerView: NSView {
    let scrollView: NSScrollView
    let textView: CeptraCodeTextView
    let gutterView: LineNumberGutterView
    let lineLayoutDelegate = CeptraCenteredLineLayoutDelegate()
    private var gutterWidth: CGFloat = 78

    private(set) var lineIndex = LineIndexTable(text: "")
    private(set) var foldableRegions: [FoldableRegion] = []
    private(set) var collapsedStartLines: Set<Int> = []

    var hasCompletedInitialLayout = false
    var pendingInitialScrollOrigin: CGPoint? = .zero
    var pendingInitialJumpLine: Int? = nil

    init(documentID: String, text: String, language: String, fontSize: CGFloat, delegate: NSTextViewDelegate) {
        self.scrollView = NSScrollView()
        let clipView = FlippedClipView()
        clipView.drawsBackground = true
        clipView.backgroundColor = NSColor(red: 0.075, green: 0.082, blue: 0.102, alpha: 1.0)
        self.scrollView.contentView = clipView

        self.lineLayoutDelegate.fontSize = fontSize

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.delegate = lineLayoutDelegate
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        self.textView = CeptraCodeTextView(frame: .zero, textContainer: textContainer)
        self.gutterView = LineNumberGutterView(textView: textView, scrollView: scrollView)

        super.init(frame: .zero)

        appearance = NSAppearance(named: .darkAqua)
        clipsToBounds = true
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

        addSubview(gutterView)
        addSubview(scrollView)

        refreshFolds(restoringCollapsedStartLines: [])
        relayoutDocument()
        scrollToClampedOrigin(.zero)
        updateGutter()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layout() {
        super.layout()
        let b = bounds
        let gw = min(gutterWidth, max(0, b.width))
        let targetGutterFrame = NSRect(x: 0, y: 0, width: gw, height: b.height)
        if gutterView.frame != targetGutterFrame {
            gutterView.frame = targetGutterFrame
        }
        let targetScrollFrame = NSRect(x: gw, y: 0, width: max(0, b.width - gw), height: b.height)
        if scrollView.frame != targetScrollFrame {
            scrollView.frame = targetScrollFrame
        }

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

    // MARK: - Code Folding Management

    func clearFoldsWithoutRelayout() {
        collapsedStartLines = []
        lineLayoutDelegate.hiddenRanges = []
    }

    func refreshFolds(restoringCollapsedStartLines previousCollapsed: Set<Int>) {
        let currentText = textView.string
        let newIndex = LineIndexTable(text: currentText)
        let newRegions = CodeFoldingEngine.detectRegions(
            in: currentText,
            language: textView.editorLanguage,
            lineIndex: newIndex
        )
        let validCollapsed = CodeFoldingEngine.validCollapsedStartLines(from: previousCollapsed, regions: newRegions)

        self.lineIndex = newIndex
        self.foldableRegions = newRegions
        self.collapsedStartLines = validCollapsed

        applyFoldRangesToLayoutManager(previousRanges: lineLayoutDelegate.hiddenRanges)
        syncFoldStateToViews()
    }

    func toggleFold(atStartLine startLine: Int) {
        let shouldCollapse = !collapsedStartLines.contains(startLine)
        setFolded(shouldCollapse, atStartLine: startLine)
    }

    func setFolded(_ collapsed: Bool, atStartLine startLine: Int) {
        guard let region = foldableRegions.first(where: { $0.startLine == startLine }) else { return }
        let prevRanges = lineLayoutDelegate.hiddenRanges
        if collapsed {
            collapsedStartLines.insert(startLine)
            // Keep caret outside hidden range so editing remains intuitive
            let sel = textView.selectedRange()
            if sel.location > region.hiddenRange.location && sel.location < NSMaxRange(region.hiddenRange) {
                textView.setSelectedRange(NSRange(location: region.hiddenRange.location, length: 0))
            }
        } else {
            collapsedStartLines.remove(startLine)
        }
        applyFoldRangesToLayoutManager(previousRanges: prevRanges)
        syncFoldStateToViews()
        relayoutDocument()
        scrollToClampedOrigin(scrollView.documentVisibleRect.origin)
    }

    func unfold(startLines: Set<Int>) {
        guard !startLines.isEmpty else { return }
        let prevRanges = lineLayoutDelegate.hiddenRanges
        collapsedStartLines.subtract(startLines)
        applyFoldRangesToLayoutManager(previousRanges: prevRanges)
        syncFoldStateToViews()
        relayoutDocument()
    }

    func performFoldAction(_ action: EditorFoldAction) {
        let caretLine = lineIndex.lineNumber(forUTF16Offset: textView.selectedRange().location)
        switch action {
        case .collapseAtCaret:
            if let region = CodeFoldingEngine.innermostRegion(containingLine: caretLine, in: foldableRegions) {
                if !collapsedStartLines.contains(region.startLine) {
                    setFolded(true, atStartLine: region.startLine)
                } else {
                    // Already collapsed at innermost -> collapse next enclosing unfolded region
                    let enclosing = foldableRegions
                        .filter { $0.startLine <= caretLine && caretLine <= $0.endLine && !collapsedStartLines.contains($0.startLine) }
                        .min { ($0.endLine - $0.startLine) < ($1.endLine - $1.startLine) }
                    if let enclosing {
                        setFolded(true, atStartLine: enclosing.startLine)
                    }
                }
            }
        case .expandAtCaret:
            if collapsedStartLines.contains(caretLine) {
                setFolded(false, atStartLine: caretLine)
            } else {
                let hiding = CodeFoldingEngine.collapsedStartLinesHiding(
                    line: caretLine,
                    regions: foldableRegions,
                    collapsedStartLines: collapsedStartLines
                )
                if !hiding.isEmpty {
                    unfold(startLines: hiding)
                } else if let region = CodeFoldingEngine.innermostRegion(containingLine: caretLine, in: foldableRegions),
                          collapsedStartLines.contains(region.startLine) {
                    setFolded(false, atStartLine: region.startLine)
                }
            }
        case .collapseAll:
            guard !foldableRegions.isEmpty else { return }
            let prevRanges = lineLayoutDelegate.hiddenRanges
            collapsedStartLines = Set(foldableRegions.map(\.startLine))
            applyFoldRangesToLayoutManager(previousRanges: prevRanges)
            syncFoldStateToViews()
            relayoutDocument()
            scrollToClampedOrigin(scrollView.documentVisibleRect.origin)
        case .expandAll:
            guard !collapsedStartLines.isEmpty else { return }
            let prevRanges = lineLayoutDelegate.hiddenRanges
            collapsedStartLines.removeAll()
            applyFoldRangesToLayoutManager(previousRanges: prevRanges)
            syncFoldStateToViews()
            relayoutDocument()
            scrollToClampedOrigin(scrollView.documentVisibleRect.origin)
        }
    }

    func selectEntireLine(_ oneBasedLine: Int) {
        let hiding = CodeFoldingEngine.collapsedStartLinesHiding(
            line: oneBasedLine,
            regions: foldableRegions,
            collapsedStartLines: collapsedStartLines
        )
        if !hiding.isEmpty {
            unfold(startLines: hiding)
        }
        let range = lineIndex.fullLineRange(forOneBasedLine: oneBasedLine)
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        gutterView.needsDisplay = true
        textView.needsDisplay = true
    }

    private func applyFoldRangesToLayoutManager(previousRanges: [NSRange]) {
        let nextRanges = CodeFoldingEngine.mergedHiddenRanges(
            regions: foldableRegions,
            collapsedStartLines: collapsedStartLines
        )
        lineLayoutDelegate.hiddenRanges = nextRanges

        guard let layoutManager = textView.layoutManager,
              let storage = textView.textStorage else { return }
        let fullLen = storage.length
        guard fullLen > 0 else { return }

        // Only invalidate when fold ranges actually changed or exist
        if !previousRanges.isEmpty || !nextRanges.isEmpty {
            let fullRange = NSRange(location: 0, length: fullLen)
            layoutManager.invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        }
    }

    private func syncFoldStateToViews() {
        let regionMap = Dictionary(uniqueKeysWithValues: foldableRegions.map { ($0.startLine, $0) })
        gutterView.lineIndex = lineIndex
        gutterView.regionsByStartLine = regionMap
        gutterView.collapsedStartLines = collapsedStartLines
        gutterView.needsDisplay = true

        textView.lineIndex = lineIndex
        textView.collapsedRegions = foldableRegions.filter { collapsedStartLines.contains($0.startLine) }
        textView.hiddenRanges = lineLayoutDelegate.hiddenRanges
        textView.needsDisplay = true
    }

    /// Forces TextKit to recompute the exact document frame immediately (crucial when switching from a
    /// long file to a short file or collapsing/expanding blocks so the scroll viewport clamps cleanly).
    func relayoutDocument() {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let extraRect = layoutManager.extraLineFragmentRect
        let totalContentHeight = max(usedRect.maxY, extraRect.maxY)
        let clipSize = scrollView.contentView.bounds.size
        let insets = textView.textContainerInset
        let badgePadding: CGFloat = collapsedStartLines.isEmpty ? 40 : 140
        let targetWidth = max(clipSize.width, ceil(usedRect.width + insets.width * 2 + badgePadding))
        let targetHeight = max(clipSize.height, ceil(totalContentHeight + insets.height * 2 + 40))
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

    func setDebugState(
        documentFilePath: String,
        breakpointsByLine: [Int: DebugBreakpoint],
        pausedLine: Int?
    ) {
        var gutterChanged = false
        var textChanged = false

        if gutterView.documentFilePath != documentFilePath {
            gutterView.documentFilePath = documentFilePath
        }
        if gutterView.breakpointsByLine != breakpointsByLine {
            gutterView.breakpointsByLine = breakpointsByLine
            gutterChanged = true
        }
        if gutterView.pausedLine != pausedLine {
            gutterView.pausedLine = pausedLine
            gutterChanged = true
        }
        if textView.pausedLine != pausedLine {
            textView.pausedLine = pausedLine
            textChanged = true
        }

        if gutterChanged {
            gutterView.needsDisplay = true
        }
        if textChanged {
            textView.needsDisplay = true
        }
    }

    func updateGutter() {
        let lineCount = max(1, lineIndex.lineCount)
        let digits = max(3, String(lineCount).count)
        // 14pt breakpoint margin + baseline-matched monospaced line numbers + right padding + dedicated 18pt fold chevron column
        let newWidth = CGFloat(digits * 9 + 38 + 14)
        if abs(gutterWidth - newWidth) > 0.5 {
            gutterWidth = newWidth
            needsLayout = true
        }
        gutterView.needsDisplay = true
    }

    func scrollToLine(_ oneBasedLine: Int) {
        if scrollView.contentView.bounds.size.height <= 0 {
            pendingInitialJumpLine = oneBasedLine
            pendingInitialScrollOrigin = nil
            return
        }

        // Auto-expand any collapsed regions concealing the target line
        let hiding = CodeFoldingEngine.collapsedStartLinesHiding(
            line: oneBasedLine,
            regions: foldableRegions,
            collapsedStartLines: collapsedStartLines
        )
        if !hiding.isEmpty {
            unfold(startLines: hiding)
        }

        relayoutDocument()
        let targetRange = lineIndex.fullLineRange(forOneBasedLine: oneBasedLine)
        textView.setSelectedRange(NSRange(location: targetRange.location, length: 0))
        textView.scrollRangeToVisible(targetRange)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        gutterView.needsDisplay = true
        textView.needsDisplay = true
    }
}

// MARK: - Line Number & Code Folding Gutter

final class LineNumberGutterView: NSView {
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?

    var documentFilePath: String = ""
    var lineIndex = LineIndexTable(text: "")
    var regionsByStartLine: [Int: FoldableRegion] = [:]
    var collapsedStartLines: Set<Int> = []
    var breakpointsByLine: [Int: DebugBreakpoint] = [:]
    var pausedLine: Int? = nil

    var onToggleFold: ((Int) -> Void)?
    var onSelectLine: ((Int) -> Void)?
    var onToggleBreakpoint: ((Int) -> Void)?
    var onEditBreakpoint: ((DebugBreakpoint) -> Void)?
    var onRemoveBreakpoint: ((UUID) -> Void)?

    private struct FoldHitItem {
        let region: FoldableRegion
        let isCollapsed: Bool
        let chevronRect: NSRect
        let rowRect: NSRect
    }

    private struct LineHitItem {
        let lineNumber: Int
        let rowRect: NSRect
    }

    private var visibleFoldItems: [FoldHitItem] = []
    private var visibleLineItems: [LineHitItem] = []
    private var isMouseInside = false
    private var hoveredFoldLine: Int? = nil
    private var hoveredBreakpointLine: Int? = nil

    private let breakpointMarginWidth: CGFloat = 14
    private let foldColumnWidth: CGFloat = 18

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isMouseInside = true
        updateHover(atWindowPoint: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        isMouseInside = true
        updateHover(atWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseInside = false
        hoveredFoldLine = nil
        hoveredBreakpointLine = nil
        toolTip = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)

        if let foldHit = visibleFoldItems.first(where: { $0.chevronRect.contains(pt) }) {
            onToggleFold?(foldHit.region.startLine)
            return
        }

        if let lineHit = visibleLineItems.first(where: { $0.rowRect.contains(pt) }) {
            if let onToggleBreakpoint {
                onToggleBreakpoint(lineHit.lineNumber)
            } else {
                onSelectLine?(lineHit.lineNumber)
            }
            return
        }

        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        guard let lineHit = visibleLineItems.first(where: { $0.rowRect.contains(pt) }) else {
            return nil
        }
        let line = lineHit.lineNumber
        let menu = NSMenu(title: "Breakpoints")

        if let existing = breakpointsByLine[line] {
            let editCond = NSMenuItem(title: "Edit Condition…", action: #selector(handleEditCondition(_:)), keyEquivalent: "")
            editCond.target = self
            editCond.representedObject = line
            menu.addItem(editCond)

            let editLog = NSMenuItem(title: "Edit Logpoint…", action: #selector(handleEditLogpoint(_:)), keyEquivalent: "")
            editLog.target = self
            editLog.representedObject = line
            menu.addItem(editLog)

            menu.addItem(.separator())

            let toggleTitle = existing.isEnabled ? "Disable Breakpoint" : "Enable Breakpoint"
            let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(handleToggleEnabled(_:)), keyEquivalent: "")
            toggleItem.target = self
            toggleItem.representedObject = line
            menu.addItem(toggleItem)

            let removeItem = NSMenuItem(title: "Remove Breakpoint", action: #selector(handleRemoveBreakpoint(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = line
            menu.addItem(removeItem)
        } else {
            let addItem = NSMenuItem(title: "Add Breakpoint", action: #selector(handleAddBreakpoint(_:)), keyEquivalent: "")
            addItem.target = self
            addItem.representedObject = line
            menu.addItem(addItem)

            let addCond = NSMenuItem(title: "Add Conditional Breakpoint…", action: #selector(handleAddConditionalBreakpoint(_:)), keyEquivalent: "")
            addCond.target = self
            addCond.representedObject = line
            menu.addItem(addCond)

            let addLog = NSMenuItem(title: "Add Logpoint…", action: #selector(handleAddLogpoint(_:)), keyEquivalent: "")
            addLog.target = self
            addLog.representedObject = line
            menu.addItem(addLog)
        }

        return menu
    }

    @objc private func handleAddBreakpoint(_ sender: NSMenuItem) {
        guard let line = sender.representedObject as? Int else { return }
        onToggleBreakpoint?(line)
    }

    @objc private func handleAddConditionalBreakpoint(_ sender: NSMenuItem) {
        guard let line = sender.representedObject as? Int else { return }
        guard let input = presentInputAlert(
            title: "Add Conditional Breakpoint",
            message: "Break on line \(line) only when this JavaScript expression evaluates to true:",
            placeholder: "e.g. user.role === 'admin'",
            initialValue: "",
            confirmTitle: "Add"
        ) else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let bp = DebugBreakpoint(
            filePath: documentFilePath,
            line: line,
            isEnabled: true,
            condition: trimmed,
            logMessage: nil
        )
        onEditBreakpoint?(bp)
    }

    @objc private func handleAddLogpoint(_ sender: NSMenuItem) {
        guard let line = sender.representedObject as? Int else { return }
        guard let input = presentInputAlert(
            title: "Add Logpoint",
            message: "Log message on line \(line) without pausing (wrap expressions in {braces}):",
            placeholder: "e.g. User logged in: {user.email}",
            initialValue: "",
            confirmTitle: "Add"
        ) else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let bp = DebugBreakpoint(
            filePath: documentFilePath,
            line: line,
            isEnabled: true,
            condition: nil,
            logMessage: trimmed
        )
        onEditBreakpoint?(bp)
    }

    @objc private func handleEditCondition(_ sender: NSMenuItem) {
        guard let line = sender.representedObject as? Int,
              let existing = breakpointsByLine[line] else { return }
        guard let input = presentInputAlert(
            title: "Edit Breakpoint Condition",
            message: "Break on line \(line) when this expression is truthy (leave empty for unconditional):",
            placeholder: "e.g. count > 3",
            initialValue: existing.condition ?? "",
            confirmTitle: "Save"
        ) else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = DebugBreakpoint(
            id: existing.id,
            filePath: existing.filePath,
            line: existing.line,
            isEnabled: existing.isEnabled,
            condition: trimmed.isEmpty ? nil : trimmed,
            logMessage: trimmed.isEmpty ? existing.logMessage : nil
        )
        onEditBreakpoint?(updated)
    }

    @objc private func handleEditLogpoint(_ sender: NSMenuItem) {
        guard let line = sender.representedObject as? Int,
              let existing = breakpointsByLine[line] else { return }
        guard let input = presentInputAlert(
            title: "Edit Logpoint Message",
            message: "Log message on line \(line) without pausing (leave empty to convert to regular breakpoint):",
            placeholder: "e.g. Value = {x}",
            initialValue: existing.logMessage ?? "",
            confirmTitle: "Save"
        ) else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = DebugBreakpoint(
            id: existing.id,
            filePath: existing.filePath,
            line: existing.line,
            isEnabled: existing.isEnabled,
            condition: trimmed.isEmpty ? existing.condition : nil,
            logMessage: trimmed.isEmpty ? nil : trimmed
        )
        onEditBreakpoint?(updated)
    }

    @objc private func handleToggleEnabled(_ sender: NSMenuItem) {
        guard let line = sender.representedObject as? Int,
              var existing = breakpointsByLine[line] else { return }
        existing.isEnabled.toggle()
        onEditBreakpoint?(existing)
    }

    @objc private func handleRemoveBreakpoint(_ sender: NSMenuItem) {
        guard let line = sender.representedObject as? Int,
              let existing = breakpointsByLine[line] else { return }
        onRemoveBreakpoint?(existing.id)
    }

    private func presentInputAlert(
        title: String,
        message: String,
        placeholder: String,
        initialValue: String,
        confirmTitle: String = "Save"
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initialValue
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func updateHover(atWindowPoint windowPoint: NSPoint) {
        let pt = convert(windowPoint, from: nil)
        if let hit = visibleFoldItems.first(where: { $0.chevronRect.contains(pt) }) {
            let changed = hoveredFoldLine != hit.region.startLine || hoveredBreakpointLine != nil
            hoveredFoldLine = hit.region.startLine
            hoveredBreakpointLine = nil
            if changed {
                needsDisplay = true
            }
            let verb = hit.isCollapsed ? "Expand" : "Collapse"
            let count = hit.region.hiddenLineCount
            toolTip = "\(verb) lines \(hit.region.startLine)–\(hit.region.endLine) (\(count) \(count == 1 ? "line" : "lines"))"
            NSCursor.pointingHand.set()
        } else if pt.x <= breakpointMarginWidth + 2,
                  let lineHit = visibleLineItems.first(where: { $0.rowRect.contains(pt) }) {
            let changed = hoveredBreakpointLine != lineHit.lineNumber || hoveredFoldLine != nil
            hoveredFoldLine = nil
            hoveredBreakpointLine = lineHit.lineNumber
            if changed {
                needsDisplay = true
            }
            if let bp = breakpointsByLine[lineHit.lineNumber] {
                if !bp.isEnabled {
                    toolTip = "Disabled breakpoint (line \(bp.line))"
                } else if let log = bp.logMessage {
                    toolTip = "Logpoint: \(log)"
                } else if let cond = bp.condition {
                    toolTip = "Conditional breakpoint: \(cond)"
                } else {
                    toolTip = "Breakpoint (line \(bp.line))"
                }
            } else {
                toolTip = "Click to add breakpoint on line \(lineHit.lineNumber)"
            }
            NSCursor.pointingHand.set()
        } else {
            let changed = hoveredFoldLine != nil || hoveredBreakpointLine != nil
            hoveredFoldLine = nil
            hoveredBreakpointLine = nil
            toolTip = nil
            NSCursor.arrow.set()
            if changed {
                needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        visibleFoldItems.removeAll(keepingCapacity: true)
        visibleLineItems.removeAll(keepingCapacity: true)

        NSColor(red: 0.088, green: 0.096, blue: 0.120, alpha: 1.0).setFill()
        dirtyRect.fill()

        NSColor.white.withAlphaComponent(0.07).setFill()
        NSRect(x: bounds.width - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView else { return }

        let docVisibleRect = scrollView.documentVisibleRect
        let textOrigin = textView.textContainerOrigin
        let containerVisibleRect = NSRect(
            x: max(0, docVisibleRect.origin.x - textOrigin.x),
            y: max(0, docVisibleRect.origin.y - textOrigin.y),
            width: max(1, docVisibleRect.width),
            height: max(1, docVisibleRect.height + textOrigin.y * 2)
        )

        let activeLineNumber = lineIndex.lineNumber(forUTF16Offset: textView.selectedRange().location)

        let codeFontSize = (textView as? CeptraCodeTextView)?.editorFontSize ?? 13.0
        let lineMetrics = CeptraCenteredLineLayoutDelegate.metrics(fontSize: codeFontSize, in: layoutManager)
        let normalFont = NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .medium)
        let activeFont = NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .semibold)
        let normalBaselineOffset = layoutManager.defaultBaselineOffset(for: normalFont)
        let activeBaselineOffset = layoutManager.defaultBaselineOffset(for: activeFont)

        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: normalFont,
            .foregroundColor: NSColor(red: 0.52, green: 0.57, blue: 0.67, alpha: 0.92)
        ]
        let activeAttrs: [NSAttributedString.Key: Any] = [
            .font: activeFont,
            .foregroundColor: NSColor(red: 0.88, green: 0.93, blue: 1.0, alpha: 1.0)
        ]
        let pausedAttrs: [NSAttributedString.Key: Any] = [
            .font: activeFont,
            .foregroundColor: NSColor(red: 1.0, green: 0.88, blue: 0.56, alpha: 1.0)
        ]

        let numberRightEdge = bounds.width - foldColumnWidth - 3

        func drawRow(lineNumber: Int, rectInGutter: NSRect) {
            let rowRect = NSRect(x: 0, y: rectInGutter.minY, width: bounds.width - 1, height: rectInGutter.height)
            visibleLineItems.append(LineHitItem(lineNumber: lineNumber, rowRect: rowRect))

            let isActive = lineNumber == activeLineNumber
            let isPaused = lineNumber == pausedLine

            if isPaused {
                NSColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 0.20).setFill()
                rowRect.fill()
                NSColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 0.35).setFill()
                NSRect(x: rowRect.minX, y: rowRect.minY, width: rowRect.width, height: 1).fill()
                NSRect(x: rowRect.minX, y: rowRect.maxY - 1, width: rowRect.width, height: 1).fill()
            } else if isActive {
                NSColor(red: 0.30, green: 0.44, blue: 0.78, alpha: 0.13).setFill()
                rowRect.fill()
            }

            let marginRect = NSRect(
                x: 0,
                y: rectInGutter.minY,
                width: breakpointMarginWidth,
                height: rectInGutter.height
            )
            let breakpoint = breakpointsByLine[lineNumber]
            if let breakpoint {
                drawBreakpoint(breakpoint, in: marginRect)
            } else if hoveredBreakpointLine == lineNumber && !isPaused {
                drawBreakpointHoverPreview(in: marginRect)
            }

            if isPaused {
                drawPausedIndicator(in: marginRect, overlappingBreakpoint: breakpoint != nil)
            }

            let attrs = isPaused ? pausedAttrs : (isActive ? activeAttrs : normalAttrs)
            let baselineOffset = (isPaused || isActive) ? activeBaselineOffset : normalBaselineOffset
            let drawY = rectInGutter.minY + lineMetrics.baseline - baselineOffset

            let label = "\(lineNumber)" as NSString
            let textSize = label.size(withAttributes: attrs)
            let drawPoint = NSPoint(
                x: max(breakpointMarginWidth + 2, numberRightEdge - textSize.width),
                y: drawY
            )
            label.draw(at: drawPoint, withAttributes: attrs)

            if let region = regionsByStartLine[lineNumber] {
                let isCollapsed = collapsedStartLines.contains(lineNumber)
                let chevronRect = NSRect(
                    x: bounds.width - foldColumnWidth - 1,
                    y: rectInGutter.minY,
                    width: foldColumnWidth,
                    height: rectInGutter.height
                )
                visibleFoldItems.append(FoldHitItem(
                    region: region,
                    isCollapsed: isCollapsed,
                    chevronRect: chevronRect,
                    rowRect: rowRect
                ))

                let isHovered = hoveredFoldLine == lineNumber
                drawFoldChevron(
                    in: chevronRect,
                    collapsed: isCollapsed,
                    highlighted: isHovered || isCollapsed,
                    subtle: !isMouseInside && !isCollapsed && !isActive && !isPaused
                )
            }
        }

        if layoutManager.numberOfGlyphs == 0 {
            let extraRect = layoutManager.extraLineFragmentRect
            let rectInTextView = NSRect(
                x: textOrigin.x,
                y: textOrigin.y + extraRect.minY,
                width: max(1, extraRect.width),
                height: lineMetrics.lineHeight
            )
            drawRow(lineNumber: 1, rectInGutter: convert(rectInTextView, from: textView))
            return
        }

        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: containerVisibleRect, in: textContainer)
        var drawnLines = Set<Int>()

        if visibleGlyphRange.length > 0 {
            layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphRange) { rect, _, _, glyphRange, _ in
                let charIdx = layoutManager.characterIndexForGlyph(at: glyphRange.location)
                let lineNumber = self.lineIndex.lineNumber(forUTF16Offset: charIdx)
                guard drawnLines.insert(lineNumber).inserted else { return }

                var rectInTextView = rect
                rectInTextView.origin.x += textOrigin.x
                rectInTextView.origin.y += textOrigin.y
                let rectInGutter = self.convert(rectInTextView, from: textView)
                drawRow(lineNumber: lineNumber, rectInGutter: rectInGutter)
            }
        }

        // Draw trailing empty line number when document ends with a newline
        let extraRect = layoutManager.extraLineFragmentRect
        if extraRect.height > 0 {
            var rectInTextView = extraRect
            rectInTextView.origin.x += textOrigin.x
            rectInTextView.origin.y += textOrigin.y
            let rectInGutter = convert(rectInTextView, from: textView)
            if rectInGutter.maxY >= dirtyRect.minY - 2 && rectInGutter.minY <= dirtyRect.maxY + 2 {
                let lastLine = lineIndex.lineCount
                if drawnLines.insert(lastLine).inserted {
                    drawRow(lineNumber: lastLine, rectInGutter: rectInGutter)
                }
            }
        }
    }

    private func drawFoldChevron(in rect: NSRect, collapsed: Bool, highlighted: Bool, subtle: Bool) {
        let cx = rect.midX - 0.5
        let cy = rect.midY

        if collapsed {
            let pill = NSRect(x: cx - 6, y: cy - 6, width: 12, height: 12)
            NSColor(red: 0.34, green: 0.62, blue: 1.0, alpha: 0.22).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
        } else if highlighted {
            let pill = NSRect(x: cx - 6, y: cy - 6, width: 12, height: 12)
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
        }

        let path = NSBezierPath()
        path.lineWidth = 1.35
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        if collapsed {
            // Right-pointing chevron ▸
            path.move(to: NSPoint(x: cx - 2.0, y: cy - 3.3))
            path.line(to: NSPoint(x: cx + 2.4, y: cy))
            path.line(to: NSPoint(x: cx - 2.0, y: cy + 3.3))
        } else {
            // Down-pointing chevron ▾
            path.move(to: NSPoint(x: cx - 3.3, y: cy - 1.8))
            path.line(to: NSPoint(x: cx, y: cy + 2.3))
            path.line(to: NSPoint(x: cx + 3.3, y: cy - 1.8))
        }

        let strokeColor: NSColor
        if collapsed {
            strokeColor = NSColor(red: 0.45, green: 0.78, blue: 1.0, alpha: 1.0)
        } else if highlighted {
            strokeColor = NSColor(red: 0.85, green: 0.90, blue: 1.0, alpha: 0.95)
        } else if subtle {
            strokeColor = NSColor(red: 0.48, green: 0.53, blue: 0.64, alpha: 0.48)
        } else {
            strokeColor = NSColor(red: 0.64, green: 0.70, blue: 0.82, alpha: 0.85)
        }
        strokeColor.setStroke()
        path.stroke()
    }

    private func drawBreakpointHoverPreview(in marginRect: NSRect) {
        let cx = marginRect.midX + 1.5
        let cy = marginRect.midY
        let r: CGFloat = 4.25
        let circle = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        NSColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 0.35).setFill()
        circle.fill()
    }

    private func drawBreakpoint(_ bp: DebugBreakpoint, in marginRect: NSRect) {
        let cx = marginRect.midX + 1.5
        let cy = marginRect.midY
        let r: CGFloat = 4.5

        if !bp.isEnabled {
            let ringRect = NSRect(x: cx - r + 0.75, y: cy - r + 0.75, width: (r - 0.75) * 2, height: (r - 0.75) * 2)
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = 1.5
            NSColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 0.72).setStroke()
            ring.stroke()
            return
        }

        if bp.isLogpoint {
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: cx, y: cy - r))
            diamond.line(to: NSPoint(x: cx + r, y: cy))
            diamond.line(to: NSPoint(x: cx, y: cy + r))
            diamond.line(to: NSPoint(x: cx - r, y: cy))
            diamond.close()
            NSColor(red: 0.65, green: 0.42, blue: 0.98, alpha: 1.0).setFill()
            diamond.fill()
            diamond.lineWidth = 0.75
            NSColor(red: 0.85, green: 0.73, blue: 1.0, alpha: 0.60).setStroke()
            diamond.stroke()
            return
        }

        if bp.isConditional {
            let circleRect = NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            let circle = NSBezierPath(ovalIn: circleRect)
            NSColor(red: 0.96, green: 0.58, blue: 0.12, alpha: 1.0).setFill()
            circle.fill()
            circle.lineWidth = 0.75
            NSColor(red: 1.0, green: 0.85, blue: 0.55, alpha: 0.65).setStroke()
            circle.stroke()

            let qMark = "?" as NSString
            let qAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7.5, weight: .bold),
                .foregroundColor: NSColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 0.95)
            ]
            let qSize = qMark.size(withAttributes: qAttrs)
            qMark.draw(
                at: NSPoint(x: cx - qSize.width * 0.5, y: cy - qSize.height * 0.5 - 0.25),
                withAttributes: qAttrs
            )
            return
        }

        let circleRect = NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        let circle = NSBezierPath(ovalIn: circleRect)
        NSColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1.0).setFill()
        circle.fill()
        circle.lineWidth = 0.75
        NSColor(red: 1.0, green: 0.72, blue: 0.72, alpha: 0.48).setStroke()
        circle.stroke()
    }

    private func drawPausedIndicator(in marginRect: NSRect, overlappingBreakpoint: Bool) {
        let cx = marginRect.midX + 1.5
        let cy = marginRect.midY

        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: cx - 3.5, y: cy - 3.8))
        arrow.line(to: NSPoint(x: cx + 1.0, y: cy - 3.8))
        arrow.line(to: NSPoint(x: cx + 4.5, y: cy))
        arrow.line(to: NSPoint(x: cx + 1.0, y: cy + 3.8))
        arrow.line(to: NSPoint(x: cx - 3.5, y: cy + 3.8))
        arrow.line(to: NSPoint(x: cx - 1.5, y: cy))
        arrow.close()

        NSColor(red: 0.961, green: 0.620, blue: 0.043, alpha: 1.0).setFill() // #F59E0B
        arrow.fill()

        if overlappingBreakpoint {
            arrow.lineWidth = 0.9
            NSColor(red: 0.088, green: 0.096, blue: 0.120, alpha: 0.92).setStroke()
            arrow.stroke()
        }
    }
}

// MARK: - Code TextView (Syntax Highlighting + Fold Badges + IntelliSense Keys + ⌘-Click Import Navigation)

final class CeptraCodeTextView: NSTextView {
    var currentFileURL: URL?
    var editorLanguage: String = "javascript"
    var editorFontSize: CGFloat = 13.0
    var tabWidth: Int = 2

    var lineIndex = LineIndexTable(text: "")
    var collapsedRegions: [FoldableRegion] = []
    var hiddenRanges: [NSRange] = []
    var pausedLine: Int? = nil

    var onInterceptKeyDown: ((NSEvent) -> Bool)?
    var onManualComplete: (() -> Void)?
    var onResolveHoverLink: ((Int) -> NavigableSpan?)?
    var onNavigateSpan: ((NavigableSpan) -> Void)?
    var onGoToDefinitionKey: (() -> Void)?
    var onFoldShortcut: ((EditorFoldAction) -> Void)?
    var onExpandFoldedLine: ((Int) -> Void)?

    private var hoveredSpan: NavigableSpan?
    private var lastMouseWindowPoint: NSPoint?
    private var renderedFoldBadges: [(startLine: Int, rect: NSRect)] = []
    private var isHoveringFoldBadge = false

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

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let layoutManager else { return }

        // Subtle highlight band behind the active caret line
        let sel = selectedRange()
        if sel.length == 0 {
            let lineRect: NSRect?
            if layoutManager.numberOfGlyphs == 0 {
                lineRect = NSRect(x: 0, y: 0, width: bounds.width, height: max(16, font?.boundingRectForFont.height ?? 17))
            } else if sel.location >= (string as NSString).length, layoutManager.extraLineFragmentRect.height > 0 {
                lineRect = layoutManager.extraLineFragmentRect
            } else {
                let safeChar = min(sel.location, max(0, (string as NSString).length - 1))
                let glyphIdx = layoutManager.glyphIndexForCharacter(at: safeChar)
                lineRect = glyphIdx < layoutManager.numberOfGlyphs
                    ? layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                    : nil
            }
            if let lineRect {
                let highlightBand = NSRect(
                    x: rect.minX,
                    y: lineRect.origin.y + textContainerOrigin.y,
                    width: rect.width,
                    height: lineRect.height
                )
                if highlightBand.intersects(rect) {
                    NSColor(red: 0.30, green: 0.44, blue: 0.78, alpha: 0.08).setFill()
                    highlightBand.fill()
                }
            }
        }

        // Full-width warm-amber highlight band behind the paused debug execution line
        if let pausedLine, pausedLine >= 1 {
            let nsLen = (string as NSString).length
            let lineRange = lineIndex.fullLineRange(forOneBasedLine: pausedLine)
            let pausedLineRect: NSRect?
            if layoutManager.numberOfGlyphs == 0 {
                pausedLineRect = pausedLine == 1
                    ? NSRect(x: 0, y: 0, width: bounds.width, height: max(16, font?.boundingRectForFont.height ?? 17))
                    : nil
            } else if lineRange.location >= nsLen, layoutManager.extraLineFragmentRect.height > 0 {
                pausedLineRect = layoutManager.extraLineFragmentRect
            } else if nsLen > 0 {
                let safeChar = min(lineRange.location, nsLen - 1)
                let glyphIdx = layoutManager.glyphIndexForCharacter(at: safeChar)
                pausedLineRect = glyphIdx < layoutManager.numberOfGlyphs
                    ? layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                    : nil
            } else {
                pausedLineRect = nil
            }

            if let pausedLineRect {
                let band = NSRect(
                    x: rect.minX,
                    y: pausedLineRect.origin.y + textContainerOrigin.y,
                    width: rect.width,
                    height: pausedLineRect.height
                )
                if band.intersects(rect) {
                    NSColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 0.16).setFill()
                    band.fill()

                    NSColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 0.35).setFill()
                    NSRect(x: band.minX, y: band.minY, width: band.width, height: 1).fill()
                    NSRect(x: band.minX, y: band.maxY - 1, width: band.width, height: 1).fill()
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawCollapsedFoldBadges(in: dirtyRect)
    }

    private func drawCollapsedFoldBadges(in dirtyRect: NSRect) {
        renderedFoldBadges.removeAll(keepingCapacity: true)
        guard !collapsedRegions.isEmpty,
              let layoutManager,
              layoutManager.numberOfGlyphs > 0 else { return }

        let badgeFont = NSFont.monospacedSystemFont(ofSize: max(10, editorFontSize - 2), weight: .medium)
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: NSColor(red: 0.54, green: 0.80, blue: 1.0, alpha: 1.0)
        ]

        let nsLen = (string as NSString).length
        for region in collapsedRegions {
            let lineStartChar = lineIndex.lineStartOffset(forOneBasedLine: region.startLine)
            guard lineStartChar < nsLen else { continue }
            // Skip nested collapsed regions whose opening line is already hidden by an outer fold
            if isCharHidden(lineStartChar) { continue }

            let glyphIdx = layoutManager.glyphIndexForCharacter(at: lineStartChar)
            guard glyphIdx < layoutManager.numberOfGlyphs else { continue }
            let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIdx, effectiveRange: nil)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)

            let label = region.badgeLabel as NSString
            let textSize = label.size(withAttributes: badgeAttrs)
            let pillHeight = min(lineRect.height - 2, textSize.height + 3)
            let pillWidth = textSize.width + 12
            let pillX = usedRect.maxX + textContainerOrigin.x + 8
            let pillY = lineRect.origin.y + textContainerOrigin.y + (lineRect.height - pillHeight) * 0.5
            let pillRect = NSRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight)

            renderedFoldBadges.append((startLine: region.startLine, rect: pillRect))
            guard pillRect.intersects(dirtyRect) else { continue }

            let path = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
            NSColor(red: 0.16, green: 0.24, blue: 0.38, alpha: 0.92).setFill()
            path.fill()
            NSColor(red: 0.36, green: 0.62, blue: 0.96, alpha: 0.55).setStroke()
            path.lineWidth = 0.75
            path.stroke()

            label.draw(
                at: NSPoint(x: pillRect.minX + 6, y: pillRect.minY + (pillRect.height - textSize.height) * 0.5),
                withAttributes: badgeAttrs
            )
        }
    }

    private func isCharHidden(_ charIndex: Int) -> Bool {
        for r in hiddenRanges {
            if charIndex >= r.location && charIndex < NSMaxRange(r) {
                return true
            }
        }
        return false
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
        // ⌘⌥[ / ⌘⌥] -> Collapse / Expand block at caret; ⌘⌥⇧[ / ⌘⌥⇧] -> Collapse / Expand all
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if mods == [.command, .option] && event.keyCode == 33 { // [
            onFoldShortcut?(.collapseAtCaret)
            return
        }
        if mods == [.command, .option] && event.keyCode == 30 { // ]
            onFoldShortcut?(.expandAtCaret)
            return
        }
        if mods == [.command, .option, .shift] && event.keyCode == 33 { // ⇧[
            onFoldShortcut?(.collapseAll)
            return
        }
        if mods == [.command, .option, .shift] && event.keyCode == 30 { // ⇧]
            onFoldShortcut?(.expandAll)
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
        let localPoint = convert(event.locationInWindow, from: nil)
        if renderedFoldBadges.contains(where: { $0.rect.contains(localPoint) }) {
            clearHoverLink()
            isHoveringFoldBadge = true
            toolTip = "Click to expand collapsed block"
            NSCursor.pointingHand.set()
            return
        }
        if isHoveringFoldBadge {
            isHoveringFoldBadge = false
            toolTip = nil
            NSCursor.iBeam.set()
        }
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
        isHoveringFoldBadge = false
        clearHoverLink()
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if let badge = renderedFoldBadges.first(where: { $0.rect.contains(localPoint) }) {
            onExpandFoldedLine?(badge.startLine)
            return
        }
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
        if let lm = layoutManager {
            let m = CeptraCenteredLineLayoutDelegate.metrics(fontSize: editorFontSize, in: lm)
            paragraph.minimumLineHeight = m.lineHeight
            paragraph.maximumLineHeight = m.lineHeight
        }

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

        let container = NSVisualEffectView(frame: p.contentRect(forFrameRect: p.frame))
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.appearance = NSAppearance(named: .darkAqua)
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
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

        let wasVisible = panel.isVisible
        panel.setFrame(NSRect(x: originX, y: originY, width: popupWidth, height: popupHeight), display: true)
        if panel.parent !== hostWindow {
            hostWindow.addChildWindow(panel, ordered: .above)
        }
        if !wasVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFront(nil)
        }
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
