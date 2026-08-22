# BuildAIMaker MCP bridge

Local **stdio MCP** process that talks to the running app over a private Unix socket (App RPC).

## Paths

| File | Default |
|------|---------|
| Socket | `~/Library/Application Support/BuildAIMaker/mcp.sock` |
| Token | `~/Library/Application Support/BuildAIMaker/mcp.token` |

Created when **BuildAIMaker** starts (`ControlPlaneEnvironment`).

## Build

```bash
cd /Users/kb/Documents/GitHub/buildaimaker
swift build --product buildaimaker-mcp
swift build --product BuildAIMaker
```

## Grok Build / MCP host config

```toml
# Example ~/.grok/config.toml fragment
[[mcp_servers]]
name = "buildaimaker"
command = "/Users/kb/Documents/GitHub/buildaimaker/.build/debug/buildaimaker-mcp"
# optional:
# env = { BAM_SOCKET = ".../mcp.sock", BAM_TOKEN = ".../mcp.token" }
```

1. Launch **BuildAIMaker** (creates socket + token).
2. Start the MCP host so it spawns `buildaimaker-mcp`.
3. Tools appear as `buildaimaker__app_get_state`, etc. (host namespacing).

## Tools (v1)

| MCP tool | Action ID |
|----------|-----------|
| `app_ping` | `app.ping` |
| `app_get_state` | `app.getState` |
| `app_list_actions` | `app.listActions` |
| `app_confirm` | `app.confirm` (human UI only — MCP self-confirm is denied) |
| `character_list` | `character.list` |
| `character_import_mind` | `character.importMind` |
| `minds_dedupe` | `minds.dedupe` |
| `finetune_start` | `finetune.start` |
| `job_get` / `job_list` / `job_cancel` | `job.*` |

## Examples

**Dry-run mind dedupe (safe default):**

```json
{ "name": "minds_dedupe", "arguments": { "dryRun": true } }
```

**Actually delete orphans:**

```json
{ "name": "minds_dedupe", "arguments": { "dryRun": false } }
```

**List characters / start fine-tune / poll job:** use `character_list`, `finetune_start` (`characterId`, `recipe`), `job_get` (`jobId`).

## Confirmation

`finetune.start` and `minds.dedupe` with `dryRun: false` return **NEEDS_CONFIRMATION** from MCP. Approve or deny the orange banner in the running app. Agents cannot call `app.confirm` to bypass that.

## Notes

- If the app is quit, tool calls return **APP_NOT_RUNNING** style errors (bridge stays up).
- Tool list is frozen for the bridge process lifetime; restart MCP after adding actions.
- No streaming in v1 — poll `job_get` for long work.
