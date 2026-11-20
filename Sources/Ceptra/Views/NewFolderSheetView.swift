import CeptraCore
import SwiftUI

struct NewFolderSheetView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var folderName: String = ""
    @State private var directory: String = ""
    @State private var errorMessage: String? = nil

    private var previewPath: String {
        ProjectScaffolder.previewFolderRelativePath(
            directory: directory,
            folderName: folderName
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CeptraTheme.accent)
                Text("New Folder")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(CeptraTheme.textPrimary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Folder Name (supports nested paths like e2e/auth/fixtures)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    TextField("e.g. fixtures or e2e/checkout", text: $folderName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: folderName) { _, _ in errorMessage = nil }
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
                            }
                            let dirs = appState.workspaceRelativeDirectories
                            if !dirs.isEmpty {
                                Divider()
                                ForEach(dirs, id: \.self) { dir in
                                    Button(dir) {
                                        directory = dir
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

                    TextField("Leave empty for root, or e.g. src/tests", text: $directory)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: directory) { _, _ in errorMessage = nil }
                }

                if !folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(CeptraTheme.accent)
                        Text(previewPath.isEmpty ? "—" : "\(previewPath)/")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(CeptraTheme.cyan)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 6))
                }

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
                Button("Create Folder") {
                    if let err = appState.createNewFolder(name: folderName, directory: directory) {
                        errorMessage = err
                    } else {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(CeptraTheme.accent)
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(CeptraTheme.sidebarBG.opacity(0.75))
            }
        }
        .onAppear {
            if let initial = appState.newFolderInitialDirectory {
                directory = initial
            } else {
                directory = ""
            }
        }
        .onDisappear {
            appState.newFolderInitialDirectory = nil
        }
    }
}
