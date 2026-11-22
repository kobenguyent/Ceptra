import Foundation

/// Stateful line-by-line parsers for SSE and NDJSON streaming formats across all AI providers.
public protocol AIStreamLineParser: Sendable {
    mutating func consume(line: String) throws -> [AIStreamDelta]
}

// MARK: - OpenAI / GitHub Models / OpenAI-Compatible SSE

public struct OpenAISSELineParser: AIStreamLineParser, Sendable {
    public init() {}

    public mutating func consume(line: String) throws -> [AIStreamDelta] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { return [] }
        guard trimmed.hasPrefix("data:") else { return [] }

        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return [.completed(stopReason: "stop")]
        }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if let err = json["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? "Unknown streaming error"
            throw AIProviderError.httpError(statusCode: 500, message: msg)
        }

        var deltas: [AIStreamDelta] = []
        if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
            if let delta = first["delta"] as? [String: Any] {
                if let content = delta["content"] as? String, !content.isEmpty {
                    deltas.append(.text(content))
                }
            } else if let message = first["message"] as? [String: Any],
                      let content = message["content"] as? String, !content.isEmpty {
                deltas.append(.text(content))
            }
            if let finishReason = first["finish_reason"] as? String, !finishReason.isEmpty {
                deltas.append(.completed(stopReason: finishReason))
            }
        }

        if let usage = json["usage"] as? [String: Any] {
            let input = usage["prompt_tokens"] as? Int
            let output = usage["completion_tokens"] as? Int
            if input != nil || output != nil {
                deltas.append(.usage(AIUsageStats(inputTokens: input, outputTokens: output)))
            }
        }
        return deltas
    }
}

// MARK: - Anthropic Messages SSE

public struct AnthropicSSELineParser: AIStreamLineParser, Sendable {
    private var currentEvent: String = ""

    public init() {}

    public mutating func consume(line: String) throws -> [AIStreamDelta] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            currentEvent = ""
            return []
        }
        if trimmed.hasPrefix("event:") {
            currentEvent = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return []
        }
        guard trimmed.hasPrefix("data:") else { return [] }

        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let eventType = (json["type"] as? String) ?? currentEvent
        switch eventType {
        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any],
               let text = delta["text"] as? String, !text.isEmpty {
                return [.text(text)]
            }
            return []

        case "message_delta":
            var out: [AIStreamDelta] = []
            if let usage = json["usage"] as? [String: Any],
               let outputTokens = usage["output_tokens"] as? Int {
                out.append(.usage(AIUsageStats(inputTokens: nil, outputTokens: outputTokens)))
            }
            if let delta = json["delta"] as? [String: Any],
               let stopReason = delta["stop_reason"] as? String {
                out.append(.completed(stopReason: stopReason))
            }
            return out

        case "message_start":
            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any],
               let inputTokens = usage["input_tokens"] as? Int {
                return [.usage(AIUsageStats(inputTokens: inputTokens, outputTokens: nil))]
            }
            return []

        case "message_stop":
            return [.completed(stopReason: "end_turn")]

        case "error":
            let errObj = json["error"] as? [String: Any]
            let msg = (errObj?["message"] as? String) ?? "Anthropic stream error"
            throw AIProviderError.httpError(statusCode: 500, message: msg)

        default:
            return []
        }
    }
}

// MARK: - Google Gemini SSE (`:streamGenerateContent?alt=sse`)

public struct GeminiSSELineParser: AIStreamLineParser, Sendable {
    public init() {}

    public mutating func consume(line: String) throws -> [AIStreamDelta] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("data:") else { return [] }

        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if let err = json["error"] as? [String: Any] {
            let code = (err["code"] as? Int) ?? 500
            let msg = (err["message"] as? String) ?? "Gemini streaming error"
            throw AIProviderError.httpError(statusCode: code, message: msg)
        }

        var deltas: [AIStreamDelta] = []
        if let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first {
            if let content = first["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String, !text.isEmpty {
                        deltas.append(.text(text))
                    }
                }
            }
            if let finishReason = first["finishReason"] as? String, !finishReason.isEmpty, finishReason != "FINISH_REASON_UNSPECIFIED" {
                deltas.append(.completed(stopReason: finishReason))
            }
        }

        if let usage = json["usageMetadata"] as? [String: Any] {
            let input = usage["promptTokenCount"] as? Int
            let output = usage["candidatesTokenCount"] as? Int
            if input != nil || output != nil {
                deltas.append(.usage(AIUsageStats(inputTokens: input, outputTokens: output)))
            }
        }
        return deltas
    }
}

// MARK: - Ollama Native NDJSON (`/api/chat`)

public struct OllamaNDJSONLineParser: AIStreamLineParser, Sendable {
    public init() {}

    public mutating func consume(line: String) throws -> [AIStreamDelta] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if let err = json["error"] as? String, !err.isEmpty {
            throw AIProviderError.httpError(statusCode: 500, message: err)
        }

        var deltas: [AIStreamDelta] = []
        if let message = json["message"] as? [String: Any],
           let content = message["content"] as? String, !content.isEmpty {
            deltas.append(.text(content))
        } else if let response = json["response"] as? String, !response.isEmpty {
            deltas.append(.text(response))
        }

        if let done = json["done"] as? Bool, done {
            let input = json["prompt_eval_count"] as? Int
            let output = json["eval_count"] as? Int
            if input != nil || output != nil {
                deltas.append(.usage(AIUsageStats(inputTokens: input, outputTokens: output)))
            }
            deltas.append(.completed(stopReason: (json["done_reason"] as? String) ?? "stop"))
        }
        return deltas
    }
}

// MARK: - Claude CLI `stream-json` NDJSON Parser

public struct ClaudeCLIStreamJSONLineParser: AIStreamLineParser, Sendable {
    private var emittedAnyDelta = false

    public init() {}

    public mutating func consume(line: String) throws -> [AIStreamDelta] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Plain text fallback if CLI emits non-JSON text
            emittedAnyDelta = true
            return [.text(line + "\n")]
        }

        let type = json["type"] as? String ?? ""
        switch type {
        case "stream_event":
            if let event = json["event"] as? [String: Any],
               let delta = event["delta"] as? [String: Any],
               let text = delta["text"] as? String, !text.isEmpty {
                emittedAnyDelta = true
                return [.text(text)]
            }
            return []

        case "assistant":
            // Claude CLI emits complete assistant turn blocks when not emitting fine-grained deltas
            if !emittedAnyDelta,
               let message = json["message"] as? [String: Any],
               let contentBlocks = message["content"] as? [[String: Any]] {
                let text = contentBlocks.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty {
                    emittedAnyDelta = true
                    return [.text(text)]
                }
            }
            return []

        case "result":
            var out: [AIStreamDelta] = []
            if let isError = json["is_error"] as? Bool, isError {
                let msg = (json["result"] as? String) ?? "Claude CLI returned an error"
                throw AIProviderError.cliProcessFailure(exitCode: 1, message: msg)
            }
            if !emittedAnyDelta, let resultText = json["result"] as? String, !resultText.isEmpty {
                emittedAnyDelta = true
                out.append(.text(resultText))
            }
            out.append(.completed(stopReason: "stop"))
            return out

        default:
            return []
        }
    }
}
