import SwiftUI
import BAMCore
import BAMInference
import BAMResourcesUI

/// Playground shell: Text chat + Talk mode (STT→LLM→TTS) panes.
struct PlaygroundView: View {
    @EnvironmentObject private var characterLaunch: CharacterStudioLaunchContext
    @StateObject private var textModel = PlaygroundViewModel()
    @StateObject private var talkModel = TalkViewModel()
    @State private var pane: TalkViewModel.PaneMode = .text

    private let featureFlags = FeatureFlags.default

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            panePicker
            Divider()
            Group {
                switch pane {
                case .text:
                    textPane
                case .talk:
                    if featureFlags.talkMode {
                        TalkView(model: talkModel)
                    } else {
                        talkDisabledPlaceholder
                    }
                }
            }
        }
        .background(BAMColors.detailBackground)
        .navigationTitle(SidebarDestination.playground.title)
        .onAppear {
            textModel.bootstrap()
            applyPendingCharacter()
            if featureFlags.talkMode {
                talkModel.bootstrap()
            }
        }
        .onChange(of: characterLaunch.pendingPlayground?.token) { _, _ in
            applyPendingCharacter()
        }
        .onChange(of: textModel.selectedBasePath) { _, _ in
            textModel.onSelectedBaseModelChanged()
        }
    }

    private func applyPendingCharacter() {
        if let target = characterLaunch.consumePlayground() {
            textModel.applyCharacterLaunch(target)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Playground", systemImage: SidebarDestination.playground.systemImage)
                .font(.headline)
            Spacer()
            if pane == .text, let latency = textModel.lastLatencyMs {
                Text("\(Int(latency)) ms · \(textModel.backendId)")
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }
            if pane == .talk {
                Text(talkModel.phaseLabel)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }
            Button {
                if pane == .text {
                    textModel.reload()
                } else {
                    talkModel.reload()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Rescan base models and adapters")

            if pane == .text {
                Button {
                    textModel.clearTranscript()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(textModel.messages.isEmpty)
                .help("Clear chat transcript")

                Menu {
                    Button("Export conversation (1 row)") {
                        textModel.exportTranscript(paired: false)
                    }
                    Button("Export user/assistant pairs") {
                        textModel.exportTranscript(paired: true)
                    }
                } label: {
                    Label("Export JSONL", systemImage: "square.and.arrow.up")
                }
                .disabled(!textModel.canExport)
                .help("Export transcript as OpenAI-messages JSONL dataset candidate")
            } else {
                Button {
                    talkModel.clearTranscript()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(talkModel.messages.isEmpty)
                .help("Clear Talk transcript")
            }
        }
        .padding(12)
    }

    private var panePicker: some View {
        HStack {
            Picker("Mode", selection: $pane) {
                ForEach(TalkViewModel.PaneMode.allCases) { mode in
                    if mode == .talk && !featureFlags.talkMode {
                        Text("\(mode.title) (off)").tag(mode)
                    } else {
                        Text(mode.title).tag(mode)
                    }
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            Spacer()
            Text(pane == .text ? "Text chat" : "Push-to-talk · STT→LLM→TTS")
                .font(.caption)
                .foregroundStyle(BAMColors.tertiaryLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var talkDisabledPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "mic.slash")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(BAMColors.secondaryLabel)
            Text("Talk mode is not enabled (ff.talkMode is off).")
                .font(.callout)
                .foregroundStyle(BAMColors.tertiaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Text pane (existing playground)

    private var textPane: some View {
        VStack(spacing: 0) {
            if !textModel.playgroundEnabled {
                Text("ff.playground is off — playground UI is disabled.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            textConfigBar
            Divider()
            textTranscript
            Divider()
            textComposer
        }
    }

    private var textConfigBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Backend preference: Apple on-device first when available.
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chat backend")
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                    Picker("Backend", selection: $textModel.backendPreference) {
                        ForEach(LLMBackendPreference.allCases) { pref in
                            Text(pref.title).tag(pref)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(textModel.appleModelStatus.isUsable ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text("Apple FM: \(textModel.appleModelStatus.rawValue)")
                            .font(.caption2.weight(.semibold))
                    }
                    Text(textModel.appleModelStatus.detail)
                        .font(.caption2)
                        .foregroundStyle(BAMColors.secondaryLabel)
                        .lineLimit(2)
                }
                Spacer()
            }

            if let name = textModel.boundCharacterName {
                HStack(spacing: 8) {
                    Label("Character: \(name)", systemImage: "theatermasks")
                        .font(.caption.weight(.semibold))
                    Text(textModel.backendId)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (textModel.usingRealGenerate ? Color.green : Color.orange).opacity(0.2),
                            in: Capsule()
                        )
                }
            } else if textModel.statusMessage != nil {
                Text(textModel.statusMessage ?? "")
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(textModel.backendId == AppleFoundationLLMBackend.id
                          ? "Open base (optional for Apple)"
                          : "Base model (MLX)")
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                    if textModel.baseModels.isEmpty {
                        Text("No local base models")
                            .foregroundStyle(BAMColors.tertiaryLabel)
                            .font(.callout)
                    } else {
                        Picker("Base model", selection: $textModel.selectedBasePath) {
                            ForEach(textModel.baseModels) { m in
                                Text(m.displayName)
                                    .tag(Optional(m.localPath))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        textModel.backendId == AppleFoundationLLMBackend.id
                            ? "Foundation adapter (optional)"
                            : "LoRA adapter (optional)"
                    )
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                    Picker("Adapter", selection: $textModel.selectedAdapterPath) {
                        Text("None").tag(Optional<String>.none)
                        ForEach(textModel.adapters) { a in
                            Text(a.displayName)
                                .tag(Optional(a.localPath))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    .disabled(textModel.adapters.isEmpty)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("A/B adapter")
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                    Toggle(
                        textModel.adapterEnabled ? "Adapter on" : "Adapter off (base only)",
                        isOn: $textModel.adapterEnabled
                    )
                    .toggleStyle(.switch)
                    .disabled(textModel.selectedAdapterPath == nil)
                    .help("Toggle adapter off to compare base-only replies")
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("System prompt")
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                TextField("System override", text: $textModel.systemPrompt, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }

            if let status = textModel.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }
            if let export = textModel.exportMessage {
                Text(export)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .textSelection(.enabled)
            }
            if let err = textModel.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("ff.playground: \(textModel.playgroundEnabled ? "on" : "off") · backend: \(textModel.backendId)")
                .font(.caption2)
                .foregroundStyle(BAMColors.tertiaryLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var textTranscript: some View {
        Group {
            if textModel.messages.isEmpty {
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
                            ForEach(textModel.messages) { message in
                                messageBubble(message)
                                    .id(message.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: textModel.messages.count) {
                        if let last = textModel.messages.last {
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

    private var textComposer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message…", text: $textModel.draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit { textModel.send() }
                .disabled(!textModel.playgroundEnabled || textModel.isGenerating)

            if textModel.isGenerating {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
            } else {
                Button {
                    textModel.send()
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!textModel.canSend)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(12)
    }
}
