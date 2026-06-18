//
//  LocalAIKitAgentTool.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/17/26.
//

import Foundation

/// A single tool definition that can be registered on an agent.
public struct LocalAIKitAgentTool: Sendable, Hashable, Identifiable {
    /// The stable identifier for the tool instance.
    public let id = UUID()
    /// The tool name used in prompts and tool calls.
    public var name: String
    /// A human-readable description of the tool.
    public var description: String
    /// Example JSON showing the expected tool input shape.
    public var inputExampleJSON: String

    private let executor: @Sendable (LocalAIKitJSONValue) async throws -> String

    /// Creates a tool definition.
    ///
    /// - Parameters:
    ///   - name: The tool name used in prompts and tool calls.
    ///   - description: A short human-readable description of the tool.
    ///   - inputExampleJSON: Example JSON showing the expected input structure.
    ///   - executor: The async handler that performs the tool work.
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

    /// Executes the tool with decoded JSON arguments.
    ///
    /// - Parameters:
    ///   - arguments: The JSON arguments passed by the model.
    /// - Returns: The tool result as a string.
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
