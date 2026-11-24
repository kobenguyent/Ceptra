import AppKit
import CeptraCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppState {
    var activeMobileResolutionPreset: MobileResolutionPreset {
        MobileResolutionPreset.preset(id: settings.mobileResolutionPresetID)
    }

    var mobilePhoneDockSide: MobilePhoneDockSide {
        settings.mobilePhoneDockSide
    }

    var selectedMobileNode: MobileAccessibilityNode? {
        guard let snap = mobileSnapshot else { return nil }
        if let id = mobileSelectedNodeID, let found = snap.allNodes.first(where: { $0.id == id }) {
            return found
        }
        return snap.allNodes.first(where: { $0.testId == "Add To Cart button" && $0.isVisible })
            ?? snap.allNodes.first(where: { $0.normalizedRole == "button" && $0.isVisible })
            ?? snap.allNodes.first(where: { $0.normalizedRole != "window" && $0.normalizedRole != "other" && $0.isVisible })
            ?? snap.allNodes.first(where: { $0.isVisible })
    }

    var selectedMobilePlatform: MobilePlatform {
        connectedMobileDevice?.platform ?? activeMobileResolutionPreset.platform
    }

    func openMobileDeviceWizard(initialStep: Int = 1) {
        mobileWizardStep = initialStep
        mobileLastError = nil
        showingMobileDeviceWizard = true
        refreshDiscoveredProvisioningProfiles()
        Task { [weak self] in
            if initialStep == 2 {
                await self?.runMobileDoctorInWizard()
            } else {
                await self?.refreshMobileDevices()
            }
        }
    }

    func refreshDiscoveredProvisioningProfiles(forDeviceID deviceID: String? = nil) {
        let profiles = MobileCLIDeviceBridge.MobileProvisioningProfileInspector.discoverInstalledProfiles()
        mobileDiscoveredProfiles = profiles
        mobileDiscoveredProvisioningProfiles = profiles.map { URL(fileURLWithPath: $0.path) }

        let targetUDID = deviceID ?? selectedMobileDeviceID ?? connectedMobileDevice?.id
        if let targetUDID,
           let best = MobileCLIDeviceBridge.MobileProvisioningProfileInspector.bestMatchingProfile(for: targetUDID, in: profiles) {
            mobileProvisioningProfilePath = best.path
        } else if mobileProvisioningProfilePath.isEmpty, let first = profiles.first(where: { !$0.isExpired }) ?? profiles.first {
            mobileProvisioningProfilePath = first.path
        }
    }

    func startMobileUSBMonitorIfNeeded() {
        guard mobileUSBMonitorTask == nil else { return }
        mobileUSBMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                if !self.isMobileStudioVisible && !self.showingMobileDeviceWizard {
                    break
                }
                if !self.isMobileAutoSetupRunning && !self.isMobileAgentInstalling && !self.isMobilePrerequisiteInstalling {
                    await self.pollForPluggedInRealDevice()
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
            await MainActor.run { [weak self] in
                self?.mobileUSBMonitorTask = nil
            }
        }
    }

    func stopMobileUSBMonitor() {
        mobileUSBMonitorTask?.cancel()
        mobileUSBMonitorTask = nil
    }

    private func pollForPluggedInRealDevice() async {
        let root = workspace?.rootURL
        guard let list = try? await mobileDeviceBridge.listDevices(workspaceRoot: root) else { return }
        mobileDevices = list

        // If the currently prompted device was unplugged, clear the prompt cleanly
        if let pending = pendingPluggedInDevicePrompt,
           !list.contains(where: { $0.id == pending.id && ($0.state.isReady || $0.state == .unauthorized) }) {
            pendingPluggedInDevicePrompt = nil
        }

        // Look for any plugged-in physical USB phone ONLY when disconnected (never interrupt an active Simulator/live session)
        guard connectedMobileDevice == nil else {
            pendingPluggedInDevicePrompt = nil
            return
        }
        let pluggedRealDevices = list.filter { $0.type == .real && ($0.state.isReady || $0.state == .unauthorized) }
        guard let candidate = pluggedRealDevices.first(where: { !dismissedPluggedInDeviceIDs.contains($0.id) }) else {
            return
        }

        if pendingPluggedInDevicePrompt?.id != candidate.id || pendingPluggedInDevicePrompt?.state != candidate.state {
            if candidate.platform == .ios {
                refreshDiscoveredProvisioningProfiles(forDeviceID: candidate.id)
            }
            pendingPluggedInDevicePrompt = candidate
        }
    }

    func dismissPluggedInDevicePrompt(_ device: MobileDeviceDescriptor) {
        dismissedPluggedInDeviceIDs.insert(device.id)
        if pendingPluggedInDevicePrompt?.id == device.id {
            pendingPluggedInDevicePrompt = nil
        }
    }

    /// Permission-approved 1-click Auto-Setup for a plugged-in real iPhone or Android phone:
    /// checks mobilecli -> auto-matches UDID .mobileprovision (iOS) -> installs agent -> connects live mirror.
    func allowAndAutoSetupRealDevice(_ device: MobileDeviceDescriptor) async {
        guard !isMobileAutoSetupRunning else { return }
        isMobileAutoSetupRunning = true
        mobileAutoSetupStatusText = "Preparing \(device.name)…"
        mobileLastError = nil
        mobileCaptureErrorDetail = nil
        mobileCaptureAgentRequired = false
        selectedMobileDeviceID = device.id
        mobileWizardTargetKind = device.platform == .ios ? .iosReal : .androidReal

        let root = workspace?.rootURL

        // 1. Ensure mobilecli is available in workspace (installs automatically if missing)
        if MobileCLIDeviceBridge.resolveMobileCLIBinary(workspaceRoot: root) == nil {
            mobileAutoSetupStatusText = "Installing @codeceptjs/mobilewright in workspace…"
            let pm = workspace?.packageManager ?? .npm
            let cmd: String
            switch pm {
            case .npm: cmd = "npm install -D @codeceptjs/mobilewright"
            case .pnpm: cmd = "pnpm add -D @codeceptjs/mobilewright"
            case .yarn: cmd = "yarn add -D @codeceptjs/mobilewright"
            case .bun: cmd = "bun add -d @codeceptjs/mobilewright"
            }
            await runWizardPrerequisiteInstall(label: "@codeceptjs/mobilewright & mobilecli", shellCommand: cmd)
            if MobileCLIDeviceBridge.resolveMobileCLIBinary(workspaceRoot: root) == nil {
                isMobileAutoSetupRunning = false
                mobileAutoSetupStatusText = ""
                return
            }
        }

        // 1b. If this is an iOS Simulator that is offline/shutdown, boot it cleanly and wait for SpringBoard
        if device.type == .simulator {
            mobileAutoSetupStatusText = "Booting \(device.name) Simulator…"
            do {
                try await mobileDeviceBridge.bootXcodeSimulator(udid: device.id)
            } catch {
                isMobileAutoSetupRunning = false
                mobileAutoSetupStatusText = ""
                mobileSnapshot = nil
                mobileSelectedNodeID = nil
                mobileHoveredNodeID = nil
                mobileCaptureErrorDetail = error.localizedDescription
                mobileLastError = error.localizedDescription
                showBanner("Could not boot \(device.name): \(error.localizedDescription)", isError: true)
                return
            }
        }

        // 2. Check whether on-device agent is already installed
        mobileAutoSetupStatusText = "Checking Mobilewright agent on \(device.name)…"
        let alreadyInstalled = (try? await mobileDeviceBridge.checkAgentStatus(deviceId: device.id, workspaceRoot: root)) ?? false

        if !alreadyInstalled {
            var profileURL: URL? = nil
            if device.platform == .ios && device.type == .real {
                mobileAutoSetupStatusText = "Finding Apple signing profile for \(device.name)…"
                refreshDiscoveredProvisioningProfiles(forDeviceID: device.id)
                if let matched = MobileCLIDeviceBridge.MobileProvisioningProfileInspector.bestMatchingProfile(
                    for: device.id,
                    in: mobileDiscoveredProfiles
                ) {
                    mobileProvisioningProfilePath = matched.path
                    if !matched.isWildcardProfile {
                        // Fail fast with an honest, crystal-clear explanation instead of wasting 60s downloading & hitting 0xe8008001
                        isMobileAutoSetupRunning = false
                        mobileAutoSetupStatusText = ""
                        mobileSnapshot = nil
                        mobileSelectedNodeID = nil
                        mobileHoveredNodeID = nil
                        let msg = "Detected '\(matched.name)' (\(matched.applicationIdentifier ?? "explicit App ID")), a free Personal Team profile. Real iPhones require a Wildcard (*) Apple Developer profile ($99/yr)."
                        mobileCaptureAgentRequired = true
                        mobileCaptureErrorDetail = msg
                        mobileLastError = nil
                        connectedMobileDevice = device
                        pendingPluggedInDevicePrompt = nil
                        showBanner("Real iPhone requires a Wildcard (*) Apple Developer profile", isError: true)
                        return
                    }
                    profileURL = URL(fileURLWithPath: matched.path)
                } else if !mobileProvisioningProfilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    profileURL = URL(fileURLWithPath: mobileProvisioningProfilePath)
                } else {
                    // No matching .mobileprovision yet — take user directly to Step 3 with guided instructions
                    isMobileAutoSetupRunning = false
                    mobileAutoSetupStatusText = ""
                    pendingPluggedInDevicePrompt = nil
                    openMobileDeviceWizard(initialStep: 3)
                    mobileLastError = "Real iOS devices require a Wildcard (*) .mobileprovision profile (paid Apple Developer account), or use iOS Simulator for free with zero signing."
                    return
                }
            }

            mobileAutoSetupStatusText = "Downloading & installing agent on \(device.name) (1st run ~60s)…"
            do {
                try await mobileDeviceBridge.installAgent(
                    deviceId: device.id,
                    provisioningProfileURL: profileURL,
                    workspaceRoot: root
                )
                mobileAgentStatusReady = true
            } catch {
                isMobileAutoSetupRunning = false
                mobileAutoSetupStatusText = ""
                mobileSnapshot = nil
                mobileSelectedNodeID = nil
                mobileHoveredNodeID = nil
                mobileCaptureAgentRequired = true
                let rawErr = error.localizedDescription
                let friendlyErr: String
                if rawErr.contains("0xe8008001") || rawErr.contains("ApplicationVerificationFailed") {
                    friendlyErr = "iOS rejected the code signature (0xe8008001). Real iOS devices require a Wildcard (*) iOS Development .mobileprovision from a paid Apple Developer Program account ($99/yr)."
                } else {
                    friendlyErr = rawErr
                }
                mobileCaptureErrorDetail = friendlyErr
                mobileLastError = nil
                connectedMobileDevice = device
                pendingPluggedInDevicePrompt = nil
                showBanner("Agent install failed — see details in phone panel", isError: true)
                return
            }
        } else {
            mobileAgentStatusReady = true
        }

        // 3. Connect & start live mirror immediately
        mobileAutoSetupStatusText = "Connecting live mirror for \(device.name)…"
        pendingPluggedInDevicePrompt = nil
        dismissedPluggedInDeviceIDs.insert(device.id)
        showingMobileDeviceWizard = false
        isMobileStudioVisible = true
        connectedMobileDevice = device
        settings.mobileResolutionPresetID = device.platform == .android ? "pixel-8" : "iphone-17-pro"
        saveSettings()

        await refreshMobileScreenSnapshot()
        isMobileAutoSetupRunning = false
        mobileAutoSetupStatusText = ""

        if !mobileCaptureAgentRequired && mobileCaptureErrorDetail == nil {
            showBanner("Connected live to \(device.name)")
        }
    }

    func openXcodeForSigning() {
        let xcodeURL = URL(fileURLWithPath: "/Applications/Xcode.app")
        if FileManager.default.fileExists(atPath: xcodeURL.path) {
            NSWorkspace.shared.open(xcodeURL)
            showBanner("Opened Xcode — sign in via Xcode → Settings → Accounts")
        } else {
            showBanner("Xcode not found in /Applications", isError: true)
        }
    }

    func switchToAvailableXcodeSimulator() async {
        mobileLastError = nil
        mobileCaptureAgentRequired = false
        mobileCaptureErrorDetail = nil
        await refreshMobileDevices()
        guard let sim = mobileDevices.first(where: { $0.type == .simulator && $0.state.isReady })
            ?? mobileDevices.first(where: { $0.type == .simulator && $0.name.contains("iPhone") })
            ?? mobileDevices.first(where: { $0.type == .simulator }) else {
            mobileCaptureErrorDetail = "No Xcode iOS Simulators found on this Mac."
            return
        }
        selectedMobileDeviceID = sim.id
        mobileWizardTargetKind = .iosSimulator
        isMobileSnapshotLoading = true
        do {
            if !sim.state.isReady {
                showBanner("Booting \(sim.name) (waiting for iOS SpringBoard)…")
                try await mobileDeviceBridge.bootXcodeSimulator(udid: sim.id)
            }
            let root = workspace?.rootURL
            let agentReady = (try? await mobileDeviceBridge.checkAgentStatus(deviceId: sim.id, workspaceRoot: root)) ?? false
            if !agentReady {
                showBanner("Installing Mobilewright agent on \(sim.name)…")
                try await mobileDeviceBridge.installAgent(deviceId: sim.id, provisioningProfileURL: nil, workspaceRoot: root)
            }
            mobileAgentStatusReady = true
            let updatedSim = MobileDeviceDescriptor(
                id: sim.id,
                name: sim.name,
                platform: .ios,
                type: .simulator,
                state: .booted,
                osVersion: sim.osVersion,
                agentInstalled: true
            )
            pendingPluggedInDevicePrompt = nil
            connectedMobileDevice = updatedSim
            settings.mobileResolutionPresetID = sim.name.lowercased().contains("ipad") ? "ipad-pro-11" : "iphone-17-pro"
            saveSettings()
            await refreshMobileScreenSnapshot()
            showBanner("Connected live to \(sim.name)")
        } catch {
            isMobileSnapshotLoading = false
            mobileCaptureErrorDetail = error.localizedDescription
            mobileLastError = error.localizedDescription
        }
    }

    func toggleMobileStudio() {
        isMobileStudioVisible.toggle()
        if isMobileStudioVisible && mobileSnapshot == nil {
            loadFallbackPreviewSnapshotIfDisconnected()
            Task { [weak self] in
                await self?.refreshMobileDevices()
            }
        }
    }

    func setMobilePhoneDockSide(_ side: MobilePhoneDockSide) {
        settings.mobilePhoneDockSide = side
        saveSettings()
    }

    func setMobileResolutionPreset(_ presetID: String) {
        settings.mobileResolutionPresetID = presetID
        saveSettings()
        if connectedMobileDevice == nil {
            loadFallbackPreviewSnapshotIfDisconnected(preserveSelection: true)
        }
    }

    func cancelMobileStudioTasks() {
        mobileRefreshTask?.cancel()
        mobileRefreshTask = nil
        mobileUSBMonitorTask?.cancel()
        mobileUSBMonitorTask = nil
        mobileLiveStreamTask?.cancel()
        mobileLiveStreamTask = nil
    }

    func startMobileLiveStreamIfNeeded() {
        guard mobileLiveStreamTask == nil else { return }
        mobileLiveStreamTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self else { break }
                guard self.isMobileStudioVisible,
                      self.isMobileLiveStreamActive,
                      self.connectedMobileDevice != nil,
                      !self.mobileCaptureAgentRequired,
                      self.mobileCaptureErrorDetail == nil,
                      !self.isMobileSnapshotLoading,
                      !self.isMobileGestureExecuting,
                      !self.isMobileAutoSetupRunning else {
                    continue
                }
                await self.refreshMobileFastFrameOnly()
            }
        }
    }

    func stopMobileLiveStream() {
        mobileLiveStreamTask?.cancel()
        mobileLiveStreamTask = nil
    }

    /// Lightweight visual-only frame refresh (~0.4s on iOS Simulator via `simctl io screenshot`).
    /// If the screen pixels changed meaningfully (e.g., an async iOS system alert popped up or external scroll),
    /// it automatically syncs the full accessibility hierarchy (`dump ui`) so element rectangles never go stale!
    func refreshMobileFastFrameOnly() async {
        guard let device = connectedMobileDevice,
              !mobileCaptureAgentRequired else { return }
        let root = workspace?.rootURL
        guard let raw = try? await mobileDeviceBridge.captureFastScreenshotOnly(device: device, workspaceRoot: root) else {
            return
        }
        let prevData = mobileSnapshot?.screenshotPNGData
        let frameChanged = Self.didScreenshotChangeMeaningfully(previous: prevData, current: raw)

        if let existing = mobileSnapshot {
            if frameChanged || prevData == nil {
                mobileSnapshot = existing.updatingScreenshotData(raw)
            }
        } else {
            let presetSize = activeMobileResolutionPreset.logicalSize(for: mobileOrientation)
            mobileSnapshot = MobileScreenSnapshot(
                deviceId: device.id,
                platform: device.platform,
                screenshotPNGData: raw,
                logicalWidth: Double(presetSize.width),
                logicalHeight: Double(presetSize.height),
                orientation: mobileOrientation,
                roots: []
            )
        }

        if frameChanged && !isMobileGestureExecuting && !isMobileSnapshotLoading {
            await refreshMobileScreenSnapshot()
        }
    }

    private static func didScreenshotChangeMeaningfully(previous: Data?, current: Data) -> Bool {
        guard let previous else { return true }
        let deltaBytes = abs(previous.count - current.count)
        if deltaBytes > max(512, previous.count / 60) {
            return true
        }
        guard previous.count == current.count, current.count > 128 else {
            return deltaBytes > 128
        }
        let strideStep = max(1, current.count / 64)
        var diffs = 0
        previous.withUnsafeBytes { prevBuf in
            current.withUnsafeBytes { currBuf in
                var i = 64
                while i < current.count {
                    if prevBuf[i] != currBuf[i] {
                        diffs += 1
                    }
                    i += strideStep
                }
            }
        }
        return diffs >= 4
    }

    func loadFallbackPreviewSnapshotIfDisconnected(preserveSelection: Bool = false) {
        guard connectedMobileDevice == nil else { return }
        let previousId = preserveSelection ? mobileSelectedNodeID : nil
        let preset = activeMobileResolutionPreset
        let snap = MockMobileDeviceTransport.sampleSnapshot(
            preset: preset,
            orientation: mobileOrientation,
            cartCount: mobilePreviewCartCount,
            usernameValue: mobilePreviewUsername,
            passwordFilled: mobilePreviewPasswordFilled
        )
        mobileSnapshot = snap
        if let previousId, snap.allNodes.contains(where: { $0.id == previousId }) {
            mobileSelectedNodeID = previousId
        } else {
            mobileSelectedNodeID = snap.allNodes.first(where: { $0.testId == "Add To Cart button" })?.id
                ?? snap.allNodes.first(where: { $0.normalizedRole == "button" })?.id
        }
    }

    func insertMobileCodeSnippet(_ codeLine: String, locator: String? = nil, action: MobileQuickActionKind = .tap) {
        let step = MobileRecordedStep(codeLine: codeLine, locator: locator, action: action)
        mobileRecordedSteps.append(step)
        appendMobileRecordedStepToActiveTab(codeLine)
        showBanner("Inserted: \(codeLine)")
    }

    func undoLastMobileRecordedStep() {
        guard let last = mobileRecordedSteps.popLast() else { return }
        if let activePath = activeTabPath,
           let idx = openTabs.firstIndex(where: { $0.filePath == activePath }) {
            var content = openTabs[idx].content
            let target = "\n  \(last.codeLine)"
            if let range = content.range(of: target, options: .backwards) {
                content.removeSubrange(range)
                updateActiveTabContent(content)
            }
        }
        showBanner("Removed last recorded step")
    }

    func clearMobileRecordedSteps() {
        mobileRecordedSteps.removeAll()
        showBanner("Cleared recorded step list")
    }

    func copyAllMobileRecordedSteps() {
        let text = mobileRecordedSteps.map(\.codeLine).joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showBanner("Copied \(mobileRecordedSteps.count) Mobilewright step(s)")
    }

    // MARK: - Wizard & Device Management Actions

    func runMobileDoctorInWizard() async {
        isMobileDoctorRunning = true
        mobileLastError = nil
        let root = workspace?.rootURL
        let report = await mobileDeviceBridge.runDoctor(workspaceRoot: root)
        mobileDoctorReport = report
        isMobileDoctorRunning = false
    }

    func refreshMobileDevices() async {
        isMobileDevicesRefreshing = true
        mobileLastError = nil
        let root = workspace?.rootURL
        do {
            let list = try await mobileDeviceBridge.listDevices(workspaceRoot: root)
            mobileDevices = list
            if selectedMobileDeviceID == nil || !list.contains(where: { $0.id == selectedMobileDeviceID }) {
                let preferred = list.first(where: { $0.platform == mobileWizardTargetKind.platform && $0.state.isReady })
                    ?? list.first(where: { $0.platform == mobileWizardTargetKind.platform })
                    ?? list.first
                selectedMobileDeviceID = preferred?.id
            }
            if let devId = selectedMobileDeviceID,
               let dev = list.first(where: { $0.id == devId }),
               dev.state.isReady {
                mobileAgentStatusReady = (try? await mobileDeviceBridge.checkAgentStatus(deviceId: dev.id, workspaceRoot: root)) ?? false
            } else {
                mobileAgentStatusReady = false
            }
        } catch {
            mobileLastError = error.localizedDescription
        }
        isMobileDevicesRefreshing = false
    }

    func bootSelectedXcodeSimulator() async {
        guard let id = selectedMobileDeviceID else { return }
        mobileLastError = nil
        do {
            try await mobileDeviceBridge.bootXcodeSimulator(udid: id)
            showBanner("Booted iOS Simulator")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshMobileDevices()
        } catch {
            mobileLastError = error.localizedDescription
        }
    }

    func browseProvisioningProfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select Apple Provisioning Profile (.mobileprovision)"
        let xcodeProfiles = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles", isDirectory: true)
        if FileManager.default.fileExists(atPath: xcodeProfiles.path) {
            panel.directoryURL = xcodeProfiles
        }
        if let ut = UTType(filenameExtension: "mobileprovision") {
            panel.allowedContentTypes = [ut]
        }
        if panel.runModal() == .OK, let url = panel.url {
            mobileProvisioningProfilePath = url.path
            mobileLastError = nil
        }
    }

    func installAgentOnSelectedDevice() async {
        guard let devId = selectedMobileDeviceID,
              let dev = mobileDevices.first(where: { $0.id == devId }) else {
            mobileLastError = "Select a connected or booted device first."
            return
        }
        isMobileAgentInstalling = true
        mobileLastError = nil
        let root = workspace?.rootURL
        do {
            let profileURL: URL?
            if dev.platform == .ios && dev.type == .real {
                guard !mobileProvisioningProfilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    mobileLastError = "A .mobileprovision file is required to sign the agent on a real iPhone/iPad."
                    isMobileAgentInstalling = false
                    return
                }
                profileURL = URL(fileURLWithPath: mobileProvisioningProfilePath)
            } else {
                profileURL = nil
            }
            try await mobileDeviceBridge.installAgent(deviceId: dev.id, provisioningProfileURL: profileURL, workspaceRoot: root)
            mobileAgentStatusReady = true
            showBanner("Mobilewright agent installed on \(dev.name)")
        } catch {
            mobileLastError = error.localizedDescription
        }
        isMobileAgentInstalling = false
    }

    func loadInstalledAppsForSelectedDevice() async {
        guard let devId = selectedMobileDeviceID else { return }
        let root = workspace?.rootURL
        if let apps = try? await mobileDeviceBridge.listInstalledApps(deviceId: devId, workspaceRoot: root), !apps.isEmpty {
            mobileInstalledApps = apps
            if !apps.contains(where: { $0.bundleId == selectedMobileAppId }), let first = apps.first {
                selectedMobileAppId = first.bundleId
            }
        } else if mobileInstalledApps.isEmpty {
            mobileInstalledApps = [
                MobileInstalledApp(bundleId: "com.saucelabs.mydemoapp.rn", name: "Sauce Labs Demo Store"),
                MobileInstalledApp(bundleId: "com.apple.Preferences", name: "iOS Settings"),
                MobileInstalledApp(bundleId: "com.android.settings", name: "Android Settings")
            ]
        }
    }

    func connectSelectedMobileDeviceAndLaunchStudio() {
        let targetDev = selectedMobileDeviceID.flatMap { id in mobileDevices.first(where: { $0.id == id }) }
        showingMobileDeviceWizard = false
        isMobileStudioVisible = true
        pendingPluggedInDevicePrompt = nil

        guard let dev = targetDev else {
            loadFallbackPreviewSnapshotIfDisconnected()
            return
        }

        // If user selected an offline/shutdown simulator or a device without agent, auto-boot & prepare it seamlessly!
        if dev.type == .simulator && (!dev.state.isReady || !mobileAgentStatusReady) {
            connectedMobileDevice = dev
            settings.mobileResolutionPresetID = dev.name.lowercased().contains("ipad") ? "ipad-pro-11" : "iphone-17-pro"
            saveSettings()
            Task { [weak self] in
                await self?.allowAndAutoSetupRealDevice(dev)
            }
            return
        }

        connectedMobileDevice = dev
        if dev.platform == .android {
            settings.mobileResolutionPresetID = "pixel-8"
        } else {
            settings.mobileResolutionPresetID = dev.name.lowercased().contains("ipad") ? "ipad-pro-11" : "iphone-17-pro"
        }
        saveSettings()
        Task { [weak self] in
            await self?.refreshMobileScreenSnapshot()
        }
    }

    func disconnectMobileDevice() {
        cancelMobileStudioTasks()
        connectedMobileDevice = nil
        mobileCaptureAgentRequired = false
        mobileCaptureErrorDetail = nil
        mobileLastError = nil
        loadFallbackPreviewSnapshotIfDisconnected()
        showBanner("Disconnected live device (Interactive Preview active)")
    }

    // MARK: - Live Screen Mirror & Recording Actions

    func refreshMobileScreenSnapshot() async {
        guard let device = connectedMobileDevice else {
            mobileCaptureAgentRequired = false
            mobileCaptureErrorDetail = nil
            loadFallbackPreviewSnapshotIfDisconnected()
            return
        }
        isMobileSnapshotLoading = true
        mobileLastError = nil
        mobileCaptureAgentRequired = false
        mobileCaptureErrorDetail = nil
        let root = workspace?.rootURL
        do {
            let snap = try await mobileDeviceBridge.captureSnapshot(device: device, workspaceRoot: root)
            mobileSnapshot = snap
            mobileOrientation = snap.orientation
            mobileAgentStatusReady = true
            if mobileSelectedNodeID == nil || !snap.allNodes.contains(where: { $0.id == mobileSelectedNodeID }) {
                mobileSelectedNodeID = snap.allNodes.first(where: { $0.normalizedRole == "button" && $0.isVisible })?.id
                    ?? snap.allNodes.first(where: { $0.normalizedRole != "window" && $0.isVisible })?.id
                    ?? snap.allNodes.first?.id
            }
        } catch let bridgeErr as MobileDeviceBridgeError {
            mobileSnapshot = nil
            if case .agentNotInstalled = bridgeErr {
                mobileCaptureAgentRequired = true
                mobileAgentStatusReady = false
                mobileCaptureErrorDetail = bridgeErr.localizedDescription
                mobileLastError = nil
            } else {
                mobileCaptureErrorDetail = bridgeErr.localizedDescription
                mobileLastError = bridgeErr.localizedDescription
            }
        } catch {
            mobileSnapshot = nil
            mobileCaptureErrorDetail = error.localizedDescription
            mobileLastError = error.localizedDescription
        }
        isMobileSnapshotLoading = false
    }

    func performMobileQuickAction(
        _ action: MobileQuickActionKind,
        node: MobileAccessibilityNode? = nil,
        coordinate: CGPoint? = nil,
        customSwipePoints: (from: CGPoint, to: CGPoint)? = nil
    ) {
        let targetNode: MobileAccessibilityNode? = {
            if let node {
                return (node.normalizedRole == "window" && coordinate != nil) ? nil : node
            }
            return (coordinate == nil) ? selectedMobileNode : nil
        }()
        let platform = selectedMobilePlatform

        if action == .setOrientation {
            mobileOrientation = mobileOrientation.toggled
        }

        let typedVal: String? = (action == .fillField) ? mobileFillInputText : nil
        let effectiveAction: MobileQuickActionKind = (action == .tap && targetNode == nil && coordinate != nil) ? .tapXY : action
        let codeLine = MobileLocatorSynthesizer.synthesizeStepCode(
            action: effectiveAction,
            node: targetNode,
            typedValue: typedVal,
            orientation: mobileOrientation,
            platform: platform,
            coordinate: coordinate
        )
        let locator = targetNode.map { MobileLocatorSynthesizer.recommendedLocator(for: $0, platform: platform) }

        if mobileRecordToEditor {
            let step = MobileRecordedStep(codeLine: codeLine, locator: locator, action: effectiveAction)
            mobileRecordedSteps.append(step)
            appendMobileRecordedStepToActiveTab(codeLine)
        }

        if let device = connectedMobileDevice {
            let root = workspace?.rootURL
            let orientation = mobileOrientation
            let snapW = mobileSnapshot?.logicalWidth ?? Double(activeMobileResolutionPreset.logicalSize(for: orientation).width)
            let snapH = mobileSnapshot?.logicalHeight ?? Double(activeMobileResolutionPreset.logicalSize(for: orientation).height)
            let tapX = coordinate.map { Double($0.x) } ?? targetNode?.bounds.centerX ?? (snapW * 0.5)
            let tapY = coordinate.map { Double($0.y) } ?? targetNode?.bounds.centerY ?? (snapH * 0.5)

            let swipeEndpoints: (x1: Double, y1: Double, x2: Double, y2: Double) = {
                if let custom = customSwipePoints {
                    return (Double(custom.from.x), Double(custom.from.y), Double(custom.to.x), Double(custom.to.y))
                }
                switch effectiveAction {
                case .swipeUp:
                    return (snapW * 0.5, snapH * 0.74, snapW * 0.5, snapH * 0.24)
                case .swipeDown:
                    return (snapW * 0.5, snapH * 0.26, snapW * 0.5, snapH * 0.76)
                case .swipeLeft:
                    return (snapW * 0.84, snapH * 0.5, snapW * 0.16, snapH * 0.5)
                case .swipeRight:
                    return (snapW * 0.16, snapH * 0.5, snapW * 0.84, snapH * 0.5)
                default:
                    return (snapW * 0.5, snapH * 0.7, snapW * 0.5, snapH * 0.3)
                }
            }()

            mobileRefreshTask?.cancel()
            mobileRefreshTask = Task { [weak self] in
                guard let self else { return }
                self.isMobileGestureExecuting = true
                defer { self.isMobileGestureExecuting = false }
                do {
                    switch effectiveAction {
                    case .tap, .tapXY:
                        try await self.mobileDeviceBridge.performTap(deviceId: device.id, x: tapX, y: tapY, workspaceRoot: root)
                    case .longPress:
                        try await self.mobileDeviceBridge.performLongPress(deviceId: device.id, x: tapX, y: tapY, durationMs: 800, workspaceRoot: root)
                    case .swipeUp, .swipeDown, .swipeLeft, .swipeRight:
                        try await self.mobileDeviceBridge.performSwipe(
                            deviceId: device.id,
                            fromX: swipeEndpoints.x1,
                            fromY: swipeEndpoints.y1,
                            toX: swipeEndpoints.x2,
                            toY: swipeEndpoints.y2,
                            durationMs: 300,
                            workspaceRoot: root
                        )
                    case .fillField:
                        try await self.mobileDeviceBridge.performTap(deviceId: device.id, x: tapX, y: tapY, workspaceRoot: root)
                        if let typedVal, !typedVal.isEmpty {
                            try await self.mobileDeviceBridge.performTypeText(deviceId: device.id, text: typedVal, workspaceRoot: root)
                        }
                    case .goBack:
                        if device.platform == .ios {
                            // iOS has no hardware BACK key; perform standard iOS left-edge back-swipe gesture
                            try await self.mobileDeviceBridge.performSwipe(
                                deviceId: device.id,
                                fromX: 12,
                                fromY: snapH * 0.5,
                                toX: snapW * 0.78,
                                toY: snapH * 0.5,
                                durationMs: 260,
                                workspaceRoot: root
                            )
                        } else {
                            try await self.mobileDeviceBridge.performHardwareButton(deviceId: device.id, button: "BACK", workspaceRoot: root)
                        }
                    case .pressHome:
                        try await self.mobileDeviceBridge.performHardwareButton(deviceId: device.id, button: "HOME", workspaceRoot: root)
                    case .setOrientation:
                        try await self.mobileDeviceBridge.setOrientation(deviceId: device.id, orientation: orientation, workspaceRoot: root)
                    case .see, .seeElement:
                        break
                    }

                    guard effectiveAction != .see && effectiveAction != .seeElement else { return }

                    // Stage 1 (Fast visual frame at 180ms): Immediate visual response as transition starts
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    guard !Task.isCancelled else { return }
                    await self.refreshMobileFastFrameOnly()

                    // Stage 2 (Settled full snapshot + UI tree at +650ms): Captures final settled screen after animation completes
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    guard !Task.isCancelled else { return }
                    await self.refreshMobileScreenSnapshot()
                } catch {
                    self.mobileLastError = error.localizedDescription
                }
            }
        } else {
            // Interactive Virtual Preview state feedback so actions feel alive even without a USB cable
            if effectiveAction == .tap || effectiveAction == .longPress {
                if targetNode?.id == "node-7" {
                    mobilePreviewCartCount += 1
                } else if targetNode?.id == "node-3" {
                    mobilePreviewCartCount = 1
                    mobilePreviewUsername = ""
                    mobilePreviewPasswordFilled = false
                }
            } else if effectiveAction == .fillField {
                if targetNode?.id == "node-5" {
                    mobilePreviewUsername = typedVal ?? mobileFillInputText
                } else if targetNode?.id == "node-6" {
                    mobilePreviewPasswordFilled = true
                }
            }
            loadFallbackPreviewSnapshotIfDisconnected(preserveSelection: true)
        }

        showBanner(mobileRecordToEditor ? "Recorded: \(codeLine)" : "Executed \(effectiveAction.rawValue)")
    }

    func performMobileCanvasDragSwipe(from startDevicePt: CGPoint, to endDevicePt: CGPoint) {
        let direction = MobileLocatorSynthesizer.classifySwipeDirection(from: startDevicePt, to: endDevicePt)
        performMobileQuickAction(direction, node: nil, coordinate: nil, customSwipePoints: (from: startDevicePt, to: endDevicePt))
    }

    func copyMobileConfigSnippet() {
        let dev = connectedMobileDevice ?? mobileDevices.first(where: { $0.id == selectedMobileDeviceID })
        let snippet = MobileLocatorSynthesizer.generateHelperConfigSnippet(
            platform: dev?.platform ?? mobileWizardTargetKind.platform,
            appId: selectedMobileAppId,
            deviceName: dev?.name,
            deviceId: dev?.type == .real ? dev?.id : nil
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        showBanner("Copied Mobilewright config snippet")
    }

    /// Generates and opens a verified cross-platform (iOS Simulator + Android Emulator/Phone) Mobilewright sample test
    /// and updates `codecept.conf.js` if Mobilewright is not yet configured in the workspace.
    func generateMobileSampleTestInWorkspace() {
        guard let root = workspace?.rootURL else {
            showBanner("Open a CodeceptJS workspace folder first", isError: true)
            return
        }

        let activePlatform = connectedMobileDevice?.platform ?? mobileWizardTargetKind.platform
        let defaultPlat = activePlatform == .android ? "android" : "ios"

        let confURL = root.appendingPathComponent("codecept.conf.js")
        let existingConf = (try? String(contentsOf: confURL, encoding: .utf8)) ?? ""
        if !existingConf.contains("Mobilewright") {
            let confContent = """
            const platform = process.env.MOBILE_PLATFORM || '\(defaultPlat)'; // 'ios' (Xcode Simulator) or 'android' (AVD / USB)
            const defaultApp = platform === 'android' ? 'com.android.settings' : 'com.apple.Preferences';

            export const config = {
              name: '\(root.lastPathComponent)',
              tests: './tests/*_test.js',
              output: './output',
              noGlobals: true,
              helpers: {
                Mobilewright: {
                  require: '@codeceptjs/mobilewright',
                  platform,
                  app: process.env.MOBILE_APP || defaultApp,
                  ...(process.env.MOBILE_DEVICE_ID ? { deviceId: process.env.MOBILE_DEVICE_ID } : {}),
                  restart: 'app',
                  waitForTimeout: 10000,
                  actionTimeout: 10000,
                },
              },
              plugins: {
                screenshot: {
                  enabled: true,
                  on: 'fail',
                },
                junitReporter: {
                  enabled: true,
                  outputName: 'report.xml',
                },
              },
            };
            """
            try? confContent.write(to: confURL, atomically: true, encoding: .utf8)
        }

        let testsDir = root.appendingPathComponent("tests")
        try? FileManager.default.createDirectory(at: testsDir, withIntermediateDirectories: true)
        let sampleURL = testsDir.appendingPathComponent("mobile_simulator_test.js")
        let sampleContent = """
        Feature('Mobile Simulator Verification (iOS & Android) @mobile');

        Scenario('launches system Settings and opens Accessibility @smoke', async ({ I }) => {
          // Runs out-of-the-box on any Xcode iOS Simulator (com.apple.Preferences)
          // and any Android Emulator / USB phone (com.android.settings)
          I.waitForText('Settings', 10);
          I.see('Settings');

          // Cross-platform locator: iOS accessibility ID or Android visible label
          I.waitForElement({ ios: '~com.apple.settings.accessibility', android: 'Accessibility' }, 10);
          I.tap({ ios: '~com.apple.settings.accessibility', android: 'Accessibility' });

          I.waitForText('Accessibility', 10);
          I.see('Accessibility');
          I.saveScreenshot('01-accessibility-screen.png');
        });

        Scenario('verifies platform-specific iOS Simulator & Android settings @cross-platform', async ({ I }) => {
          I.waitForText('Settings', 10);

          I.runOnIOS(() => {
            I.seeAppIsInstalled('com.apple.Preferences');
            I.waitForElement('~com.apple.settings.general', 10);
            I.tap('~com.apple.settings.general');
            I.waitForText('About', 10);
            I.see('About');
            I.saveScreenshot('02-ios-general-about.png');
          });

          I.runOnAndroid(() => {
            I.seeAppIsInstalled('com.android.settings');
            I.seeOrientationIs('PORTRAIT');
            I.saveScreenshot('02-android-settings.png');
          });
        });
        """
        try? sampleContent.write(to: sampleURL, atomically: true, encoding: .utf8)

        rescanWorkspace()
        if let wsFile = workspace?.files.first(where: { $0.path == sampleURL.path }) {
            openFile(wsFile)
        }
        showBanner("Ready! Opened tests/mobile_simulator_test.js (iOS & Android Simulator sample)")
    }

    func installADBViaHomebrewFromWizard() {
        Task { [weak self] in
            await self?.runWizardPrerequisiteInstall(
                label: "ADB (android-platform-tools)",
                shellCommand: "brew install android-platform-tools"
            )
        }
    }

    func installMobilewrightInWorkspaceFromWizard() {
        let pm = workspace?.packageManager ?? .npm
        let cmd: String
        switch pm {
        case .npm: cmd = "npm install -D @codeceptjs/mobilewright"
        case .pnpm: cmd = "pnpm add -D @codeceptjs/mobilewright"
        case .yarn: cmd = "yarn add -D @codeceptjs/mobilewright"
        case .bun: cmd = "bun add -d @codeceptjs/mobilewright"
        }
        Task { [weak self] in
            await self?.runWizardPrerequisiteInstall(
                label: "@codeceptjs/mobilewright & mobilecli",
                shellCommand: cmd
            )
        }
    }

    func installMobilePrerequisiteFromWizard(check: MobileDoctorCheckItem) {
        guard let rawCmd = check.remediationCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawCmd.isEmpty else { return }
        if rawCmd.contains("@codeceptjs/mobilewright") || check.name.lowercased().contains("mobilecli") {
            installMobilewrightInWorkspaceFromWizard()
            return
        }
        if rawCmd.contains("android-platform-tools") {
            installADBViaHomebrewFromWizard()
            return
        }
        Task { [weak self] in
            await self?.runWizardPrerequisiteInstall(label: check.name, shellCommand: rawCmd)
        }
    }

    private func runWizardPrerequisiteInstall(label: String, shellCommand: String) async {
        guard !isMobilePrerequisiteInstalling else { return }
        guard let workspace, let toolchain = resolvedToolchain else {
            mobileLastError = "Open a CodeceptJS workspace folder first before installing \(label)."
            return
        }
        guard !isRunning else {
            mobileLastError = "Another command is currently running in Terminal. Stop it first (⌘.) and retry."
            return
        }

        isMobilePrerequisiteInstalling = true
        mobilePrerequisiteStatusLine = "Starting: \(shellCommand)"
        mobileLastError = nil

        let command = PackageManagerSupport.buildCommand(
            action: .customShell(command: shellCommand),
            packageManager: workspace.packageManager,
            workspaceRoot: workspace.rootURL,
            toolchain: toolchain,
            extraEnv: runOptions.environmentVariables
        )

        isRunning = true
        activeRunLabel = "Setup \(label)"
        lastCommandLine = command.displayCommand
        consoleLogs.append(ConsoleLogEntry(
            timestamp: Date(),
            text: "$ \(command.displayCommand)",
            isError: false,
            isStep: false,
            isHighlight: true
        ))

        do {
            let result = try await runnerService.execute(command: command) { [weak self] event in
                Task { @MainActor [weak self] in
                    if case .logLine(let text, let isError) = event {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            self?.mobilePrerequisiteStatusLine = trimmed
                        }
                        self?.consoleLogs.append(ConsoleLogEntry(
                            timestamp: Date(),
                            text: text,
                            isError: isError,
                            isStep: false,
                            isHighlight: false
                        ))
                        if let count = self?.consoleLogs.count, count > 4000 {
                            self?.consoleLogs.removeFirst(500)
                        }
                    }
                }
            }
            isRunning = false
            isMobilePrerequisiteInstalling = false
            mobilePrerequisiteStatusLine = ""
            rescanWorkspace()

            if result.exitCode == 0 {
                showBanner("Installed \(label) successfully")
                await runMobileDoctorInWizard()
                await refreshMobileDevices()
            } else if result.wasCancelled {
                mobileLastError = "Installation of \(label) was cancelled."
            } else {
                mobileLastError = "Setup command exited with code \(result.exitCode). Open Terminal (⌘J) for full details."
            }
        } catch {
            isRunning = false
            isMobilePrerequisiteInstalling = false
            mobilePrerequisiteStatusLine = ""
            mobileLastError = "Could not install \(label): \(error.localizedDescription)"
        }
    }

    /// Inserts a recorded Mobilewright `I.*` line cleanly into the active test file (before the final `});` when possible).
    private func appendMobileRecordedStepToActiveTab(_ codeLine: String) {
        guard let activePath = activeTabPath,
              let idx = openTabs.firstIndex(where: { $0.filePath == activePath }) else {
            return
        }
        var content = openTabs[idx].content
        let indented = "  \(codeLine)"
        if let closingRange = content.range(of: "\n});", options: .backwards) {
            content.insert(contentsOf: "\n\(indented)", at: closingRange.lowerBound)
        } else if content.hasSuffix("\n") {
            content.append("\(indented)\n")
        } else {
            content.append("\n\(indented)\n")
        }
        updateActiveTabContent(content)
    }
}
