import SwiftUI
import BAMCharacterStudio
import BAMCore
import BAMInference
import BAMResourcesUI

/// Playground shell: Text chat + Talk mode (STT→LLM→TTS) panes.
struct PlaygroundView: View {
    @EnvironmentObject private var characterLaunch: CharacterStudioLaunchContext
    @EnvironmentObject private var controlPlane: ControlPlaneEnvironment
    @StateObject private var textModel = PlaygroundViewModel()
    @StateObject private var talkModel = TalkViewModel()
    @State private var pane: TalkViewModel.PaneMode = .text
    @State private var showChatSettings = false
    @State private var lastSessionNonce = ""

    private let featureFlags = FeatureFlags.default

    var body: some View {
        VStack(spacing: 0) {
            // Talk pane (STT → LLM → TTS) is future; ff.talkMode stays off.
            // Spoken replies in the text pane use Character voice (Kokoro + FX).
            if featureFlags.talkMode {
                panePicker
                Divider()
            }
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
        .toolbar { playgroundToolbar }
        .sheet(isPresented: $showChatSettings) {
            chatSettingsSheet
        }
        .onAppear {
            textModel.reloadCharacters()
            textModel.bootstrap()
            applyPendingCharacter()
            applySessionFromControlPlane()
            if featureFlags.talkMode {
                talkModel.bootstrap()
            }
        }
        .onChange(of: characterLaunch.pendingPlayground?.token) { _, _ in
            applyPendingCharacter()
        }
        .onChange(of: controlPlane.sessionNonce) { _, _ in
            applySessionFromControlPlane()
        }
        .onChange(of: textModel.selectedBasePath) { _, _ in
            textModel.onSelectedBaseModelChanged()
        }
    }

    private var characterPickerBinding: Binding<String?> {
        Binding(
            get: { textModel.boundCharacterId },
            set: { textModel.bindCharacter(id: $0) }
        )
    }

    private func applySessionFromControlPlane() {
        let nonce = controlPlane.sessionNonce
        guard !nonce.isEmpty, nonce != lastSessionNonce else { return }
        lastSessionNonce = nonce
        if let speak = controlPlane.pendingSpeakReplies {
            textModel.speakReplies = speak
        }
        if let id = controlPlane.selectionMap["characterId"] {
            textModel.bindCharacter(id: id)
        }
        if let user = controlPlane.incomingChatUser,
           let assistant = controlPlane.incomingChatAssistant
        {
            textModel.applyIncomingTurn(user: user, assistant: assistant, nonce: nonce)
        }
        if let pending = controlPlane.pendingUserMessage, !pending.isEmpty {
            textModel.draft = pending
            if textModel.canSend {
                textModel.send()
            }
        }
    }

    private func applyPendingCharacter() {
        if let target = characterLaunch.consumePlayground() {
            textModel.applyCharacterLaunch(target)
        } else if textModel.boundCharacterId == nil,
                  let target = characterLaunch.playgroundTargetForActiveCharacter()
        {
            textModel.applyCharacterLaunch(target)
        }
    }

    @ToolbarContentBuilder
    private var playgroundToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if pane == .text, let latency = textModel.lastLatencyMs {
                Text("\(Int(latency)) ms")
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }
            if pane == .talk {
                Text(talkModel.phaseLabel)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }
            if pane == .text, textModel.isSpeaking {
                Button {
                    textModel.stopSpeaking()
                } label: {
                    Label("Stop speaking", systemImage: "stop.fill")
                }
                .help("Stop reading the current reply aloud")
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
                    showChatSettings = true
                } label: {
                    Label("Chat settings", systemImage: "slider.horizontal.3")
                }
                .help("Backend, model, and how they talk")
                Button {
                    textModel.clearTranscript()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(textModel.messages.isEmpty)
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
            } else {
                Button {
                    talkModel.clearTranscript()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(talkModel.messages.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var panePicker: some View {
        // Hide Text/Talk when Talk is flagged off — that pair plus Speak replies
        // reads as two unexplained modes.
        if featureFlags.talkMode {
            HStack {
                Picker("Mode", selection: $pane) {
                    ForEach(TalkViewModel.PaneMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                Spacer()
                Text(pane == .text ? "Type to chat" : "Hold the mic to talk")
                    .font(.caption)
                    .foregroundStyle(BAMColors.tertiaryLabel)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
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
        textTranscript
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    textConfigBar
                    Divider()
                }
                .background(BAMColors.detailBackground)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    textComposer
                }
                .background(BAMColors.detailBackground)
            }
    }

    private var textConfigBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Character", selection: characterPickerBinding) {
                    Text("None").tag(Optional<String>.none)
                    ForEach(textModel.characters) { draft in
                        Text(draft.displayTitle).tag(Optional(draft.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260, alignment: .leading)
                .guideHighlight("playground.character")
                .help("Chat as this character — system prompt and voice come from their card.")

                Text(textModel.backendCaption)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                if textModel.adapterEnabled, let path = textModel.selectedAdapterPath {
                    Text("LoRA · \(textModel.adapters.first(where: { $0.localPath == path })?.displayName ?? URL(fileURLWithPath: path).lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                } else if textModel.boundCharacterId != nil {
                    Text("Base only — no LoRA yet")
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                }
                Spacer(minLength: 8)
            }

            if let err = textModel.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let spoken = textModel.lastSpokenNote {
                Text(spoken)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }
            if let export = textModel.exportMessage {
                Text(export)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .textSelection(.enabled)
            }

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var chatSettingsSheet: some View {
        NavigationStack {
            Form {
                Section("Chat backend") {
                    Picker("Backend", selection: $textModel.backendPreference) {
                        ForEach(LLMBackendPreference.allCases) { pref in
                            Text(pref.title).tag(pref)
                        }
                    }
                }
                Section("Base model") {
                    if textModel.baseModels.isEmpty {
                        Text("None installed")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: $textModel.selectedBasePath) {
                            ForEach(textModel.baseModels) { m in
                                Text(m.displayName).tag(Optional(m.localPath))
                            }
                        }
                    }
                }
                Section("Adapter") {
                    Picker("Adapter", selection: $textModel.selectedAdapterPath) {
                        Text("None").tag(Optional<String>.none)
                        ForEach(textModel.adapters) { a in
                            Text(a.displayName).tag(Optional(a.localPath))
                        }
                    }
                    .disabled(textModel.adapters.isEmpty)
                    Toggle("Use adapter", isOn: $textModel.adapterEnabled)
                        .disabled(textModel.selectedAdapterPath == nil)
                }
                Section("How they talk") {
                    TextEditor(text: $textModel.systemPrompt)
                        .font(.body)
                        .frame(minHeight: 160)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Chat settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showChatSettings = false }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private var textTranscript: some View {
        Group {
            if textModel.messages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(BAMColors.secondaryLabel)
                    Text(
                        textModel.boundCharacterName.map { "Send a message to talk with \($0)." }
                            ?? "Send a message to start chatting."
                    )
                    .font(.callout)
                    .foregroundStyle(BAMColors.tertiaryLabel)
                    Text("Turn on Speak replies to hear answers aloud.")
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
                Text(displayName(for: message.role))
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

    private func displayName(for role: String) -> String {
        switch role {
        case "user":
            return "You"
        case "assistant":
            return textModel.boundCharacterName ?? "Assistant"
        default:
            return role.capitalized
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
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $textModel.speakReplies) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speak replies in character voice")
                        .font(.callout.weight(.medium))
                    Text(
                        textModel.speakReplies
                            ? (textModel.boundCharacterName.map {
                                "On — \($0)’s answers are read aloud."
                            } ?? "On — answers are read aloud.")
                            : "Off — answers stay on screen. Turn on to hear them spoken."
                    )
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                }
            }
            .toggleStyle(.switch)

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
                    .guideHighlight("playground.send")
                }
            }
        }
        .padding(12)
    }
}
