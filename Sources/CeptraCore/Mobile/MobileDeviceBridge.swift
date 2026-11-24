import Foundation
import ImageIO

public protocol MobileDeviceTransport: Sendable {
    func listDevices(workspaceRoot: URL?) async throws -> [MobileDeviceDescriptor]
    func listXcodeSimulators() async throws -> [MobileDeviceDescriptor]
    func bootXcodeSimulator(udid: String) async throws
    func runDoctor(workspaceRoot: URL?) async -> MobileDoctorReport
    func checkAgentStatus(deviceId: String, workspaceRoot: URL?) async throws -> Bool
    func installAgent(deviceId: String, provisioningProfileURL: URL?, workspaceRoot: URL?) async throws
    func listInstalledApps(deviceId: String, workspaceRoot: URL?) async throws -> [MobileInstalledApp]
    func captureSnapshot(device: MobileDeviceDescriptor, workspaceRoot: URL?) async throws -> MobileScreenSnapshot
    func captureFastScreenshotOnly(device: MobileDeviceDescriptor, workspaceRoot: URL?) async throws -> Data?
    func performTap(deviceId: String, x: Double, y: Double, workspaceRoot: URL?) async throws
    func performLongPress(deviceId: String, x: Double, y: Double, durationMs: Int, workspaceRoot: URL?) async throws
    func performSwipe(deviceId: String, fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int, workspaceRoot: URL?) async throws
    func performTypeText(deviceId: String, text: String, workspaceRoot: URL?) async throws
    func performHardwareButton(deviceId: String, button: String, workspaceRoot: URL?) async throws
    func setOrientation(deviceId: String, orientation: MobileDeviceOrientation, workspaceRoot: URL?) async throws
}

/// Fail-closed, zero-shell-interpolation device bridge uniting:
/// - `mobilecli` (active USB/simulator session, agent management, screenshots, `dump ui`, `io tap/type`)
/// - `xcrun simctl` (discovering and booting shutdown Xcode iOS Simulators)
/// - `mobilewright doctor` (environment readiness diagnostics)
public struct MobileCLIDeviceBridge: MobileDeviceTransport, Sendable {
    private static let allowedIdentifierRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#)
    private static let screenInfoLock = NSLock()
    private static var cachedScreenInfos: [String: MobileDeviceScreenInfo] = [:]
    private static let blockedPathFragments: [String] = [
        "/.ssh/", "/.aws/", "/.gnupg/", "/.kube/", "/.docker/",
        "/Library/Keychains/", "/etc/", "/private/etc/", "/System/"
    ]

    public init() {}

    // MARK: - Security Validators (Threats T-01, T-02, T-04)

    public static func validateDeviceIdentifier(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = trimmed as NSString
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("-"),
              allowedIdentifierRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) != nil else {
            throw MobileDeviceBridgeError.invalidDeviceIdentifier(raw)
        }
        return trimmed
    }

    public static func validateBundleIdentifier(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = trimmed as NSString
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("-"),
              allowedIdentifierRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) != nil else {
            throw MobileDeviceBridgeError.invalidBundleIdentifier(raw)
        }
        return trimmed
    }

    public static func validateProvisioningProfileURL(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        for candidate in [standardized, resolved] {
            guard candidate.pathExtension.lowercased() == "mobileprovision" else {
                throw MobileDeviceBridgeError.invalidProvisioningProfile("File must have a `.mobileprovision` extension.")
            }
            for blocked in blockedPathFragments where candidate.path.contains(blocked) {
                throw MobileDeviceBridgeError.invalidProvisioningProfile("Access to protected system/credential directories is blocked.")
            }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue else {
            throw MobileDeviceBridgeError.invalidProvisioningProfile("File does not exist at \(resolved.path).")
        }
        return MobileProvisioningProfileInspector.inspect(url: resolved)?.path != nil ? resolved : resolved
    }

    /// Parses the embedded XML property list inside an Apple `.mobileprovision` file without shelling out.
    public enum MobileProvisioningProfileInspector {
        public static func inspect(url: URL) -> MobileProvisioningProfileInfo? {
            guard let raw = try? Data(contentsOf: url) else { return nil }
            return parse(data: raw, path: url.path)
        }

        public static func parse(data: Data, path: String) -> MobileProvisioningProfileInfo? {
            guard let startTag = "<?xml".data(using: .utf8),
                  let endTag = "</plist>".data(using: .utf8),
                  let startRange = data.range(of: startTag),
                  let endRange = data.range(of: endTag, in: startRange.lowerBound..<data.endIndex) else {
                return nil
            }
            let plistData = data[startRange.lowerBound..<endRange.upperBound]
            guard let obj = try? PropertyListSerialization.propertyList(from: Data(plistData), options: [], format: nil),
                  let dict = obj as? [String: Any] else {
                return nil
            }
            let fallbackName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let name = (dict["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let teamName = (dict["TeamName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let entitlements = dict["Entitlements"] as? [String: Any]
            let appID = (entitlements?["application-identifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let expiration = dict["ExpirationDate"] as? Date
            let udids = Set((dict["ProvisionedDevices"] as? [String]) ?? [])
            let allDevices = (dict["ProvisionsAllDevices"] as? Bool) ?? false
            return MobileProvisioningProfileInfo(
                path: path,
                name: (name?.isEmpty == false) ? name! : fallbackName,
                teamName: (teamName?.isEmpty == false) ? teamName : nil,
                applicationIdentifier: (appID?.isEmpty == false) ? appID : nil,
                expirationDate: expiration,
                provisionedDeviceUDIDs: udids,
                provisionsAllDevices: allDevices
            )
        }

        public static func discoverInstalledProfiles(
            in directories: [URL]? = nil
        ) -> [MobileProvisioningProfileInfo] {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            let searchDirs = directories ?? [
                home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles", isDirectory: true),
                home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles", isDirectory: true)
            ]
            var results: [MobileProvisioningProfileInfo] = []
            var seenPaths: Set<String> = []
            for dir in searchDirs {
                guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                    continue
                }
                for file in files where file.pathExtension.lowercased() == "mobileprovision" {
                    let stdPath = file.standardizedFileURL.path
                    guard !seenPaths.contains(stdPath) else { continue }
                    seenPaths.insert(stdPath)
                    if let parsed = inspect(url: file) {
                        results.append(parsed)
                    } else {
                        results.append(MobileProvisioningProfileInfo(path: stdPath, name: file.lastPathComponent))
                    }
                }
            }
            return results.sorted { lhs, rhs in
                if lhs.isExpired != rhs.isExpired { return !lhs.isExpired }
                return (lhs.expirationDate ?? .distantPast) > (rhs.expirationDate ?? .distantPast)
            }
        }

        public static func bestMatchingProfile(
            for deviceUDID: String,
            in profiles: [MobileProvisioningProfileInfo]
        ) -> MobileProvisioningProfileInfo? {
            let matching = profiles.filter { $0.supports(deviceUDID: deviceUDID) }
            // Strongly prefer wildcard (*) profiles (required by mobilecli to re-sign its runner app),
            // then non-UITests profiles, then latest expiration date.
            return matching.sorted { lhs, rhs in
                if lhs.isWildcardProfile != rhs.isWildcardProfile { return lhs.isWildcardProfile }
                let lhsUI = lhs.name.lowercased().contains("uitests")
                let rhsUI = rhs.name.lowercased().contains("uitests")
                if lhsUI != rhsUI { return !lhsUI }
                return (lhs.expirationDate ?? .distantPast) > (rhs.expirationDate ?? .distantPast)
            }.first
        }
    }

    /// Builds a sanitized child-process environment enforcing `MOBILEWRIGHT_DISABLE_TELEMETRY=1` (Threat T-02).
    public static func sanitizedEnvironment(workspaceRoot: URL?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let effectiveRoot = workspaceRoot ?? FileManager.default.homeDirectoryForCurrentUser
        let toolchain = NodeToolchainResolver.resolve(workspaceRoot: effectiveRoot)
        env["PATH"] = toolchain.searchPath
        env["MOBILEWRIGHT_DISABLE_TELEMETRY"] = "1"
        env["NO_COLOR"] = "1"
        env["FORCE_COLOR"] = "0"
        return env
    }

    /// Resolves the `mobilecli` binary from workspace `node_modules` or PATH.
    /// Prefers the native `@mobilenext/mobilecli-darwin-*` Go binary directly to bypass the Node.js wrapper overhead.
    public static func resolveMobileCLIBinary(workspaceRoot: URL?) -> String? {
        let fm = FileManager.default
        if let root = workspaceRoot {
            let directCandidates = [
                "node_modules/@mobilenext/mobilecli-darwin-arm64/mobilecli-darwin-arm64",
                "node_modules/@mobilenext/mobilecli-darwin-amd64/mobilecli-darwin-amd64",
                "node_modules/.bin/mobilecli",
                "examples/mobilewright-demo/node_modules/@mobilenext/mobilecli-darwin-arm64/mobilecli-darwin-arm64",
                "examples/mobilewright-demo/node_modules/.bin/mobilecli"
            ]
            for rel in directCandidates {
                let candidate = root.appendingPathComponent(rel).path
                if fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        let effectiveRoot = workspaceRoot ?? fm.homeDirectoryForCurrentUser
        let toolchain = NodeToolchainResolver.resolve(workspaceRoot: effectiveRoot)
        return NodeToolchainResolver.findExecutable(named: "mobilecli", in: toolchain.searchPath)
    }

    public static func resolveMobilewrightBinary(workspaceRoot: URL?) -> String? {
        let fm = FileManager.default
        if let root = workspaceRoot {
            let localBin = root.appendingPathComponent("node_modules/.bin/mobilewright").path
            if fm.isExecutableFile(atPath: localBin) {
                return localBin
            }
            let demoBin = root.appendingPathComponent("examples/mobilewright-demo/node_modules/.bin/mobilewright").path
            if fm.isExecutableFile(atPath: demoBin) {
                return demoBin
            }
        }
        let effectiveRoot = workspaceRoot ?? fm.homeDirectoryForCurrentUser
        let toolchain = NodeToolchainResolver.resolve(workspaceRoot: effectiveRoot)
        return NodeToolchainResolver.findExecutable(named: "mobilewright", in: toolchain.searchPath)
    }

    // MARK: - Device Discovery & Lifecycle

    public func listDevices(workspaceRoot: URL?) async throws -> [MobileDeviceDescriptor] {
        var combined: [MobileDeviceDescriptor] = []
        var seenIds = Set<String>()

        // 1. Live online devices via `mobilecli devices`
        if let bin = Self.resolveMobileCLIBinary(workspaceRoot: workspaceRoot) {
            if let result = try? await runProcess(
                executablePath: bin,
                arguments: ["devices"],
                workingDirectory: workspaceRoot,
                timeoutSeconds: 6
            ), result.exitCode == 0 {
                for dev in Self.parseMobileCLIDevicesJSON(result.stdout) {
                    if seenIds.insert(dev.id).inserted {
                        combined.append(dev)
                    }
                }
            }
        }

        // 2. Append installed Xcode iOS Simulators (including shutdown ones for 1-click boot)
        if let sims = try? await listXcodeSimulators() {
            for sim in sims where seenIds.insert(sim.id).inserted {
                combined.append(sim)
            }
        }

        return combined
    }

    public func listXcodeSimulators() async throws -> [MobileDeviceDescriptor] {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            return []
        }
        let res = try await runProcess(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "available", "--json"],
            workingDirectory: nil,
            timeoutSeconds: 6
        )
        guard res.exitCode == 0 else { return [] }
        return Self.parseSimctlDevicesJSON(res.stdout)
    }

    public func bootXcodeSimulator(udid: String) async throws {
        let safeID = try Self.validateDeviceIdentifier(udid)
        let res = try await runProcess(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "boot", safeID],
            workingDirectory: nil,
            timeoutSeconds: 25
        )
        // Exit code 149 (CoreSimulator code=405: "Unable to boot device in current state: Booted")
        // means the simulator is already booted — treat as success.
        if res.exitCode != 0 && !Self.isAlreadyBootedSimctlResponse(exitCode: res.exitCode, stderr: res.stderr) {
            throw MobileDeviceBridgeError.commandFailed(command: "xcrun simctl boot", exitCode: res.exitCode, stderr: res.stderr)
        }
        // Block cleanly until SpringBoard finishes booting so mobilecli never sees "simulator is offline"
        let statusRes = try await runProcess(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "bootstatus", safeID, "-b"],
            workingDirectory: nil,
            timeoutSeconds: 60
        )
        if statusRes.exitCode != 0 {
            throw MobileDeviceBridgeError.commandFailed(command: "xcrun simctl bootstatus", exitCode: statusRes.exitCode, stderr: statusRes.stderr)
        }
        // Bring Simulator.app up cleanly so user can see if desired (non-fatal)
        _ = try? await runProcess(
            executablePath: "/usr/bin/open",
            arguments: ["-a", "Simulator"],
            workingDirectory: nil,
            timeoutSeconds: 5
        )
    }

    public static func isAlreadyBootedSimctlResponse(exitCode: Int32, stderr: String) -> Bool {
        if exitCode == 149 { return true }
        let lower = stderr.lowercased()
        return lower.contains("already booted")
            || lower.contains("current state: booted")
            || lower.contains("code=405")
    }

    public static func isTransientMobileCLIRPCError(stdout: String, stderr: String) -> Bool {
        let combined = "\(stdout)\n\(stderr)".lowercased()
        return combined.contains("connection refused")
            || combined.contains("timed out waiting for webdriveragent")
            || combined.contains("connection reset by peer")
            || combined.contains("/rpc\": eof")
            || combined.contains("socket hang up")
    }

    public func runDoctor(workspaceRoot: URL?) async -> MobileDoctorReport {
        if let bin = Self.resolveMobilewrightBinary(workspaceRoot: workspaceRoot) {
            if let res = try? await runProcess(
                executablePath: bin,
                arguments: ["doctor"],
                workingDirectory: workspaceRoot,
                timeoutSeconds: 15
            ) {
                let raw = res.stdout.isEmpty ? res.stderr : res.stdout
                let parsed = Self.parseDoctorOutput(raw)
                if !parsed.isEmpty {
                    return MobileDoctorReport(checks: parsed, rawOutput: raw)
                }
            }
        }

        // Fast native fallback check when mobilewright CLI isn't installed in the workspace yet
        let effectiveRoot = workspaceRoot ?? FileManager.default.homeDirectoryForCurrentUser
        let toolchain = NodeToolchainResolver.resolve(workspaceRoot: effectiveRoot)
        var checks: [MobileDoctorCheckItem] = []
        checks.append(MobileDoctorCheckItem(
            category: "System",
            name: "Node.js",
            status: toolchain.nodePath != nil ? .ok : .error,
            detail: toolchain.nodePath ?? "Node.js >= 22.12 required",
            remediationCommand: toolchain.nodePath == nil ? "brew install node@22" : nil
        ))
        let hasMobileCLI = Self.resolveMobileCLIBinary(workspaceRoot: workspaceRoot) != nil
        checks.append(MobileDoctorCheckItem(
            category: "System",
            name: "mobilecli",
            status: hasMobileCLI ? .ok : .warning,
            detail: hasMobileCLI ? "Installed in workspace" : "Not installed in workspace (@codeceptjs/mobilewright)",
            remediationCommand: hasMobileCLI ? nil : "npm install -D @codeceptjs/mobilewright"
        ))
        let hasXcode = FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")
        checks.append(MobileDoctorCheckItem(
            category: "iOS",
            name: "Xcode CLI Tools",
            status: hasXcode ? .ok : .error,
            detail: hasXcode ? "/usr/bin/xcrun available" : "Install Xcode Command Line Tools",
            remediationCommand: hasXcode ? nil : "xcode-select --install"
        ))
        let adbPath = NodeToolchainResolver.findExecutable(named: "adb", in: toolchain.searchPath)
        checks.append(MobileDoctorCheckItem(
            category: "Android",
            name: "ADB (Android Debug Bridge)",
            status: adbPath != nil ? .ok : .error,
            detail: adbPath ?? "Not installed (required for real USB Android phones)",
            remediationCommand: adbPath == nil ? "brew install android-platform-tools" : nil
        ))
        return MobileDoctorReport(checks: checks, rawOutput: "")
    }

    public func checkAgentStatus(deviceId: String, workspaceRoot: URL?) async throws -> Bool {
        let safeID = try Self.validateDeviceIdentifier(deviceId)
        guard let bin = Self.resolveMobileCLIBinary(workspaceRoot: workspaceRoot) else {
            throw MobileDeviceBridgeError.mobileCLINotFound
        }
        let res = try await runProcess(
            executablePath: bin,
            arguments: ["agent", "status", "--device", safeID],
            workingDirectory: workspaceRoot,
            timeoutSeconds: 8
        )
        guard res.exitCode == 0,
              let data = res.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (json["status"] as? String)?.lowercased() == "ok"
    }

    public func installAgent(deviceId: String, provisioningProfileURL: URL?, workspaceRoot: URL?) async throws {
        let safeID = try Self.validateDeviceIdentifier(deviceId)
        guard let bin = Self.resolveMobileCLIBinary(workspaceRoot: workspaceRoot) else {
            throw MobileDeviceBridgeError.mobileCLINotFound
        }
        var args = ["agent", "install", "--device", safeID]
        if let provisioningProfileURL {
            let safeProfile = try Self.validateProvisioningProfileURL(provisioningProfileURL)
            args.append(contentsOf: ["--provisioning-profile", safeProfile.path])
        }
        let res = try await runProcess(
            executablePath: bin,
            arguments: args,
            workingDirectory: workspaceRoot,
            timeoutSeconds: 180
        )
        if res.exitCode != 0 {
            let errMsg = Self.extractMobileCLIErrorMessage(stdout: res.stdout, stderr: res.stderr) ?? (res.stderr.isEmpty ? res.stdout : res.stderr)
            throw MobileDeviceBridgeError.commandFailed(command: "mobilecli agent install", exitCode: res.exitCode, stderr: errMsg)
        }
        if let errMsg = Self.extractMobileCLIErrorMessage(stdout: res.stdout, stderr: "") {
            throw MobileDeviceBridgeError.commandFailed(command: "mobilecli agent install", exitCode: 1, stderr: errMsg)
        }
    }

    public func listInstalledApps(deviceId: String, workspaceRoot: URL?) async throws -> [MobileInstalledApp] {
        let safeID = try Self.validateDeviceIdentifier(deviceId)
        guard let bin = Self.resolveMobileCLIBinary(workspaceRoot: workspaceRoot) else {
            throw MobileDeviceBridgeError.mobileCLINotFound
        }
        let res = try await runProcess(
            executablePath: bin,
            arguments: ["apps", "list", "--device", safeID],
            workingDirectory: workspaceRoot,
            timeoutSeconds: 10
        )
        guard res.exitCode == 0 else {
            throw MobileDeviceBridgeError.commandFailed(command: "mobilecli apps list", exitCode: res.exitCode, stderr: res.stderr)
        }
        return Self.parseAppsListJSON(res.stdout)
    }

    public func captureFastScreenshotOnly(device: MobileDeviceDescriptor, workspaceRoot: URL?) async throws -> Data? {
        let safeID = try Self.validateDeviceIdentifier(device.id)
        let tmpShot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-mobile-fast-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmpShot) }

        if device.platform == .ios && device.type == .simulator && FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") {
            let res = try await runProcess(
                executablePath: "/usr/bin/xcrun",
                arguments: ["simctl", "io", safeID, "screenshot", "--type=jpeg", tmpShot.path],
                workingDirectory: nil,
                timeoutSeconds: 6
            )
            if res.exitCode == 0, let raw = try? Data(contentsOf: tmpShot), raw.count >= 4 {
                return raw
            }
        }

        guard let bin = Self.resolveMobileCLIBinary(workspaceRoot: workspaceRoot) else {
            return nil
        }
        let res = try await runProcess(
            executablePath: bin,
            arguments: ["screenshot", "--device", safeID, "--format", "jpeg", "--quality", "80", "--max-size", "1080", "--output", tmpShot.path],
            workingDirectory: workspaceRoot,
            timeoutSeconds: 12
        )
        if res.exitCode == 0, let raw = try? Data(contentsOf: tmpShot), raw.count >= 4 {
            return raw
        }
        return nil
    }

    public func captureSnapshot(device: MobileDeviceDescriptor, workspaceRoot: URL?) async throws -> MobileScreenSnapshot {
        let safeID = try Self.validateDeviceIdentifier(device.id)
        guard let bin = Self.resolveMobileCLIBinary(workspaceRoot: workspaceRoot) else {
            throw MobileDeviceBridgeError.mobileCLINotFound
        }

        let tmpShot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-mobile-shot-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmpShot) }

        let shotArgs = ["screenshot", "--device", safeID, "--format", "jpeg", "--quality", "85", "--max-size", "1280", "--output", tmpShot.path]
        let uiArgs = ["dump", "ui", "--device", safeID]
        let isIOSSimulator = device.platform == .ios && device.type == .simulator && FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")

        var shotError: Error?
        var shotRes: ProcessOutput?
        var uiError: Error?
        var uiRes: ProcessOutput?
        var pngData: Data? = nil

        if isIOSSimulator {
            // FAST PATH (iOS Simulator): `xcrun simctl io screenshot` (~0.4s) reads CoreSimulator's framebuffer
            // directly and NEVER touches mobilecli's port 130xx RPC server, so it runs safely in parallel with `mobilecli dump ui` (~0.85s total instead of ~4.0s!).
            async let simShotTask = runProcess(
                executablePath: "/usr/bin/xcrun",
                arguments: ["simctl", "io", safeID, "screenshot", "--type=jpeg", tmpShot.path],
                workingDirectory: nil,
                timeoutSeconds: 8
            )
            async let uiDumpTask = runProcess(
                executablePath: bin,
                arguments: uiArgs,
                workingDirectory: workspaceRoot,
                timeoutSeconds: 25
            )

            if let simShot = try? await simShotTask, simShot.exitCode == 0,
               let raw = try? Data(contentsOf: tmpShot), raw.count >= 4 {
                pngData = raw
            }

            do {
                let firstUI = try await uiDumpTask
                if (firstUI.exitCode != 0 || Self.extractMobileCLIErrorMessage(stdout: firstUI.stdout, stderr: "") != nil),
                   Self.isTransientMobileCLIRPCError(stdout: firstUI.stdout, stderr: firstUI.stderr) {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    uiRes = try await runProcess(
                        executablePath: bin,
                        arguments: uiArgs,
                        workingDirectory: workspaceRoot,
                        timeoutSeconds: 25
                    )
                } else {
                    uiRes = firstUI
                }
            } catch {
                uiRes = nil
                uiError = error
            }
        } else {
            // IMPORTANT (Real iOS / Android): Run `mobilecli screenshot` and `mobilecli dump ui` SEQUENTIALLY
            // so two mobilecli processes never race on the device runner's RPC port.
            do {
                let firstShot = try await runProcess(
                    executablePath: bin,
                    arguments: shotArgs,
                    workingDirectory: workspaceRoot,
                    timeoutSeconds: 25
                )
                if firstShot.exitCode != 0,
                   Self.isTransientMobileCLIRPCError(stdout: firstShot.stdout, stderr: firstShot.stderr) {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    shotRes = try await runProcess(
                        executablePath: bin,
                        arguments: shotArgs,
                        workingDirectory: workspaceRoot,
                        timeoutSeconds: 25
                    )
                } else {
                    shotRes = firstShot
                }
            } catch {
                shotRes = nil
                shotError = error
            }

            if let shotRes, shotRes.exitCode == 0, let raw = try? Data(contentsOf: tmpShot), raw.count >= 4 {
                pngData = raw
            }

            do {
                let firstUI = try await runProcess(
                    executablePath: bin,
                    arguments: uiArgs,
                    workingDirectory: workspaceRoot,
                    timeoutSeconds: 25
                )
                if (firstUI.exitCode != 0 || Self.extractMobileCLIErrorMessage(stdout: firstUI.stdout, stderr: "") != nil),
                   Self.isTransientMobileCLIRPCError(stdout: firstUI.stdout, stderr: firstUI.stderr) {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    uiRes = try await runProcess(
                        executablePath: bin,
                        arguments: uiArgs,
                        workingDirectory: workspaceRoot,
                        timeoutSeconds: 25
                    )
                } else {
                    uiRes = firstUI
                }
            } catch {
                uiRes = nil
                uiError = error
            }
        }

        let roots: [MobileAccessibilityNode] = {
            if let ui = uiRes, ui.exitCode == 0, Self.extractMobileCLIErrorMessage(stdout: ui.stdout, stderr: "") == nil {
                return Self.parseDumpUIJSON(ui.stdout)
            }
            return []
        }()

        // Never silently return an empty blank snapshot when both screenshot and UI dump failed!
        if pngData == nil && roots.isEmpty {
            let shotMsg = shotRes.flatMap { Self.extractMobileCLIErrorMessage(stdout: $0.stdout, stderr: $0.stderr) }
            let uiMsg = uiRes.flatMap { Self.extractMobileCLIErrorMessage(stdout: $0.stdout, stderr: $0.stderr) }
            let combinedMsg = shotMsg ?? uiMsg ?? ""
            let lower = combinedMsg.lowercased()
            if lower.contains("agent is not installed") || lower.contains("agent install") || lower.contains("provisioning-profile") {
                throw MobileDeviceBridgeError.agentNotInstalled(
                    deviceId: safeID,
                    platform: device.platform,
                    requiresProvisioningProfile: device.platform == .ios && device.type == .real
                )
            }
            if !combinedMsg.isEmpty {
                throw MobileDeviceBridgeError.commandFailed(
                    command: "mobilecli capture",
                    exitCode: shotRes?.exitCode ?? uiRes?.exitCode ?? 1,
                    stderr: combinedMsg
                )
            }
            if let err = shotError ?? uiError {
                throw err
            }
            throw MobileDeviceBridgeError.invalidResponse("Device did not return a screenshot or UI hierarchy. Unlock the device and retry.")
        }

        let screenInfo = await fetchOrCachedDeviceScreenInfo(deviceId: safeID, bin: bin, workspaceRoot: workspaceRoot)
        let imagePixelSize = pngData.flatMap { Self.extractImagePixelSize(from: $0) }
        let (logicalW, logicalH) = Self.computeSnapshotLogicalSize(
            from: roots,
            platform: device.platform,
            deviceScreenInfo: screenInfo,
            screenshotPixelSize: imagePixelSize
        )
        let orientation: MobileDeviceOrientation = logicalW > logicalH ? .landscape : .portrait

        return MobileScreenSnapshot(
            deviceId: safeID,
            platform: device.platform,
            screenshotPNGData: pngData,
            logicalWidth: logicalW,
            logicalHeight: logicalH,
            orientation: orientation,
            roots: roots
        )
    }

    public func performTap(deviceId: String, x: Double, y: Double, workspaceRoot: URL?) async throws {
        let safeID = try Self.validateDeviceIdentifier(deviceId)
        guard let bin = Self.resolveMobileCLIBinary(workspaceRoot: workspaceRoot) else {
            throw MobileDeviceBridgeError.mobileCLINotFound
        }
        let ix = Int(x.rounded())
        let iy = Int(y.rounded())
        let res = try await runProcess(
            executablePath: bin,
            arguments: ["io", "tap", "\(ix),\(iy)", "--device", safeID],
            workingDirectory: workspaceRoot,
            timeoutSeconds: 10
        )
        if res.exitCode != 0 {
            let errMsg = Self.extractMobileCLIErrorMessage(stdout: res.stdout, stderr: res.stderr) ?? res.stderr
            throw MobileDeviceBridgeError.commandFailed(command: "mobilecli io tap", exitCode: res.exitCode, stderr: errMsg)
        }
    }

    public func performLongPress(deviceId: String, x: Double, y: Double, durationMs: Int = 800, workspaceRoot: URL?) async throws {
        let safeID = try Self.validateDeviceIdentifier(deviceId)
        guard let bin = Self.resolveMobileCLIBinary(workspaceRoot: workspaceRoot) else {
            throw MobileDeviceBridgeError.mobileCLINotFound
        }
        let ix = Int(x.rounded())
        let iy = Int(y.rounded())
        let clampedMs = max(200, min(5000, durationMs))
        let res = try await runProcess(
            executablePath: bin,
            arguments: ["io", "longpress", "\(ix),\(iy)", "--duration", "\(clampedMs)", "--device", safeID],
            workingDirectory: workspaceRoot,
            timeoutSeconds: 12
        )
        if res.exitCode != 0 {
            let errMsg = Self.extractMobileCLIErrorMessage(stdout: res.stdout, stderr: res.stderr) ?? res.stderr
            throw MobileDeviceBridgeError.commandFailed(command: "mobilecli io longpress", exitCode: res.exitCode, stderr: errMsg)
        }
    }

    public func performSwipe(
        deviceId: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationMs: Int = 300,
        workspaceRoot: URL?
    ) async throws {
        let safeID = try Self.validateDeviceIdentifier(deviceId)
        guard let bin = Self.resolveMobileCLIBinary(workspaceRoot: workspaceRoot) else {
            throw MobileDeviceBridgeError.mobileCLINotFound
        }
        let x1 = Int(fromX.rounded())
        let y1 = Int(fromY.rounded())
        let x2 = Int(toX.rounded())
        let y2 = Int(toY.rounded())
        let clampedMs = max(80, min(3000, durationMs))
        let res = try await runProcess(
            executablePath: bin,
            arguments: ["io", "swipe", "\(x1),\(y1),\(x2),\(y2)", "--duration", "\(clampedMs)", "--device", safeID],
            workingDirectory: workspaceRoot,
            timeoutSeconds: 12
        )
        if res.exitCode != 0 {
            let errMsg = Self.extractMobileCLIErrorMessage(stdout: res.stdout, stderr: res.stderr) ?? res.stderr
            throw MobileDeviceBridgeError.commandFailed(command: "mobilecli io swipe", exitCode: res.exitCode, stderr: errMsg)
        }
    }

    public func performTypeText(deviceId: String, text: String, workspaceRoot: URL?) async throws {
        let safeID = try Self.validateDeviceIdentifier(deviceId)
        guard let bin = Self.resolveMobileCLIBinary(workspaceRoot: workspaceRoot) else {
            throw MobileDeviceBridgeError.mobileCLINotFound
        }
        let res = try await runProcess(
            executablePath: bin,
            arguments: ["io", "text", text, "--device", safeID],
            workingDirectory: workspaceRoot,
            timeoutSeconds: 6
        )
        if res.exitCode != 0 {
            throw MobileDeviceBridgeError.commandFailed(command: "mobilecli io text", exitCode: res.exitCode, stderr: res.stderr)
        }
    }

    public func performHardwareButton(deviceId: String, button: String, workspaceRoot: URL?) async throws {
        let safeID = try Self.validateDeviceIdentifier(deviceId)
        let allowedButtons: Set<String> = ["HOME", "BACK", "ENTER", "VOLUME_UP", "VOLUME_DOWN", "LOCK"]
        let upper = button.uppercased()
        guard allowedButtons.contains(upper) else {
            throw MobileDeviceBridgeError.invalidResponse("Unsupported hardware button '\(button)'")
        }
        guard let bin = Self.resolveMobileCLIBinary(workspaceRoot: workspaceRoot) else {
            throw MobileDeviceBridgeError.mobileCLINotFound
        }
        let res = try await runProcess(
            executablePath: bin,
            arguments: ["io", "button", upper, "--device", safeID],
            workingDirectory: workspaceRoot,
            timeoutSeconds: 6
        )
        if res.exitCode != 0 {
            throw MobileDeviceBridgeError.commandFailed(command: "mobilecli io button", exitCode: res.exitCode, stderr: res.stderr)
        }
    }

    public func setOrientation(deviceId: String, orientation: MobileDeviceOrientation, workspaceRoot: URL?) async throws {
        let safeID = try Self.validateDeviceIdentifier(deviceId)
        guard let bin = Self.resolveMobileCLIBinary(workspaceRoot: workspaceRoot) else {
            throw MobileDeviceBridgeError.mobileCLINotFound
        }
        let res = try await runProcess(
            executablePath: bin,
            arguments: ["device", "orientation", "set", orientation.rawValue.lowercased(), "--device", safeID],
            workingDirectory: workspaceRoot,
            timeoutSeconds: 6
        )
        if res.exitCode != 0 {
            throw MobileDeviceBridgeError.commandFailed(command: "mobilecli device orientation", exitCode: res.exitCode, stderr: res.stderr)
        }
    }

    // MARK: - Pure JSON & Doctor Output Parsers (Testable Offline)

    public static func parseMobileCLIDevicesJSON(_ raw: String) -> [MobileDeviceDescriptor] {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let list: [[String: Any]]
        if let dataObj = root["data"] as? [String: Any], let devs = dataObj["devices"] as? [[String: Any]] {
            list = devs
        } else if let devs = root["devices"] as? [[String: Any]] {
            list = devs
        } else {
            return []
        }

        return list.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let rawName = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (rawName?.isEmpty == false) ? rawName! : id
            let platStr = ((entry["platform"] as? String) ?? "android").lowercased()
            let platform: MobilePlatform = platStr == "ios" ? .ios : .android
            let typeStr = ((entry["type"] as? String) ?? "real").lowercased()
            let type: MobileDeviceType = {
                switch typeStr {
                case "simulator": return .simulator
                case "emulator": return .emulator
                default: return .real
                }
            }()
            let stateStr = ((entry["state"] as? String) ?? "online").lowercased()
            let state: MobileDeviceState = {
                switch stateStr {
                case "online": return .online
                case "booted": return .booted
                case "shutdown": return .shutdown
                case "unauthorized": return .unauthorized
                default: return .offline
                }
            }()
            let version = (entry["version"] as? String) ?? (entry["osVersion"] as? String)
            return MobileDeviceDescriptor(
                id: id,
                name: name,
                platform: platform,
                type: type,
                state: state,
                osVersion: version
            )
        }
    }

    public static func parseSimctlDevicesJSON(_ raw: String) -> [MobileDeviceDescriptor] {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: [[String: Any]]] else {
            return []
        }

        var results: [MobileDeviceDescriptor] = []
        for (runtimeKey, list) in devicesByRuntime.sorted(by: { $0.key > $1.key }) {
            guard runtimeKey.lowercased().contains("ios") else { continue }
            let osLabel = runtimeKey
                .components(separatedBy: ".").last?
                .replacingOccurrences(of: "iOS-", with: "iOS ")
                .replacingOccurrences(of: "-", with: ".")
            for item in list {
                let isAvailable = (item["isAvailable"] as? Bool) ?? true
                guard isAvailable,
                      let udid = item["udid"] as? String,
                      let name = item["name"] as? String else { continue }
                let rawState = ((item["state"] as? String) ?? "Shutdown").lowercased()
                let state: MobileDeviceState = rawState == "booted" ? .booted : .shutdown
                results.append(MobileDeviceDescriptor(
                    id: udid,
                    name: name,
                    platform: .ios,
                    type: .simulator,
                    state: state,
                    osVersion: osLabel
                ))
            }
        }
        return results.sorted { lhs, rhs in
            if lhs.state.isReady != rhs.state.isReady { return lhs.state.isReady }
            let lhsIsPhone = lhs.name.lowercased().contains("iphone")
            let rhsIsPhone = rhs.name.lowercased().contains("iphone")
            if lhsIsPhone != rhsIsPhone { return lhsIsPhone }
            let lhsVer = lhs.osVersion ?? ""
            let rhsVer = rhs.osVersion ?? ""
            if lhsVer != rhsVer {
                return lhsVer.localizedStandardCompare(rhsVer) == .orderedDescending
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public static func parseAppsListJSON(_ raw: String) -> [MobileInstalledApp] {
        guard let jsonStart = raw.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let data = String(raw[jsonStart...]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        let entries: [[String: Any]]
        if let dict = obj as? [String: Any] {
            if let dataArr = dict["data"] as? [[String: Any]] {
                entries = dataArr
            } else if let dataDict = dict["data"] as? [String: Any], let apps = dataDict["apps"] as? [[String: Any]] {
                entries = apps
            } else if let apps = dict["apps"] as? [[String: Any]] {
                entries = apps
            } else {
                entries = []
            }
        } else if let arr = obj as? [[String: Any]] {
            entries = arr
        } else {
            entries = []
        }
        return entries.compactMap { item in
            let bundleId = (item["bundleId"] as? String)
                ?? (item["packageName"] as? String)
                ?? (item["id"] as? String)
            guard let bundleId, !bundleId.isEmpty else { return nil }
            let name = (item["appName"] as? String)
                ?? (item["name"] as? String)
                ?? (item["displayName"] as? String)
            return MobileInstalledApp(bundleId: bundleId, name: name)
        }.sorted { $0.bundleId < $1.bundleId }
    }

    private func fetchOrCachedDeviceScreenInfo(
        deviceId: String,
        bin: String,
        workspaceRoot: URL?
    ) async -> MobileDeviceScreenInfo? {
        if let cached = Self.screenInfoLock.withLock({ Self.cachedScreenInfos[deviceId] }) {
            return cached
        }
        guard let res = try? await runProcess(
            executablePath: bin,
            arguments: ["device", "info", "--device", deviceId],
            workingDirectory: workspaceRoot,
            timeoutSeconds: 6
        ), res.exitCode == 0,
        let parsed = Self.parseDeviceInfoScreenSizeJSON(res.stdout) else {
            return nil
        }
        Self.screenInfoLock.withLock {
            Self.cachedScreenInfos[deviceId] = parsed
        }
        return parsed
    }

    public static func parseDeviceInfoScreenSizeJSON(_ raw: String) -> MobileDeviceScreenInfo? {
        guard let jsonStart = raw.firstIndex(of: "{"),
              let data = String(raw[jsonStart...]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let devDict: [String: Any]? = {
            if let dataObj = root["data"] as? [String: Any] {
                return (dataObj["device"] as? [String: Any]) ?? dataObj
            }
            return (root["device"] as? [String: Any]) ?? root
        }()
        guard let screenSize = devDict?["screenSize"] as? [String: Any],
              let w = (screenSize["width"] as? NSNumber)?.doubleValue,
              let h = (screenSize["height"] as? NSNumber)?.doubleValue,
              w > 100, h > 100 else {
            return nil
        }
        let scale = (screenSize["scale"] as? NSNumber)?.doubleValue ?? 1.0
        return MobileDeviceScreenInfo(width: w, height: h, scale: scale)
    }

    public static func extractImagePixelSize(from data: Data) -> (width: Double, height: Double)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let ph = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              pw > 10, ph > 10 else {
            return nil
        }
        return (pw, ph)
    }

    /// Computes the exact 1:1 logical/pixel viewport dimensions of the device screen so floating modals,
    /// iOS system alerts (`Allow "Calendar" to access your contacts?`), keyboards, and multi-window Android
    /// hierarchies map every accessibility bounding rectangle onto the screenshot with sub-pixel accuracy.
    public static func computeSnapshotLogicalSize(
        from roots: [MobileAccessibilityNode],
        platform: MobilePlatform,
        deviceScreenInfo: MobileDeviceScreenInfo? = nil,
        screenshotPixelSize: (width: Double, height: Double)? = nil
    ) -> (width: Double, height: Double) {
        let maxRight = roots.map { $0.bounds.x + $0.bounds.width }.max() ?? 0
        let maxBottom = roots.map { $0.bounds.y + $0.bounds.height }.max() ?? 0

        // 1. Authoritative hardware screen dimensions from `mobilecli device info` (e.g., iPhone 17 = 402×874 @3x, Android = 1080×2400)
        if let info = deviceScreenInfo, info.width > 100, info.height > 100 {
            let shortSide = min(info.width, info.height)
            let longSide = max(info.width, info.height)
            let isLandscape: Bool
            if let px = screenshotPixelSize {
                isLandscape = px.width > px.height
            } else if maxRight > 100 && maxBottom > 100 {
                isLandscape = maxRight > maxBottom * 1.08
            } else {
                isLandscape = info.width > info.height
            }
            return isLandscape ? (longSide, shortSide) : (shortSide, longSide)
        }

        // 2. Calibrate directly from screenshot pixel dimensions when `device info` isn't cached yet
        if let px = screenshotPixelSize, px.width > 100, px.height > 100 {
            if platform == .ios {
                let pxMax = max(px.width, px.height)
                let rootMax = max(maxRight, maxBottom)
                let inferredScale: Double
                if rootMax > 100 && rootMax <= pxMax / 2.35 {
                    inferredScale = 3.0
                } else if rootMax > 100 && rootMax <= pxMax / 1.55 {
                    inferredScale = 2.0
                } else if pxMax >= 2000 {
                    inferredScale = 3.0
                } else if pxMax >= 1300 {
                    inferredScale = 2.0
                } else {
                    inferredScale = 1.0
                }
                return ((px.width / inferredScale).rounded(), (px.height / inferredScale).rounded())
            } else {
                // On Android, uiautomator bounds use full display pixels; preserve exact screenshot aspect ratio
                let aspect = px.width / px.height
                if maxRight > 100 || maxBottom > 100 {
                    let w = max(maxRight, maxBottom * aspect)
                    let h = w / aspect
                    return (w.rounded(), h.rounded())
                }
                return (px.width, px.height)
            }
        }

        // 3. Pure tree fallback (offline / mock tests without screenshot data)
        let defaultSize: (Double, Double) = platform == .ios ? (393, 852) : (412, 915)
        guard !roots.isEmpty else { return defaultSize }
        let logicalW = maxRight > 100 ? maxRight : defaultSize.0
        let logicalH = maxBottom > 100 ? maxBottom : defaultSize.1
        return (logicalW, logicalH)
    }

    public static func extractMobileCLIErrorMessage(stdout: String, stderr: String) -> String? {
        if let jsonStart = stdout.firstIndex(of: "{"),
           let data = String(stdout[jsonStart...]).data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let status = (dict["status"] as? String)?.lowercased() ?? ""
            if status == "error" || status == "fail" {
                if let err = dict["error"] as? String, !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return err.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let dataDict = dict["data"] as? [String: Any],
                   let msg = dataDict["message"] as? String, !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return msg.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let msg = dict["message"] as? String, !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return msg.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        let cleanErr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanErr.isEmpty ? nil : cleanErr
    }

    public static func parseDumpUIJSON(_ raw: String) -> [MobileAccessibilityNode] {
        guard let jsonStart = raw.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let data = String(raw[jsonStart...]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        var rawNodes: [[String: Any]] = []
        if let dict = obj as? [String: Any] {
            let status = (dict["status"] as? String)?.lowercased() ?? ""
            if status == "error" || status == "fail" {
                return []
            }
            if let dataDict = dict["data"] as? [String: Any] {
                if let elements = dataDict["elements"] as? [[String: Any]] {
                    rawNodes = elements
                } else if let tree = dataDict["tree"] as? [[String: Any]] {
                    rawNodes = tree
                } else if let nodes = dataDict["nodes"] as? [[String: Any]] {
                    rawNodes = nodes
                } else if let ui = dataDict["ui"] as? [[String: Any]] {
                    rawNodes = ui
                } else if let root = dataDict["root"] as? [String: Any] {
                    rawNodes = [root]
                } else if let uiRoot = dataDict["ui"] as? [String: Any] {
                    rawNodes = [uiRoot]
                }
            } else if let elements = dict["elements"] as? [[String: Any]] {
                rawNodes = elements
            } else if dict["type"] != nil || dict["children"] != nil {
                rawNodes = [dict]
            }
        } else if let arr = obj as? [[String: Any]] {
            rawNodes = arr
        }
        var counter = 0
        return rawNodes.map { convertRawNode($0, counter: &counter) }
    }

    private static func convertRawNode(_ dict: [String: Any], counter: inout Int) -> MobileAccessibilityNode {
        counter += 1
        let nodeId = "node-\(counter)"
        let type = (dict["type"] as? String) ?? (dict["class"] as? String) ?? (dict["elementType"] as? String) ?? "View"
        let role = dict["role"] as? String
        let identifier = (dict["identifier"] as? String)
            ?? (dict["resourceId"] as? String)
            ?? (dict["accessibilityIdentifier"] as? String)
            ?? (dict["resource-id"] as? String)
        let testId = (dict["testId"] as? String) ?? (dict["testID"] as? String)
        let label = (dict["label"] as? String) ?? (dict["contentDesc"] as? String) ?? (dict["content-desc"] as? String) ?? (dict["name"] as? String)
        let text = (dict["text"] as? String) ?? (dict["title"] as? String)
        let value = dict["value"] as? String
        let placeholder = (dict["placeholder"] as? String) ?? (dict["placeholderValue"] as? String) ?? (dict["hint"] as? String)

        let rectDict = (dict["bounds"] as? [String: Any])
            ?? (dict["rect"] as? [String: Any])
            ?? (dict["frame"] as? [String: Any])
            ?? [:]
        let bounds = MobileNodeBounds(
            x: (rectDict["x"] as? NSNumber)?.doubleValue ?? 0,
            y: (rectDict["y"] as? NSNumber)?.doubleValue ?? 0,
            width: (rectDict["width"] as? NSNumber)?.doubleValue ?? 0,
            height: (rectDict["height"] as? NSNumber)?.doubleValue ?? 0
        )

        let isVisible = (dict["isVisible"] as? Bool) ?? (dict["visible"] as? Bool) ?? (bounds.width > 0 && bounds.height > 0)
        let isEnabled = (dict["isEnabled"] as? Bool) ?? (dict["enabled"] as? Bool) ?? true
        let isChecked = (dict["isChecked"] as? Bool) ?? (dict["checked"] as? Bool) ?? false
        let isSecure = (dict["isSecure"] as? Bool) ?? (dict["secure"] as? Bool) ?? type.lowercased().contains("secure")

        let rawChildren = (dict["children"] as? [[String: Any]]) ?? []
        var children = rawChildren.map { convertRawNode($0, counter: &counter) }

        // Collapse redundant 1:1 identical XCUITest leaf wrappers (e.g., iOS Alert `Button` containing an identical `Button`)
        if children.count == 1,
           let only = children.first,
           only.children.isEmpty,
           only.type == type,
           only.label == label,
           only.identifier == identifier,
           only.text == text,
           abs(only.bounds.x - bounds.x) <= 1.5,
           abs(only.bounds.y - bounds.y) <= 1.5,
           abs(only.bounds.width - bounds.width) <= 1.5,
           abs(only.bounds.height - bounds.height) <= 1.5 {
            children = []
        }

        return MobileAccessibilityNode(
            id: nodeId,
            type: type,
            role: role,
            identifier: identifier,
            testId: testId,
            label: label,
            text: text,
            value: value,
            placeholder: placeholder,
            isVisible: isVisible,
            isEnabled: isEnabled,
            isChecked: isChecked,
            isSecure: isSecure,
            bounds: bounds,
            children: children
        )
    }

    public static func parseDoctorOutput(_ raw: String) -> [MobileDoctorCheckItem] {
        var currentCategory = "System"
        var items: [MobileDoctorCheckItem] = []
        let lines = raw.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("─") || trimmed.hasPrefix("mobilewright doctor") || trimmed.hasPrefix("Summary") {
                continue
            }
            if ["System", "iOS", "Android"].contains(trimmed) {
                currentCategory = trimmed
                continue
            }
            let status: MobileDoctorStatus?
            let rest: String
            if trimmed.hasPrefix("✓") {
                status = .ok
                rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("⚠") {
                status = .warning
                rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("✗") {
                status = .error
                rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else {
                status = nil
                rest = ""
            }
            guard let status, !rest.isEmpty else { continue }

            // Split name and detail on double spaces if present
            let parts = rest.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let name = parts.first ?? rest
            let detail = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : ""

            // Look ahead up to 4 lines for a `→ <command>` hint
            var remediation: String? = nil
            var look = index + 1
            while look < min(lines.count, index + 6) {
                let nextTrimmed = lines[look].trimmingCharacters(in: .whitespaces)
                if nextTrimmed.hasPrefix("✓") || nextTrimmed.hasPrefix("⚠") || nextTrimmed.hasPrefix("✗") || ["System", "iOS", "Android"].contains(nextTrimmed) {
                    break
                }
                if nextTrimmed.hasPrefix("→") {
                    remediation = String(nextTrimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                    break
                }
                look += 1
            }

            items.append(MobileDoctorCheckItem(
                category: currentCategory,
                name: name,
                status: status,
                detail: detail.isEmpty ? (status == .ok ? "Ready" : "Needs attention") : detail,
                remediationCommand: remediation
            ))
        }
        return items
    }

    // MARK: - Bounded Direct Process Execution (Threat T-01, T-02, T-05)

    private struct ProcessOutput: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL?,
        timeoutSeconds: Double
    ) async throws -> ProcessOutput {
        let env = Self.sanitizedEnvironment(workspaceRoot: workingDirectory)
        return try await withCheckedThrowingContinuation { continuation in
            let workQueue = DispatchQueue(label: "com.kobenguyent.ceptra.mobilebridge.work", qos: .userInitiated, attributes: .concurrent)
            let timerQueue = DispatchQueue(label: "com.kobenguyent.ceptra.mobilebridge.timer", qos: .utility)

            workQueue.async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executablePath)
                proc.arguments = arguments
                proc.environment = env
                if let workingDirectory {
                    proc.currentDirectoryURL = workingDirectory
                }
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                let lock = NSLock()
                var finished = false
                let finishOnce: (Result<ProcessOutput, Error>) -> Void = { result in
                    lock.lock()
                    defer { lock.unlock() }
                    guard !finished else { return }
                    finished = true
                    continuation.resume(with: result)
                }

                // Dedicated timer queue so waitUntilExit() never blocks timeout firing
                let timer = DispatchSource.makeTimerSource(queue: timerQueue)
                timer.schedule(deadline: .now() + timeoutSeconds)
                timer.setEventHandler {
                    if proc.isRunning {
                        proc.terminate()
                    }
                    let cmdName = URL(fileURLWithPath: executablePath).lastPathComponent
                    finishOnce(.failure(MobileDeviceBridgeError.timedOut(command: cmdName, seconds: timeoutSeconds)))
                }
                timer.resume()

                do {
                    try proc.run()
                    // Drain stdout and stderr concurrently to avoid 64KB pipe deadlocks
                    let ioGroup = DispatchGroup()
                    var outData = Data()
                    var errData = Data()

                    ioGroup.enter()
                    workQueue.async {
                        outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                        ioGroup.leave()
                    }
                    ioGroup.enter()
                    workQueue.async {
                        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        ioGroup.leave()
                    }

                    proc.waitUntilExit()
                    ioGroup.wait()
                    timer.cancel()

                    let stdout = String(data: outData, encoding: .utf8) ?? ""
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    finishOnce(.success(ProcessOutput(exitCode: proc.terminationStatus, stdout: stdout, stderr: stderr)))
                } catch {
                    timer.cancel()
                    finishOnce(.failure(error))
                }
            }
        }
    }
}

/// Deterministic offline transport for XCTest and instant preview mode without physical hardware.
public final class MockMobileDeviceTransport: MobileDeviceTransport, @unchecked Sendable {
    public var devices: [MobileDeviceDescriptor]
    public var doctorReport: MobileDoctorReport
    public var installedApps: [MobileInstalledApp]
    public var snapshot: MobileScreenSnapshot
    public var agentInstalledIds: Set<String>
    public var recordedCalls: [String] = []

    public init(
        devices: [MobileDeviceDescriptor] = [
            MobileDeviceDescriptor(id: "3FC4BE9A-D2FE-4B5B-98E6-8BC9A06C1883", name: "iPhone 17 Pro", platform: .ios, type: .simulator, state: .booted, osVersion: "iOS 26.3", agentInstalled: true),
            MobileDeviceDescriptor(id: "39241FDJH0028", name: "Pixel 8", platform: .android, type: .real, state: .online, osVersion: "Android 15", agentInstalled: true)
        ],
        doctorReport: MobileDoctorReport = MobileDoctorReport(checks: [
            MobileDoctorCheckItem(category: "System", name: "Node.js", status: .ok, detail: "v22.22.3"),
            MobileDoctorCheckItem(category: "System", name: "mobilecli", status: .ok, detail: "v1.0.17"),
            MobileDoctorCheckItem(category: "iOS", name: "Xcode", status: .ok, detail: "26.5"),
            MobileDoctorCheckItem(category: "Android", name: "ADB (Android Debug Bridge)", status: .ok, detail: "Installed")
        ]),
        installedApps: [MobileInstalledApp] = [
            MobileInstalledApp(bundleId: "com.saucelabs.mydemoapp.rn", name: "Sauce Labs Demo Store"),
            MobileInstalledApp(bundleId: "com.apple.Preferences", name: "Settings")
        ],
        snapshot: MobileScreenSnapshot = MockMobileDeviceTransport.sampleSnapshot()
    ) {
        self.devices = devices
        self.doctorReport = doctorReport
        self.installedApps = installedApps
        self.snapshot = snapshot
        self.agentInstalledIds = Set(devices.filter { $0.agentInstalled == true }.map(\.id))
    }

    public static func sampleSnapshot(platform: MobilePlatform = .ios, orientation: MobileDeviceOrientation = .portrait) -> MobileScreenSnapshot {
        let preset = platform == .ios
            ? MobileResolutionPreset.preset(id: "iphone-17-pro")
            : MobileResolutionPreset.preset(id: "pixel-8")
        return sampleSnapshot(preset: preset, orientation: orientation)
    }

    public static func sampleSnapshot(
        preset: MobileResolutionPreset,
        orientation: MobileDeviceOrientation = .portrait,
        cartCount: Int = 1,
        usernameValue: String = "",
        passwordFilled: Bool = false
    ) -> MobileScreenSnapshot {
        let platform = preset.platform
        let size = preset.logicalSize(for: orientation)
        let w = Double(size.width)
        let h = Double(size.height)
        let isLandscape = orientation == .landscape
        let pad: Double = preset.isTablet ? 32 : 18

        let rootType = platform == .ios ? "XCUIElementTypeApplication" : "android.widget.FrameLayout"
        let navType = platform == .ios ? "XCUIElementTypeNavigationBar" : "android.view.ViewGroup"
        let scrollType = platform == .ios ? "XCUIElementTypeScrollView" : "android.widget.ScrollView"
        let btnType = platform == .ios ? "XCUIElementTypeButton" : "android.widget.Button"
        let txtType = platform == .ios ? "XCUIElementTypeStaticText" : "android.widget.TextView"
        let fldType = platform == .ios ? "XCUIElementTypeTextField" : "android.widget.EditText"
        let secType = platform == .ios ? "XCUIElementTypeSecureTextField" : "android.widget.EditText"

        let topBarY: Double = isLandscape ? 32 : (platform == .ios ? 54 : 44)
        let topBarH: Double = 38
        let footerH: Double = isLandscape ? 46 : 52
        let bottomInset: Double = isLandscape ? 22 : (platform == .ios ? 36 : 44)
        let ctaY = h - bottomInset - footerH

        let contentTop = topBarY + topBarH + 14
        let contentW = w - pad * 2

        let cardBounds: MobileNodeBounds
        let userBounds: MobileNodeBounds
        let passBounds: MobileNodeBounds

        if isLandscape {
            let leftW = (contentW - 16) * 0.52
            let rightX = pad + leftW + 16
            let rightW = contentW - leftW - 16
            let cardH = max(120, ctaY - contentTop - 14)
            cardBounds = MobileNodeBounds(x: pad, y: contentTop, width: leftW, height: cardH)
            userBounds = MobileNodeBounds(x: rightX, y: contentTop + 8, width: rightW, height: 46)
            passBounds = MobileNodeBounds(x: rightX, y: contentTop + 66, width: rightW, height: 46)
        } else {
            let availMid = max(240, ctaY - contentTop - 16)
            let fieldH: Double = 46
            let fieldGap: Double = 12
            let cardH = min(max(190, availMid - (fieldH * 2 + fieldGap + 38)), preset.isTablet ? 440 : 300)
            cardBounds = MobileNodeBounds(x: pad, y: contentTop, width: contentW, height: cardH)
            let formY = contentTop + cardH + 20
            userBounds = MobileNodeBounds(x: pad, y: formY, width: contentW, height: fieldH)
            passBounds = MobileNodeBounds(x: pad, y: formY + fieldH + fieldGap, width: contentW, height: fieldH)
        }

        let navNode = MobileAccessibilityNode(
            id: "node-nav",
            type: navType,
            role: "other",
            label: "Navigation Bar",
            bounds: MobileNodeBounds(x: 0, y: topBarY, width: w, height: topBarH),
            children: [
                MobileAccessibilityNode(
                    id: "node-2",
                    type: txtType,
                    role: "header",
                    label: "Products",
                    text: "Products",
                    bounds: MobileNodeBounds(x: pad, y: topBarY + 3, width: 132, height: 32)
                ),
                MobileAccessibilityNode(
                    id: "node-cart",
                    type: btnType,
                    role: "button",
                    identifier: "com.saucelabs:id/cartBadge",
                    testId: "cart badge",
                    label: "cart badge",
                    text: "Cart \(cartCount)",
                    bounds: MobileNodeBounds(x: w - pad - 184, y: topBarY + 4, width: 80, height: 30)
                ),
                MobileAccessibilityNode(
                    id: "node-3",
                    type: btnType,
                    role: "button",
                    identifier: "com.saucelabs:id/resetBtn",
                    testId: "longpress reset app",
                    label: "longpress reset app",
                    text: "Reset App",
                    bounds: MobileNodeBounds(x: w - pad - 96, y: topBarY + 4, width: 96, height: 30)
                )
            ]
        )

        let bodyNode = MobileAccessibilityNode(
            id: "node-scroll",
            type: scrollType,
            role: "other",
            label: "Product & Checkout Form",
            bounds: MobileNodeBounds(x: pad, y: contentTop, width: contentW, height: max(120, ctaY - contentTop - 10)),
            children: [
                MobileAccessibilityNode(
                    id: "node-4",
                    type: btnType,
                    role: "button",
                    identifier: "com.saucelabs:id/storeBtn",
                    testId: "store item backpack",
                    label: "Sauce Labs Backpack",
                    text: "Sauce Labs Backpack",
                    value: "$29.99",
                    bounds: cardBounds
                ),
                MobileAccessibilityNode(
                    id: "node-5",
                    type: fldType,
                    role: "textfield",
                    identifier: "com.saucelabs:id/username",
                    testId: "Username input field",
                    label: "Username input field",
                    text: usernameValue.isEmpty ? nil : usernameValue,
                    value: usernameValue.isEmpty ? nil : usernameValue,
                    placeholder: "bob@example.com",
                    bounds: userBounds
                ),
                MobileAccessibilityNode(
                    id: "node-6",
                    type: secType,
                    role: "textfield",
                    identifier: "com.saucelabs:id/password",
                    testId: "Password input field",
                    label: "Password input field",
                    value: passwordFilled ? "••••••••" : nil,
                    placeholder: "Password",
                    isSecure: true,
                    bounds: passBounds
                )
            ]
        )

        let addToCartNode = MobileAccessibilityNode(
            id: "node-7",
            type: btnType,
            role: "button",
            identifier: "com.saucelabs:id/addToCart",
            testId: "Add To Cart button",
            label: "Add To Cart button",
            text: cartCount > 1 ? "Added to Cart (\(cartCount))" : "Add To Cart",
            bounds: MobileNodeBounds(x: pad, y: ctaY, width: contentW, height: footerH)
        )

        let root = MobileAccessibilityNode(
            id: "node-1",
            type: rootType,
            role: "window",
            label: "Sauce Labs Demo Store",
            bounds: MobileNodeBounds(x: 0, y: 0, width: w, height: h),
            children: [navNode, bodyNode, addToCartNode]
        )
        return MobileScreenSnapshot(
            deviceId: "mock-device",
            platform: platform,
            screenshotPNGData: nil,
            logicalWidth: w,
            logicalHeight: h,
            orientation: orientation,
            roots: [root]
        )
    }

    public func listDevices(workspaceRoot: URL?) async throws -> [MobileDeviceDescriptor] {
        recordedCalls.append("listDevices")
        return devices
    }

    public func listXcodeSimulators() async throws -> [MobileDeviceDescriptor] {
        recordedCalls.append("listXcodeSimulators")
        return devices.filter { $0.type == .simulator }
    }

    public func bootXcodeSimulator(udid: String) async throws {
        _ = try MobileCLIDeviceBridge.validateDeviceIdentifier(udid)
        recordedCalls.append("boot:\(udid)")
    }

    public func runDoctor(workspaceRoot: URL?) async -> MobileDoctorReport {
        recordedCalls.append("runDoctor")
        return doctorReport
    }

    public func checkAgentStatus(deviceId: String, workspaceRoot: URL?) async throws -> Bool {
        let safeID = try MobileCLIDeviceBridge.validateDeviceIdentifier(deviceId)
        recordedCalls.append("agentStatus:\(safeID)")
        return agentInstalledIds.contains(safeID)
    }

    public func installAgent(deviceId: String, provisioningProfileURL: URL?, workspaceRoot: URL?) async throws {
        let safeID = try MobileCLIDeviceBridge.validateDeviceIdentifier(deviceId)
        if let provisioningProfileURL {
            _ = try MobileCLIDeviceBridge.validateProvisioningProfileURL(provisioningProfileURL)
        }
        recordedCalls.append("installAgent:\(safeID)")
        agentInstalledIds.insert(safeID)
    }

    public func listInstalledApps(deviceId: String, workspaceRoot: URL?) async throws -> [MobileInstalledApp] {
        let safeID = try MobileCLIDeviceBridge.validateDeviceIdentifier(deviceId)
        recordedCalls.append("listApps:\(safeID)")
        return installedApps
    }

    public func captureSnapshot(device: MobileDeviceDescriptor, workspaceRoot: URL?) async throws -> MobileScreenSnapshot {
        let safeID = try MobileCLIDeviceBridge.validateDeviceIdentifier(device.id)
        recordedCalls.append("snapshot:\(safeID)")
        return snapshot
    }

    public func captureFastScreenshotOnly(device: MobileDeviceDescriptor, workspaceRoot: URL?) async throws -> Data? {
        let safeID = try MobileCLIDeviceBridge.validateDeviceIdentifier(device.id)
        recordedCalls.append("fastScreenshot:\(safeID)")
        return snapshot.screenshotPNGData
    }

    public func performTap(deviceId: String, x: Double, y: Double, workspaceRoot: URL?) async throws {
        let safeID = try MobileCLIDeviceBridge.validateDeviceIdentifier(deviceId)
        recordedCalls.append("tap:\(safeID):\(Int(x)),\(Int(y))")
    }

    public func performLongPress(deviceId: String, x: Double, y: Double, durationMs: Int, workspaceRoot: URL?) async throws {
        let safeID = try MobileCLIDeviceBridge.validateDeviceIdentifier(deviceId)
        recordedCalls.append("longpress:\(safeID):\(Int(x)),\(Int(y)):\(durationMs)")
    }

    public func performSwipe(deviceId: String, fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int, workspaceRoot: URL?) async throws {
        let safeID = try MobileCLIDeviceBridge.validateDeviceIdentifier(deviceId)
        recordedCalls.append("swipe:\(safeID):\(Int(fromX)),\(Int(fromY)),\(Int(toX)),\(Int(toY)):\(durationMs)")
    }

    public func performTypeText(deviceId: String, text: String, workspaceRoot: URL?) async throws {
        let safeID = try MobileCLIDeviceBridge.validateDeviceIdentifier(deviceId)
        recordedCalls.append("type:\(safeID):\(text.count)")
    }

    public func performHardwareButton(deviceId: String, button: String, workspaceRoot: URL?) async throws {
        let safeID = try MobileCLIDeviceBridge.validateDeviceIdentifier(deviceId)
        recordedCalls.append("button:\(safeID):\(button)")
    }

    public func setOrientation(deviceId: String, orientation: MobileDeviceOrientation, workspaceRoot: URL?) async throws {
        let safeID = try MobileCLIDeviceBridge.validateDeviceIdentifier(deviceId)
        recordedCalls.append("orientation:\(safeID):\(orientation.rawValue)")
    }
}
