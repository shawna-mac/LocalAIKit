import Foundation
import LocalAIKit
import Observation

@MainActor
@Observable
final class DemoAppModel {
    struct ChatMessage: Identifiable, Hashable {
        enum Role: String, Hashable {
            case system
            case user
            case assistant
            case error
        }

        let id = UUID()
        var role: Role
        var text: String
    }

    struct StructuredContactRecord: Codable, Hashable {
        var name: String
        var title: String
        var email: String
    }

    struct TimeLookupInput: Codable, Hashable {
        var timezone: String
    }

    var modelRepository: String = "ggml-org/gemma-3-1b-it-GGUF"
    var modelRevision: String = "main"
    var modelFilename: String = "gemma-3-1b-it-Q4_K_M.gguf"
    var selectedBlueprint: LocalAIKitAgentPreset = .generalAssistant {
        didSet {
            applySelectedBlueprint()
        }
    }
    var structuredBlueprint: LocalAIKitAgentPreset = .structuredExtractor {
        didSet {
            applyStructuredBlueprint()
        }
    }
    var systemPrompt: String = "You are a helpful assistant."
    var inputText: String = "Hello! What can you help me with?"
    var statusText: String = "Enter a model and download it to begin."
    var errorText: String?
    var structuredPromptText: String = "Extract a contact card with exactly these fields: name, title, and email. My name is Taylor Chen, I work at LocalAIKit Labs as a product engineer, and my email is taylor@localaikit.dev."
    var structuredOutputText: String = ""
    var structuredOutputJSONText: String = ""
    var structuredResultText: String = "No structured output yet."
    var toolPromptText: String = "What time is it in Chicago?"
    var toolOutputText: String = ""
    var toolObservationsText: String = "No tool calls yet."
    var chatMessages: [ChatMessage] = [
        ChatMessage(role: .assistant, text: "Enter a Hugging Face model, download it, and then chat here.")
    ]

    private let client: LocalAIKitModelManager
    private let downloadManager: LocalAIKitDownloadManager

    init() {
        let client = LocalAIKitModelManager()
        self.client = client
        self.downloadManager = .shared
        applySelectedBlueprint()
    }

    var canChat: Bool {
        loadedModel != nil && modelStatus != .generating
    }

    var canDownloadModel: Bool {
        !modelRepository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !modelFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        modelStatus != .downloading &&
        modelStatus != .loadingIntoMemory &&
        modelStatus != .generating
    }

    var canQueueDownload: Bool {
        !modelRepository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !modelFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var modelStatus: LocalAIKitModelStatus { client.modelStatus }

    var loadedModel: LoadedModelContents? { client.loadedModel }

    var modelStatusText: String { client.modelStatusText }

    var generationStatusText: String { client.statusMessage ?? client.modelStatusText }

    var loadStatusText: String { client.statusMessage ?? client.modelStatusText }

    var modelSummary: String {
        let revision = modelRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(modelRepository) @ \(revision.isEmpty ? "main" : revision) / \(modelFilename)"
    }

    var selectedBlueprintSummary: String {
        selectedBlueprint.summary
    }

    var selectedBlueprintModeText: String {
        switch selectedBlueprint.blueprint.outputMode {
        case .chat:
            return "Chat"
        case .structuredJSON:
            return "Structured JSON"
        }
    }

    var structuredBlueprintSummary: String {
        structuredBlueprint.summary
    }

    var activeDownloads: [LocalAIKitModelDownload] {
        downloadManager.activeDownloads
    }

    var completedDownloads: [LocalAIKitModelDownload] {
        downloadManager.completedDownloads
    }

    var latestAssistantReplyText: String {
        let trimmedOutput = client.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOutput.isEmpty {
            return client.outputText
        }

        if let latestAssistant = chatMessages.last(where: { $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return latestAssistant.text
        }

        return "Generating response..."
    }

    var latestStructuredOutputDisplayText: String {
        let trimmedText = structuredOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            return trimmedText
        }

        let trimmedJSON = structuredOutputJSONText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedJSON.isEmpty {
            return trimmedJSON
        }

        return structuredResultText
    }

    func downloadAndLoadModel() async {
        NSLog("LocalAIKitDemoApp: downloadAndLoadModel started")
        errorText = nil
        statusText = "Preparing model..."

        do {
            let package = try makePackage()
            _ = try await client.load(package) { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    let percent = Int((progress.fractionCompleted * 100).rounded())
                    self.statusText = "Downloading \(percent)%..."
                }
            }
            guard loadedModel != nil, modelStatus == .ready else {
                errorText = client.statusMessage ?? "Model load failed."
                statusText = errorText ?? "Model load failed."
                return
            }

            statusText = "Model loaded. You can chat now."
            errorText = nil
            inputText = selectedBlueprint.blueprint.starterPrompt
            structuredPromptText = structuredBlueprint.blueprint.starterPrompt
            chatMessages.append(.init(role: .system, text: "Loaded \(modelSummary)."))
            NSLog("LocalAIKitDemoApp: model loaded")
        } catch {
            NSLog("LocalAIKitDemoApp: downloadAndLoadModel failed: %@", error.localizedDescription)
            handle(error: error)
        }
    }

    func queueDownload() {
        do {
            let package = try makePackage()
            downloadManager.queue(package)
        } catch {
            handle(error: error)
        }
    }

    func loadCompletedDownload(_ download: LocalAIKitModelDownload) {
        do {
            _ = try client.load(download: download)
            statusText = "Loaded \(download.displayName) into memory."
            errorText = nil
            inputText = selectedBlueprint.blueprint.starterPrompt
            structuredPromptText = structuredBlueprint.blueprint.starterPrompt
            chatMessages.append(.init(role: .system, text: "Loaded \(download.displayName)."))
        } catch {
            handle(error: error)
        }
    }

    func runSelectedBlueprint() async {
        inputText = selectedBlueprint.blueprint.starterPrompt
        await sendMessage()
    }

    func sendMessage() async {
        NSLog("LocalAIKitDemoApp: sendMessage started")
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            NSLog("LocalAIKitDemoApp: sendMessage ignored because input was empty")
            return
        }

        guard let loadedModel else {
            NSLog("LocalAIKitDemoApp: sendMessage blocked because model is not loaded")
            errorText = "Download and load a model before chatting."
            statusText = errorText ?? "Model not ready."
            return
        }

        errorText = nil
        chatMessages.append(.init(role: .user, text: trimmedInput))
        let assistantMessageID = UUID()
        chatMessages.append(.init(role: .assistant, text: "Generating response..."))
        inputText = ""

        statusText = "Generating response..."

        do {
            let result = try await client.run(
                selectedAgent,
                prompt: trimmedInput,
                using: loadedModel,
                history: conversationTurns,
                overrideSystemPrompt: systemPrompt,
                onPartialText: { [weak self] partialText in
                    Task { @MainActor [weak self, assistantMessageID] in
                        guard let self else { return }
                        self.updateAssistantMessage(id: assistantMessageID, text: partialText.isEmpty ? "Generating response..." : partialText)
                    }
                }
            )
            NSLog("LocalAIKitDemoApp: client.run completed")

            let rawReply = result.finalResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            let reply = rawReply.isEmpty ? "(empty response)" : rawReply
            updateAssistantMessage(id: assistantMessageID, text: reply)
            statusText = "Reply generated."
        } catch {
            NSLog("LocalAIKitDemoApp: sendMessage failed: %@", error.localizedDescription)
            updateAssistantMessage(id: assistantMessageID, text: error.localizedDescription)
            handle(error: error)
        }
    }

    func runStructuredDemo() async {
        NSLog("LocalAIKitDemoApp: runStructuredDemo started")
        let trimmedInput = structuredPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            structuredResultText = "Enter a prompt for structured output."
            structuredOutputJSONText = ""
            return
        }

        guard let loadedModel else {
            structuredResultText = "Download and load a model before running structured output."
            structuredOutputJSONText = ""
            return
        }

        structuredResultText = modelStatusText
        structuredOutputJSONText = ""
        structuredOutputText = ""
        errorText = nil

        do {
            let decoded: StructuredContactRecord = try await client.generateStructured(
                client.makeAgent(blueprint: structuredBlueprint.blueprint),
                prompt: trimmedInput,
                as: StructuredContactRecord.self,
                using: loadedModel,
                history: conversationTurns,
                overrideSystemPrompt: structuredBlueprint.blueprint.systemPrompt
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(decoded)
            let jsonText = String(decoding: data, as: UTF8.self)

            structuredOutputText = jsonText
            structuredOutputJSONText = jsonText
            structuredResultText = [
                "Name: \(decoded.name)",
                "Title: \(decoded.title)",
                "Email: \(decoded.email)",
            ].joined(separator: "\n")
            structuredOutputText = jsonText
            NSLog("LocalAIKitDemoApp: runStructuredDemo completed")
        } catch {
            let message = error.localizedDescription
            structuredResultText = message
            structuredOutputJSONText = ""
            errorText = message
            statusText = message
            NSLog("LocalAIKitDemoApp: runStructuredDemo failed: %@", message)
        }
    }

    func runToolDemo() async {
        NSLog("LocalAIKitDemoApp: runToolDemo started")
        let trimmedInput = toolPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            toolOutputText = ""
            toolObservationsText = "Enter a prompt for tool calling."
            return
        }

        guard let loadedModel else {
            toolOutputText = ""
            toolObservationsText = "Download and load a model before using tools."
            return
        }

        toolOutputText = ""
        errorText = nil

        let agent = Agent(title: "Time Agent", systemPrompt: "You are a helpful assistant that can use tools to answer time questions.")
            .register(
                "get_current_time",
                description: "Returns the current time for a requested timezone.",
                inputExample: TimeLookupInput(timezone: "America/Chicago")
            ) { input in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let now = Date()
                return [
                    "timezone": input.timezone,
                    "currentTime": formatter.string(from: now)
                ]
            }

        do {
            let result = try await client.run(
                agent,
                prompt: trimmedInput,
                using: loadedModel,
                history: conversationTurns,
                overrideSystemPrompt: nil
            )

            toolOutputText = result.finalResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.toolObservations.isEmpty {
                toolObservationsText = "No tool calls were made."
            } else {
                toolObservationsText = result.toolObservations.map { observation in
                    "\(observation.name): \(observation.result)"
                }.joined(separator: "\n")
            }
            NSLog("LocalAIKitDemoApp: runToolDemo completed")
        } catch {
            let message = error.localizedDescription
            toolOutputText = message
            toolObservationsText = message
            errorText = message
            statusText = message
            NSLog("LocalAIKitDemoApp: runToolDemo failed: %@", message)
        }
    }

    private func makePackage() throws -> HuggingFaceModelPackage {
        let repository = modelRepository.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = modelRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = modelFilename.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !repository.isEmpty else {
            throw LocalAIKitError.invalidRepository
        }

        guard !filename.isEmpty else {
            throw LocalAIKitError.missingModelFilename
        }

        return HuggingFaceModelPackage(
            repository: HuggingFaceRepository(
                identifier: repository,
                revision: revision.isEmpty ? "main" : revision
            ),
            assets: [
                HuggingFaceModelAsset(filename: filename)
            ]
        )
    }

    private var conversationTurns: [LocalAIKitConversationTurn] {
        chatMessages.compactMap { message in
            switch message.role {
            case .user:
                return LocalAIKitConversationTurn(role: .user, text: message.text)
            case .assistant:
                return LocalAIKitConversationTurn(role: .assistant, text: message.text)
            case .system:
                return LocalAIKitConversationTurn(role: .system, text: message.text)
            case .error:
                return nil
            }
        }
    }

    private var selectedAgent: LocalAIKitAgent {
        client.makeAgent(blueprint: selectedBlueprint.blueprint)
    }

    private func applySelectedBlueprint() {
        let blueprint = selectedBlueprint.blueprint
        systemPrompt = blueprint.systemPrompt
        inputText = blueprint.starterPrompt
        statusText = "Selected \(blueprint.name)."
    }

    private func applyStructuredBlueprint() {
        structuredPromptText = structuredBlueprint.blueprint.starterPrompt
        structuredResultText = "Selected \(structuredBlueprint.title) for structured output."
    }

    private func handle(error: Error) {
        let message = error.localizedDescription
        errorText = message
        statusText = message
        structuredResultText = message
        structuredOutputJSONText = ""
        toolOutputText = message
        toolObservationsText = message
        chatMessages.append(.init(role: .error, text: message))
    }

    private func updateAssistantMessage(id: UUID, text: String) {
        guard let index = chatMessages.firstIndex(where: { $0.id == id }) else {
            return
        }

        var updatedMessages = chatMessages
        updatedMessages[index].text = text
        chatMessages = updatedMessages
    }
}
