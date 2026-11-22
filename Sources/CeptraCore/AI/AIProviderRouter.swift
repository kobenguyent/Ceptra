import Foundation

/// Single entry point routing AI requests across HTTP and Local CLI providers.
public final class AIProviderRouter: Sendable {
    public let httpClient: AIHTTPProviderClient
    public let cliClient: AICLIProviderClient

    public init(
        httpClient: AIHTTPProviderClient = AIHTTPProviderClient(),
        cliClient: AICLIProviderClient = AICLIProviderClient()
    ) {
        self.httpClient = httpClient
        self.cliClient = cliClient
    }

    public func listModels(
        profile: AIProviderProfile,
        apiKey: String?
    ) async throws -> [AIModelDescriptor] {
        if profile.kind.isCLI {
            return profile.kind.curatedModels.map { AIModelDescriptor(id: $0) }
        }
        return try await httpClient.listModels(profile: profile, apiKey: apiKey)
    }

    public func testConnection(
        profile: AIProviderProfile,
        apiKey: String?
    ) async throws -> AIConnectionTestResult {
        if profile.kind.isCLI {
            return try await cliClient.testConnection(profile: profile)
        }
        return try await httpClient.testConnection(profile: profile, apiKey: apiKey)
    }

    public func streamChat(
        request: AIChatRequest,
        profile: AIProviderProfile,
        apiKey: String?
    ) -> AsyncThrowingStream<AIStreamDelta, Error> {
        if profile.kind.isCLI {
            return cliClient.streamChat(request: request, profile: profile)
        }
        return httpClient.streamChat(request: request, profile: profile, apiKey: apiKey)
    }

    public func cancelAllCLISubprocesses() {
        cliClient.cancelAll()
    }
}
