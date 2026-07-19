# Pushing this work to GitHub (GitHub Desktop)

The agent environment often **cannot** authenticate to `github.com` over HTTPS. Your **GitHub Desktop** app on this Mac can.

## Recommended: one branch with the full MVP

All execute-plan work was integrated onto a **stack tip**. For a simple Desktop push, use a single feature branch:

| Branch | What it is |
|--------|------------|
| `feature/buildaimaker-mvp` | Full app + docs (created from stack tip) |
| `main` | Still the original initial commit until you merge |

### Steps in GitHub Desktop

1. Open **GitHub Desktop**.
2. **File → Add Local Repository…** (or open existing)  
   Path:  
   `/Users/kb/.grok/worktrees/github-buildaimaker/buildaimaker`  
   (or your clone of `omnibond/buildaimaker` if that’s where this tree lives).
3. In the branch dropdown, select **`feature/buildaimaker-mvp`**.
4. Confirm commits appear in History (app + Docs).
5. Click **Publish branch** / **Push origin**.
6. On github.com: **Compare & pull request** into `main` when ready.

### CLI equivalent (if you prefer)

```bash
cd /Users/kb/.grok/worktrees/github-buildaimaker/buildaimaker
git checkout feature/buildaimaker-mvp
git push -u origin feature/buildaimaker-mvp
```

If `git push` asks for credentials, use GitHub Desktop, or switch remote to SSH:

```bash
git remote set-url origin git@github.com:omnibond/buildaimaker.git
```

## Optional: full PR stack (advanced)

There are also 21 local branches named:

```text
execute-plan/28571115-pr-1-...
…
execute-plan/28571115-pr-21-...
```

Those form a **linearized stack** for incremental review. Most teams only need **`feature/buildaimaker-mvp`** unless you want Graphite/stacked PRs.

To push the whole stack (after auth works):

```bash
git push --force-with-lease origin 'execute-plan/28571115-*'
```

## After push

- CI: `.github/workflows/ci.yml` runs `swift build` + `swift test` on macOS.
- Local run: `swift build && open .build/debug/BuildAIMaker`

## Related

- [Docs/README.md](./README.md) — doc index  
- Design PR plan in [design-buildaimaker.md](./design-buildaimaker.md)  
