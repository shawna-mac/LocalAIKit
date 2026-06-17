//
//  Presets.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/16/26.
//

import Foundation

public enum LocalAIKitAgentPreset: String, CaseIterable, Identifiable, Sendable, Hashable {
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
            return "A template for strict JSON extraction into typed Swift models."
        case .conciseSummarizer:
            return "A short-form agent that turns longer text into compact summaries."
        case .codingAssistant:
            return "A developer-focused agent that explains and writes code carefully."
        }
    }

    public var agentTemplate: LocalAIKitAgentTemplate {
        switch self {
        case .generalAssistant:
            return LocalAIKitAgentTemplate(
                id: rawValue,
                name: title,
                summary: summary,
                systemPrompt: "You are a helpful assistant that answers clearly, directly, and accurately.",
                starterPrompt: "Hello! How can you help me today?",
                outputMode: .chat,
                sampling: .init(maxTokens: 256, temperature: 0.7, topP: 0.95, topK: 40, repeatPenalty: 1.1)
            )
        case .structuredExtractor:
            return LocalAIKitAgentTemplate(
                id: rawValue,
                name: title,
                summary: summary,
                systemPrompt: "You extract information faithfully and return only valid JSON.",
                starterPrompt: "Extract a contact record with fields name, title, and email from this text: My name is Taylor Chen, I work as a product engineer, and my email is taylor@localaikit.dev.",
                outputMode: .structuredJSON,
                sampling: .init(maxTokens: 180, temperature: 0, topP: 1, topK: 1, repeatPenalty: 1),
                structuredGuide: StructuredGuide(
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
            return LocalAIKitAgentTemplate(
                id: rawValue,
                name: title,
                summary: summary,
                systemPrompt: "You summarize text in a concise, high-signal way.",
                starterPrompt: "Summarize the following text in three bullet points.",
                outputMode: .chat,
                sampling: .init(maxTokens: 160, temperature: 0.4, topP: 0.9, topK: 25, repeatPenalty: 1.0)
            )
        case .codingAssistant:
            return LocalAIKitAgentTemplate(
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

@available(*, deprecated, renamed: "LocalAIKitAgentPreset")
public typealias LocalAIKitAgentTemplatePreset = LocalAIKitAgentPreset
