import CeptraCore
import Foundation
import XCTest

final class APIStudioTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir(_ suffix: String = "api-studio") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    // MARK: - 1. Postman v2.1 Collection & Environment Import / Export

    func testPostmanV21CollectionImportAndRoundTripExport() throws {
        let postmanJSON = #"""
        {
          "info": {
            "_postman_id": "11111111-2222-3333-4444-555555555555",
            "name": "Orders API",
            "description": "Core ordering endpoints",
            "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
          },
          "auth": {
            "type": "bearer",
            "bearer": [{ "key": "token", "value": "{{authToken}}", "type": "string" }]
          },
          "variable": [
            { "key": "baseUrl", "value": "https://api.orders.test" }
          ],
          "item": [
            {
              "name": "Auth",
              "item": [
                {
                  "name": "Login",
                  "event": [
                    {
                      "listen": "test",
                      "script": {
                        "type": "text/javascript",
                        "exec": [
                          "pm.test('Status 200', function () { pm.response.to.have.status(200); });",
                          "pm.expect(pm.response.responseTime).to.be.below(800);",
                          "const jsonData = pm.response.json();",
                          "pm.environment.set('authToken', jsonData.data.token);"
                        ]
                      }
                    }
                  ],
                  "request": {
                    "auth": { "type": "noauth" },
                    "method": "POST",
                    "header": [
                      { "key": "Content-Type", "value": "application/json" }
                    ],
                    "body": {
                      "mode": "raw",
                      "raw": "{\"email\":\"qa@example.com\"}",
                      "options": { "raw": { "language": "json" } }
                    },
                    "url": {
                      "raw": "{{baseUrl}}/v1/login?remember=true",
                      "query": [
                        { "key": "remember", "value": "true" },
                        { "key": "debug", "value": "1", "disabled": true }
                      ]
                    }
                  }
                }
              ]
            },
            {
              "name": "List Orders",
              "request": {
                "method": "GET",
                "url": "{{baseUrl}}/v1/orders?status=open"
              }
            }
          ]
        }
        """#

        let imported = try APIFormatCodec.importData(Data(postmanJSON.utf8), fileName: "orders.postman_collection.json")
        XCTAssertEqual(imported.detectedFormat, .postmanV21)
        XCTAssertEqual(imported.collections.count, 1)

        let col = imported.collections[0]
        XCTAssertEqual(col.name, "Orders API")
        XCTAssertEqual(col.auth.kind, .bearer)
        XCTAssertEqual(col.auth.bearerToken, "{{authToken}}")
        XCTAssertEqual(col.variables.first?.key, "baseUrl")
        XCTAssertEqual(col.folders.count, 1)
        XCTAssertEqual(col.requests.count, 1)

        let loginReq = try XCTUnwrap(col.folders.first?.requests.first)
        XCTAssertEqual(loginReq.name, "Login")
        XCTAssertEqual(loginReq.method, .post)
        XCTAssertEqual(loginReq.auth.kind, .none)
        XCTAssertEqual(loginReq.url, "{{baseUrl}}/v1/login")
        XCTAssertEqual(loginReq.queryParams.count, 2)
        XCTAssertTrue(loginReq.queryParams[0].isEnabled)
        XCTAssertFalse(loginReq.queryParams[1].isEnabled)
        XCTAssertEqual(loginReq.body.mode, .json)
        XCTAssertTrue(loginReq.assertions.contains(where: { $0.target == .statusCode && $0.expectedValue == "200" }))
        XCTAssertTrue(loginReq.assertions.contains(where: { $0.target == .responseTimeMs && $0.expectedValue == "800" }))
        XCTAssertTrue(loginReq.extractors.contains(where: { $0.targetVariableName == "authToken" && $0.expression == "$.data.token" }))

        // Verify auth inheritance on root request
        let listCtx = try XCTUnwrap(col.request(withID: col.requests[0].id))
        XCTAssertEqual(listCtx.effectiveAuth.kind, .bearer)
        XCTAssertEqual(listCtx.effectiveAuth.bearerToken, "{{authToken}}")

        // Round-trip export -> re-import
        let exportedData = try APIFormatCodec.exportPostmanCollectionV21(col)
        let reimported = try APIFormatCodec.importData(exportedData, fileName: "exported.postman_collection.json")
        XCTAssertEqual(reimported.detectedFormat, .postmanV21)
        XCTAssertEqual(reimported.collections.first?.name, "Orders API")
        XCTAssertEqual(reimported.collections.first?.totalRequestCount, 2)
    }

    func testPostmanEnvironmentImportAndRedactedExport() throws {
        let envJSON = #"""
        {
          "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
          "name": "Staging",
          "_postman_variable_scope": "environment",
          "values": [
            { "key": "baseUrl", "value": "https://staging.example.com", "type": "default", "enabled": true },
            { "key": "apiSecret", "value": "super-secret-value-123", "type": "secret", "enabled": true },
            { "key": "disabledFlag", "value": "off", "enabled": false }
          ]
        }
        """#

        let imported = try APIFormatCodec.importData(Data(envJSON.utf8), fileName: "staging.postman_environment.json")
        XCTAssertEqual(imported.detectedFormat, .postmanV21)
        XCTAssertEqual(imported.environments.count, 1)

        let env = imported.environments[0]
        XCTAssertEqual(env.name, "Staging")
        XCTAssertEqual(env.variables.count, 3)
        XCTAssertEqual(env.variables[1].isSecret, true)
        XCTAssertEqual(env.variables[1].effectiveValue, "super-secret-value-123")
        XCTAssertEqual(env.variables[2].isEnabled, false)

        // Export with redactSecrets = true must NOT leak secret value!
        let redactedData = try APIFormatCodec.exportPostmanEnvironment(env, redactSecrets: true)
        let redactedText = String(data: redactedData, encoding: .utf8) ?? ""
        XCTAssertTrue(redactedText.contains("https://staging.example.com"))
        XCTAssertFalse(redactedText.contains("super-secret-value-123"))

        // Export to .env with redactSecrets = true must also strip secret
        let dotEnv = APIFormatCodec.exportDotEnv(env, redactSecrets: true)
        XCTAssertTrue(dotEnv.contains("baseUrl=https://staging.example.com"))
        XCTAssertFalse(dotEnv.contains("super-secret-value-123"))
    }

    // MARK: - 2. Insomnia v4 Import & Export

    func testInsomniaV4ImportNormalizesTemplatesAndExportsCleanly() throws {
        let insomniaJSON = #"""
        {
          "_type": "export",
          "__export_format": 4,
          "__export_source": "insomnia.desktop.app",
          "resources": [
            { "_id": "wrk_1", "_type": "workspace", "parentId": null, "name": "Insomnia Billing" },
            { "_id": "env_base", "_type": "environment", "parentId": "wrk_1", "name": "Base Environment", "data": { "baseUrl": "https://billing.local", "version": "v2" } },
            { "_id": "env_prod", "_type": "environment", "parentId": "env_base", "name": "Production", "data": { "baseUrl": "https://api.billing.io", "apiToken": "tok_live_999" } },
            { "_id": "fld_1", "_type": "request_group", "parentId": "wrk_1", "name": "Invoices", "metaSortKey": 1 },
            {
              "_id": "req_1",
              "_type": "request",
              "parentId": "fld_1",
              "name": "Create Invoice",
              "method": "POST",
              "url": "{{ _.baseUrl }}/{{ _.version }}/invoices",
              "headers": [{ "name": "Accept", "value": "application/json" }],
              "authentication": { "type": "bearer", "token": "{{ _.apiToken }}" },
              "body": { "mimeType": "application/json", "text": "{\"amount\":4200}" },
              "metaSortKey": 2
            }
          ]
        }
        """#

        let imported = try APIFormatCodec.importData(Data(insomniaJSON.utf8), fileName: "insomnia.json")
        XCTAssertEqual(imported.detectedFormat, .insomniaV4)
        XCTAssertEqual(imported.collections.count, 1)
        XCTAssertEqual(imported.environments.count, 2)

        let col = imported.collections[0]
        XCTAssertEqual(col.name, "Insomnia Billing")
        let req = try XCTUnwrap(col.folders.first?.requests.first)
        XCTAssertEqual(req.url, "{{baseUrl}}/{{version}}/invoices")
        XCTAssertEqual(req.auth.kind, .bearer)
        XCTAssertEqual(req.auth.bearerToken, "{{apiToken}}")
        XCTAssertEqual(req.body.mode, .json)

        let prodEnv = try XCTUnwrap(imported.environments.first(where: { $0.name == "Production" }))
        let vars = APIVariableResolver.mergedVariables(collection: col, environment: prodEnv)
        XCTAssertEqual(vars["baseUrl"], "https://api.billing.io")
        XCTAssertEqual(vars["version"], "v2")
        XCTAssertEqual(APIVariableResolver.resolve(req.url, variables: vars), "https://api.billing.io/v2/invoices")

        // Round-trip export back to Insomnia v4 with redacted secrets
        let exported = try APIFormatCodec.exportInsomniaV4(collection: col, environment: prodEnv, redactSecrets: true)
        let exportedStr = String(data: exported, encoding: .utf8) ?? ""
        XCTAssertFalse(exportedStr.contains("tok_live_999"))
        let reimported = try APIFormatCodec.importData(exported, fileName: "reexport_insomnia.json")
        XCTAssertEqual(reimported.detectedFormat, .insomniaV4)
        XCTAssertEqual(reimported.collections.first?.totalRequestCount, 1)
    }

    // MARK: - 3. OpenAPI 3.0, HAR 1.2, .http, and cURL Importers

    func testOpenAPIHARHTTPAndCurlImport() throws {
        // OpenAPI 3.0
        let openAPI = #"""
        {
          "openapi": "3.0.3",
          "info": { "title": "Petstore Mini", "version": "1.0.0" },
          "servers": [{ "url": "https://pets.example.com/api" }],
          "paths": {
            "/pets/{petId}": {
              "get": {
                "tags": ["Pets"],
                "summary": "Find pet by ID",
                "parameters": [{ "name": "expand", "in": "query", "example": "owner", "required": true }]
              },
              "post": {
                "tags": ["Pets"],
                "summary": "Update pet",
                "requestBody": {
                  "content": {
                    "application/json": {
                      "schema": { "type": "object", "properties": { "name": { "type": "string", "example": "Milo" } } }
                    }
                  }
                }
              }
            }
          }
        }
        """#
        let oai = try APIFormatCodec.importData(Data(openAPI.utf8), fileName: "petstore.json")
        XCTAssertEqual(oai.detectedFormat, .openAPI3)
        XCTAssertEqual(oai.collections.first?.name, "Petstore Mini")
        XCTAssertEqual(oai.collections.first?.totalRequestCount, 2)
        XCTAssertEqual(oai.collections.first?.folders.first?.name, "Pets")
        XCTAssertEqual(oai.collections.first?.folders.first?.requests.first?.url, "{{baseUrl}}/pets/{{petId}}")

        // HAR 1.2
        let har = #"""
        {
          "log": {
            "version": "1.2",
            "entries": [
              {
                "request": {
                  "method": "POST",
                  "url": "https://api.demo.test/v1/items?limit=10",
                  "headers": [{ "name": "Content-Type", "value": "application/json" }],
                  "postData": { "mimeType": "application/json", "text": "{\"sku\":\"A1\"}" }
                }
              }
            ]
          }
        }
        """#
        let harOut = try APIFormatCodec.importData(Data(har.utf8), fileName: "capture.har")
        XCTAssertEqual(harOut.detectedFormat, .har)
        XCTAssertEqual(harOut.collections.first?.requests.first?.method, .post)
        XCTAssertEqual(harOut.collections.first?.requests.first?.queryParams.first?.key, "limit")

        // .http file + export round-trip
        let httpText = """
        @host = https://httpbin.org

        ### Check Status
        GET {{host}}/get?source=ceptra
        Accept: application/json

        ### Post Payload
        POST {{host}}/post
        Content-Type: application/json

        {"hello": "world"}
        """
        let httpOut = try APIFormatCodec.importData(Data(httpText.utf8), fileName: "smoke.http")
        XCTAssertEqual(httpOut.detectedFormat, .httpFile)
        XCTAssertEqual(httpOut.collections.first?.totalRequestCount, 2)
        XCTAssertEqual(httpOut.collections.first?.variables.first?.key, "host")
        let exportedHTTP = APIFormatCodec.exportHTTPFile(try XCTUnwrap(httpOut.collections.first))
        XCTAssertTrue(exportedHTTP.contains("### Check Status"))
        XCTAssertTrue(exportedHTTP.contains("POST {{host}}/post"))

        // cURL command
        let curlCmd = """
        curl -X POST 'https://api.example.com/v1/tokens?scope=read' \\
          -H 'Authorization: Bearer secret_tok' \\
          -H 'Content-Type: application/json' \\
          --data-raw '{"grant":"client_credentials"}'
        """
        let curlOut = try APIFormatCodec.importData(Data(curlCmd.utf8))
        XCTAssertEqual(curlOut.detectedFormat, .curl)
        let curlReq = try XCTUnwrap(curlOut.collections.first?.requests.first)
        XCTAssertEqual(curlReq.method, .post)
        XCTAssertEqual(curlReq.url, "https://api.example.com/v1/tokens")
        XCTAssertEqual(curlReq.queryParams.first?.key, "scope")
        XCTAssertEqual(curlReq.auth.kind, .bearer)
        XCTAssertEqual(curlReq.auth.bearerToken, "secret_tok")
        XCTAssertEqual(curlReq.body.mode, .json)
    }

    // MARK: - 4. Variable Resolution, JSONPath, CodeGen & Persistence

    func testVariableResolutionJSONPathCodeGenerationAndStore() throws {
        let col = APICollection(name: "Shop", variables: [
            APIKeyValueItem(key: "baseUrl", value: "https://col.example.com"),
            APIKeyValueItem(key: "onlyCol", value: "from-col")
        ])
        let env = APIEnvironment(name: "QA", variables: [
            APIEnvironmentVariable(key: "baseUrl", initialValue: "https://qa.example.com"),
            APIEnvironmentVariable(key: "token", initialValue: "init", currentValue: "local-override", isSecret: true)
        ])
        let merged = APIVariableResolver.mergedVariables(collection: col, environment: env, runtimeOverrides: ["runtimeId": "42"])
        XCTAssertEqual(merged["baseUrl"], "https://qa.example.com")
        XCTAssertEqual(merged["onlyCol"], "from-col")
        XCTAssertEqual(merged["token"], "local-override")
        XCTAssertEqual(merged["runtimeId"], "42")

        let resolved = APIVariableResolver.resolve("{{baseUrl}}/items/{{runtimeId}}?req={{$guid}}&missing={{nope}}", variables: merged)
        XCTAssertTrue(resolved.hasPrefix("https://qa.example.com/items/42?req="))
        XCTAssertFalse(resolved.contains("{{$guid}}"))
        XCTAssertEqual(APIVariableResolver.unresolvedVariableNames(in: "{{baseUrl}}/{{nope}}", variables: merged), ["nope"])

        // JSONPath
        let json = #"{"data":{"users":[{"id":7,"name":"Ada"},{"id":8,"name":"Grace"}]},"ok":true}"#
        XCTAssertEqual(APIVariableResolver.evaluateJSONPath("$.data.users[0].name", inJSONString: json), "Ada")
        XCTAssertEqual(APIVariableResolver.evaluateJSONPath("$.data.users[1].id", inJSONString: json), "8")
        XCTAssertEqual(APIVariableResolver.evaluateJSONPath("$.data.users.length", inJSONString: json), "2")
        XCTAssertEqual(APIVariableResolver.evaluateJSONPath("$.ok", inJSONString: json), "true")
        XCTAssertNil(APIVariableResolver.evaluateJSONPath("$.data.missing", inJSONString: json))

        // Code generation across all 4 languages + full test suite file
        let sample = APIStudioStore.makeStarterSample()
        let firstReq = try XCTUnwrap(sample.collection.flattenedRequests().first)
        let vars = APIVariableResolver.mergedVariables(collection: sample.collection, environment: sample.environment)
        XCTAssertTrue(APICodeGenerator.snippet(for: firstReq.request, effectiveAuth: firstReq.effectiveAuth, variables: vars, language: .curl).contains("curl -X GET"))
        XCTAssertTrue(APICodeGenerator.snippet(for: firstReq.request, effectiveAuth: firstReq.effectiveAuth, variables: vars, language: .codeceptJS).contains("I.sendGetRequest"))
        XCTAssertTrue(APICodeGenerator.snippet(for: firstReq.request, effectiveAuth: firstReq.effectiveAuth, variables: vars, language: .playwrightTS).contains("request.get"))
        XCTAssertTrue(APICodeGenerator.snippet(for: firstReq.request, effectiveAuth: firstReq.effectiveAuth, variables: vars, language: .playwrightPython).contains("api_request_context.get"))

        let pySuite = APICodeGenerator.generateTestFile(for: sample.collection, environment: sample.environment, framework: .playwrightPython)
        XCTAssertTrue(pySuite.suggestedFileName.hasSuffix(".py"))
        XCTAssertTrue(pySuite.content.contains("def test_get_todo_by_id"))

        // Workspace persistence store round-trip
        let root = try makeTempDir("api-store")
        let store = APIStudioStore()
        let dataToSave = APIStudioWorkspaceData(collections: [sample.collection], environments: [sample.environment], activeEnvironmentID: sample.environment.id)
        store.save(dataToSave, workspaceRoot: root)
        let loaded = store.load(workspaceRoot: root)
        XCTAssertEqual(loaded.collections.count, 1)
        XCTAssertEqual(loaded.environments.count, 1)
        XCTAssertEqual(loaded.activeEnvironmentID, sample.environment.id)
    }

    // MARK: - 5. Live Localhost Collection Run with Variable Chaining & Replay HTML Generation

    func testLiveCollectionRunnerExecutesChainedRequestsAssertionsAndReplayHTML() async throws {
        let pythonExec = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: pythonExec) else {
            throw XCTSkip("python3 not installed on host")
        }

        // Launch an ephemeral local HTTP server on 127.0.0.1:0 with /login and /me endpoints
        let serverScript = #"""
        import http.server, json, sys
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length).decode("utf-8") if length else "{}"
                body = json.dumps({"token": "chained-jwt-xyz", "received": json.loads(raw)}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Set-Cookie", "sid=abc123; Path=/; HttpOnly")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def do_GET(self):
                auth = self.headers.get("Authorization", "")
                ok = (auth == "Bearer chained-jwt-xyz")
                body = json.dumps({"user": "qa-bot", "authorized": ok}).encode("utf-8")
                self.send_response(200 if ok else 401)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        print(srv.server_address[1], flush=True)
        srv.serve_forever()
        """#

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonExec)
        proc.arguments = ["-u", "-c", serverScript]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try proc.run()
        defer { proc.terminate() }

        // Read assigned port line
        var portBuf = Data()
        while true {
            let chunk = outPipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            portBuf.append(chunk)
            if portBuf.contains(10) { break }
        }
        let portStr = (String(data: portBuf, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let port = try XCTUnwrap(Int(portStr), "Failed to start local test server")

        let env = APIEnvironment(name: "Localhost", variables: [
            APIEnvironmentVariable(key: "baseUrl", initialValue: "http://127.0.0.1:\(port)")
        ])

        let loginReq = APIRequestItem(
            name: "Login",
            method: .post,
            url: "{{baseUrl}}/login",
            headers: [APIKeyValueItem(key: "Content-Type", value: "application/json")],
            auth: .none,
            body: APIBodyConfig(mode: .json, rawText: #"{"user":"qa-bot"}"#),
            assertions: [
                APIAssertionRule(name: "Login 200", target: .statusCode, op: .equals, expectedValue: "200"),
                APIAssertionRule(name: "Token returned", target: .jsonPath, property: "$.token", op: .equals, expectedValue: "chained-jwt-xyz")
            ],
            extractors: [
                APIVariableExtractor(source: .jsonPath, expression: "$.token", targetVariableName: "authToken", scope: .environment)
            ]
        )

        let profileReq = APIRequestItem(
            name: "Get Profile",
            method: .get,
            url: "{{baseUrl}}/me",
            auth: .inherit,
            assertions: [
                APIAssertionRule(name: "Authorized 200", target: .statusCode, op: .equals, expectedValue: "200"),
                APIAssertionRule(name: "User matches", target: .jsonPath, property: "$.user", op: .equals, expectedValue: "qa-bot")
            ]
        )

        let col = APICollection(
            name: "Chained Auth Flow",
            auth: APIAuthConfig(kind: .bearer, bearerToken: "{{authToken}}"),
            requests: [loginReq, profileReq]
        )

        let run = await APIRequestRunner.runCollection(col, environment: env)
        XCTAssertEqual(run.summary.results.count, 2)
        XCTAssertEqual(run.summary.passedCount, 2)
        XCTAssertEqual(run.summary.failedCount, 0)
        XCTAssertEqual(run.environmentUpdates["authToken"], "chained-jwt-xyz")
        XCTAssertEqual(run.summary.results[0].cookies.first?.name, "sid")
        XCTAssertEqual(run.summary.results[1].statusCode, 200)

        // Verify conversion to TimeTravelHTMLReportBuilder redacts Bearer token and sets API mode!
        let (report, bundle) = run.summary.toTimeTravelReport(projectPath: "/tmp", projectName: "Demo")
        let html = TimeTravelHTMLReportBuilder.build(report, traceBundle: bundle)
        XCTAssertTrue(html.contains("\"reportMode\":\"api\""))
        XCTAssertTrue(html.contains("Get Profile"))
        XCTAssertFalse(html.contains("Bearer chained-jwt-xyz"))
    }

    // MARK: - 6. Curated Example Templates & Sample Multi-Format Files on Disk

    func testExampleTemplatesAndGeneratedSampleFilesReimportCleanlyAcrossAllFormats() throws {
        // 1. Every built-in example template has runnable requests, assertions & environment variables
        for template in APIStudioStore.ExampleTemplate.allCases {
            let ex = APIStudioStore.makeExample(template)
            XCTAssertGreaterThanOrEqual(ex.collection.totalRequestCount, 2, "Template \(template) should have multiple requests")
            XCTAssertFalse(ex.environments.isEmpty)
            let merged = APIVariableResolver.mergedVariables(collection: ex.collection, environment: ex.environments.first)
            for entry in ex.collection.flattenedRequests() {
                let resolved = APIVariableResolver.resolve(entry.request.url, variables: merged)
                XCTAssertTrue(resolved.hasPrefix("https://"), "Expected resolved HTTPS URL for \(entry.request.name), got \(resolved)")
                XCTAssertFalse(entry.request.assertions.isEmpty)
            }
        }

        // 2. Generate all 6 sample import files on disk and verify every single one re-imports with the exact right format
        let outDir = try makeTempDir("api-examples")
        let files = try APIStudioStore.createSampleImportFiles(at: outDir)
        XCTAssertEqual(files.count, 6)

        let expectedFormatsByFile: [String: (format: APISourceFormat, minCollections: Int, minEnvs: Int)] = [
            "jsonplaceholder.postman_collection.json": (.postmanV21, 1, 0),
            "jsonplaceholder.postman_environment.json": (.postmanV21, 0, 1),
            "httpbin-auth.insomnia_v4.json": (.insomniaV4, 1, 1),
            "jsonplaceholder.openapi.json": (.openAPI3, 1, 0),
            "quick-checks.http": (.httpFile, 1, 0),
            "demo.env": (.ceptra, 0, 1)
        ]

        for fileURL in files {
            let spec = try XCTUnwrap(expectedFormatsByFile[fileURL.lastPathComponent], "Unexpected file \(fileURL.lastPathComponent)")
            let data = try Data(contentsOf: fileURL)
            let outcome = try APIFormatCodec.importData(data, fileName: fileURL.lastPathComponent)
            XCTAssertEqual(outcome.detectedFormat, spec.format, "Wrong detected format for \(fileURL.lastPathComponent)")
            XCTAssertGreaterThanOrEqual(outcome.collections.count, spec.minCollections, "Missing collections in \(fileURL.lastPathComponent)")
            XCTAssertGreaterThanOrEqual(outcome.environments.count, spec.minEnvs, "Missing environments in \(fileURL.lastPathComponent)")
        }
    }
}
