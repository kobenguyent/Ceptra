import AppKit
import CeptraCore
import SwiftUI

struct UpdateSheetView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let icon = CeptraAppIconRenderer.makeNSImage(pixelSize: 96) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ceptra Software Update")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    Text("Installed v\(AppMetadata.currentVersionString) · Repo: \(appState.settings.gitHubRepository)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textSecondary)
                }
                Spacer()
            }

            Divider().overlay(CeptraTheme.border)

            stateBody

            Divider().overlay(CeptraTheme.border)

            HStack {
                Button("Check Now") {
                    Task { await appState.checkForUpdates(userInitiated: true) }
                }
                .disabled(isBusy)

                Spacer()

                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .background(CeptraTheme.sidebarBG)
    }

    private var isBusy: Bool {
        switch appState.updateState {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    @ViewBuilder
    private var stateBody: some View {
        switch appState.updateState {
        case .idle:
            Text("Click \"Check Now\" to query GitHub Releases for a newer native macOS build.")
                .font(.system(size: 12.5))
                .foregroundStyle(CeptraTheme.textSecondary)

        case .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking GitHub Releases for \(appState.settings.gitHubRepository)…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(CeptraTheme.textSecondary)
            }
            .padding(.vertical, 12)

        case .upToDate(let current, let checkedAt):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(CeptraTheme.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're up to date (v\(current.description))")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    Text("Last checked \(checkedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
            }
            .padding(.vertical, 8)

        case .available(let release, let latestVersion, let asset):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CeptraBadge(text: "v\(latestVersion.description) Available", color: CeptraTheme.accentWarm, icon: "sparkles")
                    Spacer()
                    if let asset {
                        Text("\(asset.name) (\(asset.formattedSize))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                }

                if let notes = release.body, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollView {
                        Text(notes)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(height: 140)
                    .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(CeptraTheme.border, lineWidth: 0.75))
                }

                HStack(spacing: 10) {
                    if let asset {
                        Button("Download Update") {
                            Task { await appState.downloadUpdate(release: release, asset: asset) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(CeptraTheme.accent)
                    }

                    Button("Open Release Page") {
                        NSWorkspace.shared.open(release.htmlURL)
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .downloading(let release, let asset, let progress):
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloading \(release.tagName) — \(asset.name)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textPrimary)
                ProgressView(value: progress, total: 1.0)
                    .tint(CeptraTheme.accent)
                Text("\(Int((progress * 100).rounded()))% complete · Verifying SHA-256 after download")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
            }
            .padding(.vertical, 8)

        case .readyToInstall(let release, let artifact):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(CeptraTheme.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ready to Install \(release.tagName)")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                        Text(artifact.verifiedAgainstChecksums
                             ? "SHA-256 verified against release SHA256SUMS.txt"
                             : "Downloaded SHA-256: \(artifact.sha256.prefix(16))…")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(CeptraTheme.success)
                    }
                }

                Text("Ceptra will close immediately, atomically replace the installed app bundle, clear macOS quarantine attributes, and relaunch the new version.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CeptraTheme.textSecondary)

                HStack(spacing: 10) {
                    Button("Quit & Install Update") {
                        appState.installDownloadedUpdateAndQuit(release: release, artifact: artifact)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CeptraTheme.success)

                    Button("Reveal Downloaded File") {
                        NSWorkspace.shared.activateFileViewerSelecting([artifact.fileURL])
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .installing(let release):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Closing Ceptra and installing \(release.tagName)…")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .padding(.vertical, 10)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Update Check Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CeptraTheme.failure)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .textSelection(.enabled)
            }
        }
    }
}
