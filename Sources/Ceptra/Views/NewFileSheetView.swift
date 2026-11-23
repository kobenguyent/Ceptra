import CeptraCore
import SwiftUI

struct NewFileSheetView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedKind: ScaffoldTemplateKind = .blankFile
    @State private var name: String = ""
    @State private var directory: String = ""
    @State private var hasCustomDirectoryOverride: Bool = false
    @State private var errorMessage: String? = nil

    private var previewPath: String {
        ProjectScaffolder.previewFileRelativePath(
            directory: directory,
            name: name,
            kind: selectedKind
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CeptraTheme.accent)
                Text("New File")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(CeptraTheme.textPrimary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                Picker("Template", selection: $selectedKind) {
                    ForEach(ScaffoldTemplateKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .onChange(of: selectedKind) { _, newValue in
                    errorMessage = nil
                    if !hasCustomDirectoryOverride {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                            directory = newValue.suggestedDirectory
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedKind == .blankFile ? "File Name (supports nested paths & dotfiles)" : "Feature / Object Name (or nested path)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    TextField(
                        selectedKind == .blankFile
                            ? "e.g. helper.ts, data.json, .env, utils/auth.ts"
                            : "e.g. Checkout or auth/Checkout",
                        text: $name
                    )
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, _ in errorMessage = nil }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Parent Folder (empty = project root)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CeptraTheme.textSecondary)
                        Spacer()
                        Menu {
                            Button("Project Root (.)") {
                                directory = ""
                                hasCustomDirectoryOverride = true
                            }
                            let dirs = appState.workspaceRelativeDirectories
                            if !dirs.isEmpty {
                                Divider()
                                ForEach(dirs, id: \.self) { dir in
                                    Button(dir) {
                                        directory = dir
                                        hasCustomDirectoryOverride = true
                                    }
                                }
                            }
                        } label: {
                            Label("Choose Folder", systemImage: "folder")
                                .font(.system(size: 10.5))
                                .foregroundStyle(CeptraTheme.accent)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    TextField("Leave empty for root, or e.g. src/e2e/auth", text: $directory)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: directory) { _, _ in
                            hasCustomDirectoryOverride = true
                            errorMessage = nil
                        }
                }

                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10))
                        .foregroundStyle(CeptraTheme.accent)
                    Text(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "\(directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "." : directory.trimmingCharacters(in: .whitespacesAndNewlines))/…"
                         : previewPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CeptraTheme.textSecondary : CeptraTheme.cyan)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CeptraTheme.canvasBG.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: directory)
                .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: name)

                if let errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(CeptraTheme.failure)
                        Text(errorMessage)
                            .font(.system(size: 11.5))
                            .foregroundStyle(CeptraTheme.failure)
                    }
                }
            }
            .padding(14)
            .ceptraGlassSurface(cornerRadius: 10, tint: CeptraTheme.panelBG, tintOpacity: 0.54)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create File") {
                    if let err = appState.createNewFile(kind: selectedKind, name: name, directory: directory) {
                        errorMessage = err
                    } else {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(CeptraTheme.accent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(CeptraTheme.sidebarBG.opacity(0.75))
            }
        }
        .onAppear {
            let isTS = appState.workspace?.config.isTypeScript ?? false
            let isPW = appState.isPlaywrightWorkspace
            if let initial = appState.newFileInitialDirectory {
                directory = initial
                hasCustomDirectoryOverride = true
                selectedKind = inferredDefaultKind(forDirectory: initial, isTypeScript: isTS, isPlaywright: isPW)
            } else {
                if isPW {
                    selectedKind = isTS ? .playwrightTSTest : .playwrightJSTest
                } else {
                    selectedKind = isTS ? .tsTest : .jsTest
                }
                directory = selectedKind.suggestedDirectory
                hasCustomDirectoryOverride = false
            }
        }
        .onDisappear {
            appState.newFileInitialDirectory = nil
        }
    }

    private func inferredDefaultKind(forDirectory dir: String, isTypeScript: Bool, isPlaywright: Bool) -> ScaffoldTemplateKind {
        let lower = dir.lowercased()
        if lower.isEmpty { return .blankFile }
        let last = (lower as NSString).lastPathComponent
        if ["tests", "test", "e2e", "specs", "spec"].contains(last) {
            if isPlaywright {
                return isTypeScript ? .playwrightTSTest : .playwrightJSTest
            }
            return isTypeScript ? .tsTest : .jsTest
        }
        if last == "features" { return .gherkinFeature }
        if ["pages", "pageobjects", "fragments"].contains(last) {
            return isPlaywright ? .playwrightPageObject : .pageObject
        }
        if last == "helpers" { return .customHelper }
        return .blankFile
    }
}
