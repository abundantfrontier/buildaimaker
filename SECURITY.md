# Security

BuildAIMaker is a **local-first** macOS app. Training weights, minds, adapters, and MCP tokens live under:

```text
~/Library/Application Support/BuildAIMaker/
```

That directory is **not** part of this git repository. Do not commit copies of `mcp.token`, Hugging Face tokens, or library databases.

## Hugging Face tokens

Optional Hub downloads store the token in the **macOS Keychain** (`HFTokenStore`), not in the repo or in Application Support as plaintext source.

## MCP

The Unix socket and sibling `mcp.token` are created at app launch (`0600`). Agents cannot approve expensive or destructive actions; the running app shows an orange Allow / Deny banner.

## Reporting

If you find a vulnerability in this project, please open a **private** advisory on GitHub (or email the maintainers) rather than filing a public issue with exploit details or leaked tokens.
