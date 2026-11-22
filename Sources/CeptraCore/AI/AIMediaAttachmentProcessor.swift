import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum AIMediaAttachmentError: LocalizedError, Equatable, Sendable {
    case fileNotFound(String)
    case blockedSecretFile(String)
    case fileTooLarge(name: String, limitMB: Int)
    case unsupportedBinaryFile(String)
    case unreadableImage(String)
    case unreadablePDF(String)
    case unreadableVideo(String)
    case attachmentLimitReached(maxCount: Int)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let name):
            return "File not found: \(name)"
        case .blockedSecretFile(let name):
            return "Blocked attaching private key or credential file '\(name)' for security."
        case .fileTooLarge(let name, let limitMB):
            return "'\(name)' exceeds the \(limitMB) MB attachment size limit."
        case .unsupportedBinaryFile(let name):
            return "'\(name)' is an unsupported binary format. Attach images, PDFs, videos (.mp4/.mov), or text/code files."
        case .unreadableImage(let name):
            return "Could not decode image '\(name)'."
        case .unreadablePDF(let name):
            return "Could not open PDF document '\(name)'."
        case .unreadableVideo(let name):
            return "Could not extract video frames from '\(name)'."
        case .attachmentLimitReached(let maxCount):
            return "You can attach up to \(maxCount) files or media items per message."
        }
    }
}

/// Zero-dependency native macOS processor for attaching images, code/text files,
/// PDFs (`PDFKit`), and test videos (`AVFoundation`) to Ceptra AI prompts.
public enum AIMediaAttachmentProcessor {
    public static let maxAttachmentsPerMessage = 6
    public static let maxVisionFramesPerMessage = 4
    public static let maxFileSizeBytes = 25 * 1024 * 1024
    public static let maxVideoSizeBytes = 50 * 1024 * 1024
    public static let maxTextFileChars = 24_000
    public static let maxImageLongEdgePx = 1568
    public static let thumbnailLongEdgePx = 140

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tiff", "tif", "bmp"
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v"
    ]

    private static let blockedSecretExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "jks", "keystore", "ppk", "kdbx",
        "keychain", "keychain-db", "ovpn", "mobileprovision", "cer", "crt", "der", "asc", "gpg", "pgp"
    ]

    private static let blockedSecretFilenames: Set<String> = [
        "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", "authorized_keys", "known_hosts",
        ".netrc", ".pgpass", ".my.cnf", ".npmrc", ".pypirc", ".dockercfg",
        "credentials", "credentials.json", "application_default_credentials.json",
        "service-account.json", "service_account.json", "kubeconfig",
        "secrets.json", "secrets.yaml", "secrets.yml", "vault.json",
        "master.key", "credentials.yml.enc",
        ".zsh_history", ".bash_history", ".node_repl_history", ".psql_history", ".mysql_history", ".sqlite_history"
    ]

    private static let allowedEnvTemplateNames: Set<String> = [
        ".env.example", ".env.sample", ".env.template", ".env.defaults", ".env.dist"
    ]

    private static let blockedHomeRelativeSubpaths: [String] = [
        ".ssh", ".aws", ".gnupg", ".kube", ".docker",
        ".config/gh", ".config/gcloud", ".config/op",
        ".claude", ".codex",
        "Library/Keychains", "Library/Cookies", "Library/Mail", "Library/Messages", "Library/Safari",
        "Library/Application Support/Ceptra"
    ]

    private static let blockedSystemPathPrefixes: [String] = [
        "/etc/", "/private/etc/", "/var/db/", "/private/var/db/", "/System/"
    ]

    private static let untrustedTextExtensions: Set<String> = [
        "log", "html", "htm", "xml", "svg", "csv", "txt"
    ]

    public static func isBlockedSecretFile(url: URL) -> Bool {
        let candidates = [
            url.standardizedFileURL,
            url.standardizedFileURL.resolvingSymlinksInPath()
        ]
        for candidate in candidates {
            if isSingleURLBlocked(candidate) {
                return true
            }
        }
        return false
    }

    private static func isSingleURLBlocked(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if blockedSecretExtensions.contains(ext) { return true }
        if blockedSecretFilenames.contains(name) { return true }
        if name.hasPrefix("id_rsa.") || name.hasPrefix("id_ed25519.") || name.hasPrefix("id_ecdsa.") || name.hasPrefix("id_dsa.") {
            return true
        }
        // Block .env and .env.<environment> secret files while allowing .env.example / .env.sample
        if name == ".env" || (name.hasPrefix(".env.") && !allowedEnvTemplateNames.contains(name)) {
            return true
        }

        let path = url.path
        for sysPrefix in blockedSystemPathPrefixes {
            if path.hasPrefix(sysPrefix) || path == String(sysPrefix.dropLast()) {
                return true
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        let rawHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for homeRoot in Set([home, rawHome]) where !homeRoot.isEmpty {
            for rel in blockedHomeRelativeSubpaths {
                let restrictedDir = homeRoot + "/" + rel
                if path == restrictedDir || path.hasPrefix(restrictedDir + "/") {
                    return true
                }
            }
        }
        return false
    }

    public static func processFile(
        at url: URL,
        workspaceRoot: URL? = nil,
        redactSecrets: Bool = true,
        explicitSecrets: [String] = []
    ) throws -> AIUserAttachment {
        let fm = FileManager.default
        if isBlockedSecretFile(url: url) {
            throw AIMediaAttachmentError.blockedSecretFile(url.lastPathComponent)
        }
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        if isBlockedSecretFile(url: standardized) {
            throw AIMediaAttachmentError.blockedSecretFile(url.lastPathComponent)
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: standardized.path, isDirectory: &isDir), !isDir.boolValue else {
            throw AIMediaAttachmentError.fileNotFound(url.lastPathComponent)
        }

        let attrs = try? fm.attributesOfItem(atPath: standardized.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let ext = standardized.pathExtension.lowercased()

        if videoExtensions.contains(ext) {
            guard fileSize <= maxVideoSizeBytes else {
                throw AIMediaAttachmentError.fileTooLarge(name: standardized.lastPathComponent, limitMB: 50)
            }
            return try processVideo(at: standardized, fileSize: fileSize)
        }

        guard fileSize <= maxFileSizeBytes else {
            throw AIMediaAttachmentError.fileTooLarge(name: standardized.lastPathComponent, limitMB: 25)
        }

        if imageExtensions.contains(ext) {
            let data = try Data(contentsOf: standardized)
            return try processImageData(
                data,
                displayName: standardized.lastPathComponent,
                filePath: standardized.path
            )
        }

        if ext == "pdf" {
            return try processPDF(
                at: standardized,
                fileSize: fileSize,
                redactSecrets: redactSecrets,
                explicitSecrets: explicitSecrets
            )
        }

        return try processTextFile(
            at: standardized,
            workspaceRoot: workspaceRoot,
            fileSize: fileSize,
            redactSecrets: redactSecrets,
            explicitSecrets: explicitSecrets
        )
    }

    // MARK: - Image Processing (CGImageSource + Optimized JPEG/PNG + Thumbnail)

    public static func processImageData(
        _ data: Data,
        displayName: String,
        filePath: String? = nil,
        persistTempFileIfNeeded: Bool = false
    ) throws -> AIUserAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AIMediaAttachmentError.unreadableImage(displayName)
        }

        let origW = cgImage.width
        let origH = cgImage.height
        let resized = resizeCGImage(cgImage, maxLongEdge: maxImageLongEdgePx) ?? cgImage

        let hasAlpha = cgImageHasMeaningfulAlpha(resized)
        let encoded: (data: Data, mimeType: String)
        if hasAlpha && data.count <= 900_000, let pngData = encodeCGImage(resized, type: UTType.png.identifier, quality: 1.0) {
            encoded = (pngData, "image/png")
        } else if let jpgData = encodeCGImage(resized, type: UTType.jpeg.identifier, quality: 0.84) {
            encoded = (jpgData, "image/jpeg")
        } else if let pngData = encodeCGImage(resized, type: UTType.png.identifier, quality: 1.0) {
            encoded = (pngData, "image/png")
        } else {
            throw AIMediaAttachmentError.unreadableImage(displayName)
        }

        let thumbImg = resizeCGImage(resized, maxLongEdge: thumbnailLongEdgePx) ?? resized
        let thumbData = encodeCGImage(thumbImg, type: UTType.jpeg.identifier, quality: 0.72)

        var resolvedPath = filePath
        if resolvedPath == nil && persistTempFileIfNeeded {
            let ext = encoded.mimeType == "image/png" ? "png" : "jpg"
            let tmpDir = temporaryMediaDirectoryURL()
            try? FileManager.default.createDirectory(
                at: tmpDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path)
            let tmpURL = tmpDir.appendingPathComponent("paste-\(UUID().uuidString.prefix(8)).\(ext)")
            if (try? encoded.data.write(to: tmpURL, options: .atomic)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)
                resolvedPath = tmpURL.path
            }
        }

        let payload = AIImagePayload(
            mimeType: encoded.mimeType,
            base64Data: encoded.data.base64EncodedString(),
            localFilePath: resolvedPath
        )
        let subtitle = "\(origW)×\(origH) · \(formatBytes(encoded.data.count))"

        return AIUserAttachment(
            kind: .image,
            displayName: displayName,
            filePath: resolvedPath,
            byteCount: encoded.data.count,
            subtitle: subtitle,
            textContent: nil,
            images: [payload],
            thumbnailBase64: thumbData?.base64EncodedString(),
            wasRedacted: false
        )
    }

    // MARK: - PDF Processing (PDFKit Text Extraction + Page 1 Vision Snapshot)

    private static func processPDF(
        at url: URL,
        fileSize: Int,
        redactSecrets: Bool,
        explicitSecrets: [String]
    ) throws -> AIUserAttachment {
        guard let doc = PDFDocument(url: url) else {
            throw AIMediaAttachmentError.unreadablePDF(url.lastPathComponent)
        }

        let pageCount = doc.pageCount
        var extractedChunks: [String] = []
        var totalChars = 0
        for idx in 0..<pageCount {
            guard let page = doc.page(at: idx), let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !pageText.isEmpty else {
                continue
            }
            let block = "--- Page \(idx + 1) ---\n\(pageText)"
            extractedChunks.append(block)
            totalChars += block.count
            if totalChars >= maxTextFileChars { break }
        }

        var rawText = extractedChunks.joined(separator: "\n\n")
        if rawText.count > maxTextFileChars {
            rawText = String(rawText.prefix(maxTextFileChars)) + "\n... (PDF text truncated at \(maxTextFileChars) chars)"
        }

        let processed = redactSecrets
            ? AISecretRedactor.redact(rawText, explicitSecrets: explicitSecrets)
            : AISecretRedactor.Result(text: rawText, redactionCount: 0)

        let formattedText: String? = processed.text.isEmpty ? nil : """
        <untrusted_file_context name="\(url.lastPathComponent)" type="pdf" pages="\(pageCount)">
        \(processed.text)
        </untrusted_file_context>
        """

        // Render page 1 as a vision image so multimodal models can also read diagrams/tables/scanned PDFs
        var images: [AIImagePayload] = []
        var thumbBase64: String? = nil
        if let firstPage = doc.page(at: 0),
           let cg = renderPDFPage(firstPage, maxLongEdge: 1280) {
            if let jpgData = encodeCGImage(cg, type: UTType.jpeg.identifier, quality: 0.82) {
                images.append(AIImagePayload(mimeType: "image/jpeg", base64Data: jpgData.base64EncodedString(), localFilePath: nil))
            }
            if let thumb = resizeCGImage(cg, maxLongEdge: thumbnailLongEdgePx),
               let thumbData = encodeCGImage(thumb, type: UTType.jpeg.identifier, quality: 0.72) {
                thumbBase64 = thumbData.base64EncodedString()
            }
        }

        let subtitle = "\(pageCount) page\(pageCount == 1 ? "" : "s") · \(formatBytes(fileSize))"
        return AIUserAttachment(
            kind: .pdf,
            displayName: url.lastPathComponent,
            filePath: url.path,
            byteCount: fileSize,
            subtitle: subtitle,
            textContent: formattedText,
            images: images,
            thumbnailBase64: thumbBase64,
            wasRedacted: processed.wasRedacted
        )
    }

    // MARK: - Video Processing (AVFoundation 3-Keyframe Extraction)

    private static func processVideo(at url: URL, fileSize: Int) throws -> AIUserAttachment {
        let asset = AVURLAsset(url: url)
        let durationSeconds = loadVideoDurationSeconds(for: asset)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw AIMediaAttachmentError.unreadableVideo(url.lastPathComponent)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let fractions: [Double] = durationSeconds < 1.5 ? [0.1, 0.85] : [0.10, 0.50, 0.90]
        var frames: [AIImagePayload] = []
        var thumbBase64: String? = nil

        for frac in fractions {
            let t = CMTime(seconds: max(0.0, durationSeconds * frac), preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: t, actualTime: nil),
               let jpg = encodeCGImage(cg, type: UTType.jpeg.identifier, quality: 0.80) {
                frames.append(AIImagePayload(mimeType: "image/jpeg", base64Data: jpg.base64EncodedString(), localFilePath: nil))
                if thumbBase64 == nil,
                   let thumb = resizeCGImage(cg, maxLongEdge: thumbnailLongEdgePx),
                   let thumbData = encodeCGImage(thumb, type: UTType.jpeg.identifier, quality: 0.72) {
                    thumbBase64 = thumbData.base64EncodedString()
                }
            }
        }

        guard !frames.isEmpty else {
            throw AIMediaAttachmentError.unreadableVideo(url.lastPathComponent)
        }

        let durationText = String(format: "%.1fs", durationSeconds)
        let textSummary = "Attached video recording '\(url.lastPathComponent)' (duration: \(durationText), \(frames.count) extracted keyframes at start, middle, and end)."
        let subtitle = "\(durationText) · \(frames.count) frames"

        return AIUserAttachment(
            kind: .video,
            displayName: url.lastPathComponent,
            filePath: url.path,
            byteCount: fileSize,
            subtitle: subtitle,
            textContent: textSummary,
            images: frames,
            thumbnailBase64: thumbBase64,
            wasRedacted: false
        )
    }

    // MARK: - Text / Code / Config / Log File Processing

    private static func processTextFile(
        at url: URL,
        workspaceRoot: URL?,
        fileSize: Int,
        redactSecrets: Bool,
        explicitSecrets: [String]
    ) throws -> AIUserAttachment {
        let data = try Data(contentsOf: url)
        // Reject NUL-heavy arbitrary binary files cleanly
        let probeSlice = data.prefix(4096)
        if probeSlice.contains(0) {
            throw AIMediaAttachmentError.unsupportedBinaryFile(url.lastPathComponent)
        }
        guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw AIMediaAttachmentError.unsupportedBinaryFile(url.lastPathComponent)
        }

        let displayPath: String
        if let root = workspaceRoot?.standardizedFileURL.path,
           url.path.hasPrefix(root + "/") {
            displayPath = String(url.path.dropFirst(root.count + 1))
        } else {
            displayPath = url.lastPathComponent
        }

        var trimmed = decoded
        var wasTruncated = false
        if trimmed.count > maxTextFileChars {
            trimmed = String(trimmed.prefix(maxTextFileChars)) + "\n// ... (file truncated at \(maxTextFileChars) chars)"
            wasTruncated = true
        }

        let processed = redactSecrets
            ? AISecretRedactor.redact(trimmed, explicitSecrets: explicitSecrets)
            : AISecretRedactor.Result(text: trimmed, redactionCount: 0)

        let ext = url.pathExtension.lowercased()
        let formatted: String
        if untrustedTextExtensions.contains(ext) {
            formatted = """
            <untrusted_file_context name="\(displayPath)">
            \(processed.text)
            </untrusted_file_context>
            """
        } else {
            let lang = ext.isEmpty ? "text" : ext
            formatted = "Attached file: \(displayPath)\n```\(lang)\n\(processed.text)\n```"
        }

        let subtitle = formatBytes(fileSize) + (wasTruncated ? " · trimmed" : "")
        return AIUserAttachment(
            kind: .textFile,
            displayName: url.lastPathComponent,
            filePath: url.path,
            byteCount: fileSize,
            subtitle: subtitle,
            textContent: formatted,
            images: [],
            thumbnailBase64: nil,
            wasRedacted: processed.wasRedacted
        )
    }

    // MARK: - CoreGraphics & PDF Rendering Helpers

    private static func resizeCGImage(_ image: CGImage, maxLongEdge: Int) -> CGImage? {
        let w = image.width
        let h = image.height
        let longest = max(w, h)
        guard longest > maxLongEdge, maxLongEdge > 0 else { return image }

        let scale = CGFloat(maxLongEdge) / CGFloat(longest)
        let newW = max(1, Int((CGFloat(w) * scale).rounded()))
        let newH = max(1, Int((CGFloat(h) * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    private static func encodeCGImage(_ image: CGImage, type: String, quality: CGFloat) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static func cgImageHasMeaningfulAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }

    private static func renderPDFPage(_ page: PDFPage, maxLongEdge: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let longest = max(bounds.width, bounds.height)
        let scale = min(2.0, maxLongEdge / longest)
        let w = max(1, Int((bounds.width * scale).rounded()))
        let h = max(1, Int((bounds.height * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    private static func loadVideoDurationSeconds(for asset: AVURLAsset) -> Double {
        let sem = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var seconds: Double = 0 }
        let box = Box()
        Task.detached(priority: .userInitiated) {
            if let duration = try? await asset.load(.duration) {
                box.seconds = CMTimeGetSeconds(duration)
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 4.0)
        return box.seconds
    }

    public static func temporaryMediaDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ceptra-ai-media", isDirectory: true)
    }

    public static func cleanupTemporaryMediaFiles() {
        let dir = temporaryMediaDirectoryURL()
        try? FileManager.default.removeItem(at: dir)
    }

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
    }
}
