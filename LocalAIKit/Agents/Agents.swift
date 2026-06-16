//
//  Agents.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/6/26.
//

import Foundation

public struct LocalAIKitConversationTurn: Sendable, Hashable, Identifiable {
    public enum Role: String, Sendable, Hashable {
        case system
        case user
        case assistant
    }

    public let id = UUID()
    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public struct LocalAIKitAgentBlueprint: Sendable, Hashable, Identifiable {
    public struct Sampling: Sendable, Hashable {
        public var maxTokens: Int
        public var temperature: Double
        public var topP: Double
        public var topK: Int
        public var repeatPenalty: Double

        public init(
            maxTokens: Int = 256,
            temperature: Double = 0.7,
            topP: Double = 0.95,
            topK: Int = 40,
            repeatPenalty: Double = 1.1
        ) {
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.repeatPenalty = repeatPenalty
        }
    }

    public struct StructuredGuide: Sendable, Hashable {
        public var instructions: String
        public var exampleJSON: String

        public init(instructions: String, exampleJSON: String = "") {
            self.instructions = instructions
            self.exampleJSON = exampleJSON
        }
    }

    public enum OutputMode: String, Sendable, Hashable {
        case chat
        case structuredJSON
    }

    public let id: String
    public var name: String
    public var summary: String
    public var systemPrompt: String
    public var starterPrompt: String
    public var outputMode: OutputMode
    public var sampling: Sampling
    public var stopSequences: [String]
    public var structuredGuide: StructuredGuide?

    public init(
        id: String,
        name: String,
        summary: String,
        systemPrompt: String,
        starterPrompt: String,
        outputMode: OutputMode = .chat,
        sampling: Sampling = .init(),
        stopSequences: [String] = ["\nUser:", "\nAssistant:"],
        structuredGuide: StructuredGuide? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.systemPrompt = systemPrompt
        self.starterPrompt = starterPrompt
        self.outputMode = outputMode
        self.sampling = sampling
        self.stopSequences = stopSequences
        self.structuredGuide = structuredGuide
    }

    public func makeChatRequest(
        prompt: String,
        history: [LocalAIKitConversationTurn] = [],
        overrideSystemPrompt: String? = nil
    ) -> LocalAIKitInferenceRequest {
        let transcript = Self.composeTranscript(history: history, userPrompt: prompt)
        return LocalAIKitInferenceRequest(
            prompt: transcript,
            systemPrompt: Self.effectiveSystemPrompt(
                overrideSystemPrompt: overrideSystemPrompt,
                fallback: systemPrompt,
                structuredGuide: nil
            ),
            maxTokens: sampling.maxTokens,
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            repeatPenalty: sampling.repeatPenalty,
            seed: nil,
            stopSequences: stopSequences
        )
    }

    public func makeStructuredRequest(
        prompt: String,
        history: [LocalAIKitConversationTurn] = [],
        overrideSystemPrompt: String? = nil
    ) -> LocalAIKitInferenceRequest {
        let transcript = Self.composeTranscript(history: history, userPrompt: prompt)
        let request = LocalAIKitInferenceRequest(
            prompt: transcript,
            systemPrompt: Self.effectiveSystemPrompt(
                overrideSystemPrompt: overrideSystemPrompt,
                fallback: systemPrompt,
                structuredGuide: structuredGuide
            ),
            maxTokens: sampling.maxTokens,
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            repeatPenalty: sampling.repeatPenalty,
            seed: nil,
            stopSequences: stopSequences
        )

        return request.forStructuredOutput()
    }

    public func makeToolRequest(
        prompt: String,
        history: [LocalAIKitConversationTurn] = [],
        overrideSystemPrompt: String? = nil
    ) -> LocalAIKitInferenceRequest {
        let transcript = Self.composeTranscript(history: history, userPrompt: prompt)
        let request = LocalAIKitInferenceRequest(
            prompt: transcript,
            systemPrompt: Self.effectiveSystemPrompt(
                overrideSystemPrompt: overrideSystemPrompt,
                fallback: systemPrompt,
                structuredGuide: structuredGuide
            ),
            maxTokens: sampling.maxTokens,
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            repeatPenalty: sampling.repeatPenalty,
            seed: nil,
            stopSequences: stopSequences
        )

        return request
    }

    private static func composeTranscript(history: [LocalAIKitConversationTurn], userPrompt: String) -> String {
        var transcript = ""

        for turn in history {
            switch turn.role {
            case .system:
                transcript += "System: \(turn.text)\n"
            case .user:
                transcript += "User: \(turn.text)\n"
            case .assistant:
                transcript += "Assistant: \(turn.text)\n"
            }
        }

        transcript += "User: \(userPrompt)\nAssistant:"
        return transcript
    }

    private static func effectiveSystemPrompt(
        overrideSystemPrompt: String?,
        fallback: String,
        structuredGuide: StructuredGuide?
    ) -> String? {
        let basePrompt = (overrideSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? overrideSystemPrompt!
            : fallback

        var components: [String] = []
        if !basePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components.append(basePrompt)
        }

        if let structuredGuide {
            components.append(structuredGuide.instructions)
            if !structuredGuide.exampleJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                components.append("Example JSON:\n\(structuredGuide.exampleJSON)")
            }
        }

        return components.isEmpty ? nil : components.joined(separator: "\n\n")
    }
}

public enum LocalAIKitJSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LocalAIKitJSONValue])
    case object([String: LocalAIKitJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .number(Double(int))
        } else if let double = try? container.decode(Double.self) {
            self = .number(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([LocalAIKitJSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: LocalAIKitJSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .number(let number):
            try container.encode(number)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        }
    }
}

public struct LocalAIKitAgentToolCall: Sendable, Hashable, Codable {
    public var name: String
    public var arguments: LocalAIKitJSONValue

    public init(name: String, arguments: LocalAIKitJSONValue = .object([:])) {
        self.name = name
        self.arguments = arguments
    }
}

public struct LocalAIKitAgentToolObservation: Sendable, Hashable, Codable {
    public var name: String
    public var result: String

    public init(name: String, result: String) {
        self.name = name
        self.result = result
    }
}

public struct LocalAIKitAgentToolEnvelope: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case final
        case toolCall
    }

    public var kind: Kind
    public var response: String?
    public var tool: LocalAIKitAgentToolCall?

    public init(kind: Kind, response: String? = nil, tool: LocalAIKitAgentToolCall? = nil) {
        self.kind = kind
        self.response = response
        self.tool = tool
    }
}

public struct LocalAIKitAgentTool: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public var name: String
    public var description: String
    public var inputExampleJSON: String

    private let executor: @Sendable (LocalAIKitJSONValue) async throws -> String

    public init(
        name: String,
        description: String,
        inputExampleJSON: String,
        executor: @escaping @Sendable (LocalAIKitJSONValue) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.inputExampleJSON = inputExampleJSON
        self.executor = executor
    }

    public func call(arguments: LocalAIKitJSONValue) async throws -> String {
        try await executor(arguments)
    }

    public static func == (lhs: LocalAIKitAgentTool, rhs: LocalAIKitAgentTool) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

public struct LocalAIKitAgentRunResult: Sendable, Hashable {
    public var finalResponse: String
    public var toolObservations: [LocalAIKitAgentToolObservation]

    public init(finalResponse: String, toolObservations: [LocalAIKitAgentToolObservation] = []) {
        self.finalResponse = finalResponse
        self.toolObservations = toolObservations
    }
}

public struct LocalAIKitAgent: Sendable, Hashable {
    public var title: String
    public var blueprint: LocalAIKitAgentBlueprint
    public var tools: [LocalAIKitAgentTool]
    public var maxToolIterations: Int

    public init(
        title: String,
        systemPrompt: String = "",
        starterPrompt: String = "",
        outputMode: LocalAIKitAgentBlueprint.OutputMode = .chat
    ) {
        self.title = title
        self.blueprint = LocalAIKitAgentBlueprint(
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

    public init(
        blueprint: LocalAIKitAgentBlueprint,
        tools: [LocalAIKitAgentTool] = [],
        maxToolIterations: Int = 4
    ) {
        self.title = blueprint.name
        self.blueprint = blueprint
        self.tools = tools
        self.maxToolIterations = maxToolIterations
    }

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

    public func makeChatRequest(
        prompt: String,
        history: [LocalAIKitConversationTurn] = [],
        overrideSystemPrompt: String? = nil
    ) -> LocalAIKitInferenceRequest {
        blueprint.makeChatRequest(
            prompt: prompt,
            history: history,
            overrideSystemPrompt: overrideSystemPrompt
        )
    }

    public func makeStructuredRequest(
        prompt: String,
        history: [LocalAIKitConversationTurn] = [],
        overrideSystemPrompt: String? = nil
    ) -> LocalAIKitInferenceRequest {
        blueprint.makeStructuredRequest(
            prompt: prompt,
            history: history,
            overrideSystemPrompt: overrideSystemPrompt
        )
    }

    public func makeToolUseRequest(
        prompt: String,
        history: [LocalAIKitConversationTurn] = [],
        overrideSystemPrompt: String? = nil
    ) -> LocalAIKitInferenceRequest {
        var request = blueprint.makeToolRequest(
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
           let arguments = Self.decodeJSONValue(from: candidateText) {
            return LocalAIKitAgentToolEnvelope(
                kind: .toolCall,
                tool: LocalAIKitAgentToolCall(name: singleTool.name, arguments: arguments)
            )
        }

        return nil
    }

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
                let message = "Unable to decode a tool call from the model output."
                observations.append(.init(name: "tool_decode", result: message))
                currentHistory.append(.init(role: .system, text: message))
                continue
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

                let result = try await tool.call(arguments: toolCall.arguments)
                observations.append(.init(name: tool.name, result: result))
                currentHistory.append(.init(role: .system, text: "Tool \(tool.name) result: \(result)"))
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
        - If there is only one tool available, you may also return only that tool's arguments as plain JSON.
        - Do not include markdown fences or commentary.

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
        lhs.blueprint == rhs.blueprint &&
        lhs.tools.map(\.name) == rhs.tools.map(\.name) &&
        lhs.maxToolIterations == rhs.maxToolIterations
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(blueprint)
        hasher.combine(tools.map(\.name))
        hasher.combine(maxToolIterations)
    }
}

public typealias Agent = LocalAIKitAgent

public enum LocalAIKitAgentBlueprintPreset: String, CaseIterable, Identifiable, Sendable, Hashable {
    case generalAssistant
    case structuredExtractor
    case conciseSummarizer
    case codingAssistant

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .generalAssistant:
            return "General Assistant"
        case .structuredExtractor:
            return "Structured Extractor"
        case .conciseSummarizer:
            return "Concise Summarizer"
        case .codingAssistant:
            return "Coding Assistant"
        }
    }

    public var summary: String {
        switch self {
        case .generalAssistant:
            return "A friendly conversational agent for general chat and helpful answers."
        case .structuredExtractor:
            return "A blueprint for strict JSON extraction into typed Swift models."
        case .conciseSummarizer:
            return "A short-form agent that turns longer text into compact summaries."
        case .codingAssistant:
            return "A developer-focused agent that explains and writes code carefully."
        }
    }

    public var blueprint: LocalAIKitAgentBlueprint {
        switch self {
        case .generalAssistant:
            return LocalAIKitAgentBlueprint(
                id: rawValue,
                name: title,
                summary: summary,
                systemPrompt: "You are a helpful assistant that answers clearly, directly, and accurately.",
                starterPrompt: "Hello! How can you help me today?",
                outputMode: .chat,
                sampling: .init(maxTokens: 256, temperature: 0.7, topP: 0.95, topK: 40, repeatPenalty: 1.1)
            )
        case .structuredExtractor:
            return LocalAIKitAgentBlueprint(
                id: rawValue,
                name: title,
                summary: summary,
                systemPrompt: "You extract information faithfully and return only valid JSON.",
                starterPrompt: "Extract a contact record with fields name, title, and email from this text: My name is Taylor Chen, I work as a product engineer, and my email is taylor@localaikit.dev.",
                outputMode: .structuredJSON,
                sampling: .init(maxTokens: 180, temperature: 0, topP: 1, topK: 1, repeatPenalty: 1),
                structuredGuide: .init(
                    instructions: "Return only valid JSON. Do not include markdown fences, commentary, or extra text.",
                    exampleJSON: """
                    {
                      "name": "Taylor Chen",
                      "title": "product engineer",
                      "email": "taylor@localaikit.dev"
                    }
                    """
                )
            )
        case .conciseSummarizer:
            return LocalAIKitAgentBlueprint(
                id: rawValue,
                name: title,
                summary: summary,
                systemPrompt: "You summarize text in a concise, high-signal way.",
                starterPrompt: "Summarize the following text in three bullet points.",
                outputMode: .chat,
                sampling: .init(maxTokens: 160, temperature: 0.4, topP: 0.9, topK: 25, repeatPenalty: 1.0)
            )
        case .codingAssistant:
            return LocalAIKitAgentBlueprint(
                id: rawValue,
                name: title,
                summary: summary,
                systemPrompt: "You are a careful coding assistant. Prefer correctness, clarity, and practical code examples.",
                starterPrompt: "Explain this Swift snippet and suggest improvements.",
                outputMode: .chat,
                sampling: .init(maxTokens: 320, temperature: 0.2, topP: 0.9, topK: 30, repeatPenalty: 1.05)
            )
        }
    }
}

public extension LocalAIKitModelManager {
    func makeAgent(blueprint: LocalAIKitAgentBlueprint) -> LocalAIKitAgent {
        LocalAIKitAgent(blueprint: blueprint)
    }

    func generateStructured<T: Decodable>(
        _ agent: LocalAIKitAgent,
        prompt: String,
        as type: T.Type = T.self,
        using loadedModel: LoadedModelContents,
        history: [LocalAIKitConversationTurn] = [],
        overrideSystemPrompt: String? = nil,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> T {
        let request = agent.makeStructuredRequest(
            prompt: prompt,
            history: history,
            overrideSystemPrompt: overrideSystemPrompt
        )

        return try await generateStructured(
            request,
            as: type,
            using: loadedModel,
            onPartialText: onPartialText
        )
    }

    func run(
        _ agent: LocalAIKitAgent,
        prompt: String,
        using loadedModel: LoadedModelContents,
        history: [LocalAIKitConversationTurn] = [],
        overrideSystemPrompt: String? = nil,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> LocalAIKitAgentRunResult {
        try await agent.run(
            prompt: prompt,
            using: self,
            loadedModel: loadedModel,
            history: history,
            overrideSystemPrompt: overrideSystemPrompt,
            onPartialText: onPartialText
        )
    }
}
