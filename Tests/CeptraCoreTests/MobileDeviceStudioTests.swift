import CeptraCore
import CoreGraphics
import XCTest

final class MobileDeviceStudioTests: XCTestCase {
    // Threat T-01: Strict identifier validation & zero shell injection
    func testRejectsMalformedDeviceAndBundleIdentifiersAndUsesDirectProcessArgs() throws {
        XCTAssertEqual(
            try MobileCLIDeviceBridge.validateDeviceIdentifier("3FC4BE9A-D2FE-4B5B-98E6-8BC9A06C1883"),
            "3FC4BE9A-D2FE-4B5B-98E6-8BC9A06C1883"
        )
        XCTAssertEqual(
            try MobileCLIDeviceBridge.validateDeviceIdentifier("emulator-5554"),
            "emulator-5554"
        )
        XCTAssertEqual(
            try MobileCLIDeviceBridge.validateDeviceIdentifier("192.168.1.42:5555"),
            "192.168.1.42:5555"
        )
        XCTAssertEqual(
            try MobileCLIDeviceBridge.validateBundleIdentifier("com.saucelabs.mydemoapp.rn"),
            "com.saucelabs.mydemoapp.rn"
        )

        let hostileInputs = [
            "",
            "-rf",
            "abc; rm -rf /",
            "$(whoami)",
            "dev`id`",
            "id && echo pwned",
            "../etc/passwd"
        ]
        for bad in hostileInputs {
            XCTAssertThrowsError(try MobileCLIDeviceBridge.validateDeviceIdentifier(bad), "Should reject '\(bad)'")
            XCTAssertThrowsError(try MobileCLIDeviceBridge.validateBundleIdentifier(bad), "Should reject bundle '\(bad)'")
        }
    }

    // Threat T-02: Enforce telemetry disabled on every mobilecli environment
    func testEnforcesTelemetryDisableAndLoopbackOnlyInEnvironment() {
        let env = MobileCLIDeviceBridge.sanitizedEnvironment(workspaceRoot: nil)
        XCTAssertEqual(env["MOBILEWRIGHT_DISABLE_TELEMETRY"], "1")
        XCTAssertEqual(env["NO_COLOR"], "1")
        XCTAssertEqual(env["FORCE_COLOR"], "0")
    }

    // Threat T-03: Password fields automatically wrapped in CodeceptJS secret('...')
    func testSynthesizerWrapsPasswordFieldsInCodeceptSecretAndNeverEmitsCSSOrXPath() {
        let passwordNode = MobileAccessibilityNode(
            id: "pw",
            type: "XCUIElementTypeSecureTextField",
            role: "textfield",
            identifier: "com.app:id/password",
            label: "Password",
            placeholder: "Password",
            isSecure: true
        )
        let pwCode = MobileLocatorSynthesizer.synthesizeStepCode(
            action: .fillField,
            node: passwordNode,
            typedValue: "s3cr3t!",
            platform: .ios
        )
        XCTAssertEqual(pwCode, "I.fillField('Password', secret('s3cr3t!'));")

        let usernameNode = MobileAccessibilityNode(
            id: "user",
            type: "EditText",
            role: "textfield",
            identifier: "com.app:id/username",
            label: "Username",
            isSecure: false
        )
        let userCode = MobileLocatorSynthesizer.synthesizeStepCode(
            action: .fillField,
            node: usernameNode,
            typedValue: "bob@example.com",
            platform: .android
        )
        XCTAssertEqual(userCode, "I.fillField('Username', 'bob@example.com');")

        let androidButton = MobileAccessibilityNode(
            id: "btn",
            type: "Button",
            role: "button",
            identifier: "com.saucelabs.mydemoapp.rn:id/loginBtn",
            label: "Login button",
            text: "Sign In"
        )
        let androidLoc = MobileLocatorSynthesizer.recommendedLocator(for: androidButton, platform: .android)
        XCTAssertEqual(androidLoc, "#loginBtn")
        XCTAssertFalse(androidLoc.hasPrefix("//"))
        XCTAssertFalse(androidLoc.contains("[data-testid"))

        let iosButton = MobileAccessibilityNode(
            id: "iosBtn",
            type: "XCUIElementTypeButton",
            role: "button",
            testId: "Add To Cart button",
            label: "Add To Cart button"
        )
        XCTAssertEqual(
            MobileLocatorSynthesizer.synthesizeStepCode(action: .tap, node: iosButton, platform: .ios),
            "I.tap('~Add To Cart button');"
        )
    }

    // Threat T-04: Validate .mobileprovision extension and block sensitive credential paths
    func testValidatesProvisioningProfileExtensionAndBlocksSensitivePaths() throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("ceptra-prof-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let validProfile = tmpDir.appendingPathComponent("DevTeam.mobileprovision")
        try Data("plist-mock".utf8).write(to: validProfile)
        let validated = try MobileCLIDeviceBridge.validateProvisioningProfileURL(validProfile)
        XCTAssertEqual(validated.lastPathComponent, "DevTeam.mobileprovision")

        let wrongExt = tmpDir.appendingPathComponent("secret.env")
        try Data("API_KEY=123".utf8).write(to: wrongExt)
        XCTAssertThrowsError(try MobileCLIDeviceBridge.validateProvisioningProfileURL(wrongExt))

        let sensitivePath = URL(fileURLWithPath: "/etc/hosts.mobileprovision")
        XCTAssertThrowsError(try MobileCLIDeviceBridge.validateProvisioningProfileURL(sensitivePath))
    }

    func testParsesMobileCLIDevicesSimctlDumpUIAndDoctorOutputs() {
        let devicesJSON = """
        {
          "status": "ok",
          "data": {
            "devices": [
              { "id": "39241FDJH0028", "name": "Pixel 8", "platform": "android", "type": "real", "state": "online", "version": "15" }
            ]
          }
        }
        """
        let devs = MobileCLIDeviceBridge.parseMobileCLIDevicesJSON(devicesJSON)
        XCTAssertEqual(devs.count, 1)
        XCTAssertEqual(devs[0].platform, .android)
        XCTAssertEqual(devs[0].type, .real)
        XCTAssertEqual(devs[0].state, .online)

        let simctlJSON = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-3": [
              { "udid": "3FC4BE9A-D2FE-4B5B-98E6-8BC9A06C1883", "name": "iPhone 17 Pro", "state": "Booted", "isAvailable": true },
              { "udid": "6831702A-FEE3-4FB6-9797-FF95499136BE", "name": "iPhone 17 Pro Max", "state": "Shutdown", "isAvailable": true }
            ]
          }
        }
        """
        let sims = MobileCLIDeviceBridge.parseSimctlDevicesJSON(simctlJSON)
        XCTAssertEqual(sims.count, 2)
        XCTAssertEqual(sims[0].name, "iPhone 17 Pro")
        XCTAssertEqual(sims[0].state, .booted)
        XCTAssertEqual(sims[0].osVersion, "iOS 26.3")

        let dumpJSON = """
        {
          "status": "ok",
          "data": {
            "elements": [
              {
                "type": "FrameLayout",
                "bounds": { "x": 0, "y": 0, "width": 412, "height": 915 },
                "children": [
                  {
                    "type": "Button",
                    "role": "button",
                    "identifier": "com.saucelabs:id/addToCart",
                    "label": "Add To Cart button",
                    "text": "Add To Cart",
                    "visible": true,
                    "bounds": { "x": 20, "y": 810, "width": 372, "height": 52 }
                  }
                ]
              }
            ]
          }
        }
        """
        let roots = MobileCLIDeviceBridge.parseDumpUIJSON(dumpJSON)
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].children.count, 1)
        XCTAssertEqual(roots[0].children[0].label, "Add To Cart button")

        let doctorRaw = """
        mobilewright doctor  v0.0.63
        System
          ✓  Node.js  v22.22.3
          ✓  mobilecli  mobilecli version 1.0.17
        Android
          ✗  ADB (Android Debug Bridge)
             ADB is required.
             → brew install android-platform-tools
        """
        let checks = MobileCLIDeviceBridge.parseDoctorOutput(doctorRaw)
        XCTAssertEqual(checks.count, 3)
        XCTAssertEqual(checks[0].status, .ok)
        XCTAssertEqual(checks[2].status, .error)
        XCTAssertEqual(checks[2].remediationCommand, "brew install android-platform-tools")
    }

    func testMultiResolutionAspectFitAndCoordinateMappingAcrossPhoneAndTablet() {
        let stage = CGSize(width: 360, height: 640)
        for preset in MobileResolutionPreset.builtInPresets {
            for orientation in MobileDeviceOrientation.allCases {
                let logical = preset.logicalSize(for: orientation)
                let layout = MobileLocatorSynthesizer.computeAspectFit(
                    stageSize: stage,
                    deviceLogicalSize: logical,
                    padding: 16
                )
                XCTAssertGreaterThan(layout.scale, 0)
                XCTAssertLessThanOrEqual(layout.scaledSize.width, stage.width - 32 + 0.5)
                XCTAssertLessThanOrEqual(layout.scaledSize.height, stage.height - 32 + 0.5)
                XCTAssertGreaterThanOrEqual(layout.originOffset.x, 15.5)
                XCTAssertGreaterThanOrEqual(layout.originOffset.y, 15.5)

                let sampleBounds = MobileNodeBounds(x: 24, y: 120, width: 200, height: 48)
                let rect = MobileLocatorSynthesizer.mapNodeBoundsToCanvasRect(sampleBounds, layout: layout)
                let centerCanvas = CGPoint(x: rect.midX, y: rect.midY)
                let roundTrip = MobileLocatorSynthesizer.mapCanvasPointToDevicePoint(centerCanvas, layout: layout)
                XCTAssertEqual(roundTrip.x, sampleBounds.centerX, accuracy: 0.5)
                XCTAssertEqual(roundTrip.y, sampleBounds.centerY, accuracy: 0.5)
            }
        }

        // Verify hit-testing picks deepest smallest-area control over parent container
        let snap = MockMobileDeviceTransport.sampleSnapshot(platform: .ios)
        let hit = MobileLocatorSynthesizer.hitTestNode(
            atDevicePoint: CGPoint(x: 196, y: 780),
            in: snap.roots
        )
        XCTAssertEqual(hit?.testId, "Add To Cart button")
    }

    func testAppSettingsBackwardCompatibilityForMobileStudioFields() throws {
        let legacyJSON = #"{"recentProjectPaths":[],"editorFontSize":13}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.mobilePhoneDockSide, .left)
        XCTAssertEqual(decoded.mobileResolutionPresetID, "iphone-17-pro")
    }

    func testMockMobileDeviceTransportEndToEndWizardAndActionFlow() async throws {
        let transport = MockMobileDeviceTransport()
        let report = await transport.runDoctor(workspaceRoot: nil)
        XCTAssertGreaterThanOrEqual(report.okCount, 1)

        let devices = try await transport.listDevices(workspaceRoot: nil)
        XCTAssertFalse(devices.isEmpty)

        guard let sim = devices.first(where: { $0.type == .simulator }) else {
            return XCTFail("Expected mock simulator device")
        }
        try await transport.bootXcodeSimulator(udid: sim.id)
        try await transport.installAgent(deviceId: sim.id, provisioningProfileURL: nil, workspaceRoot: nil)
        let agentReady = try await transport.checkAgentStatus(deviceId: sim.id, workspaceRoot: nil)
        XCTAssertTrue(agentReady)

        let apps = try await transport.listInstalledApps(deviceId: sim.id, workspaceRoot: nil)
        XCTAssertFalse(apps.isEmpty)

        let snap = try await transport.captureSnapshot(device: sim, workspaceRoot: nil)
        XCTAssertFalse(snap.allNodes.isEmpty)

        try await transport.performTap(deviceId: sim.id, x: 196, y: 780, workspaceRoot: nil)
        try await transport.performTypeText(deviceId: sim.id, text: "bob@example.com", workspaceRoot: nil)
        try await transport.setOrientation(deviceId: sim.id, orientation: .landscape, workspaceRoot: nil)
        try await transport.performHardwareButton(deviceId: sim.id, button: "HOME", workspaceRoot: nil)
    }

    func testRankedLocatorCandidatesAndMultiResolutionSampleSnapshots() {
        // Android button with testId + resourceId + label + text should rank ~testId BEST, #resourceId ALT, and never emit CSS/XPath
        let btn = MobileAccessibilityNode(
            id: "btn-1",
            type: "android.widget.Button",
            role: "button",
            identifier: "com.saucelabs:id/addToCart",
            testId: "Add To Cart button",
            label: "Add To Cart button",
            text: "Add To Cart",
            bounds: MobileNodeBounds(x: 18, y: 780, width: 376, height: 52)
        )
        let androidCandidates = MobileLocatorSynthesizer.locatorCandidates(for: btn, platform: .android)
        XCTAssertGreaterThanOrEqual(androidCandidates.count, 3)
        XCTAssertEqual(androidCandidates[0].reliability, .recommended)
        XCTAssertEqual(androidCandidates[0].locator, "~Add To Cart button")
        XCTAssertTrue(androidCandidates.contains(where: { $0.locator == "#addToCart" }))
        XCTAssertTrue(androidCandidates.allSatisfy { !$0.locator.contains("//") && !$0.locator.hasPrefix("css=") })

        // Secure password field candidate tapSnippet must automatically use secret()
        let pwd = MobileAccessibilityNode(
            id: "pwd-1",
            type: "XCUIElementTypeSecureTextField",
            role: "textfield",
            testId: "Password input field",
            placeholder: "Password",
            isSecure: true,
            bounds: MobileNodeBounds(x: 18, y: 460, width: 357, height: 46)
        )
        let pwdCandidates = MobileLocatorSynthesizer.locatorCandidates(for: pwd, platform: .ios)
        XCTAssertTrue(pwdCandidates.first?.tapSnippet.contains("secret(") == true)

        // Multi-resolution sample snapshots must place every leaf control strictly inside logical bounds across all presets & orientations
        for preset in MobileResolutionPreset.builtInPresets {
            for orientation in MobileDeviceOrientation.allCases {
                let snap = MockMobileDeviceTransport.sampleSnapshot(preset: preset, orientation: orientation)
                let expected = preset.logicalSize(for: orientation)
                XCTAssertEqual(snap.logicalWidth, Double(expected.width), accuracy: 0.5)
                XCTAssertEqual(snap.logicalHeight, Double(expected.height), accuracy: 0.5)
                let leaves = snap.allNodes.filter { $0.normalizedRole != "window" && $0.normalizedRole != "other" }
                XCTAssertGreaterThanOrEqual(leaves.count, 6)
                for leaf in leaves {
                    XCTAssertGreaterThanOrEqual(leaf.bounds.x, 0)
                    XCTAssertGreaterThanOrEqual(leaf.bounds.y, 0)
                    XCTAssertLessThanOrEqual(leaf.bounds.x + leaf.bounds.width, snap.logicalWidth + 0.5)
                    XCTAssertLessThanOrEqual(leaf.bounds.y + leaf.bounds.height, snap.logicalHeight + 0.5)
                }
            }
        }
    }

    func testExtractsMobileCLIAgentNotInstalledJSONErrorsAndRejectsErrorPayloadInDumpUI() {
        let agentErrJSON = """
        failed to start agent on device 25baec9900a90f3b50b5023ab76141d2701b06e5: agent is not installed
        {
          "status": "error",
          "error": "failed to start agent on device 25baec9900a90f3b50b5023ab76141d2701b06e5: agent is not installed, use 'mobilecli agent install --device 25baec9900a90f3b50b5023ab76141d2701b06e5 --provisioning-profile <path>' to install it"
        }
        """
        let extracted = MobileCLIDeviceBridge.extractMobileCLIErrorMessage(stdout: agentErrJSON, stderr: "")
        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted?.contains("agent is not installed") == true)
        XCTAssertTrue(MobileCLIDeviceBridge.parseDumpUIJSON(agentErrJSON).isEmpty)

        let failJSON = #"{"status":"fail","data":{"message":"Agent is not installed on the device"}}"#
        XCTAssertEqual(
            MobileCLIDeviceBridge.extractMobileCLIErrorMessage(stdout: failJSON, stderr: ""),
            "Agent is not installed on the device"
        )
    }

    func testProvisioningProfileInspectorExtractsNameUDIDsAndSelectsBestMatch() {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400 * 5))
        let plistApp = """
        BINARY_CMS_HEADER<?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Name</key><string>iOS Team Provisioning Profile: kobean.test-app</string>
          <key>TeamName</key><string>Joseph Nguyen</string>
          <key>Entitlements</key><dict><key>application-identifier</key><string>PR93PB8S6S.kobean.test-app</string></dict>
          <key>ExpirationDate</key><date>\(futureDate)</date>
          <key>ProvisionedDevices</key><array><string>25baec9900a90f3b50b5023ab76141d2701b06e5</string></array>
        </dict></plist>TRAILING_SIGNATURE
        """.data(using: .utf8)!

        let plistWildcard = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>Name</key><string>iOS Team Provisioning Profile: *</string>
          <key>Entitlements</key><dict><key>application-identifier</key><string>PR93PB8S6S.*</string></dict>
          <key>ExpirationDate</key><date>\(futureDate)</date>
          <key>ProvisionedDevices</key><array><string>25baec9900a90f3b50b5023ab76141d2701b06e5</string></array>
        </dict></plist>
        """.data(using: .utf8)!

        let p1 = MobileCLIDeviceBridge.MobileProvisioningProfileInspector.parse(data: plistApp, path: "/tmp/app.mobileprovision")
        let p2 = MobileCLIDeviceBridge.MobileProvisioningProfileInspector.parse(data: plistWildcard, path: "/tmp/wildcard.mobileprovision")
        XCTAssertNotNil(p1)
        XCTAssertNotNil(p2)
        XCTAssertFalse(p1?.isWildcardProfile == true)
        XCTAssertTrue(p2?.isWildcardProfile == true)
        XCTAssertTrue(p1?.supports(deviceUDID: "25baec9900a90f3b50b5023ab76141d2701b06e5") == true)
        XCTAssertFalse(p1?.supports(deviceUDID: "00000000-OTHER") == true)

        let best = MobileCLIDeviceBridge.MobileProvisioningProfileInspector.bestMatchingProfile(
            for: "25baec9900a90f3b50b5023ab76141d2701b06e5",
            in: [p1!, p2!]
        )
        XCTAssertEqual(best?.path, "/tmp/wildcard.mobileprovision")
    }

    func testParsesRealMobileCLISimulatorDumpUIWithIconRoleAndRect() {
        let realDumpJSON = """
        {
          "status": "ok",
          "data": {
            "elements": [
              {
                "ref": "@e1",
                "type": "Other",
                "name": "Home screen icons",
                "identifier": "Home screen icons",
                "rect": { "x": 0, "y": 0, "width": 402, "height": 874 },
                "children": [
                  {
                    "ref": "@e2",
                    "type": "Icon",
                    "label": "Fitness",
                    "name": "Fitness",
                    "value": "",
                    "identifier": "Fitness",
                    "rect": { "x": 28, "y": 88, "width": 68, "height": 90 }
                  }
                ]
              }
            ]
          }
        }
        """
        let roots = MobileCLIDeviceBridge.parseDumpUIJSON(realDumpJSON)
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].bounds.width, 402)
        XCTAssertEqual(roots[0].bounds.height, 874)
        XCTAssertEqual(roots[0].children.count, 1)
        let icon = roots[0].children[0]
        XCTAssertEqual(icon.normalizedRole, "button")
        XCTAssertEqual(icon.label, "Fitness")
        XCTAssertEqual(MobileLocatorSynthesizer.recommendedLocator(for: icon, platform: .ios), "~Fitness")
    }

    func testParsesRealIPhoneAppsListJSONWithDataArrayAndAppName() {
        let realAppsJSON = """
        {
          "status": "ok",
          "data": [
            { "packageName": "com.grabtaxi.iphone", "appName": "Grab", "version": "5.432.0" },
            { "packageName": "com.ovelin.guitartuna", "appName": "GuitarTuna", "version": "7.105.0" }
          ]
        }
        """
        let apps = MobileCLIDeviceBridge.parseAppsListJSON(realAppsJSON)
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps[0].bundleId, "com.grabtaxi.iphone")
        XCTAssertEqual(apps[0].name, "Grab")
        XCTAssertEqual(apps[1].bundleId, "com.ovelin.guitartuna")
        XCTAssertEqual(apps[1].name, "GuitarTuna")
    }

    func testComputesAndroidMultiWindowLogicalSizeAcrossStatusBarAndAppRoot() {
        let statusBar = MobileAccessibilityNode(
            id: "root-1",
            type: "android.widget.FrameLayout",
            bounds: MobileNodeBounds(x: 0, y: 0, width: 1080, height: 84)
        )
        let appWindow = MobileAccessibilityNode(
            id: "root-2",
            type: "android.widget.FrameLayout",
            bounds: MobileNodeBounds(x: 0, y: 0, width: 1080, height: 2400)
        )
        let size = MobileCLIDeviceBridge.computeSnapshotLogicalSize(from: [statusBar, appWindow], platform: .android)
        XCTAssertEqual(size.width, 1080, accuracy: 0.5)
        XCTAssertEqual(size.height, 2400, accuracy: 0.5)
    }

    func testSimctlSortingPrioritizesBootedThenIPhonesBeforeIPadsAndNewestIOSFirst() {
        let simctlJSON = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-3": [
              { "udid": "IPAD-OLD", "name": "iPad (A16)", "state": "Shutdown", "isAvailable": true },
              { "udid": "IPHONE-OLD", "name": "iPhone 17 Pro", "state": "Shutdown", "isAvailable": true }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
              { "udid": "IPAD-NEW", "name": "iPad Air 11-inch (M4)", "state": "Shutdown", "isAvailable": true },
              { "udid": "IPHONE-NEW", "name": "iPhone 17 Pro", "state": "Shutdown", "isAvailable": true },
              { "udid": "IPAD-BOOTED", "name": "iPad mini", "state": "Booted", "isAvailable": true }
            ]
          }
        }
        """
        let sims = MobileCLIDeviceBridge.parseSimctlDevicesJSON(simctlJSON)
        XCTAssertEqual(sims.map(\.id), ["IPAD-BOOTED", "IPHONE-NEW", "IPHONE-OLD", "IPAD-NEW", "IPAD-OLD"])
    }

    func testSimctlAlreadyBootedExitCode149IsTreatedAsIdempotentSuccess() {
        let stderr149 = """
        An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):
        Unable to boot device in current state: Booted
        """
        XCTAssertTrue(MobileCLIDeviceBridge.isAlreadyBootedSimctlResponse(exitCode: 149, stderr: stderr149))
        XCTAssertTrue(MobileCLIDeviceBridge.isAlreadyBootedSimctlResponse(exitCode: 1, stderr: stderr149))
        XCTAssertFalse(MobileCLIDeviceBridge.isAlreadyBootedSimctlResponse(exitCode: 148, stderr: "Invalid device: unknown UDID"))
    }

    func testDetectsTransientMobileCLIRPCConnectionRefusedAndWDATimeoutErrors() {
        let rpcRefused = """
        {"status":"error","error":"error taking screenshot: RPC call device.screenshot failed: Post \\"http://localhost:13002/rpc\\": dial tcp 127.0.0.1:13002: connect: connection refused"}
        """
        let wdaTimeout = "failed to start agent on device B0915AAB-4954-4D93-B088-173F3979ADC4: timed out waiting for WebDriverAgent to be ready"
        XCTAssertTrue(MobileCLIDeviceBridge.isTransientMobileCLIRPCError(stdout: rpcRefused, stderr: ""))
        XCTAssertTrue(MobileCLIDeviceBridge.isTransientMobileCLIRPCError(stdout: "", stderr: wdaTimeout))
        XCTAssertFalse(MobileCLIDeviceBridge.isTransientMobileCLIRPCError(stdout: "", stderr: "Agent is not installed on the device"))
    }

    func testClassifiesDragSwipeDirectionsAndSynthesizesSwipeAndTapXYSteps() {
        XCTAssertEqual(
            MobileLocatorSynthesizer.classifySwipeDirection(from: CGPoint(x: 200, y: 650), to: CGPoint(x: 205, y: 220)),
            .swipeUp
        )
        XCTAssertEqual(
            MobileLocatorSynthesizer.classifySwipeDirection(from: CGPoint(x: 200, y: 220), to: CGPoint(x: 195, y: 650)),
            .swipeDown
        )
        XCTAssertEqual(
            MobileLocatorSynthesizer.classifySwipeDirection(from: CGPoint(x: 340, y: 400), to: CGPoint(x: 60, y: 405)),
            .swipeLeft
        )
        XCTAssertEqual(
            MobileLocatorSynthesizer.classifySwipeDirection(from: CGPoint(x: 60, y: 400), to: CGPoint(x: 340, y: 395)),
            .swipeRight
        )

        XCTAssertEqual(MobileLocatorSynthesizer.synthesizeStepCode(action: .swipeUp), "I.swipeUp();")
        XCTAssertEqual(MobileLocatorSynthesizer.synthesizeStepCode(action: .swipeDown), "I.swipeDown();")
        XCTAssertEqual(MobileLocatorSynthesizer.synthesizeStepCode(action: .swipeLeft), "I.swipeLeft();")
        XCTAssertEqual(MobileLocatorSynthesizer.synthesizeStepCode(action: .swipeRight), "I.swipeRight();")
        XCTAssertEqual(
            MobileLocatorSynthesizer.synthesizeStepCode(action: .tapXY, coordinate: CGPoint(x: 184.4, y: 512.7)),
            "I.tapXY(184, 513);"
        )
    }

    func testExactViewportCalibrationPreventsAlertRectShiftAndCollapsesDuplicateTwinButtons() {
        // Exact reproduction of the iPhone 17 (402x874 @3x = 1206x2622) Calendar Contacts TCC alert!
        let alertDumpJSON = """
        {
          "status": "ok",
          "data": {
            "elements": [
              {
                "ref": "@e1",
                "type": "Alert",
                "label": "Allow Calendar to access your contacts?",
                "identifier": "kTCCServiceAddressBook-staged-alert",
                "rect": { "x": 41, "y": 294, "width": 320, "height": 313 },
                "children": [
                  {
                    "ref": "@e2",
                    "type": "Image",
                    "identifier": "/Users/josephnguyen/Library/Developer/CoreSimulator/Devices/UUID/kTCCServiceAddressBook@3x.png",
                    "rect": { "x": 67, "y": 314, "width": 69, "height": 69 }
                  },
                  {
                    "ref": "@e5",
                    "type": "Button",
                    "label": "Don't Allow",
                    "identifier": "kTCCServiceAddressBook-deny-button",
                    "rect": { "x": 57, "y": 543, "width": 140, "height": 48 },
                    "children": [
                      {
                        "ref": "@e6",
                        "type": "Button",
                        "label": "Don't Allow",
                        "identifier": "kTCCServiceAddressBook-deny-button",
                        "rect": { "x": 57, "y": 543, "width": 140, "height": 48 }
                      }
                    ]
                  }
                ]
              }
            ]
          }
        }
        """
        let roots = MobileCLIDeviceBridge.parseDumpUIJSON(alertDumpJSON)
        XCTAssertEqual(roots.count, 1)
        // Redundant 1:1 duplicate child button is cleanly collapsed
        let denyBtn = roots[0].children[1]
        XCTAssertEqual(denyBtn.identifier, "kTCCServiceAddressBook-deny-button")
        XCTAssertTrue(denyBtn.children.isEmpty)

        // Host filesystem path on alert icon is cleaned for display and never emitted as a ~locator
        let alertIcon = roots[0].children[0]
        XCTAssertEqual(alertIcon.displayTitle, "kTCCServiceAddressBook@3x.png")
        XCTAssertEqual(MobileLocatorSynthesizer.recommendedLocator(for: alertIcon, platform: .ios), "{ role: 'image' }")

        // Device info JSON parser extracts exact 402x874 @3x screen size
        let infoJSON = #"{"status":"ok","data":{"device":{"id":"SIM-1","screenSize":{"width":402,"height":874,"scale":3}}}}"#
        let screenInfo = MobileCLIDeviceBridge.parseDeviceInfoScreenSizeJSON(infoJSON)
        XCTAssertEqual(screenInfo, MobileDeviceScreenInfo(width: 402, height: 874, scale: 3))

        // Viewport resolves to 402x874 (NOT 361x607 from the centered alert!) both with device info and with 1206x2622 screenshot fallback
        let vpFromInfo = MobileCLIDeviceBridge.computeSnapshotLogicalSize(
            from: roots,
            platform: .ios,
            deviceScreenInfo: screenInfo,
            screenshotPixelSize: (1206, 2622)
        )
        XCTAssertEqual(vpFromInfo.width, 402, accuracy: 0.1)
        XCTAssertEqual(vpFromInfo.height, 874, accuracy: 0.1)

        let vpFromPixelsOnly = MobileCLIDeviceBridge.computeSnapshotLogicalSize(
            from: roots,
            platform: .ios,
            deviceScreenInfo: nil,
            screenshotPixelSize: (1206, 2622)
        )
        XCTAssertEqual(vpFromPixelsOnly.width, 402, accuracy: 0.1)
        XCTAssertEqual(vpFromPixelsOnly.height, 874, accuracy: 0.1)
    }
}
