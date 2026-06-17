//
//  Tooling.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/16/26.
//

import Foundation

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
