<p align="center"><img src="assets/logo.svg" width="80" alt="TangentBar"></p>

# TangentBar

**Double-click any word, anywhere on your Mac, and get an instant definition — grounded in the text around it, answered by a model running on your machine.**

Reading is full of tiny tangents: a word you half-know, jargon from someone else's field, a term that means something different in this context. TangentBar makes the tangent cost nothing — a double-click opens a small card at your cursor with a context-aware definition, streamed from a local model in a fraction of a second. Click anywhere and it's gone.

Two gestures:

- **Double-click a word** → a definition card, grounded in the surrounding passage it extracted from the app you're reading.
- **Drag-select a sentence or paragraph** → an "ask about…" pill → a small chat seeded with that excerpt.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Joshuatanderson/tangentbar/main/install.sh | sh
```

The script downloads the latest release into `/Applications`, walks you through picking local models (it will point you at [Ollama](https://ollama.com) if you don't have a model server yet), and opens the app. Installing via `curl` also means macOS never applies the quarantine flag, so the unsigned build opens without Gatekeeper friction.

**Manual download instead?** Grab the zip from [Releases](https://github.com/Joshuatanderson/tangentbar/releases), then clear the quarantine flag before first open (the app is not notarized — macOS 15+ shows *"damaged and can't be opened"* otherwise):

```sh
unzip TangentBar-*.zip && xattr -dr com.apple.quarantine TangentBar.app && mv TangentBar.app /Applications/ && open /Applications/TangentBar.app
```

### First run

1. macOS asks for the **Accessibility** permission — this is how TangentBar reads the text around your click (see [Privacy](#privacy)). Grant it in System Settings → Privacy & Security → Accessibility; the app detects the grant and arms itself.
2. TangentBar probes for local model servers (Ollama on `:11434`, LM Studio on `:1234`) and adopts the best available model automatically. No server yet? The menu-bar icon shows a badge and links you to Ollama's download.

## Models

Everything runs against **your** local models, switchable from the menu-bar icon:

- **Define model** — answers double-click definitions. Pick something tiny and fast (≤2B parameters); instant beats smart here. Measured ~0.16 s warm on a small qwen.
- **Chat model** — powers the selection chats. Quality matters more; pick your biggest local model, or leave it as "same as define".

If no local server answers and the [claude CLI](https://claude.com/claude-code) is installed, TangentBar falls back to it (haiku for definitions, sonnet for chats). No local models *and* no claude CLI → an honest "no model available" message, never a hang.

## Privacy

- **Your text never leaves your machine.** The only network calls are to `localhost` (your model server). The optional claude-CLI fallback uses whatever auth you've already given that tool — if you don't have it, nothing external ever runs.
- **Nothing is logged.** Extracted words are never written to the system log in normal operation (`--debug` builds log them for troubleshooting).
- **Password fields are suppressed** — secure text fields (native and web) never trigger extraction, on any rung.
- **Clipboard note:** in apps with no accessibility text (some GPU-drawn editors), TangentBar falls back to synthesizing ⌘C on the text your double-click already selected, then restores your clipboard. Clipboard managers may record that intermediate copy. You can disable this rung (`clipboardFallback` in config) or exclude specific apps from the menu.

## Compatibility

| Works | Notes |
|---|---|
| Chromium browsers (Brave, Chrome, Arc) | full context extraction |
| Discord, Slack (Electron) | context stitched from nearby messages |
| cmux / ghostty (GPU terminals) | via copy-on-select + terminal buffer |
| Native Cocoa text (Notes, TextEdit, Mail, Safari) | expected clean; matrix still being proven |
| Google Docs, scanned PDFs | not yet — canvas/image text needs the OCR rung (planned) |

The full adapter matrix lives in [ADAPTERS.md](ADAPTERS.md).

## Menu-bar options

- **Trigger** — bare double-click (default), or require ⌥ / ⌘ / ⌃ held with it.
- **Ask First (pill)** — interpose a small "define?" pill instead of defining immediately.
- **Chat on Selection** — toggle the drag-to-chat flow.
- **Exclude "current app"** — suppress TangentBar entirely in specific apps (games, IDEs).
- **Launch at Login**, model pickers for define/chat, and a test panel.

## Troubleshooting

- **Nothing happens on double-click** → check the Accessibility grant (menu-bar icon shows `!`), and that the app isn't excluded.
- **First answer is slow** → the model is cold-loading (~7 s); TangentBar prewarms and keeps it hot afterwards.
- **Panel says a model is unreachable** → your model server stopped; TangentBar auto-adopts whatever local server is alive, or falls back to the claude CLI.

## Building from source

```sh
swift build            # dev binary (run from a terminal that has the AX grant)
swift test             # unit tests
sh scripts/build-app.sh  # release: dist/TangentBar.app + zip
```

Architecture, decisions of record, and the extraction-ladder design live in [DECISIONS.md](DECISIONS.md) and [ADAPTERS.md](ADAPTERS.md).

## License

[MIT](LICENSE)
