import Foundation

/// Persists API Studio collections & environments per workspace (inside `<workspace>/.ceptra/api-studio/studio.json`)
/// or in Application Support when no workspace is open.
public final class APIStudioStore: @unchecked Sendable {
    private let fallbackDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fallbackDirectory: URL? = nil) {
        if let fallbackDirectory {
            self.fallbackDirectory = fallbackDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fallbackDirectory = appSupport
                .appendingPathComponent("Ceptra", isDirectory: true)
                .appendingPathComponent("api-studio", isDirectory: true)
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public func storageURL(forWorkspaceRoot rootURL: URL?) -> URL {
        if let rootURL {
            return rootURL
                .appendingPathComponent(".ceptra", isDirectory: true)
                .appendingPathComponent("api-studio", isDirectory: true)
                .appendingPathComponent("studio.json")
        }
        return fallbackDirectory.appendingPathComponent("global.json")
    }

    public func load(workspaceRoot: URL?) -> APIStudioWorkspaceData {
        let url = storageURL(forWorkspaceRoot: workspaceRoot)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode(APIStudioWorkspaceData.self, from: data) else {
            return APIStudioWorkspaceData()
        }
        return decoded
    }

    public func save(_ studioData: APIStudioWorkspaceData, workspaceRoot: URL?) {
        let url = storageURL(forWorkspaceRoot: workspaceRoot)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(studioData)
            try data.write(to: url, options: .atomic)
        } catch {
            // Non-fatal persistence error; keep in-memory state intact
        }
    }

    /// Curated, live-runnable example collection templates users can load directly into API Studio.
    public enum ExampleTemplate: String, CaseIterable, Identifiable, Sendable {
        case restCRUDChaining
        case httpBinAuthPayloads
        case graphQLCountries

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .restCRUDChaining: return "REST CRUD & Variable Chaining (JSONPlaceholder)"
            case .httpBinAuthPayloads: return "Auth, Headers, Forms & Cookies (HTTPBin)"
            case .graphQLCountries: return "GraphQL Query & Variables (Countries API)"
            }
        }

        public var shortTitle: String {
            switch self {
            case .restCRUDChaining: return "REST CRUD & Chaining"
            case .httpBinAuthPayloads: return "Auth, Forms & Cookies"
            case .graphQLCountries: return "GraphQL Explorer"
            }
        }

        public var subtitle: String {
            switch self {
            case .restCRUDChaining:
                return "GET/POST/PUT/PATCH/DELETE, JSONPath assertions & chaining $.userId → {{lastUserId}}"
            case .httpBinAuthPayloads:
                return "Bearer/Basic/API Key auth, secret masking, {{$guid}}, form payloads & Set-Cookie"
            case .graphQLCountries:
                return "Live public GraphQL queries with JSON variables & nested JSONPath assertions"
            }
        }

        public var symbolName: String {
            switch self {
            case .restCRUDChaining: return "arrow.left.arrow.right"
            case .httpBinAuthPayloads: return "lock.shield"
            case .graphQLCountries: return "point.3.connected.trianglepath.dotted"
            }
        }
    }

    public static func makeExample(_ template: ExampleTemplate) -> (collection: APICollection, environments: [APIEnvironment]) {
        switch template {
        case .restCRUDChaining:
            let devEnv = APIEnvironment(
                name: "JSONPlaceholder Demo",
                sourceFormat: .ceptra,
                variables: [
                    APIEnvironmentVariable(key: "baseUrl", initialValue: "https://jsonplaceholder.typicode.com"),
                    APIEnvironmentVariable(key: "todoId", initialValue: "1"),
                    APIEnvironmentVariable(key: "postId", initialValue: "1")
                ]
            )
            let getTodo = APIRequestItem(
                name: "Get Todo by ID",
                description: "Fetches a single todo and extracts $.userId into {{lastUserId}} for the next request.",
                method: .get,
                url: "{{baseUrl}}/todos/{{todoId}}",
                headers: [APIKeyValueItem(key: "Accept", value: "application/json")],
                assertions: [
                    APIAssertionRule(name: "Status is 200", target: .statusCode, op: .equals, expectedValue: "200"),
                    APIAssertionRule(name: "ID matches env", target: .jsonPath, property: "$.id", op: .equals, expectedValue: "{{todoId}}"),
                    APIAssertionRule(name: "Title exists", target: .jsonPath, property: "$.title", op: .exists, expectedValue: ""),
                    APIAssertionRule(name: "Fast response (< 3s)", target: .responseTimeMs, op: .lessThan, expectedValue: "3000")
                ],
                extractors: [
                    APIVariableExtractor(source: .jsonPath, expression: "$.userId", targetVariableName: "lastUserId", scope: .environment)
                ]
            )
            let listUserTodos = APIRequestItem(
                name: "List Todos for Extracted User",
                description: "Chains {{lastUserId}} extracted from Get Todo by ID as a query parameter.",
                method: .get,
                url: "{{baseUrl}}/todos",
                queryParams: [APIKeyValueItem(key: "userId", value: "{{lastUserId}}")],
                headers: [APIKeyValueItem(key: "Accept", value: "application/json")],
                assertions: [
                    APIAssertionRule(name: "Status is 200", target: .statusCode, op: .equals, expectedValue: "200"),
                    APIAssertionRule(name: "First todo has title", target: .jsonPath, property: "$[0].title", op: .exists, expectedValue: "")
                ]
            )
            let createPost = APIRequestItem(
                name: "Create Post (JSON)",
                description: "Creates a new post payload with dynamic {{$guid}} correlation ID.",
                method: .post,
                url: "{{baseUrl}}/posts",
                headers: [
                    APIKeyValueItem(key: "Content-Type", value: "application/json"),
                    APIKeyValueItem(key: "Accept", value: "application/json"),
                    APIKeyValueItem(key: "X-Request-Id", value: "{{$guid}}")
                ],
                body: APIBodyConfig(
                    mode: .json,
                    rawText: """
                    {
                      "title": "API test from Ceptra",
                      "body": "Created at {{$isoTimestamp}}",
                      "userId": 1
                    }
                    """
                ),
                assertions: [
                    APIAssertionRule(name: "Created (201)", target: .statusCode, op: .equals, expectedValue: "201"),
                    APIAssertionRule(name: "Returns created title", target: .jsonPath, property: "$.title", op: .contains, expectedValue: "Ceptra")
                ]
            )
            let updatePost = APIRequestItem(
                name: "Update Post (PUT)",
                description: "Replaces an existing post resource.",
                method: .put,
                url: "{{baseUrl}}/posts/{{postId}}",
                headers: [APIKeyValueItem(key: "Content-Type", value: "application/json")],
                body: APIBodyConfig(
                    mode: .json,
                    rawText: """
                    {
                      "id": 1,
                      "title": "Updated Post Title",
                      "body": "Replaced via Ceptra API Studio",
                      "userId": 1
                    }
                    """
                ),
                assertions: [
                    APIAssertionRule(name: "Status is 200", target: .statusCode, op: .equals, expectedValue: "200"),
                    APIAssertionRule(name: "Title updated", target: .jsonPath, property: "$.title", op: .equals, expectedValue: "Updated Post Title")
                ]
            )
            let patchPost = APIRequestItem(
                name: "Patch Post Title",
                description: "Partially updates a post title.",
                method: .patch,
                url: "{{baseUrl}}/posts/{{postId}}",
                headers: [APIKeyValueItem(key: "Content-Type", value: "application/json")],
                body: APIBodyConfig(mode: .json, rawText: "{\n  \"title\": \"Patched via Ceptra\"\n}"),
                assertions: [
                    APIAssertionRule(name: "Status is 200", target: .statusCode, op: .equals, expectedValue: "200"),
                    APIAssertionRule(name: "Title patched", target: .jsonPath, property: "$.title", op: .contains, expectedValue: "Patched")
                ]
            )
            let deletePost = APIRequestItem(
                name: "Delete Post",
                description: "Deletes a post resource.",
                method: .delete,
                url: "{{baseUrl}}/posts/{{postId}}",
                assertions: [
                    APIAssertionRule(name: "Status is 200", target: .statusCode, op: .equals, expectedValue: "200")
                ]
            )
            let collection = APICollection(
                name: "REST CRUD & Chaining (JSONPlaceholder)",
                description: "Full CRUD collection demonstrating variables, JSONPath assertions, dynamic {{$guid}}, and variable chaining.",
                sourceFormat: .ceptra,
                variables: [APIKeyValueItem(key: "baseUrl", value: "https://jsonplaceholder.typicode.com")],
                folders: [
                    APIFolder(name: "Todos (Chained)", requests: [getTodo, listUserTodos]),
                    APIFolder(name: "Posts (CRUD)", requests: [createPost, updatePost, patchPost, deletePost])
                ]
            )
            return (collection, [devEnv])

        case .httpBinAuthPayloads:
            let env = APIEnvironment(
                name: "HTTPBin Sandbox",
                sourceFormat: .ceptra,
                variables: [
                    APIEnvironmentVariable(key: "httpbinUrl", initialValue: "https://httpbin.org"),
                    APIEnvironmentVariable(key: "bearerToken", initialValue: "", currentValue: "ceptra-demo-bearer-token", isSecret: true),
                    APIEnvironmentVariable(key: "apiKey", initialValue: "", currentValue: "ceptra-key-42", isSecret: true),
                    APIEnvironmentVariable(key: "basicUser", initialValue: "demo"),
                    APIEnvironmentVariable(key: "basicPass", initialValue: "", currentValue: "secret", isSecret: true)
                ]
            )
            let bearerReq = APIRequestItem(
                name: "Bearer Auth Verification",
                description: "Tests Bearer token authentication inherited/configured via secret env variable.",
                method: .get,
                url: "{{httpbinUrl}}/bearer",
                auth: APIAuthConfig(kind: .bearer, bearerToken: "{{bearerToken}}"),
                assertions: [
                    APIAssertionRule(name: "Status is 200", target: .statusCode, op: .equals, expectedValue: "200"),
                    APIAssertionRule(name: "Authenticated is true", target: .jsonPath, property: "$.authenticated", op: .equals, expectedValue: "true")
                ]
            )
            let basicReq = APIRequestItem(
                name: "Basic Auth Verification",
                description: "Tests HTTP Basic Auth header encoding.",
                method: .get,
                url: "{{httpbinUrl}}/basic-auth/{{basicUser}}/{{basicPass}}",
                auth: APIAuthConfig(kind: .basic, basicUsername: "{{basicUser}}", basicPassword: "{{basicPass}}"),
                assertions: [
                    APIAssertionRule(name: "Status is 200", target: .statusCode, op: .equals, expectedValue: "200"),
                    APIAssertionRule(name: "User echoed", target: .jsonPath, property: "$.user", op: .equals, expectedValue: "{{basicUser}}")
                ]
            )
            let apiKeyReq = APIRequestItem(
                name: "API Key Header Echo",
                description: "Sends X-API-Key header via API Key auth config.",
                method: .get,
                url: "{{httpbinUrl}}/headers",
                auth: APIAuthConfig(kind: .apiKey, apiKeyName: "X-API-Key", apiKeyValue: "{{apiKey}}", apiKeyIn: .header),
                assertions: [
                    APIAssertionRule(name: "Status is 200", target: .statusCode, op: .equals, expectedValue: "200"),
                    APIAssertionRule(name: "X-Api-Key echoed", target: .jsonPath, property: "$.headers.X-Api-Key", op: .equals, expectedValue: "{{apiKey}}")
                ]
            )
            let formReq = APIRequestItem(
                name: "Form URL-Encoded Submit",
                description: "Submits application/x-www-form-urlencoded form fields.",
                method: .post,
                url: "{{httpbinUrl}}/post",
                auth: .none,
                body: APIBodyConfig(
                    mode: .formURLEncoded,
                    formItems: [
                        APIKeyValueItem(key: "customer", value: "Ada Lovelace"),
                        APIKeyValueItem(key: "plan", value: "pro"),
                        APIKeyValueItem(key: "requestId", value: "{{$guid}}")
                    ]
                ),
                assertions: [
                    APIAssertionRule(name: "Status is 200", target: .statusCode, op: .equals, expectedValue: "200"),
                    APIAssertionRule(name: "Customer echoed", target: .jsonPath, property: "$.form.customer", op: .equals, expectedValue: "Ada Lovelace")
                ]
            )
            let cookieReq = APIRequestItem(
                name: "Response Headers & Set-Cookie",
                description: "Triggers a Set-Cookie response header visible in the Cookies tab.",
                method: .get,
                url: "{{httpbinUrl}}/response-headers",
                queryParams: [
                    APIKeyValueItem(key: "Set-Cookie", value: "ceptra_session=active; Path=/; HttpOnly"),
                    APIKeyValueItem(key: "X-Ceptra-Demo", value: "ok")
                ],
                auth: .none,
                assertions: [
                    APIAssertionRule(name: "Status is 200", target: .statusCode, op: .equals, expectedValue: "200"),
                    APIAssertionRule(name: "Custom header present", target: .header, property: "X-Ceptra-Demo", op: .equals, expectedValue: "ok")
                ]
            )
            let collection = APICollection(
                name: "Auth, Forms & Cookies (HTTPBin)",
                description: "Exercises Bearer, Basic, API Key auth, secret env vars, form payloads, and response cookies.",
                sourceFormat: .ceptra,
                variables: [APIKeyValueItem(key: "httpbinUrl", value: "https://httpbin.org")],
                folders: [
                    APIFolder(name: "Authentication", requests: [bearerReq, basicReq, apiKeyReq]),
                    APIFolder(name: "Forms & Headers", requests: [formReq, cookieReq])
                ]
            )
            return (collection, [env])

        case .graphQLCountries:
            let env = APIEnvironment(
                name: "Countries GraphQL",
                sourceFormat: .ceptra,
                variables: [
                    APIEnvironmentVariable(key: "graphqlUrl", initialValue: "https://countries.trevorblades.com/graphql"),
                    APIEnvironmentVariable(key: "countryCode", initialValue: "US")
                ]
            )
            let countryQuery = APIRequestItem(
                name: "Get Country by Code",
                description: "Queries a country using GraphQL query + JSON variables.",
                method: .post,
                url: "{{graphqlUrl}}",
                headers: [APIKeyValueItem(key: "Accept", value: "application/json")],
                body: APIBodyConfig(
                    mode: .graphql,
                    graphqlQuery: """
                    query GetCountry($code: ID!) {
                      country(code: $code) {
                        code
                        name
                        capital
                        currency
                        emoji
                      }
                    }
                    """,
                    graphqlVariables: "{\n  \"code\": \"{{countryCode}}\"\n}"
                ),
                assertions: [
                    APIAssertionRule(name: "Status is 200", target: .statusCode, op: .equals, expectedValue: "200"),
                    APIAssertionRule(name: "Country name returned", target: .jsonPath, property: "$.data.country.name", op: .exists, expectedValue: "")
                ]
            )
            let continentsQuery = APIRequestItem(
                name: "List Continents",
                description: "Lists all continents via GraphQL.",
                method: .post,
                url: "{{graphqlUrl}}",
                headers: [APIKeyValueItem(key: "Accept", value: "application/json")],
                body: APIBodyConfig(
                    mode: .graphql,
                    graphqlQuery: """
                    query {
                      continents {
                        code
                        name
                      }
                    }
                    """,
                    graphqlVariables: "{}"
                ),
                assertions: [
                    APIAssertionRule(name: "Status is 200", target: .statusCode, op: .equals, expectedValue: "200"),
                    APIAssertionRule(name: "At least one continent", target: .jsonPath, property: "$.data.continents[0].code", op: .exists, expectedValue: "")
                ]
            )
            let collection = APICollection(
                name: "GraphQL Explorer (Countries API)",
                description: "Live GraphQL queries demonstrating variables and nested JSONPath assertions.",
                sourceFormat: .ceptra,
                variables: [APIKeyValueItem(key: "graphqlUrl", value: "https://countries.trevorblades.com/graphql")],
                requests: [countryQuery, continentsQuery]
            )
            return (collection, [env])
        }
    }

    /// Generates a ready-to-run starter collection + environment so users can try API Studio immediately.
    public static func makeStarterSample() -> (collection: APICollection, environment: APIEnvironment) {
        let ex = makeExample(.restCRUDChaining)
        return (ex.collection, ex.environments[0])
    }

    /// Writes ready-to-import sample files in every supported format (Postman v2.1, Postman Environment,
    /// Insomnia v4, OpenAPI 3.0, `.http`, and `.env`) into `directoryURL` so users can test importing,
    /// editing, running, and exporting across formats.
    @discardableResult
    public static func createSampleImportFiles(at directoryURL: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let rest = makeExample(.restCRUDChaining)
        let httpBin = makeExample(.httpBinAuthPayloads)
        var written: [URL] = []

        // 1. Postman Collection v2.1 JSON
        let pmColURL = directoryURL.appendingPathComponent("jsonplaceholder.postman_collection.json")
        try APIFormatCodec.exportPostmanCollectionV21(rest.collection).write(to: pmColURL, options: .atomic)
        written.append(pmColURL)

        // 2. Postman Environment JSON
        let pmEnvURL = directoryURL.appendingPathComponent("jsonplaceholder.postman_environment.json")
        try APIFormatCodec.exportPostmanEnvironment(rest.environments[0], redactSecrets: false).write(to: pmEnvURL, options: .atomic)
        written.append(pmEnvURL)

        // 3. Insomnia v4 Export JSON (bundles collection + folders + base/sub environment!)
        let insomniaURL = directoryURL.appendingPathComponent("httpbin-auth.insomnia_v4.json")
        try APIFormatCodec.exportInsomniaV4(collection: httpBin.collection, environment: httpBin.environments[0], redactSecrets: false)
            .write(to: insomniaURL, options: .atomic)
        written.append(insomniaURL)

        // 4. OpenAPI 3.0.3 JSON specification
        let openAPIJSON = #"""
        {
          "openapi": "3.0.3",
          "info": {
            "title": "JSONPlaceholder OpenAPI Example",
            "version": "1.0.0",
            "description": "Sample OpenAPI 3.0 spec ready to import into Ceptra API Studio."
          },
          "servers": [
            { "url": "https://jsonplaceholder.typicode.com" }
          ],
          "paths": {
            "/todos/{todoId}": {
              "get": {
                "tags": ["Todos"],
                "summary": "Fetch Todo by ID",
                "parameters": [
                  { "name": "todoId", "in": "path", "required": true, "example": "1" }
                ]
              }
            },
            "/posts": {
              "get": {
                "tags": ["Posts"],
                "summary": "List Posts by User",
                "parameters": [
                  { "name": "userId", "in": "query", "required": true, "example": "1" }
                ]
              },
              "post": {
                "tags": ["Posts"],
                "summary": "Create a Post",
                "requestBody": {
                  "required": true,
                  "content": {
                    "application/json": {
                      "schema": {
                        "type": "object",
                        "properties": {
                          "title": { "type": "string", "example": "Hello from OpenAPI" },
                          "body": { "type": "string", "example": "Imported into Ceptra API Studio" },
                          "userId": { "type": "integer", "example": 1 }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """#
        let openAPIURL = directoryURL.appendingPathComponent("jsonplaceholder.openapi.json")
        try Data(openAPIJSON.utf8).write(to: openAPIURL, options: .atomic)
        written.append(openAPIURL)

        // 5. REST Client / JetBrains .http file
        let httpURL = directoryURL.appendingPathComponent("quick-checks.http")
        try Data(APIFormatCodec.exportHTTPFile(rest.collection).utf8).write(to: httpURL, options: .atomic)
        written.append(httpURL)

        // 6. .env environment file
        let envURL = directoryURL.appendingPathComponent("demo.env")
        try Data(APIFormatCodec.exportDotEnv(rest.environments[0], redactSecrets: false).utf8).write(to: envURL, options: .atomic)
        written.append(envURL)

        return written
    }
}
