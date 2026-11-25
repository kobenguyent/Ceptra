# API Client Studio

**API Client Studio** (++cmd+option+i++ or **`API`** in the bottom dock) lets you **import, edit, run, chain, and export** API collections and environments directly inside Ceptra — without switching back and forth to Postman or Insomnia.

!!! tip "Clean-Room & Zero License Issues"
    API Client Studio is written 100% natively in Swift on Apple's `URLSession` under Ceptra's **MIT License** — zero third-party SDKs, zero Electron overhead, and zero GPL/AGPL dependencies. It interoperates directly with open interchange formats (Postman v2.1 Apache 2.0, Insomnia v4 Apache 2.0, OpenAPI 3.x Apache 2.0, W3C HAR 1.2, `.http`, `.env`, and cURL).

---

## Supported Formats (Import & Export)

| Format | Import | Export | Notes |
| --- | :---: | :---: | --- |
| **Postman Collection v2.1 / v2.0** (`.json`) | Yes | Yes | Nested folders, auth inheritance, variables, bodies, plus automatic extraction &amp; synthesis of `pm.test(...)` / `pm.environment.set(...)` hints |
| **Postman Environment / Globals** (`.json`) | Yes | Yes | Preserves secret flags; **redacts secret values by default on export** |
| **Insomnia v4 Export** (`.json`) | Yes | Yes | Imports workspaces, folders, requests, and base/sub environments in a single file; normalizes `{{ _.var }}` syntax |
| **OpenAPI 3.0 / 3.1 &amp; Swagger 2.0** (`.json`) | Yes | — | Groups endpoints by tags into folders, sets `{{baseUrl}}`, and synthesizes example JSON request bodies from schemas |
| **HAR 1.2** (`.har` / `.json`) | Yes | — | Converts browser DevTools / proxy recordings straight into runnable requests |
| **REST Client / JetBrains** (`.http` / `.rest`) | Yes | Yes | Git-friendly plain-text format supporting `@var = value` and `### Request Name` sections |
| **cURL Commands** | Yes | Yes | Paste single or multi-line `curl` commands (`-X`, `-H`, `-d`, `--data-raw`, `-F`, `-u`, `-G`); copy any request back as cURL |
| **`.env` Files** | Yes | Yes | Import or export environment variables with optional secret redaction |
| **Ceptra Native Bundle** (`.ceptra-api.json`) | Yes | Yes | Lossless export of collections + environments |

!!! info "Quick Import from Explorer"
    You can also **right-click** any `.json`, `.http`, `.rest`, or `.env` file sitting inside your project repository in the Explorer sidebar and choose **Import into API Studio**.

---

## Editing Requests & Environments

### Request Editor
- **Method &amp; URL Bar**: Supports `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS`, live **Resolved URL** preview, and warnings for unresolved `{{variables}}`. Press ++cmd+return++ to send immediately.
- **Params &amp; Headers**: Key-value tables with per-row enable/disable checkboxes and quick-add presets (`Accept: application/json`, `Content-Type: application/json`).
- **Auth Inheritance**: Choose `Inherit` (from parent folder or collection), `No Auth`, `Bearer Token`, `Basic Auth`, or `API Key` (in Header or Query Param).
- **Body Modes**: `None`, `JSON` (with 1-click **Format JSON**), `Raw` (custom Content-Type), `Form URL-Encoded`, `Multipart Form-Data` (with file picker attachments), and `GraphQL` (Query + JSON Variables split editor).
- **Declarative Assertions**: Zero-code rules for **Status Code**, **Response Time (ms)**, **Body Text**, **Header**, and **JSONPath** (`equals`, `not equals`, `contains`, `<`, `>`, `exists`, `matches regex`).
- **Variable Extractors (Request Chaining)**: Extract values from a response via **JSONPath** (e.g., `$.data.token`), **Header**, or **Regex** directly into an Environment or Collection variable so Request 2 automatically inherits tokens or IDs produced by Request 1.
- **Scripts Tab**: Preserves imported Postman pre-request and test scripts for lossless round-trip export, with a 1-click **Extract Rules** button to convert common `pm.test` / `pm.environment.set` lines into Ceptra rules.

### Variable Resolution & Secret-Safe Environments

Placeholders (`{{varName}}` and `{{ _.varName }}`) resolve in strict precedence order:

1. **Runtime extracted variables** (captured from earlier steps in the active run)
2. **Active Environment variables** (`Current Value` local override > shared `Initial Value`)
3. **Collection variables**
4. **Built-in dynamic generators**: `{{$guid}}`, `{{$uuid}}`, `{{$timestamp}}`, `{{$isoTimestamp}}`, `{{$randomInt}}`, `{{$randomBoolean}}`, `{{$randomEmail}}`

Open the **Environment Manager** from the top-right environment picker to mark variables as **Secret** (masked with reveal eye toggle). When exporting environments to share with teammates, **Redact secret values when exporting** is enabled by default.

---

## Collection Runner, Replay HTML & Automated Test Generation

- **Run Collection or Folder**: Click **Run Collection** in the toolbar (or right-click any folder → **Run Folder**) to execute every request sequentially with live progress, variable chaining, real DNS/TCP/TLS/TTFB/Download timings, and pass/fail assertion summaries.
- **Open in Replay / Export Replay HTML**: Turn any Collection Run into a Ceptra Time-Travel Replay session or export a standalone interactive `ceptra-api-replay.html` report with sensitive auth headers automatically redacted.
- **Bridge Directly to Automated Tests**:
  - Open the **Code** tab in the Response panel to copy any request as **cURL**, **CodeceptJS**, **Playwright (TS)**, or **Playwright (Python)**.
  - Click **Generate Full Suite File…** (or **Export → Generate Test Suite File…**) to scaffold a complete, runnable API test file matching your workspace's active framework and open it immediately in the Code Editor.

---

## Try It Right Away with Built-In Examples

API Client Studio includes **two ways** to test everything out immediately (accessible from the API Studio welcome screen, the **Import** / `+` menus, **File → Create Example API Collections**, or **Command Palette** ++cmd+k++):

1. **Load Live Runnable Example Collections** (no signup or API keys needed):
   - **REST CRUD &amp; Variable Chaining (JSONPlaceholder)**: `GET`/`POST`/`PUT`/`PATCH`/`DELETE`, `{{$guid}}`, JSONPath assertions, and chaining `$.userId` → `{{lastUserId}}`.
   - **Auth, Forms &amp; Cookies (HTTPBin)**: Bearer, Basic, and API Key auth with secret-masked env variables, `form-urlencoded`, custom headers, and `Set-Cookie` inspection.
   - **GraphQL Explorer (Countries API)**: Live public GraphQL queries with variables and nested JSONPath assertions.
2. **Generate Sample Import Files on Disk (`api-examples/`)**:
   Creates 6 real, ready-to-import files (`jsonplaceholder.postman_collection.json`, `jsonplaceholder.postman_environment.json`, `httpbin-auth.insomnia_v4.json`, `jsonplaceholder.openapi.json`, `quick-checks.http`, and `demo.env`) so you can test importing and exporting every supported format hands-on.

### Where Collections Are Stored

Collections and environments persist automatically inside `<workspace>/.ceptra/api-studio/studio.json` when a project is open (or `~/Library/Application Support/Ceptra/api-studio/global.json` when used standalone).
