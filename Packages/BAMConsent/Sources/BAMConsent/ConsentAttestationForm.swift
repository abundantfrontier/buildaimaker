import BAMCore
import BAMModels
import SwiftUI

/// SwiftUI form for creating a voice-cloning `ConsentRecord`.
///
/// Fields: subject type, display name, attestor label, scope, statement checkboxes.
/// Rejects `third_party` without a non-empty subject display name and secondary confirm.
public struct ConsentAttestationForm: View {
    @Binding private var draft: ConsentDraft
    private let onSubmit: (ConsentDraft) -> Void
    private let onCancel: (() -> Void)?

    @State private var validationMessage: String?

    public init(
        draft: Binding<ConsentDraft>,
        onSubmit: @escaping (ConsentDraft) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self._draft = draft
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    public var body: some View {
        Form {
            Section {
                Text(
                    "This product does not provide legal advice. Voice cloning requires an explicit attestation bound by a content hash."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Subject") {
                Picker("Subject type", selection: $draft.subjectType) {
                    Text("Self").tag(ConsentSubjectType.self_)
                    Text("Third party").tag(ConsentSubjectType.thirdParty)
                    Text("Synthetic / public domain").tag(ConsentSubjectType.syntheticOrPublicDomain)
                }
                .pickerStyle(.menu)

                TextField("Subject display name", text: $draft.subjectDisplayName)
                    .textFieldStyle(.roundedBorder)

                TextField("Your label (attestor)", text: $draft.attestorUserLabel)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Scope") {
                Picker("Allowed use", selection: $draft.scope) {
                    Text("Personal use").tag(ConsentScope.personalUse)
                    Text("Shareable export").tag(ConsentScope.shareableExport)
                    Text("Research only").tag(ConsentScope.researchOnly)
                }
                .pickerStyle(.menu)
            }

            Section("Statements") {
                ForEach(draft.statementTexts.indices, id: \.self) { index in
                    Toggle(isOn: bindingForStatement(at: index)) {
                        Text(draft.statementTexts[index])
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if draft.subjectType == .thirdParty {
                Section("Third-party confirmation") {
                    Toggle(isOn: $draft.thirdPartySecondaryConfirmed) {
                        Text(ConsentStatements.thirdPartySecondaryConfirm)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Third-party clones require a named subject and this extra confirmation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Optional") {
                TextField("Jurisdiction note", text: $draft.jurisdictionNote, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Section {
                HStack {
                    if let onCancel {
                        Button("Cancel", role: .cancel, action: onCancel)
                    }
                    Spacer()
                    Button("Create consent record") {
                        submit()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: draft.subjectType) { _, newType in
            if newType != .thirdParty {
                draft.thirdPartySecondaryConfirmed = false
            }
            validationMessage = nil
        }
    }

    private func bindingForStatement(at index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard draft.acceptedStatements.indices.contains(index) else { return false }
                return draft.acceptedStatements[index]
            },
            set: { newValue in
                guard draft.acceptedStatements.indices.contains(index) else { return }
                draft.acceptedStatements[index] = newValue
                validationMessage = nil
            }
        )
    }

    private func submit() {
        do {
            try ConsentValidator.validate(draft)
            validationMessage = nil
            onSubmit(draft)
        } catch let error as ConsentValidationError {
            validationMessage = error.errorDescription
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}

// MARK: - List + create shell (Settings / Voices)

/// Lists stored consent records and presents `ConsentAttestationForm` for new attestations.
public struct ConsentRecordsView: View {
    private let service: ConsentService
    private let onCreated: ((ConsentRecord) -> Void)?

    @State private var records: [ConsentIndexRecord] = []
    @State private var draft = ConsentDraft()
    @State private var showingForm = false
    @State private var lastError: String?
    @State private var lastCreatedHash: String?

    public init(
        service: ConsentService,
        onCreated: ((ConsentRecord) -> Void)? = nil
    ) {
        self.service = service
        self.onCreated = onCreated
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showingForm {
                ConsentAttestationForm(
                    draft: $draft,
                    onSubmit: { d in create(from: d) },
                    onCancel: {
                        showingForm = false
                        lastError = nil
                    }
                )
            } else {
                listBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Voice consent")
        .onAppear { reload() }
    }

    @ViewBuilder
    private var listBody: some View {
        Form {
            Section {
                Text(
                    "Consent records bind voice profiles by id + content hash. Create an attestation before cloning a voice."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Records") {
                if records.isEmpty {
                    Text("No consent records yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(records, id: \.id) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.id)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("hash: \(shortHash(row.contentHash))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(row.createdAt)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if let lastCreatedHash {
                Section("Last created") {
                    Text(lastCreatedHash)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if let lastError {
                Section {
                    Text(lastError)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("New consent attestation…") {
                    draft = ConsentDraft()
                    lastError = nil
                    showingForm = true
                }
            }
        }
        .formStyle(.grouped)
    }

    private func reload() {
        do {
            records = try service.listAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func create(from draft: ConsentDraft) {
        do {
            let record = try service.create(from: draft)
            lastCreatedHash = record.contentHash
            lastError = nil
            showingForm = false
            self.draft = ConsentDraft()
            reload()
            onCreated?(record)
        } catch let error as ConsentValidationError {
            lastError = error.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func shortHash(_ hash: String) -> String {
        let hex = ConsentRecord.normalizeHash(hash)
        guard hex.count > 16 else { return hex }
        return String(hex.prefix(12)) + "…"
    }
}
