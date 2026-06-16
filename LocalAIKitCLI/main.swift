import Foundation
import LocalAIKit

@main
struct LocalAIKitCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let prompt = readPrompt(from: arguments) ?? "Hello!"
            let shouldRunStructuredDemo = arguments.contains("--structured")

            let client = LocalAIKitModelManager()
            let package = defaultPackage()

            print("Downloading model...")
            let loadedModel = try await client.load(package)
            guard client.modelStatus == .ready else {
                throw LocalAIKitError.modelLoadFailed(path: "unknown")
            }
            print("Model loaded from: \(loadedModel.primaryFileURL?.path ?? "unknown")")

            let request = LocalAIKitInferenceRequest(
                prompt: prompt,
                systemPrompt: "You are a helpful assistant.",
                maxTokens: 128,
                temperature: 0.7,
                topP: 0.95,
                topK: 40,
                repeatPenalty: 1.1,
                seed: nil,
                stopSequences: []
            )

            print("Generating reply...")
            let result = try await client.generate(request, using: loadedModel)

            print("")
            print("Reply:")
            print(result.trimmingCharacters(in: .whitespacesAndNewlines))

            if shouldRunStructuredDemo {
                print("")
                print("Structured reply:")
                let structuredRequest = LocalAIKitInferenceRequest(
                    prompt: """
                    Create a JSON object for a contact record with these fields:
                    - name: a realistic full name
                    - age: an integer
                    - isActive: true or false
                    - favoriteTopics: an array of 3 short strings
                    Return JSON only.
                    """,
                    systemPrompt: "You are a precise JSON generator.",
                    maxTokens: 128
                )

                let structured = try await client.generateStructured(
                    structuredRequest,
                    as: ContactRecord.self,
                    using: loadedModel
                )

                print(prettyPrintedJSON(structured) ?? String(describing: structured))
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func readPrompt(from arguments: [String]) -> String? {
        let promptArguments = arguments.filter { $0 != "--structured" }
        let joined = promptArguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func prettyPrintedJSON<T: Encodable>(_ value: T) -> String? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func defaultPackage() -> HuggingFaceModelPackage {
        HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "ggml-org/gemma-3-1b-it-GGUF", revision: "main"),
            assets: [
                HuggingFaceModelAsset(filename: "gemma-3-1b-it-Q4_K_M.gguf")
            ]
        )
    }
}

private struct ContactRecord: Codable {
    let name: String
    let age: Int
    let isActive: Bool
    let favoriteTopics: [String]
}
