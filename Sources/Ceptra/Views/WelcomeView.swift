import CeptraCore
import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 12) {
                if let icon = CeptraAppIconRenderer.makeNSImage(pixelSize: 160) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 76, height: 76)
                        .shadow(color: CeptraTheme.accent.opacity(0.35), radius: 18, y: 6)
                }

                Text("Ceptra")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(CeptraTheme.textPrimary)

                Text("Minimalist Native macOS IDE for CodeceptJS 4.x")
                    .font(.system(size: 13.5))
                    .foregroundStyle(CeptraTheme.textSecondary)

                Text("v\(AppMetadata.currentVersionString)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
            }

            HStack(spacing: 14) {
                Button {
                    appState.openWorkspacePanel()
                } label: {
                    Label("Open CodeceptJS Workspace…", systemImage: "folder.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(CeptraTheme.accent)

                Button {
                    appState.createSampleWorkspacePanel()
                } label: {
                    Label("Create Sample 4.x Project…", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }

            if !appState.settings.recentProjectPaths.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT WORKSPACES")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .padding(.horizontal, 6)

                    VStack(spacing: 4) {
                        ForEach(appState.settings.recentProjectPaths.prefix(6), id: \.self) { path in
                            let url = URL(fileURLWithPath: path)
                            Button {
                                appState.openWorkspace(at: url)
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(CeptraTheme.accent)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(url.lastPathComponent)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundStyle(CeptraTheme.textPrimary)
                                        Text(path)
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(CeptraTheme.textMuted)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10))
                                        .foregroundStyle(CeptraTheme.textMuted)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(CeptraTheme.border, lineWidth: 0.75))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 480)
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
