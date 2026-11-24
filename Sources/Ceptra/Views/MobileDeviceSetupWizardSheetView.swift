import CeptraCore
import SwiftUI

struct MobileDeviceSetupWizardSheetView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var deviceSearchQuery: String = ""
    @State private var simulatorFamilyFilter: String = "iPhone"
    @State private var bootingSimulatorID: String? = nil
    @State private var hoveredTargetKind: MobileWizardTargetKind? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CeptraTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect Mobile Device")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    Text("Step-by-step Mobilewright setup for real iOS/Android devices & simulators")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.textSecondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(CeptraTheme.hoverBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(CeptraTheme.sidebarBG)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CeptraTheme.border).frame(height: 1)
            }

            // 4-Step Stepper
            HStack(spacing: 8) {
                stepPill(1, title: "1. Platform")
                stepPill(2, title: "2. Doctor")
                stepPill(3, title: "3. Pair & Agent")
                stepPill(4, title: "4. Target App")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(CeptraTheme.canvasBG)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CeptraTheme.border).frame(height: 1)
            }

            // Step Body
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch appState.mobileWizardStep {
                    case 1:
                        stepOnePlatform
                    case 2:
                        stepTwoDoctor
                    case 3:
                        stepThreePairAndAgent
                    default:
                        stepFourTargetApp
                    }

                    if let err = appState.mobileLastError {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(CeptraTheme.failure)
                            Text(err)
                                .font(.system(size: 11.5))
                                .foregroundStyle(CeptraTheme.failure)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CeptraTheme.failure.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CeptraTheme.panelBG)

            // Footer Navigation
            HStack {
                if appState.mobileWizardStep > 1 {
                    Button("← Back") {
                        appState.mobileWizardStep -= 1
                        appState.mobileLastError = nil
                    }
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if appState.mobileWizardStep < 4 {
                    Button("Continue →") {
                        advanceToStep(appState.mobileWizardStep + 1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CeptraTheme.accent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Launch Live Mirror") {
                        appState.connectSelectedMobileDeviceAndLaunchStudio()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CeptraTheme.success)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(CeptraTheme.sidebarBG)
            .overlay(alignment: .top) {
                Rectangle().fill(CeptraTheme.border).frame(height: 1)
            }
        }
        .frame(width: 632, height: 548)
        .onAppear {
            appState.startMobileUSBMonitorIfNeeded()
            if appState.mobileDevices.isEmpty {
                Task { await appState.refreshMobileDevices() }
            }
        }
        .onDisappear {
            if !appState.isMobileStudioVisible {
                appState.stopMobileUSBMonitor()
            }
        }
    }

    private func advanceToStep(_ next: Int) {
        appState.mobileWizardStep = next
        appState.mobileLastError = nil
        Task {
            if next == 2 {
                await appState.runMobileDoctorInWizard()
            } else if next == 3 {
                await appState.refreshMobileDevices()
            } else if next == 4 {
                await appState.loadInstalledAppsForSelectedDevice()
            }
        }
    }

    private func stepPill(_ step: Int, title: String) -> some View {
        let isCurrent = appState.mobileWizardStep == step
        let isDone = appState.mobileWizardStep > step
        return Button {
            appState.mobileWizardStep = step
            appState.mobileLastError = nil
        } label: {
            HStack(spacing: 5) {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(CeptraTheme.success)
                }
                Text(title)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(isCurrent ? CeptraTheme.textPrimary : (isDone ? CeptraTheme.success : CeptraTheme.textSecondary))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isCurrent ? CeptraTheme.panelBG : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isCurrent ? CeptraTheme.accent : CeptraTheme.border.opacity(isDone ? 0.8 : 0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 1: Platform

    private var stepOnePlatform: some View {
        let pluggedReal = appState.mobileDevices.first(where: { $0.type == .real && $0.state.isReady })
        let iosSims = appState.mobileDevices.filter { $0.platform == .ios && $0.type == .simulator }
        let bootedIOSSims = iosSims.filter { $0.state.isReady }.count
        let androidEmus = appState.mobileDevices.filter { $0.platform == .android && $0.type == .emulator }
        let bootedEmus = androidEmus.filter { $0.state.isReady }.count
        let realAndroids = appState.mobileDevices.filter { $0.platform == .android && $0.type == .real }
        let readyAndroids = realAndroids.filter { $0.state.isReady }.count
        let unauthAndroids = realAndroids.filter { $0.state == .unauthorized }.count
        let realIOSCount = appState.mobileDevices.filter { $0.platform == .ios && $0.type == .real && $0.state.isReady }.count

        return VStack(alignment: .leading, spacing: 14) {
            if let realDevice = pluggedReal {
                HStack(spacing: 10) {
                    Image(systemName: realDevice.platform == .ios ? "iphone.radiowaves.left.and.right" : "smartphone")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CeptraTheme.success)
                        .frame(width: 30, height: 30)
                        .background(CeptraTheme.success.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(realDevice.name)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(CeptraTheme.textPrimary)
                                .lineLimit(1)
                            Text("USB LIVE")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(CeptraTheme.success)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(CeptraTheme.success.opacity(0.15), in: Capsule())
                        }
                        Text(appState.isMobileAutoSetupRunning
                             ? (appState.mobileAutoSetupStatusText.isEmpty ? "Running auto-setup…" : appState.mobileAutoSetupStatusText)
                             : "Connected via USB · Allow 1-click auto-setup or pick a target below")
                            .font(.system(size: 10.5))
                            .foregroundStyle(appState.isMobileAutoSetupRunning ? CeptraTheme.success : CeptraTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    if appState.isMobileAutoSetupRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await appState.allowAndAutoSetupRealDevice(realDevice) }
                        } label: {
                            Label("Auto-Setup", systemImage: "checkmark.shield.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(CeptraTheme.success)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(CeptraTheme.success.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(CeptraTheme.success.opacity(0.36), lineWidth: 1.1)
                )
            }

            // Category 1: Virtual Devices (Simulators & Emulators)
            VStack(alignment: .leading, spacing: 8) {
                targetCategoryHeader(
                    icon: "desktopcomputer",
                    title: "VIRTUAL DEVICES",
                    subtitle: "Zero cables · Zero signing"
                )

                HStack(spacing: 10) {
                    targetDeviceCard(
                        kind: .iosSimulator,
                        icon: "macbook.and.iphone",
                        title: "iOS Simulator",
                        description: "Xcode iPhones & iPads on this Mac. Instant live mirror.",
                        badgeText: bootedIOSSims > 0
                            ? "\(bootedIOSSims) booted"
                            : (iosSims.isEmpty ? "Free · Xcode" : "\(iosSims.count) ready"),
                        badgeColor: CeptraTheme.success,
                        tags: ["Free", "Zero Signing"]
                    )

                    targetDeviceCard(
                        kind: .androidEmulator,
                        icon: "cpu",
                        title: "Android Emulator",
                        description: "Local Android Virtual Devices via Android Studio SDK.",
                        badgeText: bootedEmus > 0 ? "\(bootedEmus) running" : "Android SDK",
                        badgeColor: bootedEmus > 0 ? CeptraTheme.success : CeptraTheme.textMuted,
                        tags: ["Free", "AVD"]
                    )
                }
            }

            // Category 2: Physical Handsets (USB / Wi-Fi)
            VStack(alignment: .leading, spacing: 8) {
                targetCategoryHeader(
                    icon: "cable.connector",
                    title: "PHYSICAL DEVICES",
                    subtitle: "Real hardware via USB / Wi-Fi"
                )

                HStack(spacing: 10) {
                    targetDeviceCard(
                        kind: .androidReal,
                        icon: "smartphone",
                        title: "Real Android",
                        description: "USB Debugging for Native, Flutter & React Native apps.",
                        badgeText: readyAndroids > 0
                            ? "\(readyAndroids) USB ready"
                            : (unauthAndroids > 0 ? "Tap Allow" : "Fastest USB"),
                        badgeColor: unauthAndroids > 0 && readyAndroids == 0 ? CeptraTheme.warning : CeptraTheme.success,
                        tags: ["Free", "USB / Wi-Fi"]
                    )

                    targetDeviceCard(
                        kind: .iosReal,
                        icon: "iphone.radiowaves.left.and.right",
                        title: "Real iPhone / iPad",
                        description: "USB + Developer Mode. Needs Apple Wildcard (*) profile.",
                        badgeText: realIOSCount > 0 ? "\(realIOSCount) USB" : "Wildcard * ($99)",
                        badgeColor: realIOSCount > 0 ? CeptraTheme.accent : CeptraTheme.warning,
                        tags: ["USB", "Wildcard *"]
                    )
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10.5))
                    .foregroundStyle(CeptraTheme.textMuted)
                Text("100% local via mobilecli on 127.0.0.1 · Telemetry disabled · Double-click any card to continue")
                    .font(.system(size: 10.5))
                    .foregroundStyle(CeptraTheme.textMuted)
            }
            .padding(.top, 2)
        }
    }

    private func targetCategoryHeader(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CeptraTheme.textMuted)
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(CeptraTheme.textSecondary)
            Spacer()
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(CeptraTheme.textMuted)
        }
    }

    private func targetDeviceCard(
        kind: MobileWizardTargetKind,
        icon: String,
        title: String,
        description: String,
        badgeText: String,
        badgeColor: Color,
        tags: [String]
    ) -> some View {
        let isSelected = appState.mobileWizardTargetKind == kind
        let isHovered = hoveredTargetKind == kind

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? CeptraTheme.accent : CeptraTheme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(
                        (isSelected ? CeptraTheme.accent.opacity(0.15) : CeptraTheme.panelBG),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )

                Spacer(minLength: 4)

                Text(badgeText)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2.5)
                    .background(badgeColor.opacity(0.13), in: Capsule())
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                        .lineLimit(1)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(CeptraTheme.accent)
                    }
                }
                Text(description)
                    .font(.system(size: 10.8))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
        .background(
            isSelected ? CeptraTheme.activeBG : (isHovered ? CeptraTheme.hoverBG.opacity(0.55) : CeptraTheme.canvasBG),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? CeptraTheme.accent : (isHovered ? CeptraTheme.textMuted.opacity(0.45) : CeptraTheme.border),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            hoveredTargetKind = hovering ? kind : (hoveredTargetKind == kind ? nil : hoveredTargetKind)
        }
        .onTapGesture {
            appState.mobileWizardTargetKind = kind
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                appState.mobileWizardTargetKind = kind
                advanceToStep(2)
            }
        )
    }

    // MARK: - Step 2: Doctor Check

    private var stepTwoDoctor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Environment & Prerequisites (`mobilewright doctor`)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textPrimary)
                Spacer()
                Button {
                    Task { await appState.runMobileDoctorInWizard() }
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .disabled(appState.isMobileDoctorRunning)
            }

            if appState.isMobileDoctorRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking Node.js, mobilecli, Xcode & ADB…")
                        .font(.system(size: 12))
                        .foregroundStyle(CeptraTheme.textSecondary)
                }
                .padding(.vertical, 24)
            } else if let report = appState.mobileDoctorReport {
                VStack(spacing: 6) {
                    ForEach(report.checks) { check in
                        HStack(spacing: 10) {
                            Image(systemName: icon(for: check.status))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(color(for: check.status))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(CeptraTheme.textPrimary)
                                Text(check.detail)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(CeptraTheme.textSecondary)
                                    .lineLimit(2)
                                if check.status != .ok, let cmd = check.remediationCommand {
                                    Text(cmd)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(CeptraTheme.textMuted)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if check.status != .ok, let cmd = check.remediationCommand {
                                if appState.mobileWizardTargetKind == .androidReal && cmd.contains("android-studio") {
                                    Text("Optional for USB")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(CeptraTheme.textMuted)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(CeptraTheme.hoverBG, in: Capsule())
                                } else {
                                    Button(setupButtonTitle(for: check, command: cmd)) {
                                        appState.installMobilePrerequisiteFromWizard(check: check)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(CeptraTheme.success)
                                    .controlSize(.small)
                                    .disabled(appState.isMobilePrerequisiteInstalling || appState.isRunning)
                                }
                            }
                        }
                        .padding(9)
                        .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
                    }
                }

                if appState.isMobilePrerequisiteInstalling {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Installing prerequisite…")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(CeptraTheme.textPrimary)
                            Text(appState.mobilePrerequisiteStatusLine.isEmpty ? "Working…" : appState.mobilePrerequisiteStatusLine)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(CeptraTheme.success)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("View Logs") {
                            appState.isConsoleVisible = true
                        }
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(CeptraTheme.success.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(CeptraTheme.success.opacity(0.32), lineWidth: 1)
                    )
                }
            }
        }
    }

    private func setupButtonTitle(for check: MobileDoctorCheckItem, command: String) -> String {
        if command.contains("@codeceptjs/mobilewright") || check.name.lowercased().contains("mobilecli") {
            return "Install Mobilewright"
        }
        if command.contains("android-platform-tools") {
            return "Install ADB"
        }
        return "Quick Setup"
    }

    // MARK: - Step 3: Pair & Agent

    private var stepThreePairAndAgent: some View {
        let targetKind = appState.mobileWizardTargetKind
        let query = deviceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matchingDevices = appState.mobileDevices.filter { dev in
            guard dev.platform == targetKind.platform else { return false }
            switch targetKind {
            case .iosReal, .androidReal:
                guard dev.type == .real else { return false }
            case .iosSimulator:
                guard dev.type == .simulator else { return false }
                if simulatorFamilyFilter == "iPhone" && !dev.name.lowercased().contains("iphone") {
                    return false
                }
                if simulatorFamilyFilter == "iPad" && !dev.name.lowercased().contains("ipad") {
                    return false
                }
            case .androidEmulator:
                guard dev.type == .emulator else { return false }
            }
            if !query.isEmpty {
                let hay = "\(dev.name) \(dev.osVersion ?? "") \(dev.id)".lowercased()
                return hay.contains(query)
            }
            return true
        }
        let selectedDev = appState.mobileDevices.first(where: { $0.id == appState.selectedMobileDeviceID })

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Select Device & Verify On-Device Agent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textPrimary)
                Spacer()
                Button {
                    Task { await appState.refreshMobileDevices() }
                } label: {
                    Label("Refresh Devices", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .disabled(appState.isMobileDevicesRefreshing)
            }

            if targetKind == .iosSimulator {
                let allSimulators = appState.mobileDevices.filter { $0.platform == .ios && $0.type == .simulator }
                let iphoneCount = allSimulators.filter { $0.name.lowercased().contains("iphone") }.count
                let ipadCount = allSimulators.filter { $0.name.lowercased().contains("ipad") }.count

                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10.5))
                            .foregroundStyle(CeptraTheme.textMuted)
                        TextField("Filter simulators (e.g. iPhone 17 Pro, 26.5)…", text: $deviceSearchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                        if !deviceSearchQuery.isEmpty {
                            Button {
                                deviceSearchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(CeptraTheme.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))

                    HStack(spacing: 2) {
                        ForEach([
                            ("iPhone", iphoneCount),
                            ("iPad", ipadCount),
                            ("All", allSimulators.count),
                        ], id: \.0) { fam, count in
                            let active = simulatorFamilyFilter == fam
                            Button {
                                simulatorFamilyFilter = fam
                            } label: {
                                Text(count > 0 ? "\(fam) (\(count))" : fam)
                                    .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                                    .foregroundStyle(active ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4.5)
                                    .background(active ? CeptraTheme.activeBG : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6.5, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
                }
            }

            if appState.mobileWizardTargetKind == .androidReal {
                Text("Plug in your Android phone via USB, enable **Developer Options → USB Debugging**, and tap **Allow**.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CeptraTheme.textSecondary)
            } else if appState.mobileWizardTargetKind == .iosReal {
                Text("Plug in your iPhone/iPad via USB, tap **Trust This Computer**, enable **Developer Mode**, and select your Apple `.mobileprovision` profile.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CeptraTheme.textSecondary)
            }

            if matchingDevices.isEmpty {
                VStack(spacing: 6) {
                    Text(query.isEmpty
                         ? "No \(targetKind.title) devices detected yet."
                         : "No simulators match \"\(deviceSearchQuery)\".")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    Text(targetKind == .iosSimulator
                         ? "Switch filter to All or click Refresh Devices."
                         : "Plug in a device via USB (or boot an emulator) and click Refresh Devices, or continue with Interactive Preview.")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(matchingDevices) { dev in
                            let isSel = appState.selectedMobileDeviceID == dev.id
                            let isBootingThis = bootingSimulatorID == dev.id
                            Button {
                                appState.selectedMobileDeviceID = dev.id
                                appState.mobileAgentStatusReady = false
                                if dev.platform == .ios && dev.type == .real {
                                    appState.refreshDiscoveredProvisioningProfiles(forDeviceID: dev.id)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(dev.state.isReady ? CeptraTheme.success : CeptraTheme.textMuted)
                                        .frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(dev.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(CeptraTheme.textPrimary)
                                        Text("\(dev.displaySubtitle) · \(dev.id)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(CeptraTheme.textSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if dev.type == .simulator && !dev.state.isReady {
                                        Button {
                                            appState.selectedMobileDeviceID = dev.id
                                            bootingSimulatorID = dev.id
                                            Task {
                                                await appState.bootSelectedXcodeSimulator()
                                                bootingSimulatorID = nil
                                            }
                                        } label: {
                                            if isBootingThis {
                                                HStack(spacing: 4) {
                                                    ProgressView().controlSize(.mini)
                                                    Text("Booting…")
                                                }
                                            } else {
                                                Text("Boot")
                                            }
                                        }
                                        .controlSize(.small)
                                        .disabled(bootingSimulatorID != nil)
                                    } else {
                                        Text(dev.state.rawValue.capitalized)
                                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                            .foregroundStyle(dev.state.isReady ? CeptraTheme.success : CeptraTheme.textMuted)
                                    }
                                }
                                .padding(9)
                                .background(isSel ? CeptraTheme.activeBG : CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isSel ? CeptraTheme.accent : CeptraTheme.border, lineWidth: isSel ? 1.3 : 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: 235)
            }

            if appState.mobileWizardTargetKind == .iosReal {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Apple Provisioning Profile (`.mobileprovision`)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                        Spacer()
                        Button("Refresh") {
                            appState.refreshDiscoveredProvisioningProfiles()
                        }
                        .controlSize(.mini)
                    }

                    HStack(spacing: 8) {
                        TextField("Path to .mobileprovision file…", text: $appState.mobileProvisioningProfilePath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Button("Browse…") {
                            appState.browseProvisioningProfile()
                        }
                    }

                    if !appState.mobileDiscoveredProfiles.isEmpty {
                        let targetUDID = appState.selectedMobileDeviceID ?? ""
                        let selectedProfile = appState.mobileDiscoveredProfiles.first(where: { $0.path == appState.mobileProvisioningProfilePath })
                        Picker("Detected Profiles", selection: $appState.mobileProvisioningProfilePath) {
                            ForEach(appState.mobileDiscoveredProfiles) { profile in
                                let matches = !targetUDID.isEmpty && profile.supports(deviceUDID: targetUDID)
                                let prefix = matches ? (profile.isWildcardProfile ? "✓ Wildcard · " : "⚠ Explicit · ") : (profile.isExpired ? "Expired · " : "")
                                Text("\(prefix)\(profile.displayLabel)").tag(profile.path)
                            }
                        }
                        .font(.system(size: 11))

                        if let sel = selectedProfile, !sel.isWildcardProfile {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Explicit App ID profile detected (`\(sel.applicationIdentifier ?? sel.name)`).")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(CeptraTheme.warning)
                                Text("`mobilecli` requires a **Wildcard (`*`)** iOS Development profile (paid Apple Developer Program, $99/yr) to re-sign its iOS runner on a physical iPhone. For **100% free** live testing with zero signing, use **iOS Simulator** or a **real Android phone**.")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(CeptraTheme.textSecondary)
                                Button("Use iOS Simulator Instead (Free, Zero Signing)") {
                                    appState.showingMobileDeviceWizard = false
                                    appState.isMobileStudioVisible = true
                                    Task { await appState.switchToAvailableXcodeSimulator() }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(CeptraTheme.success)
                                .controlSize(.small)
                                .padding(.top, 2)
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(CeptraTheme.warning.opacity(0.4), lineWidth: 1))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Wildcard (`*`) `.mobileprovision` required for real iPhone/iPad:")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(CeptraTheme.warning)
                            Text("1. In Apple Developer Portal (paid Apple Developer Program, $99/yr), create a Wildcard App ID (`*`) and iOS Development profile including your device.\n2. Download & double-click the `.mobileprovision` file, then click Refresh.\n• Or test **100% free right now** with Xcode iOS Simulator or a real Android phone.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(CeptraTheme.textSecondary)
                            HStack(spacing: 8) {
                                Button("Use iOS Simulator (Free, Zero Signing)") {
                                    appState.showingMobileDeviceWizard = false
                                    appState.isMobileStudioVisible = true
                                    Task { await appState.switchToAvailableXcodeSimulator() }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(CeptraTheme.success)
                                .controlSize(.small)
                                Button("Open Xcode") {
                                    appState.openXcodeForSigning()
                                }
                                .controlSize(.small)
                            }
                            .padding(.top, 2)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(CeptraTheme.warning.opacity(0.35), lineWidth: 1))
                    }
                }
            }

            if let dev = selectedDev, dev.state.isReady {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mobilewright On-Device Agent")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                        Text("mobilecli agent install --device \(dev.id)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if appState.mobileAgentStatusReady {
                        Label("Verified", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(CeptraTheme.success)
                    } else {
                        Button {
                            Task { await appState.installAgentOnSelectedDevice() }
                        } label: {
                            if appState.isMobileAgentInstalling {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Install Agent")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(CeptraTheme.accent)
                        .disabled(appState.isMobileAgentInstalling)
                    }
                }
                .padding(10)
                .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
            }
        }
    }

    // MARK: - Step 4: Target App & Config

    private var stepFourTargetApp: some View {
        let selectedDev = appState.mobileDevices.first(where: { $0.id == appState.selectedMobileDeviceID })
        let snippet = MobileLocatorSynthesizer.generateHelperConfigSnippet(
            platform: selectedDev?.platform ?? appState.mobileWizardTargetKind.platform,
            appId: appState.selectedMobileAppId,
            deviceName: selectedDev?.name,
            deviceId: selectedDev?.type == .real ? selectedDev?.id : nil
        )

        return VStack(alignment: .leading, spacing: 12) {
            Text("Target App & `codecept.conf.js` Snippet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CeptraTheme.textPrimary)

            VStack(alignment: .leading, spacing: 5) {
                Text("App Bundle ID (iOS) or Package Name (Android)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CeptraTheme.textSecondary)
                TextField("e.g. com.saucelabs.mydemoapp.rn", text: $appState.selectedMobileAppId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                if !appState.mobileInstalledApps.isEmpty {
                    Picker("Detected Apps", selection: $appState.selectedMobileAppId) {
                        ForEach(appState.mobileInstalledApps) { item in
                            Text("\(item.name) (\(item.bundleId))").tag(item.bundleId)
                        }
                    }
                    .font(.system(size: 11.5))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Mobilewright Helper Config")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    Spacer()
                    Button("Generate Sample Test & Config") {
                        appState.generateMobileSampleTestInWorkspace()
                    }
                    .controlSize(.small)
                    Button("Copy Snippet") {
                        appState.copyMobileConfigSnippet()
                    }
                    .controlSize(.small)
                }
                Text(snippet)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
            }
        }
    }

    private func icon(for status: MobileDoctorStatus) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private func color(for status: MobileDoctorStatus) -> Color {
        switch status {
        case .ok: return CeptraTheme.success
        case .warning: return CeptraTheme.warning
        case .error: return CeptraTheme.failure
        }
    }
}
