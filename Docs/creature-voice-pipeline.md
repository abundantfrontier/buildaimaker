# Creature voice pipeline: FX, layers, and fine-tune

**Status:** Product / technical direction (fictional characters first)  
**Last updated:** 2026-07-19

## Vision

Users create **monsters, aliens, robots, animals, and other fictional characters**:

- **Mind:** backstory, history, diction → LLM fine-tune / persona data  
- **Voice:** not “clone a human celebrity,” but **creature character** via:

1. **Early:** digital FX on recording or TTS (shippable now-ish)  
2. **Next:** **mix / layer** voice with noise & creature SFX (buzz saw, songbird, swamp, servo…)  
3. **Later (cool “C” path):** adapt/fine-tune a voice model so the *speech itself* is creature-like, optionally still layered  

```text
  Story & diction ──► LLM LoRA / system prompt / persona
         │
  User record or TTS ──► FX chain ──► optional SFX layers ──► voice profile
         │                              (buzz, bird, drip…)
         └──────────── later: trained creature adapter ────┘
```

---

## Why this order

| Stage | User value | Risk | Effort |
|-------|------------|------|--------|
| **A. FX on voice** | Instant “robot / lagoon / ghost” | Low | Low (AVAudioEngine) |
| **B. Mix voice + noise/SFX** | Buzz-saw robot, bird-chorus alien | Low–med (license SFX) | Medium |
| **C. Fine-tune / adapt TTS** | Inherent growl, non-human formants | Med (data, quality) | High |

A+B deliver the fantasy **before** research-grade creature TTS. C makes it “way cool” when ready.

---

## Stage A — Digital FX (early ship)

### Idea

Treat every creature voice as a **signal chain** applied to:

- a short **reference performance** (user does a funny monster voice), or  
- neutral **TTS** output, or  
- both (TTS → FX for consistency)

### Public baseline (what actually works)

There is no single “turn Samantha into 15 characters” cookbook. The published
recipes split by **archetype**. Mixing them is how you get a whirly-tube robot
instead of a person.

1. **Pick the larynx first.** TTS voice / actor is most of the character.
   Cheap DSP cannot invent a new speaker. **Kokoro catalog** (`kokoro-catalog-v1`)
   is the default larynx: each preset maps to a distinct speaker id. macOS `say`
   is the fallback while the ~350 MB model installs.
2. **Human (sultry, pirate, warm baritone).** Source + EQ + breath + rate.
   Close-mic: boost ~180 Hz (proximity), cut ~400 Hz (box), a little air
   above ~7 kHz. Breath is *highpassed noise that rides the speech envelope*,
   not white hiss. Slow down a little. **No delay, no chorus, no comb, no
   big formant OLA.** Comb / 8–12 ms delay *is* the corrugated spinning-tube
   sound (same physics as C-3PO).
3. **Robot / android.** Comb filter (Dream Foundry / Boom Box Post: C-3PO),
   optional bitcrush. Delay is correct here.
4. **Creature (beast, fairy, goblin).** Pitch + *small* formant for mouth
   size (Sage: large formant shifts sound unnatural) + grit. Optional SFX bed.
5. **Ghost / alien.** Detune/chorus + space. Delay is a feature.

Sultry in this app follows (1)+(2). Robot follows (3).

### Example chains (presets)

| Preset | Typical processing |
|--------|-------------------|
| **Sultry** | Female source, near-unity pitch, warmth EQ, intimate breath, slow, dry |
| **Robot** | Comb filter, optional bitcrush / ring mod |
| **Alien** | Slow clipped English, chimes + crystal in the voice |
| **Lagoon / swamp** | Low-pass, underwater feel, wet reverb |
| **Ghost** | Detune chorus + long reverb |
| **Goblin** | Pitch up, mouth-size formant, light grit |
| **Huge beast** | Pitch down, formant down, grit |

### Mac implementation (fits native app)

- **AVAudioEngine** + `AVAudioUnitEQ`, `AVAudioUnitReverb`, `AVAudioUnitDistortion`, time-pitch  
- Optional: [AudioKit](https://audiokit.io/) or custom AU for bitcrush / formant  
- Render offline to WAV → store under `voices/<id>/` as processed **reference** and/or **preview**

### Product UX

```text
Record or generate base line
  → pick Creature preset
  → tweak: Size (pitch/formant), Wetness, Metal, Glitch
  → optional live monitor while recording (A/B dry vs wet)
  → Save voice profile (engine id: "fx-chain-v1" + param JSON)
```

**Consent:** for fictional-first, default subject type **synthetic_or_public_domain** / “I created this character.”  
If user records **their** voice as the dry source, still store self-attestation lightly (“my performance for a fictional character”).

---

## Stage B — Layer voice + noise / creature SFX

### Idea

Final audio = **mix** of:

1. **Speech bed** (dry or FX’d voice / TTS)  
2. **Texture bed** (loopable noise, machinery, nature)  
3. **One-shots** (optional chirps, clanks on phrase boundaries — later)

### Mix topology

```text
                    ┌─ Speech (FX chain) ── gain, ducking
  Master out ◄──┬───┤
                    └─ Texture loop ─────── gain, sidechain duck under speech
                    └─ Optional one-shots ─ triggered per sentence (v2)
```

**Sidechain ducking:** when speech is active, pull texture down 3–8 dB so words stay intelligible (robot still “has a saw,” alien still “has birds,” but you can understand them).

### Texture library (ship small, license clean)

| Category | Examples | Source strategy |
|----------|----------|-----------------|
| Mechanical | Servo, buzz saw (short loop), static | Original synth or CC0 packs |
| Nature | Songbird loop, wind, drip, insect | CC0 / recorded |
| Organic weird | Goo, breath, rumble | Synth + field |
| Sci-fi | Hum, radio noise, warp | Synth |

**Do not** ship copyrighted movie SFX. Prefer **generated** or **CC0** libraries; document SPDX in `voices/.../licenses/`.

### How this interacts with “clone”

- **Clone/F5 path (later):** clone produces speech → then **same FX + layer graph**  
- **Preset path (early):** TTS or user record → FX + layers  
- Voice profile JSON roughly:

```json
{
  "engineId": "creature-fx-v1",
  "baseSource": "user_recording | tts | clone",
  "fxPreset": "robot",
  "fxParams": { "pitchSemitones": -4, "bitcrush": 0.3 },
  "layers": [
    { "id": "buzz_saw_loop", "gainDb": -18, "duckWithSpeech": true },
    { "id": "room_hum", "gainDb": -24, "duckWithSpeech": true }
  ]
}
```

Talk mode / TTS playback runs the graph in real time or pre-renders phrase audio.

---

## Stage C — Fine-tune / adapt so speech *is* the creature

### What “C” means product-wise

Not necessarily full multi-speaker TTS train on day one. Ladder:

| Level | Technique | Result |
|-------|-----------|--------|
| **C0** | Prompt TTS + FX + layers | Looks like C to users |
| **C1** | Few-shot **clone of acted creature voice** (human performs monster) | Speech carries character without celebrity clone |
| **C2** | Fine-tune / LoRA-style **TTS adapter** on creature-labeled data | Inherent non-human timbre |
| **C3** | Multi-modal: speech model + learned residual noise | Buzz/bird partially *in* the model |

C0–C1 unlock most of the magic with less R&D. C2–C3 are differentiators later.

### Data for real fine-tune (C2)

Harder than human read-speech:

- Need **aligned text + audio** of the target style (acted creature lines, synthetic voice+FX rendered as training targets, etc.)  
- Or: train on clean speech then **domain-adapt** with heavy FX’d targets (model learns to emit already-colored speech)  
- Keep **fictional / acted / synthetic** only — not scraped real people

### Pipeline when C lands

```text
Character bible → sample lines → (optional) actor record
       → train/adapt TTS or clone
       → still allow FX + SFX layers on top (never throw away B)
```

**Always keep the mixer.** Even a great creature model benefits from a songbird or saw at −20 dB.

---

## Recording UX: FX while recording (early win)

Help users perform:

1. **Input monitor** with selected preset (low latency)  
2. **Dry save + wet preview** (keep dry for re-FX later; store wet as default ref)  
3. **“Make me sound bigger / wetter / more metal”** sliders, not DSP jargon  
4. **Safety:** peak limiter so monster scream doesn’t clip  

This alone sells “I made a creature” without any neural clone.

---

## Fit to BuildAIMaker modules

| Concern | Package / place |
|---------|-----------------|
| FX graph + render | New `BAMAudioFX` (or under `BAMRunnersVoice`) — pure Swift/AVFoundation preferred for Store later |
| Texture asset pack | `Resources/CreatureTextures/` + license manifests |
| Voice profile schema | Extend `voice_profiles` meta_json / VoiceProfile |
| Talk / playground playback | `BAMInference` TTS path applies graph |
| LLM diction / story | Existing datasets + LoRA + persona (unchanged) |
| Policy | Default fictional; discourage realistic human clone (see design K20) |

Open MLX / F5 remains optional backend; **creature-fx-v1** can be the **default voice engine id** for v1 creature product.

---

## Suggested milestones

| Milestone | Deliverable |
|-----------|-------------|
| **M-Voice-FX** | Presets + param JSON + offline render to voice profile; preview in UI |
| **M-Voice-Mix** | 5–10 texture loops, ducking, mix in profile, licenses |
| **M-Record-Assist** | Live monitor FX while recording; dry+wet artifacts |
| **M-Character-Wizard** | Story → seed JSONL + default diction + suggested voice preset |
| **M-Creature-Adapt** | Optional neural path (clone acted creature or TTS adapt) under same profile schema |

---

## Success criteria (user-facing)

- User creates **Swamp Oracle**: lore fine-tune + lagoon FX + drip texture → Talk mode understandable and “not a normal podcast voice.”  
- User creates **Sawtooth Bot**: robot FX + buzz layer + clipped diction dataset.  
- User creates **Aviary Xenomorph**: light alien FX + songbird bed + formal “translator” diction.  
- No celebrity voice in the default catalog; export packs include texture licenses.

---

## Related

- [design-buildaimaker.md](./design-buildaimaker.md) — personas, consent, dual modality  
- [native-vs-python-backends.md](./native-vs-python-backends.md) — FX can stay native Swift  
- [distribution-and-app-store.md](./distribution-and-app-store.md) — AVAudioEngine path is Store-friendlier than Python clone  
- [adr/0002-voice-engine.md](./adr/0002-voice-engine.md) — F5 and later engines  
- [dogfood-test-data.md](./dogfood-test-data.md) — text data for character minds  
