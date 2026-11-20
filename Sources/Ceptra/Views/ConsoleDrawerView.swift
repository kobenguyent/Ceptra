import AppKit
import CeptraCore
import SwiftUI

struct ConsoleDrawerView: View {
    @EnvironmentObject var appState: AppState
    @State private var filterMode: ConsoleFilterMode = .all
    @State private var searchText: String = ""

    enum ConsoleFilterMode: String, CaseIterable, Identifiable {
        case all = "All"
        case steps = "Steps"
        case errors = "Errors"
        var id: String { rawValue }
    }

    var filteredLogs: [ConsoleLogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return appState.consoleLogs.filter { entry in
            switch filterMode {
            case .all: break
            case .steps: if !entry.isStep && !entry.isHighlight { return false }
            case .errors: if !entry.isError && !entry.text.contains("✖") && !entry.text.contains("FAIL") { return false }
            }
            if !query.isEmpty && !entry.text.lowercased().contains(query) { return false }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Strip
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.isRunning ? CeptraTheme.accent : CeptraTheme.textMuted)
                        .frame(width: 7, height: 7)
                    Text(appState.isRunning ? "Running: \(appState.activeRunLabel)" : "Execution Console")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                }

                Picker("", selection: $filterMode) {
                    ForEach(ConsoleFilterMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)

                TextField("Filter logs…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 5))
                    .frame(maxWidth: 180)

                Spacer()

                if !appState.consoleLogs.isEmpty {
                    Button {
                        let full = appState.consoleLogs.map(\.text).joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(full, forType: .string)
                        appState.showBanner("Copied console output")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(CeptraTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy Logs")

                    Button {
                        appState.clearConsole()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(CeptraTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Console")
                }

                Button {
                    appState.isConsoleVisible = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Hide Console (⌘J)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(CeptraTheme.sidebarBG)

            Divider().overlay(CeptraTheme.border)

            // Streaming Log Area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if filteredLogs.isEmpty {
                            Text("Ready. Press ⌘R to run all tests, ⌘⇧R to run the current file, or click any scenario play button.")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textMuted)
                                .padding(12)
                        } else {
                            ForEach(filteredLogs) { entry in
                                Text(entry.text)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(lineColor(for: entry))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry.id)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: appState.consoleLogs.count) { _, _ in
                    if let last = filteredLogs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .background(Color(red: 0.058, green: 0.064, blue: 0.080))
        }
    }

    private func lineColor(for entry: ConsoleLogEntry) -> Color {
        if entry.isError { return CeptraTheme.failure }
        let t = entry.text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("$ ") { return CeptraTheme.accent }
        if t.hasPrefix("✔") || t.hasPrefix("OK |") { return CeptraTheme.success }
        if t.hasPrefix("✖") || t.hasPrefix("FAIL |") { return CeptraTheme.failure }
        if entry.isStep { return CeptraTheme.cyan.opacity(0.92) }
        return CeptraTheme.textPrimary.opacity(0.88)
    }
}
