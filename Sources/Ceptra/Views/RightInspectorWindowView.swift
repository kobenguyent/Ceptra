import CeptraCore
import SwiftUI

struct RightInspectorWindowView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // Plain-text 38pt Right Window Tab Header (Replay · CodeceptUI · Outline · Debug · AI)
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(RightInspectorTab.allCases, id: \.self) { tab in
                            let isSelected = appState.activeRightTab == tab
                            Button {
                                withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                                    appState.activeRightTab = tab
                                    appState.persistModulePreferences()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(tab.displayTitle)
                                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                        .foregroundStyle(isSelected ? CeptraTheme.textPrimary : CeptraTheme.textSecondary.opacity(0.85))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                    if tab == .debug && !appState.breakpoints.isEmpty {
                                        Text("\(appState.breakpoints.count)")
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .monospacedDigit()
                                            .foregroundStyle(CeptraTheme.accentWarm)
                                            .fixedSize(horizontal: true, vertical: false)
                                    } else if tab == .ai && appState.isAIStreaming {
                                        Circle()
                                            .fill(CeptraTheme.accent)
                                            .frame(width: 6.5, height: 6.5)
                                    }
                                }
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    RightInspectorHeaderIconButton(
                        systemImage: "chart.bar.doc.horizontal",
                        iconSize: 13.5,
                        iconWeight: .medium,
                        helpText: "Open Run History & Artifacts"
                    ) {
                        appState.showingReportsSheet = true
                    }

                    RightInspectorHeaderIconButton(
                        systemImage: "xmark",
                        iconSize: 12,
                        iconWeight: .semibold,
                        helpText: "Hide Right Sidebar (⌘⌥B)"
                    ) {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                            appState.toggleRightSidebar()
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CeptraTheme.border).frame(height: 1)
            }

            // Active Inspector Content
            Group {
                switch appState.activeRightTab {
                case .replay:
                    ReplayInspectorView()
                case .codeceptUI:
                    CodeceptUIInspectorView()
                case .outline:
                    FlowVisualizerView(
                        file: appState.activeWorkspaceFile,
                        features: appState.activeFeaturesForCurrentTab
                    )
                case .debug:
                    DebugInspectorView()
                case .ai:
                    AIInspectorView()
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .ceptraPaneWindow(subtle: true)
    }
}

private struct RightInspectorHeaderIconButton: View {
    let systemImage: String
    var iconSize: CGFloat = 13.5
    var iconWeight: Font.Weight = .medium
    let helpText: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: iconWeight))
                .foregroundStyle(isHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    isHovered ? CeptraTheme.hoverBG : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isHovered ? CeptraTheme.border : Color.clear, lineWidth: 0.75)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.94))
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
        .help(helpText)
    }
}
