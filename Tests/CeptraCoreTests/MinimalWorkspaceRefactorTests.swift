import XCTest
@testable import CeptraCore

final class MinimalWorkspaceRefactorTests: XCTestCase {
    func testLegacyAppSettingsJSONDecodesWithSensibleMinimalDefaults() throws {
        let legacyJSON = """
        {
          "recentProjectPaths": ["/tmp/demo"],
          "editorFontSize": 14.0,
          "autoCheckForUpdates": false
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.recentProjectPaths, ["/tmp/demo"])
        XCTAssertEqual(decoded.editorFontSize, 14.0)
        XCTAssertFalse(decoded.autoCheckForUpdates)
        XCTAssertEqual(decoded.appearance, .dark)
        XCTAssertEqual(decoded.modulePreferences, WorkspaceModulePreferences())
        XCTAssertTrue(decoded.modulePreferences.showLeftSidebar)
        XCTAssertFalse(decoded.modulePreferences.showTerminal)
        XCTAssertFalse(decoded.modulePreferences.showRightSidebar)
        XCTAssertTrue(decoded.modulePreferences.showStatusBar)
        XCTAssertEqual(decoded.modulePreferences.activeRightTab, .replay)
        XCTAssertTrue(decoded.modulePreferences.autoOpenReplayOnRun)
    }

    func testAppSettingsRoundTripsAppearanceAndModulePreferences() throws {
        var settings = AppSettings()
        settings.appearance = .light
        settings.modulePreferences = WorkspaceModulePreferences(
            showLeftSidebar: false,
            showTerminal: true,
            showRightSidebar: true,
            showStatusBar: false,
            activeRightTab: .codeceptUI,
            autoOpenReplayOnRun: false
        )

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)

        XCTAssertEqual(decoded.appearance, .light)
        XCTAssertEqual(decoded.modulePreferences.showLeftSidebar, false)
        XCTAssertEqual(decoded.modulePreferences.showTerminal, true)
        XCTAssertEqual(decoded.modulePreferences.showRightSidebar, true)
        XCTAssertEqual(decoded.modulePreferences.showStatusBar, false)
        XCTAssertEqual(decoded.modulePreferences.activeRightTab, .codeceptUI)
        XCTAssertEqual(decoded.modulePreferences.autoOpenReplayOnRun, false)
    }

    func testCodeceptUIDetectionChecksPackageJsonAndLocalBin() throws {
        let fm = FileManager.default
        let emptyDir = fm.temporaryDirectory.appendingPathComponent("ceptra-ui-empty-\(UUID().uuidString)")
        let pkgDir = fm.temporaryDirectory.appendingPathComponent("ceptra-ui-pkg-\(UUID().uuidString)")
        let binDir = fm.temporaryDirectory.appendingPathComponent("ceptra-ui-bin-\(UUID().uuidString)")
        try fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: binDir.appendingPathComponent("node_modules/.bin"), withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: emptyDir)
            try? fm.removeItem(at: pkgDir)
            try? fm.removeItem(at: binDir)
        }

        XCTAssertFalse(CodeceptUIServerManager.isInstalled(in: emptyDir))

        let pkgJSON = """
        { "name": "demo", "devDependencies": { "@codeceptjs/ui": "^1.0.0" } }
        """
        try pkgJSON.write(to: pkgDir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(CodeceptUIServerManager.isInstalled(in: pkgDir))

        let fakeBin = binDir.appendingPathComponent("node_modules/.bin/codecept-ui")
        try "#!/bin/sh\necho ok\n".write(to: fakeBin, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBin.path)
        XCTAssertTrue(CodeceptUIServerManager.isInstalled(in: binDir))
    }

    func testCodeceptUILaunchCommandBindsLoopbackAndUsesPortAndConfig() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ceptra-ui-cmd-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("node_modules/.bin"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let bin = dir.appendingPathComponent("node_modules/.bin/codecept-ui")
        try "#!/bin/sh\necho ui\n".write(to: bin, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        let toolchain = NodeToolchainResolver.resolve(workspaceRoot: dir)
        let cmd = CodeceptUIServerManager.buildStartCommand(
            workspaceRoot: dir,
            port: 3456,
            customConfigPath: "configs/codecept.ci.ts",
            toolchain: toolchain
        )

        XCTAssertEqual(cmd.executablePath, bin.path)
        XCTAssertEqual(cmd.arguments, ["--port", "3456", "-c", "configs/codecept.ci.ts"])
        XCTAssertEqual(cmd.environment["HOST"], "127.0.0.1")
        XCTAssertEqual(cmd.environment["PORT"], "3456")
        XCTAssertEqual(cmd.workingDirectory, dir)
    }

    func testCodeceptUIInstallCommandMatchesPackageManager() {
        let dir = FileManager.default.temporaryDirectory
        let toolchain = NodeToolchainResolver.resolve(workspaceRoot: dir)

        let npmCmd = CodeceptUIServerManager.buildInstallCommand(
            packageManager: .npm,
            workspaceRoot: dir,
            toolchain: toolchain
        )
        XCTAssertTrue(npmCmd.displayCommand.contains("npm install -D @codeceptjs/ui"))

        let pnpmCmd = CodeceptUIServerManager.buildInstallCommand(
            packageManager: .pnpm,
            workspaceRoot: dir,
            toolchain: toolchain
        )
        XCTAssertTrue(pnpmCmd.displayCommand.contains("pnpm add -D @codeceptjs/ui"))

        let bunCmd = CodeceptUIServerManager.buildInstallCommand(
            packageManager: .bun,
            workspaceRoot: dir,
            toolchain: toolchain
        )
        XCTAssertTrue(bunCmd.displayCommand.contains("bun add -d @codeceptjs/ui"))
    }

    func testFindAvailableLoopbackPortReturnsValidUnprivilegedPort() throws {
        let port = try CodeceptUIServerManager.findAvailableLoopbackPort()
        XCTAssertGreaterThanOrEqual(port, 1024)
        XCTAssertLessThanOrEqual(port, 65535)
    }

    func testStrictLoopbackURLValidation() {
        let port = 3333
        XCTAssertTrue(CodeceptUIServerManager.isAllowedLoopbackURL(URL(string: "http://127.0.0.1:3333/")!, port: port))
        XCTAssertTrue(CodeceptUIServerManager.isAllowedLoopbackURL(URL(string: "http://localhost:3333/test-run")!, port: port))
        XCTAssertTrue(CodeceptUIServerManager.isAllowedLoopbackURL(URL(string: "ws://127.0.0.1:3333/socket.io/")!, port: port))

        XCTAssertFalse(CodeceptUIServerManager.isAllowedLoopbackURL(URL(string: "http://127.0.0.1:9999/")!, port: port))
        XCTAssertFalse(CodeceptUIServerManager.isAllowedLoopbackURL(URL(string: "https://example.com/")!, port: port))
        XCTAssertFalse(CodeceptUIServerManager.isAllowedLoopbackURL(URL(string: "http://127.0.0.1.evil.com:3333/")!, port: port))
        XCTAssertFalse(CodeceptUIServerManager.isAllowedLoopbackURL(URL(string: "file:///etc/passwd")!, port: port))
    }

    func testEditorZoomBoundsSnappingAndPercentage() {
        XCTAssertEqual(AppSettings.clampedEditorFontSize(4.0), AppSettings.minEditorFontSize)
        XCTAssertEqual(AppSettings.clampedEditorFontSize(99.0), AppSettings.maxEditorFontSize)
        XCTAssertEqual(AppSettings.clampedEditorFontSize(14.3), 14.5)
        XCTAssertEqual(AppSettings.clampedEditorFontSize(14.2), 14.0)

        var settings = AppSettings()
        XCTAssertEqual(settings.editorZoomPercentage, 100)
        XCTAssertEqual(settings.editorZoomScale, 1.0, accuracy: 0.001)

        settings.editorFontSize = 19.5
        XCTAssertEqual(settings.editorZoomPercentage, 150)
        XCTAssertEqual(settings.editorZoomScale, 1.5, accuracy: 0.001)
    }
}
