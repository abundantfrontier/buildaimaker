# Security

BuildAIMaker keeps your characters **on this Mac**. Stories, starting models, taught add-ons, and the small key used by helper programs live in:

```text
~/Library/Application Support/BuildAIMaker/
```

That folder is **not** in this git project. Do not copy `mcp.token`, Hugging Face tokens, or the library database into a pull request.

## Hugging Face (optional downloads)

If you sign in to download models, the app stores that token in the **Mac Keychain**, not in the source tree.

## Helpers that drive the app

When the app is open, another program can talk to it through a local socket. A matching token file is created with tight permissions. Big or destructive steps (like starting a teach, or deleting datasets for real) wait for **you** to tap Allow in an orange banner. The helper cannot approve those for you.

## Reporting a problem

Please use a **private** GitHub security advisory (or email the maintainers). Do not paste live tokens or a full how-to-exploit in a public issue.
