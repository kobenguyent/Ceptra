import CeptraCore
import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var hoveredPath: String?
    @State private var isPrimaryHovered = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 12) {
                ZStack {
                    RadialGradient(
                        colors: [
                            CeptraTheme.accent.opacity(0.16),
                            CeptraTheme.accent.opacity(0.05),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: 86
                    )
                    .frame(width: 172, height: 172)
                    .allowsHitTesting(false)

                    if let icon = CeptraAppIconRenderer.makeNSImage(pixelSize: 160) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 76, height: 76)
                            .shadow(color: CeptraTheme.accent.opacity(0.32), radius: 18, y: 6)
                    }
                }
                .frame(height: 92)

                Text("Ceptra")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(CeptraTheme.textPrimary)

                Text("Minimalist Native macOS IDE for CodeceptJS 4.x & Playwright (TS/JS & Python)")
                    .font(.system(size: 13.5))
                    .foregroundStyle(CeptraTheme.textSecondary)

                Text("v\(AppMetadata.currentVersionString)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 10)
            .animation(CeptraMotion.resolve(CeptraMotion.gentle, reduceMotion: reduceMotion), value: appeared)

            HStack(spacing: 12) {
                Button {
                    appState.openWorkspacePanel()
                } label: {
                    Label("Open Test Workspace…", systemImage: "folder.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(CeptraTheme.accent.opacity(isPrimaryHovered ? 0.96 : 0.86))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(isPrimaryHovered ? 0.42 : 0.28),
                                            Color.white.opacity(0.08)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.9
                                )
                        }
                        .shadow(color: CeptraTheme.accent.opacity(isPrimaryHovered ? 0.34 : 0.22), radius: isPrimaryHovered ? 12 : 8, y: 4)
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.97))
                .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isPrimaryHovered)
                .onHover { hovering in
                    isPrimaryHovered = hovering
                }

                Menu {
                    Button {
                        appState.createSamplePlaywrightWorkspacePanel()
                    } label: {
                        Label("Playwright Test Project (TypeScript)…", systemImage: "theatermasks")
                    }
                    Button {
                        appState.createSamplePlaywrightPythonWorkspacePanel()
                    } label: {
                        Label("Playwright Python Project (pytest)…", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Button {
                        appState.createSampleWorkspacePanel()
                    } label: {
                        Label("CodeceptJS 4.x Project…", systemImage: "sparkles")
                    }
                } label: {
                    Label("Create Sample Project…", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(CeptraTheme.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .ceptraGlassSurface(cornerRadius: 10, tint: CeptraTheme.panelBG, tintOpacity: 0.62)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 12)
            .animation(
                CeptraMotion.resolve(CeptraMotion.gentle.delay(0.06), reduceMotion: reduceMotion),
                value: appeared
            )

            if !appState.settings.recentProjectPaths.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT WORKSPACES")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .padding(.horizontal, 6)

                    VStack(spacing: 6) {
                        ForEach(appState.settings.recentProjectPaths.prefix(6), id: \.self) { path in
                            let url = URL(fileURLWithPath: path)
                            let isHovered = hoveredPath == path
                            Button {
                                appState.openWorkspace(at: url)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(isHovered ? CeptraTheme.accent : CeptraTheme.accent.opacity(0.85))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(url.lastPathComponent)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundStyle(CeptraTheme.textPrimary)
                                        Text(path)
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(isHovered ? CeptraTheme.textSecondary : CeptraTheme.textMuted)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(isHovered ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                                        .offset(x: isHovered && !reduceMotion ? 2.5 : 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .ceptraGlassSurface(
                                    cornerRadius: 10,
                                    tint: CeptraTheme.panelBG,
                                    tintOpacity: 0.56,
                                    accentBorder: isHovered ? CeptraTheme.accent : nil,
                                    isHovered: isHovered
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.985))
                            .onHover { hovering in
                                withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                                    hoveredPath = hovering ? path : (hoveredPath == path ? nil : hoveredPath)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 480)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 14)
                .animation(
                    CeptraMotion.resolve(CeptraMotion.gentle.delay(0.12), reduceMotion: reduceMotion),
                    value: appeared
                )
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            appeared = true
        }
    }
}
