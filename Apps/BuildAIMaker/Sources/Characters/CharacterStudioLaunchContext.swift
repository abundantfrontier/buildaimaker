import BAMCharacterStudio
import Foundation
import SwiftUI

/// Cross-screen handoff: character wizard → Playground / Train with model + mind bound.
///
/// Held at the app root so Characters / wizard can navigate with preselected
/// base model path, dataset id, and system prompt.
@MainActor
final class CharacterStudioLaunchContext: ObservableObject {
    struct PlaygroundTarget: Equatable, Sendable {
        var characterId: String
        var characterName: String
        var baseModelPath: String?
        var baseModelName: String?
        var baseModelSourceKey: String?
        var systemPrompt: String?
        /// Generation token so re-opening the same character still applies.
        var token: UUID = UUID()
    }

    struct TrainTarget: Equatable, Sendable {
        var characterId: String
        var characterName: String
        var baseModelPath: String?
        var baseModelName: String?
        var baseModelSourceKey: String?
        var datasetId: String?
        /// Prefer Apple Foundation adapter train when character is bound to system FM.
        var prefersAppleFoundationAdapter: Bool = false
        var token: UUID = UUID()
    }

    /// Active character binding shown in Playground/Train banners (not consumed).
    @Published private(set) var activeCharacterName: String?
    @Published private(set) var activeCharacterId: String?

    /// One-shot apply for Playground (cleared after consume).
    @Published var pendingPlayground: PlaygroundTarget?
    /// One-shot apply for Train (cleared after consume).
    @Published var pendingTrain: TrainTarget?

    func bindPlayground(from draft: CharacterDraft) {
        activeCharacterId = draft.id
        activeCharacterName = draft.displayTitle
        pendingPlayground = PlaygroundTarget(
            characterId: draft.id,
            characterName: draft.displayTitle,
            baseModelPath: draft.baseModelPath,
            baseModelName: draft.baseModelName,
            baseModelSourceKey: draft.baseModelSourceKey,
            systemPrompt: draft.bible?.systemPrompt
        )
    }

    func bindTrain(from draft: CharacterDraft) {
        activeCharacterId = draft.id
        activeCharacterName = draft.displayTitle
        pendingTrain = TrainTarget(
            characterId: draft.id,
            characterName: draft.displayTitle,
            baseModelPath: draft.baseModelPath,
            baseModelName: draft.baseModelName,
            baseModelSourceKey: draft.baseModelSourceKey,
            datasetId: draft.datasetId,
            prefersAppleFoundationAdapter: draft.usesAppleFoundationModel
        )
    }

    func clearActiveCharacter() {
        activeCharacterId = nil
        activeCharacterName = nil
        pendingPlayground = nil
        pendingTrain = nil
    }

    /// Take and clear the pending playground handoff.
    func consumePlayground() -> PlaygroundTarget? {
        let value = pendingPlayground
        pendingPlayground = nil
        return value
    }

    /// Take and clear the pending train handoff.
    func consumeTrain() -> TrainTarget? {
        let value = pendingTrain
        pendingTrain = nil
        return value
    }
}
