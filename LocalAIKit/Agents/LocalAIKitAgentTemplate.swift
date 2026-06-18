import Foundation

/// A reusable agent configuration that defines prompts, sampling, and output behavior.
public struct LocalAIKitAgentTemplate: Sendable, Hashable, Identifiable {
    /// Sampling controls for generation.
    public struct Sampling: Sendable, Hashable {
        /// The maximum number of tokens the model may generate.
        public var maxTokens: Int
        /// The temperature used during sampling.
        public var temperature: Double
        /// The nucleus sampling threshold.
        public var topP: Double
        /// The number of top candidate tokens to consider.
        public var topK: Int
        /// The penalty applied to repeated tokens.
        public var repeatPenalty: Double

        /// Creates a sampling configuration for an agent template.
        ///
        /// - Parameters:
        ///   - maxTokens: The maximum number of tokens to generate.
        ///   - temperature: The temperature used during sampling.
        ///   - topP: The nucleus sampling threshold.
        ///   - topK: The number of top candidate tokens to consider.
        ///   - repeatPenalty: The penalty applied to repeated tokens.
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

    public enum OutputMode: String, Sendable, Hashable {
        case chat
        case structuredJSON
    }

    /// The stable identifier for the template.
    public let id: String
    /// The display name shown in the UI.
    public var name: String
    /// A short human-readable description of the template.
    public var summary: String
    /// The base system prompt used when building requests.
    public var systemPrompt: String
    /// The starter prompt shown to users when they select this template.
    public var starterPrompt: String
    /// The output mode this template is optimized for.
    public var outputMode: OutputMode
    /// The sampling settings used for generation.
    public var sampling: Sampling
    /// Stop sequences used to end generation cleanly.
    public var stopSequences: [String]
    /// Optional structured-output guidance for JSON-producing templates.
    public var structuredGuide: StructuredGuide?

    /// Creates a reusable agent template.
    ///
    /// - Parameters:
    ///   - id: The stable identifier for the template.
    ///   - name: The display name for the template.
    ///   - summary: A short description of the template.
    ///   - systemPrompt: The base system prompt used for requests.
    ///   - starterPrompt: The starter prompt shown in the UI.
    ///   - outputMode: The output mode this template should use.
    ///   - sampling: The sampling settings used when generating text.
    ///   - stopSequences: The stop sequences used to terminate generation.
    ///   - structuredGuide: Optional extra guidance for structured output.
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

    /// Builds a plain chat request using this template.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt to send.
    ///   - history: Previous conversation turns to include.
    ///   - overrideSystemPrompt: Optional replacement for the template system prompt.
    /// - Returns: A configured inference request for chat output.
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

    /// Builds a structured-output request using this template.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt to send.
    ///   - history: Previous conversation turns to include.
    ///   - overrideSystemPrompt: Optional replacement for the template system prompt.
    /// - Returns: A configured inference request for structured JSON output.
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

    /// Builds a request intended for tool calling.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt to send.
    ///   - history: Previous conversation turns to include.
    ///   - overrideSystemPrompt: Optional replacement for the template system prompt.
    /// - Returns: A configured inference request for tool use.
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
