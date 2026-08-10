# Character Studio UX — one-stop shop (toy + research)

**Status:** Product / UX direction  
**Last updated:** 2026-07-19  
**Tone:** Fun to use first; power tools and research paths stay reachable, not front-and-center.

## Product framing

BuildAIMaker is evolving from “ML training GUI” into a **Character Studio**:

> Paste a story or way of speaking → shape a mind (LLM) → shape a creature voice (FX / layers / later train) → talk to it.

| Audience | What they need |
|----------|----------------|
| **Play / “toy”** | Few steps, presets, previews, “that was fun” in minutes |
| **Creator** | Export persona packs, iterate story + voice |
| **Research (us + power users)** | Same pipeline, but expose FX graph, corpora, train jobs, metrics, dry-run logs |

One app, **two depths** of the same flow — not two products.

---

## North-star loop (always visible)

```text
  1. WHO   Character (name, species, vibe)
  2. MIND  Paste text / lore → build “how they talk”
  3. VOICE Sound (presets, FX, layers, record)
  4. PLAY  Chat or Talk
  5. SAVE  Persona pack / share later
```

Sidebar can keep engineering names (Datasets, Jobs) under **Advanced**, while the home path is the wizard above.

```text
Home
  └─ Create a character  (primary CTA)
My characters
Playground / Talk
────────────
Advanced ▸
  Datasets · Models · Train · Jobs · Voices (raw) · Settings
```

---

## Mind: paste text → diction corpus

### User action (simple)

1. Paste free text: monologue, lore bible, sample dialogue, bullet backstory.  
2. Optional: “Make them sound like…” tags (formal, broken translator, only questions, pirate, toddler-alien).  
3. Tap **Build how they talk**.

### System action (under the hood)

| Step | What happens |
|------|----------------|
| **Normalize** | LLM (local when available; stub/template offline) turns paste into structured **character bible** (JSON) |
| **Seed JSONL** | Bible + samples → OpenAI-messages (or ShareGPT) **JSONL** rows for fine-tune |
| **Riff / expand** | Optional: “More like this” — LLM generates additional turns in the same diction from the seed corpus |
| **Review** | User sees **preview cards** (3–5 example exchanges), can edit a line, delete junk, re-riff |
| **Save dataset** | Writes real library dataset (same BAMDatasets path as Advanced import) |

Best on-disk format remains **JSONL messages** (already supported). Users rarely see raw JSONL unless they open Advanced.

### Prompting pattern (implementation sketch)

```text
System: You convert character notes into training dialogues.
User provides: free text + optional style tags.
Output:
  1) character_bible JSON (name, species, traits, speech_rules, taboos)
  2) N dialogue examples as messages[] (system = speech_rules + short identity)
```

**Riff:** sample K existing rows + “write M new exchanges that obey speech_rules.”

### Offline / no-runtime fallback

- Template-based split of pasted paragraphs into user/assistant pairs  
- Fixed system prompt from tags  
- Mark dataset `generated: template` vs `generated: llm` in meta  

Never block the toy loop on managed Python install.

### Research depth (same screen, “Lab” toggle)

- Show/edit raw JSONL  
- Temperature / N for riff  
- Hold-out split %  
- Export corpus only  
- Compare base vs adapter sample gens after train  

---

## Voice: easy fun + teachable FX + research path

### Simple mode (default)

```text
[ Preset grid ]
  Robot · Alien · Lagoon · Ghost · Beast · Birdish · Custom

[ Three sliders ]
  Size (pitch/formant) · Grit · Atmosphere (reverb/wet)

[ Optional textures ]
  ☑ Buzz saw   ☑ Songbird   ☑ Drip   ☑ Servo   (chips, not a DAW)

[ Preview line ]  "Hello. I am your character."
[ Record my performance ]  (optional, with live FX monitor)
```

Output: voice profile with `creature-fx-v1` + params + layers (see [creature-voice-pipeline.md](./creature-voice-pipeline.md)).

### Teach as you go (education without a manual)

| UI moment | Teaching |
|-----------|----------|
| Hover / long-press preset | “Robot: metal + bitcrush — words stay clear, machine vibe” |
| Move **Size** | Live label: “Lower = bigger creature” + tiny waveform/EQ cartoon |
| Enable **Buzz saw** | “Layer under speech; we duck it when they talk so you can understand them” |
| First preview | One-line tip: “If words are muddy, turn Atmosphere down or Size toward center” |
| After save | “You can re-open FX anytime; dry recording is kept when you record” |

Optional **“Why does this sound like this?”** sheet: dry vs wet vs wet+layer A/B.

### Lab mode (research / dog / buzzsaw progress)

Same character, expandable panel:

- Full FX chain list (reorder, bypass each node)  
- Param numeric values, randomize, A/B snapshots  
- Texture gain, ducking dB, HPF on layers  
- Export wet/dry/stems (speech-only, texture-only, master)  
- Hook for later: “Use this render as train target for creature-TTS adapt”  
- Job link: optional neural clone/adapt when runtime exists  

**Principle:** Lab never required for a fun character; always available from “Advanced sound.”

---

## One-stop information architecture

### Create Character wizard (5 steps, skippable)

| Step | Title | Primary controls | Advanced (collapsed) |
|------|--------|------------------|----------------------|
| 1 | **Meet them** | Name, species/preset vibe, avatar color | IDs, tags |
| 2 | **Their story** | Big paste box + style chips + “Build how they talk” | Raw bible JSON, riff count |
| 3 | **Their voice** | Preset + 3 sliders + texture chips + preview | FX graph Lab |
| 4 | **Teach them** | One button: “Practice (fine-tune)” with progress | Base model pick, rank, epochs, Hardware Fit |
| 5 | **Talk** | Chat + Talk (PTT) | System prompt override, adapter on/off |

Step 4 can run **fake LoRA** by default for instant gratification; real train when runtime + model present.

### My Characters

Cards: name, species, last played, badges (mind trained / voice only / pack exported).  
Actions: Play, Edit, Export pack, Duplicate, Delete.

---

## Mapping to existing architecture

| UX concept | Backend |
|------------|---------|
| Paste → corpus | New `BAMCharacterStudio` or service in app: LLM rewrite → `BAMDatasets` import API |
| Riff | Same service, append rows + version dataset |
| Style chips | System prompt fragments + generator constraints |
| Voice presets / sliders | `BAMAudioFX` + voice profile meta |
| Textures | Layer list in profile; assets in Resources |
| Practice (fine-tune) | Existing jobs + materialize + LoRA (fake/real) |
| Talk | Playground + Talk coordinator |
| Export | Persona Pack v1 |
| Lab stems / graphs | Files under `voices/<id>/renders/` |

Feature flags can gate Lab and real train; wizard always on for dogfood.

---

## Copy & mental model (avoid ML jargon up front)

| Avoid leading with | Prefer |
|--------------------|--------|
| Dataset JSONL | How they talk / their words |
| LoRA / rank | Practice / teach them |
| Adapter | Their trained mind |
| TTS / clone | Their voice |
| Job queue | Teaching progress |
| Hardware Fit | “This Mac can handle this character size” (only if refuse) |

Jargon stays in Advanced tooltips for us and researchers.

---

## Success metrics (toy + research)

**Toy (time-to-delight)**

- T1: First character preview (mind samples + voice line) **&lt; 5 minutes**, no terminal  
- T2: First Talk turn with FX voice **&lt; 10 minutes**  
- T3: User can explain “what Grit does” after one session (in-product tip exposure)

**Research**

- R1: Export dry/wet/stems for a buzz-saw or bird layer experiment  
- R2: Same character can attach a future creature-TTS job without new UX paradigm  
- R3: Corpus version history (paste v1 → riff v2 → hand-edit v3) inspectable in Lab  

---

## Non-goals for the toy shell

- Full DAW (Pro Tools)  
- Full LMS (epoch graphs as home screen)  
- Celebrity / realistic human clone catalog  
- Requiring cloud or App Store runtime for basic fun path  

---

## Implementation slices (suggested)

| Slice | Outcome |
|-------|---------|
| **CS-1** Home + Create Character shell (steps 1–3 UI, stub generators) | **Shipped** — Characters sidebar, wizard shell |
| **CS-2** Paste → template/LLM → dataset + preview cards | **Shipped** — offline template builder + riff + Datasets import |
| **CS-3** Voice presets + 3 sliders + preview render | **Shipped** — `BAMAudioFX` creature-fx-v1 + textures |
| **CS-4** Texture chips + ducking | Buzz/bird wow |
| **CS-5** Teach button → existing train job | One-stop close |
| **CS-6** Lab panels (FX graph, raw JSONL, stems) | Research depth |
| **CS-7** Riff / expand corpus with local LLM when available | Grow diction |

---

## Related docs

- [creature-voice-pipeline.md](./creature-voice-pipeline.md) — FX / layers / fine-tune ladder  
- [dogfood-test-data.md](./dogfood-test-data.md) — sample corpora  
- [design-buildaimaker.md](./design-buildaimaker.md) — jobs, personas, dual modality  
- [distribution-and-app-store.md](./distribution-and-app-store.md) — Store-friendly FX path  
