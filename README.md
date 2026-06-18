# LocalAIKit

LocalAIKit is a Swift SDK for running local LLM workflows on Apple platforms.

It gives you a practical set of building blocks for:

- downloading Hugging Face GGUF models
- loading them into memory
- basic chat and text generation
- reusable agents and presets
- tool calling
- structured JSON output

LocalAIKit uses a bundled `llama` binary target and is packaged as a Swift Package.

## Install

Add the package in Xcode with this URL:

```text
https://github.com/shawna-mac/LocalAIKit.git
```

Select the latest tag, for example `0.1.0`.

## What It Does

At a high level, LocalAIKit helps you:

1. download a GGUF model from Hugging Face
2. download and cache the model locally
3. load it into memory
4. generate text with plain chat, agents, tools, or structured output

The core types you will use most often are:

- `LocalAIKitModelManager`
- `HuggingFaceRepository`
- `HuggingFaceModelAsset`
- `HuggingFaceModelPackage`
- `LocalAIKitInferenceRequest`
- `LocalAIKitAgent`
- `LocalAIKitAgentPreset`
- `LocalAIKitConversationTurn`

## Quick Start

```swift
import LocalAIKit

let client = LocalAIKitModelManager()

let package = HuggingFaceModelPackage(
    repository: HuggingFaceRepository(
        identifier: "ggml-org/gemma-3-1b-it-GGUF",
        revision: "main"
    ),
    assets: [
        HuggingFaceModelAsset(filename: "gemma-3-1b-it-Q4_K_M.gguf")
    ]
)

let loadedModel = try await client.load(package)
print(loadedModel.primaryFileURL?.path ?? "No file loaded")
```

If you already have a downloaded model on disk, you can load that instead:

```swift
let loadedModel = try client.load(downloadedModel: downloadedModel)
```

## Basic Chat

For plain chat, build a `LocalAIKitInferenceRequest` and send it through the model manager.

```swift
import LocalAIKit

let client = LocalAIKitModelManager()
let loadedModel: LoadedModelContents = ...

let request = LocalAIKitInferenceRequest(
    prompt: "Write a short haiku about local AI.",
    systemPrompt: "You are a helpful assistant.",
    maxTokens: 128,
    temperature: 0.7
)

let reply = try await client.generate(request, using: loadedModel)
print(reply)
```

You can also keep conversation history:

```swift
let history: [LocalAIKitConversationTurn] = [
    .init(role: .user, text: "Remember that my favorite color is blue."),
    .init(role: .assistant, text: "Got it."),
]

let followUp = LocalAIKitInferenceRequest(
    prompt: "What color do I like?",
    systemPrompt: "Answer naturally and briefly."
)

let reply = try await client.generate(followUp, using: loadedModel)
print(reply)
```

## Agents

Agents package prompts, sampling, output mode, and optional tools into a reusable runtime.

You can start with a preset:

```swift
import LocalAIKit

let agent = LocalAIKitAgentPreset.generalAssistant.agentTemplate
let runtime = LocalAIKitAgent(agentTemplate: agent)
```

Or create one directly:

```swift
let agent = LocalAIKitAgent(
    title: "Coding Assistant",
    systemPrompt: "You are a careful Swift coding assistant.",
    starterPrompt: "Explain this code and suggest improvements."
)
```

Run the agent against a loaded model:

```swift
let result = try await client.run(
    agent,
    prompt: "Explain async/await in Swift in simple terms.",
    using: loadedModel
)

print(result.finalResponse)
```

## Tool Calling

LocalAIKit agents can register tools and ask the model to choose when to call them.

The simplest path is to register a tool with `register(_:description:inputExample:_:)`:

```swift
import Foundation
import LocalAIKit

struct TimeLookupInput: Codable {
    var timezone: String
}

let agent = LocalAIKitAgent(
    title: "Time Agent",
    systemPrompt: "You answer time questions by using tools when needed."
)
.register(
    "get_current_time",
    description: "Returns the current time for a timezone.",
    inputExample: TimeLookupInput(timezone: "America/Chicago")
)
{ input in
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return [
        "timezone": input.timezone,
        "currentTime": formatter.string(from: Date())
    ]
}
```

Then run the agent:

```swift
let result = try await client.run(
    agent,
    prompt: "What time is it in Chicago?",
    using: loadedModel
)

print(result.finalResponse)
for observation in result.toolObservations {
    print("\(observation.name): \(observation.result)")
}
```

If you want to inspect the tool metadata yourself, the raw pieces are also available:

- `LocalAIKitAgentTool`
- `LocalAIKitAgentToolCall`
- `LocalAIKitAgentToolObservation`
- `LocalAIKitAgentToolEnvelope`
- `LocalAIKitJSONValue`

## Structured Output

Structured output is for typed JSON generation.

The SDK supports a dedicated structured-output path so you can decode directly into a `Codable` type.

```swift
import LocalAIKit

struct ContactRecord: Codable {
    var name: String
    var title: String
    var email: String
}

let structuredAgent = LocalAIKitAgentPreset.structuredExtractor.agentTemplate

let record: ContactRecord = try await client.generateStructured(
    client.makeAgent(agentTemplate: structuredAgent),
    prompt: """
    Extract a contact record from this text:
    My name is Taylor Chen, I work as a product engineer, and my email is taylor@localaikit.dev.
    """,
    as: ContactRecord.self,
    using: loadedModel
)

print(record.name)
print(record.email)
```

If you want to build your own structured agent, use `StructuredGuide` with a custom template:

```swift
let extractor = LocalAIKitAgentTemplate(
    id: "contact-extractor",
    name: "Contact Extractor",
    summary: "Extracts contact records into JSON.",
    systemPrompt: "You extract information faithfully.",
    starterPrompt: "Extract a contact record.",
    outputMode: .structuredJSON,
    structuredGuide: StructuredGuide(
        instructions: "Return only valid JSON that matches the requested Swift type.",
        exampleJSON: """
        {
          "name": "Taylor Chen",
          "title": "product engineer",
          "email": "taylor@localaikit.dev"
        }
        """
    )
)
```

## Model Status

If you are driving the SDK from SwiftUI or another UI, `LocalAIKitModelManager` exposes observable state:

- `modelStatus`
- `modelStatusText`
- `loadedModel`
- `outputText`
- `isBusy`
- `isReady`

That makes it easy to show download progress, generation state, and final output in the UI.

## Demo App

This repository also includes a demo app in `LocalAIAppKitDemo/` that shows:

- model download and loading
- chat
- structured output
- tool calling

## Notes

- The package is designed around Apple platforms.
- The default package build resolves without the native `llama` binary. If you need native generation, we can publish `llama` as a separate binary artifact and wire it back in.
- The SDK is intended for local generation workflows, not hosted inference APIs.

## Roadmap 

- Optimize loading model in and out memory during usage
- Foundation model and MLX support 
- Online deep search
- RAG 
- Planning
- Replanning after tool results
- Self check before final answer
- Task Queue 
- Multi - tool orchestration 
- Retry 
- Task interrupt 
