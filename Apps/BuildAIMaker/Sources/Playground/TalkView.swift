import SwiftUI
import BAMCore
import BAMInference
import BAMResourcesUI

/// Talk pane: push-to-talk STT → LLM → TTS with barge-in and mic TCC messaging.
struct TalkView: View {
    @ObservedObject var model: TalkViewModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.talkEnabled {
                flagOffBanner
            }
            talkConfigBar
            Divider()
            talkTranscript
            Divider()
            pttBar
        }
        .onAppear { model.bootstrap() }
        .onChange(of: model.selectedBasePath) { _, _ in model.reload() }
        .onChange(of: model.systemPrompt) { _, _ in model.reload() }
    }

    private var flagOffBanner: some View {
        Text("ff.talkMode is off — Talk UI is disabled.")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
    }

    private var talkConfigBar: some View {
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
                    Toggle(
                        model.adapterEnabled ? "Adapter on" : "Adapter off (base only)",
                        isOn: $model.adapterEnabled
                    )
                    .toggleStyle(.switch)
                    .disabled(model.selectedAdapterPath == nil)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(model.phaseLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(phaseColor)
                    if let stt = model.lastTimestamps.sttMs,
                       let llm = model.lastTimestamps.llmMs,
                       let tts = model.lastTimestamps.ttsMs
                    {
                        Text("STT \(Int(stt)) · LLM \(Int(llm)) · TTS \(Int(tts)) ms")
                            .font(.caption2)
                            .foregroundStyle(BAMColors.tertiaryLabel)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("System prompt")
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                TextField("System override", text: $model.systemPrompt, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }

            if model.tccDenied {
                tccBanner
            }

            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }
            if let err = model.errorMessage, !model.tccDenied {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(
                "ff.talkMode: \(model.talkEnabled ? "on" : "off") · STT \(model.sttBackendId) · LLM \(model.llmBackendId) · TTS \(model.ttsBackendId)"
            )
            .font(.caption2)
            .foregroundStyle(BAMColors.tertiaryLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var tccBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(MicPermissionMessaging.deniedTitle)
                    .font(.callout.weight(.semibold))
                Text(model.errorMessage ?? MicPermissionMessaging.deniedMessage)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Microphone Settings…") {
                    model.openMicrophoneSettings()
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private var talkTranscript: some View {
        Group {
            if model.messages.isEmpty && model.partialTranscript.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(BAMColors.secondaryLabel)
                    Text("Talk mode: hold Push-to-talk, speak, release.")
                        .font(.callout)
                        .foregroundStyle(BAMColors.tertiaryLabel)
                    Text("Barge-in: press PTT again while TTS plays to stop speech.")
                        .font(.caption)
                        .foregroundStyle(BAMColors.tertiaryLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(model.messages) { message in
                                talkBubble(message)
                                    .id(message.id)
                            }
                            if !model.partialTranscript.isEmpty, model.isPTTDown {
                                HStack {
                                    Spacer(minLength: 40)
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text("partial")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(BAMColors.secondaryLabel)
                                        Text(model.partialTranscript)
                                            .font(.body)
                                            .italic()
                                            .padding(10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(Color.accentColor.opacity(0.08))
                                            )
                                    }
                                }
                                .id("partial")
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: model.messages.count) {
                        if let last = model.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func talkBubble(_ message: InferenceChatMessage) -> some View {
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

    private var pttBar: some View {
        VStack(spacing: 10) {
            if model.isBusy || model.phase == .synthesizingTTS || model.phase == .generatingLLM {
                ProgressView(value: model.phase == .synthesizingTTS ? model.lastTTSProgress : nil)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 280)
            }

            HStack(spacing: 16) {
                Button {
                    model.clearTranscript()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(model.messages.isEmpty && model.partialTranscript.isEmpty)

                Spacer()

                // Push-to-talk: press-and-hold via simultaneous gestures.
                Text(model.isPTTDown ? "Listening… release to send" : "Hold to talk")
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)

                pttButton
            }
        }
        .padding(12)
    }

    private var pttButton: some View {
        let enabled = model.canPTT || model.isPTTDown
        return Text(model.isPTTDown ? "Release" : "Push to talk")
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(
                Capsule()
                    .fill(model.isPTTDown ? Color.red.opacity(0.9) : Color.accentColor)
                    .opacity(enabled ? 1 : 0.4)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !model.isPTTDown, model.canPTT {
                            model.pttDown()
                        }
                    }
                    .onEnded { _ in
                        if model.isPTTDown {
                            model.pttUp()
                        }
                    }
            )
            .help("Hold to capture speech; release to run STT→LLM→TTS. Press again during TTS to barge-in.")
            .accessibilityLabel("Push to talk")
    }

    private var phaseColor: Color {
        switch model.phase {
        case .error: return .orange
        case .listening: return .red
        case .synthesizingTTS, .playing: return .accentColor
        case .generatingLLM, .finalizingSTT: return .secondary
        default: return BAMColors.secondaryLabel
        }
    }
}
