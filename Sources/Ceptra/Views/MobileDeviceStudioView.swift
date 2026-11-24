import AppKit
import CeptraCore
import SwiftUI

// MARK: - Dedicated Phone UI Sidebar (Sits Alone in Left or Right Window)

struct MobilePhoneSidebarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hoverDevicePoint: CGPoint? = nil
    @State private var dragStartCanvasPoint: CGPoint? = nil
    @State private var dragCurrentCanvasPoint: CGPoint? = nil
    @State private var tapRippleCanvasPoint: CGPoint? = nil

    private var activePreset: MobileResolutionPreset {
        appState.activeMobileResolutionPreset
    }

    private var activePlatform: MobilePlatform {
        appState.selectedMobilePlatform
    }

    private var logicalSize: CGSize {
        if let snap = appState.mobileSnapshot, snap.logicalWidth > 0, snap.logicalHeight > 0 {
            return CGSize(width: snap.logicalWidth, height: snap.logicalHeight)
        }
        return activePreset.logicalSize(for: appState.mobileOrientation)
    }

    var body: some View {
        VStack(spacing: 0) {
            phoneHeaderBar
            deviceConnectionStrip
            if let promptDevice = appState.pendingPluggedInDevicePrompt {
                pluggedInDevicePermissionBanner(device: promptDevice)
            } else if appState.isMobileAutoSetupRunning {
                autoSetupProgressBanner
            }
            phoneCanvasStage
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                .clipped()
            phoneHardwareFooter
        }
        .background(CeptraTheme.sidebarBG)
        .onAppear {
            if appState.mobileSnapshot == nil {
                appState.loadFallbackPreviewSnapshotIfDisconnected()
            }
            appState.startMobileUSBMonitorIfNeeded()
            appState.startMobileLiveStreamIfNeeded()
        }
        .onDisappear {
            if !appState.showingMobileDeviceWizard {
                appState.stopMobileUSBMonitor()
            }
            appState.stopMobileLiveStream()
        }
    }

    private func pluggedInDevicePermissionBanner(device: MobileDeviceDescriptor) -> some View {
        let isUnauthorized = device.state == .unauthorized
        let accentTint = isUnauthorized ? CeptraTheme.warning : CeptraTheme.success
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: isUnauthorized ? "lock.iphone" : (device.platform == .ios ? "iphone.radiowaves.left.and.right" : "smartphone"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accentTint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isUnauthorized ? "\(device.name) — Tap Allow on Phone" : "\(device.name) plugged in")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                        .lineLimit(1)
                    Text(isUnauthorized
                         ? "Unlock your phone and tap \"Allow USB debugging\", then click Check Again."
                         : "Allow Ceptra to auto-setup Mobilewright agent & mirror?")
                        .font(.system(size: 10))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 2)
            }

            if appState.isMobileAutoSetupRunning {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(appState.mobileAutoSetupStatusText.isEmpty ? "Setting up…" : appState.mobileAutoSetupStatusText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(CeptraTheme.success)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else if isUnauthorized {
                HStack(spacing: 6) {
                    Button {
                        Task { await appState.refreshMobileDevices() }
                    } label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CeptraTheme.warning)
                    .controlSize(.small)

                    Button("Later") {
                        appState.dismissPluggedInDevicePrompt(device)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(CeptraTheme.textMuted)
                }
            } else {
                HStack(spacing: 6) {
                    Button {
                        Task { await appState.allowAndAutoSetupRealDevice(device) }
                    } label: {
                        Label("Allow & Setup", systemImage: "checkmark.shield.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CeptraTheme.success)
                    .controlSize(.small)

                    Button("Wizard") {
                        appState.dismissPluggedInDevicePrompt(device)
                        appState.selectedMobileDeviceID = device.id
                        appState.mobileWizardTargetKind = device.platform == .ios ? .iosReal : .androidReal
                        appState.openMobileDeviceWizard(initialStep: 3)
                    }
                    .controlSize(.small)

                    Button("Later") {
                        appState.dismissPluggedInDevicePrompt(device)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(CeptraTheme.textMuted)
                }
            }
        }
        .padding(10)
        .background(accentTint.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(accentTint.opacity(0.32)).frame(height: 1)
        }
    }

    private var autoSetupProgressBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(appState.mobileAutoSetupStatusText.isEmpty ? "Setting up device…" : appState.mobileAutoSetupStatusText)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(CeptraTheme.success)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(CeptraTheme.success.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(CeptraTheme.success.opacity(0.3)).frame(height: 1)
        }
    }

    // MARK: - Header Controls

    private var phoneHeaderBar: some View {
        HStack(spacing: 5) {
            Menu {
                Section("Resolution Presets") {
                    ForEach(MobileResolutionPreset.builtInPresets) { preset in
                        Button {
                            appState.setMobileResolutionPreset(preset.id)
                        } label: {
                            HStack {
                                Text("\(preset.name) (\(Int(preset.logicalWidth))×\(Int(preset.logicalHeight)))")
                                if preset.id == activePreset.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Connect Real Device or Simulator…") {
                    appState.openMobileDeviceWizard()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: activePlatform == .ios ? "iphone" : "candybarphone")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CeptraTheme.accent)
                    Text((appState.connectedMobileDevice?.name ?? activePreset.name).trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CeptraTheme.border, lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: true)
            .frame(maxWidth: 195, alignment: .leading)
            .help("Switch Resolution Preset or Connect Device")

            Spacer(minLength: 4)

            // Dock Left / Right Toggle
            Button {
                withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                    let next: MobilePhoneDockSide = appState.mobilePhoneDockSide == .right ? .left : .right
                    appState.setMobilePhoneDockSide(next)
                }
            } label: {
                Image(systemName: appState.mobilePhoneDockSide == .right ? "sidebar.leading" : "sidebar.trailing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(CeptraTheme.hoverBG.opacity(0.65), in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(appState.mobilePhoneDockSide == .right ? "Dock Phone Sidebar on Left" : "Dock Phone Sidebar on Right")

            // Wireframe All Interactive Bounds Overlay Toggle (Appium-style element grid)
            Button {
                appState.showMobileWireframeBounds.toggle()
            } label: {
                Image(systemName: "square.dashed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appState.showMobileWireframeBounds ? CeptraTheme.cyan : CeptraTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(
                        (appState.showMobileWireframeBounds ? CeptraTheme.cyan.opacity(0.16) : CeptraTheme.hoverBG.opacity(0.65)),
                        in: RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .help(appState.showMobileWireframeBounds ? "Hide Interactive Element Wireframe Bounds" : "Show All Interactive Element Wireframe Bounds")

            // Rotate Portrait / Landscape
            Button {
                appState.performMobileQuickAction(.setOrientation)
            } label: {
                Image(systemName: "rotate.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appState.mobileOrientation == .landscape ? CeptraTheme.accent : CeptraTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(
                        (appState.mobileOrientation == .landscape ? CeptraTheme.accent.opacity(0.16) : CeptraTheme.hoverBG.opacity(0.65)),
                        in: RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .help("Rotate \(appState.mobileOrientation == .portrait ? "to Landscape" : "to Portrait")")

            // Refresh Screenshot & Hierarchy
            Button {
                Task { await appState.refreshMobileScreenSnapshot() }
            } label: {
                Group {
                    if appState.isMobileSnapshotLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CeptraTheme.textSecondary)
                    }
                }
                .frame(width: 24, height: 24)
                .background(CeptraTheme.hoverBG.opacity(0.65), in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(appState.isMobileSnapshotLoading)
            .help("Refresh Screen & Accessibility Hierarchy")

            // Record Toggle (Green when active — red reserved strictly for errors)
            Button {
                appState.mobileRecordToEditor.toggle()
            } label: {
                HStack(spacing: 3.5) {
                    Circle()
                        .fill(appState.mobileRecordToEditor ? CeptraTheme.success : CeptraTheme.textMuted)
                        .frame(width: 6.5, height: 6.5)
                    Text("Rec")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(appState.mobileRecordToEditor ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                }
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(
                    (appState.mobileRecordToEditor ? CeptraTheme.success.opacity(0.16) : CeptraTheme.hoverBG.opacity(0.65)),
                    in: RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .strokeBorder(appState.mobileRecordToEditor ? CeptraTheme.success.opacity(0.45) : Color.clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help(appState.mobileRecordToEditor ? "Recording Mobilewright steps to active editor (Click to pause)" : "Enable step recording to active editor")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CeptraTheme.border).frame(height: 1)
        }
    }

    private var deviceConnectionStrip: some View {
        let isLiveStreaming = appState.connectedMobileDevice != nil
            && !appState.mobileCaptureAgentRequired
            && appState.mobileCaptureErrorDetail == nil
            && (appState.mobileSnapshot?.screenshotPNGData != nil || !(appState.mobileSnapshot?.allNodes.isEmpty ?? true))

        let dotColor: Color = {
            if appState.connectedMobileDevice == nil { return CeptraTheme.accentWarm }
            if appState.mobileCaptureAgentRequired { return CeptraTheme.warning }
            if appState.mobileCaptureErrorDetail != nil { return CeptraTheme.failure }
            return isLiveStreaming ? CeptraTheme.success : CeptraTheme.accentWarm
        }()

        return HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6.5, height: 6.5)

            if let dev = appState.connectedMobileDevice {
                if appState.mobileCaptureAgentRequired {
                    Text("USB Detected · Agent Required")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.warning)
                        .lineLimit(1)
                } else if appState.mobileCaptureErrorDetail != nil {
                    Text("\(dev.platform.displayName) · Capture Error")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.failure)
                        .lineLimit(1)
                } else if appState.isMobileSnapshotLoading && appState.mobileSnapshot == nil {
                    Text("Connecting to \(dev.name)…")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .lineLimit(1)
                } else {
                    let liveTypeLabel = dev.type == .real ? "\(dev.platform.displayName) Real Device" : dev.type.displayName
                    Text("Live · \(liveTypeLabel)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.success)
                        .lineLimit(1)
                }
            } else {
                Text("Interactive Preview · \(activePlatform.displayName)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Appium-Style Canvas Interaction Mode Switcher (Touch & Swipe vs Inspect Only)
            HStack(spacing: 1) {
                ForEach(MobileCanvasInteractionMode.allCases) { mode in
                    let active = appState.mobileCanvasInteractionMode == mode
                    Button {
                        appState.mobileCanvasInteractionMode = mode
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: mode.symbolName)
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(mode == .interact ? "Touch" : "Inspect")
                                .font(.system(size: 9.5, weight: active ? .semibold : .medium))
                        }
                        .foregroundStyle(active ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 2.5)
                        .background(
                            active ? (mode == .interact ? CeptraTheme.success.opacity(0.22) : CeptraTheme.activeBG) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(mode == .interact
                          ? "Touch & Swipe Mode: Click on the phone screen to tap live; drag to swipe"
                          : "Inspect Mode: Click to select elements without tapping; drag to swipe; ⌘-Click to tap")
                }
            }
            .padding(1.5)
            .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5.5, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))

            Button {
                appState.openMobileDeviceWizard()
            } label: {
                Label(appState.connectedMobileDevice == nil ? "Connect…" : "Switch…", systemImage: "cable.connector")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(CeptraTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(CeptraTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Open Step-by-Step Real Device & Simulator Setup Wizard")

            Button {
                withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                    appState.isMobileStudioVisible = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Hide Mobilewright Phone Studio (⌘⌥M)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(CeptraTheme.canvasBG.opacity(0.45))
        .overlay(alignment: .bottom) {
            Rectangle().fill(CeptraTheme.border).frame(height: 1)
        }
    }

    // MARK: - Centered Multi-Resolution Auto-Fit Phone Stage (Strict 4-Edge Breathing Room)

    private var phoneCanvasStage: some View {
        GeometryReader { geo in
            // Account for outer hardware bezel (7pt * 2 = 14pt) + balanced 16pt safe margin on all 4 sides
            let bezelThickness: CGFloat = 7
            let totalPadding = Double(bezelThickness) + 16.0
            let fit = MobileLocatorSynthesizer.computeAspectFit(
                stageSize: geo.size,
                deviceLogicalSize: logicalSize,
                padding: totalPadding
            )
            let fittedW = fit.scaledSize.width
            let fittedH = fit.scaledSize.height
            let isTablet = activePreset.isTablet
            let outerRadius = max(14, CGFloat((isTablet ? 20 : 34) * fit.scale) + bezelThickness)
            let innerRadius = max(10, outerRadius - bezelThickness)

            let isShowingRecoveryOverlay = appState.connectedMobileDevice != nil
                && (appState.mobileCaptureAgentRequired || appState.mobileCaptureErrorDetail != nil)
            let isShowingLoadingOverlay = appState.connectedMobileDevice != nil
                && appState.isMobileSnapshotLoading
                && appState.mobileSnapshot == nil
            let isInteractiveCanvasActive = !isShowingRecoveryOverlay && !isShowingLoadingOverlay && appState.mobileSnapshot != nil

            ZStack {
                CeptraTheme.canvasBG.opacity(0.7)

                ZStack(alignment: .topLeading) {
                    // Screen Content: Actionable Recovery Card, Loading State, Live Device Screenshot, OR 1:1 Virtual Preview
                    if let dev = appState.connectedMobileDevice, isShowingRecoveryOverlay {
                        liveDeviceRecoveryOverlay(device: dev, canvasHeight: fittedH)
                            .frame(width: fittedW, height: fittedH)
                    } else if isShowingLoadingOverlay {
                        VStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.regular)
                            Text("Capturing live screen…")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(CeptraTheme.textSecondary)
                        }
                        .frame(width: fittedW, height: fittedH)
                        .background(Color(red: 0.055, green: 0.065, blue: 0.11))
                    } else if let pngData = appState.mobileSnapshot?.screenshotPNGData,
                              let nsImage = NSImage(data: pngData) {
                        Image(nsImage: nsImage)
                            .interpolation(.high)
                            .resizable()
                            .frame(width: fittedW, height: fittedH)
                    } else if let snapshot = appState.mobileSnapshot {
                        CoordinateMatchedVirtualScreen(
                            snapshot: snapshot,
                            layout: fit,
                            platform: activePlatform
                        )
                        .frame(width: fittedW, height: fittedH)
                    }

                    // Interactive Hover & Selected Element Reticle Overlay — STRICTLY hidden during recovery/loading!
                    if isInteractiveCanvasActive, let snapshot = appState.mobileSnapshot {
                        nodeReticleOverlay(snapshot: snapshot, layout: fit)
                    }

                    // Live Drag-to-Swipe Directional Vector Overlay + Tap Touch Ripple
                    if isInteractiveCanvasActive {
                        gestureFeedbackOverlay(layout: fit)
                    }
                }
                .frame(width: fittedW, height: fittedH)
                .clipShape(RoundedRectangle(cornerRadius: innerRadius, style: .continuous))
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard isInteractiveCanvasActive, let snapshot = appState.mobileSnapshot else {
                        if hoverDevicePoint != nil { hoverDevicePoint = nil }
                        return
                    }
                    switch phase {
                    case .active(let pt):
                        let devPt = MobileLocatorSynthesizer.mapCanvasPointToDevicePoint(pt, layout: fit)
                        hoverDevicePoint = devPt
                        let hit = MobileLocatorSynthesizer.hitTestNode(atDevicePoint: devPt, in: snapshot.roots)
                        if appState.mobileHoveredNodeID != hit?.id {
                            appState.mobileHoveredNodeID = hit?.id
                        }
                    case .ended:
                        hoverDevicePoint = nil
                        appState.mobileHoveredNodeID = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isInteractiveCanvasActive else { return }
                            let dist = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                            if dist >= 14 {
                                dragStartCanvasPoint = value.startLocation
                                dragCurrentCanvasPoint = value.location
                            }
                        }
                        .onEnded { value in
                            defer {
                                dragStartCanvasPoint = nil
                                dragCurrentCanvasPoint = nil
                            }
                            guard isInteractiveCanvasActive, let snapshot = appState.mobileSnapshot else { return }
                            let dx = value.location.x - value.startLocation.x
                            let dy = value.location.y - value.startLocation.y
                            let dist = hypot(dx, dy)

                            if dist >= 18 {
                                // Drag-to-Swipe gesture on the phone screen
                                let startDev = MobileLocatorSynthesizer.mapCanvasPointToDevicePoint(value.startLocation, layout: fit)
                                let endDev = MobileLocatorSynthesizer.mapCanvasPointToDevicePoint(value.location, layout: fit)
                                triggerTapRipple(at: value.location)
                                appState.performMobileCanvasDragSwipe(from: startDev, to: endDev)
                            } else {
                                // Single Tap on the phone screen (zero double-click latency!)
                                let devPt = MobileLocatorSynthesizer.mapCanvasPointToDevicePoint(value.location, layout: fit)
                                let hit = MobileLocatorSynthesizer.hitTestNode(atDevicePoint: devPt, in: snapshot.roots)
                                if let hit {
                                    appState.mobileSelectedNodeID = hit.id
                                }
                                if appState.mobileCanvasInteractionMode == .interact || NSEvent.modifierFlags.contains(.command) {
                                    triggerTapRipple(at: value.location)
                                    appState.performMobileQuickAction(.tap, node: hit, coordinate: devPt)
                                }
                            }
                        }
                )
                .padding(bezelThickness)
                .background(
                    RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                        .fill(Color(red: 0.08, green: 0.09, blue: 0.13))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1.2)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 16, y: 6)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: isShowingRecoveryOverlay) { _, showing in
                if showing {
                    hoverDevicePoint = nil
                    appState.mobileHoveredNodeID = nil
                }
            }
        }
    }

    private func liveDeviceRecoveryOverlay(device: MobileDeviceDescriptor, canvasHeight: CGFloat) -> some View {
        let isRealIOS = device.platform == .ios && device.type == .real
        let detail = appState.mobileCaptureErrorDetail ?? ""
        let isWildcardBlocked = isRealIOS && (
            detail.lowercased().contains("wildcard")
            || detail.lowercased().contains("personal team")
            || detail.contains("0xe8008001")
            || appState.mobileCaptureAgentRequired
        )
        let accentTint: Color = appState.mobileCaptureAgentRequired ? CeptraTheme.warning : CeptraTheme.failure
        let cleanName = device.name.trimmingCharacters(in: .whitespacesAndNewlines)

        return ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.072, blue: 0.115),
                    Color(red: 0.045, green: 0.052, blue: 0.088)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    // Clean Status Emblem
                    ZStack {
                        Circle()
                            .fill(accentTint.opacity(0.14))
                            .frame(width: 48, height: 48)
                        Circle()
                            .strokeBorder(accentTint.opacity(0.32), lineWidth: 1)
                            .frame(width: 48, height: 48)
                        Image(systemName: isWildcardBlocked ? "checkmark.seal" : (appState.mobileCaptureAgentRequired ? "wrench.and.screwdriver.fill" : "exclamationmark.triangle.fill"))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(accentTint)
                    }

                    VStack(spacing: 6) {
                        Text(isWildcardBlocked ? "Wildcard Signing Required" : (appState.mobileCaptureAgentRequired ? "Agent Setup Required" : "Live Capture Failed"))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 5) {
                            Circle()
                                .fill(accentTint)
                                .frame(width: 6, height: 6)
                            Text(formattedDeviceBadgeTitle(device: device, cleanName: cleanName))
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.86))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(Color.white.opacity(0.06), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.11), lineWidth: 1))
                    }

                    // Recessed Explanation Card (clean, scannable, no raw wall of text)
                    VStack(alignment: .leading, spacing: 6) {
                        if isWildcardBlocked {
                            Text("Physical iPhones require a Wildcard (*) Apple Developer profile ($99/yr) to sign the Mobilewright runner.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.82))
                                .fixedSize(horizontal: false, vertical: true)

                            if !detail.isEmpty {
                                Text(detail)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.55))
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text(detail.isEmpty ? "Connect or unlock the device and retry capture." : detail)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.78))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                    )

                    // Clean 3-Tier Action Stack (Smart #1 Primary CTA + Compact 2-Column Secondary + Subtle Footer Links)
                    VStack(spacing: 8) {
                        if isWildcardBlocked {
                            recoveryPrimaryButton(
                                title: appState.isMobileSnapshotLoading ? "Launching Simulator…" : "Use iOS Simulator (Free)",
                                icon: "iphone.gen3",
                                isDisabled: appState.isMobileSnapshotLoading
                            ) {
                                Task { await appState.switchToAvailableXcodeSimulator() }
                            }

                            HStack(spacing: 7) {
                                recoverySecondaryButton(title: "Wizard", icon: "wand.and.stars") {
                                    appState.openMobileDeviceWizard(initialStep: 3)
                                }
                                recoverySecondaryButton(title: "Xcode", icon: "hammer.fill") {
                                    appState.openXcodeForSigning()
                                }
                            }
                        } else {
                            recoveryPrimaryButton(
                                title: appState.isMobileAutoSetupRunning ? "Setting up…" : "Allow & Auto-Setup",
                                icon: "checkmark.shield.fill",
                                isDisabled: appState.isMobileAutoSetupRunning
                            ) {
                                Task { await appState.allowAndAutoSetupRealDevice(device) }
                            }

                            HStack(spacing: 7) {
                                recoverySecondaryButton(title: "Setup Wizard", icon: "wand.and.stars") {
                                    appState.openMobileDeviceWizard(initialStep: 3)
                                }
                                recoverySecondaryButton(title: "Retry", icon: "arrow.clockwise") {
                                    Task { await appState.refreshMobileScreenSnapshot() }
                                }
                            }
                        }

                        HStack(spacing: 14) {
                            if isWildcardBlocked {
                                Button {
                                    Task { await appState.refreshMobileScreenSnapshot() }
                                } label: {
                                    Label("Retry", systemImage: "arrow.clockwise")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.68))
                                }
                                .buttonStyle(.plain)
                            }

                            Button {
                                appState.disconnectMobileDevice()
                            } label: {
                                Text("Back to Preview")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.68))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
                .frame(minHeight: canvasHeight)
            }
        }
    }

    private func formattedDeviceBadgeTitle(device: MobileDeviceDescriptor, cleanName: String) -> String {
        guard let rawVer = device.osVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !rawVer.isEmpty else {
            return cleanName
        }
        let lower = rawVer.lowercased()
        if lower.hasPrefix("ios") || lower.hasPrefix("android") || lower.hasPrefix("ipados") {
            return "\(cleanName) · \(rawVer)"
        }
        return "\(cleanName) · \(device.platform.displayName) \(rawVer)"
    }

    private func recoveryPrimaryButton(
        title: String,
        icon: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color(red: 0.02, green: 0.14, blue: 0.08))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(CeptraTheme.success, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: CeptraTheme.success.opacity(0.25), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.65 : 1)
    }

    private func recoverySecondaryButton(
        title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white.opacity(0.88))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7.5)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7.5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func nodeReticleOverlay(snapshot: MobileScreenSnapshot, layout: MobileAspectFitLayout) -> some View {
        let canvasW = layout.scaledSize.width
        let canvasH = layout.scaledSize.height
        let hoveredNode = appState.mobileHoveredNodeID.flatMap { id in
            snapshot.allNodes.first(where: { $0.id == id })
        }
        let selectedNode = appState.selectedMobileNode
        let showGuides = appState.mobileCanvasInteractionMode == .inspect || appState.showMobileWireframeBounds

        ZStack(alignment: .topLeading) {
            // Optional Wireframe Layer: Crisp hairlines for every visible interactive control on screen
            if appState.showMobileWireframeBounds {
                let interactiveNodes = snapshot.allNodes.filter { node in
                    node.isVisible
                        && node.bounds.width >= 6
                        && node.bounds.height >= 6
                        && node.normalizedRole != "window"
                        && node.normalizedRole != "other"
                        && node.id != selectedNode?.id
                        && node.id != hoveredNode?.id
                }
                ForEach(interactiveNodes) { node in
                    let r = MobileLocatorSynthesizer.mapNodeBoundsToCanvasRect(node.bounds, layout: layout)
                    Rectangle()
                        .strokeBorder(CeptraTheme.cyan.opacity(0.38), lineWidth: 0.85)
                        .frame(width: max(2, r.width), height: max(2, r.height))
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                }
            }

            // Precision Hovered Element Reticle + Optional Sub-Pixel Alignment Guides
            if let hovered = hoveredNode, hovered.id != selectedNode?.id, hovered.normalizedRole != "window" {
                let r = MobileLocatorSynthesizer.mapNodeBoundsToCanvasRect(hovered.bounds, layout: layout)

                if showGuides {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: r.minY))
                        p.addLine(to: CGPoint(x: canvasW, y: r.minY))
                        p.move(to: CGPoint(x: 0, y: r.maxY))
                        p.addLine(to: CGPoint(x: canvasW, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: 0))
                        p.addLine(to: CGPoint(x: r.minX, y: canvasH))
                        p.move(to: CGPoint(x: r.maxX, y: 0))
                        p.addLine(to: CGPoint(x: r.maxX, y: canvasH))
                    }
                    .stroke(CeptraTheme.cyan.opacity(0.28), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                    .allowsHitTesting(false)
                }

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(CeptraTheme.cyan.opacity(0.95), lineWidth: 1.4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(CeptraTheme.cyan.opacity(0.10))
                    )
                    .frame(width: max(4, r.width), height: max(4, r.height))
                    .position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)
            }

            // Selected Element Surgical Reticle + Corner Ticks + Smart Non-Colliding HUD Pill
            if let selected = selectedNode {
                let r = MobileLocatorSynthesizer.mapNodeBoundsToCanvasRect(selected.bounds, layout: layout)
                let isWindowRoot = selected.normalizedRole == "window"
                let locator = MobileLocatorSynthesizer.recommendedLocator(for: selected, platform: activePlatform)
                let selectionAccent = CeptraTheme.success
                let dimLabel = "\(Int(selected.bounds.width.rounded()))×\(Int(selected.bounds.height.rounded()))"

                if showGuides && !isWindowRoot {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: r.midY))
                        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
                        p.move(to: CGPoint(x: r.maxX, y: r.midY))
                        p.addLine(to: CGPoint(x: canvasW, y: r.midY))
                        p.move(to: CGPoint(x: r.midX, y: 0))
                        p.addLine(to: CGPoint(x: r.midX, y: r.minY))
                        p.move(to: CGPoint(x: r.midX, y: r.maxY))
                        p.addLine(to: CGPoint(x: r.midX, y: canvasH))
                    }
                    .stroke(selectionAccent.opacity(0.28), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                    .allowsHitTesting(false)
                }

                RoundedRectangle(cornerRadius: isWindowRoot ? 8 : 4, style: .continuous)
                    .strokeBorder(
                        isWindowRoot ? Color.white.opacity(0.4) : selectionAccent,
                        style: isWindowRoot ? StrokeStyle(lineWidth: 1.2, dash: [5, 4]) : StrokeStyle(lineWidth: 1.75)
                    )
                    .background(
                        RoundedRectangle(cornerRadius: isWindowRoot ? 8 : 4, style: .continuous)
                            .fill(isWindowRoot ? Color.clear : selectionAccent.opacity(0.11))
                    )
                    .frame(width: max(4, r.width), height: max(4, r.height))
                    .position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)

                if !isWindowRoot && r.width >= 14 && r.height >= 14 {
                    // 4 Crisp Corner Anchor Squares (Appium / Figma Inspector style)
                    ForEach(0..<4, id: \.self) { idx in
                        let cx = (idx % 2 == 0) ? r.minX : r.maxX
                        let cy = (idx < 2) ? r.minY : r.maxY
                        Rectangle()
                            .fill(selectionAccent)
                            .frame(width: 4.5, height: 4.5)
                            .position(x: cx, y: cy)
                            .allowsHitTesting(false)
                    }
                }

                if !isWindowRoot {
                    let topSafeMin: CGFloat = 24
                    let bottomSafeMax: CGFloat = canvasH - 24
                    let pillCenterY: CGFloat = {
                        if r.minY - 14 >= topSafeMin {
                            return r.minY - 12
                        } else if r.maxY + 14 <= bottomSafeMax {
                            return r.maxY + 12
                        } else {
                            return max(topSafeMin, r.minY + 12)
                        }
                    }()
                    let pillMaxW = max(90, canvasW - 14)

                    HStack(spacing: 5) {
                        Text(locator)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(dimLabel)
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .opacity(0.75)
                    }
                    .foregroundStyle(Color(red: 0.02, green: 0.12, blue: 0.07))
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2.5)
                    .frame(maxWidth: pillMaxW)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(Capsule().fill(selectionAccent))
                    .shadow(color: Color.black.opacity(0.38), radius: 4, y: 1.5)
                    .position(
                        x: min(max(56, r.midX), max(56, canvasW - 56)),
                        y: pillCenterY
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(width: canvasW, height: canvasH, alignment: .topLeading)
    }

    // MARK: - Live Touch Ripple & Drag-to-Swipe Vector Overlay

    private func triggerTapRipple(at pt: CGPoint) {
        tapRippleCanvasPoint = pt
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)
            if tapRippleCanvasPoint == pt {
                tapRippleCanvasPoint = nil
            }
        }
    }

    @ViewBuilder
    private func gestureFeedbackOverlay(layout: MobileAspectFitLayout) -> some View {
        ZStack(alignment: .topLeading) {
            if let ripple = tapRippleCanvasPoint {
                Circle()
                    .fill(CeptraTheme.success.opacity(0.28))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Circle()
                            .strokeBorder(CeptraTheme.success, lineWidth: 2)
                    )
                    .position(ripple)
                    .allowsHitTesting(false)
            }

            if let start = dragStartCanvasPoint, let current = dragCurrentCanvasPoint {
                let startDev = MobileLocatorSynthesizer.mapCanvasPointToDevicePoint(start, layout: layout)
                let endDev = MobileLocatorSynthesizer.mapCanvasPointToDevicePoint(current, layout: layout)
                let dir = MobileLocatorSynthesizer.classifySwipeDirection(from: startDev, to: endDev)
                let dirLabel: String = {
                    switch dir {
                    case .swipeUp: return "Swipe Up (Scroll Down)"
                    case .swipeDown: return "Swipe Down (Scroll Up)"
                    case .swipeLeft: return "Swipe Left"
                    case .swipeRight: return "Swipe Right"
                    default: return "Swipe"
                    }
                }()

                Path { path in
                    path.move(to: start)
                    path.addLine(to: current)
                }
                .stroke(CeptraTheme.success, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 3]))
                .allowsHitTesting(false)

                Circle()
                    .fill(CeptraTheme.success.opacity(0.35))
                    .frame(width: 12, height: 12)
                    .position(start)
                    .allowsHitTesting(false)

                Circle()
                    .fill(CeptraTheme.success)
                    .frame(width: 14, height: 14)
                    .position(current)
                    .allowsHitTesting(false)

                Text(dirLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.02, green: 0.14, blue: 0.08))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(CeptraTheme.success))
                    .position(x: (start.x + current.x) / 2, y: max(22, min(start.y, current.y) - 18))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: layout.scaledSize.width, height: layout.scaledSize.height, alignment: .topLeading)
    }

    // MARK: - Hardware Controls, 1-Click Swipe Pad & Live Coordinates Footer (Always Visible)

    private var phoneHardwareFooter: some View {
        HStack(spacing: 4) {
            hardwareBtn("Back", icon: "chevron.backward") {
                appState.performMobileQuickAction(.goBack)
            }
            hardwareBtn("Home", icon: "house") {
                appState.performMobileQuickAction(.pressHome)
            }

            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)

            // 1-Click Directional Swipe Controls (Scroll Down/Up & Page Left/Right)
            swipeIconBtn(icon: "arrow.up", help: "Swipe Up (Scroll Down) — I.swipeUp()") {
                appState.performMobileQuickAction(.swipeUp)
            }
            swipeIconBtn(icon: "arrow.down", help: "Swipe Down (Scroll Up) — I.swipeDown()") {
                appState.performMobileQuickAction(.swipeDown)
            }
            swipeIconBtn(icon: "arrow.left", help: "Swipe Left (Next Page) — I.swipeLeft()") {
                appState.performMobileQuickAction(.swipeLeft)
            }
            swipeIconBtn(icon: "arrow.right", help: "Swipe Right (Prev Page) — I.swipeRight()") {
                appState.performMobileQuickAction(.swipeRight)
            }

            Spacer(minLength: 2)

            if let pt = hoverDevicePoint {
                Text("\(Int(pt.x.rounded())), \(Int(pt.y.rounded()))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(CeptraTheme.cyan)
            } else {
                Text("\(Int(logicalSize.width))×\(Int(logicalSize.height))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(CeptraTheme.textMuted)
            }

            if appState.connectedMobileDevice != nil {
                Button {
                    appState.disconnectMobileDevice()
                } label: {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .frame(width: 24, height: 22)
                        .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .strokeBorder(CeptraTheme.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Disconnect Live Device")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(CeptraTheme.sidebarBG)
        .overlay(alignment: .top) {
            Rectangle().fill(CeptraTheme.border).frame(height: 1)
        }
    }

    private func hardwareBtn(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3.5) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(CeptraTheme.textSecondary)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 4)
            .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .strokeBorder(CeptraTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func swipeIconBtn(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(CeptraTheme.textSecondary)
                .frame(width: 22, height: 22)
                .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .strokeBorder(CeptraTheme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 1:1 Coordinate-Matched Virtual Mobile Screen (Zero Bounds Drift Across All Resolutions)

private struct CoordinateMatchedVirtualScreen: View {
    let snapshot: MobileScreenSnapshot
    let layout: MobileAspectFitLayout
    let platform: MobilePlatform

    var body: some View {
        let s = CGFloat(max(0.42, layout.scale))
        let w = layout.scaledSize.width
        let h = layout.scaledSize.height

        ZStack(alignment: .topLeading) {
            // Subtle OLED Dark Surface
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.075, blue: 0.125),
                    Color(red: 0.045, green: 0.055, blue: 0.095)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Native Status Bar (Dynamic Island on iOS, Punch-Hole Camera on Android)
            HStack {
                Text("9:41")
                    .font(.system(size: 10.5 * s, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                if platform == .ios {
                    Capsule()
                        .fill(Color.black)
                        .frame(width: 64 * s, height: 17 * s)
                } else {
                    Circle()
                        .fill(Color.black)
                        .frame(width: 11 * s, height: 11 * s)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
                }
                Spacer()
                Text("5G 100%")
                    .font(.system(size: 9.5 * s, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .padding(.horizontal, 16 * s)
            .padding(.top, 9 * s)
            .frame(width: w)

            // Render every leaf control at its EXACT MobileAccessibilityNode bounds!
            ForEach(snapshot.allNodes.filter { $0.normalizedRole != "window" && $0.normalizedRole != "other" }) { node in
                let rect = MobileLocatorSynthesizer.mapNodeBoundsToCanvasRect(node.bounds, layout: layout)
                virtualControlView(for: node, rect: rect, scale: s)
                    .frame(width: max(8, rect.width), height: max(8, rect.height))
                    .offset(x: rect.minX, y: rect.minY)
            }

            // Native Bottom System Chrome
            VStack {
                Spacer()
                if platform == .ios {
                    Capsule()
                        .fill(Color.white.opacity(0.32))
                        .frame(width: 106 * s, height: 4 * s)
                        .padding(.bottom, 8 * s)
                } else {
                    HStack(spacing: 40 * s) {
                        Image(systemName: "triangle.fill")
                            .rotationEffect(.degrees(-90))
                            .font(.system(size: 8.5 * s))
                        Circle()
                            .frame(width: 8.5 * s, height: 8.5 * s)
                        RoundedRectangle(cornerRadius: 2)
                            .frame(width: 8.5 * s, height: 8.5 * s)
                    }
                    .foregroundStyle(Color.white.opacity(0.45))
                    .padding(.bottom, 10 * s)
                }
            }
            .frame(width: w, height: h)
        }
    }

    @ViewBuilder
    private func virtualControlView(for node: MobileAccessibilityNode, rect: CGRect, scale s: CGFloat) -> some View {
        switch node.id {
        case "node-2": // Header "Products"
            HStack {
                Text(node.text ?? "Products")
                    .font(.system(size: 17 * s, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

        case "node-cart": // Cart badge pill
            HStack(spacing: 4 * s) {
                Image(systemName: "cart.fill")
                    .font(.system(size: 9.5 * s))
                Text(node.text ?? "Cart 1")
                    .font(.system(size: 10.5 * s, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(CeptraTheme.success)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CeptraTheme.success.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(CeptraTheme.success.opacity(0.35), lineWidth: 1))

        case "node-3": // Reset App button
            Text(node.text ?? "Reset App")
                .font(.system(size: 10.5 * s, weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7 * s, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7 * s, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )

        case "node-4": // Product Card
            VStack(alignment: .leading, spacing: 6 * s) {
                RoundedRectangle(cornerRadius: 10 * s, style: .continuous)
                    .fill(Color(red: 0.11, green: 0.15, blue: 0.25))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        Image(systemName: "bag")
                            .font(.system(size: min(28 * s, rect.height * 0.24), weight: .light))
                            .foregroundStyle(Color(red: 0.54, green: 0.72, blue: 1.0))
                    }

                HStack {
                    Text(node.text ?? "Sauce Labs Backpack")
                        .font(.system(size: 12.5 * s, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(node.value ?? "$29.99")
                        .font(.system(size: 12 * s, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.52, green: 0.72, blue: 1.0))
                }

                if rect.height > 125 * s {
                    Text("Cross-platform native Mobilewright test target")
                        .font(.system(size: 9.5 * s))
                        .foregroundStyle(Color.white.opacity(0.58))
                        .lineLimit(1)
                }
            }
            .padding(11 * s)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14 * s, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14 * s, style: .continuous)
                    .strokeBorder(Color(red: 0.36, green: 0.56, blue: 0.96).opacity(0.38), lineWidth: 1)
            )

        case "node-5", "node-6": // Username & Password TextFields
            let hasVal = (node.value?.isEmpty == false)
            HStack(spacing: 7 * s) {
                Image(systemName: node.isSecure ? "lock.fill" : "person.fill")
                    .font(.system(size: 10.5 * s))
                    .foregroundStyle(node.isSecure ? CeptraTheme.accentWarm : CeptraTheme.cyan)
                Text(hasVal ? (node.value ?? "") : (node.placeholder ?? node.displayTitle))
                    .font(.system(size: 11 * s, design: node.isSecure ? .monospaced : .default))
                    .foregroundStyle(hasVal ? .white : Color.white.opacity(0.45))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if node.isSecure {
                    Text("secret()")
                        .font(.system(size: 8.5 * s, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.accentWarm)
                        .padding(.horizontal, 5 * s)
                        .padding(.vertical, 2 * s)
                        .background(CeptraTheme.accentWarm.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 11 * s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10 * s, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10 * s, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )

        case "node-7": // Primary CTA Button
            HStack(spacing: 6 * s) {
                Image(systemName: (node.text?.contains("Added") == true) ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 12.5 * s))
                Text(node.text ?? "Add To Cart")
                    .font(.system(size: 12.5 * s, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 11 * s, style: .continuous)
                    .fill(CeptraTheme.success)
            )

        default:
            RoundedRectangle(cornerRadius: 6 * s, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    Text(node.displayTitle)
                        .font(.system(size: 10 * s))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                )
        }
    }
}

// MARK: - State-of-the-Art Adaptive & Resizable Mobilewright Inspector Panel

private enum MobileInspectorDetailTab: String, CaseIterable, Identifiable {
    case locators = "Locators"
    case attributes = "Attributes"
    case recorded = "Recorded"
    var id: String { rawValue }
}

private enum MobileInspectorCompactTab: String, CaseIterable, Identifiable {
    case source = "App Source"
    case element = "Element"
    case recorded = "Recorded"
    var id: String { rawValue }
}

struct MobileElementInspectorPanel: View {
    @EnvironmentObject var appState: AppState
    @Binding var isExpanded: Bool
    let bodyHeight: CGFloat

    @State private var searchQuery: String = ""
    @State private var interactiveOnly: Bool = false
    @State private var collapsedNodeIDs: Set<String> = []
    @State private var detailTab: MobileInspectorDetailTab = .locators
    @State private var compactTab: MobileInspectorCompactTab = .element
    @State private var showingErrorPopover: Bool = false

    private struct FlatTreeRow: Identifiable {
        var id: String { node.id }
        let node: MobileAccessibilityNode
        let depth: Int
        let hasChildren: Bool
    }

    private var totalElementCount: Int {
        appState.mobileSnapshot?.allNodes.filter(\.isVisible).count ?? 0
    }

    private var visibleTreeRows: [FlatTreeRow] {
        guard let roots = appState.mobileSnapshot?.roots else { return [] }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if !query.isEmpty || interactiveOnly {
            // Flat filtered mode so every matching leaf is immediately visible
            let all = roots.flatMap { $0.flattened() }.filter(\.isVisible)
            return all.compactMap { node in
                if interactiveOnly && (node.normalizedRole == "window" || node.normalizedRole == "other") {
                    return nil
                }
                if !query.isEmpty {
                    let hay = [node.type, node.normalizedRole, node.testId, node.identifier, node.label, node.text, node.placeholder]
                        .compactMap { $0?.lowercased() }
                        .joined(separator: " ")
                    guard hay.contains(query) else { return nil }
                }
                return FlatTreeRow(node: node, depth: 0, hasChildren: false)
            }
        }

        var rows: [FlatTreeRow] = []
        func walk(_ node: MobileAccessibilityNode, depth: Int) {
            guard node.isVisible else { return }
            let visibleChildren = node.children.filter(\.isVisible)
            rows.append(FlatTreeRow(node: node, depth: depth, hasChildren: !visibleChildren.isEmpty))
            if !collapsedNodeIDs.contains(node.id) {
                for child in visibleChildren {
                    walk(child, depth: depth + 1)
                }
            }
        }
        for root in roots {
            walk(root, depth: 0)
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeaderStrip

            if isExpanded {
                Divider().overlay(CeptraTheme.border)

                GeometryReader { geo in
                    let isWide = geo.size.width >= 580
                    if isWide {
                        let leftW = max(210, min(320, floor(geo.size.width * 0.42)))
                        let rightW = max(200, geo.size.width - leftW - 1)
                        HStack(spacing: 0) {
                            appSourcePane
                                .frame(width: leftW, height: geo.size.height)
                                .clipped()

                            Rectangle()
                                .fill(CeptraTheme.border)
                                .frame(width: 1, height: geo.size.height)

                            selectedElementPane
                                .frame(width: rightW, height: geo.size.height)
                                .clipped()
                        }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                    } else {
                        VStack(spacing: 0) {
                            compactModeTabBar
                            Divider().overlay(CeptraTheme.border)
                            switch compactTab {
                            case .source:
                                appSourcePane
                            case .element:
                                selectedElementPane
                            case .recorded:
                                recordedStepsListView
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    }
                }
                .frame(height: bodyHeight)
                .background(CeptraTheme.canvasBG.opacity(0.82))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .bottom) {
            Rectangle().fill(CeptraTheme.border).frame(height: 1)
        }
    }

    // MARK: - Top Header Strip (Always Clean & Unclipped)

    private var inspectorHeaderStrip: some View {
        HStack(spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(CeptraTheme.textMuted)
                    Image(systemName: "viewfinder.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.accent)
                    Text("Mobilewright Inspector")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Text("\(totalElementCount) nodes")
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(CeptraTheme.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(CeptraTheme.hoverBG, in: Capsule())

            if !appState.mobileRecordedSteps.isEmpty {
                Text("\(appState.mobileRecordedSteps.count) recorded")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(CeptraTheme.success)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(CeptraTheme.success.opacity(0.14), in: Capsule())
            }

            Spacer(minLength: 4)

            if appState.mobileCaptureAgentRequired {
                Button {
                    appState.openMobileDeviceWizard(initialStep: 3)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: 9.5))
                        Text("Agent setup required")
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(CeptraTheme.warning)
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 3)
                    .background(CeptraTheme.warning.opacity(0.13), in: Capsule())
                    .overlay(Capsule().strokeBorder(CeptraTheme.warning.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(appState.mobileCaptureErrorDetail ?? "Install the Mobilewright on-device agent in Step 3 of the Setup Wizard.")
            } else if let err = appState.mobileLastError {
                HStack(spacing: 4) {
                    Button {
                        showingErrorPopover.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                            Text(err)
                                .font(.system(size: 10.5))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .foregroundStyle(CeptraTheme.failure)
                    }
                    .buttonStyle(.plain)
                    .help("Click to view full error details")
                    .popover(isPresented: $showingErrorPopover, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Mobile Device Error", systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(CeptraTheme.failure)
                                Spacer()
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(err, forType: .string)
                                    appState.showBanner("Copied error details")
                                }
                                .controlSize(.mini)
                            }
                            Text(err)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Retry Capture") {
                                    showingErrorPopover = false
                                    Task { await appState.refreshMobileScreenSnapshot() }
                                }
                                .controlSize(.small)
                                Spacer()
                                Button("Dismiss") {
                                    showingErrorPopover = false
                                    appState.mobileLastError = nil
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(14)
                        .frame(width: 360)
                    }

                    Button {
                        appState.mobileLastError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 240, alignment: .trailing)
            }

            Button {
                appState.generateMobileSampleTestInWorkspace()
            } label: {
                Label("Sample Test", systemImage: "sparkles.rectangle.stack")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(CeptraTheme.success)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(CeptraTheme.success.opacity(0.11), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(CeptraTheme.success.opacity(0.32), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Generate ready-to-run iOS Simulator & Android Emulator sample test + Mobilewright config")

            Button {
                appState.copyMobileConfigSnippet()
            } label: {
                Label("Config", systemImage: "doc.on.doc")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Copy Mobilewright Helper Config Snippet")

            Button {
                appState.openMobileDeviceWizard()
            } label: {
                Label("Setup…", systemImage: "iphone.and.arrow.forward")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(CeptraTheme.accent)
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 3)
                    .background(CeptraTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Open 4-Step Real Device & Simulator Setup Wizard")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(CeptraTheme.sidebarBG)
    }

    private var compactModeTabBar: some View {
        HStack(spacing: 4) {
            ForEach(MobileInspectorCompactTab.allCases) { tab in
                let isSelected = compactTab == tab
                let title = tab == .recorded && !appState.mobileRecordedSteps.isEmpty
                    ? "Recorded (\(appState.mobileRecordedSteps.count))"
                    : tab.rawValue
                Button {
                    compactTab = tab
                } label: {
                    Text(title)
                        .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? CeptraTheme.activeBG : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(CeptraTheme.sidebarBG.opacity(0.6))
    }

    // MARK: - Left Pane: Hierarchical Searchable App Source Tree

    private var appSourcePane: some View {
        VStack(spacing: 0) {
            // Search & Interactive Filter Bar
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(CeptraTheme.textMuted)
                    TextField("Filter tree (ID, text, role)…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(CeptraTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(CeptraTheme.sidebarBG, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))

                Button {
                    interactiveOnly.toggle()
                } label: {
                    Text("Controls")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(interactiveOnly ? CeptraTheme.accent : CeptraTheme.textMuted)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 4)
                        .background(
                            (interactiveOnly ? CeptraTheme.accent.opacity(0.14) : CeptraTheme.sidebarBG),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(interactiveOnly ? CeptraTheme.accent.opacity(0.4) : CeptraTheme.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Show only interactive & content elements (hide layout containers)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CeptraTheme.border.opacity(0.7)).frame(height: 1)
            }

            if visibleTreeRows.isEmpty {
                VStack(spacing: 4) {
                    Text(searchQuery.isEmpty ? "No accessibility elements captured" : "No elements match \"\(searchQuery)\"")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1.5) {
                        ForEach(visibleTreeRows) { row in
                            treeRowView(row)
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    private func treeRowView(_ row: FlatTreeRow) -> some View {
        let node = row.node
        let isSelected = appState.selectedMobileNode?.id == node.id
        let isHovered = appState.mobileHoveredNodeID == node.id
        let isCollapsed = collapsedNodeIDs.contains(node.id)

        return HStack(spacing: 4) {
            if row.depth > 0 {
                Spacer()
                    .frame(width: CGFloat(row.depth) * 12)
            }

            if row.hasChildren {
                Button {
                    if isCollapsed {
                        collapsedNodeIDs.remove(node.id)
                    } else {
                        collapsedNodeIDs.insert(node.id)
                    }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .frame(width: 14, height: 16)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 14)
            }

            Text(shortRoleBadge(node.normalizedRole))
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(roleColor(node.normalizedRole))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(roleColor(node.normalizedRole).opacity(0.14), in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))

            Text(node.displayTitle)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(isSelected ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if node.isLikelyPasswordField {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(CeptraTheme.accentWarm)
            }

            Spacer(minLength: 4)

            if let testId = node.testId, !testId.isEmpty {
                Text("~\(testId)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 92, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? CeptraTheme.activeBG : (isHovered ? CeptraTheme.hoverBG : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isSelected ? CeptraTheme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            appState.mobileSelectedNodeID = node.id
            if compactTab == .source {
                compactTab = .element
            }
        }
        .onHover { inside in
            appState.mobileHoveredNodeID = inside ? node.id : (appState.mobileHoveredNodeID == node.id ? nil : appState.mobileHoveredNodeID)
        }
    }

    // MARK: - Right Pane: State-of-the-Art Selected Element Studio

    private var selectedElementPane: some View {
        VStack(spacing: 0) {
            // Segmented Sub-Tab Header: Locators | Attributes | Recorded
            HStack(spacing: 6) {
                ForEach(MobileInspectorDetailTab.allCases) { tab in
                    let isSelected = detailTab == tab
                    let label = (tab == .recorded && !appState.mobileRecordedSteps.isEmpty)
                        ? "Recorded (\(appState.mobileRecordedSteps.count))"
                        : tab.rawValue
                    Button {
                        detailTab = tab
                    } label: {
                        Text(label)
                            .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isSelected ? CeptraTheme.activeBG : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 4)

                if let node = appState.selectedMobileNode {
                    if node.isLikelyPasswordField {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 9))
                            Text("secret()")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(CeptraTheme.accentWarm)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(CeptraTheme.accentWarm.opacity(0.14), in: Capsule())
                    }

                    Text(node.bounds.formatted)
                        .font(.system(size: 9.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(CeptraTheme.textMuted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(CeptraTheme.sidebarBG.opacity(0.55))
            .overlay(alignment: .bottom) {
                Rectangle().fill(CeptraTheme.border.opacity(0.7)).frame(height: 1)
            }

            switch detailTab {
            case .locators:
                locatorsAndActionsView
            case .attributes:
                attributesTableView
            case .recorded:
                recordedStepsListView
            }
        }
    }

    // MARK: - Tab 1: Ranked Mobilewright Locators + Quick Actions

    private var locatorsAndActionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if let node = appState.selectedMobileNode {
                    let candidates = MobileLocatorSynthesizer.locatorCandidates(
                        for: node,
                        platform: appState.selectedMobilePlatform
                    )

                    // Quick Actions Row + Fill Text
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            quickActionPill("Tap", icon: "hand.tap.fill", accent: CeptraTheme.accent) {
                                appState.performMobileQuickAction(.tap, node: node)
                            }
                            quickActionPill("Long Press", icon: "hand.point.up.left.fill", accent: CeptraTheme.violet) {
                                appState.performMobileQuickAction(.longPress, node: node)
                            }
                            quickActionPill("Swipe ↑", icon: "arrow.up", accent: CeptraTheme.accentWarm) {
                                appState.performMobileQuickAction(.swipeUp)
                            }
                            quickActionPill("Swipe ↓", icon: "arrow.down", accent: CeptraTheme.accentWarm) {
                                appState.performMobileQuickAction(.swipeDown)
                            }
                            quickActionPill("See", icon: "eye.fill", accent: CeptraTheme.success) {
                                appState.performMobileQuickAction(.see, node: node)
                            }
                            quickActionPill("See El", icon: "checkmark.square", accent: CeptraTheme.cyan) {
                                appState.performMobileQuickAction(.seeElement, node: node)
                            }
                            Spacer(minLength: 0)
                        }

                        // Inline Fill Field Bar (highlights automatically when a text/password input is selected)
                        HStack(spacing: 6) {
                            TextField(
                                node.isLikelyPasswordField ? "Password (auto-wrapped in secret())…" : "Text to fill…",
                                text: $appState.mobileFillInputText
                            )
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4.5)
                            .background(CeptraTheme.sidebarBG, in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                    .strokeBorder(node.isTextField ? CeptraTheme.cyan.opacity(0.6) : CeptraTheme.border, lineWidth: 1)
                            )

                            quickActionPill("Fill Field", icon: "keyboard", accent: CeptraTheme.cyan) {
                                appState.performMobileQuickAction(.fillField, node: node)
                            }
                        }
                    }

                    // Ranked Mobilewright "Find By" Locator Table
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("RANKED MOBILEWRIGHT LOCATORS")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(CeptraTheme.textMuted)
                            Spacer()
                            Text("Zero CSS / XPath")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(CeptraTheme.success.opacity(0.85))
                        }

                        ForEach(candidates) { cand in
                            locatorCandidateRow(cand)
                        }
                    }
                } else {
                    Text("Click any element on the phone screen or App Source tree to inspect its ranked Mobilewright locators and run quick actions.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                }
            }
            .padding(10)
        }
    }

    private func locatorCandidateRow(_ cand: MobileLocatorCandidate) -> some View {
        let badgeColor: Color = {
            switch cand.reliability {
            case .recommended: return CeptraTheme.success
            case .good: return CeptraTheme.cyan
            case .fallback: return CeptraTheme.accentWarm
            }
        }()

        return HStack(spacing: 6) {
            Text(cand.reliability.rawValue)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(badgeColor)
                .frame(width: 34)
                .padding(.vertical, 2)
                .background(badgeColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(cand.locator)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(cand.strategy)
                    .font(.system(size: 9.5))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cand.locator, forType: .string)
                appState.showBanner("Copied \(cand.locator)")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(CeptraTheme.hoverBG.opacity(0.8), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Copy Locator String")

            Button {
                appState.insertMobileCodeSnippet(cand.tapSnippet, locator: cand.locator, action: .tap)
            } label: {
                Text("+ Step")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CeptraTheme.accent)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(CeptraTheme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Insert `\(cand.tapSnippet)` into active editor")

            Button {
                appState.insertMobileCodeSnippet(cand.assertSnippet, locator: cand.locator, action: .see)
            } label: {
                Text("+ See")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CeptraTheme.success)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(CeptraTheme.success.opacity(0.13), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Insert `\(cand.assertSnippet)` into active editor")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(CeptraTheme.sidebarBG.opacity(0.85), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(cand.reliability == .recommended ? CeptraTheme.success.opacity(0.32) : CeptraTheme.border, lineWidth: 1)
        )
    }

    // MARK: - Tab 2: Accessibility Attributes Grid (Xcode Accessibility Inspector Style)

    private var attributesTableView: some View {
        ScrollView {
            if let node = appState.selectedMobileNode {
                let pairs: [(String, String)] = [
                    ("type", node.type),
                    ("role", node.normalizedRole),
                    ("testId", node.testId ?? "—"),
                    ("identifier", node.identifier ?? "—"),
                    ("label", node.label ?? "—"),
                    ("text", node.text ?? "—"),
                    ("value", node.value ?? "—"),
                    ("placeholder", node.placeholder ?? "—"),
                    ("bounds", node.bounds.formatted),
                    ("visible / enabled", "\(node.isVisible ? "true" : "false") / \(node.isEnabled ? "true" : "false")"),
                    ("secure (password)", node.isLikelyPasswordField ? "true (uses secret())" : "false")
                ]

                VStack(spacing: 3) {
                    ForEach(pairs, id: \.0) { key, val in
                        HStack(spacing: 8) {
                            Text(key)
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textMuted)
                                .frame(width: 112, alignment: .leading)
                                .lineLimit(1)

                            Text(val)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(val == "—" ? CeptraTheme.textMuted.opacity(0.5) : CeptraTheme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                            if val != "—" {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(val, forType: .string)
                                    appState.showBanner("Copied \(key)")
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(CeptraTheme.textMuted)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(CeptraTheme.sidebarBG.opacity(0.65), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                    }
                }
                .padding(10)
            } else {
                Text("Select an element to inspect its native accessibility attributes.")
                    .font(.system(size: 11))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .padding(14)
            }
        }
    }

    // MARK: - Tab 3: Internally Scrolling Recorded Steps (Zero Vertical Stretch)

    private var recordedStepsListView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("\(appState.mobileRecordedSteps.count) recorded step(s)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(CeptraTheme.textSecondary)
                Spacer()
                Button("Undo") {
                    appState.undoLastMobileRecordedStep()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(appState.mobileRecordedSteps.isEmpty ? CeptraTheme.textMuted.opacity(0.45) : CeptraTheme.accentWarm)
                .disabled(appState.mobileRecordedSteps.isEmpty)

                Button("Copy All") {
                    appState.copyAllMobileRecordedSteps()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(appState.mobileRecordedSteps.isEmpty ? CeptraTheme.textMuted.opacity(0.45) : CeptraTheme.accent)
                .disabled(appState.mobileRecordedSteps.isEmpty)

                Button("Clear") {
                    appState.clearMobileRecordedSteps()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(appState.mobileRecordedSteps.isEmpty ? CeptraTheme.textMuted.opacity(0.45) : CeptraTheme.failure)
                .disabled(appState.mobileRecordedSteps.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CeptraTheme.border.opacity(0.6)).frame(height: 1)
            }

            if appState.mobileRecordedSteps.isEmpty {
                VStack(spacing: 4) {
                    Text("No steps recorded yet")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    Text("Click Tap, Fill, See, or double-click any control on the phone to record I.* steps.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(appState.mobileRecordedSteps.enumerated()), id: \.element.id) { idx, step in
                            HStack(spacing: 8) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(CeptraTheme.textMuted)
                                    .frame(width: 18, alignment: .trailing)
                                Text(step.codeLine)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(CeptraTheme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(CeptraTheme.sidebarBG.opacity(0.7), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    // MARK: - Small UI Helpers

    private func quickActionPill(_ title: String, icon: String, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .strokeBorder(accent.opacity(0.32), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func shortRoleBadge(_ role: String) -> String {
        switch role {
        case "window": return "APP"
        case "header": return "HDR"
        case "button": return "BTN"
        case "textfield": return "INP"
        case "text": return "TXT"
        case "image": return "IMG"
        case "switch": return "SW"
        default: return "VIEW"
        }
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "window": return CeptraTheme.textMuted
        case "header": return CeptraTheme.accentWarm
        case "button": return CeptraTheme.accent
        case "textfield": return CeptraTheme.cyan
        case "text": return CeptraTheme.success
        case "switch": return CeptraTheme.accentWarm
        default: return CeptraTheme.violet
        }
    }
}
