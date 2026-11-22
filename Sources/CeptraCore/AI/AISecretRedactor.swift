import Foundation

/// Scrubs known API keys, Bearer/Cookie headers, JWTs, and `.env`-style secrets
/// from error messages, logs, and outbound cloud AI context.
public enum AISecretRedactor {
    public struct Result: Equatable, Sendable {
        public let text: String
        public let redactionCount: Int

        public var wasRedacted: Bool { redactionCount > 0 }
    }

    private struct PatternRule {
        let regex: NSRegularExpression
        let replacement: String
    }

    private static let rules: [PatternRule] = {
        let specs: [(String, String)] = [
            // PEM private key blocks
            (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#, "[REDACTED_PRIVATE_KEY_BLOCK]"),
            // Provider-specific secret prefixes
            (#"\bsk-ant-[A-Za-z0-9_\-]{12,}\b"#, "[REDACTED_ANTHROPIC_KEY]"),
            (#"\bsk-(?:proj-|svcacct-|live-|test-)?[A-Za-z0-9_\-]{16,}\b"#, "[REDACTED_API_KEY]"),
            (#"\bAIza[0-9A-Za-z\-_]{20,}\b"#, "[REDACTED_GOOGLE_KEY]"),
            (#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b"#, "[REDACTED_GITHUB_TOKEN]"),
            (#"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#, "[REDACTED_GITHUB_PAT]"),
            (#"\bxox[baprs]-[A-Za-z0-9\-]{12,}\b"#, "[REDACTED_SLACK_TOKEN]"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "[REDACTED_AWS_KEY]"),
            // Database & message broker connection strings with credentials
            (#"(?i)\b(?:postgres|postgresql|mysql|mariadb|mongodb(?:\+srv)?|redis|rediss|amqps?)://[^\s\"',;<>]+"#, "[REDACTED_CONNECTION_URI]"),
            // Authorization / Cookie HTTP headers
            (#"(?i)(authorization\s*[:=]\s*(?:bearer|basic|token)\s+)[^\s\"',;]+"#, "$1[REDACTED]"),
            (#"(?i)(x-api-key\s*[:=]\s*)[^\s\"',;]+"#, "$1[REDACTED]"),
            (#"(?i)(x-goog-api-key\s*[:=]\s*)[^\s\"',;]+"#, "$1[REDACTED]"),
            (#"(?i)((?:set-)?cookie\s*[:=]\s*)[^\r\n]+"#, "$1[REDACTED_COOKIE]"),
            // JWTs (three base64url segments)
            (#"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#, "[REDACTED_JWT]"),
            // .env / config key=value secret assignments (at least 6 chars value)
            (#"(?i)(\b[A-Z0-9_]*(?:API_KEY|ACCESS_KEY|AUTH_TOKEN|SESSION_SECRET|WEBHOOK_SECRET|ENCRYPTION_KEY|SIGNING_KEY|MASTER_KEY|SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE_KEY|CLIENT_SECRET|DB_PASS)\b\s*[:=]\s*[\"']?)[^\s\"',;}{]{6,}([\"']?)"#, "$1[REDACTED]$2")
        ]
        return specs.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            return PatternRule(regex: regex, replacement: replacement)
        }
    }()

    public static func redact(
        _ input: String,
        explicitSecrets: [String] = []
    ) -> Result {
        guard !input.isEmpty else {
            return Result(text: input, redactionCount: 0)
        }
        var output = input
        var total = 0

        // 1. Exact redaction for any active provider secret values first
        for secret in explicitSecrets {
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 6 else { continue }
            if output.contains(trimmed) {
                let parts = output.components(separatedBy: trimmed)
                total += max(0, parts.count - 1)
                output = parts.joined(separator: "[REDACTED_SECRET]")
            }
        }

        // 2. Pattern-based redaction
        for rule in rules {
            let ns = output as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            let matches = rule.regex.numberOfMatches(in: output, options: [], range: fullRange)
            if matches > 0 {
                total += matches
                output = rule.regex.stringByReplacingMatches(
                    in: output,
                    options: [],
                    range: fullRange,
                    withTemplate: rule.replacement
                )
            }
        }

        return Result(text: output, redactionCount: total)
    }
}
