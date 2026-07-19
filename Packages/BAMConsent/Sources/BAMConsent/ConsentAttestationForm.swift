import BAMCore
import BAMModels
import BAMPersistence
import SwiftUI

/// SwiftUI form for creating a voice-cloning `ConsentRecord`.
///
/// Fields: subject type, display name, attestor label, scope, statement checkboxes.
/// Rejects `third_party` without a non-empty subject display name and secondary confirm.
public struct ConsentAttestationForm: View {
    @Binding private var draft: ConsentDraft
    private let onSubmit: (ConsentDraft) -> Void
    private let onCancel: (() -> Void)?
    /// External create/persist error surfaced while the form remains open.
    private var submitError: Binding<String?>?

    @State private var validationMessage: String?

    public init(
        draft: Binding<ConsentDraft>,
        onSubmit: @escaping (ConsentDraft) -> Void,
        onCancel: (() -> Void)? = nil,
        submitError: Binding<String?>? = nil
    ) {
        self._draft = draft
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.submitError = submitError
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

            if let message = displayedError {
                Section {
                    Text(message)
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
            clearErrors()
        }
    }

    private var displayedError: String? {
        if let validationMessage, !validationMessage.isEmpty {
            return validationMessage
        }
        if let external = submitError?.wrappedValue, !external.isEmpty {
            return external
        }
        return nil
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
                clearErrors()
            }
        )
    }

    private func clearErrors() {
        validationMessage = nil
        submitError?.wrappedValue = nil
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
    private let onDismiss: (() -> Void)?
    private let onCreated: ((ConsentRecord) -> Void)?

    @State private var records: [ConsentIndexRecord] = []
    @State private var draft = ConsentDraft()
    @State private var showingForm = false
    @State private var lastError: String?
    @State private var formError: String?
    @State private var lastCreatedHash: String?

    public init(
        service: ConsentService,
        onDismiss: (() -> Void)? = nil,
        onCreated: ((ConsentRecord) -> Void)? = nil
    ) {
        self.service = service
        self.onDismiss = onDismiss
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
                        formError = nil
                        lastError = nil
                    },
                    submitError: $formError
                )
            } else {
                listBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Voice consent")
        .toolbar {
            if let onDismiss, !showingForm {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDismiss()
                    }
                }
            }
        }
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
                        consentRow(row)
                    }
                }
            }

            if let lastCreatedHash {
                Section("Last created hash") {
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
                    formError = nil
                    showingForm = true
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func consentRow(_ row: ConsentIndexRecord) -> some View {
        let decoded = row.decodedRecord()
        VStack(alignment: .leading, spacing: 4) {
            if let decoded {
                Text(decoded.subjectDisplayName)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(subjectTypeLabel(decoded.subjectType))
                    Text("·")
                    Text(scopeLabel(decoded.scope))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(row.id)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("hash: \(ConsentRecord.normalizeHash(row.contentHash))")
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            Text(row.createdAt)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func subjectTypeLabel(_ type: ConsentSubjectType) -> String {
        switch type {
        case .self_: return "Self"
        case .thirdParty: return "Third party"
        case .syntheticOrPublicDomain: return "Synthetic / public domain"
        }
    }

    private func scopeLabel(_ scope: ConsentScope) -> String {
        switch scope {
        case .personalUse: return "Personal use"
        case .shareableExport: return "Shareable export"
        case .researchOnly: return "Research only"
        }
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
            formError = nil
            showingForm = false
            self.draft = ConsentDraft()
            reload()
            onCreated?(record)
        } catch let error as ConsentValidationError {
            // Keep form open and surface where the user still is.
            formError = error.errorDescription
        } catch {
            formError = error.localizedDescription
        }
    }
}

// MARK: - Shared shell (Settings / Voices)

/// Opens the library-backed consent UI with an explicit dismiss path.
/// Fails closed with a visible message when the library cannot be opened (no silent in-memory store).
public struct ConsentLibraryShell: View {
    private let onDismiss: () -> Void
    private let onCreated: ((ConsentRecord) -> Void)?

    @State private var service: ConsentService?
    @State private var openError: String?

    public init(
        onDismiss: @escaping () -> Void,
        onCreated: ((ConsentRecord) -> Void)? = nil
    ) {
        self.onDismiss = onDismiss
        self.onCreated = onCreated
    }

    public var body: some View {
        Group {
            if let service {
                ConsentRecordsView(
                    service: service,
                    onDismiss: onDismiss,
                    onCreated: onCreated
                )
            } else if let openError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Library unavailable")
                        .font(.title2.weight(.semibold))
                    Text(openError)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Text("Consent records cannot be created or reviewed until the library database opens successfully.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button("Done", action: onDismiss)
                        .keyboardShortcut(.cancelAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Voice consent")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onDismiss)
                    }
                }
            } else {
                ProgressView("Opening library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Voice consent")
                    .onAppear { openLibrary() }
            }
        }
    }

    private func openLibrary() {
        do {
            let db = try LibraryDatabase.openDefault()
            let store = ConsentStore(
                database: db,
                consentDirectory: LibraryPaths.consent,
                writeJSONFiles: true
            )
            service = ConsentService(store: store)
            openError = nil
        } catch {
            service = nil
            openError = error.localizedDescription
        }
    }
}
