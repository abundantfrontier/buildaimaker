import Foundation
import SwiftUI
import UniformTypeIdentifiers
import BAMConsent
import BAMCore
import BAMJobs
import BAMModels
import BAMPersistence
import BAMRunnersVoice

/// Observable façade for the Voices pane: list profiles, import ref audio, consent, clone jobs.
@MainActor
final class VoicesViewModel: ObservableObject {
    @Published private(set) var profiles: [VoiceProfileRecord] = []
    @Published private(set) var consentRecords: [ConsentIndexRecord] = []
    @Published var statusMessage: String?
    @Published private(set) var isBusy = false
    @Published private(set) var activeJobId: String?
    @Published private(set) var activeJobStatus: JobStatus?
    @Published var selectedConsentId: String?
    @Published var sampleText: String = "Hello, this is a preview of my voice."
    @Published var importedReferencePath: String?
    @Published var importedDisplayName: String?

    private let service: VoiceCloneService
    private var pollTask: Task<Void, Never>?

    init(service: VoiceCloneService) {
        self.service = service
    }

    static func makeDefault() throws -> VoicesViewModel {
        VoicesViewModel(service: try VoiceCloneService.makeDefault())
    }

    func refresh() {
        do {
            profiles = try service.listProfiles()
            consentRecords = try service.consentService.listAll()
            if selectedConsentId == nil {
                selectedConsentId = consentRecords.first?.id
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func importReferenceAudio(from url: URL) {
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            // Security-scoped access for file importer.
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let imported = try service.importReferenceAudio(from: url)
            importedReferencePath = imported.referenceAudioPath
            importedDisplayName = url.lastPathComponent
            statusMessage = "Imported \(url.lastPathComponent) → staging"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func startClone() {
        guard !isBusy else { return }
        guard let ref = importedReferencePath else {
            statusMessage = "Import a reference WAV first."
            return
        }
        guard let consentId = selectedConsentId else {
            statusMessage = "Select a consent record (required)."
            return
        }

        isBusy = true
        statusMessage = nil
        Task {
            defer { isBusy = false }
            do {
                let started = try await service.startCloneJob(
                    referenceAudioPath: ref,
                    consentRecordId: consentId,
                    sampleText: sampleText
                )
                activeJobId = started.job.id
                activeJobStatus = started.job.status
                statusMessage = "Clone job \(started.job.id.prefix(8))… queued"
                await watchJob(jobId: started.job.id, profileId: started.voiceProfileId)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func watchJob(jobId: String, profileId: String) async {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let finished = try await self.service.waitForJob(
                    jobId: jobId,
                    timeout: .seconds(120),
                    poll: .milliseconds(150)
                )
                await MainActor.run {
                    self.activeJobStatus = finished.status
                }
                if finished.status == .succeeded {
                    let profile = try await self.service.finalizeSucceededJob(
                        jobId: jobId,
                        voiceProfileId: profileId
                    )
                    await MainActor.run {
                        self.statusMessage = "Voice profile ready (\(profile.id.prefix(8))…)"
                        self.importedReferencePath = nil
                        self.importedDisplayName = nil
                        self.refresh()
                    }
                } else {
                    await MainActor.run {
                        self.statusMessage =
                            "Clone \(finished.status.rawValue)"
                            + (finished.errorMessage.map { ": \($0)" } ?? "")
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    var canStartClone: Bool {
        !isBusy
            && importedReferencePath != nil
            && selectedConsentId != nil
            && !consentRecords.isEmpty
    }
}
