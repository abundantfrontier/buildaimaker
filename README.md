# BuildAIMaker

Make a **fictional** character on your Mac: give them a name and a story, hear a voice, then chat with them. Teaching from their stories is optional. Nothing is uploaded to a company chat service.

This is an **early test build** (0.1). It works as a small studio. It is **not** an App Store app, and there is **no file you can download and double-click**. You open the project on your Mac and run it from there.

| You need | |
|---|---|
| Computer | A **Mac with Apple silicon** (M1, M2, M3, …), macOS 14 or newer |
| To chat | Often just **Apple Intelligence** on, if your Mac supports it |
| To teach them from stories | Extra free space (several GB), and **16 GB of memory or more** if the starting model is large |
| License | [MIT](LICENSE) — free to use and share |

**The loop:** create a character → pick how they think → paste a story → pick a voice → talk in Playground → Teach if you want them to learn those stories.

## How to run it

Install **[Xcode](https://developer.apple.com/xcode/)** from the Mac App Store (free) and open it once so Mac tools finish installing.

### Easiest: Xcode

1. Get this project: on GitHub click **Code → Download ZIP**, or clone it with git.
2. Open the folder and double-click **`Package.swift`**.
3. At the top of Xcode, set the scheme to **BuildAIMaker**.
4. Press the **Run** button (▶) or **⌘R**. The first time can take a few minutes.

### Or: Terminal

```bash
git clone https://github.com/abundantfrontier/buildaimaker.git
cd buildaimaker
swift run BuildAIMaker
```

The first run compiles, then a window should open. After that, the same `swift run BuildAIMaker` command is enough.

Closing the **last window quits** the app.

**You cannot email a friend a single BuildAIMaker file.** It has to live next to this project folder. A normal Mac app icon for download is later work.

### Once the window is open

1. **Home** — if Apple on-device chat is ready, you can go to Playground.
2. **Characters** — create someone. Pick a starting model, paste how they should talk, hear a voice.
3. **Playground** — chat. Turn on **Speak replies** to hear them. For the model you taught, choose **Local MLX** in chat settings (not Apple), or you will hear Apple’s general model instead.
4. **Teach** (Advanced → Train) — they reread their stories. This takes a while and warms up the Mac.
5. **Settings → Repair** — install the local teaching tools (large download). Skip this if you only want Apple on-device chat.

## What you should see in the sidebar

**Studio:** Home, Characters, Playground, Settings  

**Advanced:** Datasets, Models, Train (this is Teach), Jobs, Actions  

Some older ideas (copying a real person’s voice, “persona packs,” talking with the mic) are **not shown**. Use the character **Voice** step or Playground **Speak replies**.

## Honest limits (so you are not surprised)

- Teaching “how much they can change” in the UI does **not** fully apply yet; the teacher uses a small built-in setting.
- Numbers on the Jobs page after teaching are **placeholders**, not a real grade.
- There is no “hold the mic and talk” mode yet. Typed chat + spoken replies is the path.
- Apple chat and the local taught model are **different**. Pick the local one in Playground if you taught them.
- A tiny **practice model** in the app is only for testing the screens. Real teaching needs a real starting model and Repair.

## Where your characters live

On your Mac only:

```text
~/Library/Application Support/BuildAIMaker/
```

Stories, voices, and jobs stay there. Do not put that folder in git.

## For builders

Folder layout, agent/MCP tools, and design notes: [Docs/README.md](Docs/README.md).  
How agents connect: [Docs/mcp-bridge.md](Docs/mcp-bridge.md).  
How to send a change: [CONTRIBUTING.md](CONTRIBUTING.md).  
Tokens and private files: [SECURITY.md](SECURITY.md).

GitHub Actions compiles and runs tests on a Mac. There is no signed app in CI.

## Please don’t

This is for **made-up** creatures and original characters. Do not ship a catalog of celebrity voices, clone someone without permission, or rip an audiobook as a voice.
