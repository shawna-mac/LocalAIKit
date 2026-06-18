//
//  LocalAIKitAgent.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/17/26.
//

import Foundation

/// A reusable agent runtime that can chat, generate structured output, and call tools.
public struct LocalAIKitAgent: Sendable, Hashable {
    /// The display title for the agent.
    public var title: String
    /// The reusable configuration backing this agent.
    public var agentTemplate: LocalAIKitAgentTemplate
    /// The tools registered on this agent.
    public var tools: [LocalAIKitAgentTool]
    /// The maximum number of tool iterations allowed during a run.
    public var maxToolIterations: Int

    /// Creates a simple agent from direct prompt values.
    ///
    /// - Parameters:
    ///   - title: The display title for the agent.
    ///   - systemPrompt: The system prompt to use.
    ///   - starterPrompt: The starter prompt to present in the UI.
    ///   - outputMode: The output mode for requests built from this agent.
    public init(
        title: String,
        systemPrompt: String = "",
        starterPrompt: String = "",
        outputMode: LocalAIKitAgentTemplate.OutputMode = .chat
    ) {
        self.title = title
        self.agentTemplate = LocalAIKitAgentTemplate(
            id: title,
            name: title,
            summary: title,
            systemPrompt: systemPrompt,
            starterPrompt: starterPrompt,
            outputMode: outputMode,
            sampling: .init(),
            stopSequences: ["\nUser:", "\nAssistant:"],
            structuredGuide: nil
        )
        self.tools = []
        self.maxToolIterations = 4
    }

    /// Creates an agent from a reusable template.
    ///
    /// - Parameters:
    ///   - agentTemplate: The template that defines the agent behavior.
    ///   - tools: The tools registered on the agent.
    ///   - maxToolIterations: The maximum number of tool iterations allowed.
    public init(
        agentTemplate: LocalAIKitAgentTemplate,
        tools: [LocalAIKitAgentTool] = [],
        maxToolIterations: Int = 4
    ) {
        self.title = agentTemplate.name
        self.agentTemplate = agentTemplate
        self.tools = tools
        self.maxToolIterations = maxToolIterations
    }

    /// Returns a copy of the agent with one more tool registered.
    ///
    /// - Parameters:
    ///   - tool: The tool to add.
    /// - Returns: A new agent value containing the tool.
    public func register(_ tool: LocalAIKitAgentTool) -> LocalAIKitAgent {
        var copy = self
        copy.tools.append(tool)
        return copy
    }

    public func register<Input: Codable, Output: Codable>(
        _ name: String,
        description: String = "",
        inputExample: Input,
        _ handler: @escaping @Sendable (Input) async throws -> Output
    ) -> LocalAIKitAgent {
        let tool = LocalAIKitAgentTool(
            name: name,
            description: description.isEmpty ? "Tool \(name)" : description,
            inputExampleJSON: Self.prettyPrintedJSON(from: inputExample) ?? "{}",
            executor: { arguments in
                let inputData = try Self.encodeJSONValue(arguments)
                let input = try JSONDecoder().decode(Input.self, from: inputData)
                let output = try await handler(input)
                let outputData = try JSONEncoder().encode(output)
                return String(decoding: outputData, as: UTF8.self)
            }
        )

        return register(tool)
    }

    /// Builds a plain chat request from this agent.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt to send.
    ///   - history: Previous conversation turns to include.
    ///   - overrideSystemPrompt: Optional replacement for the agent system prompt.
    /// - Returns: A configured inference request.
    public func makeChatRequest(
        prompt: String,
        history: [LocalAIKitConversationTurn] = [],
        overrideSystemPrompt: String? = nil
    ) -> LocalAIKitInferenceRequest {
        agentTemplate.makeChatRequest(
            prompt: prompt,
            history: history,
            overrideSystemPrompt: overrideSystemPrompt
        )
    }

    /// Builds a structured-output request from this agent.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt to send.
    ///   - history: Previous conversation turns to include.
    ///   - overrideSystemPrompt: Optional replacement for the agent system prompt.
    /// - Returns: A configured inference request for structured output.
    public func makeStructuredRequest(
        prompt: String,
        history: [LocalAIKitConversationTurn] = [],
        overrideSystemPrompt: String? = nil
    ) -> LocalAIKitInferenceRequest {
        agentTemplate.makeStructuredRequest(
            prompt: prompt,
            history: history,
            overrideSystemPrompt: overrideSystemPrompt
        )
    }

    /// Builds a tool-calling request from this agent.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt to send.
    ///   - history: Previous conversation turns to include.
    ///   - overrideSystemPrompt: Optional replacement for the agent system prompt.
    /// - Returns: A configured inference request for tool use.
    public func makeToolUseRequest(
        prompt: String,
        history: [LocalAIKitConversationTurn] = [],
        overrideSystemPrompt: String? = nil
    ) -> LocalAIKitInferenceRequest {
        var request = agentTemplate.makeToolRequest(
            prompt: prompt,
            history: history,
            overrideSystemPrompt: overrideSystemPrompt
        )

        let toolInstructions = Self.toolInstructions(for: tools)
        if let existingSystemPrompt = request.systemPrompt, !existingSystemPrompt.isEmpty {
            request.systemPrompt = [existingSystemPrompt, toolInstructions]
                .joined(separator: "\n\n")
        } else {
            request.systemPrompt = toolInstructions
        }

        return request
    }

    /// Attempts to decode a tool call from raw model text.
    ///
    /// - Parameters:
    ///   - text: The raw model output text.
    /// - Returns: A decoded tool envelope, or `nil` if the text could not be parsed.
    public func decodeToolCall(from text: String) -> LocalAIKitAgentToolEnvelope? {
        let candidateText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateText.isEmpty else {
            return nil
        }

        if let envelope = Self.decodeEnvelope(from: candidateText) {
            return envelope
        }

        if tools.count == 1,
           let singleTool = tools.first,
           let arguments = Self.decodeJSONValue(from: candidateText),
           !Self.looksLikeToolEnvelope(arguments) {
            return LocalAIKitAgentToolEnvelope(
                kind: .toolCall,
                tool: LocalAIKitAgentToolCall(name: singleTool.name, arguments: arguments)
            )
        }

        return nil
    }

    /// Runs the agent against a loaded model and returns the final response text.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt to send.
    ///   - client: The model manager used to generate text.
    ///   - loadedModel: The loaded model contents to generate from.
    ///   - history: Previous conversation turns to include.
    ///   - overrideSystemPrompt: Optional replacement for the agent system prompt.
    ///   - onPartialText: Optional callback that receives incremental text updates.
    /// - Returns: The final response and any tool observations.
    public func run(
        prompt: String,
        using client: LocalAIKitModelManager,
        loadedModel: LoadedModelContents,
        history: [LocalAIKitConversationTurn] = [],
        overrideSystemPrompt: String? = nil,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> LocalAIKitAgentRunResult {
        if tools.isEmpty {
            let request = makeChatRequest(
                prompt: prompt,
                history: history,
                overrideSystemPrompt: overrideSystemPrompt
            )
            let result = try await client.generate(request, using: loadedModel, onPartialText: onPartialText)
            return LocalAIKitAgentRunResult(finalResponse: result)
        }

        var currentHistory = history
        var observations: [LocalAIKitAgentToolObservation] = []
        var attemptedToolDecodeRepair = false

        for _ in 0..<maxToolIterations {
            let request = makeToolUseRequest(
                prompt: prompt,
                history: currentHistory,
                overrideSystemPrompt: overrideSystemPrompt
            )

            let result = try await client.generate(
                request,
                using: loadedModel,
                onPartialText: onPartialText
            )

            guard let envelope = decodeToolCall(from: result) else {
                if tools.count == 1, !attemptedToolDecodeRepair, let singleTool = tools.first {
                    attemptedToolDecodeRepair = true
                    currentHistory.append(.init(
                        role: .system,
                        text: """
                        The previous tool call could not be parsed.
                        Return only valid JSON for the tool arguments for \(singleTool.name).
                        Do not include markdown fences, commentary, or extra text.
                        Example JSON:
                        \(singleTool.inputExampleJSON)
                        Raw model output:
                        \(result)
                        """
                    ))
                    continue
                }

                let message = "Unable to decode a tool call from the model output."
                observations.append(.init(name: "tool_decode", result: message))
                currentHistory.append(.init(role: .system, text: "Tool decode failed: \(message)\n\nModel output:\n\(result)"))
                return LocalAIKitAgentRunResult(
                    finalResponse: message,
                    toolObservations: observations
                )
            }

            switch envelope.kind {
            case .final:
                return LocalAIKitAgentRunResult(
                    finalResponse: envelope.response ?? "",
                    toolObservations: observations
                )
            case .toolCall:
                guard let toolCall = envelope.tool else {
                    continue
                }

                guard let tool = tools.first(where: { $0.name == toolCall.name }) else {
                    let message = "Tool \(toolCall.name) is not registered."
                    observations.append(.init(name: toolCall.name, result: message))
                    currentHistory.append(.init(role: .system, text: "Tool \(toolCall.name) failed: \(message)"))
                    continue
                }

                do {
                    let result = try await tool.call(arguments: toolCall.arguments)
                    observations.append(.init(name: tool.name, result: result))
                    currentHistory.append(.init(role: .system, text: "Tool \(tool.name) result: \(result)"))

                    let finalRequest = makeChatRequest(
                        prompt: prompt,
                        history: currentHistory,
                        overrideSystemPrompt: overrideSystemPrompt
                    )
                    let finalResponse = try await client.generate(
                        finalRequest,
                        using: loadedModel,
                        onPartialText: onPartialText
                    )

                    return LocalAIKitAgentRunResult(
                        finalResponse: finalResponse,
                        toolObservations: observations
                    )
                } catch {
                    let message = error.localizedDescription
                    observations.append(.init(name: tool.name, result: message))
                    currentHistory.append(.init(role: .system, text: "Tool \(tool.name) failed: \(message)"))
                    return LocalAIKitAgentRunResult(
                        finalResponse: "Tool \(tool.name) failed: \(message)",
                        toolObservations: observations
                    )
                }
            }
        }

        return LocalAIKitAgentRunResult(
            finalResponse: "Tool loop exhausted before the agent produced a final answer.",
            toolObservations: observations
        )
    }

    private static func toolInstructions(for tools: [LocalAIKitAgentTool]) -> String {
        guard !tools.isEmpty else {
            return ""
        }

        let toolList = tools.map { tool in
            var lines = [
                "- name: \(tool.name)",
                "  description: \(tool.description)"
            ]

            if !tool.inputExampleJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("  exampleJSON: \(tool.inputExampleJSON)")
            }

            return lines.joined(separator: "\n")
        }.joined(separator: "\n")

        return """
        Tool calling instructions:
        - If you need to use a tool, return JSON with kind = "toolCall" and include the tool name and arguments.
        - If you are finished, return JSON with kind = "final" and include a response.
        - If there is only one tool available, return only that tool's arguments as plain JSON.
        - Return JSON only. Do not include markdown fences, explanations, code blocks, or extra commentary.
        - Do not return any text outside the JSON object.

        Available tools:
        \(toolList)
        """
    }

    private static func decodeEnvelope(from text: String) -> LocalAIKitAgentToolEnvelope? {
        guard let jsonText = Self.extractJSONObject(from: text) else {
            return nil
        }

        guard let data = jsonText.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(LocalAIKitAgentToolEnvelope.self, from: data) else {
            return nil
        }

        return decoded
    }

    private static func decodeJSONValue(from text: String) -> LocalAIKitJSONValue? {
        guard let jsonText = Self.extractJSONObject(from: text) else {
            return nil
        }

        guard let data = jsonText.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(LocalAIKitJSONValue.self, from: data) else {
            return nil
        }

        return decoded
    }

    private static func looksLikeToolEnvelope(_ value: LocalAIKitJSONValue) -> Bool {
        guard case .object(let object) = value else {
            return false
        }

        return object["kind"] != nil || object["tool"] != nil || object["response"] != nil
    }

    private static func extractJSONObject(from text: String) -> String? {
        let trimmed = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let object = extractBalancedJSON(from: trimmed, opening: "{", closing: "}") {
            return object
        }

        if let array = extractBalancedJSON(from: trimmed, opening: "[", closing: "]") {
            return array
        }

        return nil
    }

    private static func extractBalancedJSON(from text: String, opening: Character, closing: Character) -> String? {
        guard let startIndex = text.firstIndex(of: opening) else {
            return nil
        }

        var depth = 0
        var isInString = false
        var isEscaping = false
        var currentIndex = startIndex

        while currentIndex < text.endIndex {
            let character = text[currentIndex]

            if isInString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInString = false
                }
            } else {
                if character == "\"" {
                    isInString = true
                } else if character == opening {
                    depth += 1
                } else if character == closing {
                    depth -= 1
                    if depth == 0 {
                        return String(text[startIndex...currentIndex])
                    }
                }
            }

            currentIndex = text.index(after: currentIndex)
        }

        return nil
    }

    private static func prettyPrintedJSON<T: Codable>(from value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return nil
        }

        return String(decoding: data, as: UTF8.self)
    }

    private static func encodeJSONValue(_ value: LocalAIKitJSONValue) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func == (lhs: LocalAIKitAgent, rhs: LocalAIKitAgent) -> Bool {
        lhs.title == rhs.title &&
        lhs.agentTemplate == rhs.agentTemplate &&
        lhs.tools.map(\.name) == rhs.tools.map(\.name) &&
        lhs.maxToolIterations == rhs.maxToolIterations
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(agentTemplate)
        hasher.combine(tools.map(\.name))
        hasher.combine(maxToolIterations)
    }
}
