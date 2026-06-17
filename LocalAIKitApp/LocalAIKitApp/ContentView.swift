import LocalAIKit
import Observation
import SwiftUI

struct ContentView: View {
    @State private var model = DemoAppModel()

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                VStack(alignment: .leading, spacing: 16) {
                    blueprintSection(model)
                    modelSection(model)
                    downloadsSection(model)
                    structuredSection(model)
                    toolSection(model)
                    chatSection(model)
                    statusSection(model)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LocalAIKit Demo App")
                .font(.largeTitle.bold())

            Text("Download a Hugging Face GGUF model, load it locally, and chat with it from this window.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func modelSection(_ model: DemoAppModel) -> some View {
        GroupBox("Model") {
            VStack(alignment: .leading, spacing: 12) {
                modelFields(model)

                HStack(spacing: 12) {
                    Button(model.modelStatus == .downloading || model.modelStatus == .loadingIntoMemory ? "Working..." : "Download & Load Model") {
                        Task {
                            await model.downloadAndLoadModel()
                        }
                    }
                    .disabled(!model.canDownloadModel)

                    Button("Queue Download") {
                        model.queueDownload()
                    }
                    .disabled(!model.canQueueDownload)

                    Text(model.statusText)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func downloadsSection(_ model: DemoAppModel) -> some View {
        GroupBox("Downloads") {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Active") {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.activeDownloads.isEmpty {
                            Text("No active downloads.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.activeDownloads) { download in
                                downloadRow(download)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Completed") {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.completedDownloads.isEmpty {
                            Text("No completed downloads yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.completedDownloads) { download in
                                let isLoaded = model.loadedModel?.package == download.package
                                Button {
                                    model.loadCompletedDownload(download)
                                } label: {
                                    completedDownloadRow(download, isLoaded: isLoaded)
                                }
                                .buttonStyle(.plain)
                                .disabled(isLoaded)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func downloadRow(_ download: LocalAIKitModelDownload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(download.displayName)
                    .font(.headline)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Text("\(download.progressPercentage)%")
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: download.fractionCompleted)

            HStack {
                Text(download.statusText)
                    .foregroundStyle(.secondary)
                Spacer()
                if case .finished = download.downloadStatus {
                    Text("Complete")
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func completedDownloadRow(_ download: LocalAIKitModelDownload, isLoaded: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(download.displayName)
                    .font(.headline)
                Text("Tap to load into memory.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLoaded {
                Label("Loaded", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else {
                Text("Load")
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func blueprintSection(_ model: DemoAppModel) -> some View {
        GroupBox("Agent Blueprint") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Blueprint", selection: $model.selectedBlueprint) {
                        ForEach(LocalAIKitAgentPreset.allCases) { blueprint in
                            Text(blueprint.title).tag(blueprint)
                        }
                    }
                    .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.selectedBlueprintSummary)
                        .foregroundStyle(.secondary)

                    Text("Mode: \(model.selectedBlueprintModeText)")
                        .font(.subheadline.weight(.semibold))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("System Prompt")
                        .font(.headline)
                    TextField("Agent system prompt", text: $model.systemPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Starter Prompt")
                        .font(.headline)
                    Text(model.selectedBlueprint.blueprint.starterPrompt)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 12) {
                    Button("Run Blueprint") {
                        Task {
                            await model.runSelectedBlueprint()
                        }
                    }
                    .disabled(!model.canChat)

                    Text(model.canChat ? "Runs the selected agent preset with its starter prompt." : "Download and load a model first.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func structuredSection(_ model: DemoAppModel) -> some View {
        GroupBox("Structured Output") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Structured Blueprint", selection: $model.structuredBlueprint) {
                    ForEach(LocalAIKitAgentPreset.allCases) { blueprint in
                        Text(blueprint.title).tag(blueprint)
                    }
                }
                .pickerStyle(.menu)

                Text(model.structuredBlueprintSummary)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt")
                        .font(.headline)
                    TextField("Enter a prompt for structured output...", text: $model.structuredPromptText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.canChat)
                }

                HStack(spacing: 12) {
                    Button(model.modelStatus == .generating ? "Working..." : "Generate Structured Output") {
                        Task {
                            await model.runStructuredDemo()
                        }
                    }
                    .disabled(!model.canChat)

                    Text(model.modelStatusText)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Decoded Result")
                        .font(.headline)
                    Text(model.latestStructuredOutputDisplayText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func toolSection(_ model: DemoAppModel) -> some View {
        GroupBox("Tool Calling") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt")
                        .font(.headline)
                    TextField("Ask the tool agent something...", text: $model.toolPromptText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.canChat)
                }

                HStack(spacing: 12) {
                    Button(model.modelStatus == .generating ? "Working..." : "Run Tool Demo") {
                        Task {
                            await model.runToolDemo()
                        }
                    }
                    .disabled(!model.canChat)

                    Text(model.modelStatusText)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Tool Output")
                        .font(.headline)
                    Text(model.toolOutputText.isEmpty ? "No final response yet." : model.toolOutputText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Tool Observations")
                        .font(.headline)
                    Text(model.toolObservationsText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func chatSection(_ model: DemoAppModel) -> some View {
        GroupBox("Chat") {
            VStack(alignment: .leading, spacing: 12) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(model.chatMessages) { message in
                                chatBubble(for: message)
                                    .id(message.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .frame(minHeight: 280)
                    .task(id: model.chatMessages.count) {
                        guard let lastID = model.chatMessages.last?.id else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Message")
                        .font(.headline)

                    TextField("Ask the model something...", text: $model.inputText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.canChat)

                    HStack {
                        Button(model.modelStatus == .generating ? "Thinking..." : "Send Message") {
                            Task {
                                await model.sendMessage()
                            }
                        }
                        .disabled(!model.canChat)

                        Text(model.canChat ? "Chat is ready." : "Download a model first.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func statusSection(_ model: DemoAppModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Load State") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Status: \(model.loadStatusText)")
                    Text("Model: \(model.modelSummary)")
                    if let errorText = model.errorText, !errorText.isEmpty {
                        Text("Error: \(errorText)")
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Latest Reply") {
                ScrollView {
                    Text(model.latestAssistantReplyText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 180)
            }

            GroupBox("Generation Status") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Status: \(model.generationStatusText)")
                    Text("Model: \(model.modelStatusText)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Structured Status") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Status: \(model.modelStatusText)")
                    Text("Result: \(model.structuredResultText)")
                    if !model.structuredOutputJSONText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("JSON:").font(.headline)
                        ScrollView {
                            Text(model.structuredOutputJSONText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 120)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Tool Status") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Status: \(model.modelStatusText)")
                    Text("Output: \(model.toolOutputText)")
                    Text("Observations: \(model.toolObservationsText)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func modelFields(_ model: DemoAppModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            field(
                label: "Repository",
                text: Binding(
                    get: { model.modelRepository },
                    set: { model.modelRepository = $0 }
                )
            )

            field(
                label: "Revision",
                text: Binding(
                    get: { model.modelRevision },
                    set: { model.modelRevision = $0 }
                )
            )

            field(
                label: "GGUF Filename",
                text: Binding(
                    get: { model.modelFilename },
                    set: { model.modelFilename = $0 }
                )
            )

            field(
                label: "System Prompt",
                text: Binding(
                    get: { model.systemPrompt },
                    set: { model.systemPrompt = $0 }
                )
            )
        }
    }

    private func field(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.headline)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func chatBubble(for message: DemoAppModel.ChatMessage) -> some View {
        HStack {
            if message.role == .assistant {
                bubble(message, alignment: .leading, tint: .blue.opacity(0.12))
                Spacer(minLength: 0)
            } else if message.role == .user {
                Spacer(minLength: 0)
                bubble(message, alignment: .trailing, tint: .green.opacity(0.12))
            } else if message.role == .error {
                bubble(message, alignment: .leading, tint: .red.opacity(0.12))
                Spacer(minLength: 0)
            } else {
                bubble(message, alignment: .leading, tint: .gray.opacity(0.12))
                Spacer(minLength: 0)
            }
        }
    }

    private func bubble(_ message: DemoAppModel.ChatMessage, alignment: Alignment, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role.rawValue.capitalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message.text)
                .frame(maxWidth: 520, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, alignment: alignment)
    }
}

#Preview {
    ContentView()
}
