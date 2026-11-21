import AppKit
import CeptraCore
import SwiftUI
import WebKit

struct CodeceptUIInspectorView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Compact Control Bar
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 7, height: 7)
                    Text(statusTitle)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textPrimary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if let url = appState.codeceptUIStatus.activeURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Open @codeceptjs/ui in Default Browser")
                }

                if appState.codeceptUIStatus.isActive {
                    Button {
                        appState.restartCodeceptUIServer()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10.5))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Restart @codeceptjs/ui")

                    Button("Stop") {
                        appState.stopCodeceptUIServer()
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(CeptraTheme.failure)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(CeptraTheme.failure.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .buttonStyle(.plain)
                } else if appState.isCodeceptUIInstalled {
                    Button("Start") {
                        appState.startCodeceptUIServer()
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(CeptraTheme.success, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CeptraTheme.border).frame(height: 1)
            }

            // Main Surface
            switch appState.codeceptUIStatus {
            case .running(let url, let port):
                LoopbackCodeceptUIWebView(url: url, allowedPort: port)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .starting(let port):
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Starting @codeceptjs/ui on 127.0.0.1:\(port)…")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    recentLogsBox
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed(let message):
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(CeptraTheme.failure)
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.failure)
                        .multilineTextAlignment(.center)
                    Button("Retry Start") {
                        appState.startCodeceptUIServer()
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(CeptraTheme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .buttonStyle(.plain)
                    recentLogsBox
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .stopped:
                if appState.isCodeceptUIInstalled {
                    VStack(spacing: 10) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(CeptraTheme.violet)
                        Text("CodeceptUI Live")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                        Text("Launch @codeceptjs/ui on a private loopback port (127.0.0.1) right inside Ceptra.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .multilineTextAlignment(.center)
                        Button {
                            appState.startCodeceptUIServer()
                        } label: {
                            Label("Start @codeceptjs/ui", systemImage: "play.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(CeptraTheme.violet, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(CeptraTactilePressStyle())
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    installMissingCard
                }
            }
        }
    }

    private var installMissingCard: some View {
        let pm = appState.workspace?.packageManager ?? .npm
        let preview: String = {
            switch pm {
            case .npm: return "npm install -D @codeceptjs/ui"
            case .pnpm: return "pnpm add -D @codeceptjs/ui"
            case .yarn: return "yarn add -D @codeceptjs/ui"
            case .bun: return "bun add -d @codeceptjs/ui"
            }
        }()

        return VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(CeptraTheme.textMuted)
            Text("@codeceptjs/ui Not Installed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CeptraTheme.textPrimary)
            Text("Install the official CodeceptJS interactive web UI in this workspace to run live browser visual tests inside Ceptra.")
                .font(.system(size: 11.5))
                .foregroundStyle(CeptraTheme.textSecondary)
                .multilineTextAlignment(.center)
            Text(preview)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(CeptraTheme.cyan)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
            Button {
                appState.installCodeceptUIPackage()
            } label: {
                Label("Install @codeceptjs/ui", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(CeptraTheme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(CeptraTactilePressStyle())
            .disabled(appState.workspace == nil || appState.isRunning)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var recentLogsBox: some View {
        if !appState.codeceptUILogs.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(appState.codeceptUILogs.suffix(12).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 110)
            .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
        }
    }

    private var statusDotColor: Color {
        switch appState.codeceptUIStatus {
        case .running: return CeptraTheme.success
        case .starting: return CeptraTheme.accentWarm
        case .failed: return CeptraTheme.failure
        case .stopped: return CeptraTheme.textMuted
        }
    }

    private var statusTitle: String {
        switch appState.codeceptUIStatus {
        case .running(_, let port): return "@codeceptjs/ui :\(port)"
        case .starting(let port): return "Starting :\(port)…"
        case .failed: return "@codeceptjs/ui (error)"
        case .stopped: return "@codeceptjs/ui"
        }
    }
}

private struct LoopbackCodeceptUIWebView: NSViewRepresentable {
    let url: URL
    let allowedPort: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(allowedPort: allowedPort)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.allowedPort = allowedPort
        if webView.url?.port != url.port {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var allowedPort: Int

        init(allowedPort: Int) {
            self.allowedPort = allowedPort
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let targetURL = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if targetURL.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            if CodeceptUIServerManager.isAllowedLoopbackURL(targetURL, port: allowedPort) {
                decisionHandler(.allow)
            } else {
                if let scheme = targetURL.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    NSWorkspace.shared.open(targetURL)
                }
                decisionHandler(.cancel)
            }
        }
    }
}
