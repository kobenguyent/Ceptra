import CeptraCore
import CryptoKit
import XCTest

private final class MockHTTPClient: HTTPFetching, @unchecked Sendable {
    var responses: [String: HTTPResponseData] = [:]
    var downloadPayload: Data = Data()

    func fetch(_ request: URLRequest) async throws -> HTTPResponseData {
        guard let urlStr = request.url?.absoluteString, let resp = responses[urlStr] else {
            return HTTPResponseData(data: Data(), statusCode: 404)
        }
        return resp
    }

    func download(from url: URL, to destination: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        progress?(0.5)
        try downloadPayload.write(to: destination)
        progress?(1.0)
        return destination
    }
}

final class AutoUpdateTests: XCTestCase {
    func testSemanticVersionOrdering() {
        XCTAssertLessThan(SemanticVersion(parsing: "v1.0.0")!, SemanticVersion(parsing: "v1.0.1")!)
        XCTAssertLessThan(SemanticVersion(parsing: "1.2.0-rc.1")!, SemanticVersion(parsing: "1.2.0")!)
        XCTAssertLessThan(SemanticVersion(parsing: "1.2.0-alpha.1")!, SemanticVersion(parsing: "1.2.0-beta.1")!)
        XCTAssertEqual(SemanticVersion(parsing: "v2.3.4"), SemanticVersion(major: 2, minor: 3, patch: 4))
    }

    func testGitHubReleaseSelectsOptimalMacAsset() {
        let release = GitHubRelease(
            tagName: "v1.2.0",
            htmlURL: URL(string: "https://github.com/kobenguyent/Ceptra/releases/tag/v1.2.0")!,
            assets: [
                GitHubReleaseAsset(name: "SHA256SUMS.txt", browserDownloadURL: URL(string: "https://example.com/SHA256SUMS.txt")!, size: 128),
                GitHubReleaseAsset(name: "Ceptra-1.2.0-macOS-x86_64.dmg", browserDownloadURL: URL(string: "https://example.com/x86.dmg")!, size: 1000),
                GitHubReleaseAsset(name: "Ceptra-1.2.0-macOS-universal.dmg", browserDownloadURL: URL(string: "https://example.com/uni.dmg")!, size: 2000),
                GitHubReleaseAsset(name: "Ceptra-1.2.0-macOS-universal.zip", browserDownloadURL: URL(string: "https://example.com/uni.zip")!, size: 1800)
            ]
        )

        XCTAssertEqual(release.preferredMacAsset(architecture: "arm64")?.name, "Ceptra-1.2.0-macOS-universal.zip")
        XCTAssertEqual(release.checksumAsset?.name, "SHA256SUMS.txt")
    }

    func testUpdateServiceChecksDownloadsAndVerifiesSHA256() async throws {
        let payload = Data("mock-ceptra-zip-binary-contents".utf8)
        let expectedSHA = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        let mock = MockHTTPClient()
        mock.downloadPayload = payload

        let releaseJSON = """
        {
          "tag_name": "v2.0.0",
          "name": "Ceptra v2.0.0",
          "body": "Faster visual pipeline",
          "html_url": "https://github.com/kobenguyent/Ceptra/releases/tag/v2.0.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "Ceptra-2.0.0-macOS-universal.zip",
              "browser_download_url": "https://example.com/Ceptra-2.0.0-macOS-universal.zip",
              "size": 31
            },
            {
              "name": "SHA256SUMS.txt",
              "browser_download_url": "https://example.com/SHA256SUMS.txt",
              "size": 100
            }
          ]
        }
        """

        mock.responses["https://api.github.com/repos/kobenguyent/Ceptra/releases/latest"] =
            HTTPResponseData(data: Data(releaseJSON.utf8), statusCode: 200)
        mock.responses["https://example.com/SHA256SUMS.txt"] =
            HTTPResponseData(data: Data("\(expectedSHA)  Ceptra-2.0.0-macOS-universal.zip\n".utf8), statusCode: 200)

        let service = UpdateService(httpClient: mock)
        let outcome = try await service.checkForUpdates(
            repository: "kobenguyent/Ceptra",
            currentVersion: SemanticVersion(major: 1, minor: 0, patch: 0)
        )

        guard case .updateAvailable(let release, let latestVersion, let asset) = outcome, let asset else {
            return XCTFail("Expected updateAvailable with macOS asset")
        }
        XCTAssertEqual(latestVersion, SemanticVersion(major: 2, minor: 0, patch: 0))

        let tempDest = FileManager.default.temporaryDirectory.appendingPathComponent("ceptra-dl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDest) }

        let artifact = try await service.downloadAndVerify(release: release, asset: asset, destinationDirectory: tempDest)
        XCTAssertTrue(artifact.verifiedAgainstChecksums)
        XCTAssertEqual(artifact.sha256, expectedSHA)

        // Verify checksum mismatch rejects tampered download
        mock.responses["https://example.com/SHA256SUMS.txt"] =
            HTTPResponseData(data: Data("0000000000000000000000000000000000000000000000000000000000000000  Ceptra-2.0.0-macOS-universal.zip\n".utf8), statusCode: 200)
        do {
            _ = try await service.downloadAndVerify(release: release, asset: asset, destinationDirectory: tempDest)
            XCTFail("Expected checksum mismatch error")
        } catch let error as UpdateError {
            guard case .checksumMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUpdateInstallerAtomicallyReplacesAppBundleFromZip() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("ceptra-install-e2e-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        // 1. Existing v1.0.0 Ceptra.app
        let installedApp = sandbox.appendingPathComponent("Ceptra.app", isDirectory: true)
        try fm.createDirectory(at: installedApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "v1.0.0".write(to: installedApp.appendingPathComponent("Contents/MacOS/Ceptra"), atomically: true, encoding: .utf8)

        // 2. New v2.0.0 Ceptra.app zipped via ditto
        let stagingDir = sandbox.appendingPathComponent("staging", isDirectory: true)
        let newApp = stagingDir.appendingPathComponent("Ceptra.app", isDirectory: true)
        try fm.createDirectory(at: newApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "v2.0.0".write(to: newApp.appendingPathComponent("Contents/MacOS/Ceptra"), atomically: true, encoding: .utf8)

        let zipURL = sandbox.appendingPathComponent("Ceptra-2.0.0-macOS-universal.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", newApp.path, zipURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        // 3. Build & execute installer script with non-existent PID (immediate replace, no relaunch)
        let plan = UpdateInstallPlan(
            downloadedAssetURL: zipURL,
            targetAppURL: installedApp,
            processID: 999_999,
            relaunchAfterInstall: false
        )
        let script = try UpdateInstaller.buildInstallScript(plan: plan)
        // Regression checks: detached against HUP, stages bundle BEFORE waiting on PID, and has bounded TERM fallback
        XCTAssertTrue(script.contains("trap '' HUP"))
        XCTAssertTrue(script.contains("kill -TERM \"$APP_PID\""))
        let stageRange = try XCTUnwrap(script.range(of: "ditto -x -k"))
        let waitRange = try XCTUnwrap(script.range(of: "for _ in {1..40}"))
        XCTAssertLessThan(stageRange.lowerBound, waitRange.lowerBound, "Installer should stage the new bundle before waiting on the exiting PID")

        let scriptURL = sandbox.appendingPathComponent("run-update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/zsh")
        runner.arguments = [scriptURL.path]
        try runner.run()
        runner.waitUntilExit()
        XCTAssertEqual(runner.terminationStatus, 0)

        let replacedVersion = try String(contentsOf: installedApp.appendingPathComponent("Contents/MacOS/Ceptra"), encoding: .utf8)
        XCTAssertEqual(replacedVersion, "v2.0.0")
    }

    func testNextVersionScriptComputesAutomaticSemVerBumps() throws {
        let fm = FileManager.default
        let scriptPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/next-version.sh").path
        guard fm.fileExists(atPath: scriptPath) else {
            throw XCTSkip("next-version.sh not found at \(scriptPath)")
        }

        let repo = fm.temporaryDirectory.appendingPathComponent("ceptra-semver-repo-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repo) }

        @discardableResult
        func run(_ executable: String, _ args: [String]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            p.currentDirectoryURL = repo
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(p.terminationStatus, 0, "Command failed (\(executable) \(args)): \(out)")
            return out
        }

        func parseKV(_ output: String) -> [String: String] {
            var dict: [String: String] = [:]
            for line in output.components(separatedBy: .newlines) {
                guard let eq = line.firstIndex(of: "=") else { continue }
                dict[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
            return dict
        }

        try run("/usr/bin/git", ["init", "-b", "main"])
        try run("/usr/bin/git", ["config", "user.name", "Test"])
        try run("/usr/bin/git", ["config", "user.email", "test@example.com"])

        // 1. Initial release with no tags -> v1.0.0
        try "a".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "-A"])
        try run("/usr/bin/git", ["commit", "-m", "Initial commit"])
        var out = parseKV(try run("/bin/bash", [scriptPath]))
        XCTAssertEqual(out["SHOULD_RELEASE"], "true")
        XCTAssertEqual(out["NEXT_TAG"], "v1.0.0")
        XCTAssertEqual(out["BUMP_KIND"], "initial")

        // 2. Tag HEAD as v1.0.0 -> auto should skip releasing duplicate tag
        try run("/usr/bin/git", ["tag", "-a", "v1.0.0", "-m", "Release v1.0.0"])
        out = parseKV(try run("/bin/bash", [scriptPath]))
        XCTAssertEqual(out["SHOULD_RELEASE"], "false")

        // 3. Patch commit -> v1.0.1
        try "b".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "-A"])
        try run("/usr/bin/git", ["commit", "-m", "fix: handle empty test file"])
        out = parseKV(try run("/bin/bash", [scriptPath]))
        XCTAssertEqual(out["SHOULD_RELEASE"], "true")
        XCTAssertEqual(out["NEXT_TAG"], "v1.0.1")
        XCTAssertEqual(out["BUMP_KIND"], "patch")

        // 4. Feature commit -> v1.1.0
        try "c".write(to: repo.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "-A"])
        try run("/usr/bin/git", ["commit", "-m", "feat: add full project tree"])
        out = parseKV(try run("/bin/bash", [scriptPath]))
        XCTAssertEqual(out["NEXT_TAG"], "v1.1.0")
        XCTAssertEqual(out["BUMP_KIND"], "minor")

        // 5. Breaking commit -> v2.0.0
        try "d".write(to: repo.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "-A"])
        try run("/usr/bin/git", ["commit", "-m", "feat!: overhaul storage schema"])
        out = parseKV(try run("/bin/bash", [scriptPath]))
        XCTAssertEqual(out["NEXT_TAG"], "v2.0.0")
        XCTAssertEqual(out["BUMP_KIND"], "major")

        // 6. [skip release] -> skips automatic release
        try "e".write(to: repo.appendingPathComponent("e.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "-A"])
        try run("/usr/bin/git", ["commit", "-m", "chore: internal note [skip release]"])
        out = parseKV(try run("/bin/bash", [scriptPath]))
        XCTAssertEqual(out["SHOULD_RELEASE"], "false")
    }
}
