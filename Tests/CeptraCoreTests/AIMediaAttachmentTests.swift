import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CeptraCore

final class AIMediaAttachmentTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-media-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Helpers

    private func makeTestPNGData(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Failed to allocate CGContext")
            throw NSError(domain: "test", code: 1)
        }
        ctx.setFillColor(CGColor(red: 0.16, green: 0.45, blue: 0.88, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else {
            XCTFail("Failed to create CGImage")
            throw NSError(domain: "test", code: 2)
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "test", code: 3)
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func makeTestPDF(at url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            XCTFail("Failed to create PDF CGContext")
            return
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1.0))
        ctx.fill(CGRect(x: 40, y: 40, width: 320, height: 220))
        ctx.endPDFPage()
        ctx.closePDF()
    }

    // MARK: - Media Processor Tests

    func testImageDownscalingAndThumbnailGeneration() throws {
        let rawPNG = try makeTestPNGData(width: 2400, height: 1200)
        let attachment = try AIMediaAttachmentProcessor.processImageData(
            rawPNG,
            displayName: "failure-screen.png",
            persistTempFileIfNeeded: true
        )

        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.displayName, "failure-screen.png")
        XCTAssertEqual(attachment.images.count, 1)
        XCTAssertNotNil(attachment.thumbnailBase64)
        XCTAssertNotNil(attachment.filePath)
        XCTAssertTrue(attachment.subtitle.contains("2400×1200"))

        // Verify encoded payload was resized to <= 1568px on the longest edge
        let decodedData = try XCTUnwrap(Data(base64Encoded: attachment.images[0].base64Data))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(decodedData as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertLessThanOrEqual(max(img.width, img.height), AIMediaAttachmentProcessor.maxImageLongEdgePx)
        XCTAssertEqual(img.width, AIMediaAttachmentProcessor.maxImageLongEdgePx)
        XCTAssertEqual(img.height, 784)

        if let path = attachment.filePath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    func testTextFileRedactionAndUntrustedWrapping() throws {
        let logURL = tempDir.appendingPathComponent("failure.log")
        let fakeSecret = "sk-ant-api03-" + String(repeating: "x", count: 28)
        try "Request failed with token \(fakeSecret)\nAssertionError: expected button visible".write(
            to: logURL,
            atomically: true,
            encoding: .utf8
        )

        let attachment = try AIMediaAttachmentProcessor.processFile(
            at: logURL,
            workspaceRoot: tempDir,
            redactSecrets: true
        )

        XCTAssertEqual(attachment.kind, .textFile)
        XCTAssertTrue(attachment.wasRedacted)
        let text = try XCTUnwrap(attachment.textContent)
        XCTAssertTrue(text.contains("<untrusted_file_context name=\"failure.log\">"))
        XCTAssertFalse(text.contains(fakeSecret))
    }

    func testTextFileTruncationAt24K() throws {
        let codeURL = tempDir.appendingPathComponent("huge_test.ts")
        let big = String(repeating: "I.see('ok');\n", count: 3000)
        try big.write(to: codeURL, atomically: true, encoding: .utf8)

        let attachment = try AIMediaAttachmentProcessor.processFile(
            at: codeURL,
            workspaceRoot: tempDir,
            redactSecrets: false
        )

        XCTAssertEqual(attachment.kind, .textFile)
        let text = try XCTUnwrap(attachment.textContent)
        XCTAssertTrue(text.contains("truncated at \(AIMediaAttachmentProcessor.maxTextFileChars) chars"))
        XCTAssertTrue(attachment.subtitle.contains("trimmed"))
    }

    func testBlocksPrivateKeysAndUnknownBinaries() throws {
        let pemURL = tempDir.appendingPathComponent("prod.pem")
        try "synthetic-pem-fixture".write(to: pemURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try AIMediaAttachmentProcessor.processFile(at: pemURL)) { error in
            XCTAssertEqual(error as? AIMediaAttachmentError, .blockedSecretFile("prod.pem"))
        }

        let sshURL = tempDir.appendingPathComponent("id_rsa")
        try "secret".write(to: sshURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AIMediaAttachmentProcessor.processFile(at: sshURL)) { error in
            XCTAssertEqual(error as? AIMediaAttachmentError, .blockedSecretFile("id_rsa"))
        }

        let binURL = tempDir.appendingPathComponent("archive.bin")
        try Data([0x00, 0x01, 0x02, 0xFF, 0x00, 0x42]).write(to: binURL)
        XCTAssertThrowsError(try AIMediaAttachmentProcessor.processFile(at: binURL)) { error in
            XCTAssertEqual(error as? AIMediaAttachmentError, .unsupportedBinaryFile("archive.bin"))
        }
    }

    func testPDFProcessingRendersPageOneSnapshot() throws {
        let pdfURL = tempDir.appendingPathComponent("report.pdf")
        try makeTestPDF(at: pdfURL)

        let attachment = try AIMediaAttachmentProcessor.processFile(at: pdfURL)
        XCTAssertEqual(attachment.kind, .pdf)
        XCTAssertEqual(attachment.images.count, 1)
        XCTAssertEqual(attachment.images[0].mimeType, "image/jpeg")
        XCTAssertNotNil(attachment.thumbnailBase64)
        XCTAssertTrue(attachment.subtitle.contains("1 page"))
    }

    // MARK: - Multimodal Wire Serialization Tests

    func testMultimodalPayloadsAcrossProviders() throws {
        let client = AIHTTPProviderClient()
        let img = AIImagePayload(mimeType: "image/png", base64Data: "iVBORw0KGgo=", localFilePath: "/tmp/screen.png")
        let req = AIChatRequest(
            systemPrompt: "You are a QA assistant.",
            messages: [AIChatMessage(role: .user, content: "Inspect this screenshot", images: [img])]
        )

        // 1. Ollama: messages[].images = [base64]
        let ollamaProfile = AIProviderProfile(kind: .ollama, modelID: "gemma3:12b")
        let ollamaReq = try client.buildChatRequest(request: req, profile: ollamaProfile, apiKey: nil)
        let ollamaJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(ollamaReq.httpBody)) as? [String: Any])
        let ollamaMsgs = try XCTUnwrap(ollamaJSON["messages"] as? [[String: Any]])
        let ollamaUser = try XCTUnwrap(ollamaMsgs.last)
        XCTAssertEqual(ollamaUser["images"] as? [String], ["iVBORw0KGgo="])

        // 2. Anthropic: content[] with image source base64
        let anthropicProfile = AIProviderProfile(kind: .anthropic, modelID: "claude-sonnet-4-20250514")
        let anthropicReq = try client.buildChatRequest(request: req, profile: anthropicProfile, apiKey: "sk-ant-test")
        let anthropicJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(anthropicReq.httpBody)) as? [String: Any])
        let anthropicMsgs = try XCTUnwrap(anthropicJSON["messages"] as? [[String: Any]])
        let anthropicBlocks = try XCTUnwrap(anthropicMsgs[0]["content"] as? [[String: Any]])
        XCTAssertEqual(anthropicBlocks.count, 2)
        XCTAssertEqual(anthropicBlocks[0]["type"] as? String, "image")
        let source = try XCTUnwrap(anthropicBlocks[0]["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "iVBORw0KGgo=")

        // 3. OpenAI: content[] with image_url data URI
        let openAIProfile = AIProviderProfile(kind: .openAI, modelID: "gpt-4.1")
        let openAIReq = try client.buildChatRequest(request: req, profile: openAIProfile, apiKey: "sk-test")
        let openAIJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(openAIReq.httpBody)) as? [String: Any])
        let openAIMsgs = try XCTUnwrap(openAIJSON["messages"] as? [[String: Any]])
        let openAIBlocks = try XCTUnwrap(openAIMsgs.last?["content"] as? [[String: Any]])
        XCTAssertEqual(openAIBlocks.count, 2)
        XCTAssertEqual(openAIBlocks[1]["type"] as? String, "image_url")
        let imageURLObj = try XCTUnwrap(openAIBlocks[1]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURLObj["url"] as? String, "data:image/png;base64,iVBORw0KGgo=")

        // 4. Gemini: parts[] with inline_data
        let geminiProfile = AIProviderProfile(kind: .gemini, modelID: "gemini-2.5-flash")
        let geminiReq = try client.buildChatRequest(request: req, profile: geminiProfile, apiKey: "AIza-test")
        let geminiJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(geminiReq.httpBody)) as? [String: Any])
        let contents = try XCTUnwrap(geminiJSON["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        let inlineData = try XCTUnwrap(parts[0]["inline_data"] as? [String: Any])
        XCTAssertEqual(inlineData["mime_type"] as? String, "image/png")
        XCTAssertEqual(inlineData["data"] as? String, "iVBORw0KGgo=")
        XCTAssertEqual(parts[1]["text"] as? String, "Inspect this screenshot")
    }

    func testCodexCLIAttachesImagePaths() throws {
        let imgURL = tempDir.appendingPathComponent("ui.png")
        try makeTestPNGData(width: 100, height: 100).write(to: imgURL)

        let profile = AIProviderProfile(kind: .codexCLI, modelID: "o4-mini")
        let req = AIChatRequest(
            systemPrompt: "QA helper",
            messages: [
                AIChatMessage(
                    role: .user,
                    content: "Check layout",
                    images: [AIImagePayload(mimeType: "image/png", base64Data: "abc", localFilePath: imgURL.path)]
                )
            ]
        )

        let invocation = try AICLIProviderClient.buildInvocation(
            profile: profile,
            request: req,
            resolvedExecutable: URL(fileURLWithPath: "/usr/local/bin/codex")
        )
        XCTAssertTrue(invocation.arguments.contains("-i"))
        XCTAssertTrue(invocation.arguments.contains(imgURL.path))
    }

    func testConversationStoreStripsHeavyImagePayloadsButKeepsThumbnails() throws {
        let store = AIConversationStore(baseDirectory: tempDir)
        let summary = AIAttachedContextSummary(
            id: "img-1",
            kind: .userImage,
            label: "error.png",
            byteCount: 2048,
            thumbnailBase64: "thumb123"
        )
        let msg = AIChatMessage(
            role: .user,
            content: "Why did this fail?",
            attachedSummaries: [summary],
            images: [AIImagePayload(mimeType: "image/png", base64Data: String(repeating: "A", count: 50_000))]
        )
        let session = AIChatSession(title: "Visual Debug", workspacePath: "/tmp/ws", messages: [msg])
        store.saveSessions([session], forWorkspacePath: "/tmp/ws")

        let loaded = store.loadSessions(forWorkspacePath: "/tmp/ws")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertTrue(loaded[0].messages[0].images.isEmpty)
        XCTAssertEqual(loaded[0].messages[0].attachedSummaries.first?.thumbnailBase64, "thumb123")
    }

    // MARK: - Adversarial Security & Host-Isolation Tests

    func testBlocksSymlinksToSensitiveFilesAndDotEnvWhileAllowingEnvExample() throws {
        let envURL = tempDir.appendingPathComponent(".env")
        try "DB_PASSWORD=supersecret".write(to: envURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AIMediaAttachmentProcessor.processFile(at: envURL)) { err in
            XCTAssertEqual(err as? AIMediaAttachmentError, .blockedSecretFile(".env"))
        }

        let envLocalURL = tempDir.appendingPathComponent(".env.production")
        try "SECRET=123".write(to: envLocalURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AIMediaAttachmentProcessor.processFile(at: envLocalURL)) { err in
            XCTAssertEqual(err as? AIMediaAttachmentError, .blockedSecretFile(".env.production"))
        }

        // Symlink inside workspace pointing to a blocked .env or private key must be rejected
        let symlinkURL = tempDir.appendingPathComponent("harmless_notes.txt")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: envURL)
        XCTAssertTrue(AIMediaAttachmentProcessor.isBlockedSecretFile(url: symlinkURL))
        XCTAssertThrowsError(try AIMediaAttachmentProcessor.processFile(at: symlinkURL)) { err in
            XCTAssertEqual(err as? AIMediaAttachmentError, .blockedSecretFile("harmless_notes.txt"))
        }

        // Sensitive home directories (~/.ssh, ~/.aws, etc.) must be blocked
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(AIMediaAttachmentProcessor.isBlockedSecretFile(url: home.appendingPathComponent(".ssh/config")))
        XCTAssertTrue(AIMediaAttachmentProcessor.isBlockedSecretFile(url: home.appendingPathComponent(".aws/credentials")))
        XCTAssertTrue(AIMediaAttachmentProcessor.isBlockedSecretFile(url: URL(fileURLWithPath: "/etc/passwd")))

        // Safe template .env.example is allowed
        let envExampleURL = tempDir.appendingPathComponent(".env.example")
        try "BASE_URL=https://example.com\n".write(to: envExampleURL, atomically: true, encoding: .utf8)
        let exampleAttachment = try AIMediaAttachmentProcessor.processFile(at: envExampleURL)
        XCTAssertEqual(exampleAttachment.kind, .textFile)
    }

    func testActiveFileContextExcludesSensitiveDotEnvOrKeyFilesAutomatically() {
        let input = AIContextInput(
            activeFilePath: "/tmp/project/.env.local",
            activeFileRelativePath: ".env.local",
            activeFileLanguage: "env",
            activeFileContent: "INTERNAL_WEBHOOK=https://hooks.internal/secret",
            selectedText: "INTERNAL_WEBHOOK=https://hooks.internal/secret"
        )
        let attachments = AIContextAssembler.availableAttachments(from: input, redactSecrets: true)
        XCTAssertNil(attachments.first(where: { $0.kind == .activeFile }))
        XCTAssertNil(attachments.first(where: { $0.kind == .selection }))
    }

    func testCLISubprocessEnvironmentScrubsHostSecretsAndUsesIsolatedSandboxDir() throws {
        let awsKeyName = ["AWS", "SECRET", "ACCESS", "KEY"].joined(separator: "_")
        let pollutedEnv: [String: String] = [
            "HOME": "/Users/tester",
            "PATH": "/usr/bin:/bin",
            awsKeyName: "synthetic-value",
            "DATABASE_URL": ["postgres", "://", "user", ":", "val", "@localhost/db"].joined(),
            "OPENAI_API_KEY": "synthetic-openai-val",
            "SSH_AUTH_SOCK": "/private/tmp/com.apple.launchd.xyz/Listeners",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "NODE_OPTIONS": "--require /tmp/preload.js"
        ]
        let sanitized = AICLIProviderClient.buildSanitizedEnvironment(base: pollutedEnv)
        XCTAssertEqual(sanitized["HOME"], "/Users/tester")
        XCTAssertNil(sanitized[awsKeyName])
        XCTAssertNil(sanitized["DATABASE_URL"])
        XCTAssertNil(sanitized["OPENAI_API_KEY"])
        XCTAssertNil(sanitized["SSH_AUTH_SOCK"])
        XCTAssertNil(sanitized["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(sanitized["NODE_OPTIONS"])

        let req = AIChatRequest(
            systemPrompt: "Helper",
            messages: [AIChatMessage(role: .user, content: "Hi")],
            workspaceRoot: URL(fileURLWithPath: "/Users/tester/SensitiveProject")
        )
        let profile = AIProviderProfile(kind: .claudeCLI, modelID: "sonnet")
        let inv = try AICLIProviderClient.buildInvocation(
            profile: profile,
            request: req,
            resolvedExecutable: URL(fileURLWithPath: "/usr/local/bin/claude")
        )
        XCTAssertNotEqual(inv.workingDirectory?.path, "/Users/tester/SensitiveProject")
        XCTAssertTrue(inv.workingDirectory?.lastPathComponent == "ceptra-ai-cli-sandbox")
    }

    func testRedactorScrubsPrivateKeyBlocksAndDatabaseConnectionURIs() {
        let tag = ["RSA", "PRIVATE", "KEY"].joined(separator: " ")
        let header = "-----BEGIN \(tag)-----"
        let footer = "-----END \(tag)-----"
        let body = "MIIEpAIBAAKCAQEA7"
        let pem = "\(header)\n\(body)\n\(footer)"
        let cred = ["dbadmin", "syntheticPass99"].joined(separator: ":")
        let pg = ["postgres", "://", cred, "@db.example.internal:5432/production"].joined()
        let sample = "Config leaked:\n\(pem)\nand url \(pg)"
        let result = AISecretRedactor.redact(sample)
        XCTAssertTrue(result.wasRedacted)
        XCTAssertFalse(result.text.contains(body))
        XCTAssertFalse(result.text.contains("syntheticPass99"))
        XCTAssertTrue(result.text.contains("[REDACTED_PRIVATE_KEY_BLOCK]"))
        XCTAssertTrue(result.text.contains("[REDACTED_CONNECTION_URI]"))
    }

    func testPermissionModesControlCLISandboxAndAlwaysBlockSensitiveDirectories() throws {
        // Legacy JSON without permissionMode decodes safely to .askToProceed
        let legacyJSON = #"{"profiles":[],"redactSecretsInCloudContext":true}"#
        let decoded = try JSONDecoder().decode(AISettings.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.permissionMode, .askToProceed)

        let safeProjectDir = tempDir.appendingPathComponent("codecept-project", isDirectory: true)
        try FileManager.default.createDirectory(at: safeProjectDir, withIntermediateDirectories: true)

        // 1. Read-Only & Ask-to-Proceed: isolated sandbox, zero tools / read-only
        let askReq = AIChatRequest(
            systemPrompt: "Helper",
            messages: [AIChatMessage(role: .user, content: "Fix test")],
            workspaceRoot: safeProjectDir,
            permissionMode: .askToProceed
        )
        let claudeAsk = try AICLIProviderClient.buildInvocation(
            profile: AIProviderProfile(kind: .claudeCLI, modelID: "sonnet"),
            request: askReq,
            resolvedExecutable: URL(fileURLWithPath: "/usr/local/bin/claude")
        )
        XCTAssertEqual(claudeAsk.workingDirectory?.lastPathComponent, "ceptra-ai-cli-sandbox")
        XCTAssertTrue(claudeAsk.arguments.contains("--tools"))
        XCTAssertFalse(claudeAsk.arguments.contains("--allowedTools"))

        // 2. Full Workspace mode on a safe project dir: scoped file tools (NO Bash) & workspace-write
        let fullReq = AIChatRequest(
            systemPrompt: "Helper",
            messages: [AIChatMessage(role: .user, content: "Fix test")],
            workspaceRoot: safeProjectDir,
            permissionMode: .fullWorkspace
        )
        let claudeFull = try AICLIProviderClient.buildInvocation(
            profile: AIProviderProfile(kind: .claudeCLI, modelID: "sonnet"),
            request: fullReq,
            resolvedExecutable: URL(fileURLWithPath: "/usr/local/bin/claude")
        )
        XCTAssertEqual(
            claudeFull.workingDirectory?.standardizedFileURL.resolvingSymlinksInPath().path,
            safeProjectDir.standardizedFileURL.resolvingSymlinksInPath().path
        )
        XCTAssertTrue(claudeFull.arguments.contains("--allowedTools"))
        XCTAssertTrue(claudeFull.arguments.contains("Read,Edit,Write,Glob,Grep"))
        XCTAssertFalse(claudeFull.arguments.joined(separator: " ").contains("Bash"))

        let codexFull = try AICLIProviderClient.buildInvocation(
            profile: AIProviderProfile(kind: .codexCLI, modelID: "o4-mini"),
            request: fullReq,
            resolvedExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        )
        XCTAssertTrue(codexFull.arguments.contains("workspace-write"))

        // 3. Full Workspace mode pointing at a sensitive dir (~/.ssh) MUST fall back to isolated sandbox!
        let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        let hostileFullReq = AIChatRequest(
            systemPrompt: "Helper",
            messages: [AIChatMessage(role: .user, content: "Inspect")],
            workspaceRoot: sshDir,
            permissionMode: .fullWorkspace
        )
        let claudeHostile = try AICLIProviderClient.buildInvocation(
            profile: AIProviderProfile(kind: .claudeCLI, modelID: "sonnet"),
            request: hostileFullReq,
            resolvedExecutable: URL(fileURLWithPath: "/usr/local/bin/claude")
        )
        XCTAssertEqual(claudeHostile.workingDirectory?.lastPathComponent, "ceptra-ai-cli-sandbox")
        XCTAssertTrue(claudeHostile.arguments.contains("--tools"))
        XCTAssertFalse(claudeHostile.arguments.contains("--allowedTools"))
    }
}
