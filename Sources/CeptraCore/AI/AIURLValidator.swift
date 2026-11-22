import Foundation

/// Enforces HTTPS-first, SSRF-safe, and redirect-safe URLs for AI HTTP providers.
public enum AIURLValidator {
    private static let blockedMetadataHosts: Set<String> = [
        "169.254.169.254",
        "169.254.170.2",
        "metadata.google.internal",
        "metadata",
        "fd00:ec2::254",
        "[fd00:ec2::254]"
    ]

    public static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "[::1]"
    }

    public static func isLoopbackBaseURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host else {
            return false
        }
        return isLoopbackHost(host)
    }

    /// Validates and normalizes a provider base URL (strips trailing slash).
    public static func validateBaseURL(
        _ raw: String,
        allowInsecureLocalHTTP: Bool = false
    ) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AIProviderError.invalidBaseURL("Base URL cannot be empty.")
        }
        guard var components = URLComponents(string: trimmed) else {
            throw AIProviderError.invalidBaseURL("Malformed URL syntax.")
        }
        guard let scheme = components.scheme?.lowercased(), !scheme.isEmpty else {
            throw AIProviderError.invalidBaseURL("URL must include http:// or https://.")
        }
        guard scheme == "https" || scheme == "http" else {
            throw AIProviderError.invalidBaseURL("Unsupported scheme '\(scheme)://'. Only https:// (or local http://) is allowed.")
        }
        if components.user != nil || components.password != nil {
            throw AIProviderError.invalidBaseURL("Embedded credentials in URLs are forbidden. Store API keys in macOS Keychain instead.")
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw AIProviderError.invalidBaseURL("URL must include a valid host.")
        }
        if blockedMetadataHosts.contains(host) || host.hasPrefix("169.254.") {
            throw AIProviderError.invalidBaseURL("Link-local and cloud metadata hosts ('\(host)') are blocked.")
        }

        if scheme == "http" && !isLoopbackHost(host) {
            if !(allowInsecureLocalHTTP && isPrivateLANHost(host)) {
                throw AIProviderError.insecureRemoteURL(host)
            }
        }

        // Normalize trailing slash so callers can append endpoint paths cleanly
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.query = nil
        components.fragment = nil

        guard let normalized = components.url else {
            throw AIProviderError.invalidBaseURL("Unable to construct normalized URL.")
        }
        return normalized
    }

    /// Returns true if two URLs share identical scheme, host (case-insensitive), and effective port.
    public static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lScheme = lhs.scheme?.lowercased(),
              let rScheme = rhs.scheme?.lowercased(),
              lScheme == rScheme,
              let lHost = lhs.host?.lowercased(),
              let rHost = rhs.host?.lowercased(),
              lHost == rHost else {
            return false
        }
        let lPort = lhs.port ?? defaultPort(for: lScheme)
        let rPort = rhs.port ?? defaultPort(for: rScheme)
        return lPort == rPort
    }

    public static func isPrivateLANHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower.hasSuffix(".local") || lower.hasSuffix(".lan") || lower.hasSuffix(".internal") {
            return !blockedMetadataHosts.contains(lower)
        }
        let octets = lower.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        if octets[0] == 10 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        return false
    }

    private static func defaultPort(for scheme: String) -> Int {
        scheme == "https" ? 443 : 80
    }
}

/// URLSessionTaskDelegate that blocks cross-origin redirects so API keys / auth headers
/// are never forwarded to a different host or downgraded from HTTPS to HTTP.
public final class AISameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() {
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.originalRequest?.url,
              let nextURL = request.url,
              AIURLValidator.isSameOrigin(originalURL, nextURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
