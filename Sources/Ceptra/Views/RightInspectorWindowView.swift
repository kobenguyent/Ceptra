import CeptraCore
import SwiftUI

struct RightInspectorWindowView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // Plain-text 36pt Right Window Tab Header (Replay · CodeceptUI · Outline · Debug)
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
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
                                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                                    if tab == .debug && !appState.breakpoints.isEmpty {
                                        Text("\(appState.breakpoints.count)")
                                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                            .monospacedDigit()
                                            .foregroundStyle(CeptraTheme.accentWarm)
                                    }
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer(minLength: 4)

                Button {
                    appState.showingReportsSheet = true
                } label: {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Open Run History & Artifacts")

                Button {
                    withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                        appState.toggleRightSidebar()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Hide Right Sidebar (⌘⌥B)")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ceptraPaneWindow(subtle: true)
    }
}
