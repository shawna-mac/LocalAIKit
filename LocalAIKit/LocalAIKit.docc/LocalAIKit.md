# ``LocalAIKit``

LocalAIKit is a Swift framework for preparing local LLM assets for use with `llama.cpp`.

If you add the native `llama` binary target from `Package.swift` to your app or Xcode project, LocalAIKit uses the native `LlamaCppInferenceEngine` automatically. Otherwise it falls back to a stub engine that reports `inferenceEngineNotConfigured`.

## Overview

The first public API surface focuses on three pieces:

- SDK configuration and model preparation
- Hugging Face model downloads and local caching
- In-memory model loading and observable state for UI bindings
- Inference requests, results, and observable generation state
- Agent blueprints for reusable personas and task presets

## Getting started

Create a client and point it at one or more Hugging Face model files:

```swift
import LocalAIKit

let client = LocalAIKitClient()
let package = HuggingFaceModelPackage(
    repository: HuggingFaceRepository(identifier: "ggml-org/gemma-3-1b-it-GGUF"),
    assets: [
        HuggingFaceModelAsset(filename: "gemma-3-1b-it-Q4_K_M.gguf")
    ]
)

let model = try await client.prepareModel(package)
print(model.primaryFileURL?.path ?? "missing")
```

To get observable state that can drive a SwiftUI or other UI layer:

```swift
let state = LocalAIKitLoadState(client: client)
await state.load(package)

switch state.phase {
case .ready:
    print(state.loadedModel?.totalByteCount ?? 0)
case .failed(let message):
    print(message)
default:
    break
}
```

Once you have a loaded model and an inference engine configured, you can generate text:

```swift
let request = LocalAIKitInferenceRequest(prompt: "Write a haiku about local AI.")
let result = try await client.generate(request, package: package)
print(result.text)
```

You can also define an agent blueprint to keep a reusable persona or workflow in one place:

```swift
let blueprint = LocalAIKitAgentBlueprintPreset.structuredExtractor.blueprint
let agent = LocalAIKitAgent(blueprint: blueprint)
let request = agent.makeStructuredRequest(prompt: "Extract the contact info from this text.")
```

For tool calling, the agent can register Swift handlers and run a tool loop:

```swift
struct TimeLookupInput: Codable {
    var timezone: String
}

let agent = Agent(title: "Time Agent")
    .register(
        "get_current_time",
        description: "Returns the current time for a timezone.",
        inputExample: TimeLookupInput(timezone: "America/Chicago")
    ) { input in
        ["timezone": input.timezone]
    }
```

## Topics

### Core Types

- ``LocalAIKitConfiguration``
- ``LocalAIKitClient``
- ``HuggingFaceRepository``
- ``HuggingFaceModelAsset``
- ``HuggingFaceModelPackage``
- ``DownloadedModel``
- ``LoadedModelContents``
- ``LocalAIKitLoadPhase``
- ``LocalAIKitLoadState``
- ``LocalAIKitInferenceRequest``
- ``LocalAIKitInferenceResult``
- ``LocalAIKitInferencePhase``
- ``LocalAIKitInferenceState``
- ``LocalAIKitInferenceEngine``
- ``LlamaCppInferenceEngine``
- ``UnsupportedLocalAIKitInferenceEngine``
- ``HuggingFaceModelDownloader``
- ``LocalAIKitAgentBlueprint``
- ``LocalAIKitAgent``
- ``LocalAIKitAgentBlueprintPreset``
- ``LocalAIKitConversationTurn``
- ``LocalAIKitAgentTool``
- ``LocalAIKitAgentToolCall``
- ``LocalAIKitAgentToolObservation``
- ``LocalAIKitAgentToolEnvelope``
- ``LocalAIKitJSONValue``
- ``LocalAIKitAgentRunResult``
- ``Agent``
