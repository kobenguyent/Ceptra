import AppKit
import CeptraCore
import SwiftUI
import UniformTypeIdentifiers

struct CodeSnapshotDraft: Equatable {
    let fullText: String
    let language: String
    let fileName: String
    let relativePath: String
    let selectedRange: NSRange
    let caretLine: Int
    let initialScope: CodeSnapshotScope

    var hasSelection: Bool {
        selectedRange.length > 0
    }
}

struct CodeSnapshotSheetView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var scope: CodeSnapshotScope = .currentBlock
    @State private var customTitle: String = ""
    @State private var style: CodeSnapshotStyle = CodeSnapshotStyle()
    @State private var rendered: RenderedCodeSnapshot? = nil
    @State private var previewImage: NSImage? = nil
    @State private var didJustCopy: Bool = false

    private var draft: CodeSnapshotDraft? {
        appState.codeSnapshotDraft
    }

    private var currentExtraction: CodeSnapshotExtraction? {
        guard let draft else { return nil }
        return CodeSnapshotEngine.extract(
            from: draft.fullText,
            language: draft.language,
            selectedRange: draft.selectedRange,
            caretLine: draft.caretLine,
            preferredScope: scope,
            autoDedent: style.autoDedent
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider().overlay(CeptraTheme.border)

            if let draft, let extraction = currentExtraction {
                HSplitView {
                    previewStage(draft: draft, extraction: extraction)
                        .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)

                    inspectorSidebar(draft: draft, extraction: extraction)
                        .frame(width: 276)
                        .frame(maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(CeptraTheme.textMuted)
                    Text("Open a file in the editor to capture a code screenshot.")
                        .font(.system(size: 13))
                        .foregroundStyle(CeptraTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().overlay(CeptraTheme.border)

            footerBar
        }
        .frame(minWidth: 860, idealWidth: 960, minHeight: 580, idealHeight: 650)
        .background(CeptraTheme.panelBG)
        .onAppear {
            style = appState.settings.codeSnapshotStyle
            if let draft = appState.codeSnapshotDraft {
                scope = draft.initialScope
                customTitle = draft.fileName
            }
            rerender()
        }
        .onChange(of: scope) { _, _ in rerender() }
        .onChange(of: customTitle) { _, _ in rerender() }
        .onChange(of: style) { _, newStyle in
            if appState.settings.codeSnapshotStyle != newStyle {
                appState.settings.codeSnapshotStyle = newStyle
                appState.saveSettings()
            }
            rerender()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CeptraTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Code Screenshot Studio")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    if let ext = currentExtraction, let draft {
                        Text("\(draft.relativePath) · Lines \(ext.startLineNumber)–\(ext.endLineNumber) (\(ext.lineCount) \(ext.lineCount == 1 ? "line" : "lines"))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer(minLength: 12)

            if let draft {
                HStack(spacing: 3) {
                    if draft.hasSelection {
                        scopeButton(.selection)
                    }
                    scopeButton(.currentBlock)
                    scopeButton(.fullFile)
                }
                .padding(3)
                .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(CeptraTheme.border, lineWidth: 1)
                )
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .frame(width: 24, height: 24)
                    .background(CeptraTheme.hoverBG.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(CeptraTheme.sidebarBG)
    }

    private func scopeButton(_ target: CodeSnapshotScope) -> some View {
        let isSelected = (scope == target)
        return Button {
            scope = target
        } label: {
            Text(target.displayName)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? CeptraTheme.activeBG : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Live Preview Stage

    private func previewStage(draft: CodeSnapshotDraft, extraction: CodeSnapshotExtraction) -> some View {
        ZStack(alignment: .bottomLeading) {
            if style.background == .transparent {
                TransparencyCheckerboard()
            } else {
                CeptraTheme.canvasBG
            }

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                VStack {
                    if let previewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                maxWidth: min(680, rendered?.logicalSize.width ?? 680),
                                maxHeight: min(520, rendered?.logicalSize.height ?? 520)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: style.background == .transparent ? 0 : 10, style: .continuous))
                            .shadow(color: Color.black.opacity(style.background == .transparent ? 0 : 0.25), radius: 18, y: 8)
                            .onDrag {
                                dragItemProvider(draft: draft, extraction: extraction)
                            }
                            .help("Drag image directly into Slack, Notes, Keynote, or Desktop")
                    }
                }
                .padding(24)
                .frame(minWidth: 500, minHeight: 460)
            }

            if let rendered {
                HStack(spacing: 8) {
                    Text("\(Int(rendered.pixelSize.width)) × \(Int(rendered.pixelSize.height)) px · \(rendered.scale)× Retina")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    Text("·")
                        .foregroundStyle(CeptraTheme.textMuted)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(rendered.pngData.count), countStyle: .file))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(CeptraTheme.border, lineWidth: 1))
                .padding(12)
            }
        }
    }

    // MARK: - Studio Controls Sidebar

    private func inspectorSidebar(draft: CodeSnapshotDraft, extraction: CodeSnapshotExtraction) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Background Gradient Presets
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Backdrop")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(CodeSnapshotBackground.allCases) { preset in
                            backgroundSwatch(preset)
                        }
                    }
                }

                Divider().overlay(CeptraTheme.border)

                // 2. Code Theme
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Code Theme")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(CodeSnapshotTheme.allCases) { theme in
                            let selected = (style.theme == theme)
                            Button {
                                style.theme = theme
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(themePreviewColor(theme))
                                        .frame(width: 10, height: 10)
                                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.75))
                                    Text(theme.displayName)
                                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                        .foregroundStyle(selected ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(selected ? CeptraTheme.accent.opacity(0.16) : CeptraTheme.canvasBG)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(selected ? CeptraTheme.accent : CeptraTheme.border, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider().overlay(CeptraTheme.border)

                // 3. Layout: Window Chrome, Padding, Font, Scale
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Window & Layout")

                    VStack(alignment: .leading, spacing: 4) {
                        controlLabel("Window Chrome")
                        Picker("", selection: $style.windowChrome) {
                            ForEach(CodeSnapshotWindowChrome.allCases) { chrome in
                                Text(chrome.displayName).tag(chrome)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                    }

                    if style.background != .transparent {
                        VStack(alignment: .leading, spacing: 4) {
                            controlLabel("Padding")
                            Picker("", selection: $style.padding) {
                                ForEach(CodeSnapshotPadding.allCases) { pad in
                                    Text(pad.displayName).tag(pad)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                        }
                    }

                    HStack(spacing: 8) {
                        controlLabel("Font Size")
                        Spacer()
                        Text("\(Int(style.fontSize)) pt")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textPrimary)
                        Stepper("", value: $style.fontSize, in: 11...20, step: 1)
                            .labelsHidden()
                            .controlSize(.small)
                    }

                    HStack(spacing: 8) {
                        controlLabel("Resolution")
                        Spacer()
                        Picker("", selection: $style.scale) {
                            Text("2× Retina").tag(2)
                            Text("3× Ultra").tag(3)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 146)
                    }
                }

                Divider().overlay(CeptraTheme.border)

                // 4. Title & Toggles
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Details")

                    if style.windowChrome != .none {
                        HStack(spacing: 6) {
                            TextField("Window title (e.g. login_test.ts)", text: $customTitle)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))
                            if customTitle != draft.relativePath {
                                Button("Path") {
                                    customTitle = draft.relativePath
                                }
                                .controlSize(.small)
                                .help("Use relative workspace path as title")
                            }
                        }
                    }

                    Toggle("Show Line Numbers (from L\(extraction.startLineNumber))", isOn: $style.showLineNumbers)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))

                    if style.windowChrome != .none {
                        Toggle("Show Filename Title", isOn: $style.showTitle)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11.5))
                        Toggle("Show Language Badge", isOn: $style.showLanguageBadge)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11.5))
                    }

                    Toggle("Auto-Dedent Indentation", isOn: $style.autoDedent)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))

                    Toggle("Ceptra Watermark", isOn: $style.showWatermark)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                }
            }
            .padding(14)
        }
        .background(CeptraTheme.sidebarBG)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(CeptraTheme.accentWarm)
                Text("Tip: Press ⌘⌥⇧P anytime in the editor for 1-step Quick Copy using these settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(CeptraTheme.textMuted)
            }

            Spacer(minLength: 8)

            Button {
                savePNG()
            } label: {
                Label("Save PNG…", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(rendered == nil)

            Button {
                copyToClipboard()
            } label: {
                Label(didJustCopy ? "Copied!" : "Copy Image", systemImage: didJustCopy ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(didJustCopy ? CeptraTheme.success : CeptraTheme.accent)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(rendered == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(CeptraTheme.sidebarBG)
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(CeptraTheme.textMuted)
    }

    private func controlLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(CeptraTheme.textSecondary)
    }

    private func backgroundSwatch(_ preset: CodeSnapshotBackground) -> some View {
        let isSelected = (style.background == preset)
        return Button {
            style.background = preset
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if preset == .transparent {
                        TransparencyCheckerboard(cellSize: 5)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(swatchGradient(for: preset))
                    }
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 2)
                    }
                }
                .frame(height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? CeptraTheme.accent : Color.white.opacity(0.14), lineWidth: isSelected ? 2 : 1)
                )

                Text(preset.displayName)
                    .font(.system(size: 9.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private func swatchGradient(for preset: CodeSnapshotBackground) -> LinearGradient {
        let colors: [Color]
        switch preset {
        case .candy:
            colors = [Color(red: 0.996, green: 0.443, blue: 0.659), Color(red: 0.569, green: 0.369, blue: 0.965), Color(red: 0.220, green: 0.490, blue: 0.980)]
        case .midnight:
            colors = [Color(red: 0.094, green: 0.125, blue: 0.239), Color(red: 0.235, green: 0.173, blue: 0.412)]
        case .breeze:
            colors = [Color(red: 0.059, green: 0.780, blue: 0.875), Color(red: 0.192, green: 0.510, blue: 0.965), Color(red: 0.365, green: 0.325, blue: 0.922)]
        case .sunset:
            colors = [Color(red: 0.996, green: 0.514, blue: 0.220), Color(red: 0.929, green: 0.278, blue: 0.584), Color(red: 0.494, green: 0.267, blue: 0.878)]
        case .emerald:
            colors = [Color(red: 0.075, green: 0.788, blue: 0.576), Color(red: 0.047, green: 0.349, blue: 0.592)]
        case .amber:
            colors = [Color(red: 0.984, green: 0.729, blue: 0.184), Color(red: 0.941, green: 0.412, blue: 0.145), Color(red: 0.745, green: 0.133, blue: 0.310)]
        case .monochrome:
            colors = [Color(red: 0.22, green: 0.23, blue: 0.26), Color(red: 0.07, green: 0.08, blue: 0.09)]
        case .transparent:
            colors = [.clear]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func themePreviewColor(_ theme: CodeSnapshotTheme) -> Color {
        switch theme {
        case .obsidian: return Color(red: 0.07, green: 0.09, blue: 0.14)
        case .dracula: return Color(red: 0.16, green: 0.17, blue: 0.23)
        case .catppuccin: return Color(red: 0.14, green: 0.14, blue: 0.22)
        case .tokyoNight: return Color(red: 0.10, green: 0.11, blue: 0.17)
        case .paperLight: return Color(red: 0.96, green: 0.97, blue: 0.99)
        }
    }

    private func rerender() {
        guard let draft, let extraction = currentExtraction else {
            rendered = nil
            previewImage = nil
            return
        }
        let result = CodeSnapshotRenderer.render(
            extraction: extraction,
            language: draft.language,
            title: customTitle,
            style: style
        )
        rendered = result
        previewImage = result.flatMap { NSImage(data: $0.pngData) }
    }

    private func copyToClipboard() {
        guard let rendered else { return }
        if CodeSnapshotRenderer.copyToPasteboard(rendered) {
            didJustCopy = true
            appState.showBanner("Copied code screenshot (\(Int(rendered.pixelSize.width))×\(Int(rendered.pixelSize.height)) PNG) — press ⌘V to paste")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                didJustCopy = false
            }
        }
    }

    private func savePNG() {
        guard let rendered, let draft, let extraction = currentExtraction else { return }
        let suggested = CodeSnapshotEngine.suggestedFilename(fileName: draft.fileName, extraction: extraction)
        appState.saveCodeSnapshotPNG(rendered, suggestedFileName: suggested)
    }

    private func dragItemProvider(draft: CodeSnapshotDraft, extraction: CodeSnapshotExtraction) -> NSItemProvider {
        guard let rendered else { return NSItemProvider() }
        let suggested = CodeSnapshotEngine.suggestedFilename(fileName: draft.fileName, extraction: extraction)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ceptra-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent(suggested)
        try? rendered.pngData.write(to: fileURL, options: .atomic)
        let provider = NSItemProvider(contentsOf: fileURL) ?? NSItemProvider()
        provider.suggestedName = suggested
        return provider
    }
}

private struct TransparencyCheckerboard: View {
    var cellSize: CGFloat = 10

    var body: some View {
        Canvas { ctx, size in
            let light = Color.white.opacity(0.10)
            let dark = Color.black.opacity(0.18)
            let cols = Int(ceil(size.width / cellSize))
            let rows = Int(ceil(size.height / cellSize))
            for r in 0..<rows {
                for c in 0..<cols {
                    let rect = CGRect(x: CGFloat(c) * cellSize, y: CGFloat(r) * cellSize, width: cellSize, height: cellSize)
                    ctx.fill(Path(rect), with: .color((r + c).isMultiple(of: 2) ? light : dark))
                }
            }
        }
    }
}
