import CeptraCore
import SwiftUI

struct NewFileSheetView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedKind: ScaffoldTemplateKind = .jsTest
    @State private var name: String = ""
    @State private var directory: String = "tests"
    @State private var hasCustomDirectoryOverride: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New CodeceptJS 4.x File")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(CeptraTheme.textPrimary)

            VStack(alignment: .leading, spacing: 10) {
                Picker("Template", selection: $selectedKind) {
                    ForEach(ScaffoldTemplateKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .onChange(of: selectedKind) { _, newValue in
                    if !hasCustomDirectoryOverride {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                            directory = newValue.suggestedDirectory
                        }
                    }
                }

                TextField("Feature / Object Name (e.g. Checkout)", text: $name)
                    .textFieldStyle(.roundedBorder)

                TextField("Relative Folder (e.g. tests, pages, features)", text: $directory)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(CeptraTheme.accent)
                    Text("\(directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "." : directory.trimmingCharacters(in: .whitespacesAndNewlines))/\(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "…" : name.trimmingCharacters(in: .whitespacesAndNewlines))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)
                }
                .padding(.top, 2)
                .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: directory)
                .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: name)
            }
            .padding(14)
            .ceptraGlassSurface(cornerRadius: 10, tint: CeptraTheme.panelBG, tintOpacity: 0.54)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create File") {
                    appState.createNewFile(kind: selectedKind, name: name, directory: directory)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(CeptraTheme.accent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(CeptraTheme.sidebarBG.opacity(0.75))
            }
        }
        .onAppear {
            if let initial = appState.newFileInitialDirectory {
                directory = initial
                hasCustomDirectoryOverride = true
            } else {
                directory = selectedKind.suggestedDirectory
                hasCustomDirectoryOverride = false
            }
        }
        .onDisappear {
            appState.newFileInitialDirectory = nil
        }
    }
}
