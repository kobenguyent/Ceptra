import CeptraCore
import SwiftUI

struct AIDiffPreviewSheetView: View {
    @EnvironmentObject var appState: AppState
    let preview: AIPendingDiffPreview

    private var scopeDescription: String {
        switch preview.applyMode {
        case .replaceSelection(_, let start, let end):
            return "Replace selected lines L\(start)–L\(end) in \(preview.relativePath)"
        case .replaceDocument:
            return "Replace open buffer of \(preview.relativePath)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right.square")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CeptraTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preview AI Changes")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    Text(scopeDescription)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                HStack(spacing: 6) {
                    Text("+\(preview.diffResult.addedCount)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.success)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(CeptraTheme.success.opacity(0.14), in: Capsule())

                    Text("-\(preview.diffResult.removedCount)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.failure)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(CeptraTheme.failure.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(CeptraTheme.panelBG)

            Divider().overlay(CeptraTheme.border)

            if !preview.diffResult.hasChanges {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(CeptraTheme.success)
                    Text("No textual differences detected.")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CeptraTheme.canvasBG)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(preview.diffResult.lines) { line in
                            diffLineRow(line)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(CeptraTheme.canvasBG)
            }

            Divider().overlay(CeptraTheme.border)

            HStack(spacing: 10) {
                Label("Applies in-memory only · ⌘Z undoes in one step · ⌘S saves to disk", systemImage: "arrow.uturn.backward.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(CeptraTheme.textMuted)
                Spacer()
                Button("Cancel") {
                    appState.pendingAIDiffPreview = nil
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("Apply to Editor") {
                    appState.confirmApplyAIDiffPreview()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!preview.diffResult.hasChanges)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(CeptraTheme.panelBG)
        }
        .frame(minWidth: 740, minHeight: 480)
    }

    private func diffLineRow(_ line: AIDiffLine) -> some View {
        let marker: String
        let rowBG: Color
        let markerColor: Color

        switch line.kind {
        case .unchanged:
            marker = " "
            rowBG = .clear
            markerColor = CeptraTheme.textMuted
        case .removed:
            marker = "−"
            rowBG = CeptraTheme.failure.opacity(0.14)
            markerColor = CeptraTheme.failure
        case .added:
            marker = "+"
            rowBG = CeptraTheme.success.opacity(0.14)
            markerColor = CeptraTheme.success
        }

        return HStack(spacing: 0) {
            Text(line.oldLineNumber.map(String.init) ?? "")
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(CeptraTheme.textMuted)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 6)

            Text(line.newLineNumber.map(String.init) ?? "")
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(CeptraTheme.textMuted)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 8)

            Text(marker)
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundStyle(markerColor)
                .frame(width: 14, alignment: .center)

            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(CeptraTheme.textPrimary)
                .textSelection(.enabled)
                .padding(.trailing, 16)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1.5)
        .background(rowBG)
    }
}
