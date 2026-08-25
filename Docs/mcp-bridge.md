# BuildAIMaker MCP bridge

Local **stdio MCP** process that talks to the **running** app over a private Unix socket (App RPC).

## Paths

| File | Default |
|------|---------|
| Socket | `~/Library/Application Support/BuildAIMaker/mcp.sock` |
| Token | `~/Library/Application Support/BuildAIMaker/mcp.token` |

Created when **BuildAIMaker** starts. Token mode `0600`. Do not commit these files.

## Build

From the repo root:

```bash
swift build --product buildaimaker-mcp
swift build --product BuildAIMaker
```

Debug binaries land under `.build/<triple>/debug/` (for example `arm64-apple-macosx`).

## Grok / MCP host config

Replace the command path with your local build product:

```toml
# Example ~/.grok/config.toml fragment
[mcp_servers.buildaimaker]
command = "/absolute/path/to/.build/arm64-apple-macosx/debug/buildaimaker-mcp"
# optional:
# env = { BAM_SOCKET = "~/Library/Application Support/BuildAIMaker/mcp.sock", BAM_TOKEN = "~/Library/Application Support/BuildAIMaker/mcp.token" }
```

1. Launch **BuildAIMaker** (creates socket + token).
2. Start the MCP host so it spawns `buildaimaker-mcp`.
3. Tools appear as `buildaimaker__…` (host namespacing). Restart the MCP server after rebuilding the bridge.

## Tools

| MCP tool | Action | Notes |
|----------|--------|--------|
| `app_ping` | `app.ping` | Health |
| `app_get_state` | `app.getState` | Route, selection, flags |
| `app_list_actions` | `app.listActions` | Catalog |
| `app_confirm` | `app.confirm` | **Human UI only** — MCP self-confirm is denied |
| `character_list` / `character_get` / `character_create` / `character_update` / `character_delete` | `character.*` | Delete needs in-app confirm |
| `character_open` | `character.open` | Show edit / playground / train |
| `character_import_mind` | `character.importMind` | |
| `examples_propose` | `examples.propose` | Practice lines |
| `dataset_list` / `dataset_get` / `dataset_import` / `dataset_delete` | `dataset.*` | Delete needs confirm |
| `model_list` | `model.list` | Installed + Apple on-device |
| `playground_set` | `playground.set` | Bind character, speak on/off |
| `chat_send` | `chat.send` | One shot. **Prefers Apple** when available — use Playground UI for Gemma+LoRA |
| `nav_go` / `selection_set` / `ui_guide` | session | Voices/Personas routes are reserved placeholders |
| `persona_list` / `voice_list` | `persona.list` / `voice.list` | Library plumbing; UI hidden |
| `minds_dedupe` | `minds.dedupe` | Default `dryRun: true` |
| `finetune_start` | `finetune.start` | Returns `jobId`; needs Allow |
| `job_get` / `job_list` / `job_cancel` | `job.*` | Poll; no streaming |

## Confirmation

`finetune.start` and `minds.dedupe` with `dryRun: false` return **NEEDS_CONFIRMATION**. Approve or deny the orange banner **in the app**. Agents cannot call `app.confirm` to bypass that.

## Notes

- If the app is quit, calls fail with an app-not-running style error (bridge may stay up).
- No streaming in v1 — poll `job_get` for teach jobs.
- Playground **multi-turn** history is the in-app transcript, not MCP `chat_send`.
