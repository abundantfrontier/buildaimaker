# Working on this repository

Public home: **[github.com/abundantfrontier/buildaimaker](https://github.com/abundantfrontier/buildaimaker)**

## Clone

```bash
git clone https://github.com/abundantfrontier/buildaimaker.git
cd buildaimaker
```

SSH:

```bash
git remote set-url origin git@github.com:abundantfrontier/buildaimaker.git
```

If a local clone still points at the old Omnibond URL:

```bash
git remote set-url origin https://github.com/abundantfrontier/buildaimaker.git
git fetch origin
git status
```

## Push

GitHub Desktop: add this folder, confirm **origin** is `abundantfrontier/buildaimaker`, then Push.

CLI:

```bash
git push -u origin main
```

CI (`.github/workflows/ci.yml`) runs `swift build` and `swift test` on `push`/`pull_request` to `main`. Avoid extra workflow files unless needed.

## Do not commit

- `~/Library/Application Support/BuildAIMaker/` (minds, adapters, `mcp.token`)
- Hugging Face tokens (Keychain)
- `.DS_Store`, `.env`, private keys (see `.gitignore`)
