# ``LocalAIKit``

LocalAIKit is a Swift framework for preparing local LLM assets for use with `llama.cpp`.

## Overview

The first public API surface focuses on two pieces:

- SDK configuration and model preparation
- Hugging Face model downloads and local caching

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

## Topics

### Core Types

- ``LocalAIKitConfiguration``
- ``LocalAIKitClient``
- ``HuggingFaceRepository``
- ``HuggingFaceModelAsset``
- ``HuggingFaceModelPackage``
- ``DownloadedModel``
- ``HuggingFaceModelDownloader``
