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

public struct StructuredGuide: Sendable, Hashable {
    public var instructions: String
    public var exampleJSON: String

    public init(instructions: String, exampleJSON: String = "") {
        self.instructions = instructions
        self.exampleJSON = exampleJSON
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
