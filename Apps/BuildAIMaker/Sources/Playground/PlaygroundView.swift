import SwiftUI
import BAMCore
import BAMInference
import BAMResourcesUI

/// Text playground: select base model + optional adapter, chat, A/B adapter off, export JSONL.
struct PlaygroundView: View {
    @StateObject private var model = PlaygroundViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.playgroundEnabled {
                flagOffBanner
            }
            configBar
            Divider()
            transcript
            Divider()
            composer
        }
        .background(BAMColors.detailBackground)
        .navigationTitle(SidebarDestination.playground.title)
        .onAppear { model.bootstrap() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Playground", systemImage: SidebarDestination.playground.systemImage)
                .font(.headline)
            Spacer()
            if let latency = model.lastLatencyMs {
                Text("\(Int(latency)) ms · \(model.backendId)")
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }
            Button {
                model.reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Rescan base models and adapters")

            Button {
                model.clearTranscript()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(model.messages.isEmpty)
            .help("Clear chat transcript")

            Menu {
                Button("Export conversation (1 row)") {
                    model.exportTranscript(paired: false)
                }
                Button("Export user/assistant pairs") {
                    model.exportTranscript(paired: true)
                }
            } label: {
                Label("Export JSONL", systemImage: "square.and.arrow.up")
            }
            .disabled(!model.canExport)
            .help("Export transcript as OpenAI-messages JSONL dataset candidate")
        }
        .padding(12)
    }

    private var flagOffBanner: some View {
        Text("ff.playground is off — playground UI is disabled.")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
    }

    private var configBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Base model")
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                    if model.baseModels.isEmpty {
                        Text("No local base models")
                            .foregroundStyle(BAMColors.tertiaryLabel)
                            .font(.callout)
                    } else {
                        Picker("Base model", selection: $model.selectedBasePath) {
                            ForEach(model.baseModels) { m in
                                Text(m.displayName)
                                    .tag(Optional(m.localPath))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Adapter (optional)")
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                    Picker("Adapter", selection: $model.selectedAdapterPath) {
                        Text("None").tag(Optional<String>.none)
                        ForEach(model.adapters) { a in
                            Text(a.displayName)
                                .tag(Optional(a.localPath))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    .disabled(model.adapters.isEmpty)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("A/B adapter")
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                    Toggle(model.adapterEnabled ? "Adapter on" : "Adapter off (base only)", isOn: $model.adapterEnabled)
                        .toggleStyle(.switch)
                        .disabled(model.selectedAdapterPath == nil)
                        .help("Toggle adapter off to compare base-only replies")
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("System prompt")
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                TextField("System override", text: $model.systemPrompt, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }

            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }
            if let export = model.exportMessage {
                Text(export)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .textSelection(.enabled)
            }
            if let err = model.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("ff.playground: \(model.playgroundEnabled ? "on" : "off") · backend: \(model.backendId)")
                .font(.caption2)
                .foregroundStyle(BAMColors.tertiaryLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        Group {
            if model.messages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(BAMColors.secondaryLabel)
                    Text("Chat against a base model and optional LoRA adapter.")
                        .font(.callout)
                        .foregroundStyle(BAMColors.tertiaryLabel)
                    Text("Use A/B to turn the adapter off and compare.")
                        .font(.caption)
                        .foregroundStyle(BAMColors.tertiaryLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(model.messages) { message in
                                messageBubble(message)
                                    .id(message.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: model.messages.count) {
                        if let last = model.messages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageBubble(_ message: InferenceChatMessage) -> some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                Text(message.role)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(BAMColors.secondaryLabel)
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(bubbleColor(for: message.role))
                    )
            }
            if message.role != "user" { Spacer(minLength: 40) }
        }
    }

    private func bubbleColor(for role: String) -> Color {
        switch role {
        case "user":
            return Color.accentColor.opacity(0.15)
        case "assistant":
            return Color(nsColor: .controlBackgroundColor)
        default:
            return Color(nsColor: .windowBackgroundColor)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message…", text: $model.draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.send() }
                .disabled(!model.playgroundEnabled || model.isGenerating)

            if model.isGenerating {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
            } else {
                Button {
                    model.send()
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSend)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(12)
    }
}
