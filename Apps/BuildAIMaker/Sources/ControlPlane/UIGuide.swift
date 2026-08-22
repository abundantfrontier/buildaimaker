import Foundation

/// Hand-path recipes so an agent can show the user how to do a job in the UI.
enum UIGuideCatalog {
    struct Recipe: Sendable {
        var task: String
        var title: String
        var route: String
        var highlight: String
        var open: String?
        var wizardStep: String?
        var steps: [String]
    }

    static let all: [Recipe] = [
        Recipe(
            task: "createCharacter",
            title: "Create a character by hand",
            route: "characters",
            highlight: "characters.create",
            open: "create",
            steps: [
                "Open Characters in the sidebar.",
                "Click Create a new character (highlighted).",
                "Type a name, pick a creature type, then Continue → Model.",
                "Pick Apple on-device or an open MLX model.",
                "Paste a story and press Build how they talk.",
                "Hear their voice, then Finish & save.",
            ]
        ),
        Recipe(
            task: "editCharacter",
            title: "Edit a character",
            route: "characters",
            highlight: "characters.edit",
            open: "edit",
            steps: [
                "Open Characters.",
                "Select the character, then click Edit (or Continue if unfinished).",
                "Use Back / Continue to change Name, Model, Story, or Voice.",
                "Finish & save when you’re done.",
            ]
        ),
        Recipe(
            task: "importMind",
            title: "Import a mind dataset",
            route: "datasets",
            highlight: "datasets.import",
            steps: [
                "Open Advanced → Datasets.",
                "Click Import (highlighted) and choose a chat JSONL.",
                "Or from a character’s Story step, Build how they talk to write a mind.",
            ]
        ),
        Recipe(
            task: "importDataset",
            title: "Import a JSONL dataset",
            route: "datasets",
            highlight: "datasets.import",
            steps: [
                "Open Advanced → Datasets.",
                "Click Import and pick an OpenAI-messages or ShareGPT JSONL.",
                "Check the preview, then Import.",
            ]
        ),
        Recipe(
            task: "pickModel",
            title: "Pick a model for a character",
            route: "characters",
            highlight: "wizard.model",
            open: "edit",
            wizardStep: "model",
            steps: [
                "Open the character and go to the Model step.",
                "Choose Apple on-device for chat, or an installed MLX model for later train.",
                "Install more models under Advanced → Models if the list is empty.",
            ]
        ),
        Recipe(
            task: "installModel",
            title: "Install a model",
            route: "models",
            highlight: "models.install",
            steps: [
                "Open Advanced → Models.",
                "Search the catalog or paste a Hugging Face source.",
                "Click Install. Large downloads stay in this window.",
            ]
        ),
        Recipe(
            task: "hearVoice",
            title: "Hear a character voice",
            route: "characters",
            highlight: "wizard.hear",
            open: "edit",
            wizardStep: "voice",
            steps: [
                "Open the character and go to Voice.",
                "Pick a voice preset. Sliders start neutral.",
                "Click Hear their voice (highlighted).",
            ]
        ),
        Recipe(
            task: "pickCharacter",
            title: "Pick a character in Playground",
            route: "playground",
            highlight: "playground.character",
            open: "playground",
            steps: [
                "Open Playground.",
                "Use the Character menu at the top (highlighted).",
                "Turn on Speak replies in character voice to hear answers aloud.",
            ]
        ),
        Recipe(
            task: "openPlayground",
            title: "Chat in Playground",
            route: "playground",
            highlight: "playground.send",
            open: "playground",
            steps: [
                "On Characters, open the character’s Use menu → Open in Playground.",
                "Or click Playground in the sidebar after selecting the character.",
                "Type a line and press Send (highlighted).",
            ]
        ),
        Recipe(
            task: "chat",
            title: "Send a Playground message",
            route: "playground",
            highlight: "playground.send",
            open: "playground",
            steps: [
                "Bind a character (Use → Playground) so the system prompt is theirs.",
                "Type in the box at the bottom.",
                "Press Send. Optional: turn on Speak replies.",
            ]
        ),
        Recipe(
            task: "openTrain",
            title: "Open Train for a character",
            route: "train",
            highlight: "train.start",
            open: "train",
            steps: [
                "On Characters, Use → Train this character (LoRA) or Specialize Apple model.",
                "Confirm the model and mind dataset.",
                "Click Start fine-tune (highlighted). Approve the orange banner if an agent started it.",
            ]
        ),
        Recipe(
            task: "startFinetune",
            title: "Start a fine-tune",
            route: "train",
            highlight: "train.start",
            open: "train",
            steps: [
                "Open Train with the character selected (model + mind already bound).",
                "Choose Open MLX LoRA or Apple adapter.",
                "Click Start. Watch progress under Jobs.",
            ]
        ),
        Recipe(
            task: "listJobs",
            title: "Watch jobs",
            route: "jobs",
            highlight: "jobs.list",
            steps: [
                "Open Advanced → Jobs.",
                "Running and queued jobs appear here.",
                "Cancel from the row menu if you need to stop one.",
            ]
        ),
        Recipe(
            task: "dedupeMinds",
            title: "Remove duplicate mind datasets",
            route: "datasets",
            highlight: "datasets.dedupe",
            steps: [
                "Open Advanced → Datasets.",
                "Click Dedupe minds for a dry-run.",
                "Confirm delete in the dialog. Agent-started deletes also need the orange banner.",
            ]
        ),
        // Future (not in sidebar): cloneVoice → Advanced Voices (F5 stub);
        // personas → pack zip. Hear a character from Characters → Voice instead.
    ]

    static func recipe(for task: String) -> Recipe? {
        let key = task.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { $0.task.compare(key, options: .caseInsensitive) == .orderedSame }
    }
}
