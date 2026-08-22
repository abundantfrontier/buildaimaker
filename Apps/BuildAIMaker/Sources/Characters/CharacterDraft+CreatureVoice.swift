import BAMAudioFX
import BAMCharacterStudio

extension CharacterDraft {
    /// Creature FX knobs from the wizard Voice step.
    func creatureFXParams() -> CreatureFXParams {
        let preset = CreatureVoicePreset(rawValue: voicePreset) ?? .alien
        var textures = Set<CreatureTextureID>()
        var mix: [String: Double] = textureLevels
        for id in textureIdSet {
            if let t = CreatureTextureID(rawValue: id) {
                textures.insert(t)
                if (mix[id] ?? 0) < 0.02 { mix[id] = 0.4 }
            }
        }
        for (id, level) in mix where level > 0.02 {
            if let t = CreatureTextureID(rawValue: id) { textures.insert(t) }
        }
        var params = CreatureFXParams(
            preset: preset,
            size: size,
            grit: grit,
            atmosphere: atmosphere,
            formant: formant,
            metallic: metallic,
            tremble: tremble,
            breath: breath,
            speed: speed,
            robotize: robotize,
            textures: textures,
            register: VoiceRegister(rawValue: voiceRegister) ?? preset.defaultRegister,
            textureMix: mix
        )
        if params.textures == CreatureFXParams.legacyDefaultTextures(for: preset) {
            params.textures = []
        }
        // First Sultry pass used chorus + OLA + higher-register pitch (whirly tube).
        if preset == .sultry, Self.matchesLegacySultryTube(params) {
            return CreatureFXParams.fromPreset(.sultry, register: params.register)
        }
        // Factory Alien sliders (no chord imprint). Promote to the current mix.
        if preset == .alien, Self.matchesLegacyAlienFactory(params) {
            return CreatureFXParams.fromPreset(.alien, register: params.register)
        }
        // Old factory sliders stacked grit + metal + robotize + beds.
        if Self.matchesLegacyFactoryExtras(preset: preset, params: params) {
            let fresh = CreatureFXParams.fromPreset(preset)
            params.grit = fresh.grit
            params.metallic = 0
            params.robotize = 0
            params.tremble = fresh.tremble
            params.breath = fresh.breath
            if params.atmosphere > 0.65 { params.atmosphere = fresh.atmosphere }
            params.textures = []
        }
        return params
    }

    private static func matchesLegacyFactoryExtras(
        preset: CreatureVoicePreset,
        params: CreatureFXParams
    ) -> Bool {
        let oldMetal: Double
        let oldRobot: Double
        let oldGrit: Double
        switch preset {
        case .robot: oldMetal = 0.75; oldRobot = 0.7; oldGrit = 0.55
        case .android: oldMetal = 0.55; oldRobot = 0.4; oldGrit = 0.28
        case .insect: oldMetal = 0.35; oldRobot = 0.25; oldGrit = 0.22
        default: oldMetal = 0.05; oldRobot = 0; oldGrit = -1
        }
        let metalHit = abs(params.metallic - oldMetal) < 0.03
        let robotHit = abs(params.robotize - oldRobot) < 0.03
        let gritHit = oldGrit < 0 || abs(params.grit - oldGrit) < 0.03
        return (metalHit && robotHit) || (params.robotize > 0.55 && params.metallic > 0.5 && gritHit)
    }

    /// Wizard init / first Alien card: grit + metal + room, no chimes.
    private static func matchesLegacyAlienFactory(_ params: CreatureFXParams) -> Bool {
        let sizeHit = abs(params.size - 0.55) < 0.04
        let gritHit = abs(params.grit - 0.22) < 0.04
        let atmoHit = abs(params.atmosphere - 0.45) < 0.04
        let formantHit = abs(params.formant - 0.48) < 0.04
        let metalHit = abs(params.metallic - 0.25) < 0.04
        let trembleHit = abs(params.tremble - 0.20) < 0.04
        let speedHit = abs(params.speed - 0.45) < 0.04
        let noBeds = params.resolvedTextureLevels.isEmpty
        return sizeHit && gritHit && atmoHit && formantHit && metalHit && trembleHit && speedHit && noBeds
    }

    /// Chorus-era Sultry: size 0.44 or 0.56, formant 0.56/0.66, tremble 0.1, some room.
    private static func matchesLegacySultryTube(_ params: CreatureFXParams) -> Bool {
        let sizeHit = abs(params.size - 0.56) < 0.05 || abs(params.size - 0.44) < 0.04
        let formantHit = abs(params.formant - 0.66) < 0.05 || abs(params.formant - 0.56) < 0.04
        let trembleHit = abs(params.tremble - 0.1) < 0.04
        let atmoHit = params.atmosphere > 0.12 && params.atmosphere < 0.28
        return sizeHit && formantHit && trembleHit && atmoHit
    }
}
